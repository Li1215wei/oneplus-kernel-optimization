#!/usr/bin/env bash
# =============================================================================
# apply-gki.sh —— GKI-only 构建补丁脚本（v1）
#   目标机型: OnePlus Ace Pro / 10T (PGP110 / SM8475)
#   代码基线: android12-5.10 / linux-5.10.236
#
# ★ 设计依据（来自可工作的参考工作流 Li1215wei/Action-Build）：
#
#   1. 只构建 GKI 趟（common/），直接 `make gki_defconfig` + `make`，
#      不走 prepare_vendor.sh / build.sh / mixed build。
#      → 不需要 device/qcom、vendor/oplus、super.img 等；
#      → 只产出 Image，交给 AK3 在设备上重新打包 boot。
#
#   2. 配置必须与官方 GKI 完全一致（只用 common/arch/arm64/configs/gki_defconfig），
#      绝不能叠加 consolidate.fragment。
#
#      ⚠️ 这是"刷 boot 就能开机"的唯一前提：
#         consolidate.fragment 会把 LOCKDEP / LOCK_STAT / DEBUG_LOCK_ALLOC /
#         DEBUG_OBJECTS / DEBUG_SPINLOCK / DEBUG_PREEMPT / DEBUG_MUTEXES /
#         DEBUG_RWSEMS / SLUB_DEBUG_ON / PAGE_POISONING 全部置 y。
#         这些 CONFIG 改变结构体布局（struct lockdep_map 在 LOCK_STAT=y 时
#         增加 cpu/ip 成员；struct lock 在 LOCKDEP=y 时嵌入 lockdep_map），
#         导致内核导出符号的 __kcrctab CRC 全部改变。
#         原厂 vendor_dlkm/odm_dlkm 模块是用官方 GKI 的 CRC 编译的，
#         CONFIG_MODVERSIONS=y 且 MODULE_FORCE_LOAD=n 时会因
#         "disagrees about version of symbol" 被拒载 → 卡开机第一屏反复重启。
#      因此本脚本只往 gki_defconfig 里加"不改变现有结构体布局"的项。
#
#   3. 不修改 LOCALVERSION / LOCALVERSION_AUTO / MODULE_SCMVERSION。
#      版本字符串不影响 CRC（kernel/module.c same_magic() 在有 CRC 时忽略前缀），
#      改它反而是额外风险来源（关 LOCALVERSION_AUTO 需要连带删 MODULE_SCMVERSION）。
#
# 优化项（全部 CRC 安全）:
#   · SSG I/O 调度器   —— 纯新增 obj-y 代码，不 EXPORT_SYMBOL 现有符号
#   · LRNG v59         —— random/crypto/sched 的 drop-in 替换，导出签名不变
#   · USB autosuspend  —— 仅 Kconfig 数值
#   · ThinLTO          —— genksyms 基于预处理源码算 CRC，LTO 不参与
#
# 用法（在 repo 根目录执行）:
#     ROM_ROOT=$PWD bash scripts/apply-gki.sh
# 环境变量:
#     ROM_ROOT=<path>    默认 $(pwd)
# =============================================================================
set -eo pipefail
export LC_ALL=C

ROM_ROOT="${ROM_ROOT:-$(pwd)}"
KP="${KP:-$ROM_ROOT/kernel_platform}"
TREE="$KP/common"                     # GKI-only：只动 common/
CFG="$TREE/arch/arm64/configs/gki_defconfig"

WORK="${WORK:-/tmp/gki-patches}"
SRC="$WORK/src"
LOG="$WORK/log"

REJ_SCOPE="drivers/char crypto kernel/sched include/linux block"
GIT=(git -c 'safe.directory=*')

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo; echo "▶ $*"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }

find_rej() {
  local tree="$1"; shift
  local paths="" d
  for d in $REJ_SCOPE; do [ -d "$tree/$d" ] && paths="$paths $tree/$d"; done
  [ -n "$paths" ] || paths="$tree"
  find $paths -name '*.rej' "$@" 2>/dev/null || true
}

fetch() {
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

apply_patch() {
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

collect_rejects() {
  local tree="$1" tag="${2:-lrng}" d="$LOG/rejects-$tag" r rel
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
[ -d "$KP" ]   || die "找不到 kernel_platform: $KP（在 repo 根目录执行）"
[ -d "$TREE" ] || die "找不到 common 树: $TREE"
[ -f "$CFG" ]  || die "找不到 gki_defconfig: $CFG"
command -v git  >/dev/null || die "需要 git"
command -v curl >/dev/null || die "需要 curl"

cat <<EOF
==============================================================
 ROM_ROOT = $ROM_ROOT
 目标树    = common（GKI-only，不跑 vendor 趟）
 配置      = ${CFG#$KP/}
 方式      = 直接改 gki_defconfig，不叠加 consolidate.fragment
             （保持 LOCKDEP/DEBUG_OBJECTS 等 = n，确保与官方 CRC 一致）
==============================================================
EOF

# ===========================================================================
# PART 1：SSG → common/block/
# ===========================================================================
info "PART 1 / SSG → common/"
SSG_PATCH="$SRC/ssg-f03f1386.patch"
if [ -f "$TREE/block/ssg-iosched.c" ]; then
  ok "SSG 已应用，跳过"
else
  fetch "https://github.com/acuicultor/RadioactiveKernel_Pantah/commit/f03f138612bb4b4517efb33d82a29d38a42fd038.patch" "$SSG_PATCH"
  ok "已下载 $(basename "$SSG_PATCH") ($(wc -c < "$SSG_PATCH") 字节)"
  "${GIT[@]}" -C "$TREE" apply -p1 "$SSG_PATCH"
  ok "已应用"
fi
[ -f "$TREE/block/ssg-iosched.c" ] || die "SSG 校验失败: block/ssg-iosched.c 缺失"
[ -f "$TREE/block/ssg-cgroup.c" ]  || die "SSG 校验失败: block/ssg-cgroup.c 缺失"
[ -f "$TREE/block/ssg-cgroup.h" ]  || die "SSG 校验失败: block/ssg-cgroup.h 缺失"
grep -q 'MQ_IOSCHED_SSG' "$TREE/block/Kconfig.iosched" || die "SSG 校验失败: Kconfig.iosched 未接线"
grep -q 'ssg-iosched.o'  "$TREE/block/Makefile"        || die "SSG 校验失败: Makefile 未接线"
ok "SSG 校验通过"

# ===========================================================================
# PART 2：LRNG v59 → common/
# ===========================================================================
info "PART 2 / LRNG v59 → common/"
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
  die "前置补丁应用失败（common/kernel/sched/core.c 上下文不匹配）"
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
    find_rej "$TREE" -print 2>/dev/null | sed "s|^$TREE/||;s|\.rej$||" >> "$REJ_SEEN"
    find_rej "$TREE" -exec sh -c 'echo "--- $1"; head -25 "$1"' _ {} \; >> "$LOG/series-rejects.log" 2>&1 || true
    collect_rejects "$TREE" lrng
  fi
done
ok "主系列完成: ${#SERIES[@]} 补丁 | 部分被拒 $N_PARTIAL | 完全失败 $N_FAILED"
[ "$N_FAILED" -eq 0 ] || die "主系列有 $N_FAILED 个补丁完全失败，见 $LOG/series-rejects.log"

ACTUAL="$(sort -u "$REJ_SEEN" | tr '\n' ' ' | sed 's/ *$//')"
if [ "$ACTUAL" != "$EXPECTED_REJECTS" ]; then
  warn "被拒文件集合与预期不符（手工改基仍会尝试，请复核 $LOG/series-rejects.log）"
  echo "        预期: $EXPECTED_REJECTS"
  echo "        实际: $ACTUAL"
else
  ok "被拒文件集合与预期一致（4 个 hunk）"
fi

# --- 2.3 四处手工改基 ---------------------------------------------------
info "手工改基 1/4: drivers/char/Kconfig"
KCONFIG_F="$TREE/drivers/char/Kconfig"
[ -f "$KCONFIG_F" ] || die "找不到 $KCONFIG_F"
if grep -qF 'source "drivers/char/lrng/Kconfig"' "$KCONFIG_F"; then
  ok "已存在，跳过"
else
  LAST_EM="$(awk '/^endmenu$/{n=NR} END{print n}' "$KCONFIG_F")"
  [ -n "${LAST_EM:-}" ] && [ "$LAST_EM" -gt 0 ] || die "找不到顶层 endmenu: $KCONFIG_F"
  awk -v n="$LAST_EM" 'NR==n{print "source \"drivers/char/lrng/Kconfig\""; print ""} {print}' \
      "$KCONFIG_F" > "$KCONFIG_F.tmp" && mv "$KCONFIG_F.tmp" "$KCONFIG_F"
  ok "已在第 $LAST_EM 行（endmenu）前插入 source"
fi
grep -qF 'source "drivers/char/lrng/Kconfig"' "$KCONFIG_F" || die "Kconfig 接线失败"

info "手工改基 2/4: drivers/char/Makefile"
MAKEFILE_F="$TREE/drivers/char/Makefile"
[ -f "$MAKEFILE_F" ] || die "找不到 $MAKEFILE_F"
if grep -qF 'obj-$(CONFIG_LRNG)' "$MAKEFILE_F"; then
  ok "已存在，跳过"
else
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
grep -qF '#include <linux/lrng.h>' "$SCHED_F" || die "sched/core.c 未插入 lrng.h"
grep -qF 'add_sched_randomness'    "$SCHED_F" || warn "未见 add_sched_randomness（若未启用 CONFIG_LRNG_SCHED 可忽略）"

# --- 2.4 后置补丁 -------------------------------------------------------
BP_URL="https://raw.githubusercontent.com/smuellerDD/lrng/v59/backports/v59-5.10.236"
info "后置: v59-09（官方补丁优先，失败则手工 rebase 4 行）"
P09="$SRC/v59-09-revert-split-random_init.patch"
[ -s "$P09" ] || fetch "$BP_URL/v59-09-revert-split-random_init.patch" "$P09"
LRNG_RK="$TREE/drivers/char/lrng/lrng_interface_random_kernel.c"
[ -f "$LRNG_RK" ] || die "找不到 $LRNG_RK（主系列未正确落盘？）"
if "${GIT[@]}" -C "$TREE" apply --check -p1 "$P09" >/dev/null 2>&1; then
  "${GIT[@]}" -C "$TREE" apply -p1 "$P09"; ok "v59-09 直接应用"
elif grep -q '^int __init random_init(const char \*command_line)$' "$LRNG_RK"; then
  ok "v59-09 效果已存在，跳过"
else
  warn "v59-09 上下文不匹配 → 等价手工 rebase（4 行）"
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
    warn "$name 未干净应用"
    find_rej "$TREE" -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; >> "$LOG/series-rejects.log" 2>&1 || true
    collect_rejects "$TREE" lrng
  fi
done
[ "$POST_FAIL" -eq 0 ] || die "后置补丁有 $POST_FAIL 个未干净应用"

cat > "$LOG/SKIPPED.txt" <<'EOF'
刻意跳过的两个后置补丁（与 v59 源码形态不符）：
  v59-05-sysctl.patch                  —— v59 源码仍是旧形态，保留 device_initcall 才是正确的
  v59-06-add_random_ready_callbacks.patch —— v59 已改用 ATOMIC_NOTIFIER_HEAD
EOF
ok "跳过 05/06 的理由已记录: $LOG/SKIPPED.txt"

fi  # LRNG_DONE

[ -f "$TREE/include/linux/lrng.h" ]            || die "LRNG 校验失败: include/linux/lrng.h 缺失"
[ -f "$TREE/drivers/char/lrng/lrng_es_mgr.c" ] || die "LRNG 校验失败: lrng_es_mgr.c 缺失"
N_LRNG="$(ls "$TREE/drivers/char/lrng" | wc -l | tr -d ' ')"
[ "$N_LRNG" -eq 55 ] || die "LRNG 校验失败: drivers/char/lrng 文件数 $N_LRNG（期望 55）"
grep -qF 'source "drivers/char/lrng/Kconfig"' "$TREE/drivers/char/Kconfig"  || die "LRNG 校验失败: Kconfig 未接线"
grep -qF 'obj-$(CONFIG_LRNG)'                 "$TREE/drivers/char/Makefile" || die "LRNG 校验失败: Makefile 未接线"
ok "LRNG 校验通过（lrng/ 共 $N_LRNG 文件 + include/linux/lrng.h + 两处接线）"

# ===========================================================================
# PART 2.5：保持 gen-hyprel 为上游形态（撤销任何数字改写）
#
#   arch/arm64/kvm/hyp/nvhe/gen-hyprel.c:340 生成：
#       .reloc <off>, R_AARCH64_PREL32, <sym> + <off>
#
#   历史排查（2026-10-23）：
#     · 符号名 → "unknown relocation name"
#     · 数字 261 → "expected relocation name"
#   当时的真凶其实是【clang 版本选错】：workflow 用 ls|head -1 猜到了
#   clang-r383902（clang 11），它的集成汇编器不支持该 .reloc 形式，
#   同时也导致 LTO/CFI 被 Kconfig 静默关闭（那才是卡 logo 的根因）。
#   修正为官方 clang-r416183b（clang 12）后，LLVM_IAS=1 可正常汇编此文件，
#   与原厂内核构建方式一致（原厂 CONFIG_CLANG_VERSION=120005）。
#
#   因此这里只做一件事：确保源码是上游符号名形态（防止历史补丁残留）。
# ===========================================================================
info "PART 2.5 / 确保 gen-hyprel 为上游符号名形态"

HYPREC="$TREE/arch/arm64/kvm/hyp/nvhe/gen-hyprel.c"
if [ -f "$HYPREC" ]; then
  if grep -qF '.reloc %lu, 261, %s%s' "$HYPREC"; then
    sed -i 's|\.reloc %lu, 261, %s%s|.reloc %lu, R_AARCH64_PREL32, %s%s|' "$HYPREC"
    ok "gen-hyprel: 已恢复上游符号名形式"
  elif grep -qF '.reloc %lu, R_AARCH64_PREL32, %s%s' "$HYPREC"; then
    ok "gen-hyprel 已是上游符号名形式"
  else
    warn "gen-hyprel.c 未匹配到预期格式串（内核版本可能不同），继续"
  fi
  grep -qF '.reloc %lu, R_AARCH64_PREL32, %s%s' "$HYPREC" \
    || die "gen-hyprel 未处于上游形态"
  ok "gen-hyprel 校验通过（符号名，配合 GNU as）"
else
  warn "找不到 gen-hyprel.c（本内核可能不使用 nVHE hyp），跳过"
fi

# ===========================================================================
# PART 3：功能配置 → common/arch/arm64/configs/gki_defconfig
# ===========================================================================
info "PART 3 / 功能配置 → ${CFG#$KP/}"
BEFORE="$(wc -l < "$CFG" | tr -d ' ')"
append_unique "$CFG" 'CONFIG_USB_AUTOSUSPEND_DELAY=5'
append_unique "$CFG" 'CONFIG_MQ_IOSCHED_SSG=y'
append_unique "$CFG" 'CONFIG_MQ_IOSCHED_SSG_CGROUP=y'
append_unique "$CFG" 'CONFIG_LRNG=y'
AFTER="$(wc -l < "$CFG" | tr -d ' ')"
ok "行数 $BEFORE → $AFTER"

# ===========================================================================
# PART 4：CRC 安全校验（决定能否只刷 boot）
#
#   这些符号的取值必须与官方 GKI 一致：
#     必须 = y : KASAN（官方 gki_defconfig 就是 y，去掉会改变插桩布局）
#     必须 ≠ y : LOCKDEP / LOCK_STAT / DEBUG_LOCK_ALLOC / DEBUG_OBJECTS /
#                DEBUG_SPINLOCK / DEBUG_PREEMPT / DEBUG_MUTEXES / DEBUG_RWSEMS /
#                SLUB_DEBUG_ON / PAGE_POISONING
#   任何一项被置 y，struct lockdep_map / struct lock / timer_list / work_struct
#   的布局就会变化 → 导出符号 CRC 变化 → 原厂模块全部拒载 → 卡开机第一屏。
# ===========================================================================
info "PART 4 / CRC 安全校验"

MUST_Y='KASAN'
MUST_NOT_Y='LOCKDEP LOCK_STAT DEBUG_LOCK_ALLOC DEBUG_OBJECTS DEBUG_SPINLOCK DEBUG_PREEMPT DEBUG_MUTEXES DEBUG_RWSEMS SLUB_DEBUG_ON PAGE_POISONING'

for c in $MUST_Y; do
  if grep -qx "CONFIG_${c}=y" "$CFG"; then
    ok "CONFIG_${c}=y（与官方一致）"
  else
    die "CONFIG_${c} 未设为 y —— 会改变插桩布局，CRC 与官方不一致"
  fi
done

for c in $MUST_NOT_Y; do
  if grep -qx "CONFIG_${c}=y" "$CFG"; then
    die "CONFIG_${c}=y 被置为 y —— 会改变结构体布局，CRC 与官方不一致（必须移除）"
  fi
done
ok "CRC 敏感项全部符合要求（10 项）、KASAN=y"

# ---- CFI / LTO 守护 ------------------------------------------------------
# 原厂内核（从出厂 boot.img 提取）为：
#   CONFIG_CLANG_VERSION=120005  CONFIG_LTO_CLANG_FULL=y
#   CONFIG_CFI_CLANG=y           CONFIG_SHADOW_CALL_STACK=y
# CFI_CLANG 丢失时 kernel/module.c:4535 的
#   __cfi_jt_init_module / __cfi_jt_cleanup_module 修正不会执行，
#   原厂 CFI 模块无法加载 → 卡 logo 重启。这里守住 defconfig 里的这三项，
#   运行期的 CLANG_VERSION/LTO 由 workflow 在 olddefconfig 后复查。
for c in CFI_CLANG SHADOW_CALL_STACK LTO_CLANG_FULL VIRTUALIZATION KVM; do
  if grep -qx "CONFIG_${c}=y" "$CFG"; then
    ok "CONFIG_${c}=y（与原厂一致）"
  else
    die "CONFIG_${c} 必须在 gki_defconfig 中为 y（原厂为 y，缺失会导致 LTO/CFI 链路断裂）"
  fi
done

# 记录基线，供 CI 复核
{
  echo "# CRC 安全基线（apply-gki.sh 生成）"
  for c in $MUST_Y; do grep -m1 "^CONFIG_${c}=" "$CFG" || true; done
  for c in $MUST_NOT_Y; do echo "# CONFIG_${c} is not set"; done
} > "$LOG/crc-baseline.txt"
ok "基线已写出: $LOG/crc-baseline.txt"

# ===========================================================================
# 收尾
# ===========================================================================
echo
cat <<EOF
==============================================================
 完成（GKI-only）
   SSG  : common/block/ssg-*.{c,h} + 接线
   LRNG : common/drivers/char/lrng/（$N_LRNG 文件）+ include/linux/lrng.h
   配置 : ${CFG#$KP/}（$AFTER 行）
   日志 : $LOG/
 下一步由 workflow 执行：
   cd kernel_platform/common
   make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 gki_defconfig
   scripts/config --file out/.config -e LTO_CLANG -e LTO_CLANG_THIN -d LTO_CLANG_FULL -d LTO_CLANG_NONE
   make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
   make -j\$(nproc) O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 Image
==============================================================
EOF
