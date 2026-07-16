# Milvus 2026 年活跃 Top 20 提交者深度分析报告

> 分析日期: 2026-07-16  
> 数据范围: 2026-01-01 至 2026-07-16  
> 数据来源: git log --since="2026-01-01"

---

## 执行摘要

| 指标 | 数值 |
|------|------|
| 总提交数（Top 20） | 1,013 次 |
| 活跃月份 | 7 个月（全员覆盖） |
| 主要时区 | UTC+8（中国北京时间） |
| 核心双核 | congqixia (126) + wei liu (83) |
| 测试双支柱 | yanliang567 (72) + zhuwenxing (45) |

**一句话结论：** Milvus 2026 年以 **修 Bug 为主**（占 fix 类 50%+），**C++ segcore + Go 协调层** 是最活跃的开发区域，团队呈现"两核驱动 + 多域分工"格局。

---

## 一、活跃度排行榜

| 排名 | 作者 | 提交数 | 主要子系统 | 类型倾向 |
|------|------|--------|-----------|---------|
| 1 | congqixia | 126 | datacoord/proxy/segcore/rootcoord | fix+enhance 双高 |
| 2 | wei liu | 83 | datacoord/proxy/storagev2 | fix 为主 |
| 3 | yanliang567 | 72 | tests/python_client | **test (75%)** |
| 4 | Zhen Ye | 71 | datacoord/proxy/querycoordv2 | fix (66%) |
| 5 | Buqian Zheng | 69 | C++ core (index/segcore/expression) | fix (57%) |
| 6 | yihao.dai | 64 | datacoord/streaming | fix (56%) |
| 7 | Spade A | 54 | proxy/segcore | fix (56%) |
| 8 | Chun Han | 51 | proxy/datacoord/segcore | fix/enhance/feat 均衡 |
| 9 | James | 50 | design-docs/core | enhance (42%) |
| 10 | zhuwenxing | 45 | tests/benchmark | **test (78%)** |
| 11 | Xiaofan | 38 | scripts/proxy/expression | fix (45%) |
| 12 | sijie-ni-0214 | 38 | querycoordv2/rootcoord | enhance (45%) |
| 13 | Li Liu | 38 | datacoord/proxy/design_docs | fix (50%) |
| 14 | aoiasd | 37 | datacoord/delegator/rootcoord | enhance (49%) |
| 15 | zhagnlu | 36 | segcore/expression/querynodev2 | **fix (72%)** |
| 16 | sparknack | 35 | segcore/index | **enhance (77%)** |
| 17 | Bingyi Sun | 31 | proxy/rootcoord/expression | enhance (58%) |
| 18 | cai.zhang | 30 | datacoord/datanode | **fix (70%)** |
| 19 | XuanYang-cn | 24 | datacoord/rootcoord/datanode | fix (50%) |
| 20 | marcelo-cjl | 22 | segcore/query | **fix (91%)** |

---

## 二、协作网络分析

### 2.1 协作模式：接力式开发

**无 co-authored-by 协作**（GitHub 的多人共同作者功能几乎未被使用），所有协作通过 **PR 合并** 实现。真正的协作模式是"接力式"——不同作者在不同层负责同一功能：

```
StructArray 特性链:
  Spade A (核心实现) → zhuwenxing (测试覆盖) → James (边界bug修复)

Text Index 栈:
  aoiasd (analyzer) → cai.zhang (compaction构建) → 
  congqixia (sealed状态) → zhagnlu (LOB优化) → Spade A (fuzzy测试)

External Table:
  wei liu (核心功能) → congqixia (CDC集成) → yanliang567 (E2E测试)
```

### 2.2 协作热区文件

| 文件 | 改动次数 | 涉及 Top20 作者数 | 主要协作者 |
|------|---------|-----------------|-----------|
| `ChunkedSegmentSealedImpl.cpp` | 68 | 10 | congqixia主导, sparknack, Buqian Zheng |
| `component_param.go` | 54 | 15 | wei liu=Zhen Ye并列, 无单一主导 |
| `task.go` (proxy) | 21 | 3 | wei liu, Chun Han, James |

### 2.3 双核心架构

```
                    ┌─── congqixia ───┐
                    │  (全栈核心)     │
    sparknack ──────┤                 ├─── wei liu ─────┬── External Table
    (segcore索引)    │                 │   (datacoord/    │
                    └─── Buqian Zheng ┘    proxy)        │
                       (C++ Expression) ├─── yihao.dai ──┤── Import/CDC
                    ┌─── Spade A ────┤                  │
                    │  (StructArray)   ├─── zhuwenxing ──┤── E2E测试
    James ─────────┤                  │                  │
                    └─── Chun Han ────┘                  │
                       (Proxy+API)                     │
                                                     │
                    aoiasd ──────────────────────────┘
                    (analyzer/text)
```

**congqixia** 是全栈协调者，在 Segcore(42) + QueryNodeV2(20) 都是第一贡献者，同时参与 DataCoord/Proxy/RootCoord。  
**wei liu** 是 Go 层协调者，在 DataCoord(255文件) + Proxy(100文件) 都是第一。

---

## 三、子系统专注度分析

### 3.1 深度专注型 vs 跨领域型

| 分类 | 作者 | 专注子系统 |
|------|------|-----------|
| **深度专注 C++ Core** | Buqian Zheng, sparknack, marcelo-cjl, zhagnlu | internal/core/src/ |
| **深度专注测试** | yanliang567, zhuwenxing | tests/ |
| **跨领域协调者** | congqixia, wei liu, Zhen Ye, Chun Han | 5+ 子系统 |
| **数据节点专家** | cai.zhang, XuanYang-cn, yihao.dai | datacoord/datanode/streaming |

### 3.2 最汇聚人气的子系统

```
datacoord   ████████████████████████████  ← 元数据与数据协调，最热
proxy       ██████████████████████████   ← 用户请求入口
segcore     ████████████████████        ← C++ 查询引擎核心
querynodev2 ██████████████              ← 查询节点 v2
rootcoord   ████████████                ← 根协调（鉴权/元数据）
```

**internal/datacoord** 被 9 位 Top 20 作者改动，是协作最密集的协调者组件。  
**internal/core/src/segcore** 被 C++ 专家们密集改动，是性能关键区。

---

## 四、提交类型偏好分析

### 4.1 类型分布总览

| 类型 | 总计 | 占比 | 代表作者 |
|------|------|------|---------|
| fix | ~550 | **55%** | marcelo-cjl (91%), zhagnlu (72%), cai.zhang (70%) |
| enhance | ~320 | 32% | sparknack (77%), Bingyi Sun (58%), James (42%) |
| test | ~89 | 9% | yanliang567 (75%), zhuwenxing (78%) |
| feat | ~50 | 5% | Spade A (31%), Chun Han (20%), wei liu (11%) |
| doc | ~12 | 1% | Li Liu (3), James (2), congqixia (2) |

### 4.2 三类作者画像

**Bug Fix 为主型**（fix >= 50%）：
- marcelo-cjl (91%) — 几乎只修 bug，最纯粹的质量守护者
- zhagnlu (72%) — 专注修复表达式层 bug
- cai.zhang (70%) — datanode/compactor bugfix 专家
- congqixia (67条 fix) — 绝对数量最大，修 bug 总冠军

**Enhancement 为主型**（enhance >= 50%）：
- sparknack (77%) — 纯增强型，专注 segcore 索引加载改进
- Bingyi Sun (58%) — 查询路由/分区增强
- aoiasd (49%) — 跨 delegator/querynode 协调增强

**测试支柱型**（test >= 50%）：
- yanliang567 (75%) — python_client 测试
- zhuwenxing (78%) — benchmark 性能测试

### 4.3 关键发现

1. **Bug Fix 是 2026 年主旋律**：Top 20 中 11 位以 fix 为主，说明项目处于"修bug提稳定性"的成熟期
2. **文档严重不足**：Top 20 合计仅 ~12 条 doc commit，占比 <1%
3. **两位测试支柱**：yanliang567 + zhuwenxing 贡献了 89 条测试 commit，是质量保障核心

---

## 五、活跃时段模式分析

### 5.1 周活跃分布（Top 20 汇总）

```
W01  ████████████████████  111
W02  ██████████████████    91
W05  ██████████████████    98
W11  ███████████████████   94
W12  ████████████████████ 100
W13  █████████████████████ 111
W15  █████████████████████████████ 120
W16  ██████████████████████████████████████████████ 156  ← 峰值
W19  ████████████████████████████ 108
W25  █████████████████████   87
W27  █████████████████████  88
```

**峰值在 W16（4月中）**，与 Q2 开局冲刺吻合。

### 5.2 月度峰值分布

| 作者 | 峰值月 | 爆发特征 |
|------|--------|---------|
| James | **6月 (34次)** | 6月爆发，美东时区 |
| congqixia | 3月 (32次) | 稳定输出，3月略高 |
| wei liu | 4月 (25次) | 4月冲刺 |
| zhagnlu | 6月 (14次) | 6月爆发 |
| Bingyi Sun | 6月 (13次) | 6月爆发 |
| Xiaofan | **1月 (14次)** | 年初爆发后骤降 |
| marcelo-cjl | 1月 (7次) | 年初后持续低活跃 |

### 5.3 持续活跃 vs 间歇爆发

| 模式 | 作者 | 活跃周数 |
|------|------|---------|
| **持续均匀** | congqixia, wei liu, yanliang567, Buqian Zheng | 22-25 周 |
| **间歇活跃** | zhuwenxing, sparknack, aoiasd | 19-22 周 |
| **间歇爆发** | James, yihao.dai, zhagnlu, Bingyi Sun | 集中某几周 |

### 5.4 时区推断

| 时段 (UTC) | 提交密度 | 推断本地时间 |
|-----------|---------|------------|
| 10:00-12:00 | 高峰 | 北京时间 18:00-20:00（傍晚）|
| 13:00-17:00 | 次高峰 | 北京时间 21:00-01:00（深夜）|
| 02:00-05:00 | 低谷 | 北京时间 10:00-13:00（上午）|

**结论**：90%+ 提交者位于 **UTC+8（中国）**，James 可能位于美国东部（6月集中爆发模式吻合美东时区）。

---

## 六、重要发现总结

### 协作层面
1. **无 co-authored-by**：真正的协作通过 PR 合并 + 接力式开发实现
2. **双核驱动**：congqixia（C++ 全栈）+ wei liu（Go 协调层）是项目最重要的两位协调者
3. **热区协作**：`ChunkedSegmentSealedImpl.cpp` 被 10 位 Top 20 作者修改，是最繁忙的协作文件

### 技术层面
4. **Bug Fix 主导**（55%）：2026 年是"修 bug 提稳定性"之年，非大规模新功能建设
5. **C++ segcore 最热**：4 位深度专注型 C++ 专家在此密集工作
6. **测试双支柱**：yanliang567 + zhuwenxing 专职测试，是质量保障核心

### 组织层面
7. **文档严重滞后**：Top 20 doc 占比 <1%，文档可能由社区或 docs team 负责
8. **时区高度集中**：几乎全部作者位于中国（UTC+8），无欧美时区核心贡献者
9. **James 是特例**：6月集中爆发，可能是远程团队成员或时区差异

### 个人亮点
| 作者 | 亮点 |
|------|------|
| **congqixia** | 126 次提交，fix+enhance 双高，全年持续均匀输出，项目稳定支柱 |
| **marcelo-cjl** | fix 占比 91%，最纯粹的质量守护者 |
| **sparknack** | enhance 占比 77%，最纯粹的改进型开发者 |
| **yanliang567 + zhuwenxing** | 测试双支柱，合计 89 条测试 commit |
| **James** | 50 次提交，design-docs 贡献突出，文档型贡献者 |

---

## 附录：可进一步挖掘的信息

1. **PR 合并模式**：每个作者的 PR 数量 vs commit 数量比率（反映是否喜欢 squash merge）
2. **文件所有权**：哪些文件被单一作者长期主导（可做 CODEOWNERS 建议）
3. **CVE/安全修复**：是否有安全相关的 fix（敏感信息不应公开）
4. **社区 vs 内部**：noreply 邮箱背后的真实身份（需 GitHub API 辅助）
5. **跨版本 backport 频率**：哪些作者的 patch 最常被 backport 到旧版本
