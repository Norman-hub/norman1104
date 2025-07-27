#!/bin/bash

# 检查 SSH 服务状态
echo "### 检查 SSH 服务状态 ###"
ssh_status=$(systemctl status ssh 2>&1)
if echo "$ssh_status" | grep -q "active (running)"; then
    echo "SSH 服务正在运行。"
else
    echo "SSH 服务未正常运行，状态如下："
    echo "$ssh_status"
fi

# 检查 SSH 配置文件中的关键设置
echo -e "\n### 检查 SSH 配置文件中的关键设置 ###"
config_file="/etc/ssh/sshd_config"
if [ -f "$config_file" ]; then
    # 检查 Port 设置
    port=$(grep -i "^port" "$config_file" | awk '{print $2}' | head -n 1)
    if [ -z "$port" ]; then
        port=22
        echo "在 $config_file 中未找到 Port 设置，使用默认值 22。"
    else
        echo "SSH 服务端口设置为：$port"
    fi
    
    # 检查 PermitRootLogin 设置
    permit_root_login=$(grep -i "^permitrootlogin" "$config_file" | awk '{print $2}' | head -n 1)
    if [ -z "$permit_root_login" ]; then
        echo "在 $config_file 中未找到 PermitRootLogin 设置。"
    else
        echo "PermitRootLogin 设置为：$permit_root_login"
    fi
    
    # 检查 ListenAddress 设置
    listen_address=$(grep -i "^listenaddress" "$config_file" | awk '{print $2}' | head -n 1)
    if [ -z "$listen_address" ]; then
        echo "在 $config_file 中未找到 ListenAddress 设置。"
    else
        echo "ListenAddress 设置为：$listen_address"
    fi
else
    echo "SSH 配置文件 $config_file 不存在。"
fi

# 检查防火墙状态（以 ufw 为例，若使用 iptables 可修改对应检查逻辑）
echo -e "\n### 检查防火墙状态 ###"
if command -v ufw &> /dev/null
then
    ufw_status=$(ufw status 2>&1)
    echo "ufw 防火墙状态："
    echo "$ufw_status"
    if echo "$ufw_status" | grep -q "Status: active"; then
        if echo "$ufw_status" | grep -q "22/tcp"; then
            echo "ufw 已允许 SSH 端口（22/tcp）访问。"
        else
            echo "ufw 未允许 SSH 端口（22/tcp）访问，请检查防火墙规则。"
        fi
    fi
elif command -v iptables &> /dev/null
then
    iptables_status=$(iptables -L -n 2>&1)
    echo "iptables 防火墙规则："
    echo "$iptables_status"
    if echo "$iptables_status" | grep -q "22"; then
        echo "iptables 已允许 SSH 端口（22）访问。"
    else
        echo "iptables 未允许 SSH 端口（22）访问，请检查防火墙规则。"
    fi
else
    echo "未检测到常见防火墙工具（ufw 或 iptables）。"
fi
