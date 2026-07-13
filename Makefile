# Copyright (C) 2019-2020 Zilliz. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under the License.

GO		  ?= go
PWD 	  := $(shell pwd)
GOPATH	:= $(shell $(GO) env GOPATH)
SHELL 	:= /bin/bash
OBJPREFIX := "github.com/milvus-io/milvus/cmd/milvus"
MILVUS_GO_BUILD_TAGS := "dynamic,sonic,with_jemalloc"

INSTALL_PATH := $(PWD)/bin
LIBRARY_PATH := $(PWD)/lib
PGO_PATH := $(PWD)/configs/pgo
OS := $(shell uname -s)
mode = Release

# ----------------------------------------------------------------------------
# Realtime progress logging.
# Every major target appends START/DONE lines to a single fixed log file in
# the repo root, so a long `make milvus` (or a sub-target) can be inspected
# after the fact even if the terminal scrollback is gone. The file is
# truncated and a self-describing prologue is written once, at make-parse
# time, so every `make` session starts with a clean timeline.
#
# Disable with `make ... MILVUS_REALTIME_PROGRESS=0` (default: 1).
# Override the path with MILVUS_PROGRESS_LOG=/some/file (the directory will
# be created on first write).
# ----------------------------------------------------------------------------
MILVUS_REALTIME_PROGRESS ?= 1
MILVUS_PROGRESS_LOG      ?= $(PWD)/make-realtime-progress.log
MILVUS_PROGRESS_LOG_BASENAME = $(notdir $(MILVUS_PROGRESS_LOG))

# When set to 1, the hooks also write their START/DONE lines during `make -n`
# dry-runs (which otherwise would not execute any recipe). The non-hook
# commands in each recipe are still NOT executed — only the START/DONE
# log lines are emitted, with rc=0 placeholder. Useful for previewing the
# progress log without actually building anything. Default: 0.
MILVUS_PROGRESS_DRYRUN_LOG ?= 0

# Run a tiny `$(shell)` once, at make-parse time, to truncate the log file
# and write a prologue. The makefile may be re-evaluated by recursive
# `$(MAKE)` calls (e.g. `$(MAKE) -C pkg generate-mockery`); in those
# sub-makes we re-use the parent's log file but skip the truncate, so a
# sub-make's progress shows up interleaved with the parent's. To opt out
# of the truncate (e.g. from a sub-make that should preserve the parent's
# log), set MILVUS_PROGRESS_NO_RESET=1 in the sub-make's environment.
#
# This block uses `$$PPID` and `$$` which are evaluated by the *shell that
# runs the $(shell)* — i.e. the shell that invoked `make` (your terminal
# shell, or the parent CI runner shell). That makes the prologue PID the
# the make process's PID and the PPID the shell that started it.
ifeq ($(MILVUS_REALTIME_PROGRESS),1)
ifndef MILVUS_PROGRESS_NO_RESET
# Note: inside $(shell), `$$` is rendered as literal `$` by make; we need
# `$$$$` to make the shell see `$$` (which it then expands to its PID),
# and `$$PPID` to make the shell see `$PPID` (its parent PID).
MILVUS_PROGRESS_PROLOGUE := $(shell \
	mkdir -p $(dir $(MILVUS_PROGRESS_LOG)) 2>/dev/null; \
	{ \
		printf '# milvus make progress log\n# started_at=%s pid=%s ppid=%s cwd=%s cmd=%s\n' \
			"$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$$$" "$$PPID" "$(CURDIR)" "$$(ps -o args= -p $$PPID 2>/dev/null | head -c 200)"; \
	} > $(MILVUS_PROGRESS_LOG))
endif
endif

# Choose the recipe-line prefix for the hooks. Under normal builds we use
# `@` (silent). Under dry-run (`make -n`) recipe lines are not executed at
# all, so the START/DONE entries are skipped — that is the right default,
# but the user can opt into a dry-run preview by setting
# MILVUS_PROGRESS_DRYRUN_LOG=1. In that case we use `+@` so the lines DO
# run under -n (the `+` tells make "execute this even in just/dry-run/touch
# modes"); the `@` still suppresses make's own echoing of the command.
ifeq ($(MILVUS_PROGRESS_DRYRUN_LOG),1)
  MILVUS_PROGRESS_PREFIX = +@
else
  MILVUS_PROGRESS_PREFIX = @
endif

# log_start <target-name> [extra-message] — record phase start.
# Always appends to MILVUS_PROGRESS_LOG. The prologue has already been
# written once at make-parse time, so this is the second line of content.
#
# In dry-run (make -n) the recipe's actual commands are not executed, so
# @-prefixed lines never run. To still get START/DONE entries for a preview
# of the timeline, set MILVUS_PROGRESS_DRYRUN_LOG=1; the hook then writes
# its lines even under -n. The rc= on the DONE line is a placeholder (0)
# under dry-run because no real command was executed.
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

# log_done <target-name> [extra-message] — record phase completion.
# Records the *current shell* exit code (the rc of the most recent command
# in the recipe). Use as the last line of a recipe so $$? reflects the
# whole target. Extra args become a tail comment.
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

# log_milestone <target-name> <message> — emit an in-target milestone line
# (e.g. "proto generation finished", "go build successful"). Use sparingly.
define log_milestone
	@if [ "$(MILVUS_REALTIME_PROGRESS)" = "1" ]; then \
		printf '[%s] [INFO]   %-40s %s\n' \
			"$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$(1)" \
			"$(2)" >> $(MILVUS_PROGRESS_LOG); \
	fi
endef

# Set disk_index default based on OS
# macOS (Darwin) does not support aio, so disable disk_index
ifeq ($(OS),Darwin)
    use_disk_index = OFF
else
    use_disk_index = ON
endif

# Allow manual override via disk_index variable
ifdef disk_index
    use_disk_index = ${disk_index}
endif

use_asan = OFF
ifeq ($(USE_ASAN), ON)
	use_asan = ${USE_ASAN}
	CGO_LDFLAGS += -fno-stack-protector -fno-omit-frame-pointer -fno-var-tracking -fsanitize=address
	CGO_CFLAGS += -fno-stack-protector -fno-omit-frame-pointer -fno-var-tracking -fsanitize=address
	MILVUS_GO_BUILD_TAGS := $(MILVUS_GO_BUILD_TAGS),use_asan
endif

use_dynamic_simd = ON
ifdef USE_DYNAMIC_SIMD
	use_dynamic_simd = ${USE_DYNAMIC_SIMD}
endif

tantivy_features = ""
ifdef TANTIVY_FEATURES
	tantivy_features = ${TANTIVY_FEATURES}
endif

use_opendal = OFF
ifdef USE_OPENDAL
	use_opendal = ${USE_OPENDAL}
endif

use_svs = OFF
ifdef USE_SVS
	use_svs = ${USE_SVS}
endif

# FIPS: default OFF. Set MILVUS_FIPS_ENABLED=ON to enable BoringCrypto.
GOEXPERIMENT_FLAG :=
ifeq ($(MILVUS_FIPS_ENABLED),ON)
	GOEXPERIMENT_FLAG := GOEXPERIMENT=boringcrypto
endif
# golangci-lint
GOLANGCI_LINT_VERSION := 2.11.3
GOLANGCI_LINT_OUTPUT := $(shell $(INSTALL_PATH)/golangci-lint --version 2>/dev/null)
INSTALL_GOLANGCI_LINT := $(findstring $(GOLANGCI_LINT_VERSION), $(GOLANGCI_LINT_OUTPUT))
# mockery
MOCKERY_VERSION := 2.53.3
MOCKERY_OUTPUT := $(shell $(INSTALL_PATH)/mockery --version 2>/dev/null)
INSTALL_MOCKERY := $(findstring $(MOCKERY_VERSION),$(MOCKERY_OUTPUT))
# gci
GCI_VERSION := 0.11.2
GCI_OUTPUT := $(shell $(INSTALL_PATH)/gci --version 2>/dev/null)
INSTALL_GCI := $(findstring $(GCI_VERSION),$(GCI_OUTPUT))
# gofumpt
GOFUMPT_VERSION := 0.5.0
GOFUMPT_OUTPUT := $(shell $(INSTALL_PATH)/gofumpt --version 2>/dev/null)
INSTALL_GOFUMPT := $(findstring $(GOFUMPT_VERSION),$(GOFUMPT_OUTPUT))
# gotestsum
GOTESTSUM_VERSION := 1.13.0
GOTESTSUM_OUTPUT := $(shell $(INSTALL_PATH)/gotestsum --version 2>/dev/null)
INSTALL_GOTESTSUM := $(findstring $(GOTESTSUM_VERSION),$(GOTESTSUM_OUTPUT))
# protoc-gen-go
PROTOC_GEN_GO_VERSION := 1.33.0
PROTOC_GEN_GO_OUTPUT := $(shell echo | $(INSTALL_PATH)/protoc-gen-go --version 2>/dev/null)
INSTALL_PROTOC_GEN_GO := $(findstring $(PROTOC_GEN_GO_VERSION),$(PROTOC_GEN_GO_OUTPUT))
# protoc-gen-go-grpc
PROTOC_GEN_GO_GRPC_VERSION := 1.3.0
PROTOC_GEN_GO_GRPC_OUTPUT := $(shell echo | $(INSTALL_PATH)/protoc-gen-go-grpc  --version 2>/dev/null)
INSTALL_PROTOC_GEN_GO_GRPC := $(findstring $(PROTOC_GEN_GO_GRPC_VERSION),$(PROTOC_GEN_GO_GRPC_OUTPUT))

index_engine = knowhere

# Ensure git works inside containers where .git is owned by a different user.
# Must use git config --global because git's ownership check runs before
# both -c options and GIT_CONFIG_COUNT env vars are processed.
$(shell git config --global --add safe.directory '*' 2>/dev/null)

export GIT_BRANCH=$(shell git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -v '^HEAD$$' || echo "$${GITHUB_REF_NAME:-$${BRANCH_NAME:-unknown}}")
GIT_BRANCH_SAFE=$(shell echo "$(GIT_BRANCH)" | tr '/' '-')

ifeq (${ENABLE_AZURE}, false)
	AZURE_OPTION := -Z
endif

milvus: build-cpp print-build-info build-go
	@echo "milvus target finished; see $(MILVUS_PROGRESS_LOG_BASENAME) for full timeline."

build-go:
	$(call log_start,build-go)
	@echo "Building Milvus ..."
	@source $(PWD)/scripts/setenv.sh && \
		mkdir -p $(INSTALL_PATH) && go env -w CGO_ENABLED="1" && \
		$(GOEXPERIMENT_FLAG) CGO_LDFLAGS="$(CGO_LDFLAGS)" CGO_CFLAGS="$(CGO_CFLAGS)" GO111MODULE=on $(GO) build -pgo=$(PGO_PATH)/default.pgo -ldflags="-r $${RPATH} -X '$(OBJPREFIX).BuildTags=$(BUILD_TAGS)' -X '$(OBJPREFIX).BuildTime=$(BUILD_TIME)' -X '$(OBJPREFIX).GitCommit=$(GIT_COMMIT)' -X '$(OBJPREFIX).GoVersion=$(GO_VERSION)' -X '$(OBJPREFIX).MilvusVersion=$(MILVUS_VERSION)'" \
		-tags $(MILVUS_GO_BUILD_TAGS) -o $(INSTALL_PATH)/milvus $(PWD)/cmd/main.go 1>/dev/null
	$(call log_done,build-go)

milvus-gpu: build-cpp-gpu print-gpu-build-info
	$(call log_start,milvus-gpu)
	@echo "Building Milvus-gpu ..."
	@source $(PWD)/scripts/setenv.sh && \
		mkdir -p $(INSTALL_PATH) && go env -w CGO_ENABLED="1" && \
		CGO_LDFLAGS="$(CGO_LDFLAGS)" CGO_CFLAGS="$(CGO_CFLAGS)" GO111MODULE=on $(GO) build -pgo=$(PGO_PATH)/default.pgo -ldflags="-r $${RPATH} -X '$(OBJPREFIX).BuildTags=$(BUILD_TAGS_GPU)' -X '$(OBJPREFIX).BuildTime=$(BUILD_TIME)' -X '$(OBJPREFIX).GitCommit=$(GIT_COMMIT)' -X '$(OBJPREFIX).GoVersion=$(GO_VERSION)' -X '$(OBJPREFIX).MilvusVersion=$(MILVUS_VERSION)'" \
		-tags "$(MILVUS_GO_BUILD_TAGS),cuda" -o $(INSTALL_PATH)/milvus $(PWD)/cmd/main.go 1>/dev/null
	$(call log_done,milvus-gpu)

get-build-deps:
	$(call log_start,get-build-deps)
	@(env bash $(PWD)/scripts/install_deps.sh)
	$(call log_done,get-build-deps)

# attention: upgrade golangci-lint should also change Dockerfiles in build/docker/builder/cpu/<os>
getdeps:
	$(call log_start,getdeps)
	@mkdir -p $(INSTALL_PATH)
	@if [ -z "$(INSTALL_GOLANGCI_LINT)" ]; then \
		echo "Installing golangci-lint into ./bin/" && curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(INSTALL_PATH) v${GOLANGCI_LINT_VERSION} ; \
	else \
		echo "golangci-lint v@$(GOLANGCI_LINT_VERSION) already installed"; \
	fi
	@if [ -z "$(INSTALL_MOCKERY)" ]; then \
		echo "Installing mockery v$(MOCKERY_VERSION) to ./bin/" && GOBIN=$(INSTALL_PATH) go install github.com/vektra/mockery/v2@v$(MOCKERY_VERSION); \
	else \
		echo "Mockery v$(MOCKERY_VERSION) already installed"; \
	fi
	@if [ -z "$(INSTALL_GOTESTSUM)" ]; then \
		echo "Install gotestsum v$(GOTESTSUM_VERSION) to ./bin/" && GOBIN=$(INSTALL_PATH) go install -ldflags="-X 'gotest.tools/gotestsum/cmd.version=$(GOTESTSUM_VERSION)'" gotest.tools/gotestsum@v$(GOTESTSUM_VERSION); \
	else \
		echo "gotestsum v$(GOTESTSUM_VERSION) already installed";\
	fi
	$(call log_done,getdeps)

get-proto-deps:
	$(call log_start,get-proto-deps)
	@mkdir -p $(INSTALL_PATH) # make sure directory exists
	@if [ -z "$(INSTALL_PROTOC_GEN_GO)" ]; then \
		echo "install protoc-gen-go $(PROTOC_GEN_GO_VERSION) to $(INSTALL_PATH)" && GOBIN=$(INSTALL_PATH) go install google.golang.org/protobuf/cmd/protoc-gen-go@v$(PROTOC_GEN_GO_VERSION); \
	else \
		echo "protoc-gen-go@v$(PROTOC_GEN_GO_VERSION) already installed";\
	fi
	@if [ -z "$(INSTALL_PROTOC_GEN_GO_GRPC)" ]; then \
		echo "install protoc-gen-go-grpc $(PROTOC_GEN_GO_GRPC_VERSION) to $(INSTALL_PATH)" && GOBIN=$(INSTALL_PATH) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v$(PROTOC_GEN_GO_GRPC_VERSION); \
	else \
		echo "protoc-gen-go-grpc@v$(PROTOC_GEN_GO_GRPC_VERSION) already installed";\
	fi
	$(call log_done,get-proto-deps)

tools/bin/revive: tools/check/go.mod
	cd tools/check; \
	$(GO) build -pgo=$(PGO_PATH)/default.pgo -o ../bin/revive github.com/mgechev/revive

cppcheck:
	$(call log_start,cppcheck)
	@#(env bash ${PWD}/scripts/core_build.sh -l)
	@(env bash ${PWD}/scripts/check_cpp_fmt.sh)
	$(call log_done,cppcheck)

rustfmt:
	$(call log_start,rustfmt)
	@echo  "Running cargo format"
	@env bash ${PWD}/scripts/run_cargo_format.sh ${PWD}/internal/core/thirdparty/tantivy/tantivy-binding/
	$(call log_done,rustfmt)

rustcheck:
	$(call log_start,rustcheck)
	@echo  "Running cargo check"
	@env bash ${PWD}/scripts/run_cargo_format.sh ${PWD}/internal/core/thirdparty/tantivy/tantivy-binding/ --check
	$(call log_done,rustcheck)

fmt:
	$(call log_start,fmt)
ifdef GO_DIFF_FILES
	@echo "Running $@ check"
	@GO111MODULE=on env bash $(PWD)/scripts/gofmt.sh $(GO_DIFF_FILES)
else
	@echo "Running $@ check"
	@GO111MODULE=on env bash $(PWD)/scripts/gofmt.sh cmd/
	@GO111MODULE=on env bash $(PWD)/scripts/gofmt.sh internal/
	@GO111MODULE=on env bash $(PWD)/scripts/gofmt.sh tests/integration/
	@GO111MODULE=on env bash $(PWD)/scripts/gofmt.sh tests/go/
	@GO111MODULE=on env bash $(PWD)/scripts/gofmt.sh pkg/
endif
	$(call log_done,fmt)

lint-fix: getdeps
	$(call log_start,lint-fix)
	@mkdir -p $(INSTALL_PATH)
	@if [ -z "$(INSTALL_GCI)" ]; then \
		echo "Installing gci v$(GCI_VERSION) to ./bin/" && GOBIN=$(INSTALL_PATH) go install github.com/daixiang0/gci@v$(GCI_VERSION); \
	else \
		echo "gci v$(GCI_VERSION) already installed"; \
	fi
	@if [ -z "$(INSTALL_GOFUMPT)" ]; then \
		echo "Installing gofumpt v$(GOFUMPT_VERSION) to ./bin/" && GOBIN=$(INSTALL_PATH) go install mvdan.cc/gofumpt@v$(GOFUMPT_VERSION); \
	else \
		echo "gofumpt v$(GOFUMPT_VERSION) already installed"; \
	fi
	@echo "Running gofumpt fix"
	@$(INSTALL_PATH)/gofumpt -l -w internal/
	@$(INSTALL_PATH)/gofumpt -l -w cmd/
	@$(INSTALL_PATH)/gofumpt -l -w pkg/
	@$(INSTALL_PATH)/gofumpt -l -w client/
	@$(INSTALL_PATH)/gofumpt -l -w tests/go_client/
	@$(INSTALL_PATH)/gofumpt -l -w tests/integration/
	@echo "Running gci fix"
# Skip boring_enabled.go: gci misclassifies crypto/boring (a std lib package) as third-party, conflicting with gofumpt
	@find cmd/ -name '*.go' ! -name 'boring_enabled.go' | xargs $(INSTALL_PATH)/gci write --skip-generated -s standard -s default -s "prefix(github.com/milvus-io)" --custom-order
	@$(INSTALL_PATH)/gci write internal/ --skip-generated -s standard -s default -s "prefix(github.com/milvus-io)" --custom-order
	@$(INSTALL_PATH)/gci write pkg/ --skip-generated -s standard -s default -s "prefix(github.com/milvus-io)" --custom-order
	@$(INSTALL_PATH)/gci write client/ --skip-generated -s standard -s default -s "prefix(github.com/milvus-io)" --custom-order
	@$(INSTALL_PATH)/gci write tests/ --skip-generated -s standard -s default -s "prefix(github.com/milvus-io)" --custom-order
	@echo "Running golangci-lint auto-fix"
	@source $(PWD)/scripts/setenv.sh && GO111MODULE=on $(INSTALL_PATH)/golangci-lint run --fix --timeout=30m --config $(PWD)/.golangci.yml;
	@source $(PWD)/scripts/setenv.sh && cd pkg && GO111MODULE=on $(INSTALL_PATH)/golangci-lint run --fix --timeout=30m --config $(PWD)/.golangci.yml
	@source $(PWD)/scripts/setenv.sh && cd client && GO111MODULE=on $(INSTALL_PATH)/golangci-lint run --fix --timeout=30m --config $(PWD)/client/.golangci.yml
	$(call log_done,lint-fix)

#TODO: Check code specifications by golangci-lint
static-check: getdeps
	$(call log_start,static-check)
	@echo "Running $@ check"
	@echo "Start check core packages"
	@source $(PWD)/scripts/setenv.sh && GO111MODULE=on GOFLAGS=-buildvcs=false $(INSTALL_PATH)/golangci-lint run --build-tags dynamic,test --timeout=30m --config $(PWD)/.golangci.yml
	@echo "Start check pkg package"
	@source $(PWD)/scripts/setenv.sh && cd pkg && GO111MODULE=on GOFLAGS=-buildvcs=false $(INSTALL_PATH)/golangci-lint run --build-tags dynamic,test --timeout=30m --config $(PWD)/.golangci.yml
	@echo "Start check client package"
	@source $(PWD)/scripts/setenv.sh && cd client && GO111MODULE=on GOFLAGS=-buildvcs=false $(INSTALL_PATH)/golangci-lint run --timeout=30m --config $(PWD)/client/.golangci.yml
	@echo "Start check go_client e2e package"
	@source $(PWD)/scripts/setenv.sh && cd tests/go_client && GO111MODULE=on GOFLAGS=-buildvcs=false $(INSTALL_PATH)/golangci-lint run --build-tags L0,L1,L2,test --timeout=30m --config $(PWD)/tests/go_client/.golangci.yml
	$(call log_done,static-check)

verifiers: build-cpp getdeps cppcheck rustcheck fmt static-check

# Build various components locally.
binlog:
	$(call log_start,binlog)
	@echo "Building binlog ..."
	@source $(PWD)/scripts/setenv.sh && \
		mkdir -p $(INSTALL_PATH) && go env -w CGO_ENABLED="1" && \
		GO111MODULE=on $(GO) build -pgo=$(PGO_PATH)/default.pgo -ldflags="-r $${RPATH}" -o $(INSTALL_PATH)/binlog $(PWD)/cmd/tools/binlog/main.go 1>/dev/null
	$(call log_done,binlog)

MIGRATION_PATH = $(PWD)/cmd/tools/migration
meta-migration:
	$(call log_start,meta-migration)
	@echo "Building migration tool ..."
	@source $(PWD)/scripts/setenv.sh && \
    		mkdir -p $(INSTALL_PATH) && go env -w CGO_ENABLED="1" && \
    		GO111MODULE=on $(GO) build -pgo=$(PGO_PATH)/default.pgo -ldflags="-r $${RPATH} -X '$(OBJPREFIX).BuildTags=$(BUILD_TAGS)' -X '$(OBJPREFIX).BuildTime=$(BUILD_TIME)' -X '$(OBJPREFIX).GitCommit=$(GIT_COMMIT)' -X '$(OBJPREFIX).GoVersion=$(GO_VERSION)' -X '$(OBJPREFIX).MilvusVersion=$(MILVUS_VERSION)'" \
    		-tags dynamic -o $(INSTALL_PATH)/meta-migration $(MIGRATION_PATH)/main.go 1>/dev/null
	$(call log_done,meta-migration)

INTERATION_PATH = $(PWD)/tests/integration
integration-test: getdeps
	$(call log_start,integration-test)
	@echo "Building integration tests ..."
	@(env bash $(PWD)/scripts/run_intergration_test.sh "$(INSTALL_PATH)/gotestsum --")
	$(call log_done,integration-test)

BUILD_TAGS = $(shell git describe --tags --always --dirty="-dev")
BUILD_TAGS_GPU = ${BUILD_TAGS}-gpu
BUILD_TIME = $(shell date -u)
GIT_COMMIT = $(shell git rev-parse --short HEAD)
GO_VERSION = $(shell go version)
BUILD_DATE = $(shell date -u +%Y%m%d)
MILVUS_VERSION := $(shell tag=$$(git describe --exact-match --tags --match 'v*' 2>/dev/null) && echo "$$tag" | sed 's/^v//' || echo "$(GIT_BRANCH_SAFE)-$(BUILD_DATE)-$(GIT_COMMIT)")

print-build-info:
	@echo "Build Tag: $(BUILD_TAGS)"
	@echo "Build Time: $(BUILD_TIME)"
	@echo "Git Commit: $(GIT_COMMIT)"
	@echo "Go Version: $(GO_VERSION)"

print-gpu-build-info:
	@echo "Build Tag: $(BUILD_TAGS_GPU)"
	@echo "Build Time: $(BUILD_TIME)"
	@echo "Git Commit: $(GIT_COMMIT)"
	@echo "Go Version: $(GO_VERSION)"

update-milvus-api: download-milvus-proto
	$(call log_start,update-milvus-api)
	@echo "Update milvus/api version ..."
	@(env bash $(PWD)/scripts/update-api-version.sh $(PROTO_API_VERSION))
	$(call log_done,update-milvus-api)

download-milvus-proto:
	$(call log_start,download-milvus-proto)
	@echo "Download milvus-proto repo ..."
	@(env bash $(PWD)/scripts/download_milvus_proto.sh)
	$(call log_done,download-milvus-proto)

build-3rdparty:
	$(call log_start,build-3rdparty)
	@echo "Build 3rdparty ..."
	@(env bash $(PWD)/scripts/3rdparty_build.sh -o ${use_opendal} -t ${mode})
	$(call log_done,build-3rdparty)

generated-proto-without-cpp: download-milvus-proto get-proto-deps
	$(call log_start,generated-proto-without-cpp)
	@echo "Generate proto ..."
	@(env bash $(PWD)/scripts/generate_proto.sh ${INSTALL_PATH})
	$(call log_done,generated-proto-without-cpp)

generated-proto: download-milvus-proto build-3rdparty get-proto-deps
	$(call log_start,generated-proto)
	@echo "Generate proto ..."
	@(env bash $(PWD)/scripts/generate_proto.sh ${INSTALL_PATH})
	$(call log_done,generated-proto)

build-cpp: generated-proto plan-parser-lib
	$(call log_start,build-cpp)
	@echo "Building Milvus cpp library ..."
	@(env bash $(PWD)/scripts/core_build.sh -t ${mode} -a ${use_asan} -n ${use_disk_index} -y ${use_dynamic_simd} ${AZURE_OPTION} -x ${index_engine} -o ${use_opendal} -f $(tantivy_features) -S ${use_svs})
	$(call log_done,build-cpp)

build-cpp-gpu: generated-proto plan-parser-lib
	$(call log_start,build-cpp-gpu)
	@echo "Building Milvus cpp gpu library ... "
	@(env bash $(PWD)/scripts/core_build.sh -t ${mode} -g -n ${use_disk_index} -y ${use_dynamic_simd} ${AZURE_OPTION} -x ${index_engine} -o ${use_opendal} -f $(tantivy_features) -S ${use_svs})
	$(call log_done,build-cpp-gpu)

build-cpp-with-unittest: generated-proto plan-parser-lib
	$(call log_start,build-cpp-with-unittest)
	@echo "Building Milvus cpp library with unittest ... "
	@(env bash $(PWD)/scripts/core_build.sh -t ${mode} -a ${use_asan} -u -n ${use_disk_index} -y ${use_dynamic_simd} ${AZURE_OPTION} -x ${index_engine} -o ${use_opendal} -f $(tantivy_features) -S ${use_svs})
	$(call log_done,build-cpp-with-unittest)

build-cpp-with-coverage: generated-proto plan-parser-lib
	$(call log_start,build-cpp-with-coverage)
	@echo "Building Milvus cpp library with coverage and unittest ..."
	@(env bash $(PWD)/scripts/core_build.sh -t ${mode} -a ${use_asan} -u -c -n ${use_disk_index} -y ${use_dynamic_simd} ${AZURE_OPTION} -x ${index_engine} -o ${use_opendal} -f $(tantivy_features) -S ${use_svs})
	$(call log_done,build-cpp-with-coverage)

check-proto-product: generated-proto
	$(call log_start,check-proto-product)
	 @(env bash $(PWD)/scripts/check_proto_product.sh)
	$(call log_done,check-proto-product)

generate-message-codegen:
	$(call log_start,generate-message-codegen)
	@if [ -z "$(INSTALL_GOFUMPT)" ]; then \
		echo "Installing gofumpt v$(GOFUMPT_VERSION) to ./bin/" && GOBIN=$(INSTALL_PATH) go install mvdan.cc/gofumpt@v$(GOFUMPT_VERSION); \
	else \
		echo "gofumpt v$(GOFUMPT_VERSION) already installed"; \
	fi
	@echo "Generating message codegen ..."
	@(cd pkg/streaming/util/message/codegen && PATH=$(INSTALL_PATH):$(PATH) go generate .)
	$(call log_done,generate-message-codegen)

# Run the tests.
unittest: test-cpp test-go

test-util:
	$(call log_start,test-util)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t util)
	$(call log_done,test-util)

test-storage:
	$(call log_start,test-storage)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t storage)
	$(call log_done,test-storage)

test-allocator:
	$(call log_start,test-allocator)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t allocator)
	$(call log_done,test-allocator)

test-config:
	$(call log_start,test-config)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t config)
	$(call log_done,test-config)

test-tso:
	$(call log_start,test-tso)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t tso)
	$(call log_done,test-tso)

test-pkg:
	$(call log_start,test-pkg)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t pkg)
	$(call log_done,test-pkg)

test-kv:
	$(call log_start,test-kv)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t kv)
	$(call log_done,test-kv)

test-mq:
	$(call log_start,test-mq)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t mq)
	$(call log_done,test-mq)

test-rootcoord:
	$(call log_start,test-rootcoord)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t rootcoord)
	$(call log_done,test-rootcoord)

test-indexcoord:
	$(call log_start,test-indexcoord)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t indexcoord)
	$(call log_done,test-indexcoord)

test-proxy:
	$(call log_start,test-proxy)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t proxy)
	$(call log_done,test-proxy)

test-datacoord:
	$(call log_start,test-datacoord)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t datacoord)
	$(call log_done,test-datacoord)

test-datanode:
	$(call log_start,test-datanode)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t datanode)
	$(call log_done,test-datanode)

test-querynode:
	$(call log_start,test-querynode)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t querynode)
	$(call log_done,test-querynode)

test-querycoord:
	$(call log_start,test-querycoord)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t querycoord)
	$(call log_done,test-querycoord)

test-metastore:
	$(call log_start,test-metastore)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t metastore)
	$(call log_done,test-metastore)

test-streaming:
	$(call log_start,test-streaming)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t streaming)
	$(call log_done,test-streaming)

test-mixcoord:
	$(call log_start,test-mixcoord)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t mixcoord)
	$(call log_done,test-mixcoord)

test-cdc:
	$(call log_start,test-cdc)
	@echo "Running cdc unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh -t cdc)
	$(call log_done,test-cdc)

test-go: build-cpp-with-unittest
	$(call log_start,test-go)
	@echo "Running go unittests..."
	@(env bash $(PWD)/scripts/run_go_unittest.sh)
	$(call log_done,test-go)

test-cpp: build-cpp-with-unittest
	$(call log_start,test-cpp)
	@echo "Running cpp unittests..."
	@(env bash $(PWD)/scripts/run_cpp_unittest.sh)
	$(call log_done,test-cpp)

run-test-cpp:
	$(call log_start,run-test-cpp)
	@echo "Running cpp unittests..."
	@echo $(PWD)/scripts/run_cpp_unittest.sh arg=${filter}
	@(env bash $(PWD)/scripts/run_cpp_unittest.sh arg=${filter})
	$(call log_done,run-test-cpp)

plan-parser-lib:
	$(call log_start,plan-parser-lib)
	@(env bash $(PWD)/scripts/build_plan_parser.sh)
	$(call log_done,plan-parser-lib)

# Run code coverage.
codecov: codecov-go codecov-cpp

# Run codecov-go
codecov-go: build-cpp-with-coverage
	$(call log_start,codecov-go)
	@echo "Running go coverage..."
	@(env bash $(PWD)/scripts/run_go_codecov.sh)
	$(call log_done,codecov-go)

# Run codecov-go without build core again, used in github action
codecov-go-without-build: getdeps
	$(call log_start,codecov-go-without-build)
	@echo "Running go coverage..."
	@(env bash $(PWD)/scripts/run_go_codecov.sh "$(INSTALL_PATH)/gotestsum --")
	$(call log_done,codecov-go-without-build)

# Run codecov-cpp
codecov-cpp: build-cpp-with-coverage
	$(call log_start,codecov-cpp)
	@echo "Running cpp coverage..."
	@(env bash $(PWD)/scripts/run_cpp_codecov.sh)
	$(call log_done,codecov-cpp)

# Build each component and install binary to $GOPATH/bin.
install: milvus
	$(call log_start,install)
	@echo "Installing binary to './bin'"
	@(env GOPATH=$(GOPATH) LIBRARY_PATH=$(LIBRARY_PATH) bash $(PWD)/scripts/install_milvus.sh)
	@echo "Installation successful."
	$(call log_done,install)

gpu-install: milvus-gpu
	$(call log_start,gpu-install)
	@echo "Installing binary to './bin'"
	@(env GOPATH=$(GOPATH) LIBRARY_PATH=$(LIBRARY_PATH) bash $(PWD)/scripts/install_milvus.sh)
	@echo "Installation successful."
	$(call log_done,gpu-install)

clean:
	$(call log_start,clean)
	@echo "Cleaning up all the generated files"
	@rm -rf bin/
	@rm -rf lib/
	@rm -rf $(GOPATH)/bin/milvus
	@rm -rf cmake_build
	@rm -rf internal/core/output
	$(call log_done,clean)

milvus-tools: print-build-info
	$(call log_start,milvus-tools)
	@echo "Building tools ..."
	@. $(PWD)/scripts/setenv.sh && mkdir -p $(INSTALL_PATH)/tools && go env -w CGO_ENABLED="1" && GO111MODULE=on $(GO) build \
		-pgo=$(PGO_PATH)/default.pgo -ldflags="-X 'main.BuildTags=$(BUILD_TAGS)' -X 'main.BuildTime=$(BUILD_TIME)' -X 'main.GitCommit=$(GIT_COMMIT)' -X 'main.GoVersion=$(GO_VERSION)'" \
		-o $(INSTALL_PATH)/tools $(PWD)/cmd/tools/binlog $(PWD)/cmd/tools/config $(PWD)/cmd/tools/datameta $(PWD)/cmd/tools/config-docs-generator $(PWD)/cmd/tools/migration 1>/dev/null
	$(call log_done,milvus-tools)

rpm-setup:
	$(call log_start,rpm-setup)
	@echo "Setuping rpm env ...;"
	@build/rpm/setup-env.sh
	$(call log_done,rpm-setup)

rpm: install
	$(call log_start,rpm)
	@echo "Note: run 'make rpm-setup' to setup build env for rpm builder"
	@echo "Building rpm ...;"
	@yum -y install rpm-build rpmdevtools wget
	@rm -rf ~/rpmbuild/BUILD/*
	@rpmdev-setuptree
	@wget https://github.com/etcd-io/etcd/releases/download/v3.5.0/etcd-v3.5.0-linux-amd64.tar.gz && tar -xf etcd-v3.5.0-linux-amd64.tar.gz
	@cp etcd-v3.5.0-linux-amd64/etcd bin/etcd
	@wget https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.2021-02-14T04-01-33Z -O bin/minio
	@cp -r bin ~/rpmbuild/BUILD/
	@cp -r lib ~/rpmbuild/BUILD/
	@cp -r configs ~/rpmbuild/BUILD/
	@cp -r build/rpm/services ~/rpmbuild/BUILD/
	@QA_RPATHS="$$[ 0x001|0x0002|0x0020 ]" rpmbuild -ba ./build/rpm/milvus.spec
	$(call log_done,rpm)

generate-mockery-types: getdeps
	$(call log_start,generate-mockery-types)
	# MixCoord
	$(INSTALL_PATH)/mockery --name=MixCoordComponent --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_mixcoord.go --with-expecter --structname=MixCoord
	# Proxy
	$(INSTALL_PATH)/mockery --name=ProxyComponent --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_proxy.go --with-expecter --structname=MockProxy
	# QueryNode
	$(INSTALL_PATH)/mockery --name=QueryNodeComponent --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_querynode.go --with-expecter --structname=MockQueryNode
	# DataNode
	$(INSTALL_PATH)/mockery --name=DataNodeComponent --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_datanode.go --with-expecter --structname=MockDataNode
	# RootCoord
	$(INSTALL_PATH)/mockery --name=RootCoordComponent --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_rootcoord.go --with-expecter --structname=MockRootCoord
	# QueryCoord
	$(INSTALL_PATH)/mockery --name=QueryCoordComponent --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_querycoord.go --with-expecter --structname=MockQueryCoord
	# DataCoord
	$(INSTALL_PATH)/mockery --name=DataCoordComponent --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_datacoord.go --with-expecter --structname=MockDataCoord

	# Clients
	$(INSTALL_PATH)/mockery --name=MixCoordClient --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_mixcoord_client.go --with-expecter --structname=MockMixCoordClient
	$(INSTALL_PATH)/mockery --name=RootCoordClient --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_rootcoord_client.go --with-expecter --structname=MockRootCoordClient
	$(INSTALL_PATH)/mockery --name=QueryCoordClient --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_querycoord_client.go --with-expecter --structname=MockQueryCoordClient
	$(INSTALL_PATH)/mockery --name=DataCoordClient --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_datacoord_client.go --with-expecter --structname=MockDataCoordClient
	$(INSTALL_PATH)/mockery --name=QueryNodeClient --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_querynode_client.go --with-expecter --structname=MockQueryNodeClient
	$(INSTALL_PATH)/mockery --name=DataNodeClient --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_datanode_client.go --with-expecter --structname=MockDataNodeClient
	$(INSTALL_PATH)/mockery --name=ProxyClient --dir=$(PWD)/internal/types --output=$(PWD)/internal/mocks --filename=mock_proxy_client.go --with-expecter --structname=MockProxyClient
	$(call log_done,generate-mockery-types)

generate-mockery-rootcoord: getdeps
	$(call log_start,generate-mockery-rootcoord)
	$(INSTALL_PATH)/mockery --name=IMetaTable --dir=$(PWD)/internal/rootcoord --output=$(PWD)/internal/rootcoord/mocks --filename=meta_table.go --with-expecter --outpkg=mockrootcoord
	$(INSTALL_PATH)/mockery --name=FileResourceObserver --dir=$(PWD)/internal/rootcoord --output=$(PWD)/internal/rootcoord --filename=mock_file_resource_observer.go --with-expecter --structname=MockFileResourceObserver  --inpackage
	$(call log_done,generate-mockery-rootcoord)


generate-mockery-proxy: getdeps
	$(call log_start,generate-mockery-proxy)
	$(INSTALL_PATH)/mockery --config $(PWD)/internal/proxy/.mockery.yaml
	$(call log_done,generate-mockery-proxy)

generate-mockery-querycoord: getdeps
	$(call log_start,generate-mockery-querycoord)
	$(INSTALL_PATH)/mockery --config $(PWD)/internal/querycoordv2/.mockery.yaml
	$(call log_done,generate-mockery-querycoord)

generate-mockery-querynode-without-cpp:
	$(call log_start,generate-mockery-querynode-without-cpp)
	@source $(PWD)/scripts/setenv.sh && \
	$(INSTALL_PATH)/mockery --config $(PWD)/internal/querynodev2/.mockery.yaml
	$(call log_done,generate-mockery-querynode-without-cpp)

generate-mockery-querynode: build-cpp generate-mockery-querynode-without-cpp

generate-mockery-datacoord: getdeps
	$(call log_start,generate-mockery-datacoord)
	$(INSTALL_PATH)/mockery --config $(PWD)/internal/datacoord/.mockery.yaml
	$(call log_done,generate-mockery-datacoord)

generate-mockery-datanode: getdeps
	$(call log_start,generate-mockery-datanode)
	$(INSTALL_PATH)/mockery --config $(PWD)/internal/datanode/.mockery.yaml
	$(call log_done,generate-mockery-datanode)

generate-mockery-flushcommon: getdeps
	$(call log_start,generate-mockery-flushcommon)
	$(INSTALL_PATH)/mockery --name=Broker --dir=$(PWD)/internal/flushcommon/broker --output=$(PWD)/internal/flushcommon/broker/ --filename=mock_broker.go --with-expecter --structname=MockBroker --outpkg=broker --inpackage
	$(INSTALL_PATH)/mockery --name=MetaCache --dir=$(PWD)/internal/flushcommon/metacache --output=$(PWD)/internal/flushcommon/metacache --filename=mock_meta_cache.go --with-expecter --structname=MockMetaCache --outpkg=metacache --inpackage
	$(INSTALL_PATH)/mockery --name=SyncManager --dir=$(PWD)/internal/flushcommon/syncmgr --output=$(PWD)/internal/flushcommon/syncmgr --filename=mock_sync_manager.go --with-expecter --structname=MockSyncManager --outpkg=syncmgr --inpackage
	$(INSTALL_PATH)/mockery --name=MetaWriter --dir=$(PWD)/internal/flushcommon/syncmgr --output=$(PWD)/internal/flushcommon/syncmgr --filename=mock_meta_writer.go --with-expecter --structname=MockMetaWriter --outpkg=syncmgr --inpackage
	$(INSTALL_PATH)/mockery --name=PackWriter --dir=$(PWD)/internal/flushcommon/syncmgr --output=$(PWD)/internal/flushcommon/syncmgr --filename=mock_pack_writer.go --with-expecter --structname=MockPackWriter --outpkg=syncmgr --inpackage
	$(INSTALL_PATH)/mockery --name=Task --dir=$(PWD)/internal/flushcommon/syncmgr --output=$(PWD)/internal/flushcommon/syncmgr --filename=mock_task.go --with-expecter --structname=MockTask --outpkg=syncmgr --inpackage
	$(INSTALL_PATH)/mockery --name=WriteBuffer --dir=$(PWD)/internal/flushcommon/writebuffer --output=$(PWD)/internal/flushcommon/writebuffer --filename=mock_write_buffer.go --with-expecter --structname=MockWriteBuffer --outpkg=writebuffer --inpackage
	$(INSTALL_PATH)/mockery --name=BufferManager --dir=$(PWD)/internal/flushcommon/writebuffer --output=$(PWD)/internal/flushcommon/writebuffer --filename=mock_manager.go --with-expecter --structname=MockBufferManager --outpkg=writebuffer --inpackage
	$(INSTALL_PATH)/mockery --name=BinlogIO --dir=$(PWD)/internal/flushcommon/io --output=$(PWD)/internal/mocks/flushcommon/mock_util --filename=mock_binlogio.go --with-expecter --structname=MockBinlogIO --outpkg=mock_util --inpackage=false
	$(INSTALL_PATH)/mockery --name=MsgHandler --dir=$(PWD)/internal/flushcommon/util --output=$(PWD)/internal/mocks/flushcommon/mock_util --filename=mock_MsgHandler.go --with-expecter --structname=MockMsgHandler --outpkg=mock_util --inpackage=false
	$(INSTALL_PATH)/mockery --name=FlowgraphManager --dir=$(PWD)/internal/flushcommon/pipeline --output=$(PWD)/internal/flushcommon/pipeline --filename=mock_fgmanager.go --with-expecter --structname=MockFlowgraphManager --outpkg=pipeline --inpackage
	$(call log_done,generate-mockery-flushcommon)

generate-mockery-metastore: getdeps
	$(call log_start,generate-mockery-metastore)
	$(INSTALL_PATH)/mockery --name=RootCoordCatalog --dir=$(PWD)/internal/metastore --output=$(PWD)/internal/metastore/mocks --filename=mock_rootcoord_catalog.go --with-expecter --structname=RootCoordCatalog --outpkg=mocks
	$(INSTALL_PATH)/mockery --name=DataCoordCatalog --dir=$(PWD)/internal/metastore --output=$(PWD)/internal/metastore/mocks --filename=mock_datacoord_catalog.go --with-expecter --structname=DataCoordCatalog --outpkg=mocks
	$(INSTALL_PATH)/mockery --name=QueryCoordCatalog --dir=$(PWD)/internal/metastore --output=$(PWD)/internal/metastore/mocks --filename=mock_querycoord_catalog.go --with-expecter --structname=QueryCoordCatalog --outpkg=mocks
	$(call log_done,generate-mockery-metastore)

generate-mockery-utils: getdeps
	$(call log_start,generate-mockery-utils)
	# dependency.Factory
	$(INSTALL_PATH)/mockery --name=Factory --dir=internal/util/dependency --output=internal/util/dependency --filename=mock_factory.go --with-expecter --structname=MockFactory --inpackage
	# tso.Allocator
	$(INSTALL_PATH)/mockery --name=Allocator --dir=internal/tso --output=internal/tso/mocks --filename=allocator.go --with-expecter --structname=Allocator --outpkg=mocktso
	$(INSTALL_PATH)/mockery --name=SessionInterface --dir=$(PWD)/internal/util/sessionutil --output=$(PWD)/internal/util/sessionutil --filename=mock_session.go --with-expecter --structname=MockSession --inpackage
	$(INSTALL_PATH)/mockery --name=SessionWatcher --dir=$(PWD)/internal/util/sessionutil --output=$(PWD)/internal/util/sessionutil --filename=mock_session_watcher.go --with-expecter --structname=MockSessionWatcher --inpackage
	$(INSTALL_PATH)/mockery --name=GrpcClient --dir=$(PWD)/internal/util/grpcclient --output=$(PWD)/internal/mocks --filename=mock_grpc_client.go --with-expecter --structname=MockGrpcClient
	# proxy_client_manager.go
	$(INSTALL_PATH)/mockery --name=ProxyClientManagerInterface --dir=$(PWD)/internal/util/proxyutil --output=$(PWD)/internal/util/proxyutil --filename=mock_proxy_client_manager.go --with-expecter --structname=MockProxyClientManager --inpackage
	$(INSTALL_PATH)/mockery --name=ProxyWatcherInterface --dir=$(PWD)/internal/util/proxyutil --output=$(PWD)/internal/util/proxyutil --filename=mock_proxy_watcher.go --with-expecter --structname=MockProxyWatcher --inpackage
	# function
	$(INSTALL_PATH)/mockery --name=FunctionRunner --dir=$(PWD)/internal/util/function --output=$(PWD)/internal/util/function --filename=mock_function.go --with-expecter --structname=MockFunctionRunner --inpackage
	$(INSTALL_PATH)/mockery --name=GlobalIDAllocatorInterface --dir=internal/allocator --output=internal/allocator --filename=mock_global_id_allocator.go --with-expecter --structname=MockGlobalIDAllocator --inpackage
	$(call log_done,generate-mockery-utils)

generate-mockery-kv: getdeps
	$(call log_start,generate-mockery-kv)
	$(INSTALL_PATH)/mockery --name=TxnKV --dir=$(PWD)/pkg/kv --output=$(PWD)/internal/kv/mocks --filename=txn_kv.go --with-expecter
	$(INSTALL_PATH)/mockery --name=MetaKv --dir=$(PWD)/pkg/kv --output=$(PWD)/internal/kv/mocks --filename=meta_kv.go --with-expecter
	$(INSTALL_PATH)/mockery --name=WatchKV --dir=$(PWD)/pkg/kv --output=$(PWD)/internal/kv/mocks --filename=watch_kv.go --with-expecter
	$(INSTALL_PATH)/mockery --name=Predicate --dir=$(PWD)/pkg/kv/predicates --output=$(PWD)/internal/kv/predicates --filename=mock_predicate.go --with-expecter --inpackage
	$(call log_done,generate-mockery-kv)

generate-mockery-chunk-manager: getdeps
	$(call log_start,generate-mockery-chunk-manager)
	$(INSTALL_PATH)/mockery --name=ChunkManager --dir=$(PWD)/internal/storage --output=$(PWD)/internal/mocks --filename=mock_chunk_manager.go --with-expecter
	$(call log_done,generate-mockery-chunk-manager)

generate-mockery-pkg:
	$(call log_start,generate-mockery-pkg)
	$(MAKE) -C pkg generate-mockery
	$(call log_done,generate-mockery-pkg)

generate-mockery-internal: getdeps
	$(call log_start,generate-mockery-internal)
	$(INSTALL_PATH)/mockery --config $(PWD)/internal/.mockery.yaml
	$(call log_done,generate-mockery-internal)

generate-mockery-client:
	$(call log_start,generate-mockery-client)
	$(MAKE) -C client generate-mockery
	$(call log_done,generate-mockery-client)

generate-mockery-cdc: getdeps
	$(call log_start,generate-mockery-cdc)
	$(INSTALL_PATH)/mockery --config $(PWD)/internal/cdc/.mockery.yaml
	$(call log_done,generate-mockery-cdc)

generate-mockery: generate-mockery-types generate-mockery-kv generate-mockery-rootcoord generate-mockery-proxy generate-mockery-querycoord generate-mockery-querynode generate-mockery-datacoord generate-mockery-pkg generate-mockery-internal generate-mockery-client

generate-yaml: milvus-tools
	$(call log_start,generate-yaml)
	@echo "Updating milvus config yaml"
	@$(PWD)/bin/tools/config gen-yaml && mv milvus.yaml configs/milvus.yaml
	$(call log_done,generate-yaml)

MMAP_MIGRATION_PATH = $(PWD)/cmd/tools/migration/mmap/tool
mmap-migration:
	$(call log_start,mmap-migration)
	@echo "Building migration tool ..."
	@source $(PWD)/scripts/setenv.sh && \
    		mkdir -p $(INSTALL_PATH) && go env -w CGO_ENABLED="1" && \
    		GO111MODULE=on $(GO) build -pgo=$(PGO_PATH)/default.pgo -ldflags="-r $${RPATH} -X '$(OBJPREFIX).BuildTags=$(BUILD_TAGS)' -X '$(OBJPREFIX).BuildTime=$(BUILD_TIME)' -X '$(OBJPREFIX).GitCommit=$(GIT_COMMIT)' -X '$(OBJPREFIX).GoVersion=$(GO_VERSION)' -X '$(OBJPREFIX).MilvusVersion=$(MILVUS_VERSION)'" \
    		-tags dynamic -o $(INSTALL_PATH)/mmap-migration $(MMAP_MIGRATION_PATH)/main.go 1>/dev/null
	$(call log_done,mmap-migration)

generate-parser:
	$(call log_start,generate-parser)
	@echo "Updating milvus expression parser"
	@(cd $(PWD)/internal/parser/planparserv2 && env bash generate.sh)
	$(call log_done,generate-parser)
