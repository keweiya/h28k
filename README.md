# HINLINK H28K 固件

本仓库用于编译 ImmortalWrt HINLINK H28K 固件（RK3528）。

> 本项目仅供个人使用与配置留档，不面向通用环境，也不提供技术支持；请自行评估适配性。

## 版本支持

本仓库只维护 ImmortalWrt `v25.12.x` 的 HINLINK H28K 支持补丁。

| 版本线 | 补丁目录 | 固件包配置 | 状态 |
| --- | --- | --- | --- |
| `v25.12.x` | `patches/` | `config/immortalwrt-25.12.config` | 支持 |

## 补丁说明

| 补丁 | 说明 |
| --- | --- |
| `0010-rockchip-add-HINLINK-H28K-U-Boot-support.patch` | 添加 U-Boot 目标、H28K DTS、U-Boot DTSI 和 defconfig。 |
| `0020-rockchip-add-HINLINK-H28K-device-tree.patch` | 添加 Linux H28K 设备树和系统 LED 别名。 |
| `0030-rockchip-add-HINLINK-H28K-board-defaults.patch` | 添加 LED 默认值、LAN/WAN 分配、MAC 地址生成和 IRQ affinity。 |
| `0040-rockchip-add-HINLINK-H28K-image.patch` | 添加 `hinlink_h28k` 固件设备配置。 |
| `0050-rockchip-configure-HINLINK-H28K-RJ45-LEDs.patch` | 配置两个 RJ45 接口的链路灯和活动灯。 |

补丁统一放在 `patches/`。

## 自动编译

GitHub Actions 提供两个手动工作流：

1. `build-imagebuilder-docker.yml`：基于官方 `config.buildinfo` 只添加 HINLINK H28K profile，构建纯净 ImageBuilder Docker，并校验内核 ABI 与官方版本一致。
2. `build-firmware-imagebuilder-docker.yml`：使用 ImageBuilder Docker 编译 H28K 固件；需要第三方插件时下载对应版本 SDK，按 `config/packages.conf` 编译 `.ipk` 后安装进固件。

## 构建配置

所有可调整的构建配置放在 `config/`：

| 文件 | 用途 |
| --- | --- |
| `packages.conf` | 每行一条完整的 `git clone` 命令。 |
| `h28k-imagebuilder.config` | H28K 目标和 ImageBuilder 构建配置。 |
| `immortalwrt-25.12.config` | `v25.12.x` 固件 ImageBuilder 软件包配置。 |

## 本地验证补丁

示例：在本地 ImmortalWrt 源码仓库中验证补丁是否可应用：

```bash
git checkout v25.12.1
git reset --hard
for patch in /path/to/hinlink-h28k/patches/*.patch; do
  git apply --check --3way "$patch"
done
```

## 默认包含

- Fluent LuCI 主题：`luci-theme-fluent`
- Nikki：`luci-app-nikki`
- MT7921U USB 无线网卡驱动：`kmod-mt7921u`
- OpenSSH SFTP 服务：`openssh-sftp-server`

## 设备信息

- 型号：HINLINK H28K
- SoC：Rockchip RK3528
- 架构：ARMv8 / AArch64
- LAN：`eth0`
- WAN：`eth1`
- 固件设备名：`hinlink_h28k`
