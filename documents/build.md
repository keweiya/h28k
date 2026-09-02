# 构建说明

## 工作流总览

| 工作流 | 运行器 | 触发方式 | 作用 |
| --- | --- | --- | --- |
| 编译 HINLINK H28K 固件（build.yml） | GitHub 托管 `ubuntu-24.04` | 每周日定时 + 手动 | 解析系列矩阵，并行构建所选系列 |
| 自托管编译（build-local.yml） | 自托管 `h28k-builder` | 手动 | 同上，运行在自己的机器上 |
| 编译固件（build-firmware.yml） | 由上面两者调用 | 不直接触发 | 单系列完整流水线（可复用） |
| 清理历史 Release | GitHub 托管 | 每周日定时 + 手动 | 每系列保留最近 N 个 Release |

## 手动触发参数

**要构建的 ImmortalWrt 系列**：

- `all`：两个系列同时构建（默认，定时构建固定为 all）。
- `24.10` / `25.12`：只构建所选系列。

**固定版本**（可选）：填写精确版本号，如 `v24.10.6` 或 `25.12.1`（`v` 前缀可省略）。填写后只构建该版本所属的系列；留空则自动选择该系列最新的、官方 kmods 仍然可用的正式版。

不填固定版本时，构建结果跟随官方 release：官方发布新点版本后，下一次定时构建自动跟上。如果上游变动导致补丁不再适用，`git apply --3way` 会显式失败并留下 `.rej` 文件，构建红叉即回归信号。

## 产物

每个系列产出一个 Release，标签格式 `h28k-v<版本>-<日期>`（日期为 Asia/Hong_Kong 时区），例如：

- `h28k-v24.10.6-20260906`
- `h28k-v25.12.1-20260906`

Release 附件为 `bin/targets/rockchip/armv8/*hinlink_h28k*sysupgrade.img.gz`，Release 说明中记录上游 commit、管理地址和 root 密码。25.12 为主力系列，其 Release 会标记为仓库 latest。

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
bash scripts/build_config.sh prepare source config/firmware.conf config/packages.conf env.file
bash scripts/prepare_kernel_config.sh source config/firmware.conf "$version" "$series" config/hinlink-h28k.config

# 6. 下载 + 编译
(cd source && make -j"$(nproc)" download && make -j"$(nproc)" V=s)

# 7. 校验 ABI（$kernel_kmods 取 release.env 中的值）
bash scripts/build_config.sh check-abi source config/firmware.conf "$version" "$tag" "$kernel_kmods"
```

产物位于 `source/bin/targets/rockchip/armv8/`。
