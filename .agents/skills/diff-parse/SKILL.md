---
name: diff-parse
description: Use when analyzing git repository commit history — extracts insights from git log, produces CSV data and Markdown reports for later reuse and analysis.
---

# Diff-Parse — Git Repository History Analysis

## Overview

Extracts insights from git repository commit history. Produces structured outputs (CSV + Markdown reports) saved to `diff-parse/` directory for later reuse and analysis.

**Core principle:** One task per execution — unless the user explicitly asks for multiple analyses at once.

**Agent must announce:** "Using the diff-parse skill to analyze ..."

## Output Directory

All analysis outputs go to `diff-parse/` in the repository root:

```
diff-parse/
├── INDEX.md              # 分析索引，记录所有产出
├── *.csv                # 原始数据
├── *_diff.patch         # Diff 文件
└── *.md                 # 分析报告
```

## INDEX.md Structure

Every analysis must update `diff-parse/INDEX.md`. Two tables:

```markdown
# Diff-Parse 分析索引

## CSV 产出

| 日期 | 类型 | 目标 | 产出文件 | 说明 |
|------|------|------|---------|------|

## 报告产出

| 日期 | 类型 | 目标 | 产出文件 | 说明 |
|------|------|------|---------|------|
```

Append one row per analysis run. CSV and report are tracked separately because they have different information density.

## Triggers

Natural language only:

- "分析项目历史"
- "分析提交者"
- "分析时区分布"
- "第一次提交是什么"
- "看看 notfresh 的首次提交"
- "导出所有提交记录"

## Analysis Types

### 1. 项目历史统计 (project-history)

**Trigger:** "分析项目历史"、"项目有多少次提交"

**Output:** CSV + 报告

**Git Commands:**
```bash
# 总提交数
git rev-list --count HEAD

# 首次提交
git log --reverse --format="%h %ad %s" --date=short | head -1

# 最新提交
git log --format="%h %ad %s" --date=short | head -1
```

### 2. 提交者分析 (committer-analysis)

**Trigger:** "分析提交者"、"谁贡献最多"

**Output:** CSV + 报告

**Git Commands:**
```bash
# Top 10 提交者排名
git log --format="%an,%ae" | sort | uniq -c | sort -rn | head -10

# 按提交者统计次数
git log --format="%an" | sort | uniq -c | sort -rn | head -10
```

### 3. 时区分析 (timezone-analysis)

**Trigger:** "分析时区分布"

**Output:** CSV + 报告

**Git Commands:**
```bash
# 时区偏移量分布
git log --format="%ad" --date=format:"%z" | sort | uniq -c | sort -rn
```

### 4. 首次提交分析 (earliest-commit)

**Trigger:** "第一次提交是什么"

**Output:** Diff + 报告

**Git Commands:**
```bash
# 获取最早 commit hash
EARLIEST=$(git log --reverse --format="%H" | head -1)
EARLIEST_SHORT=$(git log --reverse --format="%h" | head -1)
COMMIT_DATE=$(git log --reverse --format="%ad" --date=short | head -1)

# 导出完整 diff
git show --format="" $EARLIEST > "diff-parse/${COMMIT_DATE}_${EARLIEST_SHORT}_diff.patch"

# 获取文件列表
git show --format="" --name-only $EARLIEST
```

### 5. 指定人首次提交 (author-first-commit)

**Trigger:** "notfresh 的首次提交"（需替换用户名）

**Output:** Diff + 报告

**Git Commands:**
```bash
# 查找用户的首次提交
FIRST=$(git log --format="%H %ad %s" --date=short --author="<username>" | tail -1 | awk '{print $1}')
PARENT=$(git log --format="%P" --no-walk $FIRST | awk '{print $1}')

# 导出 diff
if [ -n "$PARENT" ]; then
  git diff ${PARENT}..$FIRST > "diff-parse/${COMMIT_DATE}_${FIRST_SHORT}_parent-${PARENT}_diff.patch"
else
  git show --format="" $FIRST > "diff-parse/${COMMIT_DATE}_${FIRST_SHORT}_diff.patch"
fi
```

## Process

### Step 1: Parse Intent
Identify analysis type from user input. If unclear, ask: "你想分析哪种类型？"

### Step 2: Prepare Environment
```bash
mkdir -p diff-parse
```

### Step 3: Execute Git Commands
Run commands for the identified analysis type.

### Step 4: Generate Output
1. CSV output → `diff-parse/*.csv`
2. Diff output → `diff-parse/*_diff.patch`
3. Report output → `diff-parse/*.md`

### Step 5: Update INDEX.md
Append one row to the appropriate table.

### Step 6: Present Results
Show TL;DR findings and output file paths.

## Output Naming Convention

```
<date>_<commit-hash>_<type>.<ext>
```

Examples:
- `2025-10-09_dd013f6_diff.patch`
- `2025-10-09_dd013f6_analysis.md`
- `all_commits.csv`