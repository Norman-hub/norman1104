#!/usr/bin/env bash
# ---------------------------------------------------------------------------- #
# N100 All-in-One 初始化脚本 v0.24 优化版
# 需求：环境自动检测，菜单重新设计，日志优化，关键位置强提醒
# ---------------------------------------------------------------------------- #

set -euo pipefail
IFS=$'\n\t'

# 日志文件路径
ERROR_LOG="/var/log/n100-init-errors.log"
mkdir -p "$(dirname "$ERROR_LOG")"
touch "$ERROR_LOG"

# 颜色定义
RED='\033[0;31m'      # 错误红
GREEN='\033[0;32m'    # 信息绿
YELLOW='\033[1;33m'   # 警告黄
NC='\033[0m'          # 结束颜色

# 日志函数
log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; echo "[$(date '+%F %T')] ERROR: $*" >> "$ERROR_LOG"; }
prompt() { echo -en "${YELLOW}>>> ${NC}"; }

# 检查是否root权限
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 或 sudo 运行此脚本"
  exit 1
fi

# 环境信息自动检测并展示
env_auto_check() {
  echo -e "\n====== N100 AIO 初始化 v0.24 ======"
  echo "自动环境检测中..."

  # OS
  local os_info kernel cpu_model cpu_cores mem_total mem_available ip_address gateway dns ssh_state firewall_state

  # 操作系统
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_info="$NAME $VERSION"
  else
    os_info="未知"
  fi
  echo "操作系统: $os_info"

  # 内核版本
  kernel="$(uname -r)"
  echo "内核版本: $kernel"

  # CPU信息
  cpu_model=$(awk -F ': ' '/model name/{print $2; exit}' /proc/cpuinfo)
  cpu_cores=$(grep -c '^processor' /proc/cpuinfo)
  echo "CPU: $cpu_model ($cpu_cores 核心)"

  # 内存
  mem_total=$(free -h | awk '/^Mem:/ {print $2}')
  mem_available=$(free -h | awk '/^Mem:/ {print $7}')
  echo "内存: 总计 $mem_total，可用 $mem_available"

  # 网络
  ip_address=$(ip -4 -o addr show scope global | awk '{print $4}' | head -n1)
  gateway=$(ip route | awk '/default/ {print $3; exit}')
  dns=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd ',' -)
  echo -e "网络:\n  IP地址： $ip_address\n  网关： $gateway\n  DNS： $dns"

  # SSH状态检测
  if systemctl is-active --quiet ssh; then
    ssh_state="开启"
  else
    ssh_state="关闭"
  fi
  echo "SSH状态: $ssh_state"

  # 防火墙状态检测 (ufw或iptables)
  if command -v ufw >/dev/null 2>&1; then
    fw_status=$(ufw status | head -n1)
    firewall_state="$fw_status"
  elif command -v iptables >/dev/null 2>&1; then
    # 简单检测iptables是否有规则
    if iptables -L -n | grep -q ACCEPT; then
      firewall_state="iptables规则存在"
    else
      firewall_state="iptables无规则"
    fi
  else
    firewall_state="无防火墙或无法检测"
  fi
  echo "防火墙状态: $firewall_state"
  echo "============================="
}

# ===== 主菜单 =====
main_menu() {
  while true; do
    env_auto_check
    echo -e "\n请选择操作:"

    echo "1) SSH管理"
    echo "2) 防火墙管理"
    echo "3) 网络管理"
    echo "4) 磁盘管理"
    echo "5) 目录管理"
    echo "6) Docker管理"
    echo "7) 系统管理"
    echo "8) 脚本升级"
    echo "q) 退出脚本"

    prompt
    read -r main_choice
    case $main_choice in
      1) ssh_menu ;;
      2) firewall_menu ;;
      3) network_menu ;;
      4) disk_menu ;;
      5) directory_menu ;;
      6) docker_menu ;;
      7) system_menu ;;
      8) script_upgrade ;;
      q|Q)
        log "退出脚本，错误日志保存于 $ERROR_LOG"
        exit 0
        ;;
      *)
        warn "无效输入，请重新选择。"
        ;;
    esac
  done
}

# ===== SSH管理菜单 =====
ssh_menu() {
  while true; do
    echo -e "\n=== SSH管理 ==="
    echo "1) 查看SSH状态"
    echo "2) 安装并启用SSH服务"
    echo "3) 配置SSH允许root登录"
    echo "b) 返回主菜单"
    prompt
    read -r ssh_choice
    case $ssh_choice in
      1)
        if systemctl is-active --quiet ssh; then
          log "SSH服务处于运行状态"
        else
          warn "SSH服务未运行"
        fi
        ;;
      2)
        if command -v sshd >/dev/null 2>&1 || command -v ssh >/dev/null 2>&1; then
          log "SSH已安装，尝试启用并启动服务"
        else
          log "安装openssh-server中..."
          apt-get update && apt-get install -y openssh-server || error "安装 openssh-server 失败"
        fi
        systemctl enable ssh
        systemctl start ssh
        log "SSH服务已启用并启动"
        ;;
      3)
        SSHD_CONF="/etc/ssh/sshd_config"
        if grep -q "^PermitRootLogin yes" "$SSHD_CONF"; then
          log "已允许root登录"
        else
          sed -i.bak '/^PermitRootLogin/s/.*/PermitRootLogin yes/' "$SSHD_CONF" || echo "PermitRootLogin yes" >> "$SSHD_CONF"
          systemctl reload ssh
          log "已配置允许root通过SSH登录，已重载SSH服务"
        fi
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ===== 防火墙管理菜单 =====
firewall_menu() {
  while true; do
    echo -e "\n=== 防火墙管理 ==="
    echo "1) 查看防火墙状态"
    echo "2) 查看防火墙开放端口"
    echo "3) 设定开放端口"
    echo "b) 返回主菜单"
    prompt
    read -r fw_choice
    case $fw_choice in
      1)
        if command -v ufw >/dev/null 2>&1; then
          ufw status verbose
        elif command -v firewall-cmd >/dev/null 2>&1; then
          firewall-cmd --state || warn "防火墙正在停止或不可用"
        else
          iptables -L -n -v
        fi
        ;;
      2)
        if command -v ufw >/dev/null 2>&1; then
          ufw status numbered
        elif command -v firewall-cmd >/dev/null 2>&1; then
          firewall-cmd --list-ports
        else
          iptables -L -n --line-numbers | grep 'dpt:'
        fi
        ;;
      3)
        echo "请输入要开放的端口号（多个用空格分隔）:"
        prompt
        read -r open_ports
        if [[ -z "$open_ports" ]]; then
          warn "无输入，取消操作"
          continue
        fi

        if command -v ufw >/dev/null 2>&1; then
          for p in $open_ports; do
            ufw allow "$p"
          done
          ufw reload
          log "端口 $open_ports 已开放（通过 ufw）"
        elif command -v firewall-cmd >/dev/null 2>&1; then
          for p in $open_ports; do
            firewall-cmd --permanent --add-port="${p}/tcp"
          done
          firewall-cmd --reload
          log "端口 $open_ports 已开放（通过 firewalld）"
        else
          for p in $open_ports; do
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
          done
          log "端口 $open_ports 已添加iptables规则，注意此规则重启后丢失"
        fi
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ===== 网络管理菜单 =====
network_menu() {
  while true; do
    echo -e "\n=== 网络管理 ==="
    echo "1) 查看网络状态"
    echo "2) 配置网络 (DHCP/静态IP)"
    echo "3) 清理重复IP地址"
    echo "b) 返回主菜单"
    prompt
    read -r net_choice
    case $net_choice in
      1)
        ip addr show
        ip route show
        ;;
      2)
        echo "请编辑 /etc/network/interfaces 或使用 network-manager 等工具进行配置"
        warn "本脚本暂未自动修改网络配置，避免误操作！请手动配置。"
        ;;
      3)
        warn "注意：清理重复IP风险较大，请确保环境了解后操作"
        echo "检测重复IP地址的操作请使用网段扫描工具或查看路由器 DHCP 租约"
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ===== 磁盘管理菜单 =====
disk_menu() {
  while true; do
    echo -e "\n=== 磁盘管理 ==="
    echo "1) 查看磁盘状态"
    echo "2) 磁盘分区"
    echo "3) 磁盘挂载"
    echo "b) 返回主菜单"
    prompt
    read -r disk_choice
    case $disk_choice in
      1)
        lsblk || warn "无法获取磁盘信息"
        df -h || warn "无法获取磁盘使用情况"
        ;;
      2)
        echo -e "${RED}!!! 磁盘分区操作有风险，请谨慎操作，数据可能丢失！请提前备份重要数据！！！${NC}"
        echo "是否确认继续磁盘分区？(yes/no)"
        prompt
        read -r confirm
        if [[ "$confirm" == "yes" ]]; then
          echo "示例操作: 启动物理磁盘分区工具 fdisk"
          echo "请输入磁盘名（如 /dev/sdb）："
          prompt
          read -r disk_dev
          if [[ -b "$disk_dev" ]]; then
            fdisk "$disk_dev"
          else
            warn "设备不存在或无权限"
          fi
        else
          log "磁盘分区操作取消"
        fi
        ;;
      3)
        echo "请输入设备（如 /dev/sdb1）："
        prompt
        read -r device
        echo "请输入挂载目录（如 /mnt/data1）："
        prompt
        read -r mount_point
        mkdir -p "$mount_point"
        mount "$device" "$mount_point" && log "挂载成功：$device -> $mount_point" || warn "挂载失败"
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ===== 目录管理菜单 =====
directory_menu() {
  while true; do
    echo -e "\n=== 目录管理 ==="
    echo "1) 创建基础目录结构"
    echo "2) 创建常用媒体目录"
    echo "3) 查看现有目录结构"
    echo "4) 下载Dashy配置文件"
    echo "b) 返回主菜单"
    prompt
    read -r dir_choice
    case $dir_choice in
      1)
        log "创建基础目录结构..."
        mkdir -p /mnt/data/{app,logs,conf}
        log "基础目录结构创建完成：/mnt/data/app /mnt/data/logs /mnt/data/conf"
        ;;
      2)
        log "创建常用媒体目录..."
        mkdir -p /mnt/data/media/{music,video,pictures}
        log "媒体目录创建完成：/mnt/data/media/{music,video,pictures}"
        ;;
      3)
        echo "当前 /mnt/data 目录结构："
        tree -L 2 /mnt/data || ls -R /mnt/data
        ;;
      4)
        local dashy_url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/Dashy-conf.yml"
        local target_dir="/mnt/data/docker/dashy/config"
        mkdir -p "$target_dir"
        if curl -fsSL "$dashy_url" -o "$target_dir/Dashy-conf.yml"; then
          log "Dashy配置文件已下载并保存到 $target_dir/Dashy-conf.yml"
        else
          warn "下载Dashy配置文件失败"
        fi
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ===== Docker管理菜单 =====
docker_menu() {
  while true; do
    echo -e "\n=== Docker管理 ==="
    echo "1) 安装docker & docker-compose"
    echo "2) 部署容器"
    echo "3) Docker一键运维"
    echo "4) 日志清理"
    echo "b) 返回主菜单"
    prompt
    read -r docker_choice
    case $docker_choice in
      1)
        log "安装docker及docker-compose..."
        apt-get update
        apt-get install -y docker.io docker-compose || error "Docker安装失败"
        systemctl enable docker
        systemctl start docker
        log "Docker已安装并启动"
        ;;
      2)
        warn "容器部署功能暂未实现，请根据需求添加"
        ;;
      3)
        docker_one_click_menu
        ;;
      4)
        warn "日志清理功能待完善"
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# Docker一键运维子菜单示例（框架提示）
docker_one_click_menu() {
  while true; do
    echo -e "\n=== Docker一键运维 ==="
    echo "1) 查看所有容器状态"
    echo "2) 对单个容器进行操作"
    echo "3) 重启所有运行中的容器"
    echo "4) 停止所有运行中的容器"
    echo "5) 清理无用镜像和容器"
    echo "b) 返回上级菜单"
    prompt
    read -r choice
    case $choice in
      1)
        docker ps -a
        ;;
      2)
        echo "请输入容器名或ID："
        prompt
        read -r cid
        echo "请选择操作： start | stop | restart"
        prompt
        read -r action
        if docker container "$action" "$cid"; then
          log "操作成功：$action $cid"
        else
          warn "操作失败"
        fi
        ;;
      3)
        docker ps -q | xargs -r docker restart && log "所有运行容器重启完成"
        ;;
      4)
        docker ps -q | xargs -r docker stop && log "所有运行容器已停止"
        ;;
      5)
        docker system prune -af && log "无用镜像和容器已清理"
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ===== 系统管理菜单 =====
system_menu() {
  while true; do
    echo -e "\n=== 系统管理 ==="
    echo "1) 系统更新 & 升级"
    echo "2) 日志清理"
    echo "b) 返回主菜单"
    prompt
    read -r sys_choice
    case $sys_choice in
      1)
        log "更新和升级系统中..."
        apt-get update && apt-get upgrade -y && log "系统更新升级完成" || error "更新升级失败"
        ;;
      2)
        echo "日志清理功能待开发，示例清理/var/log中的.old和.gz文件"
        find /var/log -type f \( -name "*.gz" -o -name "*.old" \) -delete
        log "清理完毕"
        ;;
      b|B) break ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ===== 脚本升级 =====
script_upgrade() {
  echo "自动升级脚本中，可能需要网络连接..."
  local upgrade_url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/n100-aio-init-DB.sh"
  local tmpfile="/tmp/n100-aio-init-upgrade.sh"
  if curl -fsSL "$upgrade_url" -o "$tmpfile"; then
    chmod +x "$tmpfile"
    mv "$tmpfile" "$(realpath "$0")"
    log "脚本升级成功，已自动赋执行权限。请重新运行脚本！"
    exit 0
  else
    warn "脚本升级失败，请检查网络或手动升级"
  fi
}

# 启动脚本
main_menu
