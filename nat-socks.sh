#!/usr/bin/env bash
# nat-socks.sh (Ultimate FORCE-OVERWRITE Edition)
# Debian/Ubuntu 一键部署 SOCKS5 代理（无认证），基于 gost
#
# ✅ 强制覆盖安装：无论之前部署过什么版本，全部清理干净重新部署
# ✅ 只输入一个参数：SOCKS5 内部监听端口
# ✅ 自动安装依赖 / 自动识别架构 / 下载 gost 最新版
# ✅ systemd 服务 nat-socks（开机自启）
# ✅ 单监听 [::]:PORT（避免 v4/v6 端口冲突，适配性最强）
# ✅ IPv6 出口检测抗抖（默认路由 + ping6 + curl6 重试）
# ✅ 最终输出 IPv4 + 多 IPv6 连接串（过滤 ULA、link-local）

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
  p="$(echo "$p" | tr -d ' \t\r\n')"
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

# ---------- 强制清理：无论历史部署过什么，都清掉 ----------
force_cleanup_all() {
  info "开始强制清理历史残留（旧进程/旧服务/旧配置）..."

  # 1) 停止并禁用服务（存在则清）
  systemctl stop nat-socks >/dev/null 2>&1 || true
  systemctl disable nat-socks >/dev/null 2>&1 || true

  # 2) 杀掉所有 gost（不管是谁启动的）
  pkill -9 gost >/dev/null 2>&1 || true

  # 3) 清理旧配置目录
  rm -rf /etc/nat-socks >/dev/null 2>&1 || true

  # 4) 删除旧 systemd unit / wants 链接
  rm -f /etc/systemd/system/nat-socks.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/multi-user.target.wants/nat-socks.service >/dev/null 2>&1 || true

  # 5) 重新加载 systemd
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true

  # 6) 给系统一点时间释放端口
  sleep 0.3

  info "强制清理完成。"
}

# ---------- IPv6 出口检测（抗抖动） ----------
check_ipv6_egress() {
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

get_public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "$ip" ]] || ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "$ip" ]] || die "获取公网 IPv4 失败（外部 API 不可用）。"
  echo "$ip"
}

get_public_ipv6_external() {
  local ip6=""
  if [[ "${IPV6_OK}" -eq 1 ]]; then
    ip6="$(curl -6 -fsS --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  fi
  echo "${ip6:-}"
}

get_public_ipv6_local_all() {
  # 只输出本机“已绑定”的 global IPv6（公网可直连）
  # 排除：fe80 link-local / fdxx ULA / ::1
  ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6/ {print $2}' \
    | cut -d/ -f1 \
    | grep -vE '^(fe80:|::1$)' \
    | grep -vE '^fd' \
    | sort -u
}

merge_ipv6_list() {
  local local_list external_one
  local_list="$(get_public_ipv6_local_all || true)"
  external_one="$(get_public_ipv6_external || true)"

  {
    [[ -n "${local_list:-}" ]] && echo "$local_list"
    [[ -n "${external_one:-}" ]] && echo "$external_one"
  } | awk 'NF' | sort -u
}

write_gost_config() {
  mkdir -p /etc/nat-socks

  local prefer="ipv4"
  if [[ "${IPV6_OK}" -eq 1 ]]; then
    prefer="ipv6"
    info "检测到 IPv6 出口可用：代理解析优先走 IPv6。"
  else
    warn "未检测到 IPv6 出口：代理解析优先走 IPv4。"
  fi

  # ✅ 关键：单监听 [::]:PORT（同时支持 IPv4 + IPv6，避免端口冲突）
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
  info "systemd 服务文件已写入：/etc/systemd/system/nat-socks.service"
}

start_service_fresh() {
  # 让 [::] 监听兼容 IPv4（一般默认就是 0，这里强制更稳）
  sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true

  systemctl enable nat-socks >/dev/null 2>&1 || true
  systemctl start nat-socks >/dev/null 2>&1 || true
}

assert_listening() {
  # 强制检查：必须监听到你输入的端口，否则直接报错退出
  # 兼容 ss 输出差异，这里只要出现 :PORT 就算监听成功
  if ! ss -lnt 2>/dev/null | grep -qE "[:.]${SOCKS_PORT}\b"; then
    systemctl --no-pager -l status nat-socks || true
    warn "当前监听列表："
    ss -lntp 2>/dev/null || true
    die "部署失败：未检测到端口 ${SOCKS_PORT} 正在监听。"
  fi
}

health_check_proxy() {
  # 本机代理连通性（不用 ip.sb，避免 403）
  if ! curl -fsS --max-time 8 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org >/dev/null 2>&1; then
    systemctl --no-pager -l status nat-socks || true
    die "本机 SOCKS5 测试失败：无法通过代理访问外网。"
  fi
}

final_output() {
  local pub4="$1"
  local ipv6_list="$2"

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
  echo "${YELLOW}注意：NAT 小鸡 IPv4 必须做端口映射：公网IPv4:外部端口 ---> 本机:${SOCKS_PORT}${RESET}"
  echo "${GREEN}${BOLD}IPv4 连接串（端口为示例，请换成 NAT 外部映射端口）：${RESET}"
  echo "${GREEN}${BOLD}socks5://${pub4}:${SOCKS_PORT}${RESET}"
  echo

  if [[ -n "${ipv6_list:-}" ]]; then
    echo "${GREEN}${BOLD}检测到以下公网 IPv6（可用于直连 SOCKS5）：${RESET}"
    echo "${YELLOW}提示：IPv6 必须写成 socks5://[IPv6]:端口（IPv6 外面必须带 []）${RESET}"
    echo
    while IFS= read -r ip6; do
      [[ -z "${ip6:-}" ]] && continue
      echo "${GREEN}${BOLD}socks5://[${ip6}]:${SOCKS_PORT}${RESET}"
    done <<< "$ipv6_list"
  else
    echo "${YELLOW}未检测到可用公网 IPv6（可能未绑定到网卡或被限制）。${RESET}"
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

  # ✅ 核心：先把历史部署全部清掉，再重新部署（强制覆盖）
  force_cleanup_all

  check_ipv6_egress
  download_and_install_gost

  write_gost_config
  write_systemd_service
  start_service_fresh

  # ✅ 必须监听成功 + 代理可用，否则直接报错退出
  assert_listening
  health_check_proxy

  local pub4 ipv6_list
  pub4="$(get_public_ipv4)"
  ipv6_list="$(merge_ipv6_list || true)"

  final_output "$pub4" "$ipv6_list"
}

main "$@"
