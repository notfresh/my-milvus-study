# Atlas — 项目知识库索引

> 项目「地图 + 速记本」。`docs/` 是正式设计文档、`CLAUDE.md` 是硬性规则，
> `Atlas/` 是带 AI 协作痕迹的**轻量、持续演进**的认知沉淀。

## 使用约定

- **入口**：本文件。任何 agent / 开发者想了解"项目某个面"，先翻这里。
- **文件命名**：
  - `topic-subtopic.md` —— 持续维护的知识条目（如 `dependency-landscape.md`）
  - `YYYY-MM-DD-title.md` —— 一次性事件 / 决策记录（ADR 风格）
- **Frontmatter**：每个文件开头标注 `topic`、`last-verified`、`status`。
  `last-verified` 超过 3 个月的条目，下次访问应优先核实。
- **更新原则**：完成非平凡需求后，**追加**到已有条目优先；新主题才建新文件，
  然后回来更新本索引。`Atlas/` 是"长出来"的，不是"设计死"的。

## 条目状态说明

| status | 含义 |
|--------|------|
| `draft` | 初步整理，可能有错，待补全 |
| `stable` | 已交叉验证过，引用前可不核实 |
| `stale` | 距上次核实较久，引用前应先重看 |

---

## 构建与依赖

- [依赖全景](dependency-landscape.md) — Go / C++ / Rust / Python 全部依赖配置
  文件清单和改动指南。`topic: build`，`status: stable`
- [Makefile 实时进度日志](make-realtime-progress.md) — `Makefile` 第 24–134 行的
  构建进度记录机制解析。`topic: build`，`status: stable`

## 子系统速览

_（待补：从 `docs/agent_guides/` 各子系统浓缩出"5 分钟读懂"版）_

## 决策记录 (ADR)

_（待补：把项目里"为什么这样选"的决定沉淀进来）_

## 实战配方 (How-to)

_（待补：解决具体问题时验证过的步骤）_

---

## 相关资源

- [CLAUDE.md](../CLAUDE.md) — 项目硬性规则（错误处理用 `merr`、日志用 `pkg/v2/log` 等）
- [docs/](../docs/) — 正式设计文档
- [docs/agent_guides/](../docs/agent_guides/) — 给 agent 看的子系统指南
- [DEVELOPMENT.md](../DEVELOPMENT.md) — 本地开发环境搭建
