#!/usr/bin/env bash
# N100 All-in-One 初始化脚本 (优化修复版)
set -euo pipefail
shopt -s lastpipe
IFS=$'\n\t'

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# 通用输出函数
log() { echo -e "${GREEN}[√]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[×]${NC} $*" >&2; }
prompt() { 
  echo -en "${YELLOW}[输入]${NC} $*"; 
  read -e "$@"; 
}

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
  echo -en "${YELLOW}[输入] 请选择: ${NC}"
  read -r choice
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
  mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
  log "环境检测通过: 磁盘 $(awk "BEGIN{printf \"%.1fGB\", $avail_kb/1024/1024}")，内存 ${mem_mb}MB"
}
env_check

# ---------------------- 主菜单 ----------------------
main_menu() {
  while true; do
    choice=$(menu_prompt "网络设置" "SSH 设置" "Docker 管理" "系统更新与清理")
    case "$choice" in
      1) log "网络设置功能未实现" ;;  # 示例功能
      2) log "SSH 设置功能未实现" ;;   # 示例功能
      3) log "Docker 管理功能未实现" ;; # 示例功能
      4) log "系统更新与清理功能未实现" ;; # 示例功能
      q) log "退出脚本"; exit 0 ;;
      *) warn "无效选项";;
    esac
  done
}

main_menu
