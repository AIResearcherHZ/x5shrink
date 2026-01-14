简体中文 | [English](./README_EN.md)

# X5Shrink - RDK X5 镜像压缩工具

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 概述

X5Shrink 是一个专为 **RDK X5** 开发板设计的系统镜像压缩工具，针对 RDK X5 的硬件特性和分区结构进行了深度适配。

该工具能够自动压缩 RDK X5 系统镜像，移除未使用的空间，并在镜像首次启动时自动扩展到 SD 卡的最大容量，极大地方便了镜像的分发和部署。

## 主要特性

- ✅ **双分区支持**: 完美适配 RDK X5 的双分区结构 (FAT32 config 分区 + ext4 rootfs 分区)
- ✅ **自动扩展**: 压缩后的镜像在首次启动时会自动扩展 rootfs 到 SD 卡最大容量
- ✅ **文件系统检查**: 压缩前自动检查并修复文件系统错误
- ✅ **空间优化**: 清零空闲空间以提高压缩率
- ✅ **多种压缩格式**: 支持 gzip 和 xz 压缩算法
- ✅ **并行压缩**: 支持多核并行压缩，加快处理速度
- ✅ **安全可靠**: 完整的错误处理和日志记录机制

## 系统要求

### 运行环境

推荐在以下环境中运行 X5Shrink：

- **Ubuntu 22.04** (推荐，与 RDK X5 系统版本一致)
- **Ubuntu 20.04** / **Ubuntu 18.04**
- **Debian 11+**
- **WSL2** (Windows Subsystem for Linux)

### 必需工具

X5Shrink 依赖以下工具，请确保已安装：

```bash
# Ubuntu/Debian
sudo apt-get install -y parted losetup e2fsprogs util-linux coreutils

# 如果需要压缩功能，还需要安装：
sudo apt-get install -y gzip pigz xz-utils
```

**工具说明**:
- `parted`: 分区管理工具
- `losetup`: 回环设备管理
- `e2fsprogs`: ext4 文件系统工具 (包含 e2fsck, resize2fs, tune2fs)
- `gzip/pigz`: gzip 压缩工具 (pigz 支持多核并行)
- `xz-utils`: xz 压缩工具

## 快速开始

### 1. 下载脚本

```bash
# 克隆仓库
git clone https://github.com/AIResearcherHZ/x5shrink.git
cd x5shrink

# 或直接下载脚本
wget https://raw.githubusercontent.com/AIResearcherHZ/x5shrink/main/x5shrink.sh
chmod +x x5shrink.sh
```

### 2. 基本使用

```bash
# 压缩镜像（原地修改）
sudo ./x5shrink.sh your-rdk-x5-image.img

# 压缩并保存为新文件
sudo ./x5shrink.sh original.img compressed.img
```

### 3. 高级用法

```bash
# 使用 gzip 压缩（速度快）
sudo ./x5shrink.sh -z image.img

# 使用 xz 压缩（压缩率高）
sudo ./x5shrink.sh -Z image.img

# 使用多核并行压缩
sudo ./x5shrink.sh -az image.img

# 跳过自动扩展功能
sudo ./x5shrink.sh -s image.img

# 启用调试日志
sudo ./x5shrink.sh -d image.img

# 组合使用：并行 xz 压缩 + 详细输出
sudo ./x5shrink.sh -aZv original.img compressed.img
```

## 使用说明

### 命令行选项

```
用法: ./x5shrink.sh [-adhrsvzZ] imagefile.img [newimagefile.img]

选项:
  -s         首次启动时不自动扩展文件系统
  -v         显示详细信息
  -r         如果普通修复失败，使用高级文件系统修复选项
  -z         压缩后使用 gzip 压缩镜像
  -Z         压缩后使用 xz 压缩镜像
  -a         使用多核并行压缩
  -d         将调试信息写入日志文件
  -h         显示帮助信息
```

### 工作流程

1. **验证镜像**: 检查镜像文件是否有效
2. **挂载分区**: 使用 loopback 设备挂载 rootfs 分区
3. **文件系统检查**: 运行 e2fsck 检查并修复文件系统
4. **安装自动扩展脚本**: 在系统中安装首次启动自动扩展脚本
5. **计算最小尺寸**: 使用 resize2fs 计算文件系统最小尺寸
6. **清零空闲空间**: 清零未使用的空间以提高压缩率
7. **压缩文件系统**: 将文件系统压缩到最小尺寸
8. **调整分区表**: 更新分区表以反映新的分区大小
9. **截断镜像**: 删除镜像末尾的空白空间
10. **可选压缩**: 使用 gzip 或 xz 压缩最终镜像

### 自动扩展机制

X5Shrink 会在压缩后的镜像中安装自动扩展脚本 (`/etc/init.d/x5-autoexpand`)，该脚本在系统首次启动时会：

1. 检测 rootfs 所在的设备和分区
2. 使用 fdisk 扩展分区到磁盘末尾
3. 重启系统
4. 使用 resize2fs 扩展文件系统
5. 清理自动扩展脚本

**支持的设备类型**:
- eMMC/SD 卡设备 (mmcblk*)
- SATA/USB 设备 (sd*)

## 使用场景

### 场景 1: 制作系统镜像发布包

```bash
# 从 RDK X5 开发板备份系统
sudo dd if=/dev/mmcblk1 of=rdk-x5-backup.img bs=4M status=progress

# 压缩镜像并使用 xz 压缩
sudo ./x5shrink.sh -aZ rdk-x5-backup.img rdk-x5-release.img

# 结果: rdk-x5-release.img.xz (体积大幅减小)
```

### 场景 2: 在 WSL2 中压缩镜像

```bash
# 1. 安装 WSL2 Debian
wsl --install -d Debian

# 2. 启动 Debian
wsl -d Debian

# 3. 安装依赖
sudo apt update && sudo apt install -y parted e2fsprogs gzip pigz xz-utils

# 4. 进入 Windows 文件系统
cd /mnt/c/Users/YourName/Desktop/Images

# 5. 压缩镜像
sudo ./x5shrink.sh -az rdk-x5-image.img
```

### 场景 3: 批量处理多个镜像

```bash
#!/bin/bash
# batch_shrink.sh

for img in *.img; do
    echo "处理: $img"
    sudo ./x5shrink.sh -aZ "$img" "compressed_${img}"
done
```

## 技术细节

### RDK X5 分区结构

RDK X5 系统镜像采用双分区结构：

```
/dev/mmcblk1
├── /dev/mmcblk1p1  (256MB, FAT32)  - config 分区，存储启动配置
└── /dev/mmcblk1p2  (剩余空间, ext4) - rootfs 分区，存储系统文件
```

X5Shrink 主要压缩 rootfs 分区 (p2)，同时保持 config 分区 (p1) 不变。

## 常见问题

### Q1: 为什么需要 root 权限？

A: X5Shrink 需要执行以下需要 root 权限的操作：
- 创建和管理 loopback 设备
- 挂载/卸载文件系统
- 修改分区表
- 运行文件系统检查和修复工具

### Q2: 压缩过程中断了怎么办？

A: X5Shrink 有完善的清理机制，会自动释放 loopback 设备。如果镜像已被修改，建议从备份重新开始。

### Q3: 可以压缩正在运行的系统吗？

A: **不可以**。必须在另一台机器上压缩镜像文件，不能压缩当前正在运行的系统。

### Q4: 压缩后的镜像能否在其他 RDK X5 板子上使用？

A: 可以。压缩后的镜像保持了完整的系统功能，可以在任何 RDK X5 开发板上使用。

### Q5: 自动扩展失败怎么办？

A: 可以手动扩展：
```bash
# 1. 扩展分区
sudo fdisk /dev/mmcblk1
# (删除分区 2，重新创建分区 2，使用相同起始扇区，结束扇区使用默认)

# 2. 扩展文件系统
sudo resize2fs /dev/mmcblk1p2
```

### Q6: 支持其他文件系统吗？

A: 目前仅支持 ext4 文件系统的 rootfs 分区。config 分区的 FAT32 文件系统不会被修改。

## 故障排除

### 错误: "parted failed with rc X"

**原因**: 镜像文件损坏或格式不正确

**解决方案**:
```bash
# 检查镜像文件
parted your-image.img unit B print

# 如果输出错误，镜像可能已损坏，需要重新备份
```

### 错误: "tune2fs failed"

**原因**: rootfs 分区不是 ext4 文件系统

**解决方案**: 确保使用的是 RDK X5 官方镜像或兼容的镜像格式

### 错误: "resize2fs failed"

**原因**: 文件系统有错误

**解决方案**:
```bash
# 使用 -r 选项启用高级修复
sudo ./x5shrink.sh -r your-image.img
```

### 压缩后镜像无法启动

**可能原因**:
1. 自动扩展脚本安装失败
2. 分区表损坏

**解决方案**:
```bash
# 使用 -s 选项跳过自动扩展，手动验证
sudo ./x5shrink.sh -s your-image.img
```

## 性能优化建议

### 1. 使用 SSD 存储镜像

在 SSD 上处理镜像比在机械硬盘上快 5-10 倍。

### 2. 启用并行压缩

```bash
# 使用 -a 选项启用多核压缩
sudo ./x5shrink.sh -az image.img  # 使用所有 CPU 核心
```

### 3. 选择合适的压缩算法

- **gzip (-z)**: 速度快，压缩率中等，适合快速分发
- **xz (-Z)**: 速度慢，压缩率高，适合长期存储

### 4. 预清理系统

在备份镜像前清理不必要的文件：

```bash
# 在 RDK X5 上执行
sudo apt clean
sudo apt autoremove
sudo rm -rf /var/log/*.log
sudo rm -rf /tmp/*
```

## 开发与贡献

### 项目结构

```
x5shrink/
├── x5shrink.sh          # 主脚本
├── README.md            # 中文文档
├── README_EN.md         # 英文文档
├── LICENSE              # MIT 许可证
└── examples/            # 使用示例
```

### 贡献指南

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 致谢

- 感谢 [PiShrink](https://github.com/Drewsif/PiShrink) 项目提供的灵感和参考
- 感谢 D-Robotics 团队开发的 RDK X5 开发板
- 感谢所有贡献者和用户的支持

## 联系方式

- **作者**: AIResearcherHZ
- **GitHub**: https://github.com/AIResearcherHZ
- **项目主页**: https://github.com/AIResearcherHZ/x5shrink
- **问题反馈**: https://github.com/AIResearcherHZ/x5shrink/issues

## 更新日志

### v1.0.0 (2026-01-12)

- ✨ 初始版本发布
- ✅ 支持 RDK X5 双分区结构
- ✅ 实现自动扩展功能
- ✅ 支持 gzip 和 xz 压缩
- ✅ 支持并行压缩
- ✅ 完整的错误处理和日志记录

---

**如果这个项目对你有帮助，请给个 ⭐ Star！**
