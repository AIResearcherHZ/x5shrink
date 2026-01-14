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

readonly VERSION="v1.0.0"
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# 配置
# ============================================================================
readonly REQUIRED_TOOLS="parted losetup tune2fs e2fsck resize2fs"
declare -A COMPRESS_TOOLS=([gzip]="pigz" [xz]="xz")
declare -A COMPRESS_OPTS=([gzip]="-f9" [xz]="-T0")
declare -A COMPRESS_EXT=([gzip]="gz" [xz]="xz")

# ============================================================================
# 全局变量
# ============================================================================
img=""
loopback=""
mountdir=""
debug=false
repair=false
parallel=false
verbose=false
skip_autoexpand=false
ziptool=""

# ============================================================================
# 工具函数
# ============================================================================
info()    { echo "$SCRIPT_NAME: $*"; }
warn()    { echo "$SCRIPT_NAME: [警告] $*" >&2; }
die()     { echo "$SCRIPT_NAME: [错误] $*" >&2; exit 1; }
debug_log() { [[ "$debug" == true ]] && echo "[DEBUG] $*" >> "${SCRIPT_DIR}/${SCRIPT_NAME%.*}.log"; }

cleanup() {
    [[ -n "${loopback:-}" ]] && losetup "$loopback" &>/dev/null && losetup -d "$loopback"
    [[ -n "${mountdir:-}" ]] && mountpoint -q "$mountdir" 2>/dev/null && umount "$mountdir"
    [[ -n "${mountdir:-}" ]] && [[ -d "$mountdir" ]] && rmdir "$mountdir" 2>/dev/null
}

show_help() {
    cat << EOF
X5Shrink $VERSION - RDK X5 镜像压缩工具

用法: sudo $SCRIPT_NAME [选项] <镜像文件> [输出文件]

选项:
  -s    跳过自动扩展设置（首次启动时不自动扩展文件系统）
  -r    使用高级文件系统修复选项
  -z    压缩后使用 gzip 压缩镜像
  -Z    压缩后使用 xz 压缩镜像
  -a    使用多核并行压缩
  -v    显示详细信息
  -d    启用调试模式
  -h    显示此帮助信息

示例:
  sudo $SCRIPT_NAME rdk-x5.img                    # 压缩镜像
  sudo $SCRIPT_NAME rdk-x5.img rdk-x5-shrink.img  # 压缩到新文件
  sudo $SCRIPT_NAME -z rdk-x5.img                 # 压缩并gzip打包

支持 RDK X5 双分区结构: FAT32 config 分区 + ext4 rootfs 分区
EOF
    exit 0
}

check_requirements() {
    (( EUID == 0 )) || die "需要 root 权限运行此脚本"
    
    local tools="$REQUIRED_TOOLS"
    [[ -n "$ziptool" ]] && tools+=" ${COMPRESS_TOOLS[$ziptool]:-$ziptool}"
    
    for cmd in $tools; do
        command -v "$cmd" &>/dev/null || die "未找到必需工具: $cmd"
    done
}

# ============================================================================
# 核心功能
# ============================================================================
get_partition_info() {
    local img="$1"
    
    parted_output=$(parted -ms "$img" unit B print) || die "无法读取镜像分区表"
    
    local partcount=$(echo "$parted_output" | tail -n +3 | wc -l)
    (( partcount >= 2 )) || die "镜像分区数量不正确，RDK X5 应有 2 个分区"
    
    # 解析 rootfs 分区 (第2分区)
    rootfs_info=$(echo "$parted_output" | grep "^2:")
    rootfs_start=$(echo "$rootfs_info" | cut -d: -f2 | tr -d 'B')
    rootfs_end=$(echo "$rootfs_info" | cut -d: -f3 | tr -d 'B')
    
    info "Rootfs 分区: 起始=${rootfs_start}B, 结束=${rootfs_end}B"
}

setup_loopback() {
    local img="$1" offset="$2"
    loopback=$(losetup -f --show -o "$offset" "$img")
    if [[ -z "$loopback" ]]; then
        die "无法创建 loopback 设备"
    fi
    debug_log "创建 loopback: $loopback (offset=$offset)"
}

release_loopback() {
    if [[ -n "${loopback:-}" ]]; then
        losetup -d "$loopback" 2>/dev/null || true
        loopback=""
    fi
}

check_filesystem() {
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
    die "文件系统修复失败"
}

get_fs_info() {
    local tune_output
    tune_output=$(tune2fs -l "$loopback") || die "无法读取文件系统信息"
    
    block_count=$(echo "$tune_output" | grep '^Block count:' | awk '{print $NF}')
    block_size=$(echo "$tune_output" | grep '^Block size:' | awk '{print $NF}')
    
    debug_log "block_count=$block_count, block_size=$block_size"
}

calculate_min_size() {
    local min_output
    min_output=$(resize2fs -P "$loopback" 2>&1) || die "无法计算最小文件系统大小"
    
    min_blocks=$(echo "$min_output" | grep -o '[0-9]*$')
    
    # 添加少量额外空间
    local extra=$((block_count - min_blocks))
    for margin in 2500 500 50; do
        if (( extra > margin )); then
            min_blocks=$((min_blocks + margin))
            break
        fi
    done
    
    debug_log "min_blocks=$min_blocks (原始+余量)"
}

shrink_filesystem() {
    if (( block_count == min_blocks )); then
        info "文件系统已是最小尺寸"
        return 0
    fi
    
    info "压缩文件系统: ${block_count} -> ${min_blocks} 块"
    resize2fs -p "$loopback" "$min_blocks" || die "文件系统压缩失败"
    
    # 清零空闲空间以提高压缩率
    info "清零空闲空间..."
    mountdir=$(mktemp -d)
    mount "$loopback" "$mountdir"
    dd if=/dev/zero of="$mountdir/.zero" bs=1M 2>/dev/null || true
    rm -f "$mountdir/.zero"
    umount "$mountdir"
    rmdir "$mountdir"
    mountdir=""
}

shrink_partition() {
    local new_size=$((min_blocks * block_size))
    local new_end=$((rootfs_start + new_size))
    
    info "压缩分区: 新结束位置=${new_end}B"
    
    release_loopback
    sleep 1
    
    # 删除并重建分区
    parted -s -a minimal "$img" rm 2 || die "删除分区失败"
    parted -s "$img" unit B mkpart primary ext4 "$rootfs_start" "$new_end" || die "创建分区失败"
    parted -s "$img" set 2 boot on || true
    
    # 验证文件系统
    setup_loopback "$img" "$rootfs_start"
    info "验证压缩后的文件系统..."
    e2fsck -fy "$loopback"
    local rc=$?
    if (( rc >= 4 )); then
        die "文件系统验证失败 (返回码: $rc)"
    fi
    release_loopback
}

truncate_image() {
    local end_pos
    end_pos=$(parted -ms "$img" unit B print | grep "^2:" | cut -d: -f3 | tr -d 'B')
    
    info "截断镜像文件..."
    truncate -s "$((end_pos + 1))" "$img" || die "截断镜像失败"
}

setup_autoexpand() {
    [[ "$skip_autoexpand" == true ]] && { info "跳过自动扩展设置"; return 0; }
    
    info "配置首次启动自动扩展..."
    
    setup_loopback "$img" "$rootfs_start"
    mountdir=$(mktemp -d)
    
    if ! mount "$loopback" "$mountdir" 2>/dev/null; then
        warn "无法挂载 rootfs，跳过自动扩展配置"
        rmdir "$mountdir"
        mountdir=""
        return 0
    fi
    
    # 检查是否已有官方的 hobot-resizefs
    if [[ -f "$mountdir/etc/init.d/hobot-resizefs" ]]; then
        # 删除扩展完成标记，让 hobot-resizefs 重新执行
        rm -f "$mountdir/etc/.do_expand_partiton"
        rm -f "$mountdir/etc/.do_resizefs_rootfs"
        info "已重置 hobot-resizefs 扩展标记"
    else
        # 如果没有官方脚本，安装兼容的扩展脚本
        install_expand_script "$mountdir"
    fi
    
    sync
    umount "$mountdir"
    rmdir "$mountdir"
    mountdir=""
    release_loopback
}

install_expand_script() {
    local rootfs="$1"
    
    info "安装自动扩展脚本..."
    
    cat > "$rootfs/etc/init.d/x5-resizefs" << 'SCRIPT'
#!/bin/bash
### BEGIN INIT INFO
# Provides:          x5-resizefs
# Required-Start:    $local_fs
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: 扩展 RDK X5 rootfs 分区和文件系统
### END INIT INFO

do_expand() {
    [[ -f /etc/.x5_expanded ]] && return 0
    
    local root_part=$(findmnt / -o source -n)
    local root_dev="/dev/$(lsblk -no pkname "$root_part")"
    local part_num=$(echo "$root_part" | grep -o '[0-9]*$')
    
    # 检查是否为最后一个分区
    local last_part=$(parted "$root_dev" -ms unit s p | tail -1 | cut -d: -f1)
    [[ "$last_part" != "$part_num" ]] && return 0
    
    # 获取分区起始扇区
    local part_start=$(parted "$root_dev" -ms unit s p | grep "^${part_num}:" | cut -d: -f2 | tr -d 's')
    [[ -z "$part_start" ]] && return 1
    
    # 扩展分区
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
    
    # 扩展文件系统
    resize2fs "$root_part"
    
    touch /etc/.x5_expanded
    
    # 清理自身
    update-rc.d x5-resizefs remove 2>/dev/null || true
    rm -f /etc/init.d/x5-resizefs /etc/rcS.d/*x5-resizefs
}

case "$1" in
    start) do_expand ;;
    *) echo "Usage: $0 start" ;;
esac
SCRIPT
    
    chmod +x "$rootfs/etc/init.d/x5-resizefs"
    ln -sf ../init.d/x5-resizefs "$rootfs/etc/rcS.d/S01x5-resizefs" 2>/dev/null || \
        chroot "$rootfs" update-rc.d x5-resizefs defaults 2>/dev/null || true
}

compress_image() {
    [[ -z "$ziptool" ]] && return 0
    
    local tool="${COMPRESS_TOOLS[$ziptool]:-$ziptool}"
    local opts="${COMPRESS_OPTS[$ziptool]:-}"
    
    [[ "$parallel" != true && "$ziptool" == "gzip" ]] && tool="gzip"
    [[ "$verbose" == true ]] && opts+=" -v"
    
    info "使用 $tool 压缩镜像..."
    $tool $opts "$img" || die "$tool 压缩失败"
    
    img="${img}.${COMPRESS_EXT[$ziptool]}"
}

# ============================================================================
# 主程序
# ============================================================================
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
    
    echo "X5Shrink $VERSION - RDK X5 镜像压缩工具"
    echo
    
    check_requirements
    
    # 设置 POSIX 环境
    export LC_ALL=POSIX LANG=POSIX
    
    # 复制到新文件（如果指定）
    if [[ -n "${2:-}" ]]; then
        local dest="$2"
        [[ -n "$ziptool" && "${dest##*.}" == "${COMPRESS_EXT[$ziptool]}" ]] && dest="${dest%.*}"
        info "复制镜像到 $dest..."
        cp --reflink=auto --sparse=always "$src" "$dest"
        chown --reference="$src" "$dest"
        img="$dest"
    fi
    
    local before_size=$(stat -c%s "$img")
    
    # 执行压缩流程
    get_partition_info "$img"
    setup_loopback "$img" "$rootfs_start"
    get_fs_info
    setup_autoexpand
    setup_loopback "$img" "$rootfs_start"
    check_filesystem
    calculate_min_size
    shrink_filesystem
    shrink_partition
    truncate_image
    compress_image
    
    local after_size=$(stat -c%s "$img")
    local saved=$((before_size - after_size))
    
    echo
    info "压缩完成!"
    info "  原始大小: $(numfmt --to=iec $before_size)"
    info "  压缩后:   $(numfmt --to=iec $after_size)"
    info "  节省:     $(numfmt --to=iec $saved) ($(( saved * 100 / before_size ))%)"
}

main "$@"