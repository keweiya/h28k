# H28K OpenWrt 固件构建仓库

本仓库自动编译 HINLINK H28K（Rockchip RK3528）的 ImmortalWrt 固件，**与官方 release 的内核 ABI 完全一致**：官方软件源里的插件（包括带 kmod 依赖的插件）可以直接安装，不会出现 vermagic 报错。

仓库只保存编译配置、构建脚本和板级补丁，不包含 ImmortalWrt 上游源码。

> 仅供个人使用和配置留档，请自行确认硬件适配性。

## 支持版本

| ImmortalWrt 系列 | 补丁目录 | 内容 | 已测试版本 |
| --- | --- | --- | --- |
| 24.10.x | `patches/24.10/` | RK3528 内核回移 + H28K 板级支持 + U-Boot 2025.10 | 24.10.5, 24.10.6 |
| 25.12.x | `patches/25.12/` | 5 个 H28K 板级补丁 | 25.12.0, 25.12.1 |

- 内核版本跟随官方 release（24.10 系为 6.6.x，25.12 系为 6.12.x，以官方实际发布为准）。
- 每周自动构建两个系列的最新正式版；官方发布新点版本（如 24.10.7）后自动跟上。
- 补丁按文件名字典序应用（`git apply --3way`），文件名前缀数字即应用顺序。
- 每次构建强制校验 ABI，见下文"ABI 保证机制"。

## ABI 保证机制

1. 源码锁定官方 release tag（`scripts/select_release.sh` 自动解析系列最新版，并确认官方 kmods 目录存在）。
2. feeds 用官方 `feeds.buildinfo` 锁定提交；内核配置用官方 `config.buildinfo` 中的内核选项合成（`scripts/prepare_kernel_config.sh`）。
3. 24.10 系特例：计算 vermagic 时排除 `CONFIG_CLK_RK3528=y`——官方 6.6 内核没有此选项，H28K 补丁新增的时钟选项必须从 ABI 哈希中剔除，否则与官方 kmods 不一致。
4. 编译后强校验：构建出的 `.vermagic` 必须等于官方 kmods 目录哈希，不一致则构建直接失败。

## 设计说明：为什么不移植 amlogic-s9xxx-openwrt 的打包框架

[amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt) 支持 200+ 设备和多内核切换，其核心机制是：编译通用的 `armsr/armv8` rootfs，再用 `remake` 脚本配合外置预编译内核（ophub 内核）重新打包。`remake` 会把 rootfs 内 `lib/modules/*` 整体替换为 ophub 内核的模块，因此它与官方插件仓库的兼容性是：

| 插件类型 | amlogic 路线 | 本仓库（ABI 一致路线） |
| --- | --- | --- |
| 纯用户态插件（luci-app、主题等） | ✅ 可装（官方用户态包按 aarch64_generic 架构共享） | ✅ 可装 |
| kmod 及依赖 kmod 的插件 | ❌ vermagic 不匹配，只能 `--force-depends` 绕过 | ✅ 直接安装 |

本仓库以"官方插件可用"为硬性要求，因此明确**不移植**以下内容（设计决策记录）：

1. armsr rootfs + remake 重打包——kmod ABI 冲突（见上表）。
2. ophub 多内核在线切换——依赖 ophub 内核 tar 包体系，同样破坏 ABI。
3. luci-app-amlogic 图形化安装 EMMC / btrfs 快照回滚——依赖 flippy 式 btrfs 分区布局与 `/etc` 子卷；原生 rockchip 镜像已支持 dd 写 SD 启动后 sysupgrade / 直接 dd 安装 EMMC，见 [documents/install.md](documents/install.md)。
4. `model_database.conf` 多设备表——单板仓库不需要。

从 amlogic-s9xxx-openwrt 移植的是它的**多版本工程化骨架**：按系列组织的补丁与配置、矩阵化自动构建、可复用工作流、分册文档与按系列保留的 Release 规范。

## 使用

手动触发：**Actions → 编译 HINLINK H28K 固件 → Run workflow**，选择系列（`all` / `24.10` / `25.12`），可选填精确版本（如 `v24.10.6`）。自托管运行器使用"自托管编译"工作流。详细参数说明见 [documents/build.md](documents/build.md)。

| 文档 | 内容 |
| --- | --- |
| [documents/build.md](documents/build.md) | Actions 构建参数、产物说明、缓存与清理、本地手动构建 |
| [documents/customize.md](documents/customize.md) | 固件参数、额外软件包、设备选包、新增系列 |
| [documents/install.md](documents/install.md) | 刷 SD、安装 EMMC、升级 |
| [documents/faq.md](documents/faq.md) | 常见问题与故障排查 |

## 目录结构

```
h28k-openwrt/
├── README.md
├── documents/                       # 分册文档
├── config/
│   ├── firmware.conf                # 全局构建参数（默认系列、LAN IP、密码、主题、ABI 开关）
│   ├── packages.conf                # 额外 git clone 软件包（nikki、fluent 主题）
│   └── hinlink-h28k.config          # 目标与软件包选配种子
├── patches/
│   ├── 24.10/                       # 24.10 系补丁（7 个，含 RK3528 内核回移）
│   └── 25.12/                       # 25.12 系补丁（5 个板级补丁）
├── scripts/
│   ├── config.sh                    # 共享配置读取与校验
│   ├── resolve_series.sh            # 手动参数 → 构建矩阵系列列表
│   ├── select_release.sh            # 解析系列最新版/精确版 + 官方 kmods 哈希
│   ├── apply_patches.sh             # 按字典序应用系列补丁
│   ├── prepare_kernel_config.sh     # 官方内核配置合成 + 24.10 vermagic 排除
│   └── build_config.sh              # 参数注入、官方 kmod 源启用、ABI 校验
└── .github/workflows/
    ├── build.yml                    # 托管运行器入口（定时 + 手动，系列矩阵）
    ├── build-local.yml              # 自托管运行器入口（手动，系列矩阵）
    ├── build-firmware.yml           # 可复用单系列构建流水线
    └── delete-older-releases.yml    # 按系列保留最近 N 个 Release
```

## 默认组件

- `luci-theme-fluent`
- `luci-app-nikki`
- `kmod-mt7921u`
- `openssh-sftp-server`

## 设备信息

- 型号：HINLINK H28K
- SoC：Rockchip RK3528
- 架构：ARMv8 / AArch64
- LAN：`eth0`（板上 GMAC）
- WAN：`eth1`（PCIe RTL8111HS）
- 固件设备名：`hinlink_h28k`
