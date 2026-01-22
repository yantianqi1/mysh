#!/usr/bin/env bash
# ============================================================
# nat-socks.sh  (Debian/Ubuntu)
# 一键部署 gost SOCKS5 + HTTP 代理（无认证）——适配 NAT / IPv6-only / 低配 VPS
#
# ✅ 只需输入一个参数：SOCKS5 内部监听端口
# ✅ HTTP 代理端口自动生成：SOCKS5端口 + 1
# ✅ 强制覆盖安装：清理旧服务/旧进程/旧配置
# ✅ gost 单监听双栈 [::]:PORT（同时支持 IPv4+IPv6）
# ✅ IPv6 优先解析策略（有 IPv6 出口时 prefer=ipv6）
# ✅ 输出公网 IPv4 + 多公网 IPv6 连接串（SOCKS5 + HTTP）
# ✅ 自动安装依赖：curl/wget/tar/ca-certificates/netcat-openbsd
#    - APT 超时不轻易退出：curl+tar 存在则继续部署
# ✅ 双重 fallback：
#    - 版本获取：releases/latest 跳转解析；失败 -> FALLBACK_TAG
#    - 下载资产：GitHub 下载失败 -> ghproxy 镜像
#
# 服务名：nat-socks
# ============================================================

set -euo pipefail

# ------------------ 可改参数 ------------------
FALLBACK_TAG="v3.2.6"     # latest 解析失败就用它兜底（可改）
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

# ============================================================
# 1) 网络栈检测：决定 curl/apt 是否强制走 IPv6
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
# 2) DNS 自愈（针对 /etc/resolv.conf 缺失 / 解析抖动）
# ============================================================
ensure_dns_basics() {
  local hn
  hn="$(hostname 2>/dev/null || true)"
  if [[ -n "${hn:-}" ]] && [[ -f /etc/hosts ]]; then
    grep -qE "127\.0\.1\.1[[:space:]]+${hn}" /etc/hosts 2>/dev/null || echo "127.0.1.1 ${hn}" >> /etc/hosts 2>/dev/null || true
  fi

  if [[ -f /etc/nsswitch.conf ]]; then
    sed -i 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf 2>/dev/null || true
  fi

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
    warn "DNS 仍可能不稳定（github.com 解析失败）。后续若下载失败，请重点检查 DNS/网络。"
  fi
}

# ============================================================
# 3) 输入端口（兼容 | bash：从 /dev/tty 读取）
# ============================================================
ask_port() {
  local p=""
  echo
  echo "请输入 SOCKS5 监听端口（这是 VPS 内部端口，不是 NAT 外部映射端口）"

  if [[ -t 0 ]]; then
    read -r -p "SOCKS5 内部监听端口 (1-65535): " p
  else
    [[ -e /dev/tty ]] || die "当前环境无法交互输入（/dev/tty 不存在）。请先下载脚本再运行：wget -O nat-socks.sh ... && bash nat-socks.sh"
    read -r -p "SOCKS5 内部监听端口 (1-65535): " p < /dev/tty
  fi

  p="$(echo "$p" | tr -d ' \t\r\n')"
  [[ "$p" =~ ^[0-9]+$ ]] || die "端口必须是数字。"
  (( p >= 1 && p <= 65535 )) || die "端口范围必须是 1-65535。"
  SOCKS_PORT="$p"

  # ✅ HTTP 代理端口自动生成（不新增交互）
  HTTP_PORT=$((SOCKS_PORT + 1))
  if (( HTTP_PORT > 65535 )); then
    die "HTTP 端口自动生成失败（SOCKS5端口+1 超过 65535），请换个 SOCKS5 端口。"
  fi
}

# ============================================================
# 4) 安装依赖（APT 超时兜底：curl+tar 存在则继续）
# ============================================================
install_deps() {
  info "正在安装依赖（curl, wget, tar, ca-certificates, netcat-openbsd）..."
  export DEBIAN_FRONTEND=noninteractive

  local need_pkgs=()
  command -v curl >/dev/null 2>&1 || need_pkgs+=("curl")
  command -v wget >/dev/null 2>&1 || need_pkgs+=("wget")
  command -v tar  >/dev/null 2>&1 || need_pkgs+=("tar")
  command -v nc   >/dev/null 2>&1 || need_pkgs+=("netcat-openbsd")
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || need_pkgs+=("ca-certificates")

  if [[ "${#need_pkgs[@]}" -eq 0 ]]; then
    ok "依赖已存在，跳过 apt 安装。"
    return 0
  fi

  local APT_STABLE_OPTS=(
    "-o" "Acquire::Retries=2"
    "-o" "Acquire::http::Timeout=12"
    "-o" "Acquire::https::Timeout=12"
  )

  if ! apt-get update -y "${APT_OPTS[@]}" "${APT_STABLE_OPTS[@]}" >/dev/null 2>&1; then
    warn "apt-get update 出现超时/失败（IPv6-only 常见），继续尝试安装依赖..."
  fi

  if apt-get install -y "${need_pkgs[@]}" "${APT_OPTS[@]}" "${APT_STABLE_OPTS[@]}" >/dev/null 2>&1; then
    ok "依赖已就绪（含 nc 测试工具）"
    return 0
  fi

  warn "依赖安装失败（很可能是 IPv6-only 到 apt 镜像不通/超时）"

  if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    warn "但检测到 curl/tar 已存在：继续部署（缺的工具会跳过，例如 nc 本机端口测试将跳过）"
    return 0
  fi

  die "依赖安装失败且缺少 curl/tar：无法继续。请先修复 apt 源/网络后重试。"
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
# 6) 强制清理旧残留（确保可覆盖安装）
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
# 7) 获取 gost 版本（不使用 api.github.com）
# ============================================================
get_latest_gost_tag() {
  local latest_url="https://github.com/go-gost/gost/releases/latest"
  local loc tag

  loc="$(curl ${CURL_IPVER} -fsSLI "${latest_url}" 2>/dev/null | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n1 | tr -d '\r' || true)"
  tag="$(echo "${loc:-}" | sed -n 's#.*tag/\(v[0-9.]\+\).*#\1#p' | head -n1 || true)"

  if [[ -n "${tag:-}" ]]; then
    echo "${tag}"
    return 0
  fi

  warn "无法通过 releases/latest 解析版本，使用 fallback 版本：${FALLBACK_TAG}"
  echo "${FALLBACK_TAG}"
}

# ============================================================
# 8) 下载并安装 gost（GitHub -> ghproxy fallback）
# ============================================================
download_and_install_gost() {
  local tag ver tarball url1 url2 tmpdir bin_path

  tag="$(get_latest_gost_tag)"
  ver="${tag#v}"
  tarball="gost_${ver}_linux_${GOST_ARCH}.tar.gz"

  url1="https://github.com/go-gost/gost/releases/download/${tag}/${tarball}"
  url2="https://ghproxy.com/${url1}"

  info "gost 目标版本：${tag}"
  info "下载地址(主)：${url1}"
  info "下载地址(备)：${url2}"

  tmpdir="$(mktemp -d)"

  if ! curl ${CURL_IPVER} -fL --retry 3 --retry-delay 1 --connect-timeout 8 --max-time 180 \
      -o "${tmpdir}/${tarball}" "${url1}" >/dev/null 2>&1; then
    warn "主下载失败，尝试备用镜像（ghproxy）..."
    curl ${CURL_IPVER} -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 240 \
      -o "${tmpdir}/${tarball}" "${url2}" >/dev/null 2>&1 \
      || { rm -rf "${tmpdir}" 2>/dev/null || true; die "下载 gost 失败：GitHub 与 ghproxy 都不可用"; }
  fi

  info "正在解压..."
  tar -xzf "${tmpdir}/${tarball}" -C "${tmpdir}" || { rm -rf "${tmpdir}"; die "解压失败"; }

  bin_path="$(find "${tmpdir}" -maxdepth 3 -type f -name gost -perm -111 2>/dev/null | head -n1 || true)"
  [[ -n "${bin_path:-}" ]] || { rm -rf "${tmpdir}"; die "解压后未找到 gost 可执行文件"; }

  install -m 0755 "${bin_path}" "${INSTALL_BIN}"
  "${INSTALL_BIN}" -V >/dev/null 2>&1 || { rm -rf "${tmpdir}"; die "gost 安装后运行失败"; }

  rm -rf "${tmpdir}" 2>/dev/null || true
  ok "已安装 gost：${INSTALL_BIN}"
}

# ============================================================
# 9) IPv6 出口检测（用于 prefer=ipv6）
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
# 10) 写 gost 配置（SOCKS5 + HTTP 两个服务）
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
  # SOCKS5 代理（无认证）
  - name: ${SERVICE_NAME}-socks5
    addr: "[::]:${SOCKS_PORT}"
    handler:
      type: socks5
    listener:
      type: tcp
    resolver: resolver-0

  # HTTP/HTTPS Forward Proxy（无认证）
  - name: ${SERVICE_NAME}-http
    addr: "[::]:${HTTP_PORT}"
    handler:
      type: http
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
Description=${SERVICE_NAME} (SOCKS5+HTTP proxy via gost)
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

wait_listening_port() {
  local port="$1"
  local i
  for i in $(seq 1 40); do
    if ss -lnt 2>/dev/null | grep -qE "[:.]${port}\b"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

assert_listening() {
  if wait_listening_port "${SOCKS_PORT}" && wait_listening_port "${HTTP_PORT}"; then
    ok "已检测到端口 ${SOCKS_PORT}(SOCKS5) 与 ${HTTP_PORT}(HTTP) 正在监听。"
    return 0
  fi

  warn "监听检测失败，输出服务状态/日志协助排错："
  systemctl --no-pager -l status "${SERVICE_NAME}" || true
  journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
  die "部署失败：未检测到端口监听（SOCKS5=${SOCKS_PORT}, HTTP=${HTTP_PORT}）"
}

# ============================================================
# 12) 公网 IP 获取 + 多 IPv6 输出
# ============================================================
get_public_ipv4() {
  local ip=""
  ip="$(curl ${CURL_IPVER} -4 -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "${ip:-}" ]] || ip="$(curl ${CURL_IPVER} -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \r\n' || true)"
  echo "${ip:-}"
}

get_public_ipv6_http() {
  local ip6=""
  ip6="$(curl ${CURL_IPVER} -6 -fsS --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  echo "${ip6:-}"
}

get_ipv6_global_all() {
  ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6/ {print $2}' \
    | cut -d/ -f1 \
    | grep -vE '^(fe80:|::1$)' \
    | grep -vE '^fd' \
    | sort -u || true
}

merge_ipv6_list() {
  local iface_list http_one
  iface_list="$(get_ipv6_global_all)"
  http_one="$(get_public_ipv6_http)"

  {
    [[ -n "${iface_list:-}" ]] && echo "${iface_list}"
    [[ -n "${http_one:-}" ]] && echo "${http_one}"
  } | awk 'NF' | sort -u
}

# ============================================================
# 13) 本机自动测试（SOCKS5 + HTTP）并输出结果
# ============================================================
run_local_tests() {
  echo
  echo "${BOLD}================ 本机自动测试 ================${RESET}"

  # SOCKS5 测 IPv4/IPv6
  local s4 s6
  s4="$(curl -fsS --max-time 10 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/dev/null || true)"
  [[ -n "${s4:-}" ]] && ok "SOCKS5 -> IPv4 出口：通（${s4}）" || warn "SOCKS5 -> IPv4 出口：不通（IPv6-only 环境可能正常）"

  s6="$(curl -fsS --max-time 10 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://ipv6.icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "${s6:-}" ]] && ok "SOCKS5 -> IPv6 出口：通（${s6}）" || warn "SOCKS5 -> IPv6 出口：不通"

  # HTTP 测 IPv4/IPv6（HTTP forward proxy）
  local h4 h6
  h4="$(curl -fsS --max-time 10 -x "http://127.0.0.1:${HTTP_PORT}" https://api.ipify.org 2>/dev/null || true)"
  [[ -n "${h4:-}" ]] && ok "HTTP -> IPv4 出口：通（${h4}）" || warn "HTTP -> IPv4 出口：不通（IPv6-only 环境可能正常）"

  h6="$(curl -fsS --max-time 10 -x "http://127.0.0.1:${HTTP_PORT}" https://ipv6.icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  [[ -n "${h6:-}" ]] && ok "HTTP -> IPv6 出口：通（${h6}）" || warn "HTTP -> IPv6 出口：不通"

  # nc 端口测试
  if command -v nc >/dev/null 2>&1; then
    nc -vz 127.0.0.1 "${SOCKS_PORT}" >/dev/null 2>&1 && ok "nc 端口检测：SOCKS5 通（127.0.0.1:${SOCKS_PORT}）" || warn "nc 端口检测：SOCKS5 不通"
    nc -vz 127.0.0.1 "${HTTP_PORT}"  >/dev/null 2>&1 && ok "nc 端口检测：HTTP 通（127.0.0.1:${HTTP_PORT}）"  || warn "nc 端口检测：HTTP 不通"
  else
    warn "nc 未安装：跳过 nc 端口测试（不影响使用）"
  fi
}

# ============================================================
# 14) 最终输出（SOCKS5 + HTTP 两种连接串）
# ============================================================
final_output() {
  local pub4="$1"
  local ipv6_list="$2"

  echo
  echo "${BOLD}================ 部署完成 ================${RESET}"
  echo "服务名称：${SERVICE_NAME}（systemd）"
  echo "内部监听端口：SOCKS5=${SOCKS_PORT} / HTTP=${HTTP_PORT}"
  echo

  if [[ "${IPV6_EGRESS}" -eq 1 ]]; then
    echo "IPv6 出口状态：通"
  else
    echo "IPv6 出口状态：不通"
  fi

  echo
  if [[ -n "${pub4:-}" ]]; then
    echo "${GREEN}${BOLD}公网 IPv4：${pub4}${RESET}"
    echo "${YELLOW}注意：NAT 小鸡 IPv4 必须做端口映射：公网IPv4:外部端口 ---> 本机:${SOCKS_PORT}(SOCKS5) / ${HTTP_PORT}(HTTP)${RESET}"
    echo

    echo "${GREEN}${BOLD}IPv4 连接串（端口为示例，请换成 NAT 外部映射端口）：${RESET}"
    echo "${GREEN}${BOLD}SOCKS5: socks5://${pub4}:${SOCKS_PORT}${RESET}"
    echo "${GREEN}${BOLD}HTTP  : http://${pub4}:${HTTP_PORT}${RESET}"
  else
    warn "未获取到公网 IPv4（IPv6-only 环境可能正常）"
  fi

  echo
  if [[ -n "${ipv6_list:-}" ]]; then
    echo "${GREEN}${BOLD}检测到以下公网 IPv6（可用于直连代理）：${RESET}"
    echo "${YELLOW}提示：IPv6 必须写成 [IPv6]（外面必须带 []）${RESET}"
    echo
    while IFS= read -r ip6; do
      [[ -z "${ip6:-}" ]] && continue
      echo "${GREEN}${BOLD}SOCKS5: socks5://[${ip6}]:${SOCKS_PORT}${RESET}"
      echo "${GREEN}${BOLD}HTTP  : http://[${ip6}]:${HTTP_PORT}${RESET}"
      echo
    done <<< "${ipv6_list}"
  else
    warn "未检测到网卡绑定的公网 IPv6（可能只绑定了 ULA(fdxx) 或未配置 /128）。"
  fi

  echo
  echo "${BOLD}================ 一键复制测试命令 ================${RESET}"
  cat <<EOF
# ✅ VPS 本机测试（复制整段执行）
ss -lntp | grep -E ':${SOCKS_PORT}|:${HTTP_PORT}' || true

# SOCKS5 测试
curl -fsS --max-time 8 -x socks5h://127.0.0.1:${SOCKS_PORT} https://api.ipify.org && echo
curl -fsS --max-time 8 -x socks5h://127.0.0.1:${SOCKS_PORT} https://ipv6.icanhazip.com && echo

# HTTP 代理测试
curl -fsS --max-time 8 -x http://127.0.0.1:${HTTP_PORT} https://api.ipify.org && echo
curl -fsS --max-time 8 -x http://127.0.0.1:${HTTP_PORT} https://ipv6.icanhazip.com && echo

# ✅ 外网 IPv6 测试（如你可直连公网 IPv6）
# nc -vz <你的IPv6> ${SOCKS_PORT}
# nc -vz <你的IPv6> ${HTTP_PORT}
# curl -vv --socks5-hostname "[<你的IPv6>]:${SOCKS_PORT}" https://api.ipify.org
# curl -vv -x "http://[<你的IPv6>]:${HTTP_PORT}" https://api.ipify.org
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
