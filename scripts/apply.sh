#!/usr/bin/env bash
# =============================================================================
# apply.sh —— 内核优化补丁应用（双树版 v3）
#   目标机型: OnePlus Ace Pro (PGP110 / SM8475)
#   代码基线: android12-5.10 / linux-5.10.236
#
# 树映射（v3 相对 v2 的关键修正）:
#   ┌──────────────┬──────────────────┬─────────────────────────────────────────┐
#   │ 改动         │ 作用树           │ 原因                                     │
#   ├──────────────┼──────────────────┼─────────────────────────────────────────┤
#   │ SSG 调度器   │ common/          │ mixed build 下 Image 由 common 产出；     │
#   │              │                  │ obj-y 项不会被 make modules 编译，        │
#   │              │                  │ 放在 msm-kernel 等于没打（BLOCKING-2）    │
#   │ LRNG         │ common/          │ 同上 + vendor 树 Kconfig 里没有该符号     │
#   ├──────────────┼──────────────────┼─────────────────────────────────────────┤
#   │ 内核配置     │ common/arch/arm64/configs/gki_defconfig 末尾               │
#   │              │ ← v3 修正（BLOCKING-1）：不再写共享的 consolidate.fragment，│
#   │              │   否则 vendor 趟 defconfig 会因 check_merged_defconfig    │
#   │              │   报 "did not apply as expected" 而 exit 1                │
#   ├──────────────┼─────────────────────────────────────────────────────────┤
#   │ ThinLTO      │ 不改文件，仅构建参数 LTO=thin                             │
#   └──────────────┴─────────────────────────────────────────────────────────┘
#
# 用法（在 repo/ROM 根目录执行）:
#     ROM_ROOT=$PWD bash scripts/apply.sh
# 环境变量:
#     ROM_ROOT=<path>    默认 $(pwd)
#     RUN_BUILD=1        默认 0（只应用补丁+配置，不编译；编译交给 workflow 下一步）
#     LTO_MODE=thin      仅用于打印提示
#     FORCE_PARTIAL_TRACK=x  debug 用，忽略 idempotency
#
# 幂等性: 三段（SSG / LRNG / 配置）各自独立开关，重复执行不会产生 .rej 噪声。
#
# 已验证（/tmp 沙箱用真实 5.10.236 源码逐 hunk 模拟）:
#   * SSG → common/: 0 失败 0 fuzz
#   * LRNG 主系列 25 patch: 22 个 100% 直接应用；4 个 hunk 被拒，位置恒定
#   * 前置补丁过滤 2 个孤儿 include 后 hunk 计数改为 +6,8
#   * 手工 rebase v59-09 后，07/08/10/11/12/13 仍可干净应用
#   * CONFIG_LRNG 若出现在 vendor 趟合并链上会被 diffconfig 判为 "-LRNG" 并 exit 1（已实证）
# =============================================================================
set -eo pipefail
export LC_ALL=C          # 保证 sort/grep 行为一致（EXPECTED_REJECTS 比较依赖字典序）

# ---------------------------------------------------------------------------
# 0. 路径与参数
# ---------------------------------------------------------------------------
ROM_ROOT="${ROM_ROOT:-$(pwd)}"
KP="${KP:-$ROM_ROOT/kernel_platform}"

TREE_NAME="${TREE_NAME:-common}"     # v3: SSG 与 LRNG 统一落 common
TREE="$KP/$TREE_NAME"

CFG_GKI="${CFG_GKI:-$KP/common/arch/arm64/configs/gki_defconfig}"   # BLOCKING-1 修正点

LTO_MODE="${LTO_MODE:-thin}"
RUN_BUILD="${RUN_BUILD:-0}"

WORK="${WORK:-/tmp/lrng-ssg-patches}"
SRC="$WORK/src"
LOG="$WORK/log"

# 只在这些子树里扫描 .rej，避免对整个 common/（~8 万文件）反复 find
REJ_SCOPE="drivers/char crypto kernel/sched include/linux block"

GIT=(git -c 'safe.directory=*')

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo; echo "▶ $*"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }

# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------
find_rej() { # find_rej <tree> [args...]  —— 限定扫描范围
  local tree="$1"; shift
  local paths=""
  local d
  for d in $REJ_SCOPE; do [ -d "$tree/$d" ] && paths="$paths $tree/$d"; done
  [ -n "$paths" ] || paths="$tree"
  find $paths -name '*.rej' "$@" 2>/dev/null || true
}

fetch() { # 重试下载（raw.githubusercontent 实测偶发 0 字节）
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

insert_before() {
  local f="$1" pat="$2" txt="$3" once="${4:-1}"
  awk -v pat="$pat" -v txt="$txt" -v once="$once" '
    once==1 && !done && $0 ~ pat { print txt; done=1 }
    once!=1 && $0 ~ pat          { print txt }
    { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

apply_patch() { # apply_patch <tree> <patch> → 0 干净 / 1 部分(有 .rej) / 2 完全失败
  local tree="$1" p="$2" name; name="$(basename "$p")"
  find_rej "$tree" -delete
  if "${GIT[@]}" -C "$tree" apply --check -p1 "$p" >/dev/null 2>&1; then
    "${GIT[@]}" -C "$tree" apply -p1 "$p"; echo "    ✅ 直接应用: $name"; return 0
  fi
  if "${GIT[@]}" -C "$tree" apply -p1 --reject "$p" >/dev/null 2>&1; then
    echo "    ✅ 直接应用: $name"; return 0
  fi
  local n; n="$(find_rej "$tree" | wc -l | tr -d ' ')"
  if [ "$n" -gt 0 ]; then
    echo "    ⚠️  部分应用: $name"
    find_rej "$tree" -exec basename {} \; | sed 's/^/        ↳ 被拒: /'
    return 1
  fi
  echo "    ❌ 完全失败: $name"; return 2
}

collect_rejects() { # 保留相对路径，避免同名 .rej 覆盖
  local tree="$1" tag="$2" d="$LOG/rejects-$tag" r rel
  mkdir -p "$d"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    rel="${r#$tree/}"; mkdir -p "$d/$(dirname "$rel")"; mv "$r" "$d/$rel"
  done < <(find_rej "$tree" -print)
}

append_unique() {
  local f="$1" line="$2"
  if grep -qxF "$line" "$f"; then ok "已存在，跳过: $line"
  else printf '%s\n' "$line" >> "$f"; ok "已追加: $line"; fi
}

mkdir -p "$SRC" "$LOG"
[ -d "$KP" ]        || die "找不到 kernel_platform: $KP（在 repo 根目录执行）"
[ -d "$TREE" ]      || die "找不到目标树: $TREE"
[ -f "$CFG_GKI" ]   || die "找不到 GKI 配置: $CFG_GKI"
command -v git  >/dev/null || die "需要 git"
command -v curl >/dev/null || die "需要 curl"
command -v git -C "$TREE" rev-parse >/dev/null 2>&1 || warn "$TREE 不是 git 仓库，git apply 将失败"

cat <<EOF
==============================================================
 ROM_ROOT   = $ROM_ROOT
 kernel_plat= $KP
 目标树      = $TREE_NAME  ($TREE)
 配置写入    = ${CFG_GKI#$KP/}   (v3: LRNG + SSG + USB 三合一)
 LTO         = $LTO_MODE （构建参数，不改文件）
 RUN_BUILD   = $RUN_BUILD
==============================================================
EOF

# ===========================================================================
# 第一部分：SSG → common/
# ===========================================================================
info "PART 1 / SSG → $TREE_NAME/"
SSG_PATCH="$SRC/ssg-f03f1386.patch"
if [ -f "$TREE/block/ssg-iosched.c" ]; then
  ok "SSG 已应用，跳过"
else
  fetch "https://github.com/acuicultor/RadioactiveKernel_Pantah/commit/f03f138612bb4b4517efb33d82a29d38a42fd038.patch" "$SSG_PATCH"
  ok "已下载 $(basename "$SSG_PATCH") ($(wc -c < "$SSG_PATCH") 字节)"
  "${GIT[@]}" -C "$TREE" apply -p1 "$SSG_PATCH"
  ok "已应用（+1402 行）"
fi
[ -f "$TREE/block/ssg-iosched.c" ] || die "SSG 校验失败: block/ssg-iosched.c 缺失"
[ -f "$TREE/block/ssg-cgroup.c" ]  || die "SSG 校验失败: block/ssg-cgroup.c 缺失"
[ -f "$TREE/block/ssg-cgroup.h" ]  || die "SSG 校验失败: block/ssg-cgroup.h 缺失"
grep -q 'MQ_IOSCHED_SSG' "$TREE/block/Kconfig.iosched" || die "SSG 校验失败: Kconfig.iosched 未接线"
grep -q 'ssg-iosched.o'  "$TREE/block/Makefile"        || die "SSG 校验失败: Makefile 未接线"
ok "SSG 校验通过"

# ===========================================================================
# 第二部分：LRNG → common/
# ===========================================================================
info "PART 2 / LRNG → $TREE_NAME/"
LRNG_DONE=0
if [ -f "$TREE/drivers/char/lrng/lrng_es_mgr.c" ] && \
   grep -qF 'source "drivers/char/lrng/Kconfig"' "$TREE/drivers/char/Kconfig"; then
  LRNG_DONE=1
  ok "LRNG 已应用，整段跳过（幂等保护）"
fi

if [ "$LRNG_DONE" -eq 0 ]; then

# --- 2.1 前置补丁：只保留 highmem.h --------------------------------------
PRE_RAW="$SRC/v59-000001-core.patch"
PRE="$SRC/v59-000001-core.filtered.patch"
[ -s "$PRE_RAW" ] || fetch "https://raw.githubusercontent.com/smuellerDD/lrng/v59/backports/v59-5.10.236/v59-000001-core.patch" "$PRE_RAW"
# 原补丁加 3 个 include；hrtimer_api.h / ktime_api.h 在 v59 全套中无人提供 → 删除并修正 hunk 计数
sed -e '/^+#include <linux\/hrtimer_api\.h>$/d' \
    -e '/^+#include <linux\/ktime_api\.h>$/d' \
    -e 's|^@@ -6,6 +6,10 @@|@@ -6,6 +6,8 @@|' "$PRE_RAW" > "$PRE"
grep -q '^+#include <linux/highmem.h>$' "$PRE" || die "前置补丁过滤异常: highmem.h 丢失"
grep -q '^@@ -6,6 +6,8 @@'              "$PRE" || die "前置补丁过滤异常: hunk 计数未改写"
if "${GIT[@]}" -C "$TREE" apply --check -p1 "$PRE" >/dev/null 2>&1; then
  "${GIT[@]}" -C "$TREE" apply -p1 "$PRE"
  ok "前置补丁已落（仅 highmem.h；计数 +6,8）"
elif grep -qF '#include <linux/highmem.h>' "$TREE/kernel/sched/core.c"; then
  ok "前置补丁效果已存在，跳过"
else
  die "前置补丁应用失败（$TREE_NAME/kernel/sched/core.c 上下文不匹配）"
fi

# --- 2.2 主系列 v59-0001 … v59-0025 -------------------------------------
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
# LC_ALL=C 下 sort -u 的顺序：crypto/... < drivers/char/Kconfig < drivers/char/Makefile < kernel/...
EXPECTED_REJECTS="crypto/drbg.c drivers/char/Kconfig drivers/char/Makefile kernel/sched/core.c"
REJ_SEEN="$LOG/rejects-seen.txt"; : > "$REJ_SEEN"
N_PARTIAL=0; N_FAILED=0

for name in "${SERIES[@]}"; do
  p="$SRC/$name"
  [ -s "$p" ] || fetch "$SRC_URL/$name" "$p"
  set +e; apply_patch "$TREE" "$p"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 2 ]; then
      N_FAILED=$((N_FAILED + 1)); warn "完全失败: $name"
    else
      N_PARTIAL=$((N_PARTIAL + 1))
    fi
    find_rej "$TREE" -printf '%P\n' 2>/dev/null | sed 's|\.rej$||' >> "$REJ_SEEN" || \
      find_rej "$TREE" | sed "s|^$TREE/||;s|\.rej$||" >> "$REJ_SEEN"
    find_rej "$TREE" -exec sh -c 'echo "--- $1"; head -25 "$1"' _ {} \; >> "$LOG/series-rejects.log" 2>&1 || true
    collect_rejects "$TREE" lrng
  fi
done
ok "主系列完成: ${#SERIES[@]} 补丁 | 部分被拒 $N_PARTIAL | 完全失败 $N_FAILED"
[ "$N_FAILED" -eq 0 ] || die "主系列有 $N_FAILED 个补丁完全失败，见 $LOG/series-rejects.log"

ACTUAL="$(sort -u "$REJ_SEEN" | tr '\n' ' ' | sed 's/ *$//')"
if [ "$ACTUAL" != "$EXPECTED_REJECTS" ]; then
  warn "被拒文件集合与预期不符（下面手工改基仍会尝试，但请复核 $LOG/series-rejects.log）"
  echo "        预期: $EXPECTED_REJECTS"
  echo "        实际: $ACTUAL"
else
  ok "被拒文件集合与预期一致（4 个 hunk）"
fi

# --- 2.3 四处手工改基 ---------------------------------------------------
info "手工改基 1/4: drivers/char/Kconfig —— 末尾 endmenu 前引入 lrng"
KCONFIG_F="$TREE/drivers/char/Kconfig"
[ -f "$KCONFIG_F" ] || die "找不到 $KCONFIG_F"
if grep -qF 'source "drivers/char/lrng/Kconfig"' "$KCONFIG_F"; then
  ok "已存在，跳过"
else
  LAST_EM="$(awk '/^endmenu$/{n=NR} END{print n}' "$KCONFIG_F")"   # common:511
  [ -n "${LAST_EM:-}" ] && [ "$LAST_EM" -gt 0 ] || die "找不到顶层 endmenu: $KCONFIG_F"
  awk -v n="$LAST_EM" 'NR==n{print "source \"drivers/char/lrng/Kconfig\""; print ""} {print}' \
      "$KCONFIG_F" > "$KCONFIG_F.tmp" && mv "$KCONFIG_F.tmp" "$KCONFIG_F"
  ok "已在第 $LAST_EM 行（endmenu）前插入 source"
fi
grep -qF 'source "drivers/char/lrng/Kconfig"' "$KCONFIG_F" || die "Kconfig 接线失败"

info "手工改基 2/4: drivers/char/Makefile —— 末尾追加 lrng/"
MAKEFILE_F="$TREE/drivers/char/Makefile"
[ -f "$MAKEFILE_F" ] || die "找不到 $MAKEFILE_F"
if grep -qF 'obj-$(CONFIG_LRNG)' "$MAKEFILE_F"; then
  ok "已存在，跳过"
else
  # 本树最后一行恰为 obj-$(CONFIG_ADI) += adi.o，全文无 ifdef 块 → 文件末尾即上游意图位置
  printf 'obj-$(CONFIG_LRNG)\t\t+= lrng/\n' >> "$MAKEFILE_F"
  ok "已追加 obj-\$(CONFIG_LRNG) += lrng/"
fi
grep -qF 'obj-$(CONFIG_LRNG)' "$MAKEFILE_F" || die "Makefile 接线失败"

info "手工改基 3/4: crypto/drbg.c —— 去掉 drbg_cores[] 的 static"
DRBG_F="$TREE/crypto/drbg.c"
[ -f "$DRBG_F" ] || die "找不到 $DRBG_F"
if grep -q '^const struct drbg_core drbg_cores\[\] = {' "$DRBG_F"; then
  ok "已是非 static，跳过"
elif grep -q '^static const struct drbg_core drbg_cores\[\] = {' "$DRBG_F"; then
  awk '{ if (!done && $0 == "static const struct drbg_core drbg_cores[] = {") { sub(/^static /, ""); done=1 } print }' \
      "$DRBG_F" > "$DRBG_F.tmp" && mv "$DRBG_F.tmp" "$DRBG_F"
  ok "已去掉 static"
else
  die "在 $DRBG_F 中找不到 drbg_cores[] 定义"
fi

info "手工改基 4/4: kernel/sched/core.c —— 加 #include <linux/lrng.h>"
SCHED_F="$TREE/kernel/sched/core.c"
[ -f "$SCHED_F" ] || die "找不到 $SCHED_F"
if grep -qF '#include <linux/lrng.h>' "$SCHED_F"; then
  ok "已存在，跳过"
else
  if grep -qF '#include <linux/highmem.h>' "$SCHED_F"; then
    insert_before "$SCHED_F" '^#include <linux/highmem\.h>$' '#include <linux/lrng.h>' 1
  else
    insert_before "$SCHED_F" '^#define CREATE_TRACE_POINTS$' '#include <linux/lrng.h>' 1
  fi
  ok "已插入 #include <linux/lrng.h>"
fi
grep -qF '#include <linux/lrng.h>' "$SCHED_F" || die "sched/core.c 未插入 lrng.h（两个锚点均未命中）"
grep -qF 'add_sched_randomness'    "$SCHED_F" || warn "sched/core.c 未见 add_sched_randomness（若未启用 CONFIG_LRNG_SCHED 可忽略）"

# --- 2.4 后置补丁 -------------------------------------------------------
BP_URL="https://raw.githubusercontent.com/smuellerDD/lrng/v59/backports/v59-5.10.236"
info "后置: v59-09（官方补丁优先，失败则按补丁语义手工 rebase 4 行）"
P09="$SRC/v59-09-revert-split-random_init.patch"
[ -s "$P09" ] || fetch "$BP_URL/v59-09-revert-split-random_init.patch" "$P09"
LRNG_RK="$TREE/drivers/char/lrng/lrng_interface_random_kernel.c"
[ -f "$LRNG_RK" ] || die "找不到 $LRNG_RK（主系列未正确落盘？）"
if "${GIT[@]}" -C "$TREE" apply --check -p1 "$P09" >/dev/null 2>&1; then
  "${GIT[@]}" -C "$TREE" apply -p1 "$P09"; ok "v59-09 直接应用"
elif grep -q '^int __init random_init(const char \*command_line)$' "$LRNG_RK"; then
  ok "v59-09 效果已存在，跳过"
else
  warn "v59-09 上下文不匹配（补丁基线 5.15.86）→ 等价手工 rebase（4 行）"
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
grep -q '^static void __init random_init_early'               "$LRNG_RK" || die "v59-09 校验失败: random_init_early 未变 static"
grep -q '^int __init random_init(const char \*command_line)$'  "$LRNG_RK" || die "v59-09 校验失败: random_init 签名未改"
ok "v59-09 校验通过"

POST_FAIL=0
for name in v59-07-sha-includes.patch \
            v59-08-revert-arch_get_random_long.patch \
            v59-10-revert_add_hwgenerator_randomness_update.patch \
            v59-11-add_terminator_sysctl_table.patch \
            v59-12-config_base_small.patch \
            v59-13-sysctl-unconstify.patch ; do
  p="$SRC/$name"
  [ -s "$p" ] || fetch "$BP_URL/$name" "$p"
  set +e; apply_patch "$TREE" "$p"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    POST_FAIL=$((POST_FAIL + 1))
    warn "$name 未干净应用（详见 $LOG/series-rejects.log）"
    find_rej "$TREE" -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; >> "$LOG/series-rejects.log" 2>&1 || true
    collect_rejects "$TREE" lrng
  fi
done
# v3: 这些补丁对本基线应 100% 干净应用，失败=环境漂移 → 硬失败（v2 只是 warn）
[ "$POST_FAIL" -eq 0 ] || die "后置补丁有 $POST_FAIL 个未干净应用，见 $LOG/series-rejects.log"

cat > "$LOG/SKIPPED.txt" <<'EOF'
本脚本刻意跳过的两个后置补丁：

v59-05-sysctl.patch
    期望把 lrng_sysctl.c 的 random_table[] 改为非 static，并删除
    random_sysctls_init()/device_initcall()。v59 源码仍是旧形态
    （lrng_sysctl.c:89 static、:134/:139 device_initcall），该补丁面向
    "更新内核把 sysctl 注册搬到别处" 的场景 → 对 5.10.236 应跳过。
    （对 5.10.236 而言保留 device_initcall 注册才是正确形态。）

v59-06-add_random_ready_callbacks.patch
    要求新增 RAW_NOTIFIER_HEAD(lrng_ready_chain) 一整套 API；但 v59 源码
    已改用 ATOMIC_NOTIFIER_HEAD(random_ready_notifier)
    （lrng_interface_random_kernel.c:22）→ 该补丁属过时实现，跳过。
EOF
ok "跳过 05/06 的原因已记录: $LOG/SKIPPED.txt"

# --- 2.5 落盘校验 -------------------------------------------------------
fi  # LRNG_DONE

[ -f "$TREE/include/linux/lrng.h" ]            || die "LRNG 校验失败: include/linux/lrng.h 缺失"
[ -f "$TREE/drivers/char/lrng/lrng_es_mgr.c" ] || die "LRNG 校验失败: lrng_es_mgr.c 缺失"
N_LRNG="$(ls "$TREE/drivers/char/lrng" | wc -l | tr -d ' ')"
[ "$N_LRNG" -eq 55 ] || die "LRNG 校验失败: drivers/char/lrng 文件数 $N_LRNG（期望 55）"
grep -qF 'source "drivers/char/lrng/Kconfig"' "$TREE/drivers/char/Kconfig"  || die "LRNG 校验失败: Kconfig 未接线"
grep -qF 'obj-$(CONFIG_LRNG)'                 "$TREE/drivers/char/Makefile" || die "LRNG 校验失败: Makefile 未接线"
ok "LRNG 校验通过（lrng/ 共 $N_LRNG 文件 + include/linux/lrng.h + 两处接线）"

# ===========================================================================
# 第三部分：配置（v3 全部写入 GKI 侧 gki_defconfig，避免污染 vendor 合并链）
# ===========================================================================
info "PART 3 / 配置 → ${CFG_GKI#$KP/}"
BEFORE="$(wc -l < "$CFG_GKI" | tr -d ' ')"
append_unique "$CFG_GKI" 'CONFIG_USB_AUTOSUSPEND_DELAY=5'
append_unique "$CFG_GKI" 'CONFIG_MQ_IOSCHED_SSG=y'
append_unique "$CFG_GKI" 'CONFIG_MQ_IOSCHED_SSG_CGROUP=y'
append_unique "$CFG_GKI" 'CONFIG_LRNG=y'
AFTER="$(wc -l < "$CFG_GKI" | tr -d ' ')"
ok "行数 $BEFORE → $AFTER"

cat <<'NOTE'
      说明：这 4 行写在 GKI 侧 gki_defconfig，理由：
        · CONFIG_MQ_IOSCHED_SSG / CONFIG_LRNG 的源码只打在 common/，若写进
          vendor 趟也会合并的 consolidate.fragment，会让 vendor 趟的
          check_merged_defconfig 输出 "-符号" 并以
          "ERROR! Defconfig fragment did not apply as expected" 退出 1；
        · CONFIG_USB_AUTOSUSPEND_DELAY 同理（只写在 GKI 侧，避免双写冗余告警）；
        · msm-kernel/arch/arm64/configs/gki_defconfig 不在这条合并链上，天然隔离。
NOTE

# ===========================================================================
# 第四部分：ThinLTO（仅提示构建参数）
# ===========================================================================
info "PART 4 / ThinLTO 构建参数"
cat <<EOF
--------------------------------------------------------------
 推荐命令（workflow 中单独一步执行）：
   cd $ROM_ROOT
   export LTO=${LTO_MODE}
   ./kernel_platform/oplus/build/oplus_build_kernel.sh waipio consolidate

 ⚠️ 注意：oplus_build_kernel.sh 只传 \$1 \$2，没有第 3 参（LTO），
    必须 export LTO=${LTO_MODE}，否则非交互下会静默回落 defconfig 的 FULL LTO。

 若手工拼环境（等价于 oplus_build_kernel.sh:6-14）：
   export ANDROID_BUILD_TOP=\$PWD
   export TARGET_BOARD_PLATFORM=taro
   export ANDROID_PRODUCT_OUT=\$PWD/out/target/product/taro
   export CHIPSET_COMPANY=QCOM OPLUS_VND_BUILD_PLATFORM=SM8475
   export LTO=${LTO_MODE} EXTRA_KBUILD_ARGS="--skip abl"
   ./kernel_platform/build/android/prepare_vendor.sh waipio consolidate
--------------------------------------------------------------
EOF
if [ "$RUN_BUILD" = "1" ]; then
  ( cd "$ROM_ROOT" && export LTO="${LTO_MODE}" && \
    ./kernel_platform/oplus/build/oplus_build_kernel.sh waipio consolidate )
else
  warn "RUN_BUILD=0，未编译（编译由 workflow 的 Build 步骤执行）"
fi

# ===========================================================================
# 收尾
# ===========================================================================
echo
cat <<EOF
==============================================================
 完成
   SSG  ($TREE_NAME): block/ssg-iosched.c, ssg-cgroup.c/.h + 接线
   LRNG ($TREE_NAME): drivers/char/lrng/ ($N_LRNG 文件) + include/linux/lrng.h + 接线
   配置  : ${CFG_GKI#$KP/} ($AFTER 行)
   日志  : $LOG/
   LTO   : $LTO_MODE（仅构建参数）
==============================================================
EOF
