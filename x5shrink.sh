#!/usr/bin/env bash

# Project: X5Shrink
# Description: X5Shrink 是一个用于压缩 RDK X5 系统镜像的脚本，
#              针对 RDK X5 的双分区结构 (FAT32 config + ext4 rootfs) 进行适配。
#              压缩后的镜像在首次启动时会自动扩展到 SD 卡的最大容量。
# Link: https://github.com/AIResearcherHZ/x5shrink

version="v1.0.0"

CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
MYNAME="${SCRIPTNAME%.*}"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"
REQUIRED_TOOLS="parted losetup tune2fs md5sum e2fsck resize2fs"
ZIPTOOLS=("gzip xz")
declare -A ZIP_PARALLEL_TOOL=( [gzip]="pigz" [xz]="xz" )
declare -A ZIP_PARALLEL_OPTIONS=( [gzip]="-f9" [xz]="-T0" )
declare -A ZIPEXTENSIONS=( [gzip]="gz" [xz]="xz" )

function info() {
    echo "$SCRIPTNAME: $1"
}

function error() {
    echo -n "$SCRIPTNAME: 错误发生在第 $1 行: "
    shift
    echo "$@"
}

function cleanup() {
    if [ -n "${loopback:-}" ] && losetup "$loopback" &>/dev/null; then
        losetup -d "$loopback"
    fi
    if [ -n "${LOOP_DEV:-}" ] && losetup "$LOOP_DEV" &>/dev/null; then
        losetup -d "$LOOP_DEV"
    fi
    if [ "$debug" = true ] && [ -n "${src:-}" ]; then
        local old_owner=$(stat -c %u:%g "$src")
        chown "$old_owner" "$LOGFILE"
    fi
}

function logVariables() {
    if [ "$debug" = true ]; then
        echo "Line $1" >> "$LOGFILE"
        shift
        local v var
        for var in "$@"; do
            eval "v=\$$var"
            echo "$var: $v" >> "$LOGFILE"
        done
    fi
}

function checkFilesystem() {
    info "检查文件系统"
    e2fsck -pf "$loopback"
    (( $? < 4 )) && return

    info "检测到文件系统错误!"

    info "尝试修复损坏的文件系统"
    e2fsck -y "$loopback"
    (( $? < 4 )) && return

    if [[ $repair == true ]]; then
        info "尝试修复损坏的文件系统 - 第二阶段"
        e2fsck -fy -b 32768 "$loopback"
        (( $? < 4 )) && return
    fi
    error $LINENO "文件系统修复失败，放弃..."
    exit 9
}

function set_autoexpand() {
    # 在首次启动时自动扩展 rootfs
    mountdir=$(mktemp -d)
    partprobe "$loopback"
    sleep 3
    umount "$loopback" > /dev/null 2>&1
    mount "$loopback" "$mountdir" -o rw
    if (( $? != 0 )); then
        info "无法挂载 loopback 设备，自动扩展功能将不会启用"
        return
    fi

    if [ ! -d "$mountdir/etc" ]; then
        info "未找到 /etc 目录，自动扩展功能将不会启用"
        umount "$mountdir"
        return
    fi

    # 检查是否已经存在自动扩展脚本
    if [ -f "$mountdir/etc/init.d/x5-autoexpand" ]; then
        info "自动扩展脚本已存在，跳过"
        umount "$mountdir"
        return
    fi

    info "创建 RDK X5 自动扩展脚本"

    # 创建自动扩展脚本
    cat <<'EOFEXPAND' > "$mountdir/etc/init.d/x5-autoexpand"
#!/bin/bash
### BEGIN INIT INFO
# Provides:          x5-autoexpand
# Required-Start:    $local_fs
# Required-Stop:
# Default-Start:     S
# Default-Stop:
# Short-Description: 自动扩展 RDK X5 rootfs 分区
### END INIT INFO

do_expand_rootfs() {
    ROOT_PART=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p')
    
    # 检测设备类型 (mmcblk 或 sd)
    if [[ "$ROOT_PART" == mmcblk* ]]; then
        # eMMC/SD 卡设备
        DEVICE="/dev/${ROOT_PART%p*}"
        PART_NUM="${ROOT_PART##*p}"
    elif [[ "$ROOT_PART" == sd* ]]; then
        # SATA/USB 设备
        DEVICE="/dev/${ROOT_PART%[0-9]*}"
        PART_NUM="${ROOT_PART##*[a-z]}"
    else
        echo "无法识别的设备类型: $ROOT_PART"
        return 1
    fi

    # 获取 rootfs 分区的起始扇区
    PART_START=$(parted "$DEVICE" -ms unit s p | grep "^${PART_NUM}" | cut -f 2 -d: | sed 's/[^0-9]//g')
    [ -z "$PART_START" ] && return 1

    # 获取磁盘总扇区数并计算结束扇区 (留1MB对齐)
    DISK_SIZE=$(blockdev --getsz "$DEVICE")
    # 对齐到2048扇区 (1MB边界)
    END_SECTOR=$(( (DISK_SIZE / 2048) * 2048 - 1 ))

    # 使用 parted 扩展分区 (比fdisk更可靠)
    echo "正在扩展分区 $PART_NUM 从扇区 $PART_START 到 $END_SECTOR ..."
    parted -s "$DEVICE" rm "$PART_NUM"
    parted -s "$DEVICE" unit s mkpart primary ext4 "${PART_START}s" "${END_SECTOR}s"
    parted -s "$DEVICE" set "$PART_NUM" boot on

    # 创建第二阶段扩展脚本
    cat <<'EOF2' > /etc/init.d/x5-autoexpand-phase2
#!/bin/bash
### BEGIN INIT INFO
# Provides:          x5-autoexpand-phase2
# Required-Start:    $local_fs
# Required-Stop:
# Default-Start:     S
# Default-Stop:
# Short-Description: 扩展 RDK X5 rootfs 文件系统 (第二阶段)
### END INIT INFO

ROOT_PART=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p')
echo "正在扩展文件系统 /dev/$ROOT_PART ..."
resize2fs /dev/$ROOT_PART
echo "文件系统扩展完成"

# 清理自动扩展脚本
update-rc.d x5-autoexpand-phase2 remove
rm -f /etc/init.d/x5-autoexpand-phase2
rm -f /etc/init.d/x5-autoexpand
EOF2

    chmod +x /etc/init.d/x5-autoexpand-phase2
    update-rc.d x5-autoexpand-phase2 defaults

    # 移除第一阶段脚本的自启动
    update-rc.d x5-autoexpand remove

    echo "分区扩展完成，正在重启以应用更改..."
    reboot
    exit
}

case "$1" in
    start)
        do_expand_rootfs
        ;;
    *)
        echo "Usage: $0 start"
        exit 1
        ;;
esac
EOFEXPAND

    chmod +x "$mountdir/etc/init.d/x5-autoexpand"
    
    # 启用自动扩展服务
    chroot "$mountdir" /bin/bash -c "update-rc.d x5-autoexpand defaults" 2>/dev/null || \
        ln -sf ../init.d/x5-autoexpand "$mountdir/etc/rcS.d/S01x5-autoexpand"

    sync
    umount "$mountdir"
    info "自动扩展脚本已安装"
}

help() {
    local help
    read -r -d '' help << EOM
用法: $0 [-adhnrsvzZ] imagefile.img [newimagefile.img]

  -s         首次启动时不自动扩展文件系统
  -v         显示详细信息
  -r         如果普通修复失败，使用高级文件系统修复选项
  -z         压缩后使用 gzip 压缩镜像
  -Z         压缩后使用 xz 压缩镜像
  -a         使用多核并行压缩
  -d         将调试信息写入日志文件

X5Shrink $version - 专为 RDK X5 设计的镜像压缩工具
支持 RDK X5 的双分区结构 (FAT32 config 分区 + ext4 rootfs 分区)
EOM
    echo "$help"
    exit 1
}

should_skip_autoexpand=false
debug=false
repair=false
parallel=false
verbose=false
ziptool=""

while getopts ":adhrsvzZ" opt; do
    case "${opt}" in
        a) parallel=true;;
        d) debug=true;;
        h) help;;
        r) repair=true;;
        s) should_skip_autoexpand=true ;;
        v) verbose=true;;
        z) ziptool="gzip";;
        Z) ziptool="xz";;
        *) help;;
    esac
done
shift $((OPTIND-1))

if [ "$debug" = true ]; then
    info "创建日志文件 $LOGFILE"
    rm "$LOGFILE" &>/dev/null
    exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
    exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
fi

echo -e "X5Shrink $version - RDK X5 镜像压缩工具\n"

# 参数处理
src="$1"
img="$1"

# 使用检查
if [[ -z "$img" ]]; then
    help
fi

if [[ ! -f "$img" ]]; then
    error $LINENO "$img 不是一个文件..."
    exit 2
fi

if (( EUID != 0 )); then
    error $LINENO "需要 root 权限运行此脚本"
    exit 3
fi

# 设置 POSIX 语言环境
export LANGUAGE=POSIX
export LC_ALL=POSIX
export LANG=POSIX

# 检查压缩工具
if [[ -n $ziptool ]]; then
    if [[ ! " ${ZIPTOOLS[@]} " =~ $ziptool ]]; then
        error $LINENO "$ziptool 是不支持的压缩工具"
        exit 17
    else
        if [[ $parallel == true && $ziptool == "gzip" ]]; then
            REQUIRED_TOOLS="$REQUIRED_TOOLS pigz"
        else
            REQUIRED_TOOLS="$REQUIRED_TOOLS $ziptool"
        fi
    fi
fi

# 检查必需工具
for command in $REQUIRED_TOOLS; do
    command -v $command >/dev/null 2>&1
    if (( $? != 0 )); then
        error $LINENO "$command 未安装"
        exit 4
    fi
done

# 如果指定了新文件名，则复制镜像
if [ -n "$2" ]; then
    f="$2"
    if [[ -n $ziptool && "${f##*.}" == "${ZIPEXTENSIONS[$ziptool]}" ]]; then
        f="${f%.*}"
    fi
    info "正在复制 $1 到 $f..."
    cp --reflink=auto --sparse=always "$1" "$f"
    if (( $? != 0 )); then
        error $LINENO "无法复制文件..."
        exit 5
    fi
    old_owner=$(stat -c %u:%g "$1")
    chown "$old_owner" "$f"
    img="$f"
fi

# 脚本退出时清理
trap cleanup EXIT

# 收集信息
info "正在收集镜像信息"
beforesize="$(ls -lh "$img" | cut -d ' ' -f 5)"
parted_output="$(parted -ms "$img" unit B print)"
rc=$?
if (( $rc )); then
    error $LINENO "parted 执行失败，返回码 $rc"
    info "可能是无效的镜像文件。请手动运行 'parted $img unit B print' 检查"
    exit 6
fi

# 获取分区信息 - RDK X5 使用双分区: p1=FAT32(config), p2=ext4(rootfs)
partcount="$(echo "$parted_output" | tail -n +3 | wc -l)"
info "检测到 $partcount 个分区"

if (( partcount < 2 )); then
    error $LINENO "镜像分区数量不正确，RDK X5 镜像应该有 2 个分区"
    exit 6
fi

# 获取 rootfs 分区 (第二个分区) 信息
rootfs_partnum="2"
rootfs_partinfo="$(echo "$parted_output" | grep "^${rootfs_partnum}:")"
rootfs_partstart="$(echo "$rootfs_partinfo" | cut -d ':' -f 2 | tr -d 'B')"
rootfs_partend="$(echo "$rootfs_partinfo" | cut -d ':' -f 3 | tr -d 'B')"
rootfs_partsize="$(echo "$rootfs_partinfo" | cut -d ':' -f 4 | tr -d 'B')"
rootfs_parttype="$(echo "$rootfs_partinfo" | cut -d ':' -f 5)"

# 获取 config 分区 (第一个分区) 信息
config_partnum="1"
config_partinfo="$(echo "$parted_output" | grep "^${config_partnum}:")"
config_partstart="$(echo "$config_partinfo" | cut -d ':' -f 2 | tr -d 'B')"
config_partend="$(echo "$config_partinfo" | cut -d ':' -f 3 | tr -d 'B')"

info "Config 分区 (FAT32): 起始=$config_partstart, 结束=$config_partend"
info "Rootfs 分区 (ext4): 起始=$rootfs_partstart, 结束=$rootfs_partend"

# 设置 loopback 设备指向 rootfs 分区
loopback="$(losetup -f --show -o "$rootfs_partstart" "$img")"
tune2fs_output="$(tune2fs -l "$loopback")"
rc=$?
if (( $rc )); then
    echo "$tune2fs_output"
    error $LINENO "tune2fs 执行失败。无法压缩此类型的镜像"
    exit 7
fi

currentsize="$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)"
blocksize="$(echo "$tune2fs_output" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)"

logVariables $LINENO beforesize parted_output rootfs_partnum rootfs_partstart rootfs_parttype tune2fs_output currentsize blocksize

# 设置自动扩展
if [ "$should_skip_autoexpand" = false ]; then
    set_autoexpand
else
    info "跳过自动扩展设置..."
fi

# 检查文件系统
checkFilesystem

if ! minsize=$(resize2fs -P "$loopback"); then
    rc=$?
    error $LINENO "resize2fs 执行失败，返回码 $rc"
    exit 10
fi
minsize=$(cut -d ':' -f 2 <<< "$minsize" | tr -d ' ')
logVariables $LINENO currentsize minsize

if [[ $currentsize -eq $minsize ]]; then
    info "文件系统已经是最小尺寸，跳过文件系统压缩"
else
    # 在文件系统末尾添加一些空闲空间 (减少预留空间以获得更小的镜像)
    extra_space=$(($currentsize - $minsize))
    logVariables $LINENO extra_space
    for space in 2500 500 50; do
        if [[ $extra_space -gt $space ]]; then
            minsize=$(($minsize + $space))
            break
        fi
    done
    logVariables $LINENO minsize

    # 压缩文件系统
    info "正在压缩文件系统"
    if [ -z "${mountdir:-}" ]; then
        mountdir=$(mktemp -d)
    fi

    resize2fs -p "$loopback" $minsize
    rc=$?
    if (( $rc )); then
        error $LINENO "resize2fs 执行失败，返回码 $rc"
        mount "$loopback" "$mountdir"
        if [ -f "$mountdir/etc/init.d/x5-autoexpand" ]; then
            rm -f "$mountdir/etc/init.d/x5-autoexpand"
            rm -f "$mountdir/etc/rcS.d/S01x5-autoexpand"
        fi
        umount "$mountdir"
        losetup -d "$loopback"
        exit 12
    else
        info "正在清零剩余空闲空间"
        mount "$loopback" "$mountdir"
        cat /dev/zero > "$mountdir/X5Shrink_zero_file" 2>/dev/null
        info "已清零 $(ls -lh "$mountdir/X5Shrink_zero_file" 2>/dev/null | cut -d ' ' -f 5)"
        rm -f "$mountdir/X5Shrink_zero_file"
        umount "$mountdir"
    fi
    sleep 1

    # 压缩分区
    info "正在压缩分区"
    partnewsize=$(($minsize * $blocksize))
    newpartend=$(($rootfs_partstart + $partnewsize))
    logVariables $LINENO partnewsize newpartend

    # 删除旧的 rootfs 分区
    parted -s -a minimal "$img" rm "$rootfs_partnum"
    rc=$?
    if (( $rc )); then
        error $LINENO "parted 删除分区失败，返回码 $rc"
        exit 13
    fi

    # 创建新的 rootfs 分区
    parted -s "$img" unit B mkpart primary ext4 "$rootfs_partstart" "$newpartend"
    rc=$?
    if (( $rc )); then
        error $LINENO "parted 创建分区失败，返回码 $rc"
        exit 14
    fi

    # 设置启动标志
    parted -s "$img" set "$rootfs_partnum" boot on

    # 截断文件
    info "正在截断镜像文件"
    parted_output=$(parted -ms "$img" unit B print)
    rc=$?
    if (( $rc )); then
        error $LINENO "parted 执行失败，返回码 $rc"
        exit 15
    fi

    # 获取 rootfs 分区 (第2分区) 的结束位置，而不是 free space
    endresult=$(echo "$parted_output" | grep "^${rootfs_partnum}:" | cut -d ':' -f 3 | tr -d 'B')
    # 加1字节作为文件大小
    endresult=$((endresult + 1))
    logVariables $LINENO endresult
    truncate -s "$endresult" "$img"
    rc=$?
    if (( $rc )); then
        error $LINENO "truncate 执行失败，返回码 $rc"
        exit 16
    fi
fi

# 释放 loopback 设备
losetup -d "$loopback" 2>/dev/null
loopback=""

# 处理压缩
if [[ -n $ziptool ]]; then
    options=""
    envVarname="${MYNAME^^}_${ziptool^^}"
    [[ $parallel == true ]] && options="${ZIP_PARALLEL_OPTIONS[$ziptool]}"
    [[ -v $envVarname ]] && options="${!envVarname}"
    [[ $verbose == true ]] && options="$options -v"

    if [[ $parallel == true ]]; then
        parallel_tool="${ZIP_PARALLEL_TOOL[$ziptool]}"
        info "使用 $parallel_tool 压缩镜像"
        if ! $parallel_tool ${options} "$img"; then
            rc=$?
            error $LINENO "$parallel_tool 执行失败，返回码 $rc"
            exit 18
        fi
    else
        info "使用 $ziptool 压缩镜像"
        if ! $ziptool ${options} "$img"; then
            rc=$?
            error $LINENO "$ziptool 执行失败，返回码 $rc"
            exit 19
        fi
    fi
    img=$img.${ZIPEXTENSIONS[$ziptool]}
fi

aftersize=$(ls -lh "$img" | cut -d ' ' -f 5)
logVariables $LINENO aftersize

info "成功将 $img 从 $beforesize 压缩到 $aftersize"