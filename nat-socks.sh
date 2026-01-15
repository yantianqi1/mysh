#!/usr/bin/env bash
# nat-socks.sh (Final Stable)
# Debian/Ubuntu 一键部署 SOCKS5 代理（无认证），基于 gost
# 适用于 NAT 小鸡 + IPv4/IPv6 双栈
#
# 特性：
# - 只输入一个参数：SOCKS5 内部监听端口
# - 自动安装依赖：curl/wget/tar
# - 自动识别架构：amd64/arm64
# - 下载 gost 最新版并安装
# - systemd 服务：nat-socks（开机自启）
# - 采用单监听：[::]:PORT（同时支持 IPv4 + IPv6，避免端口冲突）
# - IPv6 出口检测更稳定（避免误判）
# - 最终输出 IPv4 / IPv6 连接串

set -euo pipefail

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()  { echo "${BLUE}[信息]${RESET} $*"; }
warn()  { echo "${YELLOW}[警告]${RESET} $*"; }
die()   { echo "${RED}[错误]${RESET} $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请用 root 执行：sudo bash $0"
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  info "正在安装依赖（curl, wget, tar）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl wget tar ca-certificates >/dev/null
}

ask_port() {
  local p=""
  echo
  echo "请输入 SOCKS5 监听端口（这是 VPS 内部端口，不是 NAT 外部映射端口）"
  read -r -p "SOCKS5 内部监听端口 (1-65535): " p
  [[ "$p" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
  (( p >= 1 && p <= 65535 )) || die "端口范围必须是 1-65535。"
  SOCKS_PORT="$p"
}

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

get_latest_gost_tag() {
  local api="https://api.github.com/repos/go-gost/gost/releases/latest"
  local tag
  tag="$(curl -fsSL --max-time 15 "$api" \
    | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]\+\)".*/\1/p' \
    | head -n1)"
  [[ -n "${tag:-}" ]] || die "无法从 GitHub API 获取 gost 最新版本号。"
  echo "$tag"
}

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

check_ipv6_egress() {
  # 抗抖动检测：
  # 1) 必须存在 IPv6 默认路由
  # 2) ping6 通就认为 IPv6 出口可用
  # 3) 兜底再 curl6 一次（带重试）
  if ! ip -6 route show default | grep -q '^default'; then
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

get_public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "$ip" ]] || ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "$ip" ]] || die "获取公网 IPv4 失败。"
  echo "$ip"
}

get_public_ipv6() {
  local ip6=""
  if [[ "${IPV6_OK}" -eq 1 ]]; then
    ip6="$(curl -6 -fsS --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  fi
  echo "${ip6:-}"
}

write_gost_config() {
  mkdir -p /etc/nat-socks

  # ✅ 关键：只监听一个 [::]:PORT，避免 v4/v6 端口冲突
  # prefer 根据 IPv6 是否可用决定
  local prefer="ipv4"
  if [[ "${IPV6_OK}" -eq 1 ]]; then
    prefer="ipv6"
    info "检测到 IPv6 出口可用：代理解析优先走 IPv6。"
  else
    warn "未检测到 IPv6 出口：代理解析优先走 IPv4。"
  fi

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
  systemctl enable --now nat-socks >/dev/null
  info "systemd 服务已安装并启动：nat-socks"
}

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
  else
    echo "${YELLOW}未获取到公网 IPv6（可能机器没有 IPv6 出口或被限制）。${RESET}"
  fi

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

  systemctl is-active --quiet nat-socks || die "nat-socks 服务未正常运行。"

  local pub4 pub6
  pub4="$(get_public_ipv4)"
  pub6="$(get_public_ipv6)"

  final_output "$pub4" "$pub6"
}

main "$@"
