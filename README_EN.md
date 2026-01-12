[简体中文](./README.md) | English

# X5Shrink - RDK X5 Image Compression Tool

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Overview

X5Shrink is a system image compression tool specifically designed for **RDK X5** development boards. It has been deeply adapted for the hardware characteristics and partition structure of RDK X5.

This tool automatically compresses RDK X5 system images, removes unused space, and automatically expands to the maximum SD card capacity on first boot, greatly facilitating image distribution and deployment.

## Key Features

- ✅ **Dual Partition Support**: Perfectly adapted to RDK X5's dual partition structure (FAT32 config partition + ext4 rootfs partition)
- ✅ **Auto Expansion**: Compressed images automatically expand rootfs to maximum SD card capacity on first boot
- ✅ **Filesystem Check**: Automatically checks and repairs filesystem errors before compression
- ✅ **Space Optimization**: Zeros free space to improve compression ratio
- ✅ **Multiple Compression Formats**: Supports gzip and xz compression algorithms
- ✅ **Parallel Compression**: Supports multi-core parallel compression for faster processing
- ✅ **Safe and Reliable**: Complete error handling and logging mechanism

## System Requirements

### Runtime Environment

Recommended environments for running X5Shrink:

- **Ubuntu 22.04** (Recommended, consistent with RDK X5 system version)
- **Ubuntu 20.04** / **Ubuntu 18.04**
- **Debian 11+**
- **WSL2** (Windows Subsystem for Linux)

### Required Tools

X5Shrink depends on the following tools, please ensure they are installed:

```bash
# Ubuntu/Debian
sudo apt-get install -y parted losetup e2fsprogs util-linux coreutils

# If compression functionality is needed, also install:
sudo apt-get install -y gzip pigz xz-utils
```

**Tool Description**:
- `parted`: Partition management tool
- `losetup`: Loop device management
- `e2fsprogs`: ext4 filesystem tools (includes e2fsck, resize2fs, tune2fs)
- `gzip/pigz`: gzip compression tool (pigz supports multi-core parallelism)
- `xz-utils`: xz compression tool

## Quick Start

### 1. Download Script

```bash
# Clone repository
git clone https://github.com/AIResearcherHZ/x5shrink.git
cd x5shrink

# Or download script directly
wget https://raw.githubusercontent.com/AIResearcherHZ/x5shrink/main/x5shrink.sh
chmod +x x5shrink.sh
```

### 2. Basic Usage

```bash
# Compress image (in-place modification)
sudo ./x5shrink.sh your-rdk-x5-image.img

# Compress and save as new file
sudo ./x5shrink.sh original.img compressed.img
```

### 3. Advanced Usage

```bash
# Use gzip compression (faster)
sudo ./x5shrink.sh -z image.img

# Use xz compression (higher compression ratio)
sudo ./x5shrink.sh -Z image.img

# Use multi-core parallel compression
sudo ./x5shrink.sh -az image.img

# Skip auto-expansion feature
sudo ./x5shrink.sh -s image.img

# Enable debug logging
sudo ./x5shrink.sh -d image.img

# Combined usage: parallel xz compression + verbose output
sudo ./x5shrink.sh -aZv original.img compressed.img
```

## Usage Instructions

### Command Line Options

```
Usage: ./x5shrink.sh [-adhrsvzZ] imagefile.img [newimagefile.img]

Options:
  -s         Do not auto-expand filesystem on first boot
  -v         Verbose output
  -r         Use advanced filesystem repair option if normal repair fails
  -z         Compress image with gzip after shrinking
  -Z         Compress image with xz after shrinking
  -a         Use multi-core parallel compression
  -d         Write debug information to log file
  -h         Display help information
```

### Workflow

1. **Verify Image**: Check if image file is valid
2. **Mount Partition**: Mount rootfs partition using loopback device
3. **Filesystem Check**: Run e2fsck to check and repair filesystem
4. **Install Auto-Expand Script**: Install first-boot auto-expansion script in system
5. **Calculate Minimum Size**: Use resize2fs to calculate minimum filesystem size
6. **Zero Free Space**: Zero unused space to improve compression ratio
7. **Shrink Filesystem**: Shrink filesystem to minimum size
8. **Adjust Partition Table**: Update partition table to reflect new partition size
9. **Truncate Image**: Remove blank space at end of image
10. **Optional Compression**: Compress final image using gzip or xz

### Auto-Expansion Mechanism

X5Shrink installs an auto-expansion script (`/etc/init.d/x5-autoexpand`) in the compressed image, which will:

1. Detect the device and partition where rootfs is located
2. Use fdisk to expand partition to end of disk
3. Reboot system
4. Use resize2fs to expand filesystem
5. Clean up auto-expansion script

**Supported Device Types**:
- eMMC/SD card devices (mmcblk*)
- SATA/USB devices (sd*)

## Use Cases

### Scenario 1: Creating System Image Release Package

```bash
# Backup system from RDK X5 board
sudo dd if=/dev/mmcblk1 of=rdk-x5-backup.img bs=4M status=progress

# Compress image and use xz compression
sudo ./x5shrink.sh -aZ rdk-x5-backup.img rdk-x5-release.img

# Result: rdk-x5-release.img.xz (significantly reduced size)
```

### Scenario 2: Compressing Images in WSL2

```bash
# 1. Install WSL2 Debian
wsl --install -d Debian

# 2. Start Debian
wsl -d Debian

# 3. Install dependencies
sudo apt update && sudo apt install -y parted e2fsprogs gzip pigz xz-utils

# 4. Navigate to Windows filesystem
cd /mnt/c/Users/YourName/Desktop/Images

# 5. Compress image
sudo ./x5shrink.sh -az rdk-x5-image.img
```

### Scenario 3: Batch Processing Multiple Images

```bash
#!/bin/bash
# batch_shrink.sh

for img in *.img; do
    echo "Processing: $img"
    sudo ./x5shrink.sh -aZ "$img" "compressed_${img}"
done
```

## Technical Details

### RDK X5 Partition Structure

RDK X5 system images use a dual partition structure:

```
/dev/mmcblk1
├── /dev/mmcblk1p1  (256MB, FAT32)  - config partition, stores boot configuration
└── /dev/mmcblk1p2  (remaining space, ext4) - rootfs partition, stores system files
```

X5Shrink primarily compresses the rootfs partition (p2) while keeping the config partition (p1) unchanged.

**Note**: Actual compression results depend on installed software and data volume in the system.

## FAQ

### Q1: Why is root permission required?

A: X5Shrink needs to perform the following operations that require root permission:
- Create and manage loopback devices
- Mount/unmount filesystems
- Modify partition table
- Run filesystem check and repair tools

### Q2: What if compression process is interrupted?

A: X5Shrink has a complete cleanup mechanism and will automatically release loopback devices. If the image has been modified, it's recommended to start over from backup.

### Q3: Can I compress a running system?

A: **No**. You must compress the image file on another machine, not the currently running system.

### Q4: Can compressed images be used on other RDK X5 boards?

A: Yes. Compressed images maintain complete system functionality and can be used on any RDK X5 development board.

### Q5: What if auto-expansion fails?

A: You can manually expand:
```bash
# 1. Expand partition
sudo fdisk /dev/mmcblk1
# (Delete partition 2, recreate partition 2, use same start sector, use default end sector)

# 2. Expand filesystem
sudo resize2fs /dev/mmcblk1p2
```

### Q6: Does it support other filesystems?

A: Currently only supports ext4 filesystem for rootfs partition. The FAT32 filesystem of config partition will not be modified.

## Troubleshooting

### Error: "parted failed with rc X"

**Cause**: Image file is corrupted or format is incorrect

**Solution**:
```bash
# Check image file
parted your-image.img unit B print

# If output shows error, image may be corrupted, need to re-backup
```

### Error: "tune2fs failed"

**Cause**: rootfs partition is not ext4 filesystem

**Solution**: Ensure you are using RDK X5 official image or compatible image format

### Error: "resize2fs failed"

**Cause**: Filesystem has errors

**Solution**:
```bash
# Use -r option to enable advanced repair
sudo ./x5shrink.sh -r your-image.img
```

### Compressed image won't boot

**Possible Causes**:
1. Auto-expansion script installation failed
2. Partition table corrupted

**Solution**:
```bash
# Use -s option to skip auto-expansion, verify manually
sudo ./x5shrink.sh -s your-image.img
```

## Performance Optimization Tips

### 1. Use SSD Storage for Images

Processing images on SSD is 5-10 times faster than on mechanical hard drives.

### 2. Enable Parallel Compression

```bash
# Use -a option to enable multi-core compression
sudo ./x5shrink.sh -az image.img  # Use all CPU cores
```

### 3. Choose Appropriate Compression Algorithm

- **gzip (-z)**: Fast speed, medium compression ratio, suitable for quick distribution
- **xz (-Z)**: Slow speed, high compression ratio, suitable for long-term storage

### 4. Pre-clean System

Clean unnecessary files before backing up image:

```bash
# Execute on RDK X5
sudo apt clean
sudo apt autoremove
sudo rm -rf /var/log/*.log
sudo rm -rf /tmp/*
```

## Development and Contribution

### Project Structure

```
x5shrink/
├── x5shrink.sh          # Main script
├── README.md            # Chinese documentation
├── README_EN.md         # English documentation
├── LICENSE              # MIT License
└── examples/            # Usage examples
```

### Contribution Guidelines

Welcome to submit Issues and Pull Requests!

1. Fork this repository
2. Create feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details

## Acknowledgments

- Thanks to [PiShrink](https://github.com/Drewsif/PiShrink) project for inspiration and reference
- Thanks to D-Robotics team for developing the RDK X5 development board
- Thanks to all contributors and users for their support

## Contact

- **Author**: AIResearcherHZ
- **GitHub**: https://github.com/AIResearcherHZ
- **Project Homepage**: https://github.com/AIResearcherHZ/x5shrink
- **Issue Tracker**: https://github.com/AIResearcherHZ/x5shrink/issues

## Changelog

### v1.0.0 (2026-01-12)

- ✨ Initial release
- ✅ Support RDK X5 dual partition structure
- ✅ Implement auto-expansion functionality
- ✅ Support gzip and xz compression
- ✅ Support parallel compression
- ✅ Complete error handling and logging

---

**If this project helps you, please give it a ⭐ Star!**
