# 常见问题

## 安装插件报 vermagic / 内核不匹配？

本仓库固件与官方 release ABI 一致，正常情况下不会出现。排查顺序：

1. 确认固件来自本仓库 Actions 产物（构建日志中"校验内核 ABI"一步通过）。
2. 确认没有在 `config/hinlink-h28k.config` 里选择官方源没有的 kmod 包（见 customize.md 选包规则）。
3. 确认 `config/firmware.conf` 的 `check_official_abi=true`。

## 为什么固件里没有 luci-app-amlogic / 不能多内核切换 / 不能图形化装 EMMC？

这是设计决策，不是遗漏。这些功能依赖 amlogic-s9xxx-openwrt 的 armsr rootfs + remake 重打包机制，该机制会整体替换内核模块，导致与官方插件仓库的 ABI 不一致——与"官方插件可直接安装"这一硬性要求互斥。完整决策记录见 README"设计说明"一节。EMMC 安装请看 [install.md](install.md)。

## 为什么只能构建固定几个版本？

`config/firmware.conf` 的 `supported_versions` 是已测试版本白名单：板级补丁和官方 ABI 校验只对这些版本验证过。官方发布新版本后，需要先实测补丁能否应用、ABI 能否对齐，再把新版本加入白名单——这样任何构建产物的 ABI 都是可靠的。填入白名单之外的版本会被直接拒绝。

## 设备上怎么安装插件？24.10 是 ipk、25.12 是 apk，有影响吗？

- **官方源里有的包**：直接在设备上在线安装（24.10 用 `opkg install` 装 .ipk，25.12 用 `apk add` 装 .apk），与固件来自哪个构建流程无关，官方源的包都可用。
- **第三方插件（nikki、fluent 等，官方源没有）**：已由「快速定制构建」打进固件；也可以从插件包 Release 下载对应格式的包手动安装（24.10 为 .ipk，25.12 为 .apk）。
- 本仓库自动适配：SDK 产出什么格式就收集什么格式，ImageBuilder 组装时用对应版本的包管理器安装，无需人工区分。

## ext4 固件和 LXC 镜像怎么来的？

阶段 1 已开启 `CONFIG_TARGET_ROOTFS_EXT4FS` 与 `CONFIG_TARGET_ROOTFS_TARGZ`：

- **LXC/容器镜像**：Release 里的 `*-rootfs.tar.gz`（target 级根目录打包，不含内核），解包到 LXC/容器目录即可使用（内核由宿主机提供，需宿主内核支持相应网络/防火墙特性）。
- **ext4 固件**：官方 rockchip 对每个设备都同时发布 ext4 + squashfs 双变体（已核对官方 Release 目录），本仓库同样会产出 `-ext4-sysupgrade.img.gz`，刷写方式与 squashfs 相同。两者均为镜像组装选项，不影响内核与 ABI。

## 为什么固件里默认没有 nikki 和 fluent 主题？

按需启用：`config/source-plugins.list` 里的第三方插件**默认全部注释**，阶段 1 基础固件和默认定制固件都是纯净官方组件。需要时取消注释对应两行（clone + 包名），重跑「构建插件包」（约 15~30 分钟，可勾选"编译完插件后立即组装固件"），之后的定制固件自动带上；插件更新同样只需重跑这个工作流。

## 快速定制构建（阶段 2）的固件 ABI 一致吗？

一致。阶段 2 不编译任何源码：ImageBuilder 里的内核和 kmod 就是阶段 1 全量构建通过 ABI 门禁的那一份，`make image` 只是把包组装进镜像。kmod 在组装时从官方软件源拉取（与官方 release 同一 URL），因此从定制固件上用官方源装插件与基础固件完全相同。

注意第三方插件（nikki、fluent）的 ipk 来自「构建插件包」工作流发布的 Release（基于官方 SDK、与固件同 musl ABI），更新插件只需重跑该工作流（约 15~30 分钟）；kmod 与官方源包在组装时联网拉取，始终与官方 release 一致。

## 构建在"应用补丁"一步失败，提示 .rej

上游新版本改动了补丁涉及的文件。构建日志里会打印每个 `.rej` 的内容，定位是哪个补丁的哪个 hunk 失败，在对应官方 tag 上重新生成补丁（步骤见 customize.md"修改补丁"）。

## 24.10 构建在"校验内核 ABI"一步失败

24.10 系的 ABI 哈希通过排除 `CONFIG_CLK_RK3528=y` 与官方对齐（`scripts/prepare_kernel_config.sh` 的 `exclude_rk3528_from_abi`）。若失败，通常是官方升级了 24.10 的内核小版本或调整了内核配置，`config.buildinfo` 的内核选项集合发生变化：

1. 对比构建 `.vermagic` 与官方 kmods 目录哈希确认不一致；
2. 检查官方 `config.buildinfo` 中 `CONFIG_KERNEL_*` 的变化，确认 `hinlink-h28k.config` 与补丁没有引入新的内核配置差异；
3. 若是补丁新增了官方没有的内核选项，参照 `CONFIG_CLK_RK3528` 的方式把该选项也加入 vermagic 排除规则。

## 如何新增 ImmortalWrt 系列？

见 [customize.md](customize.md)"新增 ImmortalWrt 系列"。

## 下载阶段很慢 / dl 缓存无效

托管构建按系列缓存 `source/dl`。官方发新版后缓存 key 变化，首个构建会全量下载（约 90 分钟超时上限），之后恢复。手动触发时可先构建一次单系列预热缓存。
