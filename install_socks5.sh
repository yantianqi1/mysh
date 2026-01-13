#!/usr/bin/env bash
set -euo pipefail

# ===================== TTY / IO =====================
TTY_IN=""
TTY_OUT=""

# 优先用 /dev/tty（即使 stdin 是 pipe 也能交互）
if [[ -r /dev/tty && -w /dev/tty ]]; then
  TTY_IN="/dev/tty"
  TTY_OUT="/dev/tty"
  INTERACTIVE=1
else
  # 没有控制终端就认为非交互
  INTERACTIVE=0
fi

say() { printf '%s\n' "$*" >"${TTY_OUT:-/dev/stderr}"; }

prompt_default() {
  local label="$1" def="$2" v=""
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    printf '%s [默认 %s]: ' "$label" "$def" >"$TTY_OUT"
    IFS= read -r v <"$TTY_IN" || v=""
    v="${v:-$def}"
    printf '%s' "$v"
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

# ===================== Helpers =====================
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

kill_existing_danted() {
  pkill -9 -x danted 2>/dev/null || true
  pkill -9 -f "/usr/sbin/danted .* -f /etc/danted.conf" 2>/dev/null || true
  sleep 1
}

ensure_cron_reboot() {
  # cron 可能没装，补一下（不影响已装环境）
  if ! command -v crontab >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update -y >/dev/null
    apt install -y cron >/dev/null
  fi

  local line="@reboot nohup /usr/sbin/danted -D -f /etc/danted.conf >/var/log/danted.nohup.log 2>&1 &"
  ( crontab -l 2>/dev/null | grep -vF "/usr/sbin/danted -D -f /etc/danted.conf" || true
    echo "$line"
  ) | crontab -
}

start_danted_auto() {
  local ok=0

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop danted 2>/dev/null || true
    if systemctl restart danted 2>/dev/null; then
      if systemctl is-active --quiet danted 2>/dev/null; then
        ok=1
        systemctl enable danted >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ "$ok" -ne 1 ]]; then
    kill_existing_danted
    nohup /usr/sbin/danted -D -f /etc/danted.conf >/var/log/danted.nohup.log 2>&1 &
    ensure_cron_reboot
  fi
}

verify_listen() {
  local port="$1"
  ss -lntp | grep -q ":${port}" || return 1
}

normalize_whitelist() {
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
  out="${out%,}"
  echo "$out"
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

# ===================== Main =====================
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
WHITELIST_IPS="${WHITELIST_IPS:-}" # noauth 下白名单（逗号）

IFACE="$(detect_iface)"

# 交互选择（如果没传 env）
if [[ -z "$MACHINE_TYPE" ]]; then
  say "请选择机器类型："
  say "  1) VPS（独立公网 IP）"
  say "  2) NAT（需要端口映射）"
  c="$(prompt_default "选择" "2")"
  printf '\n' >"${TTY_OUT:-/dev/stderr}"
  [[ "$c" == "1" ]] && MACHINE_TYPE="vps" || MACHINE_TYPE="nat"
fi
[[ "$MACHINE_TYPE" == "vps" || "$MACHINE_TYPE" == "nat" ]] || { echo "MACHINE_TYPE 只能是 vps 或 nat" >&2; exit 1; }

if [[ -z "$AUTH_MODE" ]]; then
  say "是否启用用户名密码？"
  say "  1) 启用（更安全）"
  say "  2) 不启用（无密码）"
  c="$(prompt_default "选择" "2")"
  printf '\n' >"${TTY_OUT:-/dev/stderr}"
  [[ "$c" == "1" ]] && AUTH_MODE="auth" || AUTH_MODE="noauth"
fi
[[ "$AUTH_MODE" == "auth" || "$AUTH_MODE" == "noauth" ]] || { echo "AUTH_MODE 只能是 auth 或 noauth" >&2; exit 1; }

if [[ -z "$PROXY_PORT" ]]; then
  PROXY_PORT="$(prompt_default "SOCKS5 内部监听端口" "$DEFAULT_PORT")"
  printf '\n' >"${TTY_OUT:-/dev/stderr}"
fi

# NAT 必问外部端口（你要的一行地址用这个）
if [[ "$MACHINE_TYPE" == "nat" ]]; then
  if [[ -z "$EXTERNAL_PORT" ]]; then
    EXTERNAL_PORT="$(prompt_required "请输入【外部转发端口】（面板外部端口，如 11111）")"
    printf '\n' >"${TTY_OUT:-/dev/stderr}"
  fi
else
  EXTERNAL_PORT="${EXTERNAL_PORT:-$PROXY_PORT}"
fi

# 公网 IP/域名
if [[ -z "$PUBLIC_IP" ]]; then
  guess="$(detect_public_ip)"
  if [[ -n "$guess" ]]; then
    PUBLIC_IP="$(prompt_default "请输入公网IP/域名（回车=自动检测）" "$guess")"
  else
    PUBLIC_IP="$(prompt_required "请输入公网IP/域名（无法自动检测）")"
  fi
  printf '\n' >"${TTY_OUT:-/dev/stderr}"
fi

# 无密码：问白名单
if [[ "$AUTH_MODE" == "noauth" && -z "$WHITELIST_IPS" && "$INTERACTIVE" -eq 1 ]]; then
  say "无密码模式建议设置白名单（多个用逗号分隔），留空表示不限制："
  say "例如：1.2.3.4,5.6.7.0/24"
  printf '白名单IP（可空）: ' >"$TTY_OUT"
  IFS= read -r WHITELIST_IPS <"$TTY_IN" || WHITELIST_IPS=""
  printf '\n' >"$TTY_OUT"
fi
WHITELIST_IPS="$(normalize_whitelist "$WHITELIST_IPS")"

# auth：账号密码
if [[ "$AUTH_MODE" == "auth" ]]; then
  PROXY_USER="${PROXY_USER:-$(prompt_default "代理用户名" "$DEFAULT_USER")}"
  printf '\n' >"${TTY_OUT:-/dev/stderr}"
  PROXY_PASS="${PROXY_PASS:-$(prompt_secret "代理密码")}"
fi

# 安装
export DEBIAN_FRONTEND=noninteractive
apt update -y >/dev/null
apt install -y dante-server curl >/dev/null

RULES="$(gen_rules_blocks "$WHITELIST_IPS")"

# 写配置（正确字段：clientmethod/socksmethod + socks pass）
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

# 覆盖式重启
kill_existing_danted
start_danted_auto

if ! verify_listen "$PROXY_PORT"; then
  echo "启动失败：未监听端口 ${PROXY_PORT}" >&2
  echo "看日志：tail -n 120 /var/log/danted.nohup.log" >&2
  exit 1
fi

# 最终只输出一行地址（stdout）
if [[ "$AUTH_MODE" == "auth" ]]; then
  echo "socks5h://${PROXY_USER}:${PROXY_PASS}@${PUBLIC_IP}:${EXTERNAL_PORT}"
else
  echo "socks5h://${PUBLIC_IP}:${EXTERNAL_PORT}"
fi
