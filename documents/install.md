# 刷机与升级

产物为 `*hinlink_h28k*sysupgrade.img.gz`（Release 附件），同一份镜像适用于 SD 启动和 EMMC。

## 写入 SD 卡启动

1. 解压得到 `.img`（或直接用 `.img.gz`，多数工具支持）。
2. 使用 balenaEtcher / Rufus（选 DD 模式）/ `dd` 写入 SD 卡：

   ```bash
   xz -d 2>/dev/null; dd if=*-hinlink_h28k*-sysupgrade.img of=/dev/sdX bs=4M conv=fsync status=progress
   ```

3. SD 卡插入 H28K，上电启动。启动完成后用网线连接 LAN 口（`eth0`）。

## 安装到 EMMC

两种常用方式（以设备实际可达者为准）：

- **从 SD 系统内升级写入**：SD 启动后，LuCI → 系统 → 备份/升级 → 刷写新固件，选择 sysupgrade 镜像并勾选"保留配置"按需；或在 SSH 中 `sysupgrade` 写入 EMMC。
- **dd 直写**：SD 启动后 SSH 执行 `lsblk` 确认 EMMC 设备名（`/dev/mmcblk0` 或 `/dev/mmcblk1`），将镜像 dd 到该整盘设备后重启拔卡。

也可以在 U-Boot 下用 `ums 0 mmc 1` 把 EMMC 暴露为 USB 存储，由电脑直接写入镜像（调试口 1500000 8n1）。

> Rockchip 镜像写入位置从扇区 0 开始由镜像自身负责（idbloader 等有固定偏移），不要手动跳过扇区。

## 升级固件

新版本发布后，直接在 LuCI 上传 sysupgrade 镜像升级（可选保留配置），或重新写 SD / dd EMMC。升级前后均为同一 ABI（与官方 release 一致），已安装的官方源插件在保留配置升级后可继续使用。

## 首次配置

- 管理地址与 root 密码见 Release 说明（由 `config/firmware.conf` 的 `lan_ip` / `password` 决定）。
- WAN 口为 `eth1`（PCIe RTL8111HS），LAN 口为 `eth0`。
- 无线：本机无内置 Wi-Fi，需插入 USB 无线网卡（固件已内置 `kmod-mt7921u`，对应 MT7921U 系列网卡；其他网卡可按 customize.md 选包规则自行增补）。
