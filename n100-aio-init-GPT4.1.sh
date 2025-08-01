#!/usr/bin/env bash
# N100 AIO 初始化脚本 v0.24 简化版 by OpenAI助手
# 仅保留 SSH管理、网络管理、磁盘管理、Docker管理、系统管理、脚本升级菜单
# 修复菜单格式、静态IP配置及磁盘挂载问题

set -euo pipefail
IFS=$'\n\t'

# ----------- 颜色和多语言提示 ------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
LANGUAGE="zh"

msg() {
  case "$1" in
    choose_option) [[ $LANGUAGE == "zh" ]] && echo -en "${YELLOW}>>> 请选择操作: ${NC}" || echo -en "${YELLOW}>>> Choose option: ${NC}" ;;
    invalid_option) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[错误] 输入无效，请重试！${NC}" || echo -e "${RED}[ERROR] Invalid input, please retry!${NC}" ;;
    back_main) [[ $LANGUAGE == "zh" ]] && echo -e "${YELLOW}返回主菜单...${NC}" || echo -e "${YELLOW}Returning to main menu...${NC}" ;;
    mount_fail) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[警告] 挂载失败，请确认设备和文件系统是否正确${NC}" || echo -e "${RED}[WARN] Mount failed. Check device and filesystem.${NC}" ;;
    network_restart_fail) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[警告] 网络服务重启失败，请手动检查配置${NC}"  || echo -e "${RED}[WARN] Network restart failed, check config manually.${NC}" ;;
  esac
}

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ----------- 权限检查 ------------
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 权限运行此脚本"
  exit 1
fi

# ----------- 依赖安装 ------------
ensure_cmd() {
  if ! command -v "$1" &>/dev/null; then
    log "安装依赖: $1"
    apt-get update -y && apt-get install -y "$1"
  fi
}

install_dependencies() {
  ensure_cmd ip
  ensure_cmd iptables
  ensure_cmd ufw
  ensure_cmd curl
  ensure_cmd systemctl
}

# ----------- 环境检测 ------------
env_auto_check() {
  echo -e "\n====== N100 AIO 初始化 v0.24 ======"
  local os kernel cpu mem ip gw dns ssh fw

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os="$NAME $VERSION"
  else
    os="未知系统"
  fi
  kernel=$(uname -r)
  cpu=$(awk -F ': ' '/model name/{print $2; exit}' /proc/cpuinfo)
  mem=$(free -h | awk '/^Mem:/ {print $2 "总，" $7 "可用"}')
  ip=$(ip -o -4 addr show scope global | awk '{print $4}' | head -1)
  gw=$(ip route show default | awk '{print $3}')
  dns=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd ',')
  ssh=$(systemctl is-active ssh 2>/dev/null && echo "开启" || echo "关闭")
  fw_status="未知"
  if command -v ufw &>/dev/null; then
    fw_status=$(ufw status | head -1)
    # 修正ufw状态为中文
    [[ $LANGUAGE == "zh" && $fw_status == "Status: inactive" ]] && fw_status="状态: 未激活"
    [[ $LANGUAGE == "zh" && $fw_status == "Status: active" ]] && fw_status="状态: 活跃"
  elif command -v firewall-cmd &>/dev/null; then
    if firewall-cmd --state &>/dev/null; then
      fw_status="firewalld 活跃"
    else
      fw_status="firewalld 未运行"
    fi
  elif command -v iptables &>/dev/null; then
    fw_status="iptables 状态未知，规则数量: $(iptables -L | grep -c ACCEPT)"
  fi

  echo "操作系统: $os"
  echo "内核版本: $kernel"
  echo "CPU: $cpu"
  echo "内存: $mem"
  echo -e "网络:\n  IP: ${ip:-无}\n  网关: ${gw:-无}\n  DNS: ${dns:-无}"
  echo "SSH状态: $ssh"
  echo "防火墙状态: $fw_status"
  echo "============================="
}

# ----------- 防火墙管理 ------------
firewall_show_ports() {
  if command -v ufw &>/dev/null; then
    ufw status numbered || warn "ufw 状态获取失败"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --list-ports || warn "firewalld 端口列表获取失败"
  else
    local out
    out=$(iptables -L INPUT -n --line-numbers 2>/dev/null | grep 'dpt:' || true)
    if [[ -z "$out" ]]; then
      echo "无开放端口规则"
    else
      echo "$out"
    fi
  fi
}

firewall_set_ports() {
  echo -en "请输入要开放的端口号（用空格分隔）: "
  read -r ports
  if [[ -z "$ports" ]]; then
    echo "[错误] 未输入端口号，取消操作"
    return
  fi

  if command -v ufw &>/dev/null; then
    for p in $ports; do ufw allow "$p"; done
    ufw reload
    log "端口已通过 ufw 开放：$ports"
  elif command -v firewall-cmd &>/dev/null; then
    for p in $ports; do firewall-cmd --permanent --add-port="${p}/tcp"; done
    firewall-cmd --reload
    log "端口已通过 firewalld 开放：$ports"
  else
    for p in $ports; do
      if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        echo "[INFO] 端口 $p 已添加 iptables 规则"
      else
        echo "[WARN] 端口 $p 规则已存在，跳过"
      fi
    done
  fi
}

firewall_menu() {
  while true; do
    echo -e "\n=== 防火墙管理 ==="
    echo "1) 查看防火墙状态"
    echo "2) 查看防火墙开放端口"
    echo "3) 设定开放端口"
    echo "b) 返回主菜单"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        if command -v ufw &>/dev/null; then ufw status verbose
        elif command -v firewall-cmd &>/dev/null; then firewall-cmd --state || echo "防火墙未启动"
        else iptables -L -n -v
        fi
        ;;
      2) firewall_show_ports ;;
      3) firewall_set_ports ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------- 网络管理 ------------
list_interfaces() {
  echo "当前接口及IP列表："
  ip -o -4 addr show | awk '{print NR": "$2, "IP: "$4}'
}

configure_static_ip() {
  list_interfaces
  echo "请输入接口名（如 eth0）："
  read -r iface
  if ! ip link show "$iface" &>/dev/null; then
    echo "[错误] 接口 $iface 不存在"
    return
  fi
  echo "请输入静态IP（带掩码，如 192.168.1.100/24）："
  read -r ipaddr
  echo "请输入网关："
  read -r gw
  echo "请输入DNS服务器地址（空格分隔）："
  read -r dnses

  # 生成interfaces备份和配置
  cp /etc/network/interfaces /etc/network/interfaces.bak."$(date +%F_%T)"
  {
    echo "auto $iface"
    echo "iface $iface inet static"
    echo "  address $ipaddr"
    echo "  gateway $gw"
    echo "  dns-nameservers $dnses"
  } > /etc/network/interfaces

  if systemctl restart networking; then
    log "静态IP配置完成，网络服务重启成功"
  else
    warn "网络服务重启失败，请检查配置"
    msg network_restart_fail
  fi
}

configure_dhcp() {
  list_interfaces
  echo "请输入接口名（如 eth0）："
  read -r iface
  if ! ip link show "$iface" &>/dev/null; then
    echo "[错误] 接口 $iface 不存在"
    return
  fi

  cp /etc/network/interfaces /etc/network/interfaces.bak."$(date +%F_%T)"
  {
    echo "auto $iface"
    echo "iface $iface inet dhcp"
  } > /etc/network/interfaces

  if systemctl restart networking; then
    log "DHCP配置完成，网络服务重启成功"
  else
    warn "网络服务重启失败，请检查配置"
    msg network_restart_fail
  fi
}

network_menu() {
  while true; do
    echo -e "\n=== 网络管理 ==="
    echo "1) 查看网络状态"
    echo "2) 配置网络 (静态IP/DHCP)"
    echo "b) 返回主菜单"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        ip addr show
        ip route show
        echo "DNS 服务器："
        grep 'nameserver' /etc/resolv.conf || echo "未配置DNS"
        ;;
      2)
        echo "1) 静态IP配置"
        echo "2) DHCP动态获取"
        msg choose_option
        read -r c
        case "$c" in
          1) configure_static_ip ;;
          2) configure_dhcp ;;
          *) msg invalid_option ;;
        esac
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------- 磁盘管理 ------------
disk_menu() {
  while true; do
    echo -e "\n=== 磁盘管理 ==="
    echo "1) 查看磁盘状态"
    echo "2) 磁盘分区"
    echo "3) 磁盘挂载"
    echo "b) 返回主菜单"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL | column -t
        echo "提示：FSTYPE为空的磁盘一般为未分区"
        ;;
      2)
        echo "磁盘分区有风险，输入 'yes' 继续，否则输入其他取消："
        read -r conf
        if [[ "$conf" != "yes" ]]; then
          echo "操作取消"
          continue
        fi
        echo "请输入磁盘设备(如 /dev/sdb)："
        read -r dev
        if [[ ! -b "$dev" ]]; then
          echo "[错误] 设备不存在"
          continue
        fi
        echo -e "${YELLOW}fdisk 中文辅助指令：n-新建, d-删除, p-打印分区, w-保存并退出${NC}"
        fdisk "$dev"
        ;;
      3)
        echo "请输入设备名(如 /dev/sdb1)："
        read -r dev
        if [[ -z "$dev" || ! -b "$dev" ]]; then
          echo "[错误] 设备无效"
          continue
        fi
        echo "请输入挂载目录(如 /mnt/data1)："
        read -r mountp
        if [[ -z "$mountp" ]]; then
          echo "[错误] 挂载目录不能为空"
          continue
        fi
        mkdir -p "$mountp"
        if mount "$dev" "$mountp"; then
          log "挂载成功 $dev -> $mountp"
        else
          msg mount_fail
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------- Docker管理 ------------
install_docker() {
  if command -v docker &>/dev/null && command -v docker-compose &>/dev/null; then
    log "Docker及docker-compose已安装"
    return
  fi
  log "安装Docker..."
  curl -fsSL https://get.docker.com | sh
  apt-get install -y docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  log "Docker安装完成"
}

docker_menu() {
  while true; do
    echo -e "\n=== Docker管理 ==="
    echo "1) 安装Docker & docker-compose"
    echo "b) 返回主菜单"
    msg choose_option
    read -r opt
    case "$opt" in
      1) install_docker ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------- 系统管理 ------------
system_menu() {
  while true; do
    echo -e "\n=== 系统管理 ==="
    echo "1) 系统更新与升级"
    echo "b) 返回主菜单"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        apt-get update && apt-get upgrade -y && log "系统升级完成" || warn "更新升级失败"
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------- 脚本升级 ------------
script_upgrade() {
  echo "自动升级脚本中..."
  local url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/n100-aio-init-GPT4.1.sh"
  local tmpfile="/tmp/n100-aio-init-upgrade.sh"
  if curl -fsSL "$url" -o "$tmpfile"; then
    chmod +x "$tmpfile"
    mv "$tmpfile" "$(realpath "$0")"
    log "脚本升级完成，请重新运行脚本。"
    exit 0
  else
    echo "[错误] 脚本下载失败"
  fi
}

# ----------- 主菜单 ------------
main_menu() {
  install_dependencies
  while true; do
    env_auto_check
    echo -e "\n====== N100 AIO 初始化 v0.24 ======"
    echo "1) SSH管理"
    echo "2) 网络管理"
    echo "3) 磁盘管理"
    echo "4) Docker管理"
    echo "5) 系统管理"
    echo "6) 脚本升级"
    echo "q) 退出脚本"
    msg choose_option
    read -r ch
    case "$ch" in
      1) ssh_menu ;;
      2) network_menu ;;
      3) disk_menu ;;
      4) docker_menu ;;
      5) system_menu ;;
      6) script_upgrade ;;
      q|Q)
        log "退出脚本，再见！"
        exit 0
        ;;
      *) msg invalid_option ;;
    esac
  done
}

# 仅保留 SSH菜单（简化）
ssh_menu() {
  while true; do
    echo -e "\n=== SSH管理 ==="
    echo "1) 查看SSH状态"
    echo "2) 安装并启用SSH服务"
    echo "3) 允许root登录"
    echo "b) 返回主菜单"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        systemctl is-active ssh &>/dev/null && log "SSH服务运行中" || warn "SSH服务未运行"
        ;;
      2)
        if command -v sshd &>/dev/null; then
          log "SSH已安装"
        else
          apt-get update
          apt-get install -y openssh-server
        fi
        systemctl enable ssh
        systemctl start ssh
        log "SSH服务已启用"
        ;;
      3)
        local conf_file="/etc/ssh/sshd_config"
        if grep -q "^PermitRootLogin yes" "$conf_file"; then
          log "已允许root登录"
        else
          sed -i.bak s/^PermitRootLogin.*/PermitRootLogin yes/ "$conf_file" || echo "PermitRootLogin yes" >>"$conf_file"
          systemctl reload ssh
          log "已配置允许root登录并重载SSH"
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

main_menu
