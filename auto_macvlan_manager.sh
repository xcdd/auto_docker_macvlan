#!/bin/bash

# 说明：
# 该脚本在宿主机上创建并管理 Docker 的 macvlan 网络，
# 让容器以“局域网独立主机”的方式加入与宿主机相同网段。
#
# 简化原则：使用 Docker IPAM 的静态/固定 IP 分配，不依赖容器内 DHCP 客户端。
# - 创建 macvlan 网络时指定子网和网关；
# - 运行容器时直接指定 IP（docker run --ip 或 Compose 的 ipv4_address）；
# - 如需路由器识别或固定地址，可指定 MAC（--mac-address / mac_address）。
#
# 运行完成后，你要为容器规划指定 IP，并配置唯一的 MAC，
# 然后在路由器上设置后续DHCP的范围不要与容器IP冲突。
# 运行容器时务必在命令或 Compose 中设置 --ip 与 --mac-address。

SERVICE_SCRIPT="/usr/local/bin/auto_macvlan.sh"
SERVICE_UNIT="/etc/systemd/system/auto_macvlan.service"
SERVICE_NAME="auto_macvlan"

# 持久化路由：清单文件与应用脚本/服务定义
ROUTES_DIR="/etc/auto_macvlan"
ROUTES_FILE="$ROUTES_DIR/routes.txt"
ROUTES_SCRIPT="/usr/local/bin/auto_macvlan_routes.sh"
ROUTES_UNIT="/etc/systemd/system/auto_macvlan-routes.service"
ROUTES_SERVICE_NAME="auto_macvlan-routes"

# 自动安装依赖：根据系统包管理器安装缺失的命令
function detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then PKG_MGR="yum"; return; fi
  if command -v zypper >/dev/null 2>&1; then PKG_MGR="zypper"; return; fi
  if command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman"; return; fi
  if command -v apk >/dev/null 2>&1; then PKG_MGR="apk"; return; fi
  PKG_MGR=""
}

function pkg_install() {
  local packages=("$@")
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y && apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${packages[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    *)
      echo "错误：无法识别包管理器，无法自动安装：${packages[*]}"
      return 1
      ;;
  esac
}

function ensure_downloader() {
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then return; fi
  detect_pkg_manager
  echo "未检测到 curl/wget，尝试自动安装..."
  pkg_install curl || pkg_install wget || echo "警告：无法安装 curl/wget，这是一个符合使用要求的Linux系统吗"
}

function ensure_ip() {
  if command -v ip >/dev/null 2>&1; then return; fi
  detect_pkg_manager
  echo "未检测到 ip 命令，尝试自动安装..."
  case "$PKG_MGR" in
    apt|zypper|pacman|apk) pkg_install iproute2 ;;
    dnf|yum) pkg_install iproute ;;
    *) echo "错误：无法为当前系统安装 ip 命令"; exit 1 ;;
  esac
}

function ensure_ipcalc() {
  if command -v ipcalc >/dev/null 2>&1; then return; fi
  detect_pkg_manager
  echo "未检测到 ipcalc，尝试自动安装..."
  case "$PKG_MGR" in
    apt|zypper|pacman|apk) pkg_install ipcalc ;;
    dnf) pkg_install ipcalc || pkg_install ipcalc-ng ;;
    yum) pkg_install ipcalc ;;
    *) echo "警告：无法安装 ipcalc，脚本将使用备用计算方法"; return ;;
  esac
}

function ensure_systemctl() {
  if command -v systemctl >/dev/null 2>&1; then return; fi
  detect_pkg_manager
  echo "未检测到 systemctl，尝试自动安装 systemd..."
  case "$PKG_MGR" in
    apt|dnf|yum|zypper|pacman) pkg_install systemd ;;
    apk) echo "错误：检测到 Alpine/非 systemd 环境，无法安装 systemd；此脚本需要使用 systemd管理的linux系统"; exit 1 ;;
    *) echo "错误：无法识别包管理器，无法安装 systemd"; exit 1 ;;
  esac
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "错误：检测到疑似非 systemd 环境，无法安装 systemd；此脚本需要 systemd；此脚本需要使用 systemd管理的linux系统"
    exit 1
  fi
}

function ensure_docker() {
  if command -v docker >/dev/null 2>&1; then return; fi
  echo "错误：未检测到 docker"
  echo "Docker 软件包较大，且安装过程涉及服务配置。请先确认本机已正确安装 Docker 并已启动服务。"
  echo "参考官方安装指南：https://docs.docker.com/ "
  echo "安装完成后请重新运行本脚本。"
  exit 1
}

function ensure_requirements() {
  detect_pkg_manager
  ensure_ip
  ensure_ipcalc
  ensure_systemctl
  ensure_docker
}

# 交互式依赖检查：仅在用户确认后才安装缺失依赖，除了docker
function ensure_requirements_interactive() {
  detect_pkg_manager
  local proceed=1

  if ! command -v docker >/dev/null 2>&1; then
    echo "错误：未检测到 docker。请先安装并启动 Docker 后再继续。"
    echo "参考：https://docs.docker.com/ 或便利脚本 https://get.docker.com"
    proceed=0
  fi

  if ! command -v ip >/dev/null 2>&1; then
    read -p "未检测到 ip (iproute2/iproute)，是否自动安装？[Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      ensure_ip
    else
      proceed=0
    fi
  fi

  if ! command -v ipcalc >/dev/null 2>&1; then
    read -p "未检测到 ipcalc，是否自动安装？[Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      ensure_ipcalc
    else
      echo "你拒绝安装ipcalc，导致将使用备用方法计算网段"
    fi
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    read -p "未检测到 systemctl (systemd)，是否自动安装？[Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      ensure_systemctl
    else
      proceed=0
    fi
  fi

  if [ "$proceed" -eq 0 ]; then
    echo "依赖未满足或用户取消安装，操作中止。"
    return 1
  fi
  return 0
}

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
  # 安装前进行交互式依赖检查，仅在用户确认后安装缺失依赖
  if ! ensure_requirements_interactive; then
    return 1
  fi
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

  # 关闭该虚拟接口上的 IPv6 自动配置，避免通过 RA/SLAAC 获得 IPv6
  sysctl -w net.ipv6.conf.\$VMHOST_IF.disable_ipv6=1 2>/dev/null || true
  sysctl -w net.ipv6.conf.\$VMHOST_IF.autoconf=0 2>/dev/null || true
  sysctl -w net.ipv6.conf.\$VMHOST_IF.accept_ra=0 2>/dev/null || true
  
  # 安全提示：不默认向整段网段添加路由，避免影响同网段其它服务
  # 如需从宿主机访问某一容器，请为该容器 IP 添加主机路由：
  #   ip route add <容器IP>/32 dev \$VMHOST_IF
  # 也可通过管理脚本菜单中的“添加容器IP路由”进行交互式管理。

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
  systemctl stop $ROUTES_SERVICE_NAME 2>/dev/null
  systemctl disable $ROUTES_SERVICE_NAME 2>/dev/null
  
  # 清理网络配置
  docker network rm mymacvlan 2>/dev/null
  ip link delete macvlan-host 2>/dev/null
  
  # 删除文件
  rm -f $SERVICE_UNIT
  rm -f $SERVICE_SCRIPT
  rm -f $ROUTES_UNIT
  rm -f $ROUTES_SCRIPT
  rm -f $ROUTES_FILE
  
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
    echo "路由服务状态："
    if [ -f "$ROUTES_UNIT" ]; then
      systemctl status $ROUTES_SERVICE_NAME --no-pager -l
    else
      echo "未安装 $ROUTES_SERVICE_NAME"
    fi
    echo ""
    echo "Docker网络："
    docker network ls | grep -E "NAME|macvlan"
    echo ""
    echo "macvlan虚拟接口："
    ip addr show macvlan-host 2>/dev/null || echo "macvlan-host接口不存在"
    echo ""
    echo "持久化路由清单 ($ROUTES_FILE)："
    if [ -f "$ROUTES_FILE" ]; then
      nl -ba "$ROUTES_FILE" | sed -n '1,100p'
    else
      echo "未找到路由清单文件"
    fi
  else
    echo "macvlan服务未安装"
  fi
  echo "========================================="
}

# 为容器 IP 添加/删除主机路由，避免对整个网段的影响
function add_container_route() {
  if ! ip link show macvlan-host &>/dev/null; then
    echo "错误：macvlan-host 接口不存在，请先安装并启动服务。"
    return 1
  fi
  read -p "请输入容器 IPv4 地址（例如 192.168.2.100）：" target_ip
  if [[ ! "$target_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "无效的 IPv4 地址格式"
    return 1
  fi
  if ip route add "$target_ip/32" dev macvlan-host 2>/dev/null; then
    echo "已为 $target_ip 添加主机路由到 macvlan-host"
    # 写入持久化清单（去重）
    mkdir -p "$ROUTES_DIR"
    if ! grep -qx "$target_ip" "$ROUTES_FILE" 2>/dev/null; then
      echo "$target_ip" >> "$ROUTES_FILE"
      echo "已记录到持久化清单：$ROUTES_FILE"
    else
      echo "持久化清单中已存在该 IP：$target_ip"
    fi
    # 确保已生成路由脚本与服务，并立即应用清单
    apply_routes_now
  else
    echo "可能该主机路由已存在或添加失败，当前路由："
    ip route show | grep -E "(^| )$target_ip/32( |$)" || true
  fi
}

function del_container_route() {
  # 显示已存在的 /32 主机路由，并允许用户按序号选择删除
  local entries
  mapfile -t entries < <(ip route show | awk '$0 ~ /dev macvlan-host/ { addr=$1; sub(/\\/32$/, "", addr); if (addr ~ /^([0-9]{1,3}\\.){3}[0-9]{1,3}$/) print addr }')
  if ((${#entries[@]} > 0)); then
    echo "已发现以下指向 macvlan-host 的主机路由："
    for i in "${!entries[@]}"; do echo "$((i+1)). ${entries[$i]}"; done
    echo "可直接输入 IP 或输入序号选择要删除的目标。"
  else
    echo "未扫描到指向 macvlan-host 的 /32 主机路由。"
  fi
  read -p "请输入容器 IPv4 或序号（例如 192.168.2.100 或 1）：" sel
  local target_ip=""
  if [[ "$sel" =~ ^[0-9]+$ ]] && ((${#entries[@]} >= sel)) && ((sel >= 1)); then
    target_ip="${entries[$((sel-1))]}"
  else
    target_ip="$sel"
  fi
  if [[ ! "$target_ip" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ ]]; then
    echo "无效的 IPv4 地址格式"
    return 1
  fi
  if ip route delete "$target_ip/32" dev macvlan-host 2>/dev/null; then
    echo "已删除 $target_ip 的主机路由"
    # 从持久化清单移除该 IP
    if [ -f "$ROUTES_FILE" ]; then
      grep -vx "$target_ip" "$ROUTES_FILE" > "$ROUTES_FILE.tmp" && mv "$ROUTES_FILE.tmp" "$ROUTES_FILE"
      echo "已从持久化清单移除：$target_ip"
    fi
    # 变更后应用或自动清理（当清单为空时）
    apply_routes_now
  else
    echo "未找到 $target_ip 的主机路由或删除失败"
  fi
}

# 选择可用编辑器并打开文件，编辑完成后返回
function open_in_editor() {
  local file="$1"
  local editor="${EDITOR:-}"
  if [ -n "$editor" ] && command -v "$editor" >/dev/null 2>&1; then
    "$editor" "$file"
    return $?
  fi
  for e in nano vim vi; do
    if command -v "$e" >/dev/null 2>&1; then
      "$e" "$file"
      return $?
    fi
  done
  echo "未找到可用编辑器。请手动编辑：$file"
  echo "你可以使用：echo '192.168.x.y' >> $file"
  read -p "按回车继续..." _
}

# 检查路由清单是否包含至少一条有效 IPv4
function has_valid_routes() {
  shopt -s extglob
  local file="$ROUTES_FILE"
  [ -f "$file" ] || return 1
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line##*( )}"
    line="${line%%*( )}"
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      return 0
    fi
  done < "$file"
  return 1
}

# 统计清单中的有效 IPv4 条数
function count_valid_routes() {
  shopt -s extglob
  local file="$ROUTES_FILE"
  local count=0
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line##*( )}"
      line="${line%%*( )}"
      [ -z "$line" ] && continue
      if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        count=$((count+1))
      fi
    done < "$file"
  fi
  echo "$count"
}

# 根据清单生成路由脚本与服务（仅在存在有效路由时）
function ensure_routes_artifacts() {
  mkdir -p "$ROUTES_DIR"
  if ! has_valid_routes; then
    return 0
  fi
  # 写路由脚本
  if [ ! -f "$ROUTES_SCRIPT" ]; then
    cat > "$ROUTES_SCRIPT" << 'EOF'
#!/bin/bash
set -euo pipefail
shopt -s extglob

ROUTES_FILE="/etc/auto_macvlan/routes.txt"
VMHOST_IF="macvlan-host"

# 等待接口可用（最多 5 秒）
for i in $(seq 1 5); do
  if ip link show "$VMHOST_IF" >/dev/null 2>&1; then break; fi
  sleep 1
done

if ! ip link show "$VMHOST_IF" >/dev/null 2>&1; then
  echo "错误：接口 $VMHOST_IF 不存在，无法应用持久化路由" >&2
  exit 1
fi

apply_route() {
  local ip="$1"
  ip route replace "$ip/32" dev "$VMHOST_IF" 2>/dev/null && echo "已应用持久化路由：$ip -> $VMHOST_IF" || echo "应用持久化路由失败：$ip"
}

# 读取路由清单并应用
if [ -f "$ROUTES_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line##*( )}"
    line="${line%%*( )}"
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      apply_route "$line"
    else
      echo "跳过无效项：$line" >&2
    fi
  done < "$ROUTES_FILE"
else
  echo "未找到路由清单：$ROUTES_FILE"
fi
EOF
    chmod +x "$ROUTES_SCRIPT"
  fi

  # 写路由服务单元
  if [ ! -f "$ROUTES_UNIT" ]; then
    cat > "$ROUTES_UNIT" << EOF
[Unit]
Description=Apply persisted /32 routes for macvlan-host
After=$SERVICE_NAME.service
Wants=$SERVICE_NAME.service

[Service]
Type=oneshot
ExecStart=$ROUTES_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || true
    systemctl enable "$ROUTES_SERVICE_NAME" || true
  fi
}

# 当清单为空时，停用并删除路由服务与脚本（外部实现，避免生成脚本中的未定义变量）
function cleanup_routes_artifacts() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop $ROUTES_SERVICE_NAME 2>/dev/null || true
    systemctl disable $ROUTES_SERVICE_NAME 2>/dev/null || true
  fi
  rm -f "$ROUTES_UNIT"
  rm -f "$ROUTES_SCRIPT"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi
  echo "路由清单为空，已停用并删除路由服务与脚本。"
}

# 立即应用路由清单：如果 systemd 可用则重启服务，否则直接执行脚本
function apply_routes_now() {
  if ! has_valid_routes; then
    cleanup_routes_artifacts
    return 0
  fi
  ensure_routes_artifacts
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart $ROUTES_SERVICE_NAME || true
  fi
  if [ -x "$ROUTES_SCRIPT" ]; then
    "$ROUTES_SCRIPT" || true
  else
    echo "未找到路由脚本：$ROUTES_SCRIPT"
  fi
}

# 编辑前预览当前清单与将执行的动作摘要
function preview_routes_actions_before_edit() {
  local count
  count=$(count_valid_routes)
  if [ -f "$ROUTES_FILE" ]; then
    echo "当前路由清单：$ROUTES_FILE"
    echo "有效 IPv4 条数：$count"
  else
    echo "当前路由清单：尚未创建 ($ROUTES_FILE)"
    echo "有效 IPv4 条数：0"
  fi
  echo "动作摘要："
  if (( count > 0 )); then
    if [ -f "$ROUTES_UNIT" ] && [ -x "$ROUTES_SCRIPT" ]; then
      echo "- 将重启 $ROUTES_SERVICE_NAME 并应用 $count 条路由"
    else
      echo "- 将创建路由脚本与服务，并应用 $count 条路由"
    fi
  else
    if [ -f "$ROUTES_UNIT" ] || [ -f "$ROUTES_SCRIPT" ]; then
      echo "- 清单为空，将停用并删除路由服务与脚本"
    else
      echo "- 清单为空，当前无需额外操作"
    fi
  fi
}

# 编辑并应用持久化路由清单
function edit_routes_and_apply() {
  mkdir -p "$ROUTES_DIR"
  preview_routes_actions_before_edit
  echo "正在打开路由清单：$ROUTES_FILE"
  open_in_editor "$ROUTES_FILE"
  echo "已返回，正在应用路由清单..."
  apply_routes_now
  echo "已应用路由清单。可再次查看状态以确认。"
}

# 仅应用当前路由清单（不编辑）
function apply_routes_file_now() {
  if [ ! -f "$ROUTES_FILE" ]; then
    echo "路由清单不存在：$ROUTES_FILE"
    return 1
  fi
  echo "正在应用路由清单：$ROUTES_FILE"
  apply_routes_now
  echo "已应用路由清单。"
}

# 一次性创建宿主 macvlan 接口（不安装服务，不创建整网路由）
function create_macvlan_host_once() {
  # 仅确保必要命令：ip；ipcalc可选
  if ! command -v ip >/dev/null 2>&1; then
    read -p "未检测到 ip 命令，是否自动安装？[Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      ensure_ip
    else
      echo "取消：缺少 ip 命令"
      return 1
    fi
  fi

  select_nic
  local NETCARD="$SELECTED_NIC"
  local VMHOST_IF="macvlan-host"

  if ip link show "$VMHOST_IF" >/dev/null 2>&1; then
    echo "错误：接口 $VMHOST_IF 已存在。如需重新创建，请先删除。"
    return 1
  fi

  # 获取 IPv4 信息
  IP_INFO=$(ip -4 addr show "$NETCARD" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
  if [ -z "$IP_INFO" ]; then
    echo "错误：网卡 $NETCARD 未分配 IPv4 地址"
    return 1
  fi
  IP_ADDR=$(echo "$IP_INFO" | cut -d'/' -f1)
  NETMASK=$(echo "$IP_INFO" | cut -d'/' -f2)

  # 分配宿主侧接口的 IPv4（主机最后一段 +50，越界则 -50）
  LAST_OCTET=$(echo "$IP_ADDR" | awk -F. '{print $4}')
  NEW_OCTET=$((LAST_OCTET + 50))
  if [ "$NEW_OCTET" -gt 254 ]; then
    NEW_OCTET=$((LAST_OCTET - 50))
    if [ "$NEW_OCTET" -lt 1 ]; then NEW_OCTET=1; fi
  fi
  HOST_IF_IP=$(echo "$IP_ADDR" | awk -F. '{print $1"."$2"."$3"."}')"$NEW_OCTET"

  echo "正在创建宿主机 macvlan 接口 $VMHOST_IF 于 $NETCARD..."
  if ! ip link add "$VMHOST_IF" link "$NETCARD" type macvlan mode bridge; then
    echo "错误：创建接口失败"
    return 1
  fi
  ip addr add "$HOST_IF_IP/$NETMASK" dev "$VMHOST_IF"
  ip link set "$VMHOST_IF" up
  sysctl -w net.ipv6.conf.$VMHOST_IF.disable_ipv6=1 2>/dev/null || true
  sysctl -w net.ipv6.conf.$VMHOST_IF.autoconf=0 2>/dev/null || true
  sysctl -w net.ipv6.conf.$VMHOST_IF.accept_ra=0 2>/dev/null || true

  echo "已创建：$VMHOST_IF -> $HOST_IF_IP/$NETMASK"
  echo "注意：未创建 Docker 网络，也未添加整网段路由。"
  echo "如需从宿主访问某容器，请添加主机路由：ip route add <容器IP>/32 dev $VMHOST_IF"
}

# 删除一次性创建的宿主 macvlan 接口（不影响服务文件与 Docker 网络）
function delete_macvlan_host_only() {
  local VMHOST_IF="macvlan-host"
  if ip link show "$VMHOST_IF" >/dev/null 2>&1; then
    if ip link delete "$VMHOST_IF" 2>/dev/null; then
      echo "已删除宿主接口 $VMHOST_IF"
    else
      echo "删除 $VMHOST_IF 失败"
    fi
  else
    echo "$VMHOST_IF 接口不存在"
  fi
}

# 卸载除宿主 macvlan 接口外的其它配置（保留 macvlan-host）
function uninstall_keep_macvlan_host() {
  echo "正在移除除宿主 macvlan 接口外的配置..."
  # 停止并禁用服务
  systemctl stop $SERVICE_NAME 2>/dev/null
  systemctl disable $SERVICE_NAME 2>/dev/null
  systemctl stop $ROUTES_SERVICE_NAME 2>/dev/null
  systemctl disable $ROUTES_SERVICE_NAME 2>/dev/null
  # 删除 Docker 网络（不影响宿主 macvlan 接口）
  docker network rm mymacvlan 2>/dev/null
  # 删除服务文件
  rm -f $SERVICE_UNIT
  rm -f $SERVICE_SCRIPT
  rm -f $ROUTES_UNIT
  rm -f $ROUTES_SCRIPT
  rm -f $ROUTES_FILE
  systemctl daemon-reload
  echo "已移除：服务与 Docker 网络；保留：macvlan-host 接口"
  echo "如需彻底删除宿主接口，可使用菜单中的删除接口功能。"
  echo "提示：已删除持久化路由服务。如需恢复，请重新安装服务并重新记录路由。"
  echo "已删除持久化路由清单：$ROUTES_FILE"
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
  echo "      Linux Docker Macvlan 管理脚本"
  echo "========================================="
  echo "1) 安装 macvlan 网卡且自动跟随外网更新配置"
  echo "2) 卸载 macvlan 网卡与自动跟随外网更新配置"
  echo "3) 只安装 macvlan 网卡（不安装自动跟随外网更新配置）"
  echo "4) 删除除了新建 macvlan 网卡以外本脚本的改动"
  echo "5) 查看服务状态"
  echo "6) 生成随机 MAC 地址的工具"
  echo "7) 编辑并应用路由清单 (当你需要从宿主访问某个容器)"
  echo "8) 立刻应用路由清单 (如果你从其他地方修改过路由，需要刷新服务)"
  echo "9) 查看使用说明"
  echo "q) 退出"
  echo "========================================="
  read -p "请输入选择（1-9, q）：" choice
  
  case $choice in
    1) install_macvlan_service ;;
    2) uninstall_macvlan_service ;;
    3) create_macvlan_host_once ;;
    4) uninstall_keep_macvlan_host ;;
    5) show_status ;;
    6) print_random_mac ;;
    7) edit_routes_and_apply ;;
    8) apply_routes_file_now ;;
    9) show_usage ;;
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

# 启动脚本不进行写入或安装操作，所有改动依据菜单选择执行

show_menu
