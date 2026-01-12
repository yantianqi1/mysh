#!/usr/bin/env bash
set -euo pipefail

# =========================
# Dante SOCKS5 installer
# - Supports NAT or VPS
# - Optional username/password auth
# - Supports non-interactive via env vars (good for curl | bash)
# =========================

DEFAULT_PORT="${DEFAULT_PORT:-1080}"
DEFAULT_USER="${DEFAULT_USER:-proxyuser}"

# Non-interactive envs (optional)
#   MACHINE_TYPE: "nat" | "vps"
#   AUTH_MODE: "auth" | "noauth"
#   PROXY_PORT: number
#   PROXY_USER: string
#   PROXY_PASS: string
MACHINE_TYPE="${MACHINE_TYPE:-}"
AUTH_MODE="${AUTH_MODE:-}"
PROXY_PORT="${PROXY_PORT:-}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

has_tty() {
  [[ -t 0 && -t 1 ]]
}

detect_iface() {
  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  if [[ -z "${iface}" ]]; then
    iface="eth0"
  fi
  echo "${iface}"
}

prompt_machine_type() {
  if [[ -n "${MACHINE_TYPE}" ]]; then
    case "${MACHINE_TYPE}" in
      nat|vps) echo "${MACHINE_TYPE}"; return 0;;
      *) echo "环境变量 MACHINE_TYPE 只能是 nat 或 vps"; exit 1;;
    esac
  fi

  echo "请选择宿主机类型："
  echo "  1) VPS（独立公网IP，端口直接对外）"
  echo "  2) NAT（需要商家后台端口映射）"
  local choice
  read -r -p "输入 1 或 2 [默认 2]: " choice
  choice="${choice:-2}"
  case "${choice}" in
    1) echo "vps";;
    2) echo "nat";;
    *) echo "nat";;
  esac
}

prompt_auth_mode() {
  if [[ -n "${AUTH_MODE}" ]]; then
    case "${AUTH_MODE}" in
      auth|noauth) echo "${AUTH_MODE}"; return 0;;
      *) echo "环境变量 AUTH_MODE 只能是 auth 或 noauth"; exit 1;;
    esac
  fi

  echo "是否启用用户名/密码认证？"
  echo "  1) 启用（更安全，推荐）"
  echo "  2) 不启用（可直接 socks5://host:port，但容易被盗用）"
  local choice
  read -r -p "输入 1 或 2 [默认 1]: " choice
  choice="${choice:-1}"
  case "${choice}" in
    1) echo "auth";;
    2) echo "noauth";;
    *) echo "auth";;
  esac
}

prompt_port() {
  if [[ -n "${PROXY_PORT}" ]]; then
    echo "${PROXY_PORT}"
    return 0
  fi
  local port
  read -r -p "SOCKS5 监听端口 [默认 ${DEFAULT_PORT}]: " port
  echo "${port:-$DEFAULT_PORT}"
}

prompt_user() {
  if [[ -n "${PROXY_USER}" ]]; then
    echo "${PROXY_USER}"
    return 0
  fi
  local user
  read -r -p "代理用户名 [默认 ${DEFAULT_USER}]: " user
  echo "${user:-$DEFAULT_USER}"
}

prompt_pass() {
  # If env provided, use it (works with curl|bash)
  if [[ -n "${PROXY_PASS}" ]]; then
    echo "${PROXY_PASS}"
    return 0
  fi

  # If no TTY, cannot safely read hidden password; require env
  if ! has_tty; then
    echo "当前不是交互终端（例如 curl | bash），请通过环境变量 PROXY_PASS 提供密码。" >&2
    echo "示例：PROXY_PASS='你的密码' curl -fsSL <raw链接> | sudo -E bash" >&2
    exit 1
  fi

  local p1 p2
  while true; do
    echo -n "代理密码（输入时不显示）："
    stty -echo
    read -r p1
    stty echo
    echo
    if [[ -z "${p1}" ]]; then
      echo "密码不能为空，请重试。"
      continue
    fi

    echo -n "再次输入确认："
    stty -echo
    read -r p2
    stty echo
    echo

    if [[ "${p1}" != "${p2}" ]]; then
      echo "两次密码不一致，请重试。"
      continue
    fi
    echo "${p1}"
    return 0
  done
}

install_pkg() {
  echo "[1/6] 安装 dante-server ..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y dante-server curl
}

create_user_if_needed() {
  local user="$1" pass="$2"
  echo "[2/6] 创建/更新代理用户 ..."
  if id "${user}" >/dev/null 2>&1; then
    echo "用户已存在：${user}，将更新密码"
  else
    useradd -m -s /usr/sbin/nologin "${user}"
  fi
  echo "${user}:${pass}" | chpasswd
}

write_config() {
  local iface="$1" port="$2" mode="$3"
  echo "[3/6] 写入 danted 配置 ..."

  if [[ "${mode}" == "auth" ]]; then
    cat >/etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${port}
external: ${iface}

method: username
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  log: connect disconnect error
}
EOF
  else
    cat >/etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${port}
external: ${iface}

method: none
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  log: connect disconnect error
}
EOF
  fi
}

start_service() {
  echo "[4/6] 启动并设置开机自启 ..."
  systemctl restart danted
  systemctl enable danted >/dev/null 2>&1 || true
}

check_listen() {
  local port="$1"
  echo "[5/6] 检查监听状态 ..."
  if ss -lntp | grep -q ":${port}"; then
    echo "✅ Dante 已监听端口 ${port}"
  else
    echo "❌ 未检测到监听端口 ${port}，请检查：systemctl status danted"
    exit 1
  fi
}

show_result() {
  local machine="$1" mode="$2" port="$3" user="$4" pass="$5"
  local public_ip
  public_ip="$(curl -s --max-time 5 ifconfig.me || true)"

  echo
  echo "================= 部署完成 ================="
  echo "机器类型：${machine}"
  echo "认证模式：${mode}"
  echo "SOCKS5（服务器内部）监听：0.0.0.0:${port}"
  echo "出口网卡：${IFACE}"
  if [[ -n "${public_ip}" ]]; then
    echo "检测到的出口公网IP（仅供参考）：${public_ip}"
  fi
  echo

  if [[ "${machine}" == "nat" ]]; then
    echo "【NAT 机器必须做】去商家后台做端口映射："
    echo "外部端口(你选)  --->  内部端口 ${port} (TCP)"
    echo
    echo "最终给外部用的是：外网IP:外部端口（不是内部 ${port}）"
  else
    echo "【VPS 机器】端口可直接对外使用（确保安全组/防火墙放行 TCP ${port}）"
  fi

  echo
  if [[ "${mode}" == "auth" ]]; then
    echo "使用方式："
    echo "  socks5://$user:$pass@<外网IP>:<端口>"
    echo "测试命令："
    echo "  curl --socks5 $user:$pass@<外网IP>:<端口> http://ipinfo.io"
  else
    echo "使用方式："
    echo "  socks5://<外网IP>:<端口>"
    echo "测试命令："
    echo "  curl --socks5 <外网IP>:<端口> http://ipinfo.io"
    echo
    echo "⚠️ 提醒：无密码模式容易被扫端口盗用，强烈建议配合 IP 白名单 或仅内网使用。"
  fi
  echo "==========================================="
}

# ---------------- main ----------------
need_root

echo "=== Dante SOCKS5 一键部署脚本（KVM/NAT/VPS 适用）==="

IFACE="$(detect_iface)"
MACHINE="$(prompt_machine_type)"
MODE="$(prompt_auth_mode)"
PORT="$(prompt_port)"

USER=""
PASS=""

if [[ "${MODE}" == "auth" ]]; then
  USER="$(prompt_user)"
  PASS="$(prompt_pass)"
fi

install_pkg

if [[ "${MODE}" == "auth" ]]; then
  create_user_if_needed "${USER}" "${PASS}"
fi

write_config "${IFACE}" "${PORT}" "${MODE}"
start_service
check_listen "${PORT}"
show_result "${MACHINE}" "${MODE}" "${PORT}" "${USER}" "${PASS}"
