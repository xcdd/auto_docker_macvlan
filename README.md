# Docker Macvlan 在linux下的自动安装、卸载脚本

> 本项目文件由AI生成，仅用于学习与研究，不建议在生产环境中使用。
> 本脚本在Debian 12+系统中进行代码调试并确认可运行。

作者在使用Unraid这款NAS系统的Docker功能时，发现系统界面支持直接为容器配置外网IPv4地址，用户体验很好，而Docker的默认安装并不支持此功能，所以找AI写了这个脚本，试图降低配置门槛。
通过使用本脚本，可在 Linux 环境下通过 macvlan 让 Docker 容器加入宿主机同网段；使用静态 IPv4（Docker IPAM），不依赖容器内 DHCP 功能。脚本会创建 `mymacvlan` 网络与宿主侧 `macvlan-host` 接口，并提供容器主机路由管理与随机 MAC 工具。

## 功能特性

- 创建并管理 Docker 的 `macvlan` 网络（默认名：`mymacvlan`）。
- [可选]安装并启用一个 systemd 服务（`auto_macvlan`），在系统启动时自动执行一次网络配置（如需在系统运行时适配网络变化，可手动 `systemctl restart auto_macvlan`）。
- [可选]根据所选物理网卡自动计算子网与网关，创建宿主机侧 `macvlan` 接口（默认名：`macvlan-host`），并为其分配与宿主同网段的 IPv4（基于宿主 IP 最后一段 +50，越界则回退）。
- 提供主机到容器可访问性的网络路由配置；按需为某一容器添加主机路由，避免影响其他内网服务。
- 提供随机 MAC 生成工具，便于为容器分配唯一 MAC。
- 交互式菜单：安装/卸载、只创建宿主接口、保留宿主接口的卸载、查看状态、随机 MAC、添加/删除容器路由、查看使用说明。
- 为避免影响同网段其它服务，默认不向宿主机整个网段添加到容器的路由（即宿主机到容器之间的网络不通）。如需从宿主机访问某个容器，请继续使用该脚本添加路由：
- 默认为 `macvlan-host` 接口关闭 IPv6 自动配置（RA/SLAAC），避免接口自动获得 IPv6 地址。

## 环境要求

- 能安装 Docker 的常见 Linux 发行版系统。（如需在系统启动时自动执行一次网络配置，需支持使用 `systemd` ）
- 需要 `root` 权限。
- 依赖命令：`docker`、`ip`、`systemctl`[可选]、`ipcalc`[可选]
- 不适用于 Windows 的 Docker Desktop 直接运行；WSL & 宿主网络环境可能不支持 `macvlan`。

## 使用

```bash
(command -v curl >/dev/null 2>&1 && curl -fsSL https://raw.githubusercontent.com/xcdd/auto_docker_macvlan/main/auto_macvlan_manager.sh -o auto_macvlan_manager.sh || wget -qO auto_macvlan_manager.sh https://raw.githubusercontent.com/xcdd/auto_docker_macvlan/main/auto_macvlan_manager.sh) && chmod +x auto_macvlan_manager.sh && sudo ./auto_macvlan_manager.sh
```

后续使用：

```
sudo ./auto_macvlan_manager.sh
```

安装后，会在系统中生成：

- `/usr/local/bin/auto_macvlan.sh`：具体的自动配置脚本。
- `/etc/systemd/system/auto_macvlan.service`：systemd 服务单元。

- 如果你使用家用路由器，你往往还需要规划哪一段IP地址用于分配给容器，并在路由器上设置后续DHCP派发的范围不要与这一段IP冲突。

## 常见问题与注意事项

- 本脚本采用静态 IP 模式，不启用容器内 DHCP 客户端。
- 为每个容器分配唯一 `MAC` 可以提升路由器识别稳定性（建议使用菜单中的随机 MAC）。
- 某些环境（如部分虚拟化、云网络、Wi-Fi、桥接限制）可能不支持宿主机侧 `macvlan` 接口或导致互通受限。
- 如果 `systemctl`/`ipcalc` 等命令缺失，请先安装相应软件包。
- Windows Docker Desktop、WSL2 的Docker不适用该方案（但你也可以用AI来参考写一个并真机调试，写好了来发个issue吧，我很乐意加个项目链接）