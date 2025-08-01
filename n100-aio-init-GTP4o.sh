#!/usr/bin/env bash
# N100 AIO 初始化脚本 v0.24 优化版
# 支持：环境检测、SSH管理、防火墙管理、网络管理、磁盘管理、Docker管理、系统管理、脚本升级

set -euo pipefail
IFS=$'\n\t'

# 定义颜色和日志函数
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 权限检测
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 或 sudo 运行此脚本"
  exit 1
fi

# 功能：环境检测
env_check() {
  log "检测系统环境..."
  echo "操作系统: $(lsb_release -d | awk -F"\t" '{print $2}')"
  echo "内核版本: $(uname -r)"
  echo "CPU: $(lscpu | grep 'Model name' | awk -F": " '{print $2}')"
  echo "内存: $(free -h | awk '/Mem:/{print $2}')"
  echo "网络: IP=$(hostname -I | awk '{print $1}') | 网关=$(ip route | grep default | awk '{print $3}') | DNS=$(grep nameserver /etc/resolv.conf | awk '{print $2}')"
  systemctl is-active --quiet ssh && echo "SSH状态: 已运行" || echo "SSH状态: 未运行"
  systemctl is-active --quiet ufw && echo "防火墙状态: 已启用" || echo "防火墙状态: 未启用"
}

# 功能：SSH管理
check_ssh() {
  systemctl is-active --quiet ssh && log "SSH服务正在运行" || warn "SSH服务未运行"
  log "SSH端口: $(grep '^Port' /etc/ssh/sshd_config | awk '{print $2}')"
}

enable_ssh() {
  log "启用SSH并允许root登录..."
  apt-get install -y openssh-server
  sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl enable --now ssh
  log "SSH已配置完成"
}

# 功能：防火墙管理
firewall_status() {
  systemctl is-active --quiet ufw && log "防火墙已启用" || warn "防火墙未启用"
}

open_firewall_port() {
  read -rp "请输入要开放的端口: " port
  ufw allow "$port" && log "已开放端口: $port"
}

# 功能：网络管理
check_network() {
  log "检测网络连接..."
  ping -c 3 8.8.8.8 >/dev/null 2>&1 && log "网络正常" || error "网络异常，请检查设置"
}

# 功能：磁盘管理
disk_status() {
  lsblk && df -h
}

create_dirs() {
  log "创建基础目录结构..."
  mkdir -p /mnt/{usbdata,media} && log "基础目录已创建"
}

# 功能：Docker管理
install_docker() {
  log "安装Docker和Compose..."
  apt-get update && apt-get install -y docker.io docker-compose
  systemctl enable --now docker && log "Docker安装并已启动"
}

docker_maintenance() {
  log "进行Docker一键护理操作..."
  docker ps -a && log "所有容器状态已显示"
}

# 功能：系统管理
system_update() {
  log "更新系统..."
  apt-get update && apt-get upgrade -y && apt-get autoremove -y && apt-get autoclean
  log "系统更新完成"
}

log_cleanup() {
  log "清理日志..."
  find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
}

# 功能：脚本升级
upgrade_script() {
  local url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/n100-aio-init-DB.sh"
  curl -o /usr/local/bin/n100-init "$url" && chmod +x /usr/local/bin/n100-init
  log "脚本已升级到最新版本"
}

# 主菜单
while true; do
  clear
  echo "====== N100 AIO 初始化 v0.24 ======"
  env_check # 环境检测
  echo -e "1) SSH管理\n2) 防火墙管理\n3) 网络管理\n4) 磁盘管理\n5) Docker管理\n6) 系统管理\n7) 脚本升级\nq) 退出脚本"
  read -rp "请选择功能: " choice

  case "$choice" in
    1) 
      echo -e "1) 查看SSH状态\n2) 启用SSH\n3) 配置SSH"
      read -rp "请选择: " ssh_choice
      case "$ssh_choice" in
        1) check_ssh ;;
        2) enable_ssh ;;
        *) warn "无效选项" ;;
      esac
      ;;
    2)
      echo -e "1) 查看防火墙状态\n2) 开放防火墙端口"
      read -rp "请选择: " fw_choice
      case "$fw_choice" in
        1) firewall_status ;;
        2) open_firewall_port ;;
        *) warn "无效选项" ;;
      esac
      ;;
    3) check_network ;;
    4) disk_status ;;
    5) install_docker ;;
    6) system_update ;;
    7) upgrade_script ;;
    q|Q) log "退出脚本"; exit 0 ;;
    *) warn "无效选项，请重新选择" ;;
  esac
done
