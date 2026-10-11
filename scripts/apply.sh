#!/usr/bin/env bash
# =============================================================================
# apply_kernel_optimizations.sh   —— 双树版 (dual-tree)
#   目标机型: OnePlus Ace Pro (PGP110 / SM8475)
#   代码基线: android12-5.10 / linux-5.10.236
#
# 树映射（本版核心变更）:
#   ┌─────────────┬──────────────────┬────────────────────────────────────────┐
#   │ 改动        │ 作用树           │ 原因                                    │
#   ├─────────────┼──────────────────┼────────────────────────────────────────┤
#   │ SSG 调度器  │ msm-kernel/block │ vendor 侧块层源码，随 vendor 趟编译      │
#   │ LRNG        │ common/          │ 替换核心 RNG（random.c/sched/core.c），  │
#   │             │                  │ GKI 趟产出 Image，必须落 common          │
#   │ USB 挂起    │ 两处 config 都写 │ usbcore 在 Image(GKI)、策略两端都要一致  │
#   │ ThinLTO     │ 不改文件         │ 仅通过构建参数 / 环境变量 LTO=thin       │
#   └─────────────┴──────────────────┴────────────────────────────────────────┘
#
# 配置文件双写:
#   msm-kernel/arch/arm64/configs/vendor/waipio_consolidate.config  ← USB + SSG
#   common/arch/arm64/configs/consolidate.fragment                  ← USB + LRNG
#
# 用法（在 ROM 根目录、即 kernel_platform 的上一层执行）:
#     bash apply_kernel_optimizations.sh
# 可选环境变量:
#     ROM_ROOT=/path/to/rom    # 默认 $(pwd)
#     RUN_BUILD=1              # 默认 0：只打印 ThinLTO 构建命令，不编译
#     LTO_MODE=thin            # 只影响打印出来的构建命令
#     BUILD_TYPE=consolidate   # consolidate | gki
#
# 已验证事实（在 /tmp 沙箱用真实 5.10.236 源码逐 hunk 模拟，msm-kernel 与 common 判定一致）:
#   * SSG 补丁 → msm-kernel/ : 0 失败 0 fuzz；新建 block/ssg-{iosched.c,cgroup.c,cgroup.h}，
#     改 block/Kconfig.iosched 与 block/Makefile（hunk 落 :50 / :26）
#   * LRNG 主系列 25 patch → common/ : 22 个 100% 直接应用；4 个 hunk 被拒，位置恒定为
#       drivers/char/Kconfig, drivers/char/Makefile, crypto/drbg.c, kernel/sched/core.c
#   * 前置补丁过滤掉 2 个孤儿 include 后（hunk 计数改 +6,8）可干净应用
#   * 手工 rebase v59-09 后，07/08/10/11/12/13 仍可干净应用
#   * 产物: common/drivers/char/lrng/ 55 文件 + common/include/linux/lrng.h
#
# 约束: 只改 kernel_platform 内的源码/配置；不下载工具链；默认不编译。
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. 路径与参数
# ---------------------------------------------------------------------------
ROM_ROOT="${ROM_ROOT:-$(pwd)}"
KP="${KP:-$ROM_ROOT/kernel_platform}"

SSG_TREE_NAME="${SSG_TREE_NAME:-msm-kernel}"     # SSG 作用树
LRNG_TREE_NAME="${LRNG_TREE_NAME:-common}"       # LRNG 作用树
SSG_TREE="$KP/$SSG_TREE_NAME"
LRNG_TREE="$KP/$LRNG_TREE_NAME"

CFG_VENDOR="${CFG_VENDOR:-$KP/msm-kernel/arch/arm64/configs/vendor/waipio_consolidate.config}"
CFG_GKI="${CFG_GKI:-$KP/common/arch/arm64/configs/consolidate.fragment}"

LTO_MODE="${LTO_MODE:-thin}"
BUILD_TYPE="${BUILD_TYPE:-consolidate}"
RUN_BUILD="${RUN_BUILD:-0}"

WORK="${WORK:-/tmp/lrng-ssg-patches}"
SRC="$WORK/src"
LOG="$WORK/log"

GIT="git -c safe.directory=* "

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo; echo "▶ $*"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }

# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------
fetch() { # fetch <url> <dest>  —— raw.githubusercontent 实测偶发 0 字节，务必重试
  local url="$1" dest="$2" i
  for i in 1 2 3 4; do
    if curl -fsSL --retry 3 --retry-delay 2 --max-time 300 -o "$dest" "$url" && [ -s "$dest" ]; then
      return 0
    fi
    warn "下载失败/空文件，重试 ($i/4): $(basename "$dest")"
    rm -f "$dest"; sleep 2
  done
  die "下载失败: $url"
}

insert_before() { # insert_before <file> <awk正则> <文本> [只插第一处=1]
  local f="$1" pat="$2" txt="$3" once="${4:-1}"
  awk -v pat="$pat" -v txt="$txt" -v once="$once" '
    once==1 && !done && $0 ~ pat { print txt; done=1 }
    once!=1 && $0 ~ pat          { print txt }
    { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

insert_after() { # insert_after <file> <awk正则> <文本>
  local f="$1" pat="$2" txt="$3"
  awk -v pat="$pat" -v txt="$txt" '
    { print } !done && $0 ~ pat { print txt; done=1 }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

apply_patch() { # apply_patch <tree_abs> <patch>  → 0=干净 1=部分(有.rej) 2=完全失败
  local tree="$1" p="$2" name; name="$(basename "$p")"
  find "$tree" -name '*.rej' -delete 2>/dev/null || true
  if $GIT -C "$tree" apply --check -p1 "$p" >/dev/null 2>&1; then
    $GIT -C "$tree" apply -p1 "$p"; echo "    ✅ 直接应用: $name"; return 0
  fi
  if $GIT -C "$tree" apply -p1 --reject "$p" >/dev/null 2>&1; then
    echo "    ✅ 直接应用: $name"; return 0
  fi
  local n; n="$(find "$tree" -name '*.rej' | wc -l | tr -d ' ')"
  if [ "$n" -gt 0 ]; then
    echo "    ⚠️  部分应用: $name"
    find "$tree" -name '*.rej' -exec basename {} \; | sed 's/^/        ↳ 被拒: /'
    return 1
  fi
  echo "    ❌ 完全失败: $name"; return 2
}

collect_rejects() { # collect_rejects <tree_abs> <标签>
  local tree="$1" tag="$2" d="$LOG/rejects-$tag"
  mkdir -p "$d"
  find "$tree" -name '*.rej' -print0 2>/dev/null | while IFS= read -r -d '' r; do
    mv "$r" "$d/$(basename "$r")"
  done
}

appen
