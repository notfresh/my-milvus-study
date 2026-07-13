# HNSW Algorithm Implementation in Milvus

## Overview

HNSW (Hierarchical Navigable Small World) is a graph-based ANN (Approximate Nearest Neighbor) algorithm. In Milvus, HNSW is implemented through **Knowhere** - a C++ vector search library that wraps **hnswlib**.

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────────┐
│  Go Client Layer                                                │
│  client/index/hnsw.go - HNSW index definition                   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Go Internal Layer                                              │
│  internal/util/indexparamcheck/ - Parameter validation           │
│  internal/util/indexcgowrapper/ - CGO bridge to C++             │
└─────────────────────────────────────────────────────────────────┘
                              ↓ (CGO)
┌─────────────────────────────────────────────────────────────────┐
│  C++ Core Layer (milvus-core)                                   │
│  internal/core/src/index/                                       │
│    IndexFactory.cpp - Index creation                            │
│    VectorMemIndex.h/cpp - Vector index wrapper                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Knowhere Library                                               │
│  internal/core/output/include/knowhere/                         │
│    index_factory.h - Index factory with registration macros     │
│    index_node.h - Base index interface                          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  hnswlib (Third-party)                                         │
│  cmake_build/thirdparty/knowhere/knowhere-src/                  │
│    thirdparty/hnswlib/hnswlib/                                  │
│      hnswalg.h - HierarchicalNSW class (core algorithm)         │
│      hnswlib.h - Base classes and interfaces                   │
│      space_*.h - Distance functions (L2, IP, Cosine, etc)      │
└─────────────────────────────────────────────────────────────────┘
```

## Key Files

### Go Layer (User-Facing)

| File | Purpose |
|------|---------|
| [client/index/hnsw.go](client/index/hnsw.go) | Go client HNSW index definition |
| [client/index/common.go](file://client/index/common.go) | Index type constants (HNSW = "HNSW") |
| [internal/util/indexparamcheck/constraints.go](file://internal/util/indexparamcheck/constraints.go) | HNSW parameter constraints (M, efConstruction) |
| [internal/util/indexcgowrapper/index.go](file://internal/util/indexcgowrapper/index.go) | CGO bridge (`#cgo pkg-config: milvus_core`) |

### C++ Core Layer

| File | Purpose |
|------|---------|
| `internal/core/src/index/IndexFactory.cpp` | Creates `VectorMemIndex<T>` for HNSW (line 1193) |
| `internal/core/src/index/VectorMemIndex.h` | Template wrapper holding `knowhere::Index<IndexNode>` |
| `internal/core/output/include/knowhere/index/index_factory.h` | Factory with `Create<T>()` and registration macros |
| `internal/core/output/include/knowhere/index/index_table.h` | HNSW index registration (line 86-106) |

### Knowhere + hnswlib (Algorithm Implementation)

| File | Purpose |
|------|---------|
| `cmake_build/.../knowhere-src/src/index/hnsw/hnsw.h` | **Knowhere's `HnswIndexNode` template** - main entry point for search/build |
| `cmake_build/.../hnswlib/hnswlib/hnswalg.h` | **Core `HierarchicalNSW` class** - actual HNSW algorithm |
| `cmake_build/.../hnswlib/hnswlib/hnswlib.h` | Base interfaces (`SpaceInterface`, `AlgorithmInterface`) |
| `cmake_build/.../hnswlib/hnswlib/space_l2.h` | L2 distance |
| `cmake_build/.../hnswlib/hnswlib/space_ip.h` | Inner Product distance |
| `cmake_build/.../hnswlib/hnswlib/space_cosine.h` | Cosine similarity |
| `cmake_build/.../hnswlib/hnswlib/space_hamming.h` | Hamming distance |
| `cmake_build/.../hnswlib/hnswlib/space_jaccard.h` | Jaccard distance |

## Call Chain

### Index Build
```
1. client/index/hnsw.go
   NewHNSWIndex(metricType, m, efConstruction)
   
2. internal/util/indexcgowrapper/index.go
   CgoIndex.Build(dataset)
   → C.CreateIndex(...) [CGO call]
   
3. internal/core/src/index/IndexFactory.cpp (line 1193)
   VectorMemIndex<float>::VectorMemIndex(...)
   → knowhere::IndexFactory::Instance().Create<T>(INDEX_HNSW, version)
   
4. knowhere (hnsw.h)
   HnswIndexNode::Train(dataset, config)
   → HnswIndexNode::Add(dataset, config)
   → hnswlib::HierarchicalNSW::addPoint()
   
5. hnswlib/hnswalg.h (line ~200+)
   HierarchicalNSW::addPoint()
```

### Search
```
1. internal/core/src/index/VectorMemIndex.cpp
   VectorMemIndex::Query()
   → index_.Search(dataset, config, bitset)
   
2. knowhere (hnsw.h)
   HnswIndexNode::Search(dataset, config, bitset)
   → index_->searchKnn(query, k, bitset, &param)
   
3. hnswlib/hnswalg.h
   HierarchicalNSW::searchKnn()
```

## HNSW Parameters

### Build Parameters (Go → C++)
| Parameter | Go Field | C++ Field | Constraint |
|-----------|----------|-----------|------------|
| M | `m` | `hnsw_cfg.M` | 1-2048 |
| efConstruction | `efConstruction` | `hnsw_cfg.efConstruction` | 1-2147483647 |

### Search Parameters
| Parameter | C++ Field | Purpose |
|-----------|-----------|---------|
| ef | `hnsw_cfg.ef` | Search window size (higher = more accurate but slower) |

### Supported Metrics
| Metric | Go Constant | C++ Metric | Data Types |
|--------|-------------|------------|------------|
| L2 | `metric.L2` | `Metric::L2` | float, float16, bfloat16, int8 |
| IP | `metric.IP` | `Metric::INNER_PRODUCT` | float, float16, bfloat16, int8 |
| COSINE | `metric.COSINE` | `Metric::COSINE` | float, float16, bfloat16, int8 |
| HAMMING | `metric.HAMMING` | `Metric::HAMMING` | binary |
| JACCARD | `metric.JACCARD` | `Metric::JACCARD` | binary |

## HNSW Variants in index_table.h

Knowhere registers multiple HNSW variants:
- `INDEX_HNSW` - Standard HNSW
- `INDEX_HNSW_SQ` - HNSW with SQ8 quantization
- `INDEX_HNSW_PQ` - HNSW with Product Quantization
- `INDEX_HNSW_PRQ` - HNSW with Product Quantization Refine

## Core Algorithm (hnswalg.h)

The `HierarchicalNSW` template class (line 73+) implements:

```cpp
template <typename data_t, typename dist_t, QuantType quant_type>
class HierarchicalNSW : public AlgorithmInterface<dist_t> {
    // Key methods:
    void addPoint(const void* dataPoint, tableint label);  // Build
    std::priority_queue<Neighbor> searchKnn(...);          // Search
    std::vector<std::pair<dist_t, tableint>> searchRange(...); // Range search
};
```

## Notes

1. **Third-party code**: The `hnswlib` in `cmake_build/thirdparty/` is a vendored dependency, not maintained in this repo.

2. **CGO boundary**: Go code crosses into C++ via `indexcgowrapper` using `#cgo pkg-config: milvus_core`.

3. **Build vs Search**: HNSW build uses `efConstruction` (higher = better graph quality, slower build), while search uses `ef` (higher = more accurate, slower search).
