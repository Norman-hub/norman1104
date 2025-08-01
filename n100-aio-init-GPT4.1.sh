#!/usr/bin/env bash
# N100 AIO 初始化脚本 v0.24 完整版 by OpenAI助手
# 集成环境检测、依赖自动安装、完善防火墙、网络、磁盘、Docker、日志管理等
# 支持中文/英文切换，用户友好提示，稳定高效

set -euo pipefail
IFS=$'\n\t'

# ---------------------- 配置区 ------------------------
ERROR_LOG="/var/log/n100-init-errors.log"
mkdir -p "$(dirname "$ERROR_LOG")"
touch "$ERROR_LOG"

LANGUAGE="zh"  # 默认语言

BASE_DIR="/mnt/data"
COMPOSE_DIR="$BASE_DIR/docker/compose"
DASHY_CONFIG_DIR="$BASE_DIR/docker/dashy/config"
DASHY_CONF_DEFAULT_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/Dashy-conf.yml"
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
DEFAULT_LOG_DAYS=7

# ---------------------- 颜色定义 ------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------------------- 消息多语言 ----------------------
msg() {
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

# ---------------------- 日志 ---------------------------
log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; echo "[$(date +'%F %T')] ERROR: $*" >> "$ERROR_LOG"; }

# ---------------------- 权限检测 -----------------------
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 权限运行此脚本"
  exit 1
fi

# ---------------------- 依赖安装 -----------------------
install_dep() {
  local pkgs=("$@")
  for p in "${pkgs[@]}"; do
    if ! command -v "$p" &>/dev/null; then
      log "检测到缺少依赖 '$p'，准备安装..."
      apt-get update -y
      if ! apt-get install -y "$p"; then
        error "安装依赖 $p 失败"
        return 1
      fi
    fi
  done
  return 0
}

install_yq_if_needed() {
  if ! command -v yq &>/dev/null; then
    log "安装 yq 用于高级 YAML 解析..."
    if ! curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq ||
       ! chmod +x /usr/local/bin/yq; then
      error "安装 yq 失败"
      return 1
    fi
  fi
  return 0
}

# ---------------------- 环境检测 -----------------------
env_auto_check() {
  echo -e "\n====== N100 AIO 初始化 v0.24 ======"

  # 必要依赖检测并安装
  install_dep ip iptables ufw curl tree || warn "部分系统工具安装失败，请手动确认"
  install_yq_if_needed || warn "yq安装失败，部分高级yaml解析功能受限"

  # 操作系统及版本
  local os_info kernel cpu mem ip gateway dns ssh_state firewall_state
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_info="$NAME $VERSION"
  else
    os_info="未知系统"
  fi
  kernel=$(uname -r)
  cpu=$(awk -F ': ' '/model name/{print $2; exit}' /proc/cpuinfo)
  mem=$(free -h | awk '/^Mem:/ {print $2 " 总，" $7 " 可用"}')
  ip=$(ip -o -4 addr show scope global | awk '{print $4}' | head -1)
  gateway=$(ip route | awk '/default/ {print $3; exit}')
  dns=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd ',' -)
  ssh_state=$(systemctl is-active --quiet ssh && echo "开启" || echo "关闭")

  # 防火墙状态检测（ufw/firewalld/iptables）
  if command -v ufw &>/dev/null; then
    firewall_state=$(ufw status | head -1)
  elif command -v firewall-cmd &>/dev/null; then
    firewall_state=$(firewall-cmd --state 2>/dev/null || echo "未启动")
  else
    if iptables -L -n &>/dev/null; then
      firewall_state="iptables规则已设置"
    else
      firewall_state="无防火墙或无法检测"
    fi
  fi

  echo "操作系统: $os_info"
  echo "内核版本: $kernel"
  echo "CPU: $cpu"
  echo "内存: $mem"
  if [[ -n $ip ]]; then
    echo -e "网络信息:\n  IP: $ip\n  网关: $gateway\n  DNS: $dns"
  else
    warn "未检测到有效IP地址"
  fi
  echo "SSH状态: $ssh_state"
  echo "防火墙状态: $firewall_state"
  echo "============================="
}

# ---------------------- 防火墙管理 -----------------------
firewall_show_ports() {
  if command -v ufw &>/dev/null; then
    ufw status numbered || warn "无法查看ufw状态"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --list-ports || warn "无法查看firewalld端口"
  elif command -v iptables &>/dev/null; then
    local out
    out=$(iptables -L INPUT -n --line-numbers 2>/dev/null | grep 'dpt:' || true)
    if [[ -z "$out" ]]; then
      echo "无开放端口规则"
    else
      echo "$out"
    fi
  else
    warn "未检测到可用防火墙管理工具"
  fi
}

firewall_set_ports() {
  msg input_port
  read -r ports
  if [[ -z "$ports" ]]; then
    msg no_ports
    return
  fi

  if command -v ufw &>/dev/null; then
    for p in $ports; do ufw allow "$p"; done
    ufw reload
    log "端口已通过ufw开放：$ports"
  elif command -v firewall-cmd &>/dev/null; then
    for p in $ports; do firewall-cmd --permanent --add-port="${p}/tcp"; done
    firewall-cmd --reload
    log "端口已通过firewalld开放：$ports"
  elif command -v iptables &>/dev/null; then
    for p in $ports; do
      if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        echo "[INFO] 端口 $p已添加iptables规则"
      else
        echo "[WARN] 端口 $p规则已存在，跳过"
      fi
    done
  else
    error "无可用防火墙工具，无法设定端口"
  fi
}

firewall_menu() {
  while true; do
    echo -e "\n=== 防火墙管理 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 查看防火墙状态\n2) 查看防火墙开放端口\n3) 设定开放端口\nb) 返回主菜单" || echo "1) Show Firewall Status\n2) Show Open Ports\n3) Set Open Ports\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        if command -v ufw &>/dev/null; then ufw status verbose
        elif command -v firewall-cmd &>/dev/null; then firewall-cmd --state || warn "防火墙未启动"
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

# ---------------------- 网络管理 -----------------------
list_interfaces() {
  echo "当前接口及IP列表："
  ip -o -4 addr show | awk '{print NR": "$2, "IP: "$4}'
}

configure_static_ip() {
  list_interfaces
  echo "请输入接口名（例如 eth0）："
  read -r iface
  if ! ip link show "$iface" &>/dev/null; then echo "[错误] 接口 $iface 不存在"; return; fi
  echo "请输入静态IP（带掩码，如 192.168.1.100/24）："
  read -r ipaddr
  echo "请输入网关："
  read -r gw
  echo "请输入DNS服务器地址（空格分隔）："
  read -r dnses

  cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%F_%T)
  cat >/etc/network/interfaces <<EOF
auto $iface
iface $iface inet static
  address $ipaddr
  gateway $gw
  dns-nameservers $dnses
EOF
  systemctl restart networking && log "静态IP配置成功" || warn "网络重启失败"
}

configure_dhcp() {
  list_interfaces
  echo "请输入接口名（例如 eth0）："
  read -r iface
  if ! ip link show "$iface" &>/dev/null; then echo "[错误] 接口 $iface 不存在"; return; fi
  cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%F_%T)
  cat >/etc/network/interfaces <<EOF
auto $iface
iface $iface inet dhcp
EOF
  systemctl restart networking && log "DHCP配置成功" || warn "网络重启失败"
}

network_menu() {
  while true; do
    echo -e "\n=== 网络管理 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 查看网络状态\n2) 配置网络 (静态IP/DHCP)\nb) 返回主菜单" || echo "1) Show Network Status\n2) Configure Network (Static/DHCP)\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        ip addr show
        ip route show
        ;;
      2)
        echo -e "1) 静态IP配置\n2) DHCP动态获取IP"
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

# ---------------------- 磁盘管理 -----------------------
disk_menu() {
  while true; do
    echo -e "\n=== 磁盘管理 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 查看磁盘状态\n2) 磁盘分区 (谨慎操作)\n3) 磁盘挂载\nb) 返回主菜单" || echo "1) Show Disk Status\n2) Partition Disk (Be careful)\n3) Mount Disk\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        echo "磁盘及分区信息："
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL | column -t
        echo "未分区磁盘标记为FSTYPE为空"
        ;;
      2)
        msg confirm_partition
        read -r conf
        if [[ "$conf" != "yes" ]]; then msg partition_cancel; continue; fi
        echo "请输入磁盘设备（如 /dev/sdb）："
        read -r dev
        if [[ ! -b "$dev" ]]; then warn "设备不存在"; continue; fi
        echo -e "${YELLOW}fdisk中文指令提示：n-新建, d-删除, p-打印分区, w-写入退出${NC}"
        fdisk "$dev"
        ;;
      3)
        echo "请输入设备名(如 /dev/sdb1)："
        read -r dev
        if [[ -z "$dev" || ! -b "$dev" ]]; then warn "设备无效"; continue; fi
        echo "请输入挂载目录(如 /mnt/data1)："
        read -r mp
        if [[ -z "$mp" ]]; then warn "挂载目录不能为空"; continue; fi
        mkdir -p "$mp"
        if mount "$dev" "$mp"; then
          log "挂载成功 $dev -> $mp"
        else
          msg mount_fail
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ---------------------- 目录管理 -----------------------

create_volume_dirs_from_compose() {
  local compose_file="$COMPOSE_DIR/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    error "docker-compose.yml 文件不存在: $compose_file"
    return 1
  fi

  # 解析宿主机卷路径，去掉 $BASE_DIR 前缀，文件映射保留目录
  # 使用 yq 读取 volumes 键里的宿主机路径
  if ! command -v yq &>/dev/null; then
    warn "未检测到 yq，跳过自动创建卷目录功能"
    return 1
  fi

  mapfile -t vols < <(yq e '.services[].volumes[]' "$compose_file" 2>/dev/null || true)
  for vol in "${vols[@]}"; do
    # vol格式： host_path:container_path 或 bind=host_path:container_path (compose v3+可能)
    local host_path
    if [[ "$vol" =~ ^([^:]+): ]]; then host_path="${BASH_REMATCH[1]}"; else continue; fi
    # 过滤只对相对路径和绝对路径处理，去掉 BASE_DIR 前缀
    # 如果host_path是相对路径 ./ 或者 /mnt/data开头
    [[ "$host_path" == ~* ]] && host_path="${host_path/#\~/$HOME}"
    if [[ "$host_path" == /* ]]; then
      if [[ "$host_path" == "$BASE_DIR"* ]]; then
        host_path="${host_path#$BASE_DIR/}"
      else
        # 对于非$BASE_DIR的绝对路径，仅取目录
        host_path=$(dirname "$host_path")
      fi
    else
      # 相对路径前面没加BASE_DIR时，则以$BASE_DIR开头
      host_path="${host_path#./}"
    fi

    local full_dir="$BASE_DIR/$host_path"
    mkdir -p "$full_dir"
    log "创建容器映射卷目录：$full_dir"
  done
}

create_basic_dirs() {
  echo "选择基础目录创建方式："
  echo "1) 下载默认docker-compose.yml自动创建映射目录"
  echo "2) 手动输入docker-compose.yml URL下载并创建映射目录"
  msg choose_option
  read -r opt
  case "$opt" in
    1)
      mkdir -p "$COMPOSE_DIR"
      if curl -fsSL "$DEFAULT_COMPOSE_URL" -o "$COMPOSE_DIR/docker-compose.yml"; then
        log "docker-compose.yml 下载成功"
        create_volume_dirs_from_compose
      else
        msg download_fail
      fi
      ;;
    2)
      echo "请输入docker-compose.yml文件URL："
      read -r url
      mkdir -p "$COMPOSE_DIR"
      if curl -fsSL "$url" -o "$COMPOSE_DIR/docker-compose.yml"; then
        log "docker-compose.yml 下载成功"
        create_volume_dirs_from_compose
      else
        msg download_fail
      fi
      ;;
    *)
      msg invalid_option
      ;;
  esac
}

create_media_dirs() {
  local base="$BASE_DIR/movies"
  mkdir -p "$base"/{movies,tvshows,av,downloads}
  log "已创建媒体目录：$base/{movies,tvshows,av,downloads}"
}

directory_menu() {
  while true; do
    echo -e "\n=== 目录管理 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 创建基础目录结构\n2) 创建常用媒体目录\n3) 查看现有目录结构\n4) 下载Dashy配置文件\nb) 返回主菜单" \
                             || echo "1) Create basic dirs\n2) Create media dirs\n3) View directory structure\n4) Download Dashy config\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1) create_basic_dirs ;;
      2) create_media_dirs ;;
      3) 
        if command -v tree &>/dev/null; then
          tree -L 3 "$BASE_DIR" || ls -R "$BASE_DIR"
        else
          ls -R "$BASE_DIR"
        fi
        ;;
      4)
        mkdir -p "$DASHY_CONFIG_DIR"
        if curl -fsSL "$DASHY_CONF_DEFAULT_URL" -o "$DASHY_CONFIG_DIR/conf.yml"; then
          log "Dashy配置文件下载成功并重命名为conf.yml"
        else
          msg download_fail
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ---------------------- Docker安装及管理 -----------------------
install_docker() {
  if command -v docker &>/dev/null && command -v docker-compose &>/dev/null; then
    msg docker_installed
    return
  fi

  # 先安装curl依赖
  install_dep curl || error "安装curl失败"

  log "开始安装Docker..."
  if ! curl -fsSL https://get.docker.com | sh; then
    error "Docker安装脚本执行失败"
    return 1
  fi
  if ! apt-get install -y docker-compose-plugin; then
    error "安装docker-compose-plugin失败"
    return 1
  fi

  # 添加当前非root用户到docker组
  local user=${SUDO_USER:-$USER}
  if [[ -n "$user" && "$user" != "root" ]]; then
    if ! usermod -aG docker "$user"; then
      warn "添加用户 $user 到docker组失败"
    fi
  fi

  log "Docker安装完成，请重启系统后重新运行脚本"
  exit 0
}

deploy_containers() {
  if ! command -v docker &>/dev/null || ! command -v docker-compose &>/dev/null; then
    error "未检测到docker或docker-compose，请先安装Docker (菜单6)"
    return
  fi

  mkdir -p "$COMPOSE_DIR"
  local url
  while true; do
    echo -e "\n1) 使用默认 compose 文件\n2) 手动输入 compose URL\n3) 返回"
    read -rp "请选择操作: " ch
    case "$ch" in
      1) url="$DEFAULT_COMPOSE_URL"; break ;;
      2) echo "请输入docker-compose.yml文件URL:"; read -r url; break ;;
      3) return ;;
      *) msg invalid_option ;;
    esac
  done

  if [[ "$url" =~ github\.com/.*/blob/ ]]; then
    url="${url/\/blob\//\/raw\/}"
    log "转换为Raw URL: $url"
  fi

  log "下载docker-compose.yml"
  if ! curl -fsSL "$url" -o "$COMPOSE_DIR/docker-compose.yml"; then
    msg download_fail
    return
  fi

  # 创建宿主映射卷目录
  create_volume_dirs_from_compose

  # 部署容器
  (cd "$COMPOSE_DIR" && docker compose up -d) && log "容器部署完成" || error "容器部署失败"
}

# ---------------------- Docker一键运维 -----------------------
docker_one_click() {
  while true; do
    echo -e "\n=== Docker一键运维 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 查看所有容器状态\n2) 单个容器操作(启动|停止|重启)\n3) 重启所有运行中容器\n4) 停止所有运行中容器\n5) 清理无用镜像和容器\nb) 返回" \
                             || echo "1) Show all containers\n2) Single container action (start|stop|restart)\n3) Restart all running\n4) Stop all running\n5) Clean unused images\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1) docker ps -a || warn "docker命令失败" ;;
      2)
        echo "请输入容器名或ID："
        read -r cid
        echo "请输入动作: start(启动)/stop(停止)/restart(重启)"
        read -r action
        if ! [[ "$action" =~ ^(start|stop|restart)$ ]]; then msg invalid_option; continue; fi
        msg confirm_action; read -r c
        if [[ "$c" == "yes" ]]; then
          docker "$action" "$cid" && log "操作成功" || warn "操作失败"
        else
          msg action_cancel
        fi
        ;;
      3)
        msg confirm_action; read -r c
        if [[ "$c" == "yes" ]]; then
          docker ps -q | xargs -r docker restart && log "所有运行容器重启完成" || warn "重启失败"
        else msg action_cancel; fi
        ;;
      4)
        msg confirm_action; read -r c
        if [[ "$c" == "yes" ]]; then
          docker ps -q | xargs -r docker stop && log "所有运行容器停止完成" || warn "停止失败"
        else msg action_cancel; fi
        ;;
      5)
        msg confirm_action; read -r c
        if [[ "$c" == "yes" ]]; then
          docker system prune -a -f --volumes && log "无用镜像及容器清理完成" || warn "清理失败"
        else msg action_cancel; fi
        ;;
      b|B) break ;;
      *) msg invalid_option ;;
    esac
  done
}

docker_log_cleanup() {
  while true; do
    echo -e "\n=== 容器日志清理 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 立即清理所有容器日志\n2) 设置定时清理日志(天)\nb) 返回" || echo "1) Immediate clean all container logs\n2) Schedule cleaning (days)\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        msg cleaning_logs_now
        for logf in /var/lib/docker/containers/*/*.log; do : > "$logf" || warn "无法清理 $logf"; done
        msg cleaning_logs_done
        ;;
      2)
        echo "请输入定时清理间隔天数（整数）:"
        read -r days
        if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
          msg invalid_input
          continue
        fi
        local script_path="/root/cron_docker_log_cleanup.sh"
        cat >"$script_path" <<-EOF
		  #!/bin/bash
		  for logf in /var/lib/docker/containers/*/*.log; do : > "\$logf"; done
EOF
        chmod +x "$script_path"
        (crontab -l 2>/dev/null | grep -v "$script_path"; echo "0 3 */$days * * $script_path") | crontab -
        log "已设置每${days}天凌晨3点自动清理docker日志"
        ;;
      b|B) break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ---------------------- 系统管理 -----------------------
system_log_cleanup() {
  while true; do
    echo -e "\n=== 系统日志清理 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 立即清理所有日志\n2) 设置定时清理日志(天)\nb) 返回" || echo "1) Immediate clean all system logs\n2) Schedule cleaning (days)\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        msg cleaning_logs_now
        find /var/log -type f \( -name "*.log" -o -name "*.old" -o -name "*.gz" \) -delete
        msg cleaning_logs_done
        ;;
      2)
        echo "请输入定时清理间隔天数（整数）:"
        read -r days
        if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
          msg invalid_input
          continue
        fi
        local script_path="/root/cron_system_log_cleanup.sh"
        cat >"$script_path" <<-EOF
		  #!/bin/bash
		  find /var/log -type f \( -name "*.log" -o -name "*.old" -o -name "*.gz" \) -delete
EOF
        chmod +x "$script_path"
        (crontab -l 2>/dev/null | grep -v "$script_path"; echo "0 4 */$days * * $script_path") | crontab -
        log "已设置每${days}天凌晨4点自动清理系统日志"
        ;;
      b|B) break ;;
      *) msg invalid_option ;;
    esac
  done
}

system_menu() {
  while true; do
    echo -e "\n=== 系统管理 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 系统更新&升级\n2) 日志清理\nb) 返回主菜单" || echo "1) Update & Upgrade\n2) Log Cleanup\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        apt-get update && apt-get upgrade -y && log "系统更新升级完成" || warn "系统升级失败"
        ;;
      2) system_log_cleanup ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ---------------------- 语言切换 -----------------------
language_menu() {
  echo -e "\n=== 语言选择 / Language Selection ==="
  echo "1) 中文"
  echo "2) English"
  msg choose_option
  read -r opt
  case "$opt" in
    1) LANGUAGE="zh"; log "语言已切换为中文" ;;
    2) LANGUAGE="en"; log "Language switched to English" ;;
    *) msg invalid_option ;;
  esac
}

# ---------------------- SSH管理 -----------------------
ssh_menu() {
  while true; do
    echo -e "\n=== SSH管理 ==="
    [[ $LANGUAGE == "zh" ]] && echo "1) 查看SSH状态\n2) 安装并启用SSH服务\n3) 配置SSH允许root登录\nb) 返回主菜单" \
                             || echo "1) Show SSH status\n2) Install and enable SSH\n3) Configure root login\nb) Back"
    msg choose_option
    read -r opt
    case "$opt" in
      1)
        if systemctl is-active --quiet ssh; then
          log "SSH服务运行中"
        else
          warn "SSH服务未运行"
        fi
        ;;
      2)
        if command -v sshd &>/dev/null || command -v ssh &>/dev/null; then
          log "检测到SSH已安装"
        else
          log "安装openssh-server..."
          apt-get update
          apt-get install -y openssh-server
        fi
        systemctl enable ssh
        systemctl start ssh
        log "SSH服务启动完成"
        ;;
      3)
        SSHD_CONF="/etc/ssh/sshd_config"
        if grep -Eq "^PermitRootLogin yes" "$SSHD_CONF"; then
          log "SSH已允许root登录"
        else
          sed -i.bak '/^PermitRootLogin/s/.*/PermitRootLogin yes/' "$SSHD_CONF" || echo "PermitRootLogin yes" >> "$SSHD_CONF"
          systemctl reload ssh
          log "配置允许root登录，SSH重载完成"
        fi
        ;;
      b|B) msg back_main; break ;;
      *) msg invalid_option ;;
    esac
  done
}

# ---------------------- 脚本升级 -----------------------
script_upgrade() {
  echo "自动升级脚本..."
  local url="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/n100-aio-init-GPT4.1.sh"
  local tmpfile="/tmp/n100-aio-init-upgrade.sh"
  if curl -fsSL "$url" -o "$tmpfile"; then
    chmod +x "$tmpfile"
    mv "$tmpfile" "$(realpath "$0")"
    log "升级成功，请重新运行脚本。"
    exit 0
  else
    msg download_fail
  fi
}

# ---------------------- 主菜单 -----------------------
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
    read -r ch
    case "$ch" in
      1) ssh_menu ;;
      2) firewall_menu ;;
      3) network_menu ;;
      4) disk_menu ;;
      5) directory_menu ;;
      6) 
         echo "1) 安装Docker及docker-compose"
         echo "2) 部署容器"
         echo "3) Docker一键运维"
         echo "4) 容器日志清理"
         echo "b) 返回主菜单"
         msg choose_option
         read -r opt
         case "$opt" in
           1) install_docker ;;
           2) deploy_containers ;;
           3) docker_one_click ;;
           4) docker_log_cleanup ;;
           b|B) continue ;;
           *) msg invalid_option ;;
         esac
         ;;
      7) system_menu ;;
      8) script_upgrade ;;
      9) language_menu ;;
      q|Q) log "退出脚本，再见！"; exit 0 ;;
      *) msg invalid_option ;;
    esac
  done
}

main_menu
