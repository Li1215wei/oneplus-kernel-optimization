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
set -eo pipefail

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

append_unique() { # append_unique <file> <line>
  local f="$1" line="$2"
  if grep -qxF "$line" "$f"; then ok "已存在，跳过: $line"
  else printf '%s\n' "$line" >> "$f"; ok "已追加: $line"; fi
}

mkdir -p "$SRC" "$LOG"
[ -d "$KP" ]        || die "找不到 kernel_platform: $KP"
[ -d "$SSG_TREE" ]  || die "找不到 SSG 树: $SSG_TREE"
[ -d "$LRNG_TREE" ] || die "找不到 LRNG 树: $LRNG_TREE"
[ -f "$CFG_VENDOR" ]|| die "找不到 vendor 配置: $CFG_VENDOR"
[ -f "$CFG_GKI" ]   || die "找不到 GKI fragment: $CFG_GKI"
command -v git  >/dev/null || die "需要 git"
command -v curl >/dev/null || die "需要 curl"

cat <<EOF
==============================================================
 ROM_ROOT    = $ROM_ROOT
 kernel_plat = $KP
 SSG  树      = $SSG_TREE_NAME   ($SSG_TREE)
 LRNG 树      = $LRNG_TREE_NAME  ($LRNG_TREE)
 配置①       = ${CFG_VENDOR#$KP/}      (USB + SSG)
 配置②       = ${CFG_GKI#$KP/}         (USB + LRNG)
 LTO 模式     = $LTO_MODE   （$([ "$RUN_BUILD" = 1 ] && echo 将执行构建 || echo 仅打印构建命令)）
==============================================================
EOF

# ===========================================================================
# 第一部分：SSG → msm-kernel/
# ===========================================================================
info "PART 1 / SSG → $SSG_TREE_NAME/"
SSG_PATCH="$SRC/ssg-f03f1386.patch"
if [ -f "$SSG_TREE/block/ssg-iosched.c" ]; then
  ok "SSG 已存在，跳过"
else
  fetch "https://github.com/acuicultor/RadioactiveKernel_Pantah/commit/f03f138612bb4b4517efb33d82a29d38a42fd038.patch" "$SSG_PATCH"
  ok "已下载 $(basename "$SSG_PATCH") ($(wc -c < "$SSG_PATCH") 字节)"
  # 期望 0 失败 0 fuzz：新建 3 文件 + 改 block/Kconfig.iosched、block/Makefile
  $GIT -C "$SSG_TREE" apply -p1 "$SSG_PATCH"
  ok "已应用（+1402 行）"
fi
[ -f "$SSG_TREE/block/ssg-iosched.c" ] || die "SSG 校验失败: block/ssg-iosched.c 缺失"
[ -f "$SSG_TREE/block/ssg-cgroup.c" ]  || die "SSG 校验失败: block/ssg-cgroup.c 缺失"
[ -f "$SSG_TREE/block/ssg-cgroup.h" ]  || die "SSG 校验失败: block/ssg-cgroup.h 缺失"
grep -q 'MQ_IOSCHED_SSG'  "$SSG_TREE/block/Kconfig.iosched" || die "SSG 校验失败: Kconfig.iosched 未接线"
grep -q 'ssg-iosched.o'   "$SSG_TREE/block/Makefile"        || die "SSG 校验失败: Makefile 未接线"
ok "SSG 校验通过（3 新文件 + Kconfig/Makefile 接线）"

# ===========================================================================
# 第二部分：LRNG → common/（前置 + 主系列 + 手工改基 + 后置）
# ===========================================================================
info "PART 2 / LRNG → $LRNG_TREE_NAME/"

# --- 2.1 前置补丁：只保留 highmem.h 一行 --------------------------------
# 原补丁对 kernel/sched/core.c 加 3 个 include：
#   +#include <linux/highmem.h>
#   +#include <linux/hrtimer_api.h>    ← v59 全套无人提供该头，删除
#   +#include <linux/ktime_api.h>      ← 同上，删除
#   +
# 删除 2 个 "+" 行后必须同步修正 hunk 计数（@@ -6,6 +6,10 @@ → @@ -6,6 +6,8 @@），
# 否则 git apply 会因计数不符而拒绝整个 hunk（已实测）。
PRE_RAW="$SRC/v59-000001-core.patch"
PRE="$SRC/v59-000001-core.filtered.patch"
fetch "https://raw.githubusercontent.com/smuellerDD/lrng/v59/backports/v59-5.10.236/v59-000001-core.patch" "$PRE_RAW"
sed -e '/^+#include <linux\/hrtimer_api\.h>$/d' \
    -e '/^+#include <linux\/ktime_api\.h>$/d' \
    -e 's|^@@ -6,6 +6,10 @@|@@ -6,6 +6,8 @@|' "$PRE_RAW" > "$PRE"
grep -q '^+#include <linux/highmem.h>$' "$PRE" || die "前置补丁过滤异常: highmem.h 行丢失"
grep -q '^@@ -6,6 +6,8 @@'              "$PRE" || die "前置补丁过滤异常: hunk 计数未改写"
if $GIT -C "$LRNG_TREE" apply --check -p1 "$PRE" >/dev/null 2>&1; then
  $GIT -C "$LRNG_TREE" apply -p1 "$PRE"
  ok "前置补丁已落（仅 highmem.h；hunk 计数修正为 +6,8）"
elif grep -q '#include <linux/highmem.h>' "$LRNG_TREE/kernel/sched/core.c"; then
  ok "前置补丁效果已存在，跳过"
else
  die "前置补丁应用失败（$LRNG_TREE_NAME/kernel/sched/core.c 上下文不匹配）"
fi

# --- 2.2 主系列 v59-0001 … v59-0025（按序；容忍 4 个已知被拒 hunk） --------
SRC_URL="https://raw.githubusercontent.com/smuellerDD/lrng/v59/kernel_patches/v6.14"
SERIES=(
  v59-0001-LRNG-Entropy-Source-and-DRNG-Manager.patch
  v59-0002-LRNG-allocate-one-DRNG-instance-per-NUMA-node.patch
  v59-0003-LRNG-proc-interface.patch
  v59-0004-LRNG-add-switchable-DRNG-support.patch
  v59-0005-LRNG-add-common-generic-hash-support.patch
  v59-0006-crypto-DRBG-externalize-DRBG-functions-for-LRNG.patch
  v59-0007-LRNG-add-SP800-90A-DRBG-extension.patch
  v59-0008-LRNG-add-kernel-crypto-API-PRNG-extension.patch
  v59-0009-LRNG-add-atomic-DRNG-implementation.patch
  v59-0010-LRNG-add-common-timer-based-entropy-source-code.patch
  v59-0011-LRNG-add-interrupt-entropy-source.patch
  v59-0012-scheduler-add-entropy-sampling-hook.patch
  v59-0013-LRNG-add-scheduler-based-entropy-source.patch
  v59-0014-LRNG-add-SP800-90B-compliant-health-tests.patch
  v59-0015-LRNG-add-random.c-entropy-source-support.patch
  v59-0016-LRNG-CPU-entropy-source.patch
  v59-0017-LRNG-add-Jitter-RNG-fast-noise-source.patch
  v59-0018-LRNG-add-option-to-enable-runtime-entropy-rate-c.patch
  v59-0019-LRNG-add-interface-for-gathering-of-raw-entropy.patch
  v59-0020-LRNG-add-power-on-and-runtime-self-tests.patch
  v59-0021-LRNG-sysctls-and-proc-interface.patch
  v59-0022-LRMG-add-drop-in-replacement-random-4-API.patch
  v59-0023-LRNG-add-kernel-crypto-API-interface.patch
  v59-0024-LRNG-add-dev-lrng-device-file-support.patch
  v59-0025-LRNG-add-hwrand-framework-interface.patch
)
EXPECTED_REJECTS="drivers/char/Kconfig drivers/char/Makefile crypto/drbg.c kernel/sched/core.c"
REJ_SEEN="$LOG/rejects-seen.txt"; : > "$REJ_SEEN"
N_PARTIAL=0
for name in "${SERIES[@]}"; do
  p="$SRC/$name"
  [ -s "$p" ] || fetch "$SRC_URL/$name" "$p"
  set +e; apply_patch "$LRNG_TREE" "$p"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    N_PARTIAL=$((N_PARTIAL + 1))
    find "$LRNG_TREE" -name '*.rej' -exec basename {} \; >> "$REJ_SEEN"
    find "$LRNG_TREE" -name '*.rej' -exec sh -c 'echo "--- $1"; head -25 "$1"' _ {} \; \
      >> "$LOG/series-rejects.log" 2>&1 || true
    collect_rejects "$LRNG_TREE" lrng
  fi
done
ok "主系列完成: ${#SERIES[@]} 个补丁，其中 $N_PARTIAL 个含被拒 hunk"
# 强校验: 被拒文件集合必须恰好等于预期的 4 个，否则环境与验证基线不符 → 立刻停下人工确认
ACTUAL="$(sort -u "$REJ_SEEN" | tr '\n' ' ' | sed 's/ *$//')"
if [ "$ACTUAL" != "$EXPECTED_REJECTS" ]; then
  warn "被拒文件集合与预期不符"
  echo "        预期: $EXPECTED_REJECTS"
  echo "        实际: $ACTUAL"
  warn "后续手工改基仍会执行，但请务必人工复核 $LOG/series-rejects.log"
else
  ok "被拒文件集合与预期完全一致（4 个 hunk）"
fi

# --- 2.3 四处手工改基（对应 4 个被拒 hunk） ------------------------------
info "手工改基 1/4: $LRNG_TREE_NAME/drivers/char/Kconfig —— 末尾 endmenu 前引入 lrng"
KCONFIG_F="$LRNG_TREE/drivers/char/Kconfig"
if grep -q 'source "drivers/char/lrng/Kconfig"' "$KCONFIG_F"; then
  ok "已存在，跳过"
else
  # 补丁原意是插在 "config ADI" 之后紧跟的 endmenu 之前；本树 ADI 与 endmenu 之间还有其它条目，
  # 故定位「最后一个 ^endmenu$」（common:511 / msm-kernel:529），语义等价且树无关。
  LAST_EM="$(awk '/^endmenu$/{n=NR} END{print n}' "$KCONFIG_F")"
  [ -n "${LAST_EM:-}" ] && [ "$LAST_EM" -gt 0 ] || die "找不到 endmenu: $KCONFIG_F"
  awk -v n="$LAST_EM" 'NR==n{print "source \"drivers/char/lrng/Kconfig\""; print ""} {print}' \
      "$KCONFIG_F" > "$KCONFIG_F.tmp" && mv "$KCONFIG_F.tmp" "$KCONFIG_F"
  ok "已在第 $LAST_EM 行（endmenu）前插入 source（+2 行）"
fi

info "手工改基 2/4: $LRNG_TREE_NAME/drivers/char/Makefile —— 接线 lrng/"
MAKEFILE_F="$LRNG_TREE/drivers/char/Makefile"
if grep -q '^obj-\$(CONFIG_LRNG)[[:space:]]*+=[[:space:]]*lrng/' "$MAKEFILE_F"; then
  ok "已存在，跳过"
else
  insert_after "$MAKEFILE_F" '^obj-y.*mem\.o random\.o' 'obj-$(CONFIG_LRNG)		+= lrng/'
  ok "已在 obj-y += mem.o random.o 之后插入（+1 行）"
fi

info "手工改基 3/4: $LRNG_TREE_NAME/crypto/drbg.c —— 去掉 drbg_cores[] 的 static"
DRBG_F="$LRNG_TREE/crypto/drbg.c"
if grep -q '^const struct drbg_core drbg_cores\[\] = {' "$DRBG_F"; then
  ok "已是非 static，跳过"
elif grep -q '^static const struct drbg_core drbg_cores\[\] = {' "$DRBG_F"; then
  awk '{ if (!done && $0 == "static const struct drbg_core drbg_cores[] = {") { sub(/^static /, ""); done=1 } print }' \
      "$DRBG_F" > "$DRBG_F.tmp" && mv "$DRBG_F.tmp" "$DRBG_F"
  ok "已去掉 static（$DRBG_F:$(grep -n '^const struct drbg_core drbg_cores\[\]' "$DRBG_F" | cut -d: -f1)）"
else
  die "在 $DRBG_F 中找不到 drbg_cores[] 定义，请人工确认"
fi

info "手工改基 4/4: $LRNG_TREE_NAME/kernel/sched/core.c —— 版权块后加 #include <linux/lrng.h>"
SCHED_F="$LRNG_TREE/kernel/sched/core.c"
if grep -q '#include <linux/lrng.h>' "$SCHED_F"; then
  ok "已存在，跳过"
else
  # v59-0012 的 include hunk 上下文含 "Copyright (C) 1998-2024 Ingo Molnar, Red Hat"（6.14 头部），
  # 5.10.236 无此行 → 该 hunk 必被拒；手工补上，且插在刚加上的 highmem.h 之前以匹配补丁顺序。
  if grep -q '#include <linux/highmem.h>' "$SCHED_F"; then
    insert_before "$SCHED_F" '^#include <linux/highmem\.h>$' '#include <linux/lrng.h>' 1
  else
    insert_before "$SCHED_F" '^#define CREATE_TRACE_POINTS$' '#include <linux/lrng.h>' 1
  fi
  ok "已插入 #include <linux/lrng.h>"
fi
grep -q 'add_sched_randomness' "$SCHED_F" \
  || warn "sched/core.c 未见 add_sched_randomness（若未启用 CONFIG_LRNG_SCHED 可忽略）"

# --- 2.4 后置补丁: 09（手工 rebase）→ 07、08、10、11、12、13；跳过 05、06 ---
BP_URL="https://raw.githubusercontent.com/smuellerDD/lrng/v59/backports/v59-5.10.236"
info "后置: v59-09（先试官方补丁；上下文不符则按补丁语义手工改 4 行）"
P09="$SRC/v59-09-revert-split-random_init.patch"
[ -s "$P09" ] || fetch "$BP_URL/v59-09-revert-split-random_init.patch" "$P09"
LRNG_RK="$LRNG_TREE/drivers/char/lrng/lrng_interface_random_kernel.c"
[ -f "$LRNG_RK" ] || die "找不到 $LRNG_RK（主系列未正确落盘？）"
if $GIT -C "$LRNG_TREE" apply --check -p1 "$P09" >/dev/null 2>&1; then
  $GIT -C "$LRNG_TREE" apply -p1 "$P09"; ok "v59-09 直接应用"
elif grep -q '^int __init random_init(const char \*command_line)$' "$LRNG_RK"; then
  ok "v59-09 效果已存在，跳过"
else
  warn "v59-09 上下文不匹配（补丁基线 5.15.86）→ 执行等价手工 rebase（4 行）"
  awk '
    /^void __init random_init_early\(const char \*command_line\)$/ {
        print "static void __init random_init_early(const char *command_line)"; next }
    /^void __init random_init\(void\)$/ {
        inb=1; print "int __init random_init(const char *command_line)"; next }
    inb && /^\{$/ { print; print "\trandom_init_early(command_line);"; next }
    inb && /^\}$/ { print "\treturn 0;"; print "}"; inb=0; next }
    { print }' "$LRNG_RK" > "$LRNG_RK.tmp" && mv "$LRNG_RK.tmp" "$LRNG_RK"
  ok "手工 rebase 完成"
fi
grep -q '^static void __init random_init_early'              "$LRNG_RK" || die "v59-09 校验失败: random_init_early 未变 static"
grep -q '^int __init random_init(const char \*command_line)$' "$LRNG_RK" || die "v59-09 校验失败: random_init 签名未改"
ok "v59-09 校验通过（与 5.10.236 的 init/main.c:958 / random.c:820 签名一致）"

# 顺序说明: 09 已手工落好；其后这些补丁经实测仍可干净应用
for name in v59-07-sha-includes.patch \
            v59-08-revert-arch_get_random_long.patch \
            v59-10-revert_add_hwgenerator_randomness_update.patch \
            v59-11-add_terminator_sysctl_table.patch \
            v59-12-config_base_small.patch \
            v59-13-sysctl-unconstify.patch ; do
  p="$SRC/$name"
  [ -s "$p" ] || fetch "$BP_URL/$name" "$p"
  set +e; apply_patch "$LRNG_TREE" "$p"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    warn "$name 需人工确认（详见 $LOG/series-rejects.log）"
    find "$LRNG_TREE" -name '*.rej' -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; \
      >> "$LOG/series-rejects.log" 2>&1 || true
    collect_rejects "$LRNG_TREE" lrng
  fi
done

cat > "$LOG/SKIPPED.txt" <<'EOF'
本脚本刻意跳过的两个后置补丁（与 v59 现源码形态冲突，属过时实现）:

v59-05-sysctl.patch
    期望把 lrng_sysctl.c 的 random_table[] 改为非 static 并删除 random_sysctls_init()/device_initcall。
    v59 源码仍是旧形态（lrng_sysctl.c:89 static、:134/:139 device_initcall），该补丁面向
    "更新内核把注册搬到别处" 的场景 → 对 5.10.236 应跳过。

v59-06-add_random_ready_callbacks.patch
    要求新增 RAW_NOTIFIER_HEAD(lrng_ready_chain) 一整套；v59 源码已改用
    ATOMIC_NOTIFIER_HEAD(random_ready_notifier)（lrng_interface_random_kernel.c:22）→ 过时，跳过。
EOF
ok "跳过 05/06 的理由已记录: $LOG/SKIPPED.txt"

# --- 2.5 LRNG 落盘校验 ---------------------------------------------------
[ -f "$LRNG_TREE/include/linux/lrng.h" ]            || die "LRNG 校验失败: include/linux/lrng.h 缺失"
[ -f "$LRNG_TREE/drivers/char/lrng/lrng_es_mgr.c" ] || die "LRNG 校验失败: lrng_es_mgr.c 缺失"
N_LRNG="$(ls "$LRNG_TREE/drivers/char/lrng" | wc -l | tr -d ' ')"
[ "$N_LRNG" -eq 55 ] || warn "drivers/char/lrng 文件数 $N_LRNG（期望 55），请核对"
grep -q 'source "drivers/char/lrng/Kconfig"' "$KCONFIG_F" || die "LRNG 校验失败: Kconfig 未接线"
grep -q 'obj-$(CONFIG_LRNG)'                 "$MAKEFILE_F" || die "LRNG 校验失败: Makefile 未接线"
ok "LRNG 校验通过（lrng/ 共 $N_LRNG 文件 + include/linux/lrng.h + 两处接线）"

# ===========================================================================
# 第三部分：配置双写
# ===========================================================================
info "PART 3 / 配置双写"

V_BEFORE="$(wc -l < "$CFG_VENDOR" | tr -d ' ')"
echo "  ── 配置① $CFG_VENDOR  （USB + SSG）"
append_unique "$CFG_VENDOR" 'CONFIG_USB_AUTOSUSPEND_DELAY=5'
append_unique "$CFG_VENDOR" 'CONFIG_MQ_IOSCHED_SSG=y'
append_unique "$CFG_VENDOR" 'CONFIG_MQ_IOSCHED_SSG_CGROUP=y'
V_AFTER="$(wc -l < "$CFG_VENDOR" | tr -d ' ')"
ok "行数 $V_BEFORE → $V_AFTER"

G_BEFORE="$(wc -l < "$CFG_GKI" | tr -d ' ')"
echo "  ── 配置② $CFG_GKI  （USB + LRNG）"
append_unique "$CFG_GKI" 'CONFIG_USB_AUTOSUSPEND_DELAY=5'
append_unique "$CFG_GKI" 'CONFIG_LRNG=y'
G_AFTER="$(wc -l < "$CFG_GKI" | tr -d ' ')"
ok "行数 $G_BEFORE → $G_AFTER"

# 说明：两个窗口都会进 vendor 趟的 DEFCONFIG_FRAGMENTS（msm.gki 既合并 common 的
# consolidate.fragment，也合并 vendor/waipio_consolidate.config），因此 USB 项在两处同值
# 会触发 merge_config.sh -r 的 "redundant" 提示——无害：msm.common:109 的覆盖守卫因
# 单/双空格不匹配而永不触发，不会 exit。保留双写是为让 GKI 趟与 vendor 趟取值一致。
echo "      （双写 USB 项 → 可能出现 'Value of CONFIG_USB_AUTOSUSPEND_DELAY is redundant' 提示，属预期）"

# ===========================================================================
# 第四部分：ThinLTO —— 只改构建参数，不改任何文件
# ===========================================================================
info "PART 4 / ThinLTO（构建参数形式，不修改文件）"
# oplus_build.sh 第 3 个参数即 LTO: full|thin|none
#   ⚠️ none 有缺陷：case 未处理 → 不 export → 回落 gki_defconfig 的 FULL
# oplus_build_kernel.sh 只传 $1 $2，没有第 3 参 → 必须 export LTO=thin，否则非交互下静默回落 FULL
BUILD_CMD="./kernel_platform/oplus/build/oplus_build.sh waipio ${BUILD_TYPE} ${LTO_MODE} all"
cat <<EOF
--------------------------------------------------------------
 构建命令（LTO=${LTO_MODE}）：
   cd $ROM_ROOT
   export LTO=${LTO_MODE}
   $BUILD_CMD 2>&1 | tee build.log

 等价的最小形式（依赖环境变量）：
   cd $ROM_ROOT && export LTO=${LTO_MODE} && \\
     ./kernel_platform/oplus/build/oplus_build_kernel.sh waipio ${BUILD_TYPE}

 构建后验证：
   grep -n "Modifying LTO mode to '${LTO_MODE}'" build.log
   grep -E '^#? ?CONFIG_(LTO_CLANG|LTO_NONE|THINLTO|CFI_CLANG)' out/*/msm-kernel/.config
   grep -E '^#? ?CONFIG_(LTO_CLANG|LTO_NONE|THINLTO|CFI_CLANG)' out/*/gki_kernel/.config
--------------------------------------------------------------
EOF
if [ "$RUN_BUILD" = "1" ]; then
  ( cd "$ROM_ROOT" && export LTO="${LTO_MODE}" && eval "$BUILD_CMD" )
else
  warn "RUN_BUILD=0，未执行构建（默认不编译）"
fi

# ===========================================================================
# 收尾摘要
# ===========================================================================
echo
cat <<EOF
==============================================================
 完成
   SSG  ($SSG_TREE_NAME): block/ssg-iosched.c, ssg-cgroup.c/.h + Kconfig/Makefile 接线
   LRNG ($LRNG_TREE_NAME): drivers/char/lrng/ ($N_LRNG 文件) + include/linux/lrng.h + 两处接线
   配置① : ${CFG_VENDOR#$KP/}  ($V_AFTER 行: USB + SSG)
   配置② : ${CFG_GKI#$KP/}     ($G_AFTER 行: USB + LRNG)
   日志  : $LOG/  (series-rejects.log, rejects-lrng/, SKIPPED.txt, rejects-seen.txt)
   补丁  : $SRC/
   LTO   : $LTO_MODE（仅构建参数，未改文件）
==============================================================
EOF
