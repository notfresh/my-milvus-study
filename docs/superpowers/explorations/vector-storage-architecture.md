# Milvus 向量存储架构探索

**探索时间**: 2026-06-17
**探索主题**: Milvus 向量数据存储方式

## 结论概览

Milvus 的向量存储**不是线性连续存储，也不是 B+树结构**，而是采用了**分块列式存储（Chunked Columnar Storage）**架构。

---

## 1. 存储结构层级

| 层级 | 描述 |
|------|------|
| **Field** | 每个字段（列）独立存储 |
| **Chunk** | 字段数据分成固定大小的数据块 |
| **Data** | 每个 chunk 内部是线性连续的内存 |

### 关键代码位置

- `internal/core/src/mmap/ChunkedColumn.h` - 分块列式存储基类
- `internal/core/src/mmap/ChunkVector.h` - 线程安全的 chunk 向量实现
- `internal/core/src/segcore/ChunkedSegmentSealedImpl.h` - Segment 实现

### Segment 结构

```cpp
class ChunkedSegmentSealedImpl : public SegmentSealed {
    folly::Synchronized<
        std::unordered_map<FieldId, std::shared_ptr<ChunkedColumnInterface>>>
        fields_;  // 每个字段映射到其分块列
};
```

---

## 2. 向量类型与内存布局

**支持的向量类型** (`internal/storage/insert_data.go`):

| 类型 | 存储格式 | 维度计算 |
|------|----------|----------|
| FloatVector | `[]float32` | dim * 4 bytes |
| BinaryVector | `[]byte` | dim / 8 bytes |
| Float16Vector | `[]byte` | dim * 2 bytes |
| BFloat16Vector | `[]byte` | dim * 2 bytes |
| SparseFloatVector | 特殊稀疏格式 | - |

---

## 3. 磁盘文件格式（Binlog）

### 路径层次结构

```
{rootPath}/
├── insert_log/{collID}/{partID}/{segID}/{fieldID}/{logID}  # 向量原始数据
├── delta_log/{collID}/{partID}/{segID}/{logID}             # 删除操作日志
├── index_v1/{collID}/{partID}/{segID}/{fieldID}/{logID}     # 向量索引
├── stats_log/{collID}/{partID}/{segID}/{fieldID}/{logID}
└── part_stats/
```

### Binlog 格式

```
[Magic Number 0xfffabc] + [Descriptor Event] + [Data Events...]
```

- 使用 **Arrow/Parquet** 序列化格式
- 向量序列化为 `FixedSizeBinary` Arrow 类型
- 支持 Zstd 压缩
- 支持加密

---

## 4. 向量索引类型

Milvus 使用 **Knowhere** 库构建索引，支持多种算法：

| 索引类型 | 特点 |
|----------|------|
| **HNSW** | 层次导航小世界图，高召回率 |
| **IVF_FLAT** | 倒排索引，精确版本 |
| **IVF_PQ** | 倒排索引 + 产品量化 |
| **DiskANN** | 磁盘优化的大规模向量索引 |
| **ScaNN** | Google 的可扩展向量索引 |
| **ANNOY** | 树结构索引 |

### 索引构建流程

1. 计算内存需求（根据向量类型和维度）
2. 调用 `indexcgowrapper.CreateIndex()` 构建索引
3. 序列化索引并上传到对象存储

---

## 5. 内存管理

- **Chunk 级缓存** - 按块加载/卸载
- **MMAP 支持** - 大向量/索引的内存映射访问
- **线程安全** - 使用 `std::shared_mutex` 保护并发访问

---

## 6. 关键洞察

1. **列式存储** - 按列存储而非行存储，每个字段独立
2. **分块管理** - 数据分成 chunks 而不是单一连续数组，便于按需加载
3. **多级存储** - 内存中活跃数据 + 磁盘完整数据 + 索引结构
4. **Knowhere 抽象** - 索引逻辑委托给独立的 Knowhere 库
5. **元数据分离** - Schema、FieldInfo 与向量数据分开存储

---

---

## 7. 完整数据流：向量从 Proxy 到落盘

### 7.1 调用链路总览

```
用户 Insert 请求
    ↓
[1] Proxy 接收 (impl.go:2744)
    ↓
[2] InsertTask 创建与调度 (impl.go:2778, task_scheduler.go:560)
    ↓
[3] 数据发送 (task_insert_streaming.go:29)
    ↓
[4] Streaming Service 接收 (WAL)
    ↓
[5] Datanode DataSyncService (data_sync_service.go:341)
    ↓
[6] WriteBuffer 缓冲 (write_buffer.go:222)
    ↓
[7] Sync 触发 (sync_policy.go) - 多策略触发
    ↓
[8] Binlog 写入 (pack_writer.go:70)
    ↓
[9] 索引构建 (index_services.go:261, task_index.go:228)
    ↓
[10] 文件落盘
```

### 7.2 详细阶段说明

#### [1] Proxy 接收层

**入口文件**: [xx](../../../internal/proxy/impl.go:2744)

```go
func (node *Proxy) Insert(ctx context.Context, request *milvuspb.InsertRequest) (*milvuspb.MutationResult, error)
```

- REST API 和 gRPC 入口都通过 `MilvusServiceServer` 接口实现
- 接收 `InsertRequest` 包含：`DbName`, `CollectionName`, `PartitionName`, `FieldsData`, `NumRows`, `HashKeys`

#### [2] 任务创建与调度

**文件**: `internal/proxy/impl.go:2778-2802`

```go
it := &insertTask{
    ctx:       ctx,
    insertMsg: &msgstream.InsertMsg{...},
    idAllocator:     node.rowIDAllocator,
    chMgr:           node.chMgr,
}
// 加入调度队列
node.sched.dmQueue.Enqueue(it)
```

**调度处理** (`internal/proxy/task_scheduler.go:560-604`):

```go
func (sched *taskScheduler) processTask(t task, q taskQueue) {
    err := t.PreExecute(ctx)  // 预执行验证
    err = t.Execute(ctx)       // 实际执行
    err = t.PostExecute(ctx)   // 后处理
}
```

#### [3] PreExecute 验证流程

**文件**: `internal/proxy/task_insert.go:103-298`

1. 集合名称验证
2. 请求大小检查
3. 集合 ID 获取
4. 集合 Schema 获取
5. 字段数据验证
6. 主键字段检查
7. 数据类型规范化
8. ID 分配 (`AllocAutoID`)

#### [4] Execute 数据发送

**文件**: `internal/proxy/task_insert_streaming.go:29-89`

```go
// 虚拟通道分配
channelNames, err := it.chMgr.getVChannels(collID)

// 根据主键分配到不同的虚拟通道
channel2RowOffsets := assignChannelsByPK(result.IDs, channelNames, insertMsg)

// 构建 WAL 消息
newMsg, err := message.NewInsertMessageBuilderV1().
    WithVChannel(channel).
    WithHeader(&message.InsertMessageHeader{...}).
    WithBody(insertRequest).
    BuildMutable()

// 追加到 WAL
resp := streaming.WAL().AppendMessages(ctx, msgs...)
```

**协议**: 使用 Milvus Streaming Service (WAL - Write-Ahead Log)

#### [5] Datanode 数据接收

**文件**: `internal/flushcommon/pipeline/data_sync_service.go:341`

```go
func NewDataSyncService(initCtx context.Context, pipelineParams *util.PipelineParams,
    info *datapb.ChannelWatchInfo, tickler *util.Tickler) (*DataSyncService, error)
```

#### [6] WriteBuffer 缓冲

**文件**: `internal/flushcommon/writebuffer/write_buffer.go:222`

```go
func NewWriteBuffer(channel string, metacache metacache.MetaCache,
    syncMgr syncmgr.SyncManager, opts ...WriteBufferOption) (WriteBuffer, error)
```

**L0 写缓冲区** (`internal/flushcommon/writebuffer/l0_write_buffer.go:62-100`):

```go
func (wb *l0WriteBuffer) BufferData(insertData []*InsertData, ...) error {
    for _, inData := range insertData {
        err := wb.bufferInsert(inData, startPos, endPos, schemaVersion)
    }
    wb.dispatchDeleteMsgsWithoutFilter(deleteMsgs, startPos, endPos)
    segmentsSync := wb.triggerSync()
}
```

#### [7] Flush 触发策略

**文件**: `internal/flushcommon/writebuffer/sync_policy.go`

| 策略 | 触发条件 |
|------|----------|
| `GetFullBufferPolicy()` | 缓冲区满（行数或字节大小达到限制） |
| `GetSyncStaleBufferPolicy()` | 缓冲区过期（时间超过阈值） |
| `GetSealedSegmentsPolicy()` | 分段被封印（Sealed） |
| `GetFlushTsPolicy()` | Flush 时间戳到达 |
| `GetOldestBufferPolicy()` | 最旧的 N 个缓冲区 |

#### [8] Binlog 写入

**PackWriter** (`internal/flushcommon/syncmgr/pack_writer.go:70-98`):

```go
func (bw *BulkPackWriter) Write(ctx context.Context, pack *SyncPack) (
    inserts map[int64]*datapb.FieldBinlog,
    deltas *datapb.FieldBinlog,
    stats map[int64]*datapb.FieldBinlog,
    bm25Stats map[int64]*datapb.FieldBinlog,
    size int64, err error,
) {
    // 1. 写插入数据
    inserts, err = bw.writeInserts(ctx, pack)
    // 2. 写统计信息
    stats, err = bw.writeStats(ctx, pack)
    // 3. 写删除数据
    deltas, err = bw.writeDelta(ctx, pack)
    // 4. 写 BM25 统计
    bm25Stats, err = bw.writeBM25Stasts(ctx, pack)
}
```

**序列化** (`internal/flushcommon/syncmgr/storage_serializer.go:62-86`):

```go
func (s *storageV1Serializer) serializeBinlog(ctx context.Context, pack *SyncPack) {
    blobs, err := s.inCodec.Serialize(pack.partitionID, pack.segmentID, pack.insertData...)
}
```

**InsertCodec** (`internal/storage/data_codec.go:227-450`):

```go
func (insertCodec *InsertCodec) Serialize(partitionID, segmentID UniqueID, data ...*InsertData) ([]*Blob, error) {
    // 为每个字段创建 BinlogWriter
    writer = NewInsertBinlogWriter(field.DataType, ..., binlogWriterOpts...)
    // 添加字段数据到 payload
    eventWriter.AddFieldDataToPayload(field.DataType, singleData)
}
```

**BinlogWriter** (`internal/storage/binlog_writer.go:73+`):
- 管理 Binlog 文件头 (`descriptorEvent`)
- 序列化 Event 数据
- 写入到 ChunkManager (S3/MinIO)

#### [9] 索引构建

**索引任务创建** (`internal/datanode/index_services.go:261-329`):

```go
func (node *DataNode) createIndexTask(ctx context.Context, req *workerpb.CreateJobRequest) {
    task := index.NewIndexBuildTask(taskCtx, taskCancel, req, cm, node.taskManager, pluginContext)
    node.taskScheduler.TaskQueue.Enqueue(task)  // 异步入队
}
```

**索引执行** (`internal/datanode/index/task_index.go:228-355`):

```go
func (it *indexBuildTask) Execute(ctx context.Context) error {
    // 1. 估算字段数据大小
    switch it.req.GetField().GetDataType() {
    case schemapb.DataType_FloatVector:
        fieldDataSize = dim * numRows * 4
    }

    // 2. 构建索引参数
    buildIndexParams := &indexcgopb.BuildIndexInfo{...}

    // 3. 异步创建索引 (CGO 调用 Knowhere)
    it.index, err = indexcgowrapper.CreateIndex(ctx, buildIndexParams)

    // 4. 上传索引文件到对象存储
    // 5. 通知 IndexCoord
}
```

#### [10] 最终落盘文件

```
{rootPath}/
├── insert_log/{collID}/{partID}/{segID}/{fieldID}/{logID}  # 向量原始数据
├── delta_log/{collID}/{partID}/{segID}/{logID}             # 删除日志
├── stats_log/{collID}/{partID}/{segID}/{fieldID}/{logID}   # 统计信息
├── bm25_stats/{collID}/{partID}/{segID}/{fieldID}/{logID}  # BM25 统计
└── index_v1/{collID}/{partID}/{segID}/{fieldID}/{logID}   # 向量索引
```

### 7.3 关键文件总结

| 组件 | 文件路径 | 关键函数 |
|------|---------|---------|
| **Proxy 入口** | `internal/proxy/impl.go:2744` | `Proxy.Insert()` |
| **任务调度** | `internal/proxy/task_scheduler.go:560` | `processTask()` |
| **插入预处理** | `internal/proxy/task_insert.go:103` | `insertTask.PreExecute()` |
| **数据发送** | `internal/proxy/task_insert_streaming.go:29` | `insertTask.Execute()` |
| **通道分配** | `internal/proxy/task_insert_streaming.go:91` | `repackInsertDataForStreamingService()` |
| **DataSyncService** | `internal/flushcommon/pipeline/data_sync_service.go:341` | `NewDataSyncService()` |
| **WriteBuffer** | `internal/flushcommon/writebuffer/write_buffer.go:222` | `NewWriteBuffer()` |
| **L0 Buffer** | `internal/flushcommon/writebuffer/l0_write_buffer.go:34` | `NewL0WriteBuffer()` |
| **BufferData** | `internal/flushcommon/writebuffer/l0_write_buffer.go:62` | `BufferData()` |
| **Sync 策略** | `internal/flushcommon/writebuffer/sync_policy.go` | 多策略触发 |
| **PackWriter** | `internal/flushcommon/syncmgr/pack_writer.go:70` | `BulkPackWriter.Write()` |
| **Storage Serializer** | `internal/flushcommon/syncmgr/storage_serializer.go:62` | `serializeBinlog()` |
| **InsertCodec** | `internal/storage/data_codec.go:227` | `InsertCodec.Serialize()` |
| **BinlogWriter** | `internal/storage/binlog_writer.go` | `InsertBinlogWriter` |
| **索引任务** | `internal/datanode/index_services.go:261` | `createIndexTask()` |
| **索引执行** | `internal/datanode/index/task_index.go:228` | `IndexBuildTask.Execute()` |

### 7.4 关键技术特性

1. **流式服务架构**: 使用新的 Streaming Service (WAL) 替代传统的 msgstream
2. **L0 Buffer**: 新的 L0 写缓冲区设计，避免频繁 Flush
3. **多策略 Flush**: 支持缓冲区满、过期、封印、时间戳、最旧等多种触发条件
4. **异步索引构建**: 索引构建完全异步，不阻塞数据写入
5. **CGO 索引**: 使用 Knowhere C++ 库构建高性能向量索引
6. **字段级序列化**: 每个字段单独序列化为独立的 Binlog 文件
7. **加密支持**: 完整的端到端加密支持

---

## 相关文件

| 文件 | 用途 |
|------|------|
| `internal/storage/insert_data.go` | 向量数据结构定义 |
| `internal/storage/binlog_writer.go` | Binlog 文件格式 |
| `internal/storage/serde.go` | Arrow/Parquet 序列化 |
| `internal/core/src/segcore/ChunkedSegmentSealedImpl.h` | Segment 实现 |
| `internal/core/src/mmap/ChunkedColumn.h` | 列式 chunk 结构 |
| `internal/core/src/index/VectorMemIndex.h` | 内存索引实现 |
| `internal/core/src/index/VectorDiskIndex.cpp` | 磁盘索引实现 |
