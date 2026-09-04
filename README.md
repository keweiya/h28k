# H28K OpenWrt 固件构建仓库

本仓库自动编译 HINLINK H28K（Rockchip RK3528）的 ImmortalWrt 固件，**与官方 release 的内核 ABI 完全一致**：官方软件源里的插件（包括带 kmod 依赖的插件）可以直接安装，不会出现 vermagic 报错。

仓库只保存编译配置、构建脚本和板级补丁，不包含 ImmortalWrt 上游源码。

> 仅供个人使用和配置留档，请自行确认硬件适配性。

> **分支说明**：`master` 分支只构建实测过的固定版本；本分支（`adapt`）扩展支持 ImmortalWrt 官方全部已发布版本（24.10.1+ / 25.12.x）、`X.Y-SNAPSHOT` 分支滚动快照和 `master` 滚动快照。稳定后可合并回 `master`。

## 支持版本

| ImmortalWrt 版本形态 | 补丁目录 | 内容 | 已实测版本 |
| --- | --- | --- | --- |
| 24.10.x（X.Y.Z 与 24.10-SNAPSHOT） | `patches/24.10/` | RK3528 内核回移 + H28K 板级支持 + U-Boot 2025.10 | 24.10.1 ~ 24.10.6 与 openwrt-24.10 分支 HEAD（补丁应用层面全部验证） |
| 25.12.x（X.Y.Z 与 25.12-SNAPSHOT） | `patches/25.12/` | 5 个 H28K 板级补丁 | 25.12.0, 25.12.1 与 openwrt-25.12 分支 HEAD |
| master（滚动快照） | `patches/25.12/`（构建时自动映射） | 与 25.12 同源，跟随 master 演进 | 当前官方快照 revision（见下方说明） |

- **三种版本形态**：
  - `X.Y.Z`（如 `24.10.4`）：正式 release，源码锁 tag `vX.Y.Z`，官方产物目录不可变，ABI 校验最稳。
  - `X.Y-SNAPSHOT`（如 `25.12-SNAPSHOT`）：`openwrt-X.Y` 分支的滚动快照，官方源 `releases/X.Y-SNAPSHOT/`，源码锁 `version.buildinfo` 里的 revision。
  - `master`：master 分支滚动快照，官方源 `snapshots/`，源码锁当前已发布快照对应的 revision。
- **滚动快照不做 ABI 强校验**：官方快照产物随时被新构建覆盖，无法作为固定契约。构建改为源码锁 revision + 全量 kmod 本地捆绑（固件自包含），与官方源的 kmod 兼容是尽力而为；正式版 `X.Y.Z` 的 ABI 强校验照常生效。
- 24.10.0 不支持：上游在 24.10.1 才引入 `phy-leds` 脚本（`0050` 补丁的前提）。
- 系列内的任意版本都可以直接构建（如 `24.10.2`），无需登记白名单；`config/firmware.conf` 的 `supported_series` 控制开放哪些系列，补丁应用与编译后的 ABI 强校验兜底质量。
- 内核版本跟随官方对应版本（24.10 系为 6.6.x，25.12 系为 6.12.x，master 当前为 6.18.x，以官方实际发布为准）。
- 补丁按文件名字典序应用（`git apply --3way`），文件名前缀数字即应用顺序。
- 每次构建强制校验 ABI，见下文"ABI 保证机制"。

## ABI 保证机制

（仅对 `X.Y.Z` 正式版生效；`master` / `X.Y-SNAPSHOT` 滚动快照不做 ABI 校验，见"支持版本"说明。）

1. 源码锁定官方版本：正式版锁 release tag；滚动快照锁官方已发布产物对应的 revision（`scripts/select_release.sh` 自动解析，并确认官方 kmods 目录存在）。
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
3. luci-app-amlogic 图形化安装 EMMC / btrfs 快照回滚——依赖 flippy 式 btrfs 分区布局与 `/etc` 子卷；原生 rockchip 镜像已支持 dd 写 SD 启动后 sysupgrade / 直接 dd 安装 EMMC。
4. `model_database.conf` 多设备表——单板仓库不需要。

从 amlogic-s9xxx-openwrt 移植的是它的**多版本工程化骨架**：按系列组织的补丁与配置、矩阵化自动构建、可复用工作流、分册文档与按系列保留的 Release 规范。

## 使用

本仓库采用**三段式构建**（基础固件 / 插件包 / 定制固件分离，插件更新无需全量重编）：

```
阶段 1 · 全量源码构建（慢，1.5~3 小时，手动触发）
  H28K 固件全量构建：全量编译 → check-abi 门禁
  → 发布/覆盖更新 Base Release（tag = immortalwrt-h28k-base-v<版本>）：
    基础固件 + rootfs.tar.gz + 自建 ImageBuilder

插件包 · SDK 独立编译（约 15~30 分钟，插件更新时手动触发）
  H28K 插件包构建：官方 SDK 编译 nikki / fluent 主题等源码插件
  → 发布/覆盖更新 Packages Release（tag = immortalwrt-h28k-packages-v<版本>）：插件 ipk/apk 集合

阶段 2 · 固件快速组装（快，约 5 分钟，随时手动触发）
  H28K 固件快速组装：下载自建 ImageBuilder + 匹配版本的插件包
  → 注入 IP/密码/主题/软件包 → make image 组装 → ABI 与阶段 1 完全一致
  → 发布/覆盖更新 Custom Release（tag = immortalwrt-h28k-custom-v<版本>）

每个版本最多三个 Release（base / packages / custom），重复构建原地覆盖更新，不会堆积；全部工作流均为手动触发。日常使用请下载带 -custom 标识的定制固件。
```

- **阶段 1**：Actions → 「H28K 固件全量构建」→ 版本填 `X.Y.Z` / `X.Y-SNAPSHOT` / `master` / `all`（默认集合并行编译，见 `config/firmware.conf` 的 `supported_versions`，默认 `master`）。版本解析、源码锁定与 ABI 校验全自动，系列内任意版本可直接构建。为什么用自建而不是官方 ImageBuilder：官方 ImageBuilder 没有 `hinlink_h28k` 设备（无 device 配方、无 H28K DTB/u-boot），且预编译内核无法打补丁，H28K 支持只能从源码编出。自建 IB 会自动补写 `repositories` 在线源清单（官方 buildbot 产物自带、本地 `make imagebuilder` 不生成），IB 本地没有的包组装时从官方源在线拉取。
- **插件包**：Actions → 「H28K 插件包构建」→ 选版本。编译 `config/source-plugins.list` 里启用的源码插件（默认全注释，纯净固件可跳过）并长期保存到 Release；插件更新只需重跑这个（约 15~30 分钟），也可勾选"立即组装固件"一步出固件。
- **阶段 2**：Actions → 「H28K 固件快速组装」→ 选版本，改 `config/ib-packages.list` 即可换软件包组合；Release 总结里会列出当前启用的插件。**日常使用的固件来自这里**（基础固件不含第三方插件）。

（各配置文件的用法见文件内注释；历史详细文档见 git 历史中的 documents/ 目录）

## 目录结构

```
h28k-openwrt/
├── README.md
├── config/
│   ├── firmware.conf                # 初始化参数（开放系列、all 默认集合、LAN IP、密码、根目录大小、主题、ABI 开关）
│   ├── source-plugins.list          # 源码插件清单（唯一插件入口，默认全注释保持纯净）
│   ├── ib-packages.list             # 阶段 2 追加安装的官方源包
│   └── hinlink-h28k.config          # 目标与软件包选配种子（含 CONFIG_IB 产出自建 IB）
├── patches/
│   ├── 24.10/                       # 24.10 系补丁（7 个，含 RK3528 内核回移）
│   └── 25.12/                       # 25.12 系补丁（5 个板级补丁；master 构建时自动映射到此）
├── scripts/
│   ├── config.sh                    # 共享配置读取与校验（版本白名单、参数覆盖）
│   ├── select_release.sh            # 从已测试版本白名单解析版本 + 官方 kmods 哈希
│   ├── select_sdk.sh                # 解析官方 SDK 下载地址
│   ├── select_ib.sh                 # 选基础 Release（IB 附件 + 匹配版本的插件包附件）
│   ├── build_ib_image.sh            # 用自建 IB 组装定制固件（IP/密码/主题/包/根目录大小）
│   ├── apply_patches.sh             # 按字典序应用系列补丁
│   ├── prepare_kernel_config.sh     # 官方内核配置合成 + 根目录大小注入 + 24.10 vermagic 排除
│   └── build_config.sh              # 参数注入、源码包克隆、官方 kmod 源启用、ABI 校验
└── .github/workflows/
    ├── build-base.yml               # 阶段 1：全量源码构建（单版本或 all 并行）→ Base Release
    ├── build-packages.yml           # 插件包：官方 SDK 编译源码插件 → 独立 Packages Release
    └── build-custom.yml             # 阶段 2：固件快速组装（分钟级）→ Custom Release
```

## 固件组件

- **基础固件**（阶段 1 Release）与**默认定制固件**（阶段 2 产物）：均为纯净官方组件（`kmod-mt7921u`、`wpad-openssl`、`openssh-sftp-server`），**不含第三方插件**
- 需要第三方插件（nikki、fluent 主题等）：在 `config/source-plugins.list` 取消注释并重跑「构建插件包」，之后所有阶段 2 固件自动带上

## 设备信息

- 型号：HINLINK H28K
- SoC：Rockchip RK3528
- 架构：ARMv8 / AArch64
- LAN：`eth0`（板上 GMAC）
- WAN：`eth1`（PCIe RTL8111HS）
- 固件设备名：`hinlink_h28k`
