### AnyKernel3 配置 —— Redmi K60 / POCO F5 Pro (mondrian)
### 由 GitHub Actions 自动生成，请勿在设备上手动修改本文件

properties() { '
kernel.string=Redmi K60 (mondrian) Kernel | SukiSU Ultra + KPM + BBG
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=mondrian
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

### boot.img 参数
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# 载入 AnyKernel3 核心函数
. tools/ak3-core.sh;

# split_boot = 只拆分镜像，不解包 ramdisk
# flash_boot = 只重组并写入 boot.img，不改 ramdisk
# （SukiSU 已编入内核，无需 ramdisk 补丁，这样最安全）
split_boot;
flash_boot;
