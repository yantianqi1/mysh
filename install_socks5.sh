#!/usr/bin/env bash
set -euo pipefail

# ===================== 强制交互 I/O（防“非交互误判”） =====================
TTY_IN=""
TTY_OUT=""
if [[ -r /dev/tty && -w /dev/tty ]]; then
  TTY_IN="/dev/tty"
  TTY_OUT="/dev/tty"
  INTERACTIVE=1
else
  INTERACTIVE=0
fi

say() { printf '%s\n' "$*" >"${TTY_OUT:-/dev/stderr}"; }

prompt_default() {
  local label="$1" def="$2" v=""
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    printf '%s [默认 %s]: ' "$label" "$def" >"$TTY_OUT"
    IFS= read -r v <"$TTY_IN" || v=""
    printf '%s' "${v:-$def}"
  else
    printf '%s' "$def"
  fi
}

prompt_required() {
  local label="$1" v=""
  if [[ "$INTERACTIVE" -ne 1 ]]; then
    echo "非交互模式下缺少必填项：$label" >&2
    exit 1
  fi
  while true; do
    printf '%s: ' "$label" >"$TTY_OUT"
    IFS= read -r v <"$TTY_IN" || v=""
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
}

prompt_secret() {
  local label="$1" v=""
  if [[ "$INTERACTIVE" -ne 1 ]]; then
    echo "非交互模式下无法安全输入密码，请用 PROXY_PASS 环境变量。" >&2
    exit 1
  fi
  while true; do
    printf '%s（输入不显示）: ' "$label" >"$TTY_OUT"
    stty -echo <"$TTY_IN" || true
    IFS= read -r v <"$TTY_IN" || v=""
    stty echo <"$TTY_IN" || true
    printf '\n' >"$TTY_OUT"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
}

# ===================== 工具函数 =====================
need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "请用 root 运行：sudo ./install.sh" >&2
    exit 1
  fi
}

detect_iface() {
  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  echo "${iface:-eth0}"
}

detect_public_ip() {
  curl -s --max-time 5 ifconfig.me 2>/dev/null || true
}

get_ssh_client_ip() {
  # 优先 SSH_CLIENT（格式：ip port port），否则 SSH_CONNECTION（ip port ip port）
  local ip=""
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    ip="${SSH_CLIENT%% *}"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="${SSH_CONNECTION%% *}"
  fi
  # 简单过滤（只接受像 IPv4/IPv6 的字符串）
  [[ -n "$ip" ]] && echo "$ip" || echo ""
}

kill_existing_danted() {
  # 尽量彻底：避免端口占用/旧配置还在跑
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop danted 2>/dev/null || true
    systemctl disable danted 2>/dev/null || true
  fi
  pkill -9 -x danted 2>/dev/null || true
  pkill -9 -f "/usr/sbin/danted .* -f /etc/danted.conf" 2>/dev/null || true
  sleep 1
}

ensure_cron_reboot() {
  # cron 可能没装
  if ! command -v crontab >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update -y >/dev/null
    apt install -y cron >/dev/null
  fi
  local line="@reboot nohup /usr/sbin/danted -f /etc/danted.conf >/var/log/danted.nohup.log 2>&1 &"
  ( crontab -l 2>/dev/null | grep -vF "/usr/sbin/danted -f /etc/danted.conf" || true
    echo "$line"
  ) | crontab -
}

start_danted_auto() {
  local ok=0
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart danted 2>/dev/null; then
      if systemctl is-active --quiet danted 2>/dev/null; then
        ok=1
        systemctl enable danted >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ "$ok" -ne 1 ]]; then
    # systemd 不可用（NAMESPACE/LXC 常见） -> nohup
    nohup /usr/sbin/danted -f /etc/danted.conf >/var/log/danted.nohup.log 2>&1 &
    ensure_cron_reboot
  fi
}

verify_listen() {
  local port="$1"
  ss -lntp | grep -q ":${port}" || return 1
}

normalize_whitelist() {
  # 输入：1.2.3.4,5.6.7.0/24  -> 输出：1.2.3.4/32,5.6.7.0/24
  local raw="$1"
  raw="${raw// /}"
  raw="${raw//$'\t'/}"
  [[ -z "$raw" ]] && { echo ""; return 0; }

  local out="" item=""
  IFS=',' read -ra arr <<< "$raw"
  for item in "${arr[@]}"; do
    [[ -z "$item" ]] && continue
    if [[ "$item" == */* ]]; then
      out+="${item},"
    else
      out+="${item}/32,"
    fi
  done
  echo "${out%,}"
}

whitelist_contains_ip() {
  # 粗略判断：如果白名单里包含 "ip/" 前缀就认为包含
  local wl="$1" ip="$2"
  [[ -z "$wl" || -z "$ip" ]] && return 1
  [[ "$wl" == *"${ip}/"* ]] && return 0
  return 1
}

gen_rules_blocks() {
  local wl="$1"
  if [[ -z "$wl" ]]; then
cat <<'EOF'
client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  command: connect
}
EOF
  else
    local item=""
    IFS=',' read -ra arr <<< "$wl"

    for item in "${arr[@]}"; do
cat <<EOF
client pass {
  from: ${item} to: 0.0.0.0/0
}

EOF
    done

cat <<'EOF'
client block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

EOF

    for item in "${arr[@]}"; do
cat <<EOF
socks pass {
  from: ${item} to: 0.0.0.0/0
  protocol: tcp
  command: connect
}

EOF
    done

cat <<'EOF'
socks block {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}
EOF
  fi
}

# ===================== 主流程 =====================
need_root

DEFAULT_PORT="${DEFAULT_PORT:-1080}"
DEFAULT_USER="${DEFAULT_USER:-proxyuser}"

MACHINE_TYPE="${MACHINE_TYPE:-}"   # nat|vps
AUTH_MODE="${AUTH_MODE:-}"         # noauth|auth
PROXY_PORT="${PROXY_PORT:-}"
EXTERNAL_PORT="${EXTERNAL_PORT:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
WHITELIST_IPS="${WHITELIST_IPS:-}" # 多个用逗号

IFACE="$(detect_iface)"
SSH_IP="$(get_ssh_client_ip)"

# 1) 机器类型
if [[ -z "$MACHINE_TYPE" ]]; then
  say "请选择机器类型："
  say "  1) VPS（独立公网 IP）"
  say "  2) NAT（需要端口映射）"
  c="$(prompt_default "选择" "2")"
  say ""
  [[ "$c" == "1" ]] && MACHINE_TYPE="vps" || MACHINE_TYPE="nat"
fi
[[ "$MACHINE_TYPE" == "vps" || "$MACHINE_TYPE" == "nat" ]] || { echo "MACHINE_TYPE 只能是 vps 或 nat" >&2; exit 1; }

# 2) 认证模式
if [[ -z "$AUTH_MODE" ]]; then
  say "是否启用用户名密码？"
  say "  1) 启用（更安全）"
  say "  2) 不启用（无密码）"
  c="$(prompt_default "选择" "2")"
  say ""
  [[ "$c" == "1" ]] && AUTH_MODE="auth" || AUTH_MODE="noauth"
fi
[[ "$AUTH_MODE" == "auth" || "$AUTH_MODE" == "noauth" ]] || { echo "AUTH_MODE 只能是 auth 或 noauth" >&2; exit 1; }

# 3) 内部监听端口
if [[ -z "$PROXY_PORT" ]]; then
  PROXY_PORT="$(prompt_default "SOCKS5 内部监听端口" "$DEFAULT_PORT")"
  say ""
fi

# 4) NAT 外部端口（必须问）
if [[ "$MACHINE_TYPE" == "nat" ]]; then
  if [[ -z "$EXTERNAL_PORT" ]]; then
    EXTERNAL_PORT="$(prompt_required "请输入【外部转发端口】（面板外部端口，如 11111）")"
    say ""
  fi
else
  EXTERNAL_PORT="${EXTERNAL_PORT:-$PROXY_PORT}"
fi

# 5) 公网 IP/域名
if [[ -z "$PUBLIC_IP" ]]; then
  guess="$(detect_public_ip)"
  if [[ -n "$guess" ]]; then
    PUBLIC_IP="$(prompt_default "请输入公网IP/域名（回车=自动检测）" "$guess")"
  else
    PUBLIC_IP="$(prompt_required "请输入公网IP/域名（无法自动检测）")"
  fi
  say ""
fi

# 6) 白名单（只在 noauth 时交互询问；但 env 也支持）
if [[ "$AUTH_MODE" == "noauth" && -z "$WHITELIST_IPS" && "$INTERACTIVE" -eq 1 ]]; then
  say "无密码模式建议设置白名单（多个用逗号分隔），留空表示不限制："
  say "例如：64.81.113.45,1.2.3.0/24"
  if [[ -n "$SSH_IP" ]]; then
    say "检测到你当前 SSH 客户端 IP 可能是：${SSH_IP}（建议加入白名单）"
  fi
  printf '白名单IP（可空）: ' >"$TTY_OUT"
  IFS= read -r WHITELIST_IPS <"$TTY_IN" || WHITELIST_IPS=""
  say ""
fi
WHITELIST_IPS="$(normalize_whitelist "$WHITELIST_IPS")"

# 6.1 防锁死：如果设置了白名单，但不包含当前 SSH IP，则提示并默认加入
if [[ "$AUTH_MODE" == "noauth" && -n "$WHITELIST_IPS" && -n "$SSH_IP" ]]; then
  if ! whitelist_contains_ip "$WHITELIST_IPS" "$SSH_IP"; then
    if [[ "$INTERACTIVE" -eq 1 ]]; then
      say "⚠️ 你设置了白名单，但不包含当前 SSH IP：${SSH_IP}"
      say "不加入的话，你可能立刻无法再连接这台服务器。"
      ans="$(prompt_default "是否自动把 ${SSH_IP} 加入白名单？(y/n)" "y")"
      say ""
      if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
        WHITELIST_IPS="${WHITELIST_IPS},${SSH_IP}/32"
        WHITELIST_IPS="$(normalize_whitelist "$WHITELIST_IPS")"
      else
        say "已选择不加入（注意：可能会锁死自己）"
      fi
    else
      # 非交互：保守起见自动加入（避免自锁）
      WHITELIST_IPS="${WHITELIST_IPS},${SSH_IP}/32"
      WHITELIST_IPS="$(normalize_whitelist "$WHITELIST_IPS")"
    fi
  fi
fi

# 7) 账号密码（auth）
if [[ "$AUTH_MODE" == "auth" ]]; then
  PROXY_USER="${PROXY_USER:-$(prompt_default "代理用户名" "$DEFAULT_USER")}"
  say ""
  PROXY_PASS="${PROXY_PASS:-$(prompt_secret "代理密码")}"
  say ""
fi

# 安装
export DEBIAN_FRONTEND=noninteractive
apt update -y >/dev/null
apt install -y dante-server curl >/dev/null

# 写配置
RULES="$(gen_rules_blocks "$WHITELIST_IPS")"

if [[ "$AUTH_MODE" == "auth" ]]; then
  id "$PROXY_USER" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$PROXY_USER"
  echo "${PROXY_USER}:${PROXY_PASS}" | chpasswd

  cat >/etc/danted.conf <<EOF
logoutput: stderr

internal: 0.0.0.0 port = ${PROXY_PORT}
external: ${IFACE}

clientmethod: username
socksmethod: username

user.privileged: root
user.notprivileged: nobody

${RULES}
EOF
else
  cat >/etc/danted.conf <<EOF
logoutput: stderr

internal: 0.0.0.0 port = ${PROXY_PORT}
external: ${IFACE}

clientmethod: none
socksmethod: none

user.privileged: root
user.notprivileged: nobody

${RULES}
EOF
fi

# 覆盖式重启（杀旧 -> 启动）
kill_existing_danted
start_danted_auto

if ! verify_listen "$PROXY_PORT"; then
  echo "启动失败：未监听端口 ${PROXY_PORT}" >&2
  echo "看日志：tail -n 120 /var/log/danted.nohup.log" >&2
  exit 1
fi

# 最终只输出一行（stdout），方便你复制给项目用
if [[ "$AUTH_MODE" == "auth" ]]; then
  echo "socks5h://${PROXY_USER}:${PROXY_PASS}@${PUBLIC_IP}:${EXTERNAL_PORT}"
else
  echo "socks5h://${PUBLIC_IP}:${EXTERNAL_PORT}"
fi
