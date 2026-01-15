#!/usr/bin/env bash
# nat-socks.sh
# Debian/Ubuntu 一键部署 SOCKS5 代理（无认证），基于 gost（Go Simple Tunnel）
# - 交互式：只让用户输入 SOCKS5 监听端口（VPS 内部端口）
# - 自动安装依赖：curl / wget / tar
# - 自动识别架构：amd64 / arm64
# - 下载 gost 最新版并安装到 /usr/local/bin/gost
# - 配置 systemd 服务 nat-socks（开机自启）
# - 如果检测到 IPv6 出口可用，则优先走 IPv6；否则优先走 IPv4
# - 最后输出：公网 IPv4 + SOCKS5 连接字符串（注意 NAT 外部端口需要你在面板映射！）

set -euo pipefail

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()  { echo "${BLUE}[信息]${RESET} $*"; }
warn()  { echo "${YELLOW}[警告]${RESET} $*"; }
error() { echo "${RED}[错误]${RESET} $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "请用 root 执行：sudo bash $0"
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

  [[ "$p" =~ ^[0-9]+$ ]] || error "端口必须是数字。"
  (( p >= 1 && p <= 65535 )) || error "端口范围必须是 1-65535。"
  SOCKS_PORT="$p"
}

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) GOST_ARCH="amd64" ;;
    aarch64|arm64) GOST_ARCH="arm64" ;;
    *) error "不支持的架构：$m（仅支持 amd64/arm64）" ;;
  esac
  info "检测到系统架构：${GOST_ARCH}"
}

get_latest_gost_tag() {
  # 用 GitHub API 获取最新版本 tag，比如 v3.2.6
  local api="https://api.github.com/repos/go-gost/gost/releases/latest"
  local tag
  tag="$(curl -fsSL --max-time 15 "$api" \
    | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]\+\)".*/\1/p' \
    | head -n1)"
  [[ -n "${tag:-}" ]] || error "无法从 GitHub API 获取 gost 最新版本号。"
  echo "$tag"
}

check_ipv6_egress() {
  # 检测 IPv6 出口是否真正可用（能 curl -6 出去才算）
  if curl -6 -fsS --max-time 6 https://ip.sb >/dev/null 2>&1; then
    IPV6_OK=1
  else
    IPV6_OK=0
  fi
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

  # ✅ 修复：即使 tmpdir 未定义也不会报错
  trap '[[ -n "${tmpdir-}" && -d "${tmpdir-}" ]] && rm -rf "${tmpdir-}"' EXIT

  if cmd_exists curl; then
    curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 120 \
      -o "${tmpdir}/${tarball}" "$url" \
      || error "下载失败（curl）。请检查网络或 GitHub 是否可访问。"
  else
    wget -T 30 -t 3 -O "${tmpdir}/${tarball}" "$url" \
      || error "下载失败（wget）。请检查网络或 GitHub 是否可访问。"
  fi

  info "正在解压..."
  tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir" || error "解压失败。"

  local bin_path=""
  bin_path="$(find "$tmpdir" -maxdepth 3 -type f -name gost -perm -111 2>/dev/null | head -n1 || true)"
  [[ -n "$bin_path" ]] || error "解压后未找到 gost 可执行文件。"

  install -m 0755 "$bin_path" /usr/local/bin/gost
  /usr/local/bin/gost -V >/dev/null 2>&1 || error "gost 安装完成但运行失败。"

  info "已安装 gost 到：/usr/local/bin/gost"
}

write_gost_config() {
  local prefer
  mkdir -p /etc/nat-socks

  if [[ "${IPV6_OK}" -eq 1 ]]; then
    prefer="ipv6"
    info "检测到 IPv6 出口可用：将优先走 IPv6（解析优先 IPv6）。"
  else
    prefer="ipv4"
    warn "未检测到 IPv6 出口：将优先走 IPv4（避免代理出站异常）。"
  fi

  cat > /etc/nat-socks/gost.yaml <<EOF
# 本配置由 nat-socks.sh 自动生成
# 同时监听 IPv4 + IPv6，适配不同系统的 IPv6 绑定行为
services:
  - name: nat-socks-v4
    addr: "0.0.0.0:${SOCKS_PORT}"
    handler:
      type: socks5
    listener:
      type: tcp
    resolver: resolver-0

  - name: nat-socks-v6
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

get_public_ipv4() {
  # NAT 机器网卡可能是内网 IP，因此必须访问外部 API 获取公网 IPv4
  local ip=""
  ip="$(curl -4 -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "$ip" ]] || ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "$ip" ]] || ip="$(curl -4 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null | tr -d ' \r\n' || true)"

  [[ -n "$ip" ]] || error "获取公网 IPv4 失败（外部 API 均不可用）。"
  echo "$ip"
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

  if ! systemctl is-active --quiet nat-socks; then
    systemctl --no-pager -l status nat-socks || true
    error "nat-socks 服务未正常运行。"
  fi

  local pub4
  pub4="$(get_public_ipv4)"

  echo
  echo "${BOLD}================ 部署完成 ================${RESET}"
  echo "服务名称：nat-socks（systemd）"
  echo "内部监听端口（VPS 内部端口）：${SOCKS_PORT}"
  echo
  echo "${YELLOW}注意：你是 NAT 机器，还需要去服务商面板做「端口转发」：${RESET}"
  echo "  外部端口（公网端口）  --->  内部端口（本机监听端口 ${SOCKS_PORT}）"
  echo "  例如：${pub4}:40001  --->  本机:${SOCKS_PORT}"
  echo

  if [[ "${IPV6_OK}" -eq 1 ]]; then
    echo "IPv6 出口状态：通"
  else
    echo "IPv6 出口状态：不通"
  fi

  echo
  echo "${GREEN}${BOLD}你的公网 IPv4 是：${pub4}${RESET}"
  echo "${GREEN}${BOLD}（提示：如果 NAT 外部端口不是 ${SOCKS_PORT}，请用“外部端口”替换下面端口）${RESET}"
  echo
  echo "${GREEN}${BOLD}socks5://${pub4}:${SOCKS_PORT}${RESET}"
  echo
}

main "$@"
