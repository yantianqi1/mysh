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

ensure_cron_rebo
