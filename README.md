# H28K ImmortalWrt 固件构建仓库

自动构建 HINLINK H28K（Rockchip RK3528）的 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 固件。产物与官方 release 内核 **ABI 完全一致**，官方源插件（含 kmod 依赖）直接安装无 vermagic 报错。

仓库只保存配置、脚本与板级补丁，不含上游源码。仅供个人使用。

## 快速开始

| 工作流 | 用途 | 产物 Release |
|---|---|---|
| **固件快速组装** | 日常用固件（预装 `config/ib-packages.list` 插件，约 5 分钟） | `*-custom-<版本>` |
| 固件全量构建 | 底包（源码编译，1.5~3 小时，改动补丁/配置后跑） | `*-base-<版本>` |
| 固件周更（周四 02:00） | 滚动版本（master + 双 SNAPSHOT）自动刷新 | 原地覆盖 base/custom |

- 日常使用下载 **custom** 固件；首启默认（LAN IP/密码/WAN 模式/Wi-Fi/中文）在 `config/firmware.conf` 配置。
- **更新校验自动跳过**：上游未推进且补丁/配置未变的版本不重编（Release 正文记录 revision 与构建指纹）；勾选 `force` 强制重建。
- 组装容错：设备配方缺包自动剔除；安装失败的插件自动跳过并在 Release 总结标注；无法修复的错误立即失败报真因。
- H28K 定制固件带出厂自检：base-files 被官方包覆盖时自动恢复 H28K 板级配置（WAN/LED），WAN 配置缺失则注入兜底，仍失败不出包。

## 支持版本

24.10.1 ~ 24.10.6、25.12.0 ~ 25.12.2 正式版，24.10-SNAPSHOT / 25.12-SNAPSHOT 分支快照，master 快照。内核随官方（6.6 / 6.12 / 6.18.x）。`all` = `config/firmware.conf` 里的固定集合，新官方版本需先加选项并全量构建底包后再加入。

补丁在单层 `patches/`，命名 `<序号>-<功能>-v<范围>.patch`（`-v24.10` 整个系列、`-v24.10.1` 精确版本、`-vmaster` 仅 master）。24.10 系含 RK3528 内核回移；24.10.0 不支持（缺 phy-leds 脚本）。

## 构建其他 rockchip 设备

其他官方 rockchip/armv8 设备用**官方 ImageBuilder**（官方 IB 天然支持全部官方设备）：

- **workflow**：「快速组装」填「设备名称」（如 `friendlyarm_nanopi-r5s`）即自动用官方 IB 组装，发布独立 Release `immortalwrt-<设备>-custom-<版本>`；留空默认 H28K（读 `config/hinlink-h28k.config` 的 `PROFILE=`）。建议选正式版——master/快照源轮换期间会因官方 feed 失配失败，过几小时重试即可。
- **手动**（任意 Linux）：

  ```bash
  curl -O https://downloads.immortalwrt.org/releases/<版本>/targets/rockchip/armv8/immortalwrt-imagebuilder-<版本>-rockchip-armv8.Linux-x86_64.tar.zst
  tar --zstd -xf immortalwrt-imagebuilder-*-Linux-x86_64.tar.zst && cd immortalwrt-imagebuilder-*
  make info    # 全部设备 profile
  make image PROFILE=friendlyarm_nanopi-r5s PACKAGES="luci-app-openclash"
  ```

- PROFILE 名 = 官方 [armv8.mk](https://github.com/immortalwrt/immortalwrt/blob/master/target/linux/rockchip/image/armv8.mk) 里 `DEVICE_xxx` 的下划线形式（各版本/分支同路径替换 ref；官方文件不含 H28K——由本仓库 `0030` 补丁添加）。

## ABI 保证

源码锁官方 tag/revision，feeds 锁官方 `feeds.buildinfo`，内核配置合成自官方 `config.buildinfo`；编译后 `.vermagic` 必须等于官方 kmods 目录哈希，不一致构建失败。24.10 系对补丁新增符号（`CLK_RK3528` 等）做 vermagic 排除以对齐官方。

## 目录结构

```
├── config/
│   ├── firmware.conf          # 首启默认与构建参数；supported_versions 固定集合
│   ├── hinlink-h28k.config    # 构建种子（顶部 PROFILE= 为组装默认设备）
│   └── ib-packages.list       # 定制固件预装插件清单
├── patches/                   # 板级补丁（命名规则见上）
├── scripts/                   # 构建/校验/组装脚本（用法见各文件头注释）
└── .github/workflows/         # build-base / build-custom / build-weekly
```

## 设备信息

HINLINK H28K · RK3528 · aarch64 · LAN `eth0`（GMAC）/ WAN `eth1`（PCIe RTL8111HS）· 固件设备名 `hinlink_h28k`

## 参考

- [Ssrtvb/hinlink-h28k](https://github.com/Ssrtvb/hinlink-h28k)
- [ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt)
