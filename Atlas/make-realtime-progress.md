---
topic: build
last-verified: 2026-07-13
status: stable
related: [../Makefile, ../DEVELOPMENT.md]
---

# Makefile 实时进度日志系统

> `Makefile` 第 24–134 行实现了一套轻量级的构建进度记录机制。
> 在 `make milvus` 等长时间构建完成后，即使终端滚动条丢失，
> 仍能从日志文件回溯每个阶段的起止时间与退出码。

## 1. 核心变量

| 变量 | 默认值 | 作用 |
|------|--------|------|
| `MILVUS_REALTIME_PROGRESS` | `1` | 主开关；设为 `0` 完全关闭 |
| `MILVUS_PROGRESS_LOG` | `$(PWD)/make-realtime-progress.log` | 日志文件路径 |
| `MILVUS_PROGRESS_DRYRUN_LOG` | `0` | `make -n` 干跑时也写入日志 |
| `MILVUS_PROGRESS_NO_RESET` | 未定义 | 子 `make` 设置此变量避免截断父日志 |

## 2. 三类日志宏

### `log_start` — 记录阶段开始

```makefile
define log_start
    $(MILVUS_PROGRESS_PREFIX)if [ "$(MILVUS_REALTIME_PROGRESS)" = "1" ]; then \
        mkdir -p $$(dirname $(MILVUS_PROGRESS_LOG)) 2>/dev/null || true; \
        { \
            printf '[%s] [START]  %-40s pid=%s ppid=%s%s\n' \
                "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "$(1)" \
                "$$$$" \
                "$$PPID" \
                $(if $(2)," $(2)"); \
        } >> $(MILVUS_PROGRESS_LOG); \
    fi
endef
```

调用方式：`$(call log_start, <目标名>[, 附加消息])`

输出格式示例：

```
[2026-07-13T10:23:45Z] [START]  build-cmake-dependencies        pid=12345 ppid=12344
```

### `log_done` — 记录阶段完成

```makefile
define log_done
    $(MILVUS_PROGRESS_PREFIX)if [ "$(MILVUS_REALTIME_PROGRESS)" = "1" ]; then \
        _rc=$$?; \
        printf '[%s] [DONE]   %-40s rc=%s%s\n' \
            "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$(1)" \
            "$$_rc" \
            $(if $(2)," $(2)") >> $(MILVUS_PROGRESS_LOG); \
    fi
endef
```

调用方式：`$(call log_done, <目标名>[, 附加消息])`

输出格式示例：

```
[2026-07-13T10:25:01Z] [DONE]   build-cmake-dependencies        rc=0
```

关键细节：`$$_rc` 在 recipe **最后一个命令执行后**读取，因此反映的是整个目标的成功与否，而非某一行命令。

### `log_milestone` — 内联里程碑

```makefile
define log_milestone
    @if [ "$(MILVUS_REALTIME_PROGRESS)" = "1" ]; then \
        printf '[%s] [INFO]   %-40s %s\n' \
            "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$(1)" \
            "$(2)" >> $(MILVUS_PROGRESS_LOG); \
    fi
endef
```

用于在目标内部记录"proto 生成完成"、"go build 成功"等关键节点，不依赖 recipe 的退出码。

## 3. 前置logue（日志初始化）

在所有宏之前，有一段只执行一次的截断+ prologue 写入逻辑：

```makefile
ifeq ($(MILVUS_REALTIME_PROGRESS),1)
ifndef MILVUS_PROGRESS_NO_RESET
MILVUS_PROGRESS_PROLOGUE := $(shell \
    mkdir -p $(dir $(MILVUS_PROGRESS_LOG)) 2>/dev/null; \
    { \
        printf '# milvus make progress log\n# started_at=%s pid=%s ppid=%s cwd=%s cmd=%s\n' \
            "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$$$" "$$PPID" \
            "$(CURDIR)" "$$(ps -o args= -p $$PPID 2>/dev/null | head -c 200)"; \
    } > $(MILVUS_PROGRESS_LOG))
endif
endif
```

这一段只在**顶层 make** 解析时执行（子 make 继承 `MILVUS_PROGRESS_NO_RESET=1`），
写入的文件头包含本次构建的起始时间、PID、父 PID、工作目录和调用命令（从父 shell 的 `ps` 输出截取前 200 字符）。

## 4. `make -n`（干跑）兼容

```makefile
ifeq ($(MILVUS_PROGRESS_DRYRUN_LOG),1)
  MILVUS_PROGRESS_PREFIX = +@
else
  MILVUS_PROGRESS_PREFIX = @
endif
```

默认 `make -n` 根本不执行任何 recipe 行，所以 `START`/`DONE` 日志不会写入。
设置 `MILVUS_PROGRESS_DRYRUN_LOG=1` 后，宏改用 `+@` 前缀——`+` 告诉 make
"即使在干跑模式下也执行这一行"，`@` 依然抑制 make 自身的命令回显。
这样可以在不实际构建的情况下预览完整的时间线。

## 5. 使用示例

在任意 recipe 的首尾使用：

```makefile
some-target: deps
    $(call log_start,some-target)
    @echo "building..."
    # 更多命令...
    $(call log_done,some-target)
```

实际构建中 `milvus` 目标（以及其所有子目标）都遵循此模式，
形成一棵完整的时间树：顶层 `milvus:START` → `build-cmake:START` → … → `build-cmake:DONE` → … → `milvus:DONE rc=0`。

## 6. 设计要点

1. **进程归属清晰**：`$$$$`（当前 shell PID）和 `$$PPID`（父 make PID）使得日志能还原完整的调用链，即使 CI 中有多层递归 `make`。
2. **子 make 透明追加**：子 `make` 通过环境变量继承 `MILVUS_PROGRESS_LOG`，但不截断文件（`MILVUS_PROGRESS_NO_RESET`），日志自然交织。
3. **零侵入**：日志系统完全由 `$(call)` 宏驱动，不修改任何 recipe 的实际逻辑，可随时关闭（`MILVUS_REALTIME_PROGRESS=0`）。
4. **退出码溯源**：`log_done` 在整个 recipe 执行完毕后读取 `$$?`，反映的是目标的最终状态，而非中间某一行的结果。

## 7. 小结

这套机制用约 110 行 makefile 代码解决了两个实际问题：

- **构建历史可查**：事后可以从 `make-realtime-progress.log` 还原完整的构建时间线和每个阶段的成败。
- **CI 调试友好**：在 CI 日志缺失或截断的情况下，独立于构建产物的日志文件提供了第二数据源。

核心就三个 `define` 宏加一组环境变量开关，无需任何外部依赖。
