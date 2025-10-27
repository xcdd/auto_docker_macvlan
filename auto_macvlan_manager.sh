#!/bin/bash

# 说明：
# 该脚本在宿主机上创建并管理 Docker 的 macvlan 网络，
# 让容器以“局域网独立主机”的方式加入与宿主机相同网段。
#
# 简化原则：使用 Docker IPAM 的静态/固定 IP 分配，无需容器内 DHCP 客户端。
# - 创建 macvlan 网络时指定子网和网关；
# - 运行容器时直接指定 IP（docker run --ip 或 Compose 的 ipv4_address）；
# - 如需路由器识别或固定地址，可指定 MAC（--mac-address / mac_address）。
#
# 运行完成后需要做的事：为容器规划静态 IP，并配置唯一的 MAC。
# 运行容器时务必在命令或 Compose 中设置 --ip 与 --mac-address。

SERVICE_SCRIPT="/usr/local/bin/auto_macvlan.sh"
SERVICE_UNIT="/etc/systemd/system/auto_macvlan.service"
SERVICE_NAME="auto_macvlan"

# 生成本地管理的随机 MAC 地址（unicast），以 02 开头避免冲突
function generate_mac() {
  if command -v hexdump >/dev/null 2>&1; then
    local tail_bytes
    tail_bytes=$(hexdump -n5 -v -e '5/1 "%02x:"' /dev/urandom)
    tail_bytes=${tail_bytes%:}
    echo "02:${tail_bytes}"
  else
    # 兼容环境：使用 bash 的 RANDOM 作为后备
    printf "02:%02x:%02x:%02x:%02x:%02x\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
  fi
}

# 菜单项：打印一个随机 MAC 地址供用户使用
function print_random_mac() {
  local mac
  mac=$(generate_mac)
  echo "随机 MAC 地址：${mac}"
  echo "示例 docker run: docker run --network=mymacvlan --ip 192.168.x.y --mac-address ${mac} busybox sleep infinity"
}

# 安装完成后的下一步指引
function show_next_steps() {
  local mac
  mac=$(generate_mac)
  echo ""
  echo "下一步指引："
  echo "- 规划一个未占用的静态 IP（与宿主机同网段）"
  echo "- 为容器指定唯一 MAC（路由器识别更稳定）：${mac}"
  echo "- 示例命令：docker run --network=mymacvlan --ip 192.168.x.y --mac-address ${mac} busybox sleep infinity"
  echo "- Compose 可在服务下设置 ipv4_address 与 mac_address"
}

function select_nic() {
  echo "正在检测可用的物理网卡..."
  echo "-------------------------------"
  
  # 获取所有网卡，排除虚拟网卡、回环、docker等
  nics=$(ip link | awk -F: '$0 !~ "lo|docker|veth|br-|macvlan|tun|tap|virbr" && NR%2==1 {gsub(/ /, "", $2); print $2}')
  
  if [ -z "$nics" ]; then
    echo "错误：未检测到可用的物理网卡！"
    exit 1
  fi
  
  echo "序号  网卡名称    IP地址"
  echo "-------------------------------"
  
  i=1
  declare -a nic_array
  for nic in $nics; do
    # 获取网卡IP地址
    ip_addr=$(ip -4 addr show $nic 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    if [ -z "$ip_addr" ]; then
      ip_addr="未分配IP"
    fi
    echo "$i     $nic        $ip_addr"
    nic_array[$i]=$nic
    ((i++))
  done
  
  echo "-------------------------------"
  # 读取并校验用户选择的网卡序号（循环直到有效）
  local nic_choice
  while true; do
    read -p "请输入要使用的网卡序号(1-$((i-1)))：" nic_choice
    if [[ "$nic_choice" =~ ^[0-9]+$ ]] && [ "$nic_choice" -ge 1 ] && [ "$nic_choice" -lt "$i" ]; then
      break
    else
      echo "无效选择，请输入数字 1-$((i-1))。"
    fi
  done
  
  SELECTED_NIC=${nic_array[$nic_choice]}
  echo "已选择网卡：$SELECTED_NIC"
}


function install_macvlan_service() {
  select_nic
  
  # 写入自动macvlan配置脚本，使用选定的网卡和DHCP模式
  cat > $SERVICE_SCRIPT << EOF
#!/bin/bash
NETCARD="$SELECTED_NIC"
MACVLAN_NAME="mymacvlan"
VMHOST_IF="macvlan-host"

# 检查网卡是否存在
if ! ip link show \$NETCARD &>/dev/null; then
  echo "错误：网卡 \$NETCARD 不存在！"
  exit 1
fi

# 获取网卡IP和网段信息
IP_INFO=\$(ip -4 addr show \$NETCARD 2>/dev/null | grep 'inet ' | awk '{print \$2}' | head -1)
if [ -z "\$IP_INFO" ]; then
  echo "错误：网卡 \$NETCARD 未分配IP地址！"
  exit 1
fi

IP_ADDR=\$(echo \$IP_INFO | cut -d'/' -f1)
NETMASK=\$(echo \$IP_INFO | cut -d'/' -f2)

# 计算网段
NETWORK=\$(ipcalc -n \$IP_INFO 2>/dev/null | awk -F'=' '/NETWORK/ {print \$2}')
if [ -z "\$NETWORK" ]; then
  # 备用方法计算网段
  NETWORK=\$(echo \$IP_ADDR | awk -F. '{print \$1"."\$2"."\$3".0"}')
fi
SUBNET="\$NETWORK/\$NETMASK"

# 获取网关
GATEWAY=\$(ip route | grep default | grep \$NETCARD | awk '{print \$3}' | head -1)
if [ -z "\$GATEWAY" ]; then
  echo "警告：未找到默认网关，尝试使用网段第一个IP作为网关"
  GATEWAY=\$(echo \$NETWORK | awk -F. '{print \$1"."\$2"."\$3".1"}')
fi

echo "网卡: \$NETCARD"
echo "IP: \$IP_ADDR/\$NETMASK"
echo "网段: \$SUBNET"
echo "网关: \$GATEWAY"

# 清理旧配置
docker network rm \$MACVLAN_NAME 2>/dev/null
ip link delete \$VMHOST_IF 2>/dev/null

echo "正在创建macvlan网络（Docker IPAM 模式）..."
if docker network create -d macvlan --subnet=\$SUBNET --gateway=\$GATEWAY -o parent=\$NETCARD \$MACVLAN_NAME; then
  echo "macvlan网络创建成功"
else
  echo "错误：macvlan网络创建失败！"
  exit 1
fi

# 创建宿主机macvlan虚拟接口
echo "正在创建宿主机macvlan虚拟接口..."
if ip link add \$VMHOST_IF link \$NETCARD type macvlan mode bridge; then
  # 为虚拟接口分配IP（主机IP最后一位+50，避免冲突）
  LAST_OCTET=\$(echo \$IP_ADDR | awk -F. '{print \$4}')
  NEW_OCTET=\$((LAST_OCTET + 50))
  if [ \$NEW_OCTET -gt 254 ]; then
    NEW_OCTET=\$((LAST_OCTET - 50))
  fi
  HOST_IF_IP=\$(echo \$IP_ADDR | awk -F. '{print \$1"."\$2"."\$3"."}')"\$NEW_OCTET"
  
  ip addr add \$HOST_IF_IP/\$NETMASK dev \$VMHOST_IF
  ip link set \$VMHOST_IF up
  
  # 添加路由
  ip route add \$SUBNET dev \$VMHOST_IF 2>/dev/null
  
  echo "宿主机macvlan接口已配置: \$HOST_IF_IP"
  echo "macvlan网络配置完成！"
  echo ""
  echo "使用说明：运行容器时直接指定静态 IP（或 Compose 的 ipv4_address），可选 --mac-address 指定 MAC。"
  echo "示例: docker run --network=\$MACVLAN_NAME --ip 192.168.x.y --mac-address 02:42:ac:11:00:02 busybox sleep infinity"
else
  echo "警告：宿主机macvlan接口创建失败，可能在某些环境下不支持"
fi
EOF

  chmod +x $SERVICE_SCRIPT

  # 写入systemd服务单元
  cat > $SERVICE_UNIT << EOF
[Unit]
Description=Auto Configure Docker macvlan
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$SERVICE_SCRIPT
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable $SERVICE_NAME
  systemctl restart $SERVICE_NAME

  echo ""
  echo "========================================="
  echo "macvlan服务已安装并设置为开机自启！"
  echo "选择的网卡：$SELECTED_NIC"
  echo "========================================="
  echo ""
  echo "可以使用以下命令查看服务状态："
  echo "systemctl status $SERVICE_NAME"
  echo ""
  echo "测试macvlan网络："
  echo "docker network ls"
  echo "重要：运行容器时请配置唯一 MAC（路由器识别更稳定）"
  show_next_steps
}


function uninstall_macvlan_service() {
  echo "正在卸载macvlan服务..."
  
  systemctl stop $SERVICE_NAME 2>/dev/null
  systemctl disable $SERVICE_NAME 2>/dev/null
  
  # 清理网络配置
  docker network rm mymacvlan 2>/dev/null
  ip link delete macvlan-host 2>/dev/null
  
  # 删除文件
  rm -f $SERVICE_UNIT
  rm -f $SERVICE_SCRIPT
  
  systemctl daemon-reload
  
  echo "========================================="
  echo "macvlan服务及相关配置已完全卸载！"
  echo "========================================="
}

function show_status() {
  echo "========================================="
  echo "当前macvlan服务状态"
  echo "========================================="
  
  if [ -f $SERVICE_UNIT ]; then
    echo "服务状态："
    systemctl status $SERVICE_NAME --no-pager -l
    echo ""
    echo "Docker网络："
    docker network ls | grep -E "NAME|macvlan"
    echo ""
    echo "macvlan虚拟接口："
    ip addr show macvlan-host 2>/dev/null || echo "macvlan-host接口不存在"
  else
    echo "macvlan服务未安装"
  fi
  echo "========================================="
}

# 文字版使用说明
function show_usage() {
  echo ""
  echo "========================================="
  echo "            使用说明（文字版）"
  echo "========================================="
  echo "- 功能：创建并管理 Docker 的 macvlan 网络，使容器加入与宿主机相同网段。"
  echo "- 依赖与权限：需要 root；依赖 docker、ip、ipcalc、systemctl。"
  echo "- 安装：选择物理网卡后，自动创建网络 \"mymacvlan\" 与宿主机接口 \"macvlan-host\"，并注册为开机自启服务。"
  echo "- 卸载：移除服务、删除 \"mymacvlan\" 网络与 \"macvlan-host\" 接口。"
  echo "- 运行容器（示例）："
  echo "  docker run --network=mymacvlan --ip 192.168.x.y --mac-address 02:xx:xx:xx:xx:xx <image> sleep infinity"
  echo "- Compose（示意）："
  echo "  networks:"
  echo "    mymacvlan:"
  echo "      external: true"
  echo "  services:"
  echo "    app:"
  echo "      networks:"
  echo "        mymacvlan:"
  echo "          ipv4_address: 192.168.x.y"
  echo "      mac_address: 02:xx:xx:xx:xx:xx"
  echo "- 注意：使用静态 IP；为每个容器设置唯一 MAC；部分环境可能不支持宿主机 macvlan 接口；Windows 的 Docker Desktop 不适用。"
  echo "========================================="
}

function show_menu() {
  echo ""
  echo "========================================="
  echo "        Docker Macvlan 管理脚本"
  echo "========================================="
  echo "1) 安装 macvlan 自动服务"
  echo "2) 卸载 macvlan 自动服务"  
  echo "3) 查看服务状态"
  echo "4) 生成随机 MAC 地址"
  echo "5) 查看使用说明"
  echo "q) 退出"
  echo "========================================="
  read -p "请输入选择（1-5, q）：" choice
  
  case $choice in
    1) install_macvlan_service ;;
    2) uninstall_macvlan_service ;;
    3) show_status ;;
    4) print_random_mac ;;
    5) show_usage ;;
    q|Q) echo "退出脚本"; exit 0 ;;
    *) echo "无效选择，请重新输入"; show_menu ;;
  esac
  
  echo ""
  read -p "按回车键继续..." 
  show_menu
}

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要root权限运行"
  echo "请使用: sudo $0"
  exit 1
fi

# 检查必要命令
for cmd in docker ip ipcalc systemctl; do
  if ! command -v $cmd &> /dev/null; then
    echo "错误：未找到命令 $cmd，请先安装相关软件包"
    exit 1
  fi
done

show_menu
