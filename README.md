# Docker Macvlan 在linux下的自动安装、卸载脚本

> 本项目文件由AI生成

让容器以“局域网独立主机”的方式加入与宿主机相同网段，采用 Docker IPAM 的静态 IP 分配，无需容器内 DHCP 客户端。容器在启动时指定 `--ip` 与（建议）`--mac-address`。

## 功能特性

- 创建并管理 Docker 的 `macvlan` 网络（默认名：`mymacvlan`）。
- 自动生成并安装一个 systemd `oneshot` 服务（`auto_macvlan`），开机时创建网络与宿主机侧接口。
- 根据所选物理网卡自动计算子网、网关，配置路由与宿主机 `macvlan` 接口（默认名：`macvlan-host`）。
- 提供交互式菜单：安装、卸载、查看状态、生成随机 MAC、查看使用说明。

## 环境要求

- Linux使用 `systemd` 的发行版
- 需要 `root` 权限。
- 依赖命令：`docker`、`ip`、`ipcalc`、`systemctl`。
- 不适用于 Windows 的 Docker Desktop 直接运行；WSL & 宿主网络环境可能不支持 `macvlan`。

## 使用

```bash
(command -v curl >/dev/null 2>&1 && curl -fsSL https://raw.githubusercontent.com/xcdd/auto_docker_macvlan/main/auto_macvlan_manager.sh -o auto_macvlan_manager.sh || wget -qO auto_macvlan_manager.sh https://raw.githubusercontent.com/xcdd/auto_docker_macvlan/main/auto_macvlan_manager.sh) && chmod +x auto_macvlan_manager.sh && sudo ./auto_macvlan_manager.sh
```

后续使用：

```
sudo ./auto_macvlan_manager.sh
```

安装后在系统中生成：

- `/usr/local/bin/auto_macvlan.sh`：具体的自动配置脚本。
- `/etc/systemd/system/auto_macvlan.service`：systemd 服务单元。

## 原理与实现要点

- 脚本会枚举物理网卡（排除 `lo`、`docker`、`veth`、`br-`、`macvlan`、`tun/tap`、`virbr` 等），由用户选择一个作为 `parent`。
- 通过 `ipcalc` 与路由表推导子网与网关；若未找到默认网关，尝试使用网段第一个 IP（`x.y.z.1`）作为网关。
- 创建 Docker `macvlan` 网络：

  ```bash
  docker network create -d macvlan \
    --subnet=<SUBNET> --gateway=<GATEWAY> \
    -o parent=<NETCARD> mymacvlan
  ```

- 创建宿主机侧 `macvlan` 虚拟接口 `macvlan-host` 并分配一个与宿主机同网段的地址（基于主机 IP 最后一位 +50 避免冲突，超过 254 时反向调整）。
- 添加路由以保证宿主机与 `macvlan` 网段互通：

  ```bash
  ip route add <SUBNET> dev macvlan-host
  ```

## 常见问题与注意事项

- 本脚本采用静态 IP 模式，不启用容器内 DHCP 客户端。
- 为每个容器分配唯一 `MAC` 可以提升路由器识别稳定性（建议使用菜单中的随机 MAC）。
- 某些环境（如部分虚拟化、云网络、Wi-Fi、桥接限制）可能不支持宿主机侧 `macvlan` 接口或导致互通受限。
- 如果 `systemctl`/`ipcalc` 等命令缺失，请先安装相应软件包。
- Windows Docker Desktop、WSL2 通常不适用该方案。