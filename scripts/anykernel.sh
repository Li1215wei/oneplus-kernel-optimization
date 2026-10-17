### AnyKernel3 Ramdisk Mod Script
### OnePlus 10T / Ace Pro (PGP110, SM8475) —— 优化内核
## 基于 osm0sis @ xda-developers 的 AnyKernel3（https://github.com/osm0sis/AnyKernel3）

properties() { '
kernel.string=PGP110 Optimized Kernel (ThinLTO + LRNG v59 + SSG + power-lean)
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

### 额外分区写入
# 本内核删除了 KASAN/KFENCE/UBSAN 插桩，stock vendor_dlkm 里的 .ko 会引用
# 已不存在的 __asan_* 等符号而加载失败 → 必须同步写入本次构建的 vendor_dlkm/odm_dlkm。
flash_partition() {
  local name="$1" file="$2" part
  part="/dev/block/bootdevice/by-name/${name}${SLOT}"
  [ -e "$part" ] || part="/dev/block/bootdevice/by-name/${name}"
  if [ ! -e "$part" ]; then
    ui_print "  ! 找不到 ${name} 分区，跳过"
    return 0
  fi
  if [ ! -f "$AKHOME/$file" ]; then
    ui_print "  - 未打包 ${file}，跳过"
    return 0
  fi
  ui_print "  - 写入 ${name}  ($(du -h "$AKHOME/$file" 2>/dev/null | cut -f1))"
  dd if="$AKHOME/$file" of="$part" bs=1048576 2>/dev/null || {
    ui_print "  ! ${name} 写入失败"; return 1; }
  sync
  return 0
}

# boot install
dump_boot;
write_boot;
## end boot install

### 模块分区（必须与内核同时更新）
flash_partition vendor_dlkm vendor_dlkm.img
flash_partition odm_dlkm   odm_dlkm.img

### dtbo 未做 DT 改动，默认不刷（需要时取消注释）
# flash_partition dtbo       dtbo.img

ui_print " ";
ui_print " 完成，请重启。首次开机较慢属正常。";
