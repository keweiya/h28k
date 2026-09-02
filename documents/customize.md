# 定制说明

## config/firmware.conf（初始化参数 / 默认值）

| 参数 | 说明 |
| --- | --- |
| `supported_versions` | **已测试版本白名单**（空格分隔）：板级补丁与 ABI 校验只对这些版本验证过，构建只能从中选择，每系列自动取最新的一个。官方新版本实测通过后再加入 |
| `default_series` | 回退系列（本地调用脚本未传系列参数时使用），白名单中必须有该系列的版本 |
| `lan_ip` | LAN 管理地址默认值（`192.168.100.1`）；阶段 1 编译期注入，阶段 2 以首启 uci-defaults 注入 |
| `password` | root 密码默认值（`password`），以 SHA-512 哈希写入 |
| `rootfs_size` | 固件根目录大小默认值，MiB（可选 512 / 1024 / 2048，默认 2048） |
| `default_theme` | LuCI 默认主题；**默认留空**（不修改，用内置 bootstrap 主题）。启用 fluent 等第三方主题后可填 `fluent` |
| `check_official_abi` | `true` 时启用官方内核配置合成、官方 kmod 源和 ABI 强校验；**无特殊理由不要关闭**，关闭后固件将不再与官方源 ABI 一致 |

工作流手动触发时可在输入框临时覆盖 `lan_ip` / `password` / `rootfs_size`，留空即使用这里的默认值；定时构建固定使用默认值。

## config/source-plugins.list（源码插件清单 —— 唯一的插件配置入口）

官方源码库里没有的第三方插件（nikki、fluent 主题等）都在这**一个文件**里配置，格式：

- `clone: ` 开头的行：git clone 命令，把插件源码克隆进 SDK 源码树
- 其他非注释行：要编译并安装进固件的包名（`make package/<名称>/compile` 的目标名）

```
# —— nikki（mihomo 代理）：取消注释以下两行启用 ——
# clone: git clone --depth=1 -b main https://github.com/nikkinikki-org/OpenWrt-nikki.git package/OpenWrt-nikki
# luci-app-nikki

# —— fluent LuCI 主题 ——
# clone: git clone --depth=1 https://github.com/LazuliKao/luci-theme-fluent.git package/luci-theme-fluent
# luci-theme-fluent
```

- **默认全部注释**（固件保持纯净的官方组件）；启用 = 取消注释对应两行，然后重跑「构建插件包」工作流（可勾选"编译完插件后立即组装固件"）。
- 这里启用的插件在阶段 2 组装固件时**自动安装**（插件包 tar 内附包名清单），**不要**再写进 `ib-packages.list`。
- 注意：不要填官方包的子包名（编译目标名对不上会失败）；kmod 一律不写在这里（由官方源在组装时提供，ABI 才一致）。
- 插件更新：重跑「构建插件包」（约 15~30 分钟），无需重编固件。

## config/ib-packages.list（官方源包开关清单，y/n 格式）

由 `scripts/fetch_official_packages.sh` 从官方源自动生成的**全部官方插件包目录**（3184 个，来自 packages/luci/routing/telephony 四个插件源），每行一个包：

```
kmod-mt7921u=y          # 清单外小节：base/kmods 源的包
wpad-openssl=y
openssh-sftp-server=y
464xlat=n
6in4=n
luci-app-docker=n
luci-app-openclash=n
...
```

- **`=y` 安装进固件，`=n` 不安装**；默认只有 kmod-mt7921u、wpad-openssl、openssh-sftp-server 三个是 `=y`，其余全部 `=n`。
- 启用想要的插件：把对应行改成 `=y`（用编辑器搜索，如 `luci-app-docker`），下次「快速定制构建」自动带上，无需重编固件。
- 重新生成/换版本生成：`bash scripts/fetch_official_packages.sh <版本> config/ib-packages.list`——**已启用（=y）的会保留**，新增包默认 `=n`。
- 覆盖范围：四个插件源（packages/luci/routing/telephony）；base 核心与 kmod 不在目录里，需要时手动加在文件末尾"清单外的官方包"小节（如 `kmod-usb-storage=y`）。
- 源码第三方插件**不要**写在这里（由 source-plugins.list 自动带入）。
- 组装时 opkg/apk 会自动从官方在线源拉取所选包及其依赖（含 kmod），与官方 release 完全一致——这是 ABI 保证的一部分。

## 添加自定义插件要改几处？

| 场景 | 改哪里 |
| --- | --- |
| 生成 ImageBuilder（阶段 1） | **0 处**——IB 与插件无关，保持纯净 |
| 用 IB 组装固件（阶段 2） | **0 处**——source-plugins.list 启用的插件自动带入 |
| 加官方源已有的包 | **1 处**：`ib-packages.list` |
| 加源码插件 | **1 个文件 2 行**：`source-plugins.list` 加 clone 行 + 包名行，重跑「构建插件包」 |

## config/hinlink-h28k.config（设备选包种子）

保存目标与软件包选配（`CONFIG_TARGET_rockchip_armv8_DEVICE_hinlink_h28k=y` 等）。构建时与官方 `config.buildinfo` 中的内核选项合成最终 `.config`。末尾的 `CONFIG_IB=y` 让阶段 1 构建完成后顺带产出自建 ImageBuilder——这是构建系统选项，不参与内核配置，不影响 ABI。根目录大小（`CONFIG_TARGET_ROOTFS_PARTSIZE`）统一由 `firmware.conf` 的 `rootfs_size` 控制，不要写在这里。

**选包规则（重要）**：

- **用户态包**（luci-app、主题、工具）随意增删，不影响 ABI。
- **kmod 包**只能选择官方软件源中已有的包：流水线启用了 `CONFIG_ALL_KMODS`，kmod 一律从官方 kmod 源安装；若选择官方源没有的 kmod，会触发源码编译并改变内核配置，**ABI 校验会直接失败**。这是门禁在保护你，不是 bug。
- 修改后建议先手动触发一次单系列构建验证 ABI 门禁通过。

## 新增版本 / 系列

**新增已测试版本（同系列，如未来的 24.10.7）**：官方发布后先实测——补丁能否应用、ABI 能否对齐、功能是否正常——然后把版本号加入 `config/firmware.conf` 的 `supported_versions`。这是唯一需要改的地方：定时构建会自动取该系列最新的已测试版本，旧版本的重复构建会被"已构建自动跳过"拦住。

**新增系列（如未来的 26.x）**：

1. 新建 `patches/<系列>/`，放入该系列的板级补丁（文件名数字前缀决定应用顺序）。
2. `supported_versions` 加入该系列版本。
3. `.github/workflows/build.yml` 的 `series` 选项和 `delete-older-releases.yml` 的版本正则中加入新系列。
4. 若官方该系列内核缺少 H28K 支持（如 24.10 之于 RK3528），需要先补内核回移补丁；若官方已有 RK3528 支持则只需板级补丁。
5. 手动触发构建验证 ABI 门禁，测试通过后更新 README 支持矩阵。

## 修改补丁

补丁是针对官方 release tag 的 `git diff`，应用目录即 ImmortalWrt 源码树根。上游小版本升级若导致上下文漂移，`git apply --3way` 通常能自动合并；失败时看构建日志中的 `.rej` 内容，在对应官方 tag 上重新生成补丁（`git diff` 后按原文件名命名，保留数字前缀）。
