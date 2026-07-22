---
name: fetch-pr
description: Use when you need to fetch a GitHub pull request locally for testing or code review
---

# Fetch PR

## Overview

Fetch a GitHub pull request into a local branch for testing, reviewing, or merging.

## Step 1: Detect Remotes

```bash
git remote -v
```

Example output:
```
upstream        https://github.com/milvus-io/milvus.git (fetch)
upstream        https://github.com/milvus-io/milvus.git (push)
origin  https://github.com/notfresh/my-milvus-study.git (fetch)
origin  https://github.com/notfresh/my-milvus-study.git (push)
```

## Step 2: Choose Remote

| Remote | URL Contains | Use For |
|--------|---------------|---------|
| `upstream` | `github.com/milvus-io/milvus` | Official Milvus PRs |
| `origin` | `github.com/notfresh/...` | Your fork PRs |

**Rule:** PRs from `https://github.com/milvus-io/milvus` → use `upstream`

## Step 3: Fetch

```bash
git fetch <REMOTE> pull/<PR_NUMBER>/head:<BRANCH_NAME>
```

Do NOT auto-checkout. Ask the user if they want to switch to the branch.

## Step 4: Analyze PR Changes

The PR branch HEAD IS the PR's commit.

```bash
# Get PR info
git log -1 --format="%H%n%s%n%b" <BRANCH>

# Get diff with line numbers (using -U to show full context with line info)
git show <PR_HEAD_HASH> -U999999

# Get per-file stats
git show <PR_HEAD_HASH> --stat
```

## Step 5: Write Analysis to pr-parse/

Create a markdown file at `pr-parse/<PR_NUMBER>.md` containing:

1. **PR title, author, and commit hash**
2. **Summary** — one-paragraph description of the core fix/feature
3. **Changed files table** — file path (as clickable markdown link), lines added/deleted
4. **Diff section** — the full diff with line numbers, where file paths in headers are clickable links

**File path links** use relative paths from `pr-parse/` (go up one level `../` to reach repo root):
- Source file: `internal/core/src/bitset/bitset.h`
- Markdown link: `[internal/core/src/bitset/bitset.h](../internal/core/src/bitset/bitset.h#L20)`
- The fragment `#L<line>` enables jump-to-line when the file is opened directly

**Diff headers** should be formatted as:
```
### [internal/core/src/bitset/bitset.h](../internal/core/src/bitset/bitset.h)
```

## Quick Reference

```bash
# Fetch from upstream (milvus-io/milvus)
git fetch upstream pull/51678/head:pr/51678

# Fetch from origin (your fork)
git fetch origin pull/123/head:pr/123
```

## Common Mistakes

- **Using `origin` for official PRs**: Official PRs are on `upstream`, not `origin`
- **Branch already exists**: Use `-f` to force update or choose a different branch name
- **Auto-checkout without asking**: Always ask before switching branches
