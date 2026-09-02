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
- **只构建已测试版本**（24.10.5 / 24.10.6 / 25.12.0 / 25.12.1，白名单见 `config/firmware.conf` 的 `supported_versions`）；官方新版本实测通过后再加入。
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

本仓库采用**三段式构建**（基础固件 / 插件包 / 定制固件分离，插件更新无需全量重编）：

```
阶段 1 · 全量源码构建（慢，1.5~3 小时，仅在官方发新版或手动触发时）
  编译 HINLINK H28K 固件：全量编译 → check-abi 门禁
  → Release：基础固件（不含第三方插件）+ 自建 ImageBuilder
  定时构建发现该版本已发过 Release 会自动跳过（可传 force_build 强制重建）

插件包 · SDK 独立编译（约 15~30 分钟，插件更新时手动触发）
  构建插件包工作流：官方 SDK 编译 nikki / fluent 主题等源码插件
  → Release 长期保存 ipk 集合（h28k-packages-v<版本>.tar.gz）

阶段 2 · 快速定制构建（快，约 5 分钟，随时手动触发）
  快速定制构建工作流：下载自建 ImageBuilder + 匹配版本的插件包 ipk
  → 注入 IP/密码/主题/软件包 → make image 组装 → ABI 与阶段 1 完全一致
```

- **阶段 1**：Actions → 编译 HINLINK H28K 固件 → 选系列（`all` / `24.10` / `25.12`），可选填精确版本、LAN 地址、root 密码、根目录大小（512M/1G/2G）。**版本对应是固定的**：补丁与 ABI 校验只对 `supported_versions` 白名单内的版本验证过，其他版本会被拒绝构建。为什么用自建而不是官方 ImageBuilder：官方 ImageBuilder 没有 `hinlink_h28k` 设备（无 device 配方、无 H28K DTB/u-boot），且预编译内核无法打补丁，H28K 支持只能从源码编出。
- **插件包**：Actions → 构建插件包 → 选系列。nikki / fluent 主题等源码插件用官方 SDK 单独编译并长期保存到 Release；nikki 更新时只需重跑这个（约 15~30 分钟），不用重编固件。
- **阶段 2**：Actions → 快速定制构建（ImageBuilder）→ 选基础系列/Release，改 `config/ib-packages.list` 即可换软件包组合。**日常使用的固件来自这里**（基础固件不含第三方插件）。

| 文档 | 内容 |
| --- | --- |
| [documents/build.md](documents/build.md) | 工作流总览、两段式构建、构建参数、产物、缓存与清理 |
| [documents/customize.md](documents/customize.md) | 固件参数、额外软件包、快速定制的包列表、新增系列 |
| [documents/install.md](documents/install.md) | 刷 SD、安装 EMMC、升级 |
| [documents/faq.md](documents/faq.md) | 常见问题与故障排查 |

## 目录结构

```
h28k-openwrt/
├── README.md
├── documents/                       # 分册文档
├── config/
│   ├── firmware.conf                # 初始化参数（已测试版本白名单、LAN IP、密码、根目录大小、主题、ABI 开关）
│   ├── packages.conf                # 插件源码 git clone 列表（仅「构建插件包」工作流使用）
│   ├── sdk-packages.list            # 需要 SDK 源码编译的第三方插件名（nikki、fluent）
│   ├── ib-packages.list             # 阶段 2 快速定制构建的追加软件包列表
│   └── hinlink-h28k.config          # 目标与软件包选配种子（含 CONFIG_IB 产出自建 IB）
├── patches/
│   ├── 24.10/                       # 24.10 系补丁（7 个，含 RK3528 内核回移）
│   └── 25.12/                       # 25.12 系补丁（5 个板级补丁）
├── scripts/
│   ├── config.sh                    # 共享配置读取与校验（版本白名单、参数覆盖）
│   ├── resolve_series.sh            # 手动参数 → 构建矩阵系列列表
│   ├── select_release.sh            # 从已测试版本白名单解析版本 + 官方 kmods 哈希
│   ├── select_sdk.sh                # 解析官方 SDK 下载地址
│   ├── select_ib.sh                 # 选基础 Release（IB 附件 + 匹配版本的插件包附件）
│   ├── build_ib_image.sh            # 用自建 IB 组装定制固件（IP/密码/主题/包/根目录大小）
│   ├── apply_patches.sh             # 按字典序应用系列补丁
│   ├── prepare_kernel_config.sh     # 官方内核配置合成 + 根目录大小注入 + 24.10 vermagic 排除
│   └── build_config.sh              # 参数注入、源码包克隆、官方 kmod 源启用、ABI 校验
└── .github/workflows/
    ├── build.yml                    # 阶段 1：全量源码构建（定时 + 手动，系列矩阵）
    ├── build-packages.yml           # 插件包：官方 SDK 编译第三方插件 → Release 长期保存
    ├── build-custom.yml             # 阶段 2：快速定制构建（分钟级）
    └── delete-older-releases.yml    # 各类 Release 分别保留最近 N 个
```

## 固件组件

- **基础固件**（阶段 1 Release）：`kmod-mt7921u`、`wpad-openssl`、`openssh-sftp-server` 等官方源组件，**不含第三方插件**
- **定制固件**（阶段 2 产物，日常使用推荐）：基础固件 + `luci-app-nikki`、`luci-theme-fluent`（ipk 来自插件包 Release）+ `config/ib-packages.list` 所列包

## 设备信息

- 型号：HINLINK H28K
- SoC：Rockchip RK3528
- 架构：ARMv8 / AArch64
- LAN：`eth0`（板上 GMAC）
- WAN：`eth1`（PCIe RTL8111HS）
- 固件设备名：`hinlink_h28k`
