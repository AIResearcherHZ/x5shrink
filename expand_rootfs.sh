#!/bin/bash
###
# X5 Rootfs 扩展脚本
# 用于手动扩展 RDK X5 的 rootfs 分区到磁盘最大容量
# 适用于自动扩展脚本未成功执行的情况
###

set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 需要 root 权限运行此脚本"
    echo "请使用: sudo $0"
    exit 1
fi

echo "=========================================="
echo "  RDK X5 Rootfs 分区扩展工具"
echo "=========================================="
echo

# 获取根分区信息
ROOT_PART=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p')
if [ -z "$ROOT_PART" ]; then
    echo "[错误] 无法检测根分区"
    exit 1
fi

# 检测设备类型
if [[ "$ROOT_PART" == mmcblk* ]]; then
    DEVICE="/dev/${ROOT_PART%p*}"
    PART_NUM="${ROOT_PART##*p}"
elif [[ "$ROOT_PART" == sd* ]]; then
    DEVICE="/dev/${ROOT_PART%[0-9]*}"
    PART_NUM="${ROOT_PART##*[a-z]}"
else
    echo "[错误] 无法识别的设备类型: $ROOT_PART"
    exit 1
fi

echo "[信息] 根分区: /dev/$ROOT_PART"
echo "[信息] 设备: $DEVICE"
echo "[信息] 分区号: $PART_NUM"
echo

# 显示当前分区信息
echo "[当前分区布局]"
parted "$DEVICE" unit GB print free
echo

# 检查是否有未分配空间
FREE_SPACE=$(parted "$DEVICE" -ms unit B print free | grep "free" | tail -1 | cut -d: -f4 | tr -d 'B')
if [ -z "$FREE_SPACE" ] || [ "$FREE_SPACE" -lt 100000000 ]; then
    echo "[信息] 没有足够的未分配空间需要扩展"
    echo "[信息] 检查文件系统是否已扩展到分区大小..."
    
    # 检查文件系统是否需要扩展
    PART_SIZE=$(lsblk -b -n -o SIZE "/dev/$ROOT_PART")
    FS_SIZE=$(df -B1 "/dev/$ROOT_PART" | tail -1 | awk '{print $2}')
    
    if [ "$FS_SIZE" -lt "$((PART_SIZE - 100000000))" ]; then
        echo "[信息] 文件系统未完全扩展，正在扩展..."
        resize2fs "/dev/$ROOT_PART"
        echo "[成功] 文件系统扩展完成"
    else
        echo "[信息] 文件系统已是最大尺寸"
    fi
    
    echo
    echo "[最终磁盘使用情况]"
    df -h "/dev/$ROOT_PART"
    exit 0
fi

FREE_SPACE_GB=$(echo "scale=2; $FREE_SPACE / 1024 / 1024 / 1024" | bc)
echo "[信息] 检测到 ${FREE_SPACE_GB}GB 未分配空间"
echo

# 获取分区起始扇区
PART_START=$(parted "$DEVICE" -ms unit s p | grep "^${PART_NUM}:" | cut -d: -f2 | sed 's/s$//')
if [ -z "$PART_START" ]; then
    echo "[错误] 无法获取分区起始扇区"
    exit 1
fi

echo "[警告] 此操作将扩展 rootfs 分区"
echo "[警告] 虽然数据通常是安全的，但建议先备份重要数据"
echo
read -p "是否继续? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "操作已取消"
    exit 0
fi

echo
echo "[步骤 1/3] 扩展分区..."

# 使用 parted 扩展分区到磁盘末尾
parted -s "$DEVICE" resizepart "$PART_NUM" 100%

echo "[步骤 2/3] 通知内核分区表变化..."
partprobe "$DEVICE"
sleep 2

echo "[步骤 3/3] 扩展文件系统..."
resize2fs "/dev/$ROOT_PART"

echo
echo "=========================================="
echo "  扩展完成!"
echo "=========================================="
echo
echo "[最终磁盘使用情况]"
df -h "/dev/$ROOT_PART"
echo
echo "[最终分区布局]"
parted "$DEVICE" unit GB print

# 清理自动扩展脚本
if [ -f /etc/init.d/x5-autoexpand ]; then
    echo
    echo "[信息] 清理自动扩展脚本..."
    update-rc.d x5-autoexpand remove 2>/dev/null || true
    rm -f /etc/init.d/x5-autoexpand
    rm -f /etc/rcS.d/S01x5-autoexpand
    echo "[信息] 自动扩展脚本已清理"
fi

if [ -f /etc/init.d/x5-autoexpand-phase2 ]; then
    update-rc.d x5-autoexpand-phase2 remove 2>/dev/null || true
    rm -f /etc/init.d/x5-autoexpand-phase2
fi

echo
echo "[完成] rootfs 分区已成功扩展!"