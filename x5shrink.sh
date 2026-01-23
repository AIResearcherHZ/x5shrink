#!/usr/bin/env bash
#
# X5Shrink - RDK X5 镜像压缩工具
# 
# 功能：压缩 RDK X5 系统镜像，支持双分区结构 (FAT32 config + ext4 rootfs)
#       压缩后的镜像在首次启动时通过 hobot-resizefs 自动扩展
#
# 用法：sudo ./x5shrink.sh [选项] <镜像文件> [输出文件]
#
# Link: https://github.com/AIResearcherHZ/x5shrink

set -e

# ===================== 基本配置 =====================
VERSION="v1.0.0"
SCRIPT_NAME="${0##*/}"
REQUIRED_TOOLS="parted losetup tune2fs e2fsck resize2fs"

# 全局变量
img=""
loopback=""
mountdir=""
rootfs_start=""
block_count=""
block_size=""
min_blocks=""

# 选项变量
debug=false
repair=false
parallel=false
verbose=false
skip_autoexpand=false
ziptool=""

# ===================== 工具函数 =====================
info() { echo "$SCRIPT_NAME: $*"; }
warn() { echo "$SCRIPT_NAME: [警告] $*" >&2; }
die()  { echo "$SCRIPT_NAME: [错误] $*" >&2; cleanup; exit 1; }

cleanup() {
    set +e
    [[ -n "$mountdir" ]] && mountpoint -q "$mountdir" 2>/dev/null && umount "$mountdir"
    [[ -n "$mountdir" && -d "$mountdir" ]] && rmdir "$mountdir" 2>/dev/null
    [[ -n "$loopback" ]] && losetup "$loopback" &>/dev/null && losetup -d "$loopback"
    set -e
}

show_help() {
    cat << EOF
X5Shrink $VERSION - RDK X5 镜像压缩工具

用法: sudo $SCRIPT_NAME [选项] <镜像文件> [输出文件]

选项:
  -s    跳过自动扩展设置
  -r    使用高级文件系统修复
  -z    使用 gzip 压缩
  -Z    使用 xz 压缩
  -a    多核并行压缩
  -v    详细输出
  -d    调试模式
  -h    显示帮助

示例:
  sudo $SCRIPT_NAME rdk-x5.img
  sudo $SCRIPT_NAME rdk-x5.img output.img
  sudo $SCRIPT_NAME -z rdk-x5.img
EOF
    exit 0
}

check_requirements() {
    (( EUID == 0 )) || die "需要 root 权限"
    for cmd in $REQUIRED_TOOLS; do
        command -v "$cmd" &>/dev/null || die "未找到工具: $cmd"
    done
}

# ===================== Part 1: 分区信息 =====================
get_partition_info() {
    local img_file="$1"
    info "读取分区信息..."
    
    local parted_output
    parted_output=$(parted -ms "$img_file" unit B print) || die "无法读取分区表"
    
    local partcount
    partcount=$(echo "$parted_output" | tail -n +3 | wc -l)
    (( partcount >= 2 )) || die "分区数量不正确，需要 2 个分区"
    
    # 解析 rootfs 分区 (第2分区)
    local rootfs_info
    rootfs_info=$(echo "$parted_output" | grep "^2:")
    rootfs_start=$(echo "$rootfs_info" | cut -d: -f2 | tr -d 'B')
    local rootfs_end
    rootfs_end=$(echo "$rootfs_info" | cut -d: -f3 | tr -d 'B')
    
    info "Rootfs: ${rootfs_start}B -> ${rootfs_end}B"
}

# ===================== Part 2: Loopback 设备 =====================
setup_loopback() {
    local img_file="$1" offset="$2"
    loopback=$(losetup -f --show -o "$offset" "$img_file")
    [[ -n "$loopback" ]] || die "无法创建 loopback 设备"
    [[ "$debug" == true ]] && info "[DEBUG] loopback=$loopback, offset=$offset"
}

release_loopback() {
    [[ -n "$loopback" ]] && losetup -d "$loopback" 2>/dev/null || true
    loopback=""
}

# ===================== Part 3: 文件系统操作 =====================
check_filesystem() {
    info "检查文件系统..."
    
    e2fsck -pf "$loopback" || true
    local rc=$?
    (( rc < 4 )) && return 0
    
    info "尝试修复文件系统..."
    e2fsck -y "$loopback" || true
    rc=$?
    (( rc < 4 )) && return 0
    
    if [[ "$repair" == true ]]; then
        info "深度修复文件系统..."
        e2fsck -fy -b 32768 "$loopback" || true
        rc=$?
        (( rc < 4 )) && return 0
    fi
    
    die "文件系统修复失败"
}

get_fs_info() {
    info "获取文件系统信息..."
    
    local tune_output
    tune_output=$(tune2fs -l "$loopback") || die "无法读取文件系统信息"
    
    block_count=$(echo "$tune_output" | grep '^Block count:' | awk '{print $NF}')
    block_size=$(echo "$tune_output" | grep '^Block size:' | awk '{print $NF}')
    
    [[ "$debug" == true ]] && info "[DEBUG] blocks=$block_count, size=$block_size"
}

calculate_min_size() {
    info "计算最小尺寸..."
    
    local min_output
    min_output=$(resize2fs -P "$loopback" 2>&1) || die "无法计算最小尺寸"
    min_blocks=$(echo "$min_output" | grep -o '[0-9]*$')
    
    # 添加余量空间
    local extra=$((block_count - min_blocks))
    for margin in 2500 500 50; do
        if (( extra > margin )); then
            min_blocks=$((min_blocks + margin))
            break
        fi
    done
    
    info "最小块数: $min_blocks"
}

# ===================== Part 4: 压缩文件系统 =====================
shrink_filesystem() {
    if (( block_count == min_blocks )); then
        info "文件系统已是最小尺寸"
        return 0
    fi
    
    info "压缩文件系统: $block_count -> $min_blocks 块"
    resize2fs -p "$loopback" "$min_blocks" || die "文件系统压缩失败"
    
    # 清零空闲空间
    info "清零空闲空间..."
    mountdir=$(mktemp -d)
    if mount "$loopback" "$mountdir" 2>/dev/null; then
        dd if=/dev/zero of="$mountdir/.zero" bs=1M 2>/dev/null || true
        rm -f "$mountdir/.zero"
        umount "$mountdir"
    else
        warn "跳过清零（挂载失败）"
    fi
    rmdir "$mountdir" 2>/dev/null || true
    mountdir=""
}

# ===================== Part 5: 压缩分区 =====================
shrink_partition() {
    local new_size=$((min_blocks * block_size))
    local new_end=$((rootfs_start + new_size - 1))
    (( new_end > rootfs_start )) || die "计算分区结束位置失败"
    
    info "压缩分区: 新结束位置=${new_end}B"
    
    release_loopback
    sleep 1
    
    # 重建分区
    parted -s -a minimal "$img" rm 2 || die "删除分区失败"
    parted -s "$img" unit B mkpart primary ext4 "$rootfs_start" "$new_end" || die "创建分区失败"
    parted -s "$img" set 2 boot on 2>/dev/null || true
    
    # 验证
    setup_loopback "$img" "$rootfs_start"
    info "验证文件系统..."
    e2fsck -fy "$loopback" || true
    local rc=$?
    (( rc >= 4 )) && die "文件系统验证失败"
    release_loopback
}

# ===================== Part 6: 截断镜像 =====================
truncate_image() {
    local end_pos
    end_pos=$(parted -ms "$img" unit B print | grep "^2:" | cut -d: -f3 | tr -d 'B')
    
    info "截断镜像..."
    truncate -s "$((end_pos + 1))" "$img" || die "截断镜像失败"
}

# ===================== Part 7: 自动扩展配置 =====================
setup_autoexpand() {
    if [[ "$skip_autoexpand" == true ]]; then
        info "跳过自动扩展设置"
        return 0
    fi
    
    info "配置首次启动自动扩展..."
    
    setup_loopback "$img" "$rootfs_start"
    mountdir=$(mktemp -d)
    
    if ! mount "$loopback" "$mountdir" 2>/dev/null; then
        warn "无法挂载 rootfs，跳过自动扩展"
        rmdir "$mountdir" 2>/dev/null || true
        mountdir=""
        release_loopback
        return 0
    fi
    
    # 检查官方 hobot-resizefs
    if [[ -f "$mountdir/etc/init.d/hobot-resizefs" ]]; then
        rm -f "$mountdir/etc/.do_expand_partiton"
        rm -f "$mountdir/etc/.do_resizefs_rootfs"
        info "已重置 hobot-resizefs 标记"
    else
        install_expand_script "$mountdir"
    fi
    
    sync
    umount "$mountdir"
    rmdir "$mountdir" 2>/dev/null || true
    mountdir=""
    release_loopback
}

install_expand_script() {
    local rootfs="$1"
    info "安装自动扩展脚本..."
    
    cat > "$rootfs/etc/init.d/x5-resizefs" << 'EXPAND_SCRIPT'
#!/bin/bash
### BEGIN INIT INFO
# Provides:          x5-resizefs
# Required-Start:    $local_fs
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Expand rootfs
### END INIT INFO

do_expand() {
    [[ -f /etc/.x5_expanded ]] && return 0
    
    root_part=$(findmnt / -o source -n)
    root_dev="/dev/$(lsblk -no pkname "$root_part")"
    part_num=$(echo "$root_part" | grep -o '[0-9]*$')
    
    last_part=$(parted "$root_dev" -ms unit s p | tail -1 | cut -d: -f1)
    [[ "$last_part" != "$part_num" ]] && return 0
    
    part_start=$(parted "$root_dev" -ms unit s p | grep "^${part_num}:" | cut -d: -f2 | tr -d 's')
    [[ -z "$part_start" ]] && return 1
    
    fdisk "$root_dev" << EOF
d
$part_num
n
p
$part_num
$part_start

w
EOF
    
    partprobe "$root_dev"
    parted "$root_dev" set "$part_num" boot on
    resize2fs "$root_part"
    touch /etc/.x5_expanded
    
    update-rc.d x5-resizefs remove 2>/dev/null || true
    rm -f /etc/init.d/x5-resizefs /etc/rcS.d/*x5-resizefs
}

case "$1" in
    start) do_expand ;;
esac
EXPAND_SCRIPT
    
    chmod +x "$rootfs/etc/init.d/x5-resizefs"
    ln -sf ../init.d/x5-resizefs "$rootfs/etc/rcS.d/S01x5-resizefs" 2>/dev/null || true
}

# ===================== Part 8: 压缩镜像 =====================
compress_image() {
    [[ -z "$ziptool" ]] && return 0
    
    local tool ext opts
    case "$ziptool" in
        gzip) tool="pigz"; ext="gz"; opts="-f9" ;;
        xz)   tool="xz";   ext="xz"; opts="-T0" ;;
    esac
    
    [[ "$parallel" != true && "$ziptool" == "gzip" ]] && tool="gzip"
    [[ "$verbose" == true ]] && opts="$opts -v"
    
    command -v "$tool" &>/dev/null || die "未找到压缩工具: $tool"
    
    info "使用 $tool 压缩镜像..."
    $tool $opts "$img" || die "压缩失败"
    img="${img}.${ext}"
}

# ===================== 主程序 =====================
main() {
    trap cleanup EXIT
    
    # 解析参数
    while getopts ":adhrszvZ" opt; do
        case "$opt" in
            a) parallel=true ;;
            d) debug=true ;;
            h) show_help ;;
            r) repair=true ;;
            s) skip_autoexpand=true ;;
            v) verbose=true ;;
            z) ziptool="gzip" ;;
            Z) ziptool="xz" ;;
            *) show_help ;;
        esac
    done
    shift $((OPTIND - 1))
    
    [[ $# -lt 1 ]] && show_help
    
    local src="$1"
    img="$1"
    [[ -f "$img" ]] || die "文件不存在: $img"
    
    echo "==================== X5Shrink $VERSION ===================="
    echo
    
    check_requirements
    export LC_ALL=POSIX LANG=POSIX
    
    # 复制到新文件
    if [[ -n "${2:-}" ]]; then
        local dest="$2"
        info "复制镜像到 $dest..."
        cp --reflink=auto --sparse=always "$src" "$dest"
        chown --reference="$src" "$dest" 2>/dev/null || true
        img="$dest"
    fi
    
    local before_size
    before_size=$(stat -c%s "$img")
    
    echo "==================== Part 1: 读取分区信息 ===================="
    get_partition_info "$img"
    
    echo "==================== Part 2: 配置自动扩展 ===================="
    setup_autoexpand
    
    echo "==================== Part 3: 检查文件系统 ===================="
    setup_loopback "$img" "$rootfs_start"
    get_fs_info
    check_filesystem
    calculate_min_size
    
    echo "==================== Part 4: 压缩文件系统 ===================="
    shrink_filesystem
    
    echo "==================== Part 5: 压缩分区 ===================="
    shrink_partition
    
    echo "==================== Part 6: 截断镜像 ===================="
    truncate_image
    
    echo "==================== Part 7: 压缩打包 ===================="
    compress_image
    
    # 完成
    local after_size
    after_size=$(stat -c%s "$img")
    local saved=$((before_size - after_size))
    
    echo
    echo "==================== 完成 ===================="
    info "原始大小: $(numfmt --to=iec $before_size)"
    info "压缩后:   $(numfmt --to=iec $after_size)"
    info "节省:     $(numfmt --to=iec $saved) ($((saved * 100 / before_size))%)"
    echo "==== All done. =="
}

main "$@"