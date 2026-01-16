#!/usr/bin/env bash
# ============================================================
# nat-socks.sh  (Debian/Ubuntu)
# 一键部署 gost SOCKS5（无认证），适配 NAT / IPv6-only / 低配 VPS
#
# ✅ 强制覆盖安装：清理旧服务/旧进程/旧配置
# ✅ 只输入一个参数：内部监听端口
# ✅ 单监听 [::]:PORT（同时支持 IPv4 + IPv6，避免端口冲突）
# ✅ IPv6 优先解析策略（有 IPv6 出口时 prefer=ipv6）
# ✅ 输出公网 IPv4 + 多个公网 IPv6 连接串
# ✅ 自动安装依赖：curl/wget/tar/ca-certificates/netcat-openbsd
# ✅ 自动本机测试并打印结果
#
# ✅ 双重 fallback：
#   - 获取版本：优先 latest 跳转解析；失败 -> 固定版本 FALLBACK_TAG
#   - 下载资产：优先 GitHub；失败 -> ghproxy 镜像
# ============================================================

set -euo pipefail

# ------------------ 可改参数 ------------------
FALLBACK_TAG="v3.2.6"     # 如果 latest 解析失败，就用这个版本兜底（可改）
SERVICE_NAME="nat-socks"
INSTALL_BIN="/usr/local/bin/gost"
CONF_DIR="/etc/nat-socks"
CONF_FILE="${CONF_DIR}/gost.yaml"
SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# ------------------------------------------------

# ---------- 颜色 ----------
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()  { echo "${BLUE}[信息]${RESET} $*"; }
warn()  { echo "${YELLOW}[警告]${RESET} $*"; }
ok()    { echo "${GREEN}[成功]${RESET} $*"; }
die()   { echo "${RED}[错误]${RESET} $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请用 root 执行：sudo bash $0"
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# ============================================================
# 1) 网络环境判断：IPv4/IPv6 是否有默认路由 -> 决定 curl/apt 是否强制走 IPv6
# ============================================================
IPV4_OK=0
IPV6_OK=0
CURL_IPVER=""
APT_OPTS=()

detect_stack() {
  if ip route 2>/dev/null | grep -q '^default'; then
    IPV4_OK=1
  else
    IPV4_OK=0
  fi

  if ip -6 route 2>/dev/null | grep -q '^default'; then
    IPV6_OK=1
  else
    IPV6_OK=0
  fi

  if [[ "$IPV4_OK" -eq 0 && "$IPV6_OK" -eq 1 ]]; then
    CURL_IPVER="-6"
    APT_OPTS=(-o Acquire::ForceIPv6=true -o Acquire::ForceIPv4=false)
    info "检测到环境：IPv6-only（curl/apt 将强制走 IPv6）"
  else
    CURL_IPVER=""
    APT_OPTS=()
    info "检测到环境：IPv4/双栈（curl/apt 使用默认策略）"
  fi
}

# ============================================================
# 2) DNS 自愈（适配你这种 /etc/resolv.conf 缺失或解析抖动的 NAT 小鸡）
# ============================================================
ensure_dns_basics() {
  # 修 hosts，避免 sudo: unable to resolve host
  local hn
  hn="$(hostname 2>/dev/null || true)"
  if [[ -n "${hn:-}" ]] && ! grep -qE "127\.0\.1\.1[[:space:]]+${hn}" /etc/hosts 2>/dev/null; then
    echo "127.0.1.1 ${hn}" >> /etc/hosts 2>/dev/null || true
  fi

  # 保证 nsswitch.conf 优先 files + dns
  if [[ -f /etc/nsswitch.conf ]]; then
    sed -i 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf 2>/dev/null || true
  fi

  # 没有 resolv.conf 就补一个（优先 IPv6 DNS）
  if [[ ! -f /etc/resolv.conf ]]; then
    warn "/etc/resolv.conf 不存在，自动写入 DNS（优先 IPv6 DNS）"
    mkdir -p /etc
    cat > /etc/resolv.conf <<'EOF'
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:2 rotate
EOF
  fi
}

dns_probe_or_fix() {
  # 若解析 github.com 失败，尝试重写 resolv.conf（常见：IPv6-only 缺 DNS）
  if ! getent hosts github.com >/dev/null 2>&1; then
    warn "检测到 DNS 解析异常，尝试修复 /etc/resolv.conf ..."
    mkdir -p /etc
    cat > /etc/resolv.conf <<'EOF'
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:2 rotate
EOF
    sleep 0.2
  fi

  if getent hosts github.com >/dev/null 2>&1; then
    ok "DNS 解析正常（github.com 可解析）"
  else
    warn "DNS 仍可能不稳定（github.com 解析失败）。若后续下载失败，请再次检查 DNS/网络。"
  fi
}

# ============================================================
# 3) 输入端口（唯一交互）
# ============================================================
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

# ============================================================
# 4) 依赖安装（自动装 nc）
# ============================================================
install_deps() {
  info "正在安装依赖（curl, wget, tar, ca-certificates, netcat-openbsd）..."
  export DEBIAN_FRONTEND=noninteractive

  # apt update 可能偶发 timeout（IPv6-only 镜像抖动），这里不强制失败退出
  if ! apt-get update -y "${APT_OPTS[@]}" >/dev/null 2>&1; then
    warn "apt-get update 出现超时/失败（常见于 IPv6-only/镜像抖动），继续尝试安装依赖..."
  fi

  if ! apt-get install -y curl wget tar ca-certificates netcat-openbsd "${APT_OPTS[@]}" >/dev/null 2>&1; then
    die "依赖安装失败：请检查网络/镜像后重试。"
  fi
  ok "依赖已就绪（含 nc 测试工具）"
}

# ============================================================
# 5) 架构判断（amd64/arm64）
# ============================================================
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

# ============================================================
# 6) 强制清理旧残留（无论部署过多少次都能覆盖）
# ============================================================
force_cleanup_all() {
  info "开始强制清理历史残留（旧进程/旧服务/旧配置）..."
  systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true

  pkill -9 gost >/dev/null 2>&1 || true

  rm -rf "${CONF_DIR}" >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_FILE}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service" >/dev/null 2>&1 || true

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  sleep 0.2

  info "强制清理完成。"
}

# ============================================================
# 7) 获取 gost 最新版本（双重 fallback：latest -> 固定版本）
#    说明：不用 api.github.com（你的机房经常连不上）
# ============================================================
get_latest_gost_tag() {
  local latest_url="https://github.com/go-gost/gost/releases/latest"
  local loc tag

  # 这里用 -I 拿跳转 Location，避免 api.github.com
  loc="$(curl ${CURL_IPVER} -fsSLI "${latest_url}" 2>/dev/null | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n1 | tr -d '\r' || true)"
  tag="$(echo "${loc:-}" | sed -n 's#.*tag/\(v[0-9.]\+\).*#\1#p' | head -n1 || true)"

  if [[ -n "${tag:-}" ]]; then
    echo "${tag}"
    return 0
  fi

  # fallback 固定版本
  warn "无法通过 latest 跳转解析 gost 最新版本，使用 fallback 版本：${FALLBACK_TAG}"
  echo "${FALLBACK_TAG}"
}

# ============================================================
# 8) 下载 gost（双重 fallback：GitHub -> ghproxy）
# ============================================================
download_and_install_gost() {
  local tag ver tarball url1 url2 tmpdir bin_path

  tag="$(get_latest_gost_tag)"
  ver="${tag#v}"
  tarball="gost_${ver}_linux_${GOST_ARCH}.tar.gz"

  url1="https://github.com/go-gost/gost/releases/download/${tag}/${tarball}"
  url2="https://ghproxy.com/${url1}"   # 镜像加速兜底

  info "gost 目标版本：${tag}"
  info "下载地址(主)：${url1}"
  info "下载地址(备)：${url2}"

  tmpdir="$(mktemp -d)"
  trap '[[ -d "${tmpdir}" ]] && rm -rf "${tmpdir}"' EXIT

  # 尝试主下载
  if ! curl ${CURL_IPVER} -fL --retry 3 --retry-delay 1 --connect-timeout 8 --max-time 180 \
      -o "${tmpdir}/${tarball}" "${url1}" >/dev/null 2>&1; then
    warn "主下载失败，尝试备用镜像下载（ghproxy）..."
    curl ${CURL_IPVER} -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 240 \
      -o "${tmpdir}/${tarball}" "${url2}" >/dev/null 2>&1 \
      || die "下载 gost 失败：GitHub 与镜像都不可用（检查网络/DNS/防火墙）。"
  fi

  info "正在解压..."
  tar -xzf "${tmpdir}/${tarball}" -C "${tmpdir}" || die "解压失败。"

  bin_path="$(find "${tmpdir}" -maxdepth 3 -type f -name gost -perm -111 2>/dev/null | head -n1 || true)"
  [[ -n "${bin_path:-}" ]] || die "解压后未找到 gost 可执行文件。"

  install -m 0755 "${bin_path}" "${INSTALL_BIN}"
  "${INSTALL_BIN}" -V >/dev/null 2>&1 || die "gost 安装完成但运行失败。"

  ok "已安装 gost：${INSTALL_BIN}"
}

# ============================================================
# 9) IPv6 出口检测（用于 resolver prefer）
# ============================================================
IPV6_EGRESS=0
check_ipv6_egress() {
  if ip -6 route show default 2>/dev/null | grep -q '^default' \
     && ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
    IPV6_EGRESS=1
  else
    IPV6_EGRESS=0
  fi
}

# ============================================================
# 10) 写 gost 配置（单监听双栈）
# ============================================================
write_gost_config() {
  mkdir -p "${CONF_DIR}"

  local prefer="ipv4"
  if [[ "${IPV6_EGRESS}" -eq 1 ]]; then
    prefer="ipv6"
    info "检测到 IPv6 出口可用：解析优先走 IPv6。"
  else
    warn "未检测到 IPv6 出口：解析优先走 IPv4。"
  fi

  cat > "${CONF_FILE}" <<EOF
services:
  - name: ${SERVICE_NAME}
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

  info "配置文件已写入：${CONF_FILE}"
}

# ============================================================
# 11) systemd 服务
# ============================================================
write_systemd_service() {
  cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=${SERVICE_NAME} (SOCKS5 proxy via gost)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_BIN} -C ${CONF_FILE}
Restart=on-failure
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  info "systemd 服务文件已写入：${SYSTEMD_FILE}"
}

start_service_fresh() {
  sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

wait_listening() {
  local i
  for i in $(seq 1 40); do
    if ss -lnt 2>/dev/null | grep -qE "[:.]${SOCKS_PORT}\b"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

assert_listening() {
  if wait_listening; then
    ok "已检测到端口 ${SOCKS_PORT} 正在监听。"
    return 0
  fi

  warn "监听检测失败，输出服务状态/日志协助排错："
  systemctl --no-pager -l status "${SERVICE_NAME}" || true
  journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
  die "部署失败：未检测到端口 ${SOCKS_PORT} 正在监听。"
}

# ============================================================
# 12) 公网 IP 获取 + 多 IPv6 输出
# ============================================================
get_public_ipv4() {
  local ip=""
  # NAT 小鸡一般有公网 IPv4（但网卡上是内网），因此必须外部查询
  ip="$(curl ${CURL_IPVER} -4 -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "${ip:-}" ]] || ip="$(curl ${CURL_IPVER} -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n' || true)"
  echo "${ip:-}"
}

get_public_ipv6_via_http() {
  local ip6=""
  ip6="$(curl ${CURL_IPVER} -6 -fsS --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  echo "${ip6:-}"
}

get_ipv6_on_iface() {
  # 输出 scope global 的 IPv6，过滤 ULA(fdxx) 与 link-local(fe80)
  ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6/ {print $2}' \
    | cut -d/ -f1 \
    | grep -vE '^(fe80:|::1$)' \
    | grep -vE '^fd' \
    | sort -u || true
}

merge_ipv6_list() {
  local local_list http_one
  local_list="$(get_ipv6_on_iface)"
  http_one="$(get_public_ipv6_via_http)"
  {
    [[ -n "${local_list:-}" ]] && echo "${local_list}"
    [[ -n "${http_one:-}" ]] && echo "${http_one}"
  } | awk 'NF' | sort -u
}

# ============================================================
# 13) 本机自动测试（直接输出结果）
# ============================================================
run_local_tests() {
  echo
  echo "${BOLD}================ 本机自动测试 ================${RESET}"

  if ss -lnt 2>/dev/null | grep -qE "[:.]${SOCKS_PORT}\b"; then
    ok "监听检测：端口 ${SOCKS_PORT} 已监听"
  else
    die "监听检测失败：端口 ${SOCKS_PORT} 未监听"
  fi

  # 测试 SOCKS5 IPv4 出口（哪怕 IPv4-only 也可以通过代理访问 IPv4 网站）
  local out4=""
  out4="$(curl -fsS --max-time 10 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "${out4:-}" ]]; then
    ok "SOCKS5 -> IPv4 出口：通（出口 IPv4 = ${out4}）"
  else
    warn "SOCKS5 -> IPv4 出口：不通（某些 IPv6-only 环境可能正常）"
  fi

  # 测试 SOCKS5 IPv6 出口
  local out6=""
  out6="$(curl -fsS --max-time 10 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://ipv6.icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  if [[ -n "${out6:-}" ]]; then
    ok "SOCKS5 -> IPv6 出口：通（出口 IPv6 = ${out6}）"
  else
    warn "SOCKS5 -> IPv6 出口：不通（目标站点或出口策略不同）"
  fi

  # nc 本机端口测试
  if nc -vz 127.0.0.1 "${SOCKS_PORT}" >/dev/null 2>&1; then
    ok "nc 本机端口测试：通（127.0.0.1:${SOCKS_PORT}）"
  else
    warn "nc 本机端口测试：不通（通常不影响 SOCKS5 可用性）"
  fi
}

# ============================================================
# 14) 最终输出（连接串 + 一键复制测试命令）
# ============================================================
final_output() {
  local pub4="$1"
  local ipv6_list="$2"

  echo
  echo "${BOLD}================ 部署完成 ================${RESET}"
  echo "服务名称：${SERVICE_NAME}（systemd）"
  echo "内部监听端口（VPS 内部端口）：${SOCKS_PORT}"
  echo

  if [[ "${IPV6_EGRESS}" -eq 1 ]]; then
    echo "IPv6 出口状态：通"
  else
    echo "IPv6 出口状态：不通"
  fi

  echo
  if [[ -n "${pub4:-}" ]]; then
    echo "${GREEN}${BOLD}公网 IPv4：${pub4}${RESET}"
    echo "${YELLOW}注意：NAT 小鸡 IPv4 必须做端口映射：公网IPv4:外部端口 ---> 本机:${SOCKS_PORT}${RESET}"
    echo "${GREEN}${BOLD}IPv4 连接串（端口为示例，请换成 NAT 外部映射端口）：${RESET}"
    echo "${GREEN}${BOLD}socks5://${pub4}:${SOCKS_PORT}${RESET}"
  else
    warn "未获取到公网 IPv4（IPv6-only 环境可能正常）"
  fi

  echo
  if [[ -n "${ipv6_list:-}" ]]; then
    echo "${GREEN}${BOLD}检测到以下公网 IPv6（可用于直连 SOCKS5）：${RESET}"
    echo "${YELLOW}提示：IPv6 必须写成 socks5://[IPv6]:端口（IPv6 外面必须带 []）${RESET}"
    echo
    while IFS= read -r ip6; do
      [[ -z "${ip6:-}" ]] && continue
      echo "${GREEN}${BOLD}socks5://[${ip6}]:${SOCKS_PORT}${RESET}"
    done <<< "${ipv6_list}"
  else
    warn "未检测到可用公网 IPv6（可能只有内网 ULA(fdxx) 或未开放入站）"
  fi

  echo
  echo "${BOLD}================ 一键复制测试命令 ================${RESET}"
  cat <<EOF
# ✅ VPS 本机测试（复制整段执行）
ss -lntp | grep ${SOCKS_PORT} || true
curl -v -x socks5h://127.0.0.1:${SOCKS_PORT} https://api.ipify.org && echo
curl -v -x socks5h://127.0.0.1:${SOCKS_PORT} https://ipv6.icanhazip.com && echo

# ✅ 外网测试（如你有公网 IPv6 可直连）
# nc -vz <你的IPv6> ${SOCKS_PORT}
# curl -vv --socks5-hostname "[<你的IPv6>]:${SOCKS_PORT}" https://api.ipify.org
EOF
}

# ============================================================
# 主流程
# ============================================================
main() {
  need_root
  ensure_dns_basics
  detect_stack
  dns_probe_or_fix

  ask_port
  install_deps
  detect_arch

  force_cleanup_all
  check_ipv6_egress

  download_and_install_gost
  write_gost_config
  write_systemd_service
  start_service_fresh
  assert_listening

  run_local_tests

  local pub4 ipv6_list
  pub4="$(get_public_ipv4 || true)"
  ipv6_list="$(merge_ipv6_list || true)"

  final_output "${pub4}" "${ipv6_list}"
}

main "$@"
