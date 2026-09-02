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

## 快速定制构建（阶段 2）的固件 ABI 一致吗？

一致。阶段 2 不编译任何源码：ImageBuilder 里的内核和 kmod 就是阶段 1 全量构建通过 ABI 门禁的那一份，`make image` 只是把包组装进镜像。kmod 在组装时从官方软件源拉取（与官方 release 同一 URL），因此从定制固件上用官方源装插件与基础固件完全相同。

注意阶段 2 的包版本冻结在阶段 1 构建时刻（nikki、主题等自编译包在 IB 内）；要升级这些包，重跑一次阶段 1。

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
