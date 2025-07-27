#!/bin/bash

# 检查 SSH 服务状态
echo "检查 SSH 服务状态..."
if systemctl is-active --quiet ssh; then
    echo "SSH 服务正在运行"
else
    echo "SSH 服务未运行"
fi

# 检查 SSH 配置文件
echo -e "\n检查 SSH 配置文件..."
config_file="/etc/ssh/sshd_config"
if [ -f "$config_file" ]; then
    echo "配置文件存在: $config_file"
    echo "检查关键配置:"
    port=$(grep -i "^Port" "$config_file" | awk '{print $2}' | head -n 1)
    if [ -z "$port" ]; then
        echo "  - Port: 默认 (22)"
    else
        echo "  - Port: $port"
    fi
    permit_root=$(grep -i "^PermitRootLogin" "$config_file" | awk '{print $2}' | head -n 1)
    if [ -z "$permit_root" ]; then
        echo "  - PermitRootLogin: 默认 (no)"
    else
        echo "  - PermitRootLogin: $permit_root"
    fi
    password_auth=$(grep -i "^PasswordAuthentication" "$config_file" | awk '{print $2}' | head -n 1)
    if [ -z "$password_auth" ]; then
        echo "  - PasswordAuthentication: 默认 (yes)"
    else
        echo "  - PasswordAuthentication: $password_auth"
    fi
else
    echo "配置文件不存在: $config_file"
fi

# 检查防火墙状态
echo -e "\n检查防火墙状态..."
if command -v ufw &> /dev/null; then
    echo "检测到 UFW 防火墙"
    if sudo ufw status | grep -q "Status: active"; then
        echo "UFW 已启用"
        if sudo ufw status | grep -q "22/tcp"; then
            echo "SSH 端口 (22/tcp) 已开放"
        else
            echo "SSH 端口 (22/tcp) 未开放"
        fi
    else
        echo "UFW 未启用"
    fi
elif command -v iptables &> /dev/null; then
    echo "检测到 iptables 防火墙"
    if sudo iptables -L | grep -q "22"; then
        echo "iptables 允许 SSH 端口 (22)"
    else
        echo "iptables 未明确允许 SSH 端口 (22)"
    fi
else
    echo "未检测到常见防火墙工具"
fi

# 检查 SSH 端口监听
echo -e "\n检查 SSH 端口监听..."
if ss -tuln | grep -q ":22"; then
    echo "SSH 端口 (22) 正在监听"
else
    echo "SSH 端口 (22) 未监听"
fi
