# 构建说明

## 三段式构建

```
阶段 1 · 全量源码构建（build.yml）
  官方源码 + H28K 补丁全量编译 → check-abi 门禁
  → Release：基础固件（不含第三方插件）+ 自建 ImageBuilder（immortalwrt-imagebuilder-*.tar.xz）
  耗时 1.5~3 小时；仅在官方发新版或手动触发时需要执行

插件包 · SDK 独立编译（build-packages.yml）
  官方 SDK（与固件同版本、同 musl ABI）编译 config/sdk-packages.list 里的源码插件
  → Release 长期保存 ipk 集合（h28k-packages-v<版本>.tar.gz）
  耗时约 15~30 分钟；nikki 等插件更新时只需重跑这个，无需重编固件

阶段 2 · 快速定制构建（build-custom.yml）
  下载自建 ImageBuilder + 匹配版本的插件包 ipk → 注入 IP/密码/主题/软件包
  → make image 组装 → 定制 sysupgrade 固件
  耗时约 5 分钟；改包组合、迭代配置用这个
```

所有产物内核和 kmod 完全相同（阶段 2 不编译任何源码，插件 ipk 与固件同 ABI），ABI 一致。为什么必须用**自建** ImageBuilder：官方 IB 没有 `hinlink_h28k` 设备与 H28K 的 DTB/u-boot，预编译内核也无法打补丁重建。

## Release 结构总览

| Release 标签 | 生成者 | 附件 | 保留策略 |
| --- | --- | --- | --- |
| `h28k-v<版本>-<日期>`（如 `h28k-v25.12.1-20260906`） | 阶段 1 | ① 基础固件 `*-hinlink_h28k-sysupgrade.img.gz`（官方源组件，**不含第三方插件**）② 自建 ImageBuilder `immortalwrt-imagebuilder-rockchip-armv8.*.tar.xz` | 每系列保留最近 3 个 |
| `h28k-packages-v<版本>-<日期>` | 插件包工作流 | `h28k-packages-v<版本>.tar.gz`：SDK 编译的 `luci-app-nikki`、`nikki`（mihomo 核心）、`luci-theme-fluent` 及其用户态依赖 ipk（不含 kmod） | 保留最近 3 个 |
| `h28k-custom-<基础标签>-<时间>` | 阶段 2（可选发布） | 定制固件 `*-hinlink_h28k-sysupgrade.img.gz`（基础 + 插件 + 你的参数） | 保留最近 3 个 |

组装阶段 2 固件时，kmod（如 nikki 依赖的 kmod-tun、kmod-nft-tproxy）由官方软件源在线提供——与官方 release 完全一致，这是 ABI 保证的一部分；插件包 Release 里刻意不放 kmod。

## 工作流总览

| 工作流 | 触发方式 | 耗时（量级） |
| --- | --- | --- |
| 编译 HINLINK H28K 固件（build.yml） | 每周日定时 + 手动 | 全新 1.5~3h，版本已发布则秒级跳过 |
| 构建插件包（build-packages.yml） | 手动 | 15~30 分钟 |
| 快速定制构建（build-custom.yml） | 手动 | ~5 分钟 |
| 清理历史 Release | 每周日定时 + 手动 | 秒级 |

运行器统一使用 GitHub 托管 `ubuntu-24.04`。全量构建在公开仓库免费，私有仓库消耗 Actions 额度。

## 手动触发参数

**要构建的 ImmortalWrt 系列**：

- `all`：两个系列同时构建（默认，定时构建固定为 all）。
- `24.10` / `25.12`：只构建所选系列。

**精确版本**（可选）：只能填 `config/firmware.conf` 中 `supported_versions` 白名单内的版本（如 `v24.10.6`、`25.12.1`）。**版本对应是固定的**——板级补丁与 ABI 校验只对这些版本验证过，填其他版本会直接报错拒绝构建；留空则每个系列自动取白名单中最新的版本。

**固件参数**（手动触发时可临时覆盖，留空 = 使用 `config/firmware.conf` 默认值）：

| 输入 | 说明 | 默认 |
| --- | --- | --- |
| LAN 管理地址 | 有效的 IPv4 地址 | `192.168.100.1` |
| root 密码 | 明文 | `password` |
| 根目录大小 | 512M / 1G / 2G | 2G（2048 MiB） |

定时构建没有输入，固定使用 `config/firmware.conf` 中的默认值。

**强制重建**（force_build，可选）：阶段 1 在解析版本后会检查该版本是否已发过固件 Release，已发布则整个构建自动跳过——每周定时构建因此几乎零成本。需要重新出包（比如改了 `firmware.conf` 或补丁）时勾选 force_build。

不填固定版本时，构建结果跟随官方 release。如果上游变动导致补丁不再适用，`git apply --3way` 会显式失败并留下 `.rej` 文件，构建红叉即回归信号。

## 快速定制构建（阶段 2）参数

- **基础固件系列**：使用哪个系列的 ImageBuilder。
- **基础 Release 标签**（可选）：留空自动选该系列最新的、附带 ImageBuilder 的 Release。
- **LAN 地址 / root 密码 / 根目录大小**（可选）：留空使用 `config/firmware.conf` 默认值，也可触发时直接填写。
- **发布为 Release**：默认关闭（只上传 Artifact，避免 Release 列表膨胀）；开启后以 `h28k-custom-<基础标签>-<时间>` 为标签发布。

定制内容也可以在仓库文件中预先改好：

- 软件包：`config/ib-packages.list`（在设备默认包之上追加）。
- LAN IP / root 密码 / 默认主题：`config/firmware.conf`，以首启 `uci-defaults` 方式注入（与阶段 1 编译期注入效果相同）。
- 根目录大小：通过 `ROOTFS_PARTSIZE` 传给 ImageBuilder；若所用 IB 版本不支持该覆盖，则以基础构建时的根目录大小为准。

阶段 2 的软件包版本冻结在阶段 1 构建时刻（nikki、主题等自编译包在 IB 内）；要升级这些包，重跑一次阶段 1 即可。

## 产物

每个系列产出一个 Release，标签格式 `h28k-v<版本>-<日期>`（日期为 Asia/Hong_Kong 时区），例如：

- `h28k-v24.10.6-20260906`
- `h28k-v25.12.1-20260906`

Release 附件包含两类文件：

- `bin/targets/rockchip/armv8/*hinlink_h28k*sysupgrade.img.gz`：默认配置固件。
- `immortalwrt-imagebuilder-rockchip-armv8.*.tar.xz`：**自建 ImageBuilder**，供"快速定制构建"工作流（阶段 2）使用。

Release 说明中记录上游 commit、管理地址和 root 密码。25.12 为主力系列，其 Release 会标记为仓库 latest。

托管构建同时上传 30 天保留期的 Artifact，失败时上传 7 天保留期的编译日志。

## 缓存与清理

- **下载缓存**：`source/dl` 按系列缓存（`actions/cache`），命中后 `make download` 阶段从几分钟缩短到秒级。key 含上游版本号，新版本自动重建。
- **磁盘清理**：托管运行器构建前清理预装组件释放磁盘（rockchip 全量编译约需 25–30 GB）；自托管构建默认关闭清理，可用 `cleanup_disk` 输入控制。
- **Release 清理**：`delete-older-releases.yml` 每个系列只保留最近 3 个（可用 `keep_per_series` 输入调整），不触碰其他命名格式的 Release。

## 本地手动构建（不经 Actions）

在 Linux（Ubuntu 24.04）上按顺序执行：

```bash
sudo apt-get install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison \
  build-essential bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex \
  gawk genisoimage gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man \
  intltool lib32gcc-s1 libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev \
  libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev libtool \
  libyaml-dev lld llvm lrzsz msmtp ninja-build openssl p7zip-full patch pkgconf python3 \
  python3-pip python3-ply python3-docutils python3-pyelftools qemu-utils re2c rsync scons \
  squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip wget xmlto xxd zlib1g-dev zstd

# 1. 解析版本（系列可省略，回退到 firmware.conf 的 default_series）
bash scripts/select_release.sh config/firmware.conf release.env 25.12
source <(sed 's/^/export /' release.env)

# 2. 克隆官方源码
git clone --branch "$tag" --single-branch --depth=1 \
  https://github.com/immortalwrt/immortalwrt.git source

# 3. 应用补丁（$series 取 release.env 中的值）
(cd source && bash ../scripts/apply_patches.sh . "../patches/$series")

# 4. 官方 feeds
curl -fsSL "https://downloads.immortalwrt.org/releases/$version/targets/rockchip/armv8/feeds.buildinfo" \
  -o source/feeds.conf.default
(cd source && ./scripts/feeds update -a && ./scripts/feeds install -a)

# 5. 构建配置 + 内核配置
bash scripts/build_config.sh prepare source config/firmware.conf "" env.file
bash scripts/prepare_kernel_config.sh source config/firmware.conf "$version" "$series" config/hinlink-h28k.config

# 6. 下载 + 编译
(cd source && make -j"$(nproc)" download && make -j"$(nproc)" V=s)

# 7. 校验 ABI（$kernel_kmods 取 release.env 中的值）
bash scripts/build_config.sh check-abi source config/firmware.conf "$version" "$tag" "$kernel_kmods"
```

产物位于 `source/bin/targets/rockchip/armv8/`。
