#!/usr/bin/env bash
# ---------------------------------------------------------------------------- #
# N100 All-in-One 交互式初始化脚本 v0.15 优化版
# 优化点：恢复磁盘信息显示、日志轮转增加自动清理设置、增强系统信息展示
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
  环境检测 (自动)
  网络检测与配置
  SSH 管理 (状态查看与配置)
  磁盘分区 & 挂载
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

# 全局变量
BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/norman110/N100/refs/heads/main/docker-compose.yml"
# 日志保留天数默认值
DEFAULT_LOG_DAYS=7

# 环境检测与系统信息展示
env_check(){
  # 基础系统信息
  . /etc/os-release
  log "操作系统: $PRETTY_NAME"
  log "内核版本: $(uname -r)"
  
  # CPU信息
  local cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed -e 's/^ *//')
  local cpu_cores=$(grep -c '^processor' /proc/cpuinfo)
  log "CPU: $cpu_model ($cpu_cores 核心)"
  
  # 内存信息
  mem_total=$(free -h | awk '/^Mem:/ {print $2}')
  mem_available=$(free -h | awk '/^Mem:/ {print $7}')
  log "内存总量: $mem_total (可用: $mem_available)"
  
  # 磁盘信息（增强显示）
  log "磁盘信息 ($BASE_DIR):"
  # 获取磁盘统计信息
  disk_stats=$(df -h "$BASE_DIR" 2>/dev/null || df -h /)
  disk_total=$(echo "$disk_stats" | awk 'NR==2 {print $2}')
  disk_used=$(echo "$disk_stats" | awk 'NR==2 {print $3}')
  disk_available=$(echo "$disk_stats" | awk 'NR==2 {print $4}')
  disk_usage=$(echo "$disk_stats" | awk 'NR==2 {print $5}')
  
  log "  总容量: $disk_total"
  log "  已用空间: $disk_used ($disk_usage)"
  log "  可用空间: $disk_available"
  
  # 检查磁盘空间是否充足
  avail_kb=$(df --output=avail "$BASE_DIR" 2>/dev/null | tail -1 || df --output=avail / | tail -1)
  (( avail_kb < 5*1024*1024 )) && error "磁盘可用空间不足5GB" && exit 1
  
  # 主机信息
  log "主机名: $(hostname)"
  log "当前时间: $(date "+%Y-%m-%d %H:%M:%S")"
  
  log "系统信息检测完成"
}
env_check

# 创建基础目录结构（仅保留必要目录）
log "创建基础目录结构"
mkdir -p "$BASE_DIR" "$COMPOSE_DIR" "$BASE_DIR/media"

# 检测IP
detect_ip(){
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  log "本机IP: $IP_ADDR"
}
detect_ip

read -e -rp "请输入泛域名 (如 *.example.com): " WILDCARD_DOMAIN
log "使用域名: $WILDCARD_DOMAIN"

# 网络检测与配置
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

network_config(){
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
        
        cat >"/etc/network/interfaces.d/$iface.cfg" <<EOF
auto $iface
iface $iface inet dhcp
EOF
        systemctl restart networking && log "DHCP 配置应用完成"
        ;;
      2)
        iface=$(ip -o link show | awk -F': ' '/state UP/ {print $2}' | head -1)
        [[ -z "$iface" ]] && { warn "无可用接口"; continue; }
        
        read -e -rp "静态IP (如 192.168.1.100/24): " sip
        if ! echo "$sip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
          warn "IP格式错误（示例：192.168.1.100/24）"; continue
        fi
        
        read -e -rp "网关 (如 192.168.1.1): " gtw
        if ! echo "$gtw" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
          warn "网关格式错误"; continue
        fi
        
        cat >"/etc/network/interfaces.d/$iface.cfg" <<EOF
auto $iface
iface $iface inet static
  address $sip
  gateway $gtw
EOF
        systemctl restart networking && log "静态IP 配置应用完成"
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

# SSH 管理（合并状态查看与配置）
ssh_menu(){
  while true; do
    echo -e "\n====== SSH 管理 ======"
    echo "1) 查看SSH状态与配置"
    echo "2) 安装并启用SSH服务"
    echo "3) 配置SSH允许root登录"
    echo "4) 返回主菜单"
    read -e -rp "选择: " sopt
    
    case "$sopt" in
      1)
        check_ssh_status
        ;;
      2)
        install_ssh
        ;;
      3)
        configure_root_ssh
        ;;
      4)
        return
        ;;
      *)
        warn "无效选项，请重试"
        ;;
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

# 磁盘分区 & 挂载
partition_disk(){
  if ! command -v parted &>/dev/null; then
    log "安装 parted..."
    apt-get update && apt-get install -y parted
  fi
  
  while true; do
    echo -e "\n可用磁盘列表："
    lsblk -dn -o NAME,SIZE | nl
    
    read -e -rp "请输入要操作的磁盘编号 (或 q 返回): " idx
    [[ "$idx" == "q" ]] && return
    
    dev=$(lsblk -dn -o NAME | sed -n "${idx}p")
    [[ -z "$dev" ]] && { warn "无效编号"; continue; }
    
    read -e -rp "确认要对 /dev/$dev 进行分区? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { warn "操作取消"; return; }
    
    # 分区并格式化
    log "正在分区 /dev/$dev..."
    parted /dev/"$dev" --script mklabel gpt mkpart primary ext4 1MiB 100%
    mkfs.ext4 /dev/"${dev}"1
    
    # 挂载点设置
    read -e -rp "请输入挂载点 (例如 /mnt/data): " mnt
    [[ -z "$mnt" ]] && { warn "挂载点不能为空"; continue; }
    
    mkdir -p "$mnt" && mount /dev/"${dev}"1 "$mnt"
    
    # 写入fstab实现持久化
    uuid=$(blkid -s UUID -o value /dev/"${dev}"1)
    echo "UUID=$uuid $mnt ext4 defaults 0 2" >> /etc/fstab
    
    log "挂载完成（重启后自动生效）: /dev/${dev}1 -> $mnt"
    return
  done
}

# Docker 安装
install_docker(){
  if ! command -v curl &>/dev/null; then
    log "安装 curl..."
    apt-get update && apt-get install -y curl
  fi
  
  if ! command -v docker &>/dev/null; then
    log "正在安装Docker..."
    curl -fsSL https://get.docker.com | sh
    apt-get install -y docker-compose-plugin
    
    # 添加用户到docker组
    local user=${SUDO_USER:-$USER}
    [[ -n "$user" ]] && usermod -aG docker "$user"
    
    log "Docker 安装完成，请重启系统后重新运行脚本"
    exit 0
  else
    log "Docker 已安装"
  fi
}

# 部署容器
deploy_containers(){
  if ! command -v curl &>/dev/null; then
    log "安装 curl..."
    apt-get update && apt-get install -y curl
  fi
  
  # 检查docker-compose是否可用
  if ! command -v docker compose &>/dev/null; then
    error "未检测到 docker-compose-plugin，请先执行 5) 安装 Docker"
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
      1) 网站="$DEFAULT_COMPOSE_URL"; break ;;
      2) read -e -rp "请输入 compose 文件 URL: " URL; break ;;
      3) return ;;
      *) warn "无效选项，请重试" ;;
    esac
  done
  
  # GitHub URL转换
  if [[ "$URL" =~ github\.com/.*/blob/.* ]]; then
    网站="${URL/\/blob\//\/raw\/}"
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

# Docker 一键运维
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

# 系统更新
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

# 日志轮转（增加自动清理设置）
log_rotate(){
  local log_days
  
  while true; do
    echo -e "\n====== 日志清理设置 ======"
    read -e -rp "请输入日志保留天数 (1-7天，默认7天): " log_days
    
    # 处理用户输入，使用默认值如果为空
    log_days=${log_days:-$DEFAULT_LOG_DAYS}
    
    # 验证输入是否为1-7之间的数字
    if [[ "$log_days" =~ ^[1-7]$ ]]; then
      break
    else
      warn "无效输入，请输入1到7之间的数字"
    fi
  done
  
  log "正在清理${log_days}天前的容器日志..."
  for c in $(docker ps -a --format '{{.Names}}'); do
    f="/var/log/${c}.log"
    # 保存当前日志
    docker logs "$c" &> "$f"
    # 删除指定天数前的日志
    find "$f" -mtime +"$log_days" -delete
  done
  
  log "日志清理完成，已保留最近${log_days}天的日志"
}

# 主菜单
while true; do
  echo -e "\n====== N100 AIO 初始化 v0.15 ======"
  echo "1) 网络管理"
  echo "2) SSH 管理"
  echo "3) 磁盘分区 & 挂载"
  echo "4) 安装 Docker"
  echo "5) 部署容器"
  echo "6) Docker 一键运维"
  echo "7) 系统更新与升级"
  echo "8) 日志轮转与清理（可设置自动清理时间）"
  echo "9) 显示帮助信息"
  echo "q) 退出脚本"
  read -e -rp "请选择操作 [1-9/q]: " ch
  
  case "$ch" in
    1) network_menu ;;
    2) ssh_menu ;;
    3) partition_disk ;;
    4) install_docker ;;
    5) deploy_containers ;;
    6) docker_one_click ;;
    7) update_system ;;
    8) log_rotate ;;
    9) display_help ;;
    q) log "退出脚本"; break ;;
    *) warn "无效选项，请输入1-9或q" ;;
  esac
done

log "脚本执行完毕"
    
