#!/usr/bin/env bash
# N100 All-in-One 初始化脚本 (优化版)
set -euo pipefail
IFS=$'\n\t'

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# 通用输出函数
log() { echo -e "${GREEN}[√]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[×]${NC} $*" >&2; }
prompt() { echo -en "${YELLOW}[输入]${NC} $*"; read -e "$@"; }

# 全局变量
BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)

# ---------------------- 通用函数 ----------------------
menu_prompt() {
  local options=("$@")
  for i in "${!options[@]}"; do
    echo "$((i + 1))) ${options[i]}"
  done
  echo "q) 返回上一级"
  prompt "请选择: " choice
  echo "$choice"
}

validate_ip() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$ ]]; then
    return 0
  else
    warn "无效的 IP 地址: $ip"
    return 1
  fi
}

# ---------------------- 环境检测 ----------------------
env_check() {
  . /etc/os-release
  VERSION_ID=${VERSION_ID%%.*}
  case "$VERSION_ID" in
    9) CODENAME="stretch";; 10) CODENAME="buster";; 11) CODENAME="bullseye";; 12) CODENAME="bookworm";; *) CODENAME="bookworm";;
  esac
  log "系统: Debian $VERSION_ID ($CODENAME)"
  avail_kb=$(df --output=avail "$BASE_DIR" 2>/dev/null | tail -1 || df --output=avail / | tail -1)
  (( avail_kb < 5*1024*1024 )) && error "磁盘可用 <5GB" && exit 1
  mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
  (( mem_mb < 1024 )) && error "内存 <1GB" && exit 1
  log "环境检测通过: 磁盘 $(awk "BEGIN{printf '%.1fGB', $avail_kb/1024/1024}")，内存 ${mem_mb}MB"
}
env_check

# ---------------------- 网络设置 ----------------------
network_detect() {
  log "网络接口与IP："
  ip -brief addr show
  log "路由表："
  ip route show
}

network_config() {
  while true; do
    choice=$(menu_prompt "DHCP（动态IP）" "静态IP")
    iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
    [[ -z "$iface" ]] && { warn "无可用接口"; continue; }
    case "$choice" in
      1)
        cat >/etc/network/interfaces.d/$iface.cfg <<EOF
auto $iface
iface $iface inet dhcp
EOF
        systemctl restart networking && log "DHCP 配置应用完成"
        ;;
      2)
        prompt "静态IP (如 192.168.1.100/24): " sip
        validate_ip "$sip" || continue
        prompt "网关 (如 192.168.1.1): " gtw
        [[ -z "$gtw" ]] && { warn "网关不能为空"; continue; }
        cat >/etc/network/interfaces.d/$iface.cfg <<EOF
auto $iface
iface $iface inet static
  address $sip
  gateway $gtw
EOF
        systemctl restart networking && log "静态IP 配置应用完成"
        ;;
      q) break ;;
      *) warn "无效选项";;
    esac
  done
}

# ---------------------- SSH 设置 ----------------------
check_ssh_status() {
  systemctl is-active --quiet ssh && log "SSH 服务已启动" || warn "SSH 未运行"
  cfg=/etc/ssh/sshd_config
  if [[ -f $cfg ]]; then
    port=$(grep -E '^Port ' $cfg | awk '{print $2}'); port=${port:-22}
    pr=$(grep -E '^PermitRootLogin ' $cfg | awk '{print $2}'); pr=${pr:-no}
    pa=$(grep -E '^PasswordAuthentication ' $cfg | awk '{print $2}'); pa=${pa:-yes}
    echo -e "端口: $port\nPermitRootLogin: $pr\nPasswordAuthentication: $pa"
  fi
}

enable_ssh() {
  apt-get update && apt-get install -y openssh-server
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl enable ssh && systemctl restart ssh
  log "SSH 已启用 (root登录+密码登录)"
}

ssh_config_edit() {
  cfg=/etc/ssh/sshd_config
  while true; do
    choice=$(menu_prompt "修改SSH端口" "开启/关闭 root 登录" "开启/关闭 密码登录")
    case "$choice" in
      1)
        prompt "输入新端口 (默认22): " sshport
        [[ -z "$sshport" ]] && { warn "未输入端口，已取消"; continue; }
        sed -i "s/^#\?Port .*/Port $sshport/" $cfg
        systemctl restart ssh
        log "SSH 端口已修改为 $sshport"
        ;;
      2)
        prompt "允许root登录？(yes/no): " rlogin
        [[ "$rlogin" != "yes" && "$rlogin" != "no" ]] && { warn "无效输入"; continue; }
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin $rlogin/" $cfg
        systemctl restart ssh
        log "PermitRootLogin 已设为 $rlogin"
        ;;
      3)
        prompt "允许密码登录？(yes/no): " pauth
        [[ "$pauth" != "yes" && "$pauth" != "no" ]] && { warn "无效输入"; continue; }
        sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication $pauth/" $cfg
        systemctl restart ssh
        log "PasswordAuthentication 已设为 $pauth"
        ;;
      q) break ;;
      *) warn "无效选项";;
    esac
  done
}

# ---------------------- Docker 管理 ----------------------
install_docker() {
  if ! command -v curl &>/dev/null; then
    log "安装 curl..."
    apt-get update && apt-get install -y curl || { error "curl 安装失败"; exit 1; }
  fi
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh || { error "Docker 安装失败"; exit 1; }
    apt-get install -y docker-compose-plugin || { error "docker-compose 插件安装失败"; exit 1; }
    usermod -aG docker "${SUDO_USER:-$(logname)}"
    log "Docker 安装完成，请重启系统并重新运行脚本"
    exit 0
  else
    log "Docker 已安装"
  fi
}

docker_one_click() {
  while true; do
    choice=$(menu_prompt "停止所有容器" "启动所有容器" "重启所有容器" "删除所有容器" "删除所有镜像" "清理 & 重置")
    case "$choice" in
      1) docker stop $(docker ps -q) ;;
      2) docker start $(docker ps -aq) ;;
      3) docker restart $(docker ps -q) ;;
      4) docker rm -f $(docker ps -aq) ;;
      5) docker rmi -f $(docker images -q) ;;
      6) docker system prune -af && rm -rf "$BASE_DIR/docker" ;;
      q) break ;;
      *) warn "无效选项";;
    esac
  done
}

# ---------------------- 系统更新与清理 ----------------------
update_system() {
  cp /etc/apt/sources.list /etc/apt/sources.list.bak
  sed -i "s|^deb .*|deb http://deb.debian.org/debian ${CODENAME} main contrib non-free|" /etc/apt/sources.list
  apt-get update && apt-get upgrade -y
  log "系统更新完毕"
}

log_rotate() {
  for c in $(docker ps -aq --format '{{.Names}}'); do
    log_file="/var/lib/docker/containers/$(docker inspect --format='{{.Id}}' "$c")/$c-json.log"
    if [[ -f "$log_file" ]]; then
      truncate -s 0 "$log_file"
      log "日志已清理: $c"
    fi
  done
  log "日志清理完毕"
}

# ---------------------- 主菜单 ----------------------
main_menu() {
  while true; do
    choice=$(menu_prompt "网络设置" "SSH 设置" "Docker 管理" "系统更新与清理")
    case "$choice" in
      1) network_detect ;;
      2) check_ssh_status ;;
      3) install_docker ;;
      4) update_system ;;
      q) log "退出脚本"; exit 0 ;;
      *) warn "无效选项";;
    esac
  done
}

main_menu
