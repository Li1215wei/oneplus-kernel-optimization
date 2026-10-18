### AnyKernel3 Ramdisk Mod Script
### OnePlus 10T / Ace Pro (PGP110, SM8475) —— 优化内核（纯 boot 模式）
## 基于 osm0sis @ xda-developers 的 AnyKernel3（https://github.com/osm0sis/AnyKernel3）
##
## ★ 本包只写 boot，绝不触碰任何其他分区 ★
##
## 为什么可以只刷 boot：
##   本内核完整保留了所有影响符号 CRC 的 CONFIG（KASAN / KASAN_HW_TAGS / KFENCE /
##   PAGE_OWNER / UBSAN / LOCKDEP / DEBUG_OBJECTS …）。genksyms 基于「源码签名 +
##   #ifdef 预处理结果」计算 __kcrctab（common/scripts/Makefile.build:298），
##   这些取值与原厂一致 ⇒ 导出的符号 CRC 与原厂一致
##   ⇒ 原厂 vendor_dlkm / odm_dlkm 里的模块可正常加载，无需刷新。
##
## 反之（历史教训）：一旦删除上述任一 CONFIG，CRC 改变，原厂模块会因
##   "disagrees about version of symbol" 被 kernel/module.c 拒绝加载
##   （CONFIG_MODVERSIONS=y 且 MODULE_FORCE_LOAD=n），
##   其中 odm_dlkm 含 binder/ext4/f2fs/erofs/usbcore 等启动必需模块，
##   会导致卡第一屏并反复重启。
##
## 本内核所做的优化都不会改变导出的符号签名：
##   - ThinLTO：genksyms 只喂编译器 .s 输出，不参与 LTO 优化
##   - SSG I/O 调度器：纯新增 obj-y 代码，不 EXPORT_SYMBOL
##   - LRNG v59：改动限 random/crypto/sched，导出签名不变
##   - USB_AUTOSUSPEND_DELAY=5：仅配置值
##   - 删除 DEBUG_INFO：只去掉 .debug_* 段，不改变任何 #ifdef 分支
##
## 注意：AK3 的 write_boot 内部会处理 super 里的逻辑分区（历史刷机日志中可见
##   "/dev/block/mapper/vendor_dlkm_a" 与 "vendor_dlkm_a replaced in super"）。
##   那是 AK3/Magisk 在检测到逻辑分区时的固有行为，用于让新的 boot 正常启动；
##   它写入的内容来自它自己备份/重建的逻辑分区，本包不额外提供也不再改写
##   odm_dlkm —— 与本内核保持 CRC 兼容的原厂模块可继续使用。

properties() { '
kernel.string=PGP110 Optimized Kernel (ThinLTO + LRNG v59 + SSG) [boot only]
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=OnePlus10T
device.name2=PGP110
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
'; } # end properties


boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes


# boot shell variables
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

ui_print " ";
ui_print " ============================================";
ui_print "  纯 boot 模式：只写 boot 分区";
ui_print "  vendor_dlkm / odm_dlkm / dtbo 全部不动";
ui_print " ============================================";
ui_print " ";

# ---- 仅安装 boot：内核 + ramdisk ----
dump_boot;
write_boot;

ui_print " ";
ui_print " 完成。其他分区未被修改。";
ui_print " 请重启（首次开机较慢，属正常）。";
