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
git checkout <BRANCH_NAME>
```

## Quick Reference

```bash
# Fetch from upstream (milvus-io/milvus)
git fetch upstream pull/51678/head:enhance/amortize-getchunk-bulk

# Fetch from origin (your fork)
git fetch origin pull/123/head:fix/my-branch
```

## Common Mistakes

- **Using `origin` for official PRs**: Official PRs are on `upstream`, not `origin`
- **Branch already exists**: Use `-f` to force update or choose a different branch name
- **checkout**: checkout without permission, usually pull doesn't mean checkout to it

## Example Session

```bash
$ git remote -v
upstream        https://github.com/milvus-io/milvus.git (fetch)
origin  https://github.com/notfresh/my-milvus-study.git (fetch)

# Fetch PR 51678 from upstream
$ git fetch upstream pull/51678/head:enhance/amortize-getchunk-bulk
```
