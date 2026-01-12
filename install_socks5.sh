#!/usr/bin/env bash
set -euo pipefail

# ====== 可改参数（也可以运行时交互输入）======
DEFAULT_PORT="1080"
DEFAULT_USER="proxyuser"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0"
  exit 1
fi

echo "=== Dante SOCKS5 一键部署脚本（KVM/NAT 适用）==="

# 检测网卡
IFACE="$(ip route | awk '/default/ {print $5; exit}')"
if [[ -z "${IFACE}" ]]; then
  echo "未检测到默认网卡，请手动输入（例如 eth0）："
  read -r IFACE
fi

# 交互输入端口/账号/密码
read -r -p "SOCKS5 监听端口 [默认 ${DEFAULT_PORT}]: " PORT
PORT="${PORT:-$DEFAULT_PORT}"

read -r -p "代理用户名 [默认 ${DEFAULT_USER}]: " USERNAME
USERNAME="${USERNAME:-$DEFAULT_USER}"

echo -n "代理密码（输入时不显示）："
stty -echo
read -r PASSWORD
stty echo
echo
if [[ -z "${PASSWORD}" ]]; then
  echo "密码不能为空"
  exit 1
fi

echo "[1/5] 安装 dante-server ..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y dante-server

echo "[2/5] 创建/更新代理用户 ..."
if id "${USERNAME}" >/dev/null 2>&1; then
  echo "用户已存在：${USERNAME}，将更新密码"
else
  useradd -m -s /usr/sbin/nologin "${USERNAME}"
fi
echo "${USERNAME}:${PASSWORD}" | chpasswd

echo "[3/5] 写入 danted 配置 ..."
cat >/etc/danted.conf <<EOF
logoutput: syslog

# 监听所有地址的 ${PORT} 端口
internal: 0.0.0.0 port = ${PORT}

# 外网出口网卡（自动检测）
external: ${IFACE}

# 认证方式：用户名密码
method: username
user.notprivileged: nobody

# 允许所有客户端连接（你也可以改成只允许固定IP段）
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

# 只放行 TCP（NAT/商家不保证 UDP）
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp
    log: connect disconnect error
}
EOF

echo "[4/5] 启动并设置开机自启 ..."
systemctl restart danted
systemctl enable danted

echo "[5/5] 检查监听状态 ..."
if ss -lntp | grep -q ":${PORT}"; then
  echo "✅ Dante 已监听端口 ${PORT}"
else
  echo "❌ 未检测到监听端口 ${PORT}，请检查：systemctl status danted"
  exit 1
fi

PUBLIC_IP="$(curl -s --max-time 5 ifconfig.me || true)"
echo
echo "================= 部署完成 ================="
echo "SOCKS5（服务器内部）地址：0.0.0.0:${PORT}"
echo "用户名：${USERNAME}"
echo "密码：${PASSWORD}"
echo "出口网卡：${IFACE}"
echo
echo "【NAT 机器必须做】去商家后台做端口映射："
echo "外部端口(你选)  --->  内部端口 ${PORT} (TCP)"
echo
if [[ -n "${PUBLIC_IP}" ]]; then
  echo "（检测到的出口公网IP可能是：${PUBLIC_IP}）"
fi
echo
echo "远端服务器测试命令："
echo "curl --socks5 ${USERNAME}:${PASSWORD}@<外网IP>:<外部端口> http://ipinfo.io"
echo "==========================================="
