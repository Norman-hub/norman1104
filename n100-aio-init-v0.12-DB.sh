#!/usr/bin/env bash
# ---------------------------------------------------------------------------- #
# N100 All-in-One 交互式初始化脚本 v0.19 优化版
# 优化点：解决RTNETLINK配置冲突错误，修复子网掩码计算，增强接口状态处理
# ---------------------------------------------------------------------------- #

set -euo pipefail
IFS=$'\n\t'

# 恢复终端输入功能
stty sane

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 帮助信息
display_help(){
  cat <<EOF
使用方法: $0 [选项]
选项:
  -h        显示帮助信息
功能:
  环境检测
  网络检测与配置
  SSH 管理 (状态查看与配置)
  磁盘分区 & 挂载
  目录结构创建与管理
  安装 Docker
  部署容器
  Docker 一键运维
  系统更新与升级
  日志轮转与清理（可设置自动清理时间）
EOF
}

# 根权限检测
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 或 sudo 运行此脚本"
  exit 1
fi
[[ "${1:-}" == "-h" ]] && display_help && exit 0

# 全局变量 - 默认挂载点为/mnt/data
BASE_DIR="/mnt/data"
COMPOSE_DIR="$BASE_DIR/docker/compose"
MOUNTS=(/mnt/data1 /mnt/data2 /mnt/data3)
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
DEFAULT_LOG_DAYS=7

# 常用媒体目录定义
MEDIA_DIRS=(
  "movies" "tvshows" "documentary" "anime" 
  "music" "downloads" "photos" "other"
)

# 环境检测与系统信息展示
env_check(){
  . /etc/os-release
  log "操作系统: $PRETTY_NAME"
  log "内核版本: $(uname -r)"
  
  local cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed -e 's/^ *//')
  local cpu_cores=$(grep -c '^processor' /proc/cpuinfo)
  log "CPU: $cpu_model ($cpu_cores 核心)"
  
  mem_total=$(free -h | awk '/^Mem:/ {print $2}')
  mem_available=$(free -h | awk '/^Mem:/ {print $7}')
  log "内存总量: $mem_total (可用: $mem_available)"
  
  # 系统磁盘信息（根目录）
  log "系统磁盘信息 (/) :"
  root_disk_stats=$(df -h /)
  root_total=$(echo "$root_disk_stats" | awk 'NR==2 {print $2}')
  root_used=$(echo "$root_disk_stats" | awk 'NR==2 {print $3}')
  root_available=$(echo "$root_disk_stats" | awk 'NR==2 {print $4}')
  root_usage=$(echo "$root_disk_stats" | awk 'NR==2 {print $5}')
  
  log "  总容量: $root_total"
  log "  已用空间: $root_used ($root_usage)"
  log "  可用空间: $root_available"
  
  # 所有可用磁盘列表（排除loop设备）
  log "\n所有可用磁盘（包括未分区/未挂载）:"
  lsblk -e 7,128,252,253 -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v '^loop'
  
  # 检查是否已挂载BASE_DIR
  if [[ -d "$BASE_DIR" && "$(mount | grep "$BASE_DIR")" ]]; then
    log "\n已挂载存储信息 ($BASE_DIR) :"
    mount_disk_stats=$(df -h "$BASE_DIR")
    mount_total=$(echo "$mount_disk_stats" | awk 'NR==2 {print $2}')
    mount_used=$(echo "$mount_disk_stats" | awk 'NR==2 {print $3}')
    mount_available=$(echo "$mount_disk_stats" | awk 'NR==2 {print $4}')
    mount_usage=$(echo "$mount_disk_stats" | awk 'NR==2 {print $5}')
    
    log "  总容量: $mount_total"
    log "  已用空间: $mount_used ($mount_usage)"
    log "  可用空间: $mount_available"
  else
    warn "\n未检测到已挂载的存储设备（$BASE_DIR 不存在或未挂载）"
    warn "请通过 4) 磁盘分区 & 挂载 选项配置存储设备"
  fi
  
  # 磁盘空间检查
  root_avail_kb=$(df --output=avail / | tail -1)
  (( root_avail_kb < 5*1024*1024 )) && error "系统磁盘可用空间不足5GB" && exit 1
  
  log "\n主机名: $(hostname)"
  log "当前时间: $(date "+%Y-%m-%d %H:%M:%S")"
  log "系统信息检测完成"
}

# 目录结构管理函数（保持不变）
manage_directories(){
  while true; do
    echo -e "\n====== 目录结构管理 ======"
    echo "1) 创建基础目录结构 (Docker相关)"
    echo "2) 创建常用媒体目录"
    echo "3) 查看现有目录结构"
    echo "4) 返回主菜单"
    read -e -rp "选择: " dir_opt
    
    case "$dir_opt" in
      1) create_base_directories ;;
      2) create_media_directories ;;
      3) view_directories ;;
      4) return ;;
      *) warn "无效选项，请重试" ;;
    esac
  done
}

create_base_directories(){
  if [[ ! -d "$BASE_DIR" ]]; then
    warn "未检测到基础存储目录 $BASE_DIR，请先分区并挂载存储设备"
    return 1
  fi
  
  log "创建基础目录结构..."
  mkdir -p \
    "$BASE_DIR" \
    "$COMPOSE_DIR" \
    "$BASE_DIR/docker/configs" \
    "$BASE_DIR/docker/data" \
    "$BASE_DIR/media"
  
  log "基础目录结构创建完成:"
  ls -ld "$BASE_DIR" "$COMPOSE_DIR" "$BASE_DIR/media"
}

create_media_directories(){
  if [[ ! -d "$BASE_DIR" ]]; then
    warn "未检测到基础存储目录 $BASE_DIR，请先分区并挂载存储设备"
    return 1
  fi
  
  if [[ ! -d "$BASE_DIR/media" ]]; then
    warn "未检测到基础媒体目录，先创建基础目录结构"
    create_base_directories || return 1
  fi
  
  log "创建常用媒体目录..."
  for dir in "${MEDIA_DIRS[@]}"; do
    mkdir -p "$BASE_DIR/media/$dir"
    echo "创建: $BASE_DIR/media/$dir"
  done
  
  log "常用媒体目录创建完成"
}

view_directories(){
  if [[ ! -d "$BASE_DIR" ]]; then
    warn "未检测到基础存储目录 $BASE_DIR，请先分区并挂载存储设备"
    return 1
  fi
  
  log "当前目录结构 ($BASE_DIR):"
  tree -L 3 "$BASE_DIR" || ls -lR "$BASE_DIR" | head -n 50
}

# 检测IP
detect_ip(){
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  log "本机IP: $IP_ADDR"
}

# 网络检测与配置（核心修复部分）
network_menu(){
  while true; do
    echo -e "\n====== 网络管理 ======"
    echo "1) 查看网络状态"
    echo "2) 配置网络 (DHCP/静态IP)"
    echo "3) 返回主菜单"
    read -e -rp "选择: " nopt
    
    case "$nopt" in
      1)
        log "网络接口 & IP:"
        ip -brief addr show
        log "路由表:"
        ip route show
        log "DNS 配置:"
        cat /etc/resolv.conf | grep 'nameserver' || echo "未配置DNS"
        ;;
      2)
        network_config
        ;;
      3)
        return
        ;;
      *)
        warn "无效选项，请重试"
        ;;
    esac
  done
}

# 计算子网掩码（修复核心错误）
calculate_netmask() {
  local cidr=$1
  # CIDR前缀转子网掩码（如24 → 255.255.255.0）
  local netmask=""
  for ((i=0; i<4; i++)); do
    if (( cidr >= 8 )); then
      netmask+="255."
      ((cidr -= 8))
    else
      local bits=$(( 8 - cidr ))
      local mask=$(( 256 - (1 << bits) ))
      netmask+="${mask}."
      cidr=0
    fi
  done
  # 移除末尾的点
  echo "${netmask%.*}"
}

network_config(){
  # 检查并处理NetworkManager冲突
  if systemctl is-active --quiet NetworkManager; then
    warn "检测到NetworkManager正在运行，这会导致网络配置冲突"
    read -e -rp "是否停止并禁用NetworkManager? [y/N]: " stop_nm
    if [[ "$stop_nm" =~ ^[Yy]$ ]]; then
      systemctl stop NetworkManager
      systemctl disable NetworkManager
      log "NetworkManager已停止并禁用"
    else
      warn "继续操作可能导致网络配置失败"
      read -e -rp "是否继续? [y/N]: " cont
      [[ ! "$cont" =~ ^[Yy]$ ]] && return
    fi
  fi

  while true; do
    echo -e "\n网络配置选项："
    echo "1) DHCP (动态IP)"
    echo "2) 静态IP"
    echo "3) 返回上一级"
    read -e -rp "选择: " opt
    
    case "$opt" in
      1)
        iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
        [[ -z "$iface" ]] && { warn "无可用接口"; continue; }
        
        log "应用DHCP配置到接口 $iface..."
        # 先清理现有配置
        ifdown "$iface" || true
        
        # 生成DHCP配置（包含DNS）
        cat >"/etc/network/interfaces.d/$iface.cfg" <<EOF
auto $iface
iface $iface inet dhcp
dns-nameservers 8.8.8.8 114.114.114.114
EOF
        
        # 分步启动接口（解决RTNETLINK错误）
        if ifup "$iface"; then
          log "DHCP 配置应用完成"
          log "新IP地址:"
          ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+'
        else
          error "接口启动失败"
          error "请查看配置文件: /etc/network/interfaces.d/$iface.cfg"
          error "尝试手动修复: ifdown $iface && ifup $iface"
        fi
        ;;
      2)
        iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
        [[ -z "$iface" ]] && { warn "无可用接口"; continue; }
        
        read -e -rp "静态IP (如 192.168.1.100/24): " sip
        if ! echo "$sip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
          warn "IP格式错误（示例：192.168.1.100/24）"; continue
        fi
        
        # 提取IP和CIDR前缀
        ip_addr=$(echo "$sip" | cut -d'/' -f1)
        cidr=$(echo "$sip" | cut -d'/' -f2)
        # 计算子网掩码（修复之前的错误计算）
        netmask=$(calculate_netmask "$cidr")
        
        read -e -rp "网关 (如 192.168.1.1): " gtw
        if ! echo "$gtw" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
          warn "网关格式错误"; continue
        fi

        read -e -rp "DNS服务器 (多个用空格分隔，默认: 8.8.8.8 114.114.114.114): " dns
        dns=${dns:-"8.8.8.8 114.114.114.114"}
        
        log "应用静态IP配置到接口 $iface..."
        # 先清理现有配置（解决冲突核心步骤）
        ifdown "$iface" || true
        # 清除可能的残留路由
        ip route flush dev "$iface" || true
        
        # 生成静态IP配置
        cat >"/etc/network/interfaces.d/$iface.cfg" <<EOF
auto $iface
iface $iface inet static
  address $ip_addr
  netmask $netmask
  gateway $gtw
  dns-nameservers $dns
EOF
        
        # 分步启动接口（避免直接重启服务导致的冲突）
        if ifup "$iface"; then
          log "静态IP 配置应用完成"
          log "配置信息:"
          grep -v '^#' "/etc/network/interfaces.d/$iface.cfg"
          log "当前IP地址:"
          ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+'
        else
          error "接口启动失败"
          error "请查看配置文件: /etc/network/interfaces.d/$iface.cfg"
          error "尝试手动修复: ifdown $iface && ifup $iface"
        fi
        ;;
      3)
        return
        ;;
      *)
        warn "无效选项，请重试"
        ;;
    esac
  done
}

# SSH 管理（保持不变）
ssh_menu(){
  while true; do
    echo -e "\n====== SSH 管理 ======"
    echo "1) 查看SSH状态与配置"
    echo "2) 安装并启用SSH服务"
    echo "3) 配置SSH允许root登录"
    echo "4) 返回主菜单"
    read -e -rp "选择: " sopt
    
    case "$sopt" in
      1) check_ssh_status ;;
      2) install_ssh ;;
      3) configure_root_ssh ;;
      4) return ;;
      *) warn "无效选项，请重试" ;;
    esac
  done
}

check_ssh_status(){
  if systemctl is-active --quiet ssh; then
    log "SSH 服务正在运行"
  else
    warn "SSH 服务未运行"
  fi
  
  cfg=/etc/ssh/sshd_config
  if [[ -f "$cfg" ]]; then
    port=$(grep -E '^Port ' "$cfg" | awk '{print $2}'); port=${port:-22}
    pr=$(grep -E '^PermitRootLogin ' "$cfg" | awk '{print $2}'); pr=${pr:-no}
    pa=$(grep -E '^PasswordAuthentication ' "$cfg" | awk '{print $2}'); pa=${pa:-yes}
    echo "当前配置: 端口=$port, 允许root登录=$pr, 密码认证=$pa"
  fi
  
  if command -v ufw &>/dev/null; then
    ufw status | grep -q '22/tcp' && echo "防火墙: SSH端口已开放" || echo "防火墙: SSH端口未开放"
  elif command -v iptables &>/dev/null; then
    iptables -L | grep -q 'dpt:22' && echo "防火墙: SSH已允许" || echo "防火墙: SSH未允许"
  fi
}

install_ssh(){
  if ! command -v sshd &>/dev/null; then
    log "正在安装SSH服务..."
    apt-get update && apt-get install -y openssh-server
    systemctl enable --now ssh
    log "SSH服务安装并启动完成"
  else
    log "SSH服务已安装"
    systemctl start ssh && log "SSH服务已启动"
  fi
}

configure_root_ssh(){
  if ! command -v sshd &>/dev/null; then
    warn "请先安装SSH服务（选项2）"
    return 1
  fi
  
  log "配置SSH允许root登录..."
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
  
  systemctl restart ssh
  log "SSH配置已更新：允许root密码登录"
}

# 磁盘分区 & 挂载（保持不变）
partition_disk(){
  if ! command -v parted &>/dev/null; then
    log "安装 parted..."
    apt-get update && apt-get install -y parted
  fi
  
  while true; do
    echo -e "\n可用磁盘列表："
    lsblk -e 7,128,252,253 -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v '^loop' | nl
    
    read -e -rp "请输入要操作的磁盘编号 (或 q 返回): " idx
    [[ "$idx" == "q" ]] && return
    
    dev=$(lsblk -e 7,128,252,253 -no NAME | grep -v '^loop' | sed -n "${idx}p")
    [[ -z "$dev" ]] && { warn "无效编号"; continue; }
    
    mountpoint=$(lsblk -no MOUNTPOINT "/dev/$dev")
    if [[ -n "$mountpoint" ]]; then
      warn "警告：/dev/$dev 已挂载到 $mountpoint，操作将导致数据丢失！"
      read -e -rp "是否继续? [y/N]: " force_confirm
      [[ ! "$force_confirm" =~ ^[Yy]$ ]] && { warn "操作取消"; continue; }
    fi
    
    read -e -rp "确认要对 /dev/$dev 进行分区? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { warn "操作取消"; return; }
    
    log "正在分区 /dev/$dev..."
    parted /dev/"$dev" --script mklabel gpt mkpart primary ext4 1MiB 100%
    mkfs.ext4 /dev/"${dev}"1
    
    read -e -rp "请输入挂载点 (默认: $BASE_DIR): " mnt
    mnt=${mnt:-$BASE_DIR}
    
    mkdir -p "$mnt" && mount /dev/"${dev}"1 "$mnt"
    
    uuid=$(blkid -s UUID -o value /dev/"${dev}"1)
    echo "UUID=$uuid $mnt ext4 defaults 0 2" >> /etc/fstab
    
    log "挂载完成（重启后自动生效）: /dev/${dev}1 -> $mnt"
    return
  done
}

# Docker 安装与部署（保持不变）
install_docker(){
  if ! command -v curl &>/dev/null; then
    log "安装 curl..."
    apt-get update && apt-get install -y curl
  fi
  
  if ! command -v docker &>/dev/null; then
    log "正在安装Docker..."
    curl -fsSL https://get.docker.com | sh
    apt-get install -y docker-compose-plugin
    
    local user=${SUDO_USER:-$USER}
    [[ -n "$user" ]] && usermod -aG docker "$user"
    
    log "Docker 安装完成，请重启系统后重新运行脚本"
    exit 0
  else
    log "Docker 已安装"
  fi
}

deploy_containers(){
  if [[ ! -d "$BASE_DIR" || ! "$(mount | grep "$BASE_DIR")" ]]; then
    error "未检测到已挂载的存储设备，请先通过 4) 磁盘分区 & 挂载 配置存储"
    return 1
  fi
  
  if ! command -v curl &>/dev/null; then
    log "安装 curl..."
    apt-get update && apt-get install -y curl
  fi
  
  if ! command -v docker compose &>/dev/null; then
    error "未检测到 docker-compose-plugin，请先执行 6) 安装 Docker"
    return 1
  fi
  
  local URL
  while true; do
    mkdir -p "$COMPOSE_DIR"
    echo -e "\n部署容器选项："
    echo "1) 使用默认 compose 文件"
    echo "2) 手动输入 compose 文件 URL"
    echo "3) 返回主菜单"
    read -e -rp "选择: " o
    
    case "$o" in
      1) URL="$DEFAULT_COMPOSE_URL"; break ;;
      2) read -e -rp "请输入 compose 文件 URL: " URL; break ;;
      3) return ;;
      *) warn "无效选项，请重试" ;;
    esac
  done
  
  if [[ "$URL" =~ github\.com/.*/blob/.* ]]; then
    URL="${URL/\/blob\//\/raw\/}"
    log "已转换为 Raw URL: $URL"
  fi
  
  log "正在下载 compose 文件: $URL"
  if ! curl -fsSL "$URL" -o "$COMPOSE_DIR/docker-compose.yml"; then
    error "下载失败，请检查URL是否正确"
    return 1
  fi
  
  log "开始部署容器..."
  cd "$COMPOSE_DIR" && docker compose up -d
  log "容器部署完成"
}

# Docker 一键运维（保持不变）
docker_one_click(){
  while true; do
    echo -e "\n====== Docker 运维 ======"
    echo "1) 查看容器状态"
    echo "2) 重启所有运行中的容器"
    echo "3) 停止所有运行中的容器"
    echo "4) 清理无用镜像和容器"
    echo "5) 返回主菜单"
    read -e -rp "选择: " opt
    
    case "$opt" in
      1) docker ps -a ;;
      2) docker restart $(docker ps -q) ;;
      3) docker stop $(docker ps -q) ;;
      4) 
        log "正在清理无用资源..."
        docker system prune -a -f --volumes
        log "清理完成"
        ;;
      5) return ;;
      *) warn "无效选项，请重试" ;;
    esac
  done
}

# 系统更新与日志轮转（保持不变）
update_system(){
  . /etc/os-release
  VERSION_ID=${VERSION_ID%%.*}
  case "$VERSION_ID" in
    9) CODENAME="stretch" ;; 10) CODENAME="buster" ;; 11) CODENAME="bullseye" ;; 12) CODENAME="bookworm" ;; *) CODENAME="bookworm" ;;
  esac
  
  log "正在更新系统 ($CODENAME)..."
  sed -i "s|^deb .*|deb http://deb.debian.org/debian ${CODENAME} main contrib non-free|" /etc/apt/sources.list
  apt-get update && apt-get upgrade -y
  log "系统更新完毕"
}

log_rotate(){
  local log_days
  
  while true; do
    echo -e "\n====== 日志清理设置 ======"
    read -e -rp "请输入日志保留天数 (1-7天，默认7天): " log_days
    log_days=${log_days:-$DEFAULT_LOG_DAYS}
    
    if [[ "$log_days" =~ ^[1-7]$ ]]; then
      break
    else
      warn "无效输入，请输入1到7之间的数字"
    fi
  done
  
  log "正在清理${log_days}天前的容器日志..."
  for c in $(docker ps -a --format '{{.Names}}'); do
    f="/var/log/${c}.log"
    docker logs "$c" &> "$f"
    find "$f" -mtime +"$log_days" -delete
  done
  
  log "日志清理完成，已保留最近${log_days}天的日志"
}

# 主菜单
while true; do
  echo -e "\n====== N100 AIO 初始化 v0.19 ======"
  echo "1) 环境检测"
  echo "2) 网络管理"
  echo "3) SSH 管理"
  echo "4) 磁盘分区 & 挂载"
  echo "5) 目录结构创建与管理"
  echo "6) 安装 Docker"
  echo "7) 部署容器"
  echo "8) Docker 一键运维"
  echo "9) 系统更新与升级"
  echo "10) 日志轮转与清理（可设置自动清理时间）"
  echo "11) 显示帮助信息"
  echo "q) 退出脚本"
  read -e -rp "请选择操作 [1-11/q]: " ch
  
  case "$ch" in
    1) env_check ;;
    2) network_menu ;;
    3) ssh_menu ;;
    4) partition_disk ;;
    5) manage_directories ;;
    6) install_docker ;;
    7) deploy_containers ;;
    8) docker_one_click ;;
    9) update_system ;;
    10) log_rotate ;;
    11) display_help ;;
    q) log "退出脚本"; break ;;
    *) warn "无效选项，请输入1-11或q" ;;
  esac
done

log "脚本执行完毕"
    
