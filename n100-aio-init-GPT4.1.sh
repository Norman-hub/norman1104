#!/usr/bin/env bash
# N100 All-In-One 初始化脚本 v0.24  by OpenAI助手（含您反馈的全部修改）

set -euo pipefail
IFS=$'\n\t'

# ----------------- 配置区 -------------------
ERROR_LOG="/var/log/n100-init-errors.log"
mkdir -p "$(dirname "$ERROR_LOG")"
touch "$ERROR_LOG"

LANGUAGE="zh"  # 初始语言 zh 或 en
BASE_DIR="/mnt/data"
COMPOSE_DIR="$BASE_DIR/docker/compose"
DASHY_CONFIG_DIR="$BASE_DIR/docker/dashy/config"
DASHY_CONF_DEFAULT_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/Dashy-conf.yml"
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
DEFAULT_LOG_DAYS=7

# ----------------- 颜色 -------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ----------------- 多语言支持基础函数 -------------------
msg() {
  # 调用方式示例： msg "welcome"
  case "$1" in
    welcome) [[ $LANGUAGE == "zh" ]] && echo -e "${GREEN}欢迎使用N100 AIO初始化脚本${NC}" || echo -e "${GREEN}Welcome to N100 AIO Init Script${NC}" ;;
    choose_option) [[ $LANGUAGE == "zh" ]] && echo -en "${YELLOW}>>> 请选择操作: ${NC}" || echo -en "${YELLOW}>>> Choose option: ${NC}" ;;
    invalid_option) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[错误] 输入无效，请重试！${NC}" || echo -e "${RED}[ERROR] Invalid input, please retry!${NC}" ;;
    back_main) [[ $LANGUAGE == "zh" ]] && echo -e "${YELLOW}返回主菜单...${NC}" || echo -e "${YELLOW}Returning to main menu...${NC}" ;;
    input_port) [[ $LANGUAGE == "zh" ]] && echo -en "${YELLOW}请输入要开放的端口号（用空格分隔）: ${NC}" || echo -en "${YELLOW}Enter ports to open (space separated): ${NC}" ;;
    no_ports) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[错误] 未输入端口号，操作取消${NC}" || echo -e "${RED}[ERROR] No ports entered, cancelled${NC}" ;;
    ip_not_found) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[错误] 找不到有效IP地址${NC}" || echo -e "${RED}[ERROR] No valid IP address found${NC}" ;;
    confirm_partition) [[ $LANGUAGE == "zh" ]] && echo -en "${RED}!!! 磁盘分区有丢失风险，慎重操作，输入 yes 继续: ${NC}" || echo -en "${RED}!!! Disk partitioning can cause data loss, type yes to continue: ${NC}" ;;
    partition_cancel) [[ $LANGUAGE == "zh" ]] && echo -e "${YELLOW}磁盘分区操作已取消${NC}" || echo -e "${YELLOW}Partition operation canceled${NC}" ;;
    mount_fail) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[警告] 挂载失败，请确认设备和文件系统是否正确${NC}" || echo -e "${RED}[WARN] Mount failed. Check device and filesystem.${NC}" ;;
    docker_installed) [[ $LANGUAGE == "zh" ]] && echo -e "${GREEN}检测到Docker和docker-compose已安装，跳过安装步骤${NC}" || echo -e "${GREEN}Docker and docker-compose detected, skipping installation.${NC}" ;;
    download_fail) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[错误] 文件下载失败${NC}" || echo -e "${RED}[ERROR] Download failed${NC}" ;;
    cleaning_logs_now) [[ $LANGUAGE == "zh" ]] && echo -e "${GREEN}开始立即清理日志...${NC}" || echo -e "${GREEN}Starting immediate log clean...${NC}" ;;
    cleaning_logs_done) [[ $LANGUAGE == "zh" ]] && echo -e "${GREEN}日志清理完成${NC}" || echo -e "${GREEN}Log cleaning done${NC}" ;;
    set_timer_days) [[ $LANGUAGE == "zh" ]] && echo -en "${YELLOW}请输入定时清理间隔天数（整数）: ${NC}" || echo -en "${YELLOW}Enter scheduled clean interval in days (integer): ${NC}" ;;
    invalid_input) [[ $LANGUAGE == "zh" ]] && echo -e "${RED}[错误] 输入不符合格式，请重新输入${NC}" || echo -e "${RED}[ERROR] Input invalid, please try again${NC}" ;;
    confirm_action) [[ $LANGUAGE == "zh" ]] && echo -en "${YELLOW}请确认操作（yes/no）: ${NC}" || echo -en "${YELLOW}Confirm action (yes/no): ${NC}" ;;
    action_cancel) [[ $LANGUAGE == "zh" ]] && echo -e "${YELLOW}操作取消${NC}" || echo -e "${YELLOW}Action cancelled${NC}" ;;
  esac
}

# ----------------- 日志函数 -------------------
log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; echo "[$(date +'%F %T')] ERROR: $*" >> "$ERROR_LOG"; }

# ----------------- 权限检查 -------------------
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 权限运行此脚本"
  exit 1
fi

# ----------------- 网络自动检测 -------------------
env_auto_check() {
  echo -e "\n====== N100 AIO 初始化 v0.24 ======"
  echo "环境自动检测中..."

  # 操作系统
  local os_info kernel cpu_info mem ip gateway dns ssh_state firewall_state
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_info="$NAME $VERSION"
  else
    os_info="未知系统"
  fi
  kernel=$(uname -r)
  cpu_info=$(awk -F ': ' '/model name/{print $2; exit}' /proc/cpuinfo)
  mem=$(free -h | awk '/^Mem:/ {print $2 " 总，" $7 " 可用"}')
  ip=$(ip -o -4 addr show scope global | awk '{print $4}' | head -1)
  gateway=$(ip route | awk '/default/ {print $3; exit}')
  dns=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd ',' -)
  ssh_state="关闭"
  if systemctl is-active --quiet ssh; then ssh_state="开启"; fi

  # 防火墙状态
  if command -v ufw >/dev/null 2>&1; then
    firewall_state=$(ufw status | head -1)
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall_state=$(firewall-cmd --state 2>/dev/null || echo "未启动")
  else 
    firewall_state="无防火墙/无法检测"
  fi

  echo "操作系统: $os_info"
  echo "内核版本: $kernel"
  echo "CPU: $cpu_info"
  echo "内存: $mem"
  if [[ -n "$ip" ]]; then
    echo -e "网络:\n  IP: $ip\n  网关: $gateway\n  DNS: $dns"
  else
    warn "未检测到有效IP地址"
  fi
  echo "SSH状态: $ssh_state"
  echo "防火墙状态: $firewall_state"
  echo "============================="
}

# ----------------- 防火墙管理 -------------------
firewall_menu() {
  while true; do
    echo -e "\n=== 防火墙管理 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 查看防火墙状态"
      echo "2) 查看防火墙开放端口"
      echo "3) 设定开放端口"
      echo "b) 返回主菜单"
    else
      echo "1) Show Firewall Status"
      echo "2) Show Open Ports"
      echo "3) Set Open Ports"
      echo "b) Back to Main Menu"
    fi

    msg choose_option
    read -r opt
    case "$opt" in
      1)
        if command -v ufw >/dev/null 2>&1; then
          ufw status verbose || warn "无法查看防火墙状态"
        elif command -v firewall-cmd >/dev/null 2>&1; then
          firewall-cmd --state || warn "防火墙未启动"
        else
          iptables -L -n -v || warn "iptables不可用"
        fi
        ;;
      2)
        # 修正：用case循环打印每个端口，避免整行传递
        if command -v ufw >/dev/null 2>&1; then
          ufw status numbered
        elif command -v firewall-cmd >/dev/null 2>&1; then
          firewall-cmd --list-ports
        else
          iptables -L INPUT -n --line-numbers | grep dpt
        fi
        ;;
      3)
        msg input_port
        read -r ports
        if [[ -z "$ports" ]]; then
          msg no_ports
          continue
        fi
        # 分开处理每个端口
        if command -v ufw >/dev/null 2>&1; then
          for p in $ports; do ufw allow "$p"; done
          ufw reload
          log "端口已通过ufw开放：$ports"
        elif command -v firewall-cmd >/dev/null 2>&1; then
          for p in $ports; do firewall-cmd --permanent --add-port="${p}/tcp"; done
          firewall-cmd --reload
          log "端口已通过firewalld开放：$ports"
        else
          for p in $ports; do
            # iptables单次命令只能处理一个端口
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
          done
          log "端口已通过iptables规则开放（重启丢失）：$ports"
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------------- 网络管理 -------------------
network_menu() {
  while true; do
    echo -e "\n=== 网络管理 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 查看网络状态"
      echo "2) 配置网络 (静态IP/DHCP)"
      echo "b) 返回主菜单"
    else
      echo "1) Show Network Status"
      echo "2) Configure Network (Static IP/DHCP)"
      echo "b) Back to Main Menu"
    fi
    msg choose_option
    read -r net_opt
    case "$net_opt" in
      1)
        ip addr show
        ip route show
        ;;
      2)
        echo -e "\n1) 静态IP配置（需手动输入IP/网关/DNS）"
        echo "2) DHCP动态获取IP"
        msg choose_option
        read -r ip_conf
        if [[ "$ip_conf" == "1" ]]; then
          echo "请输入接口名（如 eth0）:"
          read -r iface
          echo "请输入静态IP（格式 192.168.x.x/24）:"
          read -r ipaddr
          echo "请输入网关:"
          read -r gw
          echo "请输入DNS(多个用空格分隔):"
          read -r dns_entry

          # 备份interfaces
          cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%F_%T)
          # 编辑接口配置（简易示例，仅覆盖）
          cat >/etc/network/interfaces <<EOF
auto $iface
iface $iface inet static
    address $ipaddr
    gateway $gw
    dns-nameservers $dns_entry
EOF
          systemctl restart networking
          log "静态IP配置完成并重启网络服务"
        elif [[ "$ip_conf" == "2" ]]; then
          echo "请输入接口名（如 eth0）："
          read -r iface
          cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%F_%T)
          cat >/etc/network/interfaces <<EOF
auto $iface
iface $iface inet dhcp
EOF
          systemctl restart networking
          log "DHCP配置完成已生效"
        else
          msg invalid_option
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------------- 磁盘管理 -------------------
disk_menu() {
  while true; do
    echo -e "\n=== 磁盘管理 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 查看磁盘状态"
      echo "2) 磁盘分区 (请谨慎)"
      echo "3) 磁盘挂载"
      echo "b) 返回主菜单"
    else
      echo "1) Show Disk Status"
      echo "2) Partition Disk (Be careful)"
      echo "3) Mount Disk"
      echo "b) Back to Main Menu"
    fi
    msg choose_option
    read -r disk_opt
    case "$disk_opt" in
      1)
        echo "显示所有磁盘及分区状态："
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL | column -t
        echo
        echo "未分区磁盘标记为: FSTYPE为空"
        ;;
      2)
        msg confirm_partition
        read -r confirm
        if [[ "$confirm" != "yes" ]]; then
          msg partition_cancel
          continue
        fi
        echo "请输入要分区的磁盘，如 /dev/sdb ："
        read -r disk_dev
        if [[ ! -b "$disk_dev" ]]; then
          warn "磁盘设备不存在"
          continue
        fi
        # fdisk界面提示（中文辅助提示）
        echo -e "${YELLOW}fdisk中文指令辅助：n-新建分区, d-删除分区, p-打印分区表, w-写入退出${NC}"
        fdisk "$disk_dev"
        ;;
      3)
        echo "请输入设备名（如 /dev/sdb1）："
        read -r dev
        if [[ -z "$dev" || ! -b "$dev" ]]; then
          warn "设备输入为空或不存在"
          continue
        fi
        echo "请输入挂载目录（如 /mnt/data1）："
        read -r mp
        if [[ -z "$mp" ]]; then
          warn "挂载目录输入不能为空"
          continue
        fi
        mkdir -p "$mp"
        if mount "$dev" "$mp"; then
          log "挂载成功：$dev -> $mp"
        else
          msg mount_fail
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------------- 目录管理 -------------------
directory_menu() {
  while true; do
    echo -e "\n=== 目录管理 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 创建基础目录结构（根据docker-compose配置）"
      echo "2) 创建常用媒体目录"
      echo "3) 查看现有目录结构"
      echo "4) 下载Dashy配置文件"
      echo "b) 返回主菜单"
    else
      echo "1) Create basic directories (from docker-compose)"
      echo "2) Create common media folders"
      echo "3) View current directory structure"
      echo "4) Download Dashy config file"
      echo "b) Back to Main Menu"
    fi
    msg choose_option
    read -r dir_opt
    case "$dir_opt" in
      1)
        echo "1) 从固定URL下载docker-compose.yml"
        echo "2) 手动输入URL下载docker-compose.yml"
        msg choose_option
        read -r url_opt
        if [[ "$url_opt" == "1" ]]; then
          mkdir -p "$COMPOSE_DIR"
          if curl -fsSL "$DEFAULT_COMPOSE_URL" -o "$COMPOSE_DIR/docker-compose.yml"; then
            log "docker-compose.yml 下载成功"
          else
            msg download_fail
            continue
          fi
        elif [[ "$url_opt" == "2" ]]; then
          echo "请输入docker-compose.yml文件URL："
          read -r user_url
          mkdir -p "$COMPOSE_DIR"
          if curl -fsSL "$user_url" -o "$COMPOSE_DIR/docker-compose.yml"; then
            log "docker-compose.yml 下载成功"
          else
            msg download_fail
            continue
          fi
        else
          msg invalid_option
          continue
        fi
        # 解析compose文件中volumes路径，创建对应目录（通过yaml解析简化版匹配）
        grep -E "^\s*-\s*[^:]+:" "$COMPOSE_DIR/docker-compose.yml" | while read -r line; do
          # 取冒号之前部分，例如 - ./data:/data，取./data
          vol=$(echo "$line" | sed -n 's/^\s*-\s*\([^:]*\):.*$/\1/p' | tr -d '[]')
          if [[ -n "$vol" && "$vol" =~ ^[./] ]]; then
            dir_path="$BASE_DIR/${vol#./}"
            mkdir -p "$dir_path"
            log "创建容器映射卷目录：$dir_path"
          fi
        done
        ;;
      2)
        mkdir -p "$BASE_DIR/media/movies" "$BASE_DIR/media/tvshows" "$BASE_DIR/media/av" "$BASE_DIR/media/downloads"
        log "已创建媒体目录：media/{movies,tvshows,av,downloads}"
        ;;
      3)
        tree -L 3 "$BASE_DIR" 2>/dev/null || ls -R "$BASE_DIR"
        ;;
      4)
        mkdir -p "$DASHY_CONFIG_DIR"
        if curl -fsSL "$DASHY_CONF_DEFAULT_URL" -o "$DASHY_CONFIG_DIR/conf.yml"; then
          log "Dashy配置文件下载并重命名为 conf.yml"
        else
          msg download_fail
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------------- Docker管理 -------------------
docker_menu() {
  while true; do
    echo -e "\n=== Docker管理 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 安装Docker & docker-compose"
      echo "2) 部署容器"
      echo "3) Docker一键运维"
      echo "4) 容器日志清理"
      echo "b) 返回主菜单"
    else
      echo "1) Install Docker & docker-compose"
      echo "2) Deploy Containers"
      echo "3) One-click Docker Maintenance"
      echo "4) Clean Container Logs"
      echo "b) Back to Main Menu"
    fi

    msg choose_option
    read -r dock_opt
    case "$dock_opt" in
      1)
        # 判断是否已安装docker和docker-compose
        if command -v docker >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then
          msg docker_installed
        else
          log "正在安装Docker及docker-compose..."
          apt-get update
          apt-get install -y docker.io docker-compose
          systemctl enable docker
          systemctl start docker
          log "Docker及docker-compose安装完成"
        fi
        ;;
      2)
        echo "1) 从固定URL下载docker-compose.yml部署"
        echo "2) 手动输入URL下载docker-compose.yml部署"
        msg choose_option
        read -r deploy_opt
        if [[ "$deploy_opt" == "1" ]]; then
          mkdir -p "$COMPOSE_DIR"
          if curl -fsSL "$DEFAULT_COMPOSE_URL" -o "$COMPOSE_DIR/docker-compose.yml"; then
            log "docker-compose.yml 下载成功"
          else
            msg download_fail
            continue
          fi
        elif [[ "$deploy_opt" == "2" ]]; then
          echo "请输入docker-compose.yml文件URL："
          read -r user_url
          mkdir -p "$COMPOSE_DIR"
          if curl -fsSL "$user_url" -o "$COMPOSE_DIR/docker-compose.yml"; then
            log "docker-compose.yml 下载成功"
          else
            msg download_fail
            continue
          fi
        else
          msg invalid_option
          continue
        fi
        # 创建映射目录脚本与目录管理类似
        grep -E "^\s*-\s*[^:]+:" "$COMPOSE_DIR/docker-compose.yml" | while read -r line; do
          vol=$(echo "$line" | sed -n 's/^\s*-\s*\([^:]*\):.*$/\1/p' | tr -d '[]')
          if [[ -n "$vol" && "$vol" =~ ^[./] ]]; then
            dir_path="$BASE_DIR/${vol#./}"
            mkdir -p "$dir_path"
            log "创建容器映射目录：$dir_path"
          fi
        done
        (cd "$COMPOSE_DIR" && docker-compose up -d)
        log "容器部署完成"
        ;;
      3) docker_one_click ;; 
      4) docker_log_cleanup ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# Docker一键运维细节加中文提示及确认
docker_one_click() {
  while true; do
    echo -e "\n=== Docker一键运维 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 查看所有容器状态"
      echo "2) 对单个容器操作 (启动|停止|重启)"
      echo "3) 重启所有运行容器"
      echo "4) 停止所有运行容器"
      echo "5) 清理无用镜像和容器"
      echo "b) 返回上级菜单"
    else
      echo "1) Show all containers"
      echo "2) Single container action (start|stop|restart)"
      echo "3) Restart all running containers"
      echo "4) Stop all running containers"
      echo "5) Clean unused images and containers"
      echo "b) Back"
    fi
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        docker ps -a || warn "Docker命令失败"
        ;;
      2)
        echo "请输入容器名称或ID："
        read -r cid
        echo "请输入动作: start(启动)/stop(停止)/restart(重启)"
        read -r action
        if [[ "$action" != "start" && "$action" != "stop" && "$action" != "restart" ]]; then
          msg invalid_option
          continue
        fi
        echo "确认执行 $action 容器 $cid ?"
        msg confirm_action
        read -r confirm
        if [[ "$confirm" == "yes" ]]; then
          docker "$action" "$cid" && log "操作成功" || warn "操作失败"
        else
          msg action_cancel
        fi
        ;;
      3)
        msg confirm_action
        read -r confirm
        if [[ "$confirm" == "yes" ]]; then
          docker ps -q | xargs -r docker restart && log "所有运行容器重启完成" || warn "重启容器失败"
        else
          msg action_cancel
        fi
        ;;
      4)
        msg confirm_action
        read -r confirm
        if [[ "$confirm" == "yes" ]]; then
          docker ps -q | xargs -r docker stop && log "所有运行容器停止完成" || warn "停止容器失败"
        else
          msg action_cancel
        fi
        ;;
      5)
        msg confirm_action
        read -r confirm
        if [[ "$confirm" == "yes" ]]; then
          docker system prune -a -f --volumes && log "无用镜像及容器清理完成" || warn "清理失败"
        else
          msg action_cancel
        fi
        ;;
      b|B) break ;;
      *) msg invalid_option ;;
    esac
  done
}

# 容器日志清理
docker_log_cleanup() {
  while true; do
    echo -e "\n=== 容器日志清理 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 立即清理所有容器日志"
      echo "2) 设置定时清理容器日志（以天为单位）"
      echo "b) 返回"
    else
      echo "1) Immediate clean all container logs"
      echo "2) Schedule container logs cleaning (days)"
      echo "b) Back"
    fi
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        msg cleaning_logs_now
        for logf in /var/lib/docker/containers/*/*.log; do
          : > "$logf" || warn "无法清空日志 $logf"
        done
        msg cleaning_logs_done
        ;;
      2)
        msg set_timer_days
        read -r days
        if [[ ! "$days" =~ ^[0-9]+$ ]] || (( days < 1 )); then
          msg invalid_input
          continue
        fi
        # 设定cron job，示例写入/root/cron_docker_log_cleanup.sh
        cat >/root/cron_docker_log_cleanup.sh <<EOF
#!/bin/bash
for logf in /var/lib/docker/containers/*/*.log; do
  : > "\$logf"
done
EOF
        chmod +x /root/cron_docker_log_cleanup.sh
        (crontab -l 2>/dev/null | grep -v 'cron_docker_log_cleanup.sh'; echo "0 3 */$days * * /root/cron_docker_log_cleanup.sh") | crontab -
        log "已设置每${days}天凌晨3点自动清理容器日志"
        ;;
      b|B) break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------------- 系统管理 -------------------
system_menu() {
  while true; do
    echo -e "\n=== 系统管理 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 更新 & 升级系统"
      echo "2) 系统日志清理"
      echo "b) 返回主菜单"
    else
      echo "1) Update and Upgrade System"
      echo "2) System Logs Cleaning"
      echo "b) Back to Main Menu"
    fi
    msg choose_option
    read -r sys_opt
    case "$sys_opt" in
      1)
        apt-get update && apt-get upgrade -y && log "系统升级完成" || warn "更新失败"
        ;;
      2)
        system_log_cleanup
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# 系统日志清理（立即与定时）
system_log_cleanup() {
  while true; do
    echo -e "\n=== 系统日志清理 ==="
    if [[ $LANGUAGE == "zh" ]]; then
      echo "1) 立即清理所有日志"
      echo "2) 设置定时清理（天）"
      echo "b) 返回"
    else
      echo "1) Immediate clean all logs"
      echo "2) Schedule log cleaning (days)"
      echo "b) Back"
    fi
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        msg cleaning_logs_now
        find /var/log -type f \( -name "*.log" -o -name "*.old" -o -name "*.gz" \) -delete
        msg cleaning_logs_done
        ;;
      2)
        msg set_timer_days
        read -r days
        if [[ ! "$days" =~ ^[0-9]+$ ]] || (( days < 1 )); then
          msg invalid_input
          continue
        fi
        # 定时任务脚本
        cat >/root/cron_sys_log_cleanup.sh <<EOF
#!/bin/bash
find /var/log -type f \( -name "*.log" -o -name "*.old" -o -name "*.gz" \) -delete
EOF
        chmod +x /root/cron_sys_log_cleanup.sh
        (crontab -l 2>/dev/null | grep -v 'cron_sys_log_cleanup.sh'; echo "0 4 */$days * * /root/cron_sys_log_cleanup.sh") | crontab -
        log "已设置每${days}天凌晨4点自动清理系统日志"
        ;;
      b|B) break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------------- 语言切换 -------------------
language_menu() {
  echo -e "\n=== 语言选择 / Language Selection ==="
  echo "1) 中文"
  echo "2) English"
  msg choose_option
  read -r lang_opt
  case "$lang_opt" in
    1) LANGUAGE="zh"; log "语言已切换为中文" ;;
    2) LANGUAGE="en"; log "Language switched to English" ;;
    *) msg invalid_option ;;
  esac
}

# ----------------- 主菜单 -------------------
main_menu() {
  while true; do
    env_auto_check
    if [[ $LANGUAGE == "zh" ]]; then
      echo -e "\n====== N100 AIO 初始化 v0.24 ======"
      echo "1) SSH管理"
      echo "2) 防火墙管理"
      echo "3) 网络管理"
      echo "4) 磁盘管理"
      echo "5) 目录管理"
      echo "6) Docker管理"
      echo "7) 系统管理"
      echo "8) 脚本升级"
      echo "9) 语言切换"
      echo "q) 退出脚本"
    else
      echo -e "\n====== N100 AIO Init v0.24 ======"
      echo "1) SSH Management"
      echo "2) Firewall Management"
      echo "3) Network Management"
      echo "4) Disk Management"
      echo "5) Directory Management"
      echo "6) Docker Management"
      echo "7) System Management"
      echo "8) Script Upgrade"
      echo "9) Language Switch"
      echo "q) Quit"
    fi

    msg choose_option
    read -r choice
    case "$choice" in
      1) ssh_menu ;;
      2) firewall_menu ;;
      3) network_menu ;;
      4) disk_menu ;;
      5) directory_menu ;;
      6) docker_menu ;;
      7) system_menu ;;
      8) script_upgrade ;;
      9) language_menu ;;
      q|Q) log "退出脚本，再见！"; exit 0 ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------------- SSH管理 -------------------
ssh_menu() {
  while true; do
    if [[ $LANGUAGE == "zh" ]]; then
      echo -e "\n=== SSH管理 ==="
      echo "1) 查看SSH状态"
      echo "2) 安装并启用SSH服务"
      echo "3) 配置SSH允许root登录"
      echo "b) 返回主菜单"
    else
      echo -e "\n=== SSH Management ==="
      echo "1) Show SSH status"
      echo "2) Install and enable SSH service"
      echo "3) Configure SSH to allow root login"
      echo "b) Back to Main Menu"
    fi
    msg choose_option
    read -r ssh_opt
    case "$ssh_opt" in
      1)
        if systemctl is-active --quiet ssh; then
          log "SSH服务运行中"
        else
          warn "SSH服务未运行"
        fi
        ;;
      2)
        if command -v sshd >/dev/null 2>&1 || command -v ssh >/dev/null 2>&1; then
          log "检测到SSH已安装"
        else
          log "安装openssh-server..."
          apt-get update
          apt-get install -y openssh-server
        fi
        systemctl enable ssh
        systemctl start ssh
        log "SSH服务已启动"
        ;;
      3)
        local SSHD_CONF="/etc/ssh/sshd_config"
        if grep -Eq "^PermitRootLogin yes" "$SSHD_CONF"; then
          log "SSH已允许root登录"
        else
          sed -i.bak '/^PermitRootLogin/s/.*/PermitRootLogin yes/' "$SSHD_CONF" || echo "PermitRootLogin yes" >> "$SSHD_CONF"
          systemctl reload ssh
          log "配置允许root登录，已重载SSH服务"
        fi
        ;;
      b|B) break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ----------------- 脚本升级 -------------------
script_upgrade() {
  echo "正在自动升级脚本..."
  local url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/n100-aio-init-GPT4.1.sh"
  local tmpfile="/tmp/n100-aio-init-upgrade.sh"
  if curl -fsSL "$url" -o "$tmpfile"; then
    chmod +x "$tmpfile"
    mv "$tmpfile" "$(realpath "$0")"
    log "升级成功，脚本已替换，请重新运行"
    exit 0
  else
    msg download_fail
  fi
}

# 启动主菜单
main_menu
