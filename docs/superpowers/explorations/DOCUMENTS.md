# Project Documents Registry

> 最后更新: 2026-06-26 · 已识别 4 份文档

## 必读 (🟢)
- `client/index/hnsw.go` — HNSW Go 客户端定义，包含 m/efConstruction/ef 参数
- `internal/util/indexparamcheck/constraints.go` — HNSW 参数约束 (M: 1-2048, efConstruction: 1-2147483647)

## 参考 (🟡)
- `internal/core/src/index/IndexFactory.cpp` — C++ 索引工厂，创建 VectorMemIndex (line 1193)
- `internal/core/src/index/VectorMemIndex.h` — 向量内存索引模板，持有 knowhere::Index

## 跳过 (🔴)
- `cmake_build/thirdparty/knowhere/knowhere-src/thirdparty/hnswlib/` — 第三方依赖，无需探索

## 待整理 (🟠)

---
*描述越准，后续越能判断"是否与当前主题相关"。新增文档时给一句"什么时候该读"。*
