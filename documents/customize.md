# 定制说明

## config/firmware.conf（全局参数）

| 参数 | 说明 |
| --- | --- |
| `default_series` | 默认 ImmortalWrt 系列，只能填 `24.10` 或 `25.12`。Actions 手动触发时会显式选系列，此值只在本地调用脚本未传系列参数时作为回退 |
| `lan_ip` | 固件 LAN 管理地址，编译时直接替换 `config_generate` 中的默认地址 |
| `password` | root 密码明文，编译时以 SHA-512 哈希写入 `/etc/shadow` |
| `default_theme` | LuCI 默认主题，填 `luci-static` 下的目录名（如 `fluent`），留空不修改 |
| `check_official_abi` | `true` 时启用官方内核配置合成、官方 kmod 源和 ABI 强校验；**无特殊理由不要关闭**，关闭后固件将不再与官方源 ABI 一致 |

## config/packages.conf（额外软件包）

每行一条完整的 `git clone` 命令，克隆到 OpenWrt 源码树的 `package/` 下（目标路径相对源码根目录）。当前内置：

```
git clone --depth=1 -b main https://github.com/nikkinikki-org/OpenWrt-nikki.git package/OpenWrt-nikki
git clone --depth=1 https://github.com/LazuliKao/luci-theme-fluent.git package/luci-theme-fluent
```

这些包不经过 feeds，直接随源码编译，不影响内核 ABI，并会自动打包进自建 ImageBuilder 供阶段 2（快速定制构建）使用。

## config/ib-packages.list（快速定制构建的包列表）

阶段 2 在设备默认包之上追加安装的软件包，每行一个：

```
luci-app-nikki
luci-theme-fluent
kmod-mt7921u
openssh-sftp-server
```

- 包来源：自建 ImageBuilder 内置包（阶段 1 编译的 nikki、fluent 等）+ 官方软件源（组装时联网拉取）。
- 包版本冻结在阶段 1 构建时刻，升级包需重跑一次阶段 1。
- **kmod 只能选择官方源已有的包**——IB 内核与阶段 1 完全一致（ABI 不变），但阶段 2 没有源码编译环节。
- 想把默认 `wpad-basic-mbedtls` 换成 `wpad-openssl`：加 `-wpad-basic-mbedtls` 和 `wpad-openssl` 两行；若该版本 ImageBuilder 不支持负号移除默认包（会显式报错），删掉这两行即可——默认 wpad 同样能驱动 MT7921U。
- 阶段 2 只需要维护这一个文件：LAN IP / root 密码 / 默认主题自动取自 `config/firmware.conf`，以首启 `uci-defaults` 方式注入，与阶段 1 编译期注入效果相同。

## config/hinlink-h28k.config（设备选包种子）

保存目标、软件包和分区配置（`CONFIG_TARGET_rockchip_armv8_DEVICE_hinlink_h28k=y` 等）。构建时与官方 `config.buildinfo` 中的内核选项合成最终 `.config`。末尾的 `CONFIG_IB=y` 让阶段 1 构建完成后顺带产出自建 ImageBuilder——这是构建系统选项，不参与内核配置，不影响 ABI。

**选包规则（重要）**：

- **用户态包**（luci-app、主题、工具）随意增删，不影响 ABI。
- **kmod 包**只能选择官方软件源中已有的包：流水线启用了 `CONFIG_ALL_KMODS`，kmod 一律从官方 kmod 源安装；若选择官方源没有的 kmod，会触发源码编译并改变内核配置，**ABI 校验会直接失败**。这是门禁在保护你，不是 bug。
- 修改后建议先手动触发一次单系列构建验证 ABI 门禁通过。

## 新增 ImmortalWrt 系列（如未来的 26.x）

1. 新建 `patches/<系列>/`，放入该系列的板级补丁（文件名数字前缀决定应用顺序）。
2. 在以下三处把新系列加入白名单：
   - `scripts/resolve_series.sh` 的 `known_series`
   - `scripts/select_release.sh` 的系列正则 `^(24\.10|25\.12)$` 与版本正则 `^(24\.10|25\.12)\.[0-9]+$`
   - `scripts/config.sh` 的 `default_series` 校验
3. `.github/workflows/build.yml` 与 `build-local.yml` 的 `series` 选项列表中加入新系列。
4. 若官方该系列内核缺少 H28K 支持（如 24.10 之于 RK3528），需要先补内核回移补丁；若官方已有 RK3528 支持则只需板级补丁。
5. 手动触发构建验证 ABI 门禁，测试通过后更新 README 支持矩阵。

## 修改补丁

补丁是针对官方 release tag 的 `git diff`，应用目录即 ImmortalWrt 源码树根。上游小版本升级若导致上下文漂移，`git apply --3way` 通常能自动合并；失败时看构建日志中的 `.rej` 内容，在对应官方 tag 上重新生成补丁（`git diff` 后按原文件名命名，保留数字前缀）。
