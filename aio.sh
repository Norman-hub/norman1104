#!/usr/bin/env bash
# ---------------------------------------------------------------------------- #
# N100 小主机 All-in-One 交互式初始化脚本 v6.0
# Interactive AIO Initialization Script for N100 Mini-PC v6.0
# ---------------------------------------------------------------------------- #

set -euo pipefail
IFS=$'\n\t'

# 颜色输出 / Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 检查root权限 / Check root
if [[ $EUID -ne 0 ]]; then
  error "请使用 root 或 sudo 运行此脚本 / Please run as root or sudo"
  exit 1
fi

# 自动探测本机IP / Auto detect local IP
IP_ADDR="$(hostname -I | awk '{print $1}')"
log "检测到本机IP: $IP_ADDR / Detected IP: $IP_ADDR"

# 用户输入泛域名 / Prompt for wildcard domain
read -rp "请输入泛域名 (例如 *.example.com): " WILDCARD_DOMAIN
log "使用泛域名: $WILDCARD_DOMAIN / Using domain: $WILDCARD_DOMAIN"

# 全局变量 / Globals
BASE_DIR="/mnt/usbdata"
COMPOSE_DIR="$BASE_DIR/docker/compose"
BACKUP_DIR=""

# 挂载点提示数组 / Available mounts
MOUNTS=(/mnt/usbdata1 /mnt/usbdata2 /mnt/usbdata3)

# ---------------------------------------------------------------------------- #
# 功能函数定义 / Functions
# ---------------------------------------------------------------------------- #

enable_ssh(){
  log "配置 SSH 访问 / Configuring SSH..."
  apt-get update
  apt-get install -y openssh-server
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl enable ssh
  systemctl restart ssh
  log "SSH 已开启，允许root及密码登录 / SSH enabled with root & password login"
}

partition_disk(){
  log "列出可用磁盘 / Listing available disks..."
  lsblk -dn -o NAME,SIZE | nl
  read -rp "请输入要分区的磁盘编号 (如1)，或输入 q 退出: " idx
  [[ "$idx" == "q" ]] && return
  dev=$(lsblk -dn -o NAME | sed -n "${idx}p")
  read -rp "确认在 /dev/$dev 上创建新分区? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    parted /dev/$dev --script mklabel gpt mkpart primary ext4 0% 100%
    mkfs.ext4 /dev/${dev}1
    read -rp "请输入挂载点路径 (如 /mnt/data): " mnt
    mkdir -p "$mnt"
    mount /dev/${dev}1 "$mnt"
    log "分区并挂载完成: /dev/${dev}1 -> $mnt"
  else
    warn "取消分区操作 / Partition cancelled"
  fi
}

install_docker(){
  if ! command -v docker &>/dev/null; then
    log "检测到 Docker 未安装，开始安装 / Installing Docker..."
    apt-get update
    curl -fsSL https://get.docker.com | sh
    apt-get install -y docker-compose-plugin
    usermod -aG docker "$SUDO_USER"
    log "Docker 安装完成，请重新登录后重跑脚本 / Docker installed. Re-login and rerun script."
    exit 0
  else
    log "Docker 已安装，跳过 / Docker already installed, skip."
  fi
}

deploy_containers(){
  log "生成目录结构 / Creating directories..."
  mkdir -p "$BASE_DIR"/docker/{compose,qbittorrent/config,dashy/config,filebrowser/config,bitwarden/data,emby/config,metatube/postgres,proxy/{data,letsencrypt}} \
           "$BASE_DIR"/media/{movies,tvshows,av,downloads}

  log "生成 docker-compose.yml / Generating docker-compose.yml..."
  cat > "$COMPOSE_DIR/docker-compose.yml" <<EOF
version: '3.8'
networks:
  download_net: {}
  proxy_net: {}
services:
  qbittorrent:
    image: superng6/qbittorrentee
    container_name: qbittorrent
    networks: [download_net, proxy_net]
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Shanghai
    volumes:
      - \$BASE_DIR/docker/qbittorrent/config:/config
      - \$BASE_DIR/media/downloads:/downloads
    ports: ['8080:8080','6881:6881','6881:6881/udp']
    restart: unless-stopped

  dashy:
    image: lissy93/dashy:latest
    container_name: dashy
    networks: [proxy_net]
    volumes:
      - \$BASE_DIR/docker/dashy/config/conf.yml:/app/user-data/conf.yml
    ports: ['8081:8080']
    restart: unless-stopped

  glances:
    image: nicolargo/glances:latest
    container_name: glances
    network_mode: host
    pid: host
    command: ["glances","-w","--enable-api","-B","0.0.0.0"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped

  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    networks: [proxy_net]
    volumes:
      - \$BASE_DIR:/srv
      - \$BASE_DIR/docker/filebrowser/config:/config
    ports: ['8082:80']
    restart: unless-stopped

  bitwarden:
    image: vaultwarden/server:latest
    container_name: bitwarden
    networks: [proxy_net]
    volumes:
      - \$BASE_DIR/docker/bitwarden/data:/data
    ports: ['8083:80']
    environment:
      - SIGNUPS_ALLOWED=true
      - ADMIN_TOKEN=changeme
    restart: unless-stopped

  emby:
    image: amilys/embyserver
    container_name: emby
    networks: [proxy_net]
    volumes:
      - \$BASE_DIR/docker/emby/config:/config
      - \$BASE_DIR/media:/mnt/media
    ports: ['8096:8096']
    restart: unless-stopped

  metatube-postgres:
    image: postgres:15-alpine
    container_name: metatube-postgres
    networks: [proxy_net]
    environment:
      - POSTGRES_USER=metatube
      - POSTGRES_PASSWORD=metatube
      - POSTGRES_DB=metatube
    volumes:
      - \$BASE_DIR/docker/metatube/postgres:/var/lib/postgresql/data
    restart: unless-stopped

  metatube:
    image: ghcr.io/metatube-community/metatube-server:latest
    container_name: metatube
    networks: [proxy_net]
    depends_on: [metatube-postgres]
    volumes: [run:/var/run]
    ports: ['9090:8080']
    restart: unless-stopped

volumes:
  run:
EOF

  log "创建 Dashy 配置 / Generating Dashy config..."
  cat > "$BASE_DIR/docker/dashy/config/conf.yml" <<EOF
appConfig:
  theme: nord
  language: zh
pageInfo:
  title: AIO 控制面板
sections:
  - name: 服务导航
    items:
      - title: qBittorrent
        url: http://$IP_ADDR:8080
      - title: Dashy
        url: http://$IP_ADDR:8081
      - title: Filebrowser
        url: http://$IP_ADDR:8082
      - title: Bitwarden
        url: http://$IP_ADDR:8083
EOF

  log "启动容器 / Starting containers..."
  cd "$COMPOSE_DIR"
  docker compose up -d
  log "部署完成 / Deployment complete"
}

one_click(){
  echo -e "
1) 停止所有容器 / Stop all containers
2) 启动所有容器 / Start all containers
3) 重启所有容器 / Restart all containers
4) 删除所有容器 / Remove all containers
5) 删除镜像 / Remove all images
6) 清理镜像和配置 / Remove images & configs
7) 查看容器日志 / View container logs
8) 备份配置 / Backup configs
q) 返回 / Back
"
  read -rp "请选择操作编号: " opt
  case $opt in
    1) docker stop \$(docker ps -q) ;;
    2) docker start \$(docker ps -aq) ;;
    3) docker restart \$(docker ps -q) ;;
    4) docker rm -f \$(docker ps -aq) ;;
    5) docker rmi -f \$(docker images -q) ;;
    6) docker rm -f \$(docker ps -aq) && docker rmi -f \$(docker images -q) && rm -rf "$BASE_DIR/docker" ;;
    7)
       mapfile -t ct <<< "\$(docker ps -a --format '{{.Names}}')"
       for i in "\${!ct[@]}"; do echo "\$((i+1)). \${ct[i]}"; done
       read -rp "输入编号查看日志: " i
       docker logs \${ct[i-1]} ;;
    8)
       echo "可选挂载点: \${MOUNTS[*]}"
       read -rp "选择备份目录: " BACKUP_DIR
       mkdir -p "$BACKUP_DIR"
       cp -r "$BASE_DIR/docker" "$BACKUP_DIR/"
       log "备份完成: $BACKUP_DIR/docker"
       ;;
    q) return ;; 
    *) warn "无效选项 / Invalid choice" ;; 
  esac
}

# ---------------------------------------------------------------------------- #
# 主菜单 / Main Menu
# ---------------------------------------------------------------------------- #
while true; do
  echo -e "
====== N100 AIO 初始化 v6.0 ======
1) 开启 SSH 访问 / Enable SSH
2) 硬盘分区与挂载 / Disk partition & mount
3) 安装 Docker / Install Docker
4) 部署容器 / Deploy containers
5) 一键操作 / One-click actions
q) 退出 / Quit
"
  read -rp "请选择编号: " choice
  case $choice in
    1) enable_ssh ;;  
    2) partition_disk ;;  
    3) install_docker ;;  
    4) deploy_containers ;;  
    5) one_click ;;  
    q) log "退出脚本 / Exiting..."; break ;; 
    *) warn "无效选项 / Invalid choice" ;; 
  esac
done

log "脚本结束 / Script finished"
