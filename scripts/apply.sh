#!/usr/bin/env bash
# =============================================================================
# apply.sh —— 内核优化补丁应用（v8 · 纯 boot 模式）
#   目标机型: OnePlus Ace Pro (PGP110 / SM8475)
#   代码基线: android12-5.10 / linux-5.10.236
#
# ★ 本版本核心约束：只刷 boot，绝不修改 vendor_dlkm / odm_dlkm
#
#   原厂模块的 __kcrctab CRC 由 genksyms 基于「源码签名 + CONFIG #ifdef 的预处理
#   结果」计算（common/scripts/Makefile.build:298）。kernel/module.c 在
#   CONFIG_MODVERSIONS=y 且 MODULE_FORCE_LOAD=n 时，CRC 不符即拒绝加载
#   （"disagrees about version of symbol"）。
#
#   ⇒ 任何改变 #ifdef 预处理结果的 CONFIG 都不可删除，否则原厂模块全部拒载，
#     odm_dlkm 中的 binder/ext4/f2fs/erofs/usbcore 加载失败 → 卡第一屏反复重启。
#   ⇒ 实测对照 ColorArchive：其 KASAN/KASAN_HW_TAGS/KFENCE/PAGE_OWNER 全部 =y，
#     故 CRC 与原厂一致，只刷 boot 即可开机。
#
# 优化项（全部兼容纯 boot）:
#   1. ThinLTO          —— 构建参数 export LTO=thin。genksyms 只喂编译器 .s 输出，
#                          不参与 LTO 优化 → 导出符号 CRC 不变
#   2. LRNG v59         —— 打入 common/。改动限 random/crypto/sched，导出签名不变
#   3. SSG I/O 调度器    —— 打入 common/。纯新增 obj-y 代码，不 EXPORT_SYMBOL
#   4. USB 省电         —— CONFIG_USB_AUTOSUSPEND_DELAY=5（仅 cmdline/配置值）
#   5. DEBUG_INFO       —— 可选删除（PART 3.5）。只产生 .debug_* 段，不进 Image，
#                          不影响 CRC；收益仅限 vmlinux 体积
#   6. KVM              —— 原仓库已开启（CONFIG_VIRTUALIZATION=y + CONFIG_KVM=y），不动
#   ❌ TEO              —— 不改：保持 qcom-cpu-lpm（原厂集群 LPM 感知）
#   ❌ 关闭插桩          —— 放弃：KASAN/KFENCE/PAGE_OWNER/UBSAN/LOCKDEP/DEBUG_OBJECTS
#                          等全部保留，否则 CRC 改变导致无法只刷 boot
#
# ⚠️ 必须用 VARIANT=consolidate（默认值）构建：
#    - consolidate 的 GKI 趟 POST_DEFCONFIG_CMDS 被 gki_consolidate.aarch64 覆盖为 rm，
#      不跑 check_defconfig → 配置可自由改动
#    - VARIANT=gki 会跑 check_defconfig，且 build/build.sh:357 有全局 set -e
#      → 配置与 savedefconfig 不一致时构建直接中止
#
# ⚠️ PART 3.5 为什么用「删除行」而不是「# CONFIG_X is not set」：
#    写 "not set" 会让子选项变成「不可见符号」→ 从 .config 消失，却仍留在合并后的
#    defconfig 里 → vendor 趟 check_merged_defconfig 输出 "-符号" → exit 1 → 构建中止。
#    删除行则只会在 .config 侧多出 "+符号"（允许），不会触发该守卫。
#
# 用法（在 repo/ROM 根目录执行）:
#     ROM_ROOT=$PWD bash scripts/apply.sh
# 环境变量:
#     ROM_ROOT=<path>    默认 $(pwd)
#     RUN_BUILD=1        默认 0（只应用补丁+配置，不编译）
#     LTO_MODE=thin      仅用于打印提示
#     POWER_LEAN=0|1     默认 1；置 0 则保留 DEBUG_INFO（vmlinux 更大）
# =============================================================================
set -eo pipefail
export LC_ALL=C

ROM_ROOT="${ROM_ROOT:-$(pwd)}"
KP="${KP:-$ROM_ROOT/kernel_platform}"

TREE_NAME="${TREE_NAME:-common}"
TREE="$KP/$TREE_NAME"

CFG_GKI="${CFG_GKI:-$KP/common/arch/arm64/configs/gki_defconfig}"
GKI_VENDOR="$KP/msm-kernel/arch/arm64/configs/gki_defconfig"
FRAG="${FRAG:-$KP/common/arch/arm64/configs/consolidate.fragment}"

LTO_MODE="${LTO_MODE:-thin}"
RUN_BUILD="${RUN_BUILD:-0}"
POWER_LEAN="${POWER_LEAN:-1}"

WORK="${WORK:-/tmp/lrng-ssg-patches}"
SRC="$WORK/src"
LOG="$WORK/log"

REJ_SCOPE="drivers/char crypto kernel/sched include/linux block"

GIT=(git -c 'safe.directory=*')

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo; echo "▶ $*"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
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
[ -d "$KP" ]        || die "找不到 kernel_platform: $KP（在 repo 根目录执行）"
[ -d "$TREE" ]      || die "找不到目标树: $TREE"
[ -f "$CFG_GKI" ]   || die "找不到 GKI 配置: $CFG_GKI"
[ -f "$GKI_VENDOR" ]|| die "找不到 vendor GKI 配置: $GKI_VENDOR"
[ -f "$FRAG" ]      || die "找不到 consolidate fragment: $FRAG"
command -v git  >/dev/null || die "需要 git"
command -v curl >/dev/null || die "需要 curl"

cat <<EOF
==============================================================
 ROM_ROOT   = $ROM_ROOT
 kernel_plat= $KP
 目标树      = $TREE_NAME  ($TREE)
 配置①       = ${CFG_GKI#$KP/}    (LRNG/SSG/USB)
 配置②       = ${FRAG#$KP/}   (调试项删除)
 插桩删除    = 两个 gki_defconfig 同步删除
 LTO         = $LTO_MODE
 POWER_LEAN  = $POWER_LEAN
 RUN_BUILD   = $RUN_BUILD
 ⚠️ 请用 VARIANT=consolidate 构建
==============================================================
EOF

# ===========================================================================
# PART 1：SSG → common/
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
# PART 2：LRNG v59 → common/
# ===========================================================================
info "PART 2 / LRNG v59 → $TREE_NAME/"
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
  warn "被拒文件集合与预期不符（手工改基仍会尝试，请复核 $LOG/series-rejects.log）"
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
  LAST_EM="$(awk '/^endmenu$/{n=NR} END{print n}' "$KCONFIG_F")"
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
[ "$POST_FAIL" -eq 0 ] || die "后置补丁有 $POST_FAIL 个未干净应用，见 $LOG/series-rejects.log"

cat > "$LOG/SKIPPED.txt" <<'EOF'
刻意跳过的两个后置补丁：

v59-05-sysctl.patch
    期望把 lrng_sysctl.c 的 random_table[] 改为非 static 并删除
    random_sysctls_init()/device_initcall()。v59 源码仍是旧形态
    （lrng_sysctl.c:89 static、:134/:139 device_initcall），该补丁面向
    "更新内核把 sysctl 注册搬到别处" 的场景 → 对 5.10.236 应跳过。

v59-06-add_random_ready_callbacks.patch
    要求新增 RAW_NOTIFIER_HEAD(lrng_ready_chain) 一整套 API；v59 源码
    已改用 ATOMIC_NOTIFIER_HEAD(random_ready_notifier)
    （lrng_interface_random_kernel.c:22）→ 过时实现，跳过。
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
# PART 3：功能配置 → common/gki_defconfig
# ===========================================================================
info "PART 3 / 功能配置 → ${CFG_GKI#$KP/}"
BEFORE="$(wc -l < "$CFG_GKI" | tr -d ' ')"
append_unique "$CFG_GKI" 'CONFIG_USB_AUTOSUSPEND_DELAY=5'
append_unique "$CFG_GKI" 'CONFIG_MQ_IOSCHED_SSG=y'
append_unique "$CFG_GKI" 'CONFIG_MQ_IOSCHED_SSG_CGROUP=y'
append_unique "$CFG_GKI" 'CONFIG_LRNG=y'
AFTER="$(wc -l < "$CFG_GKI" | tr -d ' ')"
ok "行数 $BEFORE → $AFTER"
cat <<'NOTE'
      说明：LRNG/SSG 的源码只打在 common/，且这两个符号在 msm-kernel 的 Kconfig 里不存在；
      若写进两趟共享的 consolidate.fragment，vendor 趟会因"-符号"而 exit 1。
      故写入仅 GKI 趟读取的 common/gki_defconfig。
NOTE

# ===========================================================================
# PART 3.5：可选 —— 仅删除 DEBUG_INFO（不改变符号 CRC）
#
# ⚠️ 纯 boot 约束（只刷 boot，绝不刷 vendor_dlkm / odm_dlkm）：
#    原厂模块的 __kcrctab CRC 由 genksyms 基于「源码签名 + CONFIG #ifdef 的
#    预处理结果」算出（common/scripts/Makefile.build:298 —— genksyms 只喂
#    编译器的 .s 输出，不参与 LTO 优化）。因此：
#
#      改变 CRC（必须保留）：
#        KASAN / KASAN_HW_TAGS / KFENCE / PAGE_OWNER / UBSAN* / LOCKDEP /
#        LOCK_STAT / DEBUG_LOCK_ALLOC / DEBUG_MUTEXES / DEBUG_RT_MUTEXES /
#        DEBUG_RWSEMS / DEBUG_SPINLOCK / DEBUG_OBJECTS* / DEBUG_PREEMPT /
#        SLUB_DEBUG_ON / PAGE_POISONING / DYNAMIC_DEBUG / KUNIT
#
#      不改变 CRC（可安全删除）：
#        DEBUG_INFO / DEBUG_INFO_DWARF4 —— 只生成 .debug_* 段，不进 Image，
#        不改变任何 #ifdef 分支
#
#    实测对照（ColorArchive 自制内核）：其 CONFIG_KASAN=y、KASAN_HW_TAGS=y、
#    KFENCE=y、PAGE_OWNER=y 全部保留，故 CRC 与原厂一致，只刷 boot 即可开机；
#    一旦删除这些项，原厂模块会因 "disagrees about version of symbol" 被
#    kernel/module.c 拒绝加载（CONFIG_MODVERSIONS=y 且 MODULE_FORCE_LOAD=n）。
#
#    注意：Image 是只含 .text/.data/.rodata 的裸二进制，.debug_* 段只在
#    vmlinux 里。因此删 DEBUG_INFO 不会缩小 Image，运行时性能与功耗均无变化；
#    这一项只是为了减小 vmlinux 体积。POWER_LEAN=0 可完全跳过。
# ===========================================================================
if [ "${POWER_LEAN:-1}" = "1" ]; then

info "PART 3.5 / 仅删除 DEBUG_INFO（不影响符号 CRC）"

DI_PAT='^#? ?CONFIG_DEBUG_INFO(_DWARF4)?=y'
for g in "$CFG_GKI" "$GKI_VENDOR"; do
  [ -f "$g" ] || die "找不到 $g"
  if grep -qE "$DI_PAT" "$g"; then
    n=$(grep -cE "$DI_PAT" "$g")
    awk -v p="$DI_PAT" '$0 ~ p {next} {print}' "$g" > "$g.tmp" && mv "$g.tmp" "$g"
    ok "已从 ${g#$KP/} 删除 $n 行 DEBUG_INFO"
  else
    ok "${g#$KP/} 无 DEBUG_INFO，跳过"
  fi
done

# ---- 反向校验：CRC 相关配置必须一个不少 --------------------------------
# 纯 boot 方案的唯一正确性依据：这些符号的 CONFIG 取值与原厂完全一致。
CRC_GUARD='CONFIG_(KASAN|KASAN_HW_TAGS|KFENCE|PAGE_OWNER|UBSAN|UBSAN_TRAP|UBSAN_LOCAL_BOUNDS|LOCKDEP|LOCK_STAT|DEBUG_LOCK_ALLOC|DEBUG_OBJECTS|DEBUG_PREEMPT|DEBUG_SPINLOCK|DEBUG_MUTEXES|DEBUG_RT_MUTEXES|DEBUG_RWSEMS|SLUB_DEBUG_ON|PAGE_POISONING|DYNAMIC_DEBUG|KUNIT)=y'
for g in "$CFG_GKI" "$GKI_VENDOR"; do
  n=$(grep -cE "^${CRC_GUARD}$" "$g")
  if [ "$n" -gt 0 ]; then
    ok "${g#$KP/} CRC 相关配置保留完好（$n 项为 y）"
  else
    die "${g#$KP/} 未找到 CRC 相关配置，无法确认纯 boot 安全性"
  fi
done

# consolidate.fragment 里也不能删任何调试项（它们同样影响 CRC）
if grep -qE '^CONFIG_(DEBUG_|LOCKDEP|LOCK_STAT|SLUB_DEBUG_ON|PAGE_POISONING|DYNAMIC_DEBUG|KUNIT)' "$FRAG"; then
  ok "consolidate.fragment 调试项完整保留（纯 boot 要求）"
else
  die "consolidate.fragment 的调试项被删除，会改变 CRC"
fi

ok "PART 3.5 校验通过（只删了 DEBUG_INFO，CRC 未受影响）"

else
  warn "POWER_LEAN=0 → 跳过 PART 3.5（保留 DEBUG_INFO）"
fi

# ===========================================================================
# PART 3.6：统一版本字符串（关闭 LOCALVERSION_AUTO）
#
#   CONFIG_LOCALVERSION_AUTO 默认 y（common/init/Kconfig:180-183），
#   common/scripts/setlocalversion:208-210 会追加所在 git 仓库 HEAD 的短哈希。
#   而 GKI 趟在 common/ 编译、vendor 趟在 msm-kernel/ 编译 —— 两个独立仓库，
#   HEAD 天然不同，于是：
#       内核 Image : 5.10.236-qki-consolidate-android12-9-o-gc076c7357bf1-dirty
#       全部模块   : 5.10.236-qki-consolidate-g9f869b57a717-dirty
#
#   注意：MODVERSIONS=y 时内核会忽略 vermagic 的版本前缀
#   （kernel/module.c:1378-1387 same_magic() 跳过空格前部分），
#   所以字符串不一致 "本身" 不致命；统一它是为了便于用 uname -r 判断版本、
#   并让 CI 的 vermagic 校验可读。真正的兼容性由 __kcrctab CRC 决定。
# ===========================================================================
info "PART 3.6 / 统一版本字符串（关闭 LOCALVERSION_AUTO）"

VFLAG='# CONFIG_LOCALVERSION_AUTO is not set'
for g in "$CFG_GKI" "$GKI_VENDOR"; do
  [ -f "$g" ] || die "找不到 $g"
  if grep -qxF "$VFLAG" "$g"; then
    ok "${g#$KP/} 已关闭，跳过"
  elif grep -qx 'CONFIG_LOCALVERSION_AUTO=y' "$g"; then
    awk '{ if ($0 == "CONFIG_LOCALVERSION_AUTO=y") print "# CONFIG_LOCALVERSION_AUTO is not set"; else print }' \
        "$g" > "$g.tmp" && mv "$g.tmp" "$g"
    ok "${g#$KP/} 已改为 not set"
  else
    printf '%s\n' "$VFLAG" >> "$g"
    ok "${g#$KP/} 已追加 not set"
  fi
done

for g in "$CFG_GKI" "$GKI_VENDOR"; do
  grep -qxF "$VFLAG" "$g" || die "LOCALVERSION_AUTO 未关闭: $g"
done
ok "PART 3.6 校验通过（两趟都不会追加 git 哈希）"

# ===========================================================================
# PART 4：ThinLTO 构建参数（不改文件）
# ===========================================================================
info "PART 4 / ThinLTO 构建参数"
cat <<EOF
--------------------------------------------------------------
 构建命令（workflow 中单独一步执行）：
   cd $ROM_ROOT
   export LTO=${LTO_MODE}
   ./kernel_platform/build/android/prepare_vendor.sh waipio consolidate

 ⚠️ 本 manifest 无 vendor/oplus，因此不能用 oplus_build_kernel.sh
    （其 build_cmd 硬 source vendor/oplus/kernel/prebuilt/vendorsetup.sh）
 ⚠️ 必须用 consolidate（默认变体）：VARIANT=gki 会跑 check_defconfig，
    配合 build.sh:357 的 set -e，配置不一致会直接中止构建。
 ⚠️ 必须 export LTO=${LTO_MODE}，否则回落 defconfig 的 FULL LTO。
--------------------------------------------------------------
EOF
if [ "$RUN_BUILD" = "1" ]; then
  ( cd "$ROM_ROOT" \
    && export LTO="${LTO_MODE}" \
    && export TOPDIR="$ROM_ROOT" ANDROID_BUILD_TOP="$ROM_ROOT" \
    && export TARGET_BOARD_PLATFORM=taro \
    && export ANDROID_PRODUCT_OUT="$ROM_ROOT/out/target/product/taro" \
    && export CHIPSET_COMPANY=QCOM OPLUS_VND_BUILD_PLATFORM=SM8475 \
    && mkdir -p "$ANDROID_PRODUCT_OUT" \
    && ./kernel_platform/build/android/prepare_vendor.sh waipio consolidate )
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
   配置①: ${CFG_GKI#$KP/} ($AFTER 行: USB/SSG/LRNG)
   配置②: ${FRAG#$KP/}（调试项已删除，POWER_LEAN=$POWER_LEAN）
   插桩 : 两个 gki_defconfig 已删除 KASAN/KFENCE/UBSAN/PAGE_OWNER/DEBUG_INFO
   KVM  : 未改动（原仓库已开启 CONFIG_VIRTUALIZATION=y + CONFIG_KVM=y）
   cpuidle: 未改动（保持 qcom-cpu-lpm 原厂行为）
   日志 : $LOG/
   LTO  : $LTO_MODE
==============================================================
EOF
