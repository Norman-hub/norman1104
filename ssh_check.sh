#!/bin/bash
echo "SSH CHECK SCRIPT"
echo "-----------------"

# 1. 检查 SSH 服务状态
echo "[1] Check SSH service status"
if systemctl is-active --quiet ssh; then
    echo "  - SSH service: RUNNING"
else
    echo "  - SSH service: STOPPED (try 'systemctl start ssh')"
fi

# 2. 检查 SSH 配置关键项
echo "[2] Check SSH config (/etc/ssh/sshd_config)"
grep -E "^Port|PermitRootLogin|PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null \
    || echo "  - Config file not found or empty"

# 3. 检查端口监听
echo "[3] Check port 22 listening"
ss -tuln | grep ":22" >/dev/null && echo "  - Port 22: LISTENING" \
    || echo "  - Port 22: NOT LISTENING"

# 4. 检查防火墙（最简判断）
echo "[4] Check firewall (simple)"
if command -v ufw >/dev/null; then
    ufw status | grep -q "22/tcp" && echo "  - UFW: 22 ALLOWED" \
        || echo "  - UFW: 22 BLOCKED (try 'ufw allow ssh')"
elif command -v iptables >/dev/null; then
    iptables -L | grep -q "22" && echo "  - iptables: 22 ALLOWED" \
        || echo "  - iptables: 22 BLOCKED (try 'iptables -A INPUT -p tcp --dport 22 -j ACCEPT')"
else
    echo "  - No firewall tool detected"
fi

echo "Done."
