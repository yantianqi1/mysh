#!/usr/bin/env bash
# nat-socks.sh (Ultimate Compatibility Edition)
# Debian/Ubuntu 一键部署 SOCKS5 代理（无认证），基于 gost（Go Simple Tunnel）
#
# 适用场景：NAT 架构低配 VPS（小鸡）、LXC / veth 环境、IPv4/IPv6 双栈
#
# 设计目标（适配性最强）：
# ✅ 只输入一个参数：SOCKS5 内部监听端口
# ✅ 自动安装依赖：curl/wget/tar/ca-certificates
# ✅ 自动识别架构：amd64/arm64
# ✅ 自动下载 gost 最新版本并安装到 /usr/local/bin/gost
# ✅ systemd 服务 nat-socks（开机自启）
# ✅ 只使用单监听：[::]:PORT（同时支持 IPv4 + IPv6，避免端口冲突）
# ✅ IPv6 出口检测抗抖（避免误判）
# ✅ IPv6 优先策略：若 IPv6 出口可用 -> prefer: ipv6，否则 prefer: ipv4
# ✅ 最终输出公网 IPv4/IPv6 连接串（绿色高亮）
# ✅ 输出 NAT 端口映射提醒（IPv4 必须外部端口 -> 内部端口）

set -euo pipefail

# ---------- 颜色 ----------
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()  { echo "${BLUE}[信息]${RESET} $*"; }
warn()  { echo "${YELLOW}[警告]${RESET} $*"; }
die()   { echo "${RED}[错误]${RESET} $*" >&2; exit 1; }

# ---------- 基础检查 ----------
need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请用 root 执行：sudo bash $0"
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# ---------- 依赖安装 ----------
install_deps() {
  info "正在安装依赖（curl, wget, tar）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl wget tar ca-certificates >/dev/null
}

# ---------- 交互输入端口 ----------
ask_port() {
  local p=""
  echo
  echo "请输入 SOCKS5 监听端口（这是 VPS 内部端口，不是 NAT 外部映射端口）"
  read -r -p "SOCKS5 内部监听端口 (1-65535): " p

  # 去掉空格/回车等杂质，最大兼容
  p="$(echo "$p" | tr -d ' \t\r\n')"

  [[ "$p" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
  (( p >= 1 && p <= 65535 )) || die "端口范围必须是 1-65535。"
  SOCKS_PORT="$p"
}

# ---------- 架构判断 ----------
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) GOST_ARCH="amd64" ;;
    aarch64|arm64) GOST_ARCH="arm64" ;;
    *) die "不支持的架构：$m（仅支持 amd64/arm64）" ;;
  esac
  info "检测到系统架构：${GOST_ARCH}"
}

# ---------- 获取 gost 最新版本 ----------
get_latest_gost_tag() {
  local api="https://api.github.com/repos/go-gost/gost/releases/latest"
  local tag

  tag="$(curl -fsSL --max-time 15 "$api" \
    | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]\+\)".*/\1/p' \
    | head -n1)"

  [[ -n "${tag:-}" ]] || die "无法从 GitHub API 获取 gost 最新版本号。"
  echo "$tag"
}

# ---------- 下载并安装 gost ----------
download_and_install_gost() {
  local tag ver url tarball
  local tmpdir=""

  tag="$(get_latest_gost_tag)"
  ver="${tag#v}"
  tarball="gost_${ver}_linux_${GOST_ARCH}.tar.gz"
  url="https://github.com/go-gost/gost/releases/download/${tag}/${tarball}"

  info "gost 最新版本：${tag}"
  info "正在下载：${url}"

  tmpdir="$(mktemp -d)"
  trap '[[ -n "${tmpdir-}" && -d "${tmpdir-}" ]] && rm -rf "${tmpdir-}"' EXIT

  if cmd_exists curl; then
    curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 120 \
      -o "${tmpdir}/${tarball}" "$url" \
      || die "下载失败（curl）。请检查网络或 GitHub 是否可访问。"
  else
    wget -T 30 -t 3 -O "${tmpdir}/${tarball}" "$url" \
      || die "下载失败（wget）。请检查网络或 GitHub 是否可访问。"
  fi

  info "正在解压..."
  tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir" || die "解压失败。"

  local bin_path=""
  bin_path="$(find "$tmpdir" -maxdepth 3 -type f -name gost -perm -111 2>/dev/null | head -n1 || true)"
  [[ -n "$bin_path" ]] || die "解压后未找到 gost 可执行文件。"

  install -m 0755 "$bin_path" /usr/local/bin/gost
  /usr/local/bin/gost -V >/dev/null 2>&1 || die "gost 安装完成但运行失败。"

  info "已安装 gost 到：/usr/local/bin/gost"
}

# ---------- IPv6 出口检测（抗抖动） ----------
check_ipv6_egress() {
  # 逻辑：
  # 1) 必须存在 IPv6 默认路由
  # 2) ping6 通 -> 认为 IPv6 出口可用
  # 3) ping6 不通时用 curl6 重试兜底
  if ! ip -6 route show default 2>/dev/null | grep -q '^default'; then
    IPV6_OK=0
    return 0
  fi

  if ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
    IPV6_OK=1
    return 0
  fi

  if curl -6 -fsS --max-time 6 --retry 2 --retry-delay 1 https://ipv6.icanhazip.com >/dev/null 2>&1; then
    IPV6_OK=1
  else
    IPV6_OK=0
  fi
}

# ---------- 获取公网 IPv4 / IPv6 ----------
get_public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "$ip" ]] || ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "$ip" ]] || die "获取公网 IPv4 失败（外部 API 不可用）。"
  echo "$ip"
}

get_public_ipv6() {
  local ip6=""
  if [[ "${IPV6_OK}" -eq 1 ]]; then
    ip6="$(curl -6 -fsS --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  fi
  echo "${ip6:-}"
}

# ---------- 写入 gost 配置（单监听双栈） ----------
write_gost_config() {
  mkdir -p /etc/nat-socks

  local prefer="ipv4"
  if [[ "${IPV6_OK}" -eq 1 ]]; then
    prefer="ipv6"
    info "检测到 IPv6 出口可用：代理解析优先走 IPv6。"
  else
    warn "未检测到 IPv6 出口：代理解析优先走 IPv4。"
  fi

  # ✅ 核心：只监听 [::]:PORT，避免 v4/v6 端口冲突（适配性最强）
  cat > /etc/nat-socks/gost.yaml <<EOF
services:
  - name: nat-socks
    addr: "[::]:${SOCKS_PORT}"
    handler:
      type: socks5
    listener:
      type: tcp
    resolver: resolver-0

resolvers:
  - name: resolver-0
    nameservers:
      - addr: "udp://1.1.1.1:53"
        prefer: ${prefer}
      - addr: "udp://8.8.8.8:53"
        prefer: ${prefer}
EOF

  info "配置文件已写入：/etc/nat-socks/gost.yaml"
}

# ---------- systemd 服务 ----------
write_systemd_service() {
  cat > /etc/systemd/system/nat-socks.service <<'EOF'
[Unit]
Description=nat-socks (SOCKS5 proxy via gost)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/nat-socks/gost.yaml
Restart=on-failure
RestartSec=1
LimitNOFILE=1048576

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

# ---------- 强制应用配置：清理旧进程（解决 LXC 残留导致端口不变） ----------
restart_clean() {
  info "正在重启服务（强制清理旧 gost，避免端口残留）..."
  systemctl stop nat-socks >/dev/null 2>&1 || true
  pkill -9 gost >/dev/null 2>&1 || true

  # 让 [::] 监听也能兼容 IPv4（多数系统默认 0，写一下更稳）
  sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true

  systemctl enable --now nat-socks >/dev/null 2>&1 || true
  systemctl start nat-socks >/dev/null 2>&1 || true
}

# ---------- 健康检查 ----------
health_check() {
  if ! systemctl is-active --quiet nat-socks; then
    systemctl --no-pager -l status nat-socks || true
    die "nat-socks 服务未正常运行。"
  fi

  # 确认端口监听（以 gost 进程为准）
  if ! ss -lntp 2>/dev/null | grep -qE "gost.*:(${SOCKS_PORT})"; then
    warn "未检测到 gost 正在监听端口 ${SOCKS_PORT}（可能 ss 输出不含进程名/权限限制）。"
  fi

  # 本机代理连通性快速测试（不依赖 ip.sb，避免 403）
  if ! curl -fsS --max-time 8 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org >/dev/null 2>&1; then
    systemctl --no-pager -l status nat-socks || true
    die "本机 SOCKS5 测试失败：无法通过代理访问外网。"
  fi
}

# ---------- 输出结果 ----------
final_output() {
  local pub4="$1"
  local pub6="$2"

  echo
  echo "${BOLD}================ 部署完成 ================${RESET}"
  echo "服务名称：nat-socks（systemd）"
  echo "内部监听端口（VPS 内部端口）：${SOCKS_PORT}"
  echo

  if [[ "${IPV6_OK}" -eq 1 ]]; then
    echo "IPv6 出口状态：通"
  else
    echo "IPv6 出口状态：不通"
  fi

  echo
  echo "${GREEN}${BOLD}公网 IPv4：${pub4}${RESET}"
  echo "${YELLOW}注意：NAT 小鸡的 IPv4 需要在服务商面板做端口映射：公网IPv4:外部端口 ---> 本机:${SOCKS_PORT}${RESET}"
  echo "${GREEN}${BOLD}IPv4 连接串（端口为示例，请换成 NAT 外部映射端口）：${RESET}"
  echo "${GREEN}${BOLD}socks5://${pub4}:${SOCKS_PORT}${RESET}"
  echo

  if [[ -n "${pub6:-}" ]]; then
    echo "${GREEN}${BOLD}公网 IPv6：${pub6}${RESET}"
    echo "${GREEN}${BOLD}IPv6 连接串（一般无需 NAT 映射，直接可用）：${RESET}"
    echo "${GREEN}${BOLD}socks5://[${pub6}]:${SOCKS_PORT}${RESET}"
    echo "${YELLOW}提示：IPv6 在客户端里必须写成 socks5://[IPv6]:端口（IPv6 外面必须带 []）${RESET}"
  else
    echo "${YELLOW}未获取到公网 IPv6（可能机器没有 IPv6 出口或被限制）。${RESET}"
  fi

  echo
  echo "${BLUE}[信息]${RESET} 常用命令："
  echo "  查看状态：systemctl status nat-socks --no-pager -l"
  echo "  重启服务：systemctl restart nat-socks"
  echo "  查看监听：ss -lntp | grep ${SOCKS_PORT}"
  echo
}

main() {
  need_root
  ask_port
  install_deps
  detect_arch

  check_ipv6_egress
  download_and_install_gost

  write_gost_config
  write_systemd_service

  restart_clean
  health_check

  local pub4 pub6
  pub4="$(get_public_ipv4)"
  pub6="$(get_public_ipv6)"

  final_output "$pub4" "$pub6"
}

main "$@"
