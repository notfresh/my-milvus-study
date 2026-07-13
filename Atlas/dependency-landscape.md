---
topic: build
last-verified: 2026-06-12
status: stable
related: [../CLAUDE.md, ../DEVELOPMENT.md]
---

# Milvus 项目依赖全景

> Milvus 是多语言混合构建的向量数据库：C++ 负责核心查询引擎（`internal/core`），
> Go 负责协调节点/Proxy/数据节点等分布式组件，Rust 通过 `corrosion` 集成进来
> 负责 tantivy 全文索引与 milvus-storage 的部分能力，Python 仅出现在测试与
> 离线部署工具中。理解 Milvus 的依赖，要按语言分别看。

## 1. Go 模块体系

Go 端有 **多个独立 Go module**——这在 Go 项目里不算常见，但对一个由多个
子项目组合而成的系统很合理：

| 模块 | 路径 | 角色 |
|------|------|------|
| 主模块 | `go.mod` | 协调节点、Proxy、DataNode、QueryNode、所有内部包 |
| pkg 子模块 | `pkg/go.mod` | 跨子项目复用的工具库（merr、log、paramtable、proto 等） |
| client SDK | `client/go.mod` | 公开的 Go SDK |
| 测试客户端 | `tests/go_client/go.mod` | Go 端集成测试 |
| 示例 | `examples/telemetry_demo/go.mod`、`examples/telemetry_e2e_test/go.mod` | 演示与端到端测试 |
| proto 子模块 | `cmake_build/thirdparty/milvus-proto/go.mod` 与 `go-api/go.mod` | CMake 构建时由 milvus-proto 仓库嵌入的子模块 |

`pkg` 目录有**自己独立的 module**（`github.com/milvus-io/milvus/pkg/v3`），
CLAUDE.md 明确指出：往 `pkg/` 加依赖时要 `cd pkg && go get`，从根目录
`go get` 不会作用于这个子模块。每个模块都有自己的 `go.sum` 校验文件。

## 2. C++ 依赖（Conan + CMake）

C++ 是 Milvus 依赖最复杂的一层，构建系统由 **Conan 2.x** 管包，由 **CMake**
编译，最后通过 **Corrosion**（CMake 的 cargo 桥接）引入 Rust 组件。

### 2.1 核心文件

- **`internal/core/conanfile.py`** —— C++ 依赖的「中央注册表」，列出 30+ 个
  Conan 包（rocksdb、arrow、folly、opentelemetry-cpp、aws-sdk-cpp、
  azure-sdk-for-cpp、google-cloud-cpp、abseil、protobuf/grpc、boost、openssl、
  prometheus-cpp 等等）以及它们的 `force=True` 强制版本。
- **`internal/core/CMakeLists.txt`** —— Milvus 核心引擎的总构建入口。
- **`internal/core/thirdparty/CMakeLists.txt`** —— 内部 thirdparty 子目录聚合，
  把 `boost_ext/rocksdb/simdjson/opendal/milvus-storage/jemalloc/rdkafka/tantivy/knowhere/...`
  等拉到一起编译。
- **`internal/core/thirdparty/versions.txt`** —— 7 行小文件，记录了**不被 Conan
  托管、直接走源码/系统包**的几个 C++ 库的版本：

  ```
  GTEST_VERSION=1.8.1
  YAMLCPP_VERSION=0.6.3
  OPENTRACING_VERSION=v1.5.1
  PROTOBUF_VERSION=3.9.0
  LIBUNWIND_VERSION=1.6.2
  GPERFTOOLS_VERSION=2.9.1
  MILVUS_JEMALLOC_BUILD_VERSION=5.2.1
  ```

  注意：conanfile.py 中托管的那些版本（rocksdb/arrow/folly/abseil/grpc/
  protobuf 5.27.0 …）并不在这里出现，**这里只列「不走 conan 的硬编码版本」**，
  相当于一份「逃生舱」清单。改版本时要分清楚你改的是 Conan 托管的还是源码自带的。

### 2.2 子模块构建（internal/core/src）

C++ 引擎的每个子目录都有独立的 `CMakeLists.txt`，体现 Milvus 的模块化组织：

- `segcore/`、`query/`、`index/`、`indexbuilder/` —— 向量/标量检索核心
- `storage/` 及其下的 `minio/`、`gcp-native-storage/`、`azure/`、`aliyun/`、
  `tencent/`、`huawei/`、`loon_ffi/` —— 多云对象存储适配
- `clustering/`、`plan/`、`common/`、`bitset/`、`exec/`、`minhash/`、`monitor/`、
  `pb/`、`config/`、`futures/`、`rescores/` —— 其它子模块

测试和基准也各自有：`unittest/CMakeLists.txt`、`benchmark/CMakeLists.txt`。

### 2.3 cmake_build 目录

`cmake_build/` 是**构建期下载并展开的第三方源码目录**，不是源项目维护的代码：

- `3rdparty_download/`：构建时通过 FetchContent/CPM 下载（mongo-cxx-driver、
  mongo-c-driver、simdjson、corrosion、knowhere、milvus-storage）。
- `thirdparty/`：已经下载好的仓库副本（knowhere、milvus-proto、milvus-storage）。
  这里能看到 vcpkg 的痕迹，但只在 mongo-c-driver 的 *examples* 子目录里，
  **Milvus 主项目不用 vcpkg**。
- `corrosion/required_libs/`：corrosion 在 cargo 端需要的 Rust 库。
- `conan/`：Conan 包缓存与 cmake 配置文件生成位置（`conanfile.py` 写明的
  `generators_folder` 就在 `cmake_build/conan/`）。

## 3. Rust 依赖

Milvus 自身直接维护的 Rust crate 只有两个，**都在 `internal/core/thirdparty/`**：

- **`internal/core/thirdparty/tantivy/tantivy-binding/Cargo.toml`** ——
  全文搜索引擎 tantivy 的 C++ 绑定（Milvus 通过 cgo/corrosion 暴露给 C++ 端）。
- `cmake_build/thirdparty/milvus-storage/milvus-storage-src/rust/Cargo.toml`
  与 `bridge/rust/Cargo.toml` —— milvus-storage 的 Rust 部分（columnar format），
  通过 corrosion 集成进 C++ 构建。

集成原理：`internal/core/thirdparty/CMakeLists.txt` 在编译时启用 `corrosion`
（CMake 的 Cargo 集成），把上述 `Cargo.toml` 编译产物静态链接进
`milvus_storage` C++ 库。这意味着 **修改 tantivy 版本 = 改
`internal/core/thirdparty/tantivy/tantivy-binding/Cargo.toml`**；修改
milvus-storage 的 Rust 部分则需要进入 `cmake_build/thirdparty/milvus-storage/`
（这是上游仓库的副本）。

## 4. Python 依赖（仅测试/工具）

Milvus 主程序不依赖 Python。Python `requirements.txt` 全部用于**测试或离线工具**：

- `tests/python_client/requirements.txt`、`chaos/`、`deploy/`、`data_verify/`
  —— pymilvus 测试套件
- `tests/restful_client/requirements.txt`、`v2/` —— REST API 测试
- `tests/go_client/requirements.txt` —— Go client 的 Python 端驱动
- `cmd/tools/binlogv2/requirements.txt` —— binlog 工具
- `deployments/offline/requirements.txt` —— 离线安装包生成

注意：项目里**没有** `pyproject.toml`、`setup.py`、`Pipfile`，纯 requirements
文件管理。

## 5. 构建与工具链文件

- `Makefile` —— 顶层构建入口（`make milvus`、`make test-go`、
  `make generated-proto-without-cpp` 等）
- `client/Makefile`、`pkg/Makefile`、`tests/Makefile` —— 各子项目 Makefile
- `configs/milvus.yaml`、`configs/hook.yaml` —— 运行时配置（不属于依赖，
  但常被一并查阅）
- `internal/core/build-support/cpp_license.txt` 与 `cmake_license.txt` ——
  新增源文件时使用的版权头模板
- `internal/core/thirdparty/versions.txt` —— 前面已讨论
- `internal/core/lsan_suppressions.txt` —— LeakSanitizer 抑制规则

## 6. 改动依赖时的"按表操课"清单

| 你想改的东西 | 改这个文件 |
|------|------|
| Go 主程序依赖 | `go.mod`（根目录执行 `go get`） |
| pkg/ 工具库依赖 | `pkg/go.mod`（`cd pkg && go get`） |
| Go SDK 依赖 | `client/go.mod` |
| C++ 中**由 Conan 管**的库（rocksdb、arrow、folly、opentelemetry、aws-sdk、grpc、protobuf、boost、openssl…） | `internal/core/conanfile.py` |
| C++ 中**不走 Conan** 的硬编码库（gtest 1.8.1、yaml-cpp 0.6.3、protobuf 3.9.0、jemalloc 5.2.1 等） | `internal/core/thirdparty/versions.txt` + 对应的 `internal/core/thirdparty/<lib>/CMakeLists.txt` |
| 新增 C++ 第三方子目录 | 在 `internal/core/thirdparty/CMakeLists.txt` 注册 |
| tantivy 版本 | [Cargo.toml](../internal/core/thirdparty/tantivy/tantivy-binding/Cargo.toml) |
| Python 测试依赖 | 对应 `tests/.../requirements.txt` |
| Proto 协议生成 | CMake 触发 `make generated-proto-without-cpp`，**不要**手改 `pkg/proto/*.pb.go` |

## 7. 小结

Milvus 的依赖结构可以概括为三句话：

1. **Go 端**走标准 `go modules`，靠多 module 划分边界。
2. **C++ 端**是项目里依赖治理最重的部分：Conan 2.x 管「主菜」，
   `versions.txt` 管「配菜」，CMake 串起一切；其中 protobuf 是个有趣的双源 ——
   既出现在 Conan (`5.27.0@milvus/dev`) 也作为兜底版本出现在 `versions.txt` (`3.9.0`)。
3. **Rust 端**是 C++ 的延伸（通过 corrosion），主项目自己只维护 tantivy 绑定和
   milvus-storage 桥接，存储格式与索引逻辑都在上游仓库。

理解这个三层结构后，无论是要做依赖升级、安全审计、还是裁剪构建，都知道该动哪份文件。
