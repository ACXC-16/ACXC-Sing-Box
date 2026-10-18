#!/usr/bin/env bash
# =============================================================================
#  ACXC-SINGBOX 一键协议脚本 —— 基于 sing-box 的服务端协议管理器
#  版本: 0.1.0
#  许可: MIT
# -----------------------------------------------------------------------------
#  独立运行：
#      bash acxc-singbox.sh
#
#  设计原则：
#    * 一个"节点"= 一个协议实例 = 独立端口 + 独立凭据 + 独立备注，同协议可开 N 个
#    * 一个节点一个配置文件（/etc/sing-box/conf.d/in-<名字>.json），加删互不影响
#    * state 是真相（/etc/acxc-singbox/nodes/），conf.d 是渲染产物，--render 可全量重建
#    * 任何改动都走 备份 → 渲染 → sing-box check → 热重载 → 验活，失败自动还原
#    * 函数只 return 不 exit；所有全局变量 SBX_ 前缀，所有函数 sbx_ 前缀
#      —— 这样将来能原样拼进 ACXC-VPS-ONECLICK 的 init.sh
# =============================================================================

# 注意：步骤函数通过表间接调用，lint 看不到调用点，会误报 SC2317
# shellcheck disable=SC2317

set -u
set -o pipefail

SCRIPT_NAME="ACXC-SINGBOX 一键协议脚本"
SCRIPT_VERSION="0.1.16"
# 脚本自身的更新源。留空 = 未配置（菜单里会提示），填 GitHub raw / release 直链即可启用自动更新
SCRIPT_UPDATE_URL="${ACXC_SBX_UPDATE_URL:-}"
SCRIPT_SELF_PATH="${ACXC_SBX_SELF:-/usr/local/share/acxc-singbox/singbox.sh}"
SBX_CMD_PATH="${ACXC_SBX_CMD:-/usr/local/bin/sb}"

# ---------------------------- 路径常量 ---------------------------------------
# 全部支持用环境变量覆盖：测试、以及在主脚本里嵌不同目录时都不用改代码
SBX_BIN="${ACXC_SBX_BIN:-/usr/local/bin/sing-box}"
SBX_DIR="${ACXC_SBX_DIR:-/etc/sing-box}"
SBX_CONF="$SBX_DIR/config.json"
SBX_CONFD="$SBX_DIR/conf.d"
SBX_CERTS="$SBX_DIR/certs"
SBX_HOP_NFT="$SBX_DIR/porthop.nft"

SBX_DATA="${ACXC_SBX_DATA:-/etc/acxc-singbox}"
SBX_NODES="$SBX_DATA/nodes"
SBX_SERVER="$SBX_DATA/server.json"
SBX_SUB="$SBX_DATA/sub"

SBX_UNIT="/etc/systemd/system/sing-box.service"
SBX_HOP_UNIT="/etc/systemd/system/singbox-porthop.service"
SBX_BACKUP_ROOT="${ACXC_SBX_BACKUP:-/root/acxc-vps-backup}"

LOG_FILE="${ACXC_SBX_LOG:-/var/log/acxc-singbox.log}"

# sing-box 版本：安装/升级时用。空 = 自动查最新
SBX_SB_VERSION="${ACXC_SBX_SB_VERSION:-1.14.3}"

# 默认值
SBX_DEFAULT_SNI="https://addons.mozilla.org/"    # Reality 伪装目标（会自动取出主机名）
SBX_DEFAULT_TLS_SNI="https://addons.mozilla.org/" # 自签证书协议的默认 CN/SNI
SBX_DEFAULT_HOP_RANGE="20000-30000"

# ---------------------------- 运行时状态 -------------------------------------
SBX_DRY_RUN=0
SBX_ASSUME_YES=0
SBX_TTY_OK=0
SBX_COLOR_OFF=0
SBX_EMBEDDED="${ACXC_SBX_EMBEDDED:-0}"
SBX_NO_ALTSCREEN="${ACXC_SBX_NO_ALTSCREEN:-0}"
SBX_ALT_SCREEN=0
SBX_SNAP=""
SBX_FAILED=0
SBX_REPLY=""

declare -a SBX_ARGS=()

# ============================== 输出与日志 ==================================
C_RST=''; C_BLD=''; C_DIM=''; C_GRN=''; C_YEL=''; C_RED=''; C_CYN=''

sbx_init_colors() {
  if [ "$SBX_COLOR_OFF" -eq 0 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GRN=$'\033[32m'
    C_YEL=$'\033[33m'; C_RED=$'\033[31m'; C_CYN=$'\033[36m'
  fi
}

# 日志函数无条件定义（下划线前缀，撞名概率极低）
_sbx_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_sbx_log() {
  [ -n "${LOG_FILE:-}" ] || return 0
  printf '%s [%s] %s\n' "$(_sbx_ts)" "$1" "$2" 2>/dev/null >>"$LOG_FILE"
  return 0
}

# 宿主（init.sh）已经定义了同名输出函数就直接用，保证嵌进去后观感一致
if ! declare -F info >/dev/null 2>&1; then
  info()  { printf '%s\n' "  ${C_CYN}[信息]${C_RST} $*"; _sbx_log INFO "$*"; }
  ok()    { printf '%s\n' "  ${C_GRN}[成功]${C_RST} $*"; _sbx_log OK "$*"; }
  warn()  { printf '%s\n' "  ${C_YEL}[注意]${C_RST} $*" >&2; _sbx_log WARN "$*"; }
  err()   { printf '%s\n' "  ${C_RED}[错误]${C_RST} $*" >&2; _sbx_log ERROR "$*"; }
fi

sbx_die() { err "$*"; return 1; }
sbx_title() { printf '\n%s\n' "  ${C_BLD}${C_CYN}==== $* ====${C_RST}"; _sbx_log TITLE "==== $* ===="; }

# 计算显示宽度（中文/全角按 2 列算）→ SBX_DW
SBX_DW=0
sbx_dw() {
  local s="$1" save_lc="${LC_ALL-}" ascii=""
  LC_ALL=C
  ascii="${s//[! -~]/}"
  SBX_DW=$(( ${#ascii} + ((${#s} - ${#ascii}) / 3) * 2 ))
  if [ -n "$save_lc" ]; then LC_ALL="$save_lc"; else unset LC_ALL; fi
}

# 按"显示列"补齐到指定宽度 → 结果放 $1 指定的变量（不能用 $( ) 取，尾部空格会被吃掉）
sbx_padv() { # $1=变量名 $2=文本 $3=宽度
  local n
  sbx_dw "$2"
  n=$(( $3 - SBX_DW ))
  [ "$n" -lt 0 ] && n=0
  printf -v "$1" '%s%*s' "$2" "$n" ""
}

sbx_kv() { # $1=标签 $2=值（按显示宽度对齐，中文标签也不会歪）
  local k
  sbx_padv k "$1" 16
  printf '  %s %s\n' "$k" "$2"
}
sbx_have() { command -v "$1" >/dev/null 2>&1; }

# 干跑：只打印不执行
sbx_run() {
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] $*${C_RST}"
    return 0
  fi
  _sbx_log CMD "$*"
  "$@"
}

sbx_prepare_log() {
  local dir
  [ -n "$LOG_FILE" ] || return 0
  dir="$(dirname "$LOG_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
  if ! { : 2>/dev/null >>"$LOG_FILE"; }; then
    LOG_FILE="/tmp/acxc-singbox.log"
    if ! { : 2>/dev/null >>"$LOG_FILE"; }; then LOG_FILE=""; fi
  fi
  [ -n "$LOG_FILE" ] && chmod 600 "$LOG_FILE" 2>/dev/null || true
  return 0
}

# ============================== 交互输入 ====================================
sbx_detect_tty() {
  SBX_TTY_OK=0
  [ "${ACXC_SBX_FORCE_STDIN:-0}" = "1" ] && return 0
  if ( : </dev/tty ) 2>/dev/null && ( : >/dev/tty ) 2>/dev/null; then
    SBX_TTY_OK=1
  fi
  return 0
}

# $1=提示语 $2=默认值 → SBX_REPLY（去首尾空白）
sbx_prompt() {
  local p="$1" d="${2-}" line=""
  # 无人值守：直接用默认值，不读输入
  if [ "$SBX_ASSUME_YES" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [自动回答] $p -> ${d:-<空>}${C_RST}"
    SBX_REPLY="$d"
    return 0
  fi
  if [ "$SBX_TTY_OK" -eq 1 ]; then
    if [ -n "$d" ]; then
      IFS= read -r -p "  $p（$d）: " line </dev/tty || return 1
    else
      IFS= read -r -p "  $p: " line </dev/tty || return 1
    fi
  else
    if [ -n "$d" ]; then
      IFS= read -r -p "  $p（$d）: " line || return 1
    else
      IFS= read -r -p "  $p: " line || return 1
    fi
  fi
  SBX_REPLY="$(sbx_trim "${line:-$d}")"
  return 0
}

sbx_trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# $1=问题 $2=默认值(y/n) → 0=是
sbx_ask_yn() {
  local q="$1" def="${2:-n}" hint ans
  if [ "$SBX_ASSUME_YES" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [自动回答] $q -> ${def}${C_RST}"
    [ "$def" = y ] && return 0 || return 1
  fi
  hint="[y/N]"; [ "$def" = y ] && hint="[Y/n]"
  while :; do
    sbx_prompt "$q $hint" "" || return 1
    ans="$SBX_REPLY"
    [ -n "$ans" ] || ans="$def"
    case "$ans" in
      y|Y|yes|YES|是) return 0 ;;
      n|N|no|NO|否)   return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

sbx_pause() {
  [ "$SBX_TTY_OK" -eq 1 ] || return 0
  [ "$SBX_ASSUME_YES" -eq 1 ] && return 0
  printf '\n'
  sbx_prompt "按回车继续" "" >/dev/null 2>&1 || true
  return 0
}

sbx_clear() {
  [ "$SBX_TTY_OK" -eq 1 ] || return 0
  [ "${ACXC_SBX_CLEAR_SCREEN:-1}" = "0" ] && return 0
  clear 2>/dev/null || printf '\033[2J\033[H'
  return 0
}

# ============================== 小工具 ======================================
sbx_valid_port() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

sbx_valid_name() {
  case "${1:-}" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 32 ] && [ "${#1}" -ge 1 ]
}

# 协议缩写，用于默认节点名 ACXC-SB-<缩写>
sbx_proto_short() {
  case "$1" in
    reality)     printf 'Reality' ;;
    hysteria2)   printf 'HY2' ;;
    shadowsocks) printf 'SS' ;;
    trojan)      printf 'Trojan' ;;
    *)           printf '%s' "$1" ;;
  esac
}

# 只向 stdout 输出密码
sbx_gen_password() {
  local len="${1:-20}" pw=""
  if [ -r /dev/urandom ]; then
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len")"
  fi
  [ "${#pw}" -ge "$len" ] || return 1
  printf '%s' "$pw"
}

sbx_gen_uuid() {
  if [ -x "$SBX_BIN" ] && "$SBX_BIN" generate uuid >/dev/null 2>&1; then
    "$SBX_BIN" generate uuid 2>/dev/null
    return 0
  fi
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi
  return 1
}

# 4 字节 short_id（8 位十六进制），Reality 要求是偶数位十六进制、不超过 16 位
sbx_gen_shortid() {
  local s=""
  if sbx_have openssl; then
    s="$(openssl rand -hex 4 2>/dev/null)"
  fi
  [ -n "$s" ] || s="$(date +%s | md5sum | cut -c1-8)"
  printf '%s' "$s"
}

# 2022 加密方式的密钥必须是指定长度的 base64
sbx_gen_ss_key() {
  local bytes="${1:-16}" k=""
  if sbx_have openssl; then
    k="$(openssl rand -base64 "$bytes" 2>/dev/null | tr -d '\r\n')"
  fi
  [ -n "$k" ] || return 1
  printf '%s' "$k"
}

# 引号包裹含 IPv6 的 host
sbx_url_host() {
  case "$1" in
    *:*) printf '[%s]' "$1" ;;
    *)   printf '%s' "$1" ;;
  esac
}

# 从用户输入里取出主机名：https://addons.mozilla.org/ → addons.mozilla.org
# 用户可能填 https://域名/、域名:8443、域名/path，统一归一化成裸域名
sbx_sni_host() {
  local s
  s="$(sbx_trim "${1-}")"
  s="${s#*://}"          # 去掉 scheme
  s="${s%%/*}"           # 去掉路径
  s="${s%%\?*}"
  s="${s%%\#*}"
  s="${s%%:*}"           # 去掉端口
  printf '%s' "$s"
}

# 随机一个空闲高位端口。
# 避开 20000-30000：那是 HY2 端口跳跃的默认段，节点监听在这个段里会被 DNAT 劫持
sbx_random_port() {
  local i=0 p
  while [ "$i" -lt 60 ]; do
    if [ $((RANDOM % 2)) -eq 0 ]; then
      p=$(( RANDOM % 10000 + 10000 ))     # 10000-19999
    else
      p=$(( RANDOM % 29000 + 31000 ))     # 31000-59999
    fi
    sbx_port_in_use "$p" both || { printf '%s' "$p"; return 0; }
    i=$((i + 1))
  done
  sbx_port_suggest 31000
}

# ============================== 系统 / 依赖 =================================
sbx_require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  if [ "$SBX_DRY_RUN" -eq 1 ] && [ "${ACXC_SBX_ALLOW_NONROOT:-0}" = "1" ]; then
    warn "非 root + dry-run：仅供本地演练"
    return 0
  fi
  err "需要 root 权限运行（请用 root 或 sudo）"
  return 1
}

sbx_os_pretty() {
  local p="unknown"
  if [ -r /etc/os-release ]; then
    p="$( (. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}") 2>/dev/null || printf 'unknown' )"
  fi
  printf '%s' "$p"
}

sbx_check_os() {
  if [ "$SBX_DRY_RUN" -eq 1 ]; then return 0; fi
  sbx_have apt-get || { err "本脚本只支持 Debian / Ubuntu（找不到 apt-get）"; return 1; }
  return 0
}

# 依赖：jq 是硬依赖（渲染配置）；curl/openssl 基本都有
sbx_check_deps() {
  local missing=""
  sbx_have jq      || missing="$missing jq"
  sbx_have curl    || missing="$missing curl"
  sbx_have openssl || missing="$missing openssl"
  [ -z "$missing" ] && return 0
  warn "缺少依赖：${missing# }"
  if [ "$SBX_ASSUME_YES" -eq 0 ]; then
    if ! sbx_ask_yn "现在用 apt 安装${missing# }？" y; then
      err "缺少依赖无法继续"
      return 1
    fi
  fi
  # shellcheck disable=SC2086
  sbx_run env DEBIAN_FRONTEND=noninteractive apt-get install -y $missing || {
    err "依赖安装失败"; return 1; }
  ok "依赖已安装"
  return 0
}

# ============================== systemd / 服务 ==============================
sbx_svc_active() { systemctl is-active --quiet sing-box 2>/dev/null; }

sbx_sb_installed() { [ -x "$SBX_BIN" ]; }

sbx_sb_version() {
  [ -x "$SBX_BIN" ] || return 1
  local v
  v="$("$SBX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}')"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

sbx_unit_write() {
  local tmp
  tmp="$(mktemp)" || return 1
  cat >"$tmp" <<EOF
[Unit]
Description=sing-box service (ACXC-SINGBOX)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$SBX_BIN run -c $SBX_CONF -C $SBX_CONFD
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 $SBX_UNIT：${C_RST}"
    sed 's/^/    /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  install -m 644 "$tmp" "$SBX_UNIT" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  systemctl daemon-reload 2>/dev/null || true
  return 0
}

# ============================== 基础配置 ====================================
sbx_base_config_write() {
  local tmp
  tmp="$(mktemp)" || return 1
  jq -n '{log:{level:"info",timestamp:true,output:"/var/log/sing-box.log"},
          outbounds:[{type:"direct",tag:"direct"}]}' >"$tmp" || { rm -f "$tmp"; return 1; }
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 $SBX_CONF：${C_RST}"
    sed 's/^/    /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  install -m 600 "$tmp" "$SBX_CONF" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# 确保目录结构与基座配置就位
sbx_layout_init() {
  local d
  for d in "$SBX_DIR" "$SBX_CONFD" "$SBX_CERTS" "$SBX_DATA" "$SBX_NODES" "$SBX_SUB"; do
    [ -d "$d" ] || sbx_run mkdir -p "$d" || return 1
  done
  [ "$SBX_DRY_RUN" -eq 1 ] && return 0
  chmod 700 "$SBX_DATA" "$SBX_NODES" 2>/dev/null || true
  chmod 600 "$SBX_CONFD"/*.json 2>/dev/null || true
  [ -f "$SBX_CONF" ] || sbx_base_config_write || return 1
  [ -f "$SBX_SERVER" ] || sbx_server_init || return 1
  return 0
}

# ============================== 服务器信息 ==================================
sbx_server_init() {
  local tmp
  tmp="$(mktemp)" || return 1
  jq -n --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
    '{schema:1,public_ip:"",domain:"",sni_default:"'"$SBX_DEFAULT_SNI"'",updated:$ts}' >"$tmp" || return 1
  if [ "$SBX_DRY_RUN" -eq 1 ]; then rm -f "$tmp"; return 0; fi
  install -m 600 "$tmp" "$SBX_SERVER" && rm -f "$tmp"
}

sbx_server_get() { # $1=键
  [ -r "$SBX_SERVER" ] || return 1
  jq -r --arg k "$1" '.[$k] // empty' "$SBX_SERVER" 2>/dev/null
}

sbx_server_set() { # $1=键 $2=值
  [ -r "$SBX_SERVER" ] || return 1
  local tmp
  tmp="$(mktemp)" || return 1
  jq --arg k "$1" --arg v "$2" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
     '.[$k]=$v | .updated=$ts' "$SBX_SERVER" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$SBX_SERVER" && chmod 600 "$SBX_SERVER" 2>/dev/null
}

# 探测公网 IP（多个源兜底）
sbx_detect_ip() {
  local ip="" u
  for u in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    [ -n "$ip" ] && break
    ip="$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d ' \r\n')"
    case "$ip" in
      ''|*[!0-9a-fA-F:.]*) ip="" ;;
    esac
  done
  [ -n "$ip" ] || return 1
  printf '%s' "$ip"
}

# 链接里使用的地址：节点覆盖 > server.public_ip > 现场探测
sbx_host_for() {
  local name="$1" h=""
  h="$(sbx_node_get "$name" host)"
  if [ -z "$h" ]; then
    h="$(sbx_server_get public_ip)"
  fi
  if [ -z "$h" ]; then
    h="$(sbx_detect_ip)" || return 1
    sbx_server_set public_ip "$h" >/dev/null 2>&1 || true
  fi
  printf '%s' "$h"
}

# ============================== 节点：读写 ==================================
sbx_node_file() { printf '%s/%s.json' "$SBX_NODES" "$1"; }
sbx_node_exists() { [ -f "$(sbx_node_file "$1")" ]; }

sbx_node_get() { # $1=名字 $2=键
  local f
  f="$(sbx_node_file "$1")"
  [ -r "$f" ] || return 1
  jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null
}

sbx_node_set() { # $1=名字 $2=键 $3=值
  local f tmp
  f="$(sbx_node_file "$1")"
  [ -r "$f" ] || return 1
  tmp="$(mktemp)" || return 1
  jq --arg k "$2" --arg v "$3" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
     '.[$k]=$v | .updated=$ts' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" && chmod 600 "$f" 2>/dev/null
}

# 节点名列表（按创建时间排序，列表编号用这个顺序）
sbx_node_names() {
  local f
  for f in "$SBX_NODES"/*.json; do
    [ -e "$f" ] || continue
    basename "$f" .json
  done
}

sbx_node_count() {
  local n=0 f
  for f in "$SBX_NODES"/*.json; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

sbx_proto_label() {
  case "$1" in
    reality)     printf 'VLESS+TCP+XTLS Vision+Reality' ;;
    hysteria2)   printf 'Hysteria2' ;;
    shadowsocks) printf 'SS2022' ;;
    trojan)      printf 'Trojan-TLS' ;;
    *)           printf '%s' "$1" ;;
  esac
}

# 下一个可用名字：<基础名>、<基础名>-2、<基础名>-3…
sbx_next_name() {
  local base="$1" n=2 c
  sbx_node_exists "$base" || { printf '%s' "$base"; return 0; }
  while [ "$n" -lt 100 ]; do
    c="${base}-${n}"
    sbx_node_exists "$c" || { printf '%s' "$c"; return 0; }
    n=$((n + 1))
  done
  return 1
}

# 端口是否被占用。
# $1=端口 $2=net（tcp|udp|both，缺省 both）
# 同端口不同协议允许共存：443/TCP 的 Reality 和 443/UDP 的 Hysteria2 可以同时开
sbx_proto_net() {
  case "$1" in
    hysteria2)   printf 'udp' ;;
    shadowsocks) printf 'both' ;;
    *)           printf 'tcp' ;;
  esac
}

sbx_net_overlap() { # $1 $2 → 0=会冲突
  [ "$1" = both ] || [ "$2" = both ] || [ "$1" = "$2" ]
}

# $1=tcp|udp $2=端口
sbx_ss_check() {
  local flag="-tln" p="$2"
  [ "$1" = udp ] && flag="-uln"
  if sbx_have ss; then
    ss "$flag" 2>/dev/null | awk 'NR>1{print $4}' | grep -Eq "[:.]${p}\$"
  elif sbx_have netstat; then
    netstat -tuln 2>/dev/null | awk 'NR>2{print $4}' | grep -Eq "[:.]${p}\$"
  else
    return 1
  fi
}

sbx_port_in_use() { # $1=端口 $2=net
  local p="$1" net="${2:-both}" f n nnet
  for f in "$SBX_NODES"/*.json; do
    [ -e "$f" ] || continue
    n="$(jq -r '.port // empty' "$f" 2>/dev/null)"
    [ "$n" = "$p" ] || continue
    nnet="$(sbx_proto_net "$(jq -r '.proto // ""' "$f" 2>/dev/null)")"
    sbx_net_overlap "$net" "$nnet" && return 0
  done
  case "$net" in
    tcp)  sbx_ss_check tcp "$p" ;;
    udp)  sbx_ss_check udp "$p" ;;
    *)    sbx_ss_check tcp "$p" || sbx_ss_check udp "$p" ;;
  esac
}

sbx_port_suggest() { # $1=起始端口
  local p="${1:-8443}" i=0
  while [ "$i" -lt 200 ]; do
    sbx_port_in_use "$p" || { printf '%s' "$p"; return 0; }
    p=$((p + 1))
    [ "$p" -gt 65000 ] && p=20000
    i=$((i + 1))
  done
  return 1
}

# ============================== 节点：新建 ==================================
# 统一写 state 的小工具
sbx_node_write() { # $1=JSON 文本（stdin 更安全，这里用文件）$2=目标
  local src="$1" dst="$2"
  [ -f "$src" ] || return 1
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 $dst：${C_RST}"
    sed 's/^/    /' "$src"
    return 0
  fi
  install -m 600 "$src" "$dst" || return 1
  return 0
}

# 生成 Reality 密钥对 → stdout "私钥 公钥"
sbx_reality_keypair() {
  local out pk pub
  [ -x "$SBX_BIN" ] || return 1
  out="$("$SBX_BIN" generate reality-keypair 2>/dev/null)" || return 1
  pk="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  pub="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}')"
  [ -n "$pk" ] && [ -n "$pub" ] || return 1
  printf '%s %s\n' "$pk" "$pub"
}

# 自签证书：$1=节点名 $2=CN/SNI → 生成 crt/key，输出 "crt key" 两个路径
sbx_self_signed() {
  local name="$1" cn="$2" crt="$SBX_CERTS/$1.crt" key="$SBX_CERTS/$1.key"
  sbx_have openssl || return 1
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将自签证书 CN=$cn → $crt / $key${C_RST}"
    printf '%s %s\n' "$crt" "$key"
    return 0
  fi
  mkdir -p "$SBX_CERTS" || return 1
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" \
    -keyout "$key" -out "$crt" >/dev/null 2>&1 || return 1
  chmod 600 "$key" "$crt" 2>/dev/null || true
  printf '%s %s\n' "$crt" "$key"
}

# ---- 各协议的"新建" ---------------------------------------------------------
# 参数：名字 端口 SNI 备注
sbx_add_reality() {
  local name="$1" port="$2" sni="$3" remark="$4"
  local uuid kp pk pub sid tmp
  uuid="$(sbx_gen_uuid)" || { err "生成 UUID 失败"; return 1; }
  kp="$(sbx_reality_keypair)" || { err "生成 Reality 密钥失败（sing-box 未安装？）"; return 1; }
  pk="${kp%% *}"; pub="${kp##* }"
  sid="$(sbx_gen_shortid)"
  tmp="$(mktemp)" || return 1
  jq -n --arg n "$name" --argjson p "$port" --arg sni "$sni" --arg r "$remark" \
        --arg u "$uuid" --arg pk "$pk" --arg pub "$pub" --arg sid "$sid" \
        --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
    '{schema:1,name:$n,proto:"reality",remark:$r,port:$p,host:"",hop:"",
      sni:$sni,flow:"xtls-rprx-vision",uuid:$u,private_key:$pk,public_key:$pub,
      short_id:$sid,created:$ts,updated:$ts}' >"$tmp" || { rm -f "$tmp"; return 1; }
  sbx_node_write "$tmp" "$(sbx_node_file "$name")" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# 参数：名字 端口 方法 备注
sbx_add_ss() {
  local name="$1" port="$2" method="$3" remark="$4"
  local bytes=16 pw tmp
  case "$method" in
    2022-blake3-aes-256-gcm) bytes=32 ;;
    2022-blake3-chacha20-poly1305) bytes=32 ;;
  esac
  pw="$(sbx_gen_ss_key "$bytes")" || { err "生成 SS 密钥失败"; return 1; }
  tmp="$(mktemp)" || return 1
  jq -n --arg n "$name" --argjson p "$port" --arg m "$method" --arg pw "$pw" \
        --arg r "$remark" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
    '{schema:1,name:$n,proto:"shadowsocks",remark:$r,port:$p,host:"",hop:"",
      method:$m,password:$pw,created:$ts,updated:$ts}' >"$tmp" || { rm -f "$tmp"; return 1; }
  sbx_node_write "$tmp" "$(sbx_node_file "$name")" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# 参数：名字 端口 SNI 备注 [证书路径] [私钥路径]
sbx_add_tls_proto() { # $1=proto $2=名字 $3=端口 $4=sni $5=备注 $6=crt $7=key
  local proto="$1" name="$2" port="$3" sni="$4" remark="$5" crt="${6-}" key="${7-}"
  local pw tmp
  pw="$(sbx_gen_password 24)" || { err "生成密码失败"; return 1; }
  if [ -z "$crt" ] || [ -z "$key" ]; then
    local pair
    pair="$(sbx_self_signed "$name" "$sni")" || { err "自签证书失败（需要 openssl）"; return 1; }
    crt="${pair%% *}"; key="${pair##* }"
  fi
  tmp="$(mktemp)" || return 1
  jq -n --arg n "$name" --argjson p "$port" --arg sni "$sni" --arg r "$remark" \
        --arg pw "$pw" --arg crt "$crt" --arg key "$key" --arg proto "$proto" \
        --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
    '{schema:1,name:$n,proto:$proto,remark:$r,port:$p,host:"",hop:"",
      sni:$sni,password:$pw,cert_path:$crt,key_path:$key,created:$ts,updated:$ts}' \
    >"$tmp" || { rm -f "$tmp"; return 1; }
  sbx_node_write "$tmp" "$(sbx_node_file "$name")" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

# ============================== 渲染：state → conf.d ========================
# 一个节点一个文件；文件名 in-<名字>.json
sbx_render_reality() { # $1=state 文件 $2=tag $3=端口
  local f="$1" tag="$2" port="$3"
  jq -n --arg tag "$tag" --argjson port "$port" \
    --arg uuid "$(jq -r '.uuid' "$f")" \
    --arg flow "$(jq -r '.flow // "xtls-rprx-vision"' "$f")" \
    --arg sni "$(jq -r '.sni' "$f")" \
    --arg pk "$(jq -r '.private_key' "$f")" \
    --arg sid "$(jq -r '.short_id' "$f")" \
    '{inbounds:[{
        type:"vless", tag:$tag, listen:"::", listen_port:$port,
        users:[{uuid:$uuid, flow:$flow}],
        tls:{enabled:true, server_name:$sni,
             reality:{enabled:true,
                      handshake:{server:$sni, server_port:443},
                      private_key:$pk, short_id:[$sid]}}}]}'
}

sbx_render_ss() {
  local f="$1" tag="$2" port="$3"
  # 注意：不要写 network:"tcp,udp"。sing-box 不认这种逗号写法（会报 unknown network），
  # 省略 network 字段时默认就是 tcp+udp，跟我们要的行为一致。
  jq -n --arg tag "$tag" --argjson port "$port" \
    --arg m "$(jq -r '.method' "$f")" \
    --arg pw "$(jq -r '.password' "$f")" \
    '{inbounds:[{type:"shadowsocks", tag:$tag, listen:"::", listen_port:$port,
                 method:$m, password:$pw}]}'
}

sbx_render_hy2() {
  local f="$1" tag="$2" port="$3" sni
  sni="$(jq -r '.sni' "$f")"
  jq -n --arg tag "$tag" --argjson port "$port" \
    --arg pw "$(jq -r '.password' "$f")" \
    --arg sni "$sni" \
    --arg crt "$(jq -r '.cert_path' "$f")" \
    --arg key "$(jq -r '.key_path' "$f")" \
    --arg masq "https://$sni/" \
    '{inbounds:[{type:"hysteria2", tag:$tag, listen:"::", listen_port:$port,
                 users:[{password:$pw}],
                 masquerade:$masq,
                 tls:{enabled:true, server_name:$sni,
                      certificate_path:$crt, key_path:$key}}]}'
}

sbx_render_trojan() {
  local f="$1" tag="$2" port="$3"
  jq -n --arg tag "$tag" --argjson port "$port" \
    --arg pw "$(jq -r '.password' "$f")" \
    --arg sni "$(jq -r '.sni' "$f")" \
    --arg crt "$(jq -r '.cert_path' "$f")" \
    --arg key "$(jq -r '.key_path' "$f")" \
    '{inbounds:[{type:"trojan", tag:$tag, listen:"::", listen_port:$port,
                 users:[{password:$pw}],
                 tls:{enabled:true, server_name:$sni,
                      certificate_path:$crt, key_path:$key}}]}'
}

sbx_render_node() { # $1=名字
  local name="$1" f proto port tag tmp
  f="$(sbx_node_file "$name")"
  [ -r "$f" ] || { warn "节点不存在：$name"; return 1; }
  proto="$(jq -r '.proto' "$f")"
  port="$(jq -r '.port' "$f")"
  tag="in-$name"
  tmp="$SBX_CONFD/in-$name.json.tmp"
  mkdir -p "$SBX_CONFD" 2>/dev/null || true
  case "$proto" in
    reality)     sbx_render_reality "$f" "$tag" "$port" >"$tmp" ;;
    shadowsocks) sbx_render_ss      "$f" "$tag" "$port" >"$tmp" ;;
    hysteria2)   sbx_render_hy2     "$f" "$tag" "$port" >"$tmp" ;;
    trojan)      sbx_render_trojan  "$f" "$tag" "$port" >"$tmp" ;;
    *) warn "未知协议类型：$proto"; rm -f "$tmp"; return 1 ;;
  esac
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 $SBX_CONFD/in-$name.json：${C_RST}"
    sed 's/^/    /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$SBX_CONFD/in-$name.json" || return 1
  return 0
}

# 全量重建 conf.d：删掉不再对应节点的文件，重渲染所有节点
sbx_render_all() {
  local name f base
  mkdir -p "$SBX_CONFD" 2>/dev/null || true
  for f in "$SBX_CONFD"/in-*.json; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .json)"; base="${base#in-}"
    sbx_node_exists "$base" || { [ "$SBX_DRY_RUN" -eq 1 ] || rm -f "$f"; }
  done
  for name in $(sbx_node_names); do
    sbx_render_node "$name" || return 1
  done
  return 0
}

# ============================== 校验 / 应用 / 回滚 ==========================
sbx_check_config() {
  local out rc=0
  [ -x "$SBX_BIN" ] || { warn "sing-box 未安装，跳过校验"; return 0; }
  out="$("$SBX_BIN" check -c "$SBX_CONF" -C "$SBX_CONFD" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err "配置校验失败："
    printf '%s\n' "$out" | sed 's/^/    /'
    return 1
  fi
  return 0
}

sbx_svc_reload() {
  if ! sbx_svc_active; then
    sbx_run systemctl start sing-box || return 1
    return 0
  fi
  if sbx_run systemctl reload sing-box 2>/dev/null; then return 0; fi
  sbx_run systemctl restart sing-box
}

# 等端口进入监听状态；$1=端口 $2=tcp|udp
sbx_wait_port() {
  local p="$1" proto="${2:-tcp}" i=0
  [ "$SBX_DRY_RUN" -eq 1 ] && return 0
  sbx_have ss || return 0
  while [ "$i" -lt 15 ]; do
    sbx_ss_check "$proto" "$p" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

sbx_snapshot() {
  # 已经有快照就不再拍：调用方在"改动 state 之前"先拍，sbx_apply 复用这一份
  [ -n "${SBX_SNAP:-}" ] && return 0
  SBX_SNAP="$SBX_DATA/.snap.$$"
  [ "$SBX_DRY_RUN" -eq 1 ] && return 0
  rm -rf "$SBX_SNAP"
  mkdir -p "$SBX_SNAP" || return 1
  [ -d "$SBX_NODES" ] && cp -a "$SBX_NODES" "$SBX_SNAP/nodes" 2>/dev/null
  [ -d "$SBX_CONFD" ] && cp -a "$SBX_CONFD" "$SBX_SNAP/conf.d" 2>/dev/null
  return 0
}

sbx_snapshot_drop() {
  [ -n "${SBX_SNAP:-}" ] || return 0
  [ -d "$SBX_SNAP" ] && rm -rf "$SBX_SNAP"
  SBX_SNAP=""
  return 0
}

sbx_rollback() {
  [ -n "${SBX_SNAP:-}" ] && [ -d "$SBX_SNAP" ] || { warn "没有可用快照，请手工检查"; return 1; }
  warn "正在还原改动前的配置…"
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将从 $SBX_SNAP 还原${C_RST}"
    return 0
  fi
  [ -d "$SBX_SNAP/nodes" ] && { rm -rf "$SBX_NODES"; mv "$SBX_SNAP/nodes" "$SBX_NODES"; } 
  [ -d "$SBX_SNAP/conf.d" ] && { rm -rf "$SBX_CONFD"; mv "$SBX_SNAP/conf.d" "$SBX_CONFD"; }
  rm -rf "$SBX_SNAP"; SBX_SNAP=""
  sbx_check_config >/dev/null 2>&1 || warn "还原后的配置仍校验失败，请手工检查"
  sbx_svc_reload >/dev/null 2>&1 || warn "还原后重载服务失败"
  ok "已回到改动前的状态"
  return 0
}

# 所有"改动类"操作都走这里：渲染 → 校验 → 重载 → 验活 → 失败回滚
# 调用前：① 先 sbx_snapshot 拍快照 ② 再改 state
sbx_apply() { # $1=说明 $2=期望监听的端口（可空）$3=tcp|udp
  local desc="$1" port="${2-}" proto="${3:-tcp}"
  sbx_snapshot || { err "创建快照失败"; return 1; }
  if ! sbx_render_all; then
    err "渲染配置失败"
    sbx_rollback
    return 1
  fi
  if ! sbx_check_config; then
    err "配置校验未通过，已放弃本次改动"
    sbx_rollback
    return 1
  fi
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将重载 sing-box 使 ${desc} 生效"
    sbx_snapshot_drop
    return 0
  fi
  if ! sbx_svc_reload; then
    err "重载服务失败"
    sbx_rollback
    return 1
  fi
  if ! sbx_svc_active; then
    err "服务未能保持运行"
    sbx_rollback
    return 1
  fi
  if [ -n "$port" ] && ! sbx_wait_port "$port" "$proto"; then
    err "端口 ${port}/${proto} 没有进入监听状态"
    sbx_rollback
    return 1
  fi
  sbx_snapshot_drop
  return 0
}

# ============================== 分享链接 ====================================
sbx_link_node() { # $1=名字 → stdout
  local name="$1" proto host port remark hop
  sbx_node_exists "$name" || return 1
  proto="$(sbx_node_get "$name" proto)"
  port="$(sbx_node_get "$name" port)"
  remark="$(sbx_node_get "$name" remark)"
  hop="$(sbx_node_get "$name" hop)"
  host="$(sbx_host_for "$name")" || { err "拿不到公网 IP，请用 --host 指定"; return 1; }
  [ -n "$remark" ] || remark="$name"
  local h url_h
  h="$(sbx_url_host "$host")"; url_h="$h"
  case "$proto" in
    reality)
      printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
        "$(sbx_node_get "$name" uuid)" "$url_h" "$port" \
        "$(sbx_node_get "$name" flow)" "$(sbx_node_get "$name" sni)" \
        "$(sbx_node_get "$name" public_key)" "$(sbx_node_get "$name" short_id)" "$remark"
      ;;
    shadowsocks)
      local ui
      ui="$(printf '%s:%s' "$(sbx_node_get "$name" method)" "$(sbx_node_get "$name" password)" \
            | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')"
      printf 'ss://%s@%s:%s#%s' "$ui" "$url_h" "$port" "$remark"
      ;;
    hysteria2)
      local extra=""
      [ -n "$hop" ] && extra="&mport=$hop"
      printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1%s#%s' \
        "$(sbx_node_get "$name" password)" "$url_h" "$port" \
        "$(sbx_node_get "$name" sni)" "$extra" "$remark"
      ;;
    trojan)
      printf 'trojan://%s@%s:%s?security=tls&sni=%s&insecure=1&type=tcp#%s' \
        "$(sbx_node_get "$name" password)" "$url_h" "$port" \
        "$(sbx_node_get "$name" sni)" "$remark"
      ;;
    *) return 1 ;;
  esac
}

# sing-box 客户端的 outbound 片段（最准，客户端导入不认链接时用这个）
sbx_client_json() { # $1=名字
  local name="$1" proto host port
  proto="$(sbx_node_get "$name" proto)"
  port="$(sbx_node_get "$name" port)"
  host="$(sbx_host_for "$name")" || return 1
  case "$proto" in
    reality)
      jq -n --arg tag "$name" --arg h "$host" --argjson p "$port" \
        --arg u "$(sbx_node_get "$name" uuid)" --arg sni "$(sbx_node_get "$name" sni)" \
        --arg pub "$(sbx_node_get "$name" public_key)" --arg sid "$(sbx_node_get "$name" short_id)" \
        --arg flow "$(sbx_node_get "$name" flow)" \
        '{type:"vless",tag:$tag,server:$h,server_port:$p,uuid:$u,flow:$flow,
          tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},
               reality:{enabled:true,public_key:$pub,short_id:$sid}}}'
      ;;
    shadowsocks)
      jq -n --arg tag "$name" --arg h "$host" --argjson p "$port" \
        --arg m "$(sbx_node_get "$name" method)" --arg pw "$(sbx_node_get "$name" password)" \
        '{type:"shadowsocks",tag:$tag,server:$h,server_port:$p,method:$m,password:$pw}'
      ;;
    hysteria2)
      jq -n --arg tag "$name" --arg h "$host" --argjson p "$port" \
        --arg pw "$(sbx_node_get "$name" password)" --arg sni "$(sbx_node_get "$name" sni)" \
        --arg hop "$(sbx_node_get "$name" hop)" \
        '{type:"hysteria2",tag:$tag,server:$h,server_port:$p,password:$pw,
          tls:{enabled:true,server_name:$sni,insecure:true}}
         + (if $hop == "" then {} else {server_ports:[($hop | sub("-"; ":"))]} end)'
      ;;
    trojan)
      jq -n --arg tag "$name" --arg h "$host" --argjson p "$port" \
        --arg pw "$(sbx_node_get "$name" password)" --arg sni "$(sbx_node_get "$name" sni)" \
        '{type:"trojan",tag:$tag,server:$h,server_port:$p,password:$pw,
          tls:{enabled:true,server_name:$sni,insecure:true}}'
      ;;
    *) return 1 ;;
  esac
}

sbx_qr() { # $1=内容
  local s="$1"
  if ! sbx_have qrencode; then
    info "二维码需要 qrencode"
    if [ "$SBX_ASSUME_YES" -eq 1 ] || sbx_ask_yn "现在安装 qrencode？" y; then
      sbx_run env DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode >/dev/null 2>&1 || true
    fi
  fi
  if ! sbx_have qrencode; then
    warn "未安装 qrencode，只显示链接"
    return 0
  fi
  printf '\n'
  printf '%s' "$s" | qrencode -t ANSIUTF8 2>/dev/null || warn "二维码渲染失败"
  printf '\n'
  return 0
}

# ---- Clash / mihomo 配置 ----------------------------------------------------
# YAML 里双引号字符串要转义：只保留安全字符，最省事
sbx_yaml_name() {
  local s="${1-}"
  s="${s//\"/}"
  s="${s//\\/}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

# 单个节点的 proxies 条目（带前导两空格，方便直接拼进 proxies:）
sbx_clash_proxy() { # $1=名字
  local name="$1" proto host port remark
  sbx_node_exists "$name" || return 1
  proto="$(sbx_node_get "$name" proto)"
  port="$(sbx_node_get "$name" port)"
  remark="$(sbx_yaml_name "$(sbx_node_get "$name" remark)")"
  host="$(sbx_host_for "$name")" || return 1
  case "$proto" in
    reality)
      cat <<EOF
  - name: "$remark"
    type: vless
    server: $host
    port: $port
    uuid: $(sbx_node_get "$name" uuid)
    network: tcp
    udp: true
    tls: true
    flow: $(sbx_node_get "$name" flow)
    servername: $(sbx_node_get "$name" sni)
    client-fingerprint: chrome
    reality-opts:
      public-key: $(sbx_node_get "$name" public_key)
      short-id: "$(sbx_node_get "$name" short_id)"
EOF
      ;;
    shadowsocks)
      cat <<EOF
  - name: "$remark"
    type: ss
    server: $host
    port: $port
    cipher: $(sbx_node_get "$name" method)
    password: "$(sbx_node_get "$name" password)"
    udp: true
EOF
      ;;
    hysteria2)
      cat <<EOF
  - name: "$remark"
    type: hysteria2
    server: $host
    port: $port
    password: "$(sbx_node_get "$name" password)"
    sni: $(sbx_node_get "$name" sni)
    skip-cert-verify: true
EOF
      if [ -n "$(sbx_node_get "$name" hop)" ]; then
        printf '    ports: "%s"\n' "$(sbx_node_get "$name" hop)"
      fi
      ;;
    trojan)
      cat <<EOF
  - name: "$remark"
    type: trojan
    server: $host
    port: $port
    password: "$(sbx_node_get "$name" password)"
    sni: $(sbx_node_get "$name" sni)
    udp: true
    skip-cert-verify: true
    client-fingerprint: chrome
EOF
      ;;
    *) return 1 ;;
  esac
}

# 完整可用的 mihomo 配置（订阅用）
sbx_clash_yaml() {
  local name n=0
  printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\n'
  printf 'proxies:\n'
  for name in $(sbx_node_names); do
    sbx_clash_proxy "$name"
    n=$((n + 1))
  done
  [ "$n" -eq 0 ] && printf '  []\n'
  printf 'proxy-groups:\n'
  printf '  - name: PROXY\n    type: select\n    proxies:\n'
  for name in $(sbx_node_names); do
    printf '      - "%s"\n' "$(sbx_yaml_name "$(sbx_node_get "$name" remark)")"
  done
  printf 'rules:\n  - MATCH,PROXY\n'
  return 0
}

# ============================== 端口跳跃（Hysteria2） =======================
# sing-box 不支持监听端口段，用 nftables 把一段 UDP 重定向到真实端口
sbx_hop_render() {
  local name range port out="" f n r p
  for f in "$SBX_NODES"/*.json; do
    [ -e "$f" ] || continue
    n="$(jq -r '.name' "$f")"
    r="$(jq -r '.hop // empty' "$f")"
    p="$(jq -r '.port' "$f")"
    [ -n "$r" ] || continue
    out="${out}    udp dport ${r} redirect to :${p}\n"
  done
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 $SBX_HOP_NFT：${C_RST}"
    printf "table inet sbx_hop {\n  chain prerouting {\n    type nat hook prerouting priority dstnat; policy accept;\n%b  }\n}\n" "$out" | sed 's/^/    /'
    return 0
  fi
  if [ -z "$out" ]; then
    rm -f "$SBX_HOP_NFT"
    return 0
  fi
  mkdir -p "$SBX_DIR" 2>/dev/null || true
  {
    printf 'table inet sbx_hop {\n'
    printf '  chain prerouting {\n'
    printf '    type nat hook prerouting priority dstnat; policy accept;\n'
    printf '%b' "$out"
    printf '  }\n'
    printf '}\n'
  } >"$SBX_HOP_NFT" || return 1
  chmod 600 "$SBX_HOP_NFT" 2>/dev/null || true
  return 0
}

sbx_hop_unit_write() {
  local tmp
  tmp="$(mktemp)" || return 1
  cat >"$tmp" <<EOF
[Unit]
Description=sing-box port hopping (ACXC-SINGBOX)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet sbx_hop
ExecStart=/usr/sbin/nft -f $SBX_HOP_NFT
ExecStop=-/usr/sbin/nft delete table inet sbx_hop

[Install]
WantedBy=multi-user.target
EOF
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] 将写入 $SBX_HOP_UNIT${C_RST}"
    rm -f "$tmp"
    return 0
  fi
  install -m 644 "$tmp" "$SBX_HOP_UNIT" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  systemctl daemon-reload 2>/dev/null || true
  return 0
}

# $1=名字 $2=端口段（如 20000-30000） 或 off
sbx_hop_apply() {
  local name="$1" range="$2"
  sbx_node_exists "$name" || { err "节点不存在：$name"; return 1; }
  [ "$(sbx_node_get "$name" proto)" = hysteria2 ] || {
    err "端口跳跃只对 Hysteria2 节点有效"; return 1; }
  if ! sbx_have nft; then
    warn "端口跳跃需要 nftables"
    if [ "$SBX_ASSUME_YES" -eq 1 ] || sbx_ask_yn "现在安装 nftables？" y; then
      sbx_run env DEBIAN_FRONTEND=noninteractive apt-get install -y nftables || {
        err "nftables 安装失败"; return 1; }
    else
      return 1
    fi
  fi

  if [ "$range" = off ]; then
    sbx_node_set "$name" hop "" || return 1
  else
    case "$range" in
      [0-9]*-[0-9]*) ;;
      *) err "端口段格式应为 20000-30000"; return 1 ;;
    esac
    local a b
    a="${range%%-*}"; b="${range##*-}"
    sbx_valid_port "$a" && sbx_valid_port "$b" && [ "$a" -lt "$b" ] || {
      err "端口段不合法：$range"; return 1; }
    [ $((b - a)) -le 20000 ] || { err "端口段太大（建议不超过 10000 个）"; return 1; }
    sbx_port_in_use "$a" udp && warn "端口段起点 ${a} 已被 UDP 占用（跳跃用不到它，继续）"
    sbx_node_set "$name" hop "$range" || return 1
  fi

  sbx_hop_render || return 1
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将写入并启用 ${SBX_HOP_UNIT}"
    return 0
  fi
  sbx_hop_unit_write || return 1
  # 一条跳跃规则都不剩了：把 unit 停掉，别让它拿着不存在的规则文件报错
  if [ ! -f "$SBX_HOP_NFT" ]; then
    systemctl disable --now singbox-porthop >/dev/null 2>&1 || true
    ok "端口跳跃已全部关闭"
    return 0
  fi
  systemctl enable singbox-porthop >/dev/null 2>&1 || true
  if ! systemctl restart singbox-porthop 2>/dev/null; then
    err "nftables 规则应用失败，已回退"
    sbx_node_set "$name" hop "" >/dev/null 2>&1 || true
    sbx_hop_render >/dev/null 2>&1 || true
    systemctl restart singbox-porthop >/dev/null 2>&1 || true
    return 1
  fi
  ok "端口跳跃已生效"
  return 0
}

# ============================== sing-box 安装 / 更新 ========================
sbx_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7)  printf 'armv7' ;;
    armv6l)        printf 'armv6' ;;
    i386|i686)     printf '386' ;;
    *) return 1 ;;
  esac
}

# $1=版本 → 下载并安装到 /usr/local/bin，成功返回 0
sbx_install_singbox() {
  local ver="$1" arch url tmpdir tarball bin flavour
  arch="$(sbx_arch)" || { err "不支持的架构：$(uname -m)"; return 1; }
  ver="${ver#v}"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
  info "下载 sing-box v${ver} (${arch})…"
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${C_DIM}  [dry-run] curl -fsSL $url${C_RST}"
    return 0
  fi
  tmpdir="$(mktemp -d)" || return 1
  tarball="$tmpdir/sb.tar.gz"
  if ! curl -fsSL --retry 2 --connect-timeout 15 "$url" -o "$tarball" 2>/dev/null; then
    warn "下载失败（网络或版本号不对）"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! tar -xzf "$tarball" -C "$tmpdir" 2>/dev/null; then
    warn "解压失败"
    rm -rf "$tmpdir"
    return 1
  fi
  bin="$(find "$tmpdir" -maxdepth 2 -type f -name 'sing-box' 2>/dev/null | head -1)"
  if [ -z "$bin" ]; then
    warn "压缩包里没找到 sing-box 二进制"
    rm -rf "$tmpdir"
    return 1
  fi
  chmod +x "$bin" 2>/dev/null || true
  # glibc 版本太老会跑不起来，这时换 musl 构建再试一次
  if ! "$bin" version >/dev/null 2>&1; then
    warn "glibc 构建无法运行，改用 musl 构建重试…"
    flavour="musl"
    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}-${flavour}.tar.gz"
    rm -rf "$tmpdir"; tmpdir="$(mktemp -d)" || return 1
    tarball="$tmpdir/sb.tar.gz"
    if ! curl -fsSL --retry 2 --connect-timeout 15 "$url" -o "$tarball" 2>/dev/null \
       || ! tar -xzf "$tarball" -C "$tmpdir" 2>/dev/null; then
      warn "musl 构建也下载/解压失败"
      rm -rf "$tmpdir"; return 1
    fi
    bin="$(find "$tmpdir" -maxdepth 2 -type f -name 'sing-box' | head -1)"
    chmod +x "$bin" 2>/dev/null || true
    if ! "$bin" version >/dev/null 2>&1; then
      warn "仍无法运行，放弃"
      rm -rf "$tmpdir"; return 1
    fi
  fi
  [ -x "$SBX_BIN" ] && cp -a "$SBX_BIN" "${SBX_BIN}.bak" 2>/dev/null
  install -m 755 "$bin" "$SBX_BIN" || { rm -rf "$tmpdir"; return 1; }
  rm -rf "$tmpdir"
  ok "sing-box 已安装：$("$SBX_BIN" version 2>/dev/null | head -1)"
  return 0
}

# sing-box 自己不会切日志，给它配一份 logrotate，免得长期跑把磁盘写满
SBX_LOGROTATE="/etc/logrotate.d/sing-box"
sbx_logrotate_write() {
  local tmp
  [ "$SBX_DRY_RUN" -eq 1 ] && { info "[dry-run] 将写入 $SBX_LOGROTATE"; return 0; }
  tmp="$(mktemp)" || return 1
  cat >"$tmp" <<'EOF'
/var/log/sing-box.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  install -m 644 "$tmp" "$SBX_LOGROTATE" 2>/dev/null || true
  rm -f "$tmp"
  return 0
}

sbx_cmd_install() {
  local ver="${SBX_SB_VERSION:-}"
  if sbx_sb_installed; then
    info "已安装：$("$SBX_BIN" version 2>/dev/null | head -1)"
    if [ "$SBX_ASSUME_YES" -eq 0 ] && ! sbx_ask_yn "是否重新安装 / 覆盖？" n; then
      return 0
    fi
  fi
  [ "$SBX_ASSUME_YES" -eq 0 ] && [ -z "$ver" ] && {
    sbx_prompt "要安装的版本号" "1.14.3" || return 1
    ver="$SBX_REPLY"
  }
  [ -n "$ver" ] || ver="1.14.3"
  sbx_install_singbox "$ver" || return 1
  sbx_layout_init || return 1
  sbx_unit_write || return 1
  sbx_logrotate_write || true
  if [ "$SBX_DRY_RUN" -eq 0 ]; then
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box || { err "启动失败，看日志：journalctl -u sing-box -n 30"; return 1; }
    sleep 1
    if sbx_svc_active; then
      ok "sing-box 已启动"
    else
      err "服务没起来，执行 10) 查看日志 排查"
      return 1
    fi
  fi
  return 0
}

# 用新版本二进制先校验现有配置，通过才替换
sbx_cmd_update_singbox() {
  local ver newbin tmpdir okflag=1
  ver="${SBX_SB_VERSION:-}"
  if [ "$SBX_ASSUME_YES" -eq 0 ]; then
    sbx_prompt "目标版本" "$SBX_SB_VERSION" || return 1
    [ -n "$SBX_REPLY" ] && ver="$SBX_REPLY"
  fi
  [ -n "$ver" ] || ver="$SBX_SB_VERSION"
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将下载 v${ver}，用新二进制 check 现有配置通过后替换"
    return 0
  fi
  tmpdir="$(mktemp -d)" || return 1
  local arch url
  arch="$(sbx_arch)" || { rm -rf "$tmpdir"; return 1; }
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
  info "下载 v${ver}…"
  if ! curl -fsSL --retry 2 --connect-timeout 15 "$url" -o "$tmpdir/sb.tar.gz" 2>/dev/null \
     || ! tar -xzf "$tmpdir/sb.tar.gz" -C "$tmpdir" 2>/dev/null; then
    err "下载失败"; rm -rf "$tmpdir"; return 1
  fi
  newbin="$(find "$tmpdir" -maxdepth 2 -type f -name 'sing-box' | head -1)"
  [ -n "$newbin" ] || { err "包里没有二进制"; rm -rf "$tmpdir"; return 1; }
  chmod +x "$newbin" 2>/dev/null || true
  info "用新版本校验现有配置…"
  if ! "$newbin" check -c "$SBX_CONF" -C "$SBX_CONFD" >/tmp/sbx-check.$$ 2>&1; then
    err "新版本不通过现有配置校验，已放弃升级："
    sed 's/^/    /' /tmp/sbx-check.$$ 2>/dev/null
    rm -f /tmp/sbx-check.$$; rm -rf "$tmpdir"; return 1
  fi
  rm -f /tmp/sbx-check.$$
  [ -x "$SBX_BIN" ] && cp -a "$SBX_BIN" "${SBX_BIN}.bak" 2>/dev/null
  install -m 755 "$newbin" "$SBX_BIN" || { rm -rf "$tmpdir"; return 1; }
  rm -rf "$tmpdir"
  if systemctl restart sing-box 2>/dev/null; then
    sleep 1
    if sbx_svc_active; then ok "已升级到 v${ver}"; return 0; fi
  fi
  warn "新版启动失败，回退到旧版本"
  [ -f "${SBX_BIN}.bak" ] && install -m 755 "${SBX_BIN}.bak" "$SBX_BIN"
  systemctl restart sing-box >/dev/null 2>&1 || true
  err "升级失败，已回退"
  [ "$okflag" -eq 0 ] && return 1
  return 1
}

# ============================== 节点：命令 ==================================
sbx_cmd_list() {
  local name i=0 n=0 c1 c2 c3 c4 c5
  sbx_screen_header "节点列表"
  sbx_padv c1 "编号" 4; sbx_padv c2 "名字" 22; sbx_padv c3 "协议" 32
  sbx_padv c4 "端口" 7; sbx_padv c5 "状态" 8
  printf '  %s %s %s %s %s 备注\n' "$c1" "$c2" "$c3" "$c4" "$c5"
  printf '  %s\n' "──────────────────────────────────────────────────────────────────────────"
  for name in $(sbx_node_names); do
    i=$((i + 1)); n=$((n + 1))
    local st="停止"
    sbx_svc_active && st="运行"
    sbx_padv c1 "$i" 4
    sbx_padv c2 "$name" 22
    sbx_padv c3 "$(sbx_proto_label "$(sbx_node_get "$name" proto)")" 32
    sbx_padv c4 "$(sbx_node_get "$name" port)" 7
    sbx_padv c5 "$st" 8
    printf '  %s %s %s %s %s %s\n' "$c1" "$c2" "$c3" "$c4" "$c5" "$(sbx_node_get "$name" remark)"
  done
  [ "$n" -eq 0 ] && printf '  （还没有节点，选 2) 添加协议）\n'
  printf '\n  %s输入编号查看详情，直接回车返回上级菜单%s\n\n' "$C_DIM" "$C_RST"
  return 0
}

# 按编号或名字找节点 → SBX_REPLY
sbx_resolve_node() {
  local arg="$1" i=0 name
  case "$arg" in
    ''|*[!0-9]*)
      if sbx_node_exists "$arg"; then SBX_REPLY="$arg"; return 0; fi
      return 1 ;;
  esac
  for name in $(sbx_node_names); do
    i=$((i + 1))
    [ "$i" -eq "$arg" ] && { SBX_REPLY="$name"; return 0; }
  done
  return 1
}

sbx_show_node() {
  local name="$1" link
  sbx_screen_header "节点：$name"
  sbx_kv "协议" "$(sbx_proto_label "$(sbx_node_get "$name" proto)")"
  sbx_kv "端口" "$(sbx_node_get "$name" port)"
  sbx_kv "备注" "$(sbx_node_get "$name" remark)"
  case "$(sbx_node_get "$name" proto)" in
    reality)
      sbx_kv "伪装域名" "$(sbx_node_get "$name" sni)"
      sbx_kv "UUID" "$(sbx_node_get "$name" uuid)"
      sbx_kv "公钥" "$(sbx_node_get "$name" public_key)"
      sbx_kv "short_id" "$(sbx_node_get "$name" short_id)"
      ;;
    shadowsocks)
      sbx_kv "加密" "$(sbx_node_get "$name" method)"
      sbx_kv "密码" "$(sbx_node_get "$name" password)"
      ;;
    hysteria2|trojan)
      sbx_kv "SNI" "$(sbx_node_get "$name" sni)"
      sbx_kv "密码" "$(sbx_node_get "$name" password)"
      local hop; hop="$(sbx_node_get "$name" hop)"
      [ -n "$hop" ] && sbx_kv "端口跳跃" "$hop"
      ;;
  esac
  printf '\n'
  link="$(sbx_link_node "$name")" || { warn "生成链接失败"; return 1; }
  printf '  %s分享链接%s\n' "$C_BLD" "$C_RST"
  printf '  %s\n\n' "$link"
  return 0
}

sbx_cmd_add() {
  local proto
  if ! sbx_sb_installed; then
    err "还没安装 sing-box，请先安装（交互菜单首次运行会提示，或 bash $0 --install）"
    return 1
  fi
  [ -n "${SBX_PROTO_HINT:-}" ] && proto="$SBX_PROTO_HINT"
  if [ -z "${proto:-}" ]; then
    sbx_screen_header "添加协议"
    printf '  %s1)%s %-32s%s（无需域名，推荐）%s\n' "$C_GRN" "$C_RST" "VLESS+TCP+XTLS Vision+Reality" "$C_DIM" "$C_RST"
    printf '  %s2)%s %-32s%s（UDP，抗丢包）%s\n' "$C_GRN" "$C_RST" "Hysteria2" "$C_DIM" "$C_RST"
    printf '  %s3)%s %-32s%s（兼容性最好）%s\n' "$C_GRN" "$C_RST" "Shadowsocks 2022" "$C_DIM" "$C_RST"
    printf '  %s4)%s %-32s%s（需要伪装域名）%s\n' "$C_GRN" "$C_RST" "Trojan + TLS" "$C_DIM" "$C_RST"
    printf '\n'
    sbx_prompt "请选择协议（1-4）" "" || return 1
    case "$SBX_REPLY" in
      1|reality|vless) proto="reality" ;;
      2|hy2|hysteria2) proto="hysteria2" ;;
      3|ss|shadowsocks) proto="shadowsocks" ;;
      4|trojan) proto="trojan" ;;
      *) err "无效选择：$SBX_REPLY"; return 1 ;;
    esac
  fi

  local base def_name name port def_port sni remark pnet
  # 默认端口一律随机，用户直接回车就用随机值，也可以自己填
  case "$proto" in
    reality|hysteria2|shadowsocks|trojan) def_port="$(sbx_random_port)" ;;
    *) err "未知协议：$proto"; return 1 ;;
  esac
  pnet="$(sbx_proto_net "$proto")"
  # 默认名字：ACXC-SB-Reality / ACXC-SB-HY2 / ACXC-SB-SS / ACXC-SB-Trojan，重名自动加 -2 -3
  base="${SBX_NAME_PREFIX:-ACXC-SB-$(sbx_proto_short "$proto")}"
  def_name="$(sbx_next_name "$base")"
  if [ -n "${SBX_ARG_NAME:-}" ]; then
    name="$SBX_ARG_NAME"
    info "节点名字：$name"
  else
    sbx_prompt "节点名字" "$def_name" || return 1
    name="${SBX_REPLY:-$def_name}"
  fi
  if ! sbx_valid_name "$name"; then err "名字不合法：$name"; return 1; fi
  if sbx_node_exists "$name"; then err "名字已存在：$name"; return 1; fi

  if [ -n "${SBX_PORT_HINT:-}" ]; then
    port="$SBX_PORT_HINT"
  else
    if sbx_port_in_use "$def_port" "$pnet"; then
      local alt; alt="$(sbx_port_suggest "$def_port")"
      warn "端口 $def_port（$pnet）已被占用，建议 $alt"
      def_port="$alt"
    fi
    sbx_prompt "端口" "$def_port" || return 1
    port="${SBX_REPLY:-$def_port}"
  fi
  if ! sbx_valid_port "$port"; then err "端口不合法：$port"; return 1; fi
  if sbx_port_in_use "$port" "$pnet"; then err "端口 $port（$pnet）已被占用"; return 1; fi
  # 同端口的另一个协议已被占：不冲突，提示一下（典型：443/TCP 的 Reality + 443/UDP 的 H2）
  local other=""
  case "$pnet" in tcp) other="udp" ;; udp) other="tcp" ;; esac
  if [ -n "$other" ] && sbx_port_in_use "$port" "$other"; then
    info "端口 $port 的 ${other} 已被别的节点占用，本节点走 ${pnet}，两者可以共存"
  fi

  # 不再单独问备注名：备注就是节点名字（分享链接 #后面显示的就是它）
  remark="${SBX_ARG_REMARK:-$name}"

  sbx_snapshot || { err "创建快照失败"; return 1; }
  case "$proto" in
    reality)
      sni="${SBX_SNI_HINT:-}"
      if [ -z "$sni" ]; then
        sbx_prompt "Reality 伪装域名" "$SBX_DEFAULT_SNI" || { sbx_snapshot_drop; return 1; }
        sni="${SBX_REPLY:-$SBX_DEFAULT_SNI}"
      fi
      sni="$(sbx_sni_host "$sni")"
      case "$sni" in
        ''|*[!A-Za-z0-9.-]*) err "伪装域名不合法：$sni"; sbx_snapshot_drop; return 1 ;;
      esac
      info "生成密钥并写入配置…（伪装目标：$sni）"
      sbx_add_reality "$name" "$port" "$sni" "$remark" || { sbx_snapshot_drop; return 1; }
      ;;
    shadowsocks)
      local method="2022-blake3-aes-128-gcm"
      info "生成密钥并写入配置…"
      sbx_add_ss "$name" "$port" "$method" "$remark" || { sbx_snapshot_drop; return 1; }
      ;;
    hysteria2|trojan)
      sni="${SBX_SNI_HINT:-}"
      if [ -z "$sni" ]; then
        sbx_prompt "证书域名 / SNI" "$SBX_DEFAULT_TLS_SNI" || { sbx_snapshot_drop; return 1; }
        sni="${SBX_REPLY:-$SBX_DEFAULT_TLS_SNI}"
      fi
      sni="$(sbx_sni_host "$sni")"
      case "$sni" in
        ''|*[!A-Za-z0-9.-]*) err "域名不合法：$sni"; sbx_snapshot_drop; return 1 ;;
      esac
      local crt="${SBX_CERT_HINT:-}" key="${SBX_KEY_HINT:-}"
      if [ -z "$crt" ]; then
        info "生成自签证书（CN=$sni）…"
      fi
      sbx_add_tls_proto "$proto" "$name" "$port" "$sni" "$remark" "$crt" "$key" \
        || { sbx_snapshot_drop; return 1; }
      ;;
  esac

  info "校验配置并热重载…"
  local net="tcp"
  [ "$proto" = hysteria2 ] && net="udp"
  if ! sbx_apply "添加节点 $name" "$port" "$net"; then
    err "添加失败，已回滚"
    return 1
  fi
  ok "节点 $name 已创建"
  { sbx_show_node "$name"; } || true
  return 0
}

sbx_cmd_del() { # $1=编号/名字，空格或逗号分隔；a=全部
  local arg="${1:-}" name
  sbx_screen_header "删除协议"
  if [ -z "$arg" ]; then
    sbx_cmd_list
    info "多个用空格分隔，例如 1 2 3；输入 a 删除全部"
    sbx_prompt "要删除的编号/名字" "" || return 1
    arg="$SBX_REPLY"
  fi
  if [ "$arg" = "a" ] || [ "$arg" = "A" ]; then
    sbx_ask_yn "确认删除全部节点？" n || { info "已取消"; return 0; }
    local all
    all="$(sbx_node_names)"
    [ -n "$all" ] || { info "没有节点"; return 0; }
    sbx_snapshot || return 1
    for name in $all; do rm -f "$(sbx_node_file "$name")"; done
    sbx_apply "删除全部节点" "" "tcp" || return 1
    ok "已删除全部节点"
    return 0
  fi
  local okd=0
  local -a targets=()
  sbx_snapshot || return 1
  # 先把编号全部解析成名字，再统一删。
  # 不能边解析边删：删掉一个之后编号会整体前移，"1 3" 会误删第 4 个。
  # 空格、逗号、中文逗号、分号都能当分隔符
  for name in $(printf '%s' "$arg" | sed 's/[,，;；]/ /g'); do
    [ -n "$name" ] || continue
    if ! sbx_resolve_node "$name"; then
      warn "找不到节点：$name"
      continue
    fi
    targets+=("$SBX_REPLY")
  done
  [ "${#targets[@]}" -gt 0 ] || { info "没有删除任何节点"; sbx_snapshot_drop; return 0; }
  for name in "${targets[@]}"; do
    # 命令行里点名删（--del hk01 --yes）视为明确意图，不再问；菜单里删仍然要确认
    if [ "$SBX_ASSUME_YES" -eq 0 ]; then
      sbx_ask_yn "确认删除节点 ${name}？" n || continue
    fi
    rm -f "$(sbx_node_file "$name")"
    okd=$((okd + 1))
  done
  [ "$okd" -gt 0 ] || { info "没有删除任何节点"; sbx_snapshot_drop; return 0; }
  sbx_apply "删除节点" "" "tcp" || return 1
  ok "已删除 ${okd} 个节点"
  return 0
}

sbx_cmd_port() { # $1=节点 $2=新端口
  local name="$1" port="$2"
  sbx_node_exists "$name" || { err "节点不存在：$name"; return 1; }
  [ -n "$port" ] || { err "缺少端口"; return 1; }
  sbx_valid_port "$port" || { err "端口不合法"; return 1; }
  if [ "$(sbx_node_get "$name" port)" = "$port" ]; then info "端口没变"; return 0; fi
  local pnet; pnet="$(sbx_proto_net "$(sbx_node_get "$name" proto)")"
  sbx_port_in_use "$port" "$pnet" && { err "端口 $port（$pnet）已被占用"; return 1; }
  sbx_snapshot || return 1
  sbx_node_set "$name" port "$port" || { sbx_snapshot_drop; return 1; }
  local net="tcp"
  [ "$pnet" = udp ] && net="udp"
  if ! sbx_apply "修改 $name 端口为 $port" "$port" "$net"; then
    err "改端口失败，已回滚"
    return 1
  fi
  ok "端口已改为 $port（旧链接失效，新链接密钥不变）"
  return 0
}

sbx_cmd_links() { # 全部链接
  local name out=""
  for name in $(sbx_node_names); do
    out="${out}$(sbx_link_node "$name" 2>/dev/null)
"
  done
  [ -n "$out" ] || { warn "没有可用的节点"; return 1; }
  printf '%s' "$out" | sed '/^$/d'
  if [ "$SBX_ASSUME_YES" -eq 0 ] && sbx_ask_yn "保存到 ${SBX_SUB}/links.txt？" y; then
    if [ "$SBX_DRY_RUN" -eq 1 ]; then
      info "[dry-run] 将写入 ${SBX_SUB}/links.txt"
    else
      mkdir -p "$SBX_SUB"
      printf '%s' "$out" | sed '/^$/d' >"$SBX_SUB/links.txt"
      chmod 600 "$SBX_SUB/links.txt"
      ok "已保存：$SBX_SUB/links.txt"
    fi
  fi
  return 0
}

# 订阅/汇总文件：clash 配置 或 全部链接
sbx_cmd_sub() { # $1=clash|links
  local fmt="${1:-clash}" out
  case "$fmt" in
    clash)
      out="$SBX_SUB/clash.yaml"
      if [ "$(sbx_node_count)" -eq 0 ]; then
        warn "还没有节点"
        return 1
      fi
      if [ "$SBX_DRY_RUN" -eq 1 ]; then
        info "[dry-run] 将生成 $out："
        sbx_clash_yaml | sed 's/^/    /'
        return 0
      fi
      mkdir -p "$SBX_SUB" || return 1
      sbx_clash_yaml >"$out.tmp" && mv -f "$out.tmp" "$out" || return 1
      chmod 600 "$out" 2>/dev/null || true
      ok "已生成：$out"
      info "把它下载到本地，用 Clash Verge / mihomo 直接导入"
      return 0
      ;;
    links)
      sbx_cmd_links
      return $?
      ;;
    *)
      err "未知格式：$fmt（可用：clash / links）"
      return 1
      ;;
  esac
}

# ============================== 服务 / 信息 =================================
sbx_cmd_service() { # $1=start|stop|restart|reload|status
  case "$1" in
    start)   sbx_run systemctl start sing-box && ok "已启动" ;;
    stop)    sbx_run systemctl stop sing-box && ok "已停止" ;;
    restart) sbx_run systemctl restart sing-box && ok "已重启" ;;
    reload)  sbx_svc_reload && ok "已热重载" ;;
    status)  ;;
    *) return 1 ;;
  esac
}

sbx_status_line() {
  local ver="未安装" st="未运行" sc="$C_YEL" c=0
  if sbx_sb_installed; then
    ver="$(sbx_sb_version 2>/dev/null)" || ver="?"
    if sbx_svc_active; then st="运行中"; sc="$C_GRN"; else st="已停止"; sc="$C_RED"; fi
  fi
  c="$(sbx_node_count)"
  printf '  %sv%s%s · sing-box %s · %s%s%s · %s 个节点\n' \
    "$C_DIM" "$SCRIPT_VERSION" "$C_RST" "$ver" "$sc" "$st" "$C_RST" "$c"
}

sbx_cmd_info() {
  local ip="" h
  sbx_screen_header "节点信息"
  sbx_kv "系统" "$(sbx_os_pretty)"
  sbx_kv "内核" "$(uname -r)"
  sbx_kv "架构" "$(uname -m)"
  ip="$(sbx_server_get public_ip)"
  [ -n "$ip" ] || { ip="$(sbx_detect_ip 2>/dev/null)"; [ -n "$ip" ] && sbx_server_set public_ip "$ip" >/dev/null 2>&1; }
  sbx_kv "公网 IP" "${ip:-探测失败（用 --host 指定）}"
  sbx_kv "节点数" "$(sbx_node_count)"
  if sbx_sb_installed; then
    sbx_kv "sing-box" "$(sbx_sb_version 2>/dev/null)"
    if sbx_svc_active; then
      sbx_kv "服务状态" "运行中"
      sbx_kv "启动时间" "$(systemctl show -p ActiveEnterTimestamp --value sing-box 2>/dev/null)"
    else
      sbx_kv "服务状态" "已停止"
    fi
  else
    sbx_kv "sing-box" "未安装"
  fi
  if [ -r /proc/meminfo ]; then
    sbx_kv "内存" "$(awk '/^MemTotal:/{printf "%.2f GB", $2/1048576}' /proc/meminfo)"
  fi
  if [ -r /proc/loadavg ]; then
    sbx_kv "负载" "$(cut -d' ' -f1-3 /proc/loadavg)"
  fi
  printf '\n'
  return 0
}

sbx_cmd_log() {
  local n="${1:-40}"
  sbx_screen_header "运行日志"
  if sbx_have journalctl; then
    printf '%s\n' "${C_BLD}最近 ${n} 行（journalctl -u sing-box）：${C_RST}"
    journalctl -u sing-box -n "$n" --no-pager 2>/dev/null || true
  fi
  if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
    printf '\n%s\n' "${C_BLD}脚本日志 ${LOG_FILE}：${C_RST}"
    tail -n 20 "$LOG_FILE" 2>/dev/null || true
  fi
  printf '\n'
  return 0
}

# ============================== 自检 ========================================
# 用临时目录把四种协议各渲染一份，交给 sing-box check。
# 不碰现有节点、不碰 systemd，纯离线验证「渲染出来的配置能不能被 sing-box 接受」
sbx_self_test() {
  local tmp rc=0 crt key kp pk pub ss_pw
  if ! sbx_sb_installed; then
    err "sing-box 还没装，无法自检"
    return 1
  fi
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/conf.d" "$tmp/nodes" "$tmp/certs" || { rm -rf "$tmp"; return 1; }
  printf '{"log":{"level":"warn"},"outbounds":[{"type":"direct","tag":"direct"}]}' >"$tmp/base.json"

  info "生成自签证书与密钥…"
  # 注意：这个子命令是把密钥和证书打印到 stdout，不会自己写文件，得手动分离
  "$SBX_BIN" generate tls-keypair -m 12 addons.mozilla.org >"$tmp/certs/pair.pem" 2>/dev/null
  awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/'     "$tmp/certs/pair.pem" >"$tmp/certs/private-key.pem"
  awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/'     "$tmp/certs/pair.pem" >"$tmp/certs/certificate.pem"
  crt="$tmp/certs/certificate.pem"; key="$tmp/certs/private-key.pem"
  if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
    err "自签证书生成失败（sing-box generate tls-keypair 没输出）"
    rm -rf "$tmp"
    return 1
  fi
  kp="$("$SBX_BIN" generate reality-keypair 2>/dev/null)"
  pk="$(printf '%s\n' "$kp" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  pub="$(printf '%s\n' "$kp" | awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}')"
  ss_pw="$(sbx_gen_ss_key 16)" || ss_pw="AAAAAAAAAAAAAAAAAAAAAA=="

  info "渲染四种协议配置…"
  jq -n --arg pk "$pk" --arg pub "$pub" \
    '{name:"selftest",proto:"reality",port:20001,sni:"addons.mozilla.org",
      flow:"xtls-rprx-vision",uuid:"11111111-2222-3333-4444-555555555555",
      private_key:$pk,public_key:$pub,short_id:"0123456789abcdef"}' \
    >"$tmp/nodes/reality.json"
  jq -n --arg pw "$ss_pw" \
    '{name:"selftest",proto:"shadowsocks",port:20002,method:"2022-blake3-aes-128-gcm",password:$pw}' \
    >"$tmp/nodes/ss.json"
  jq -n --arg c "$crt" --arg k "$key" \
    '{name:"selftest",proto:"hysteria2",port:20003,sni:"addons.mozilla.org",password:"selftest-pw",cert_path:$c,key_path:$k}' \
    >"$tmp/nodes/hy2.json"
  jq -n --arg c "$crt" --arg k "$key" \
    '{name:"selftest",proto:"trojan",port:20004,sni:"addons.mozilla.org",password:"selftest-pw",cert_path:$c,key_path:$k}' \
    >"$tmp/nodes/trojan.json"

  sbx_render_reality "$tmp/nodes/reality.json" "st-reality" 20001 >"$tmp/conf.d/in-reality.json" || rc=1
  sbx_render_ss      "$tmp/nodes/ss.json"      "st-ss"      20002 >"$tmp/conf.d/in-ss.json"      || rc=1
  sbx_render_hy2     "$tmp/nodes/hy2.json"     "st-hy2"     20003 >"$tmp/conf.d/in-hy2.json"     || rc=1
  sbx_render_trojan  "$tmp/nodes/trojan.json"  "st-trojan"  20004 >"$tmp/conf.d/in-trojan.json"  || rc=1

  if [ "$rc" -eq 0 ]; then
    local out
    if out="$("$SBX_BIN" check -c "$tmp/base.json" -C "$tmp/conf.d" 2>&1)"; then
      ok "自检通过：四种协议配置全部合法"
    else
      err "自检失败："
      printf '%s\n' "$out" | sed 's/^/    /'
      rc=1
    fi
  else
    err "渲染阶段就失败了"
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# ============================== 脚本自更新 ==================================
# 找一个含有本脚本的 git 仓库（默认 /opt/ACXC-Sing-Box）
sbx_repo_dir() {
  local d own own_dir
  for d in "${ACXC_SBX_REPO:-}" /opt/ACXC-Sing-Box; do
    [ -n "$d" ] || continue
    [ -d "$d/.git" ] && { printf '%s' "$d"; return 0; }
  done
  own="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  own_dir="$(dirname "$own")"
  [ -d "$own_dir/.git" ] && { printf '%s' "$own_dir"; return 0; }
  return 1
}

# 从本地 git 仓库更新：git pull 之后把仓库里的脚本装到标准位置
sbx_update_from_git() {
  local repo
  repo="$(sbx_repo_dir)" || return 1
  info "从本地仓库更新：$repo"
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    info "[dry-run] git -C $repo pull --ff-only"
    return 0
  fi
  if ! git -C "$repo" pull --ff-only 2>&1 | sed 's/^/    /'; then
    err "git pull 失败（本地有未提交改动？或网络不通）"
    return 1
  fi
  [ -f "$repo/acxc-singbox.sh" ] || { err "仓库里找不到 acxc-singbox.sh"; return 1; }
  sbx_cmd_update_script "$repo/acxc-singbox.sh"
}

sbx_cmd_update_script() { # $1=本地文件或 URL（可空 → 用 SCRIPT_UPDATE_URL）
  local src="${1:-$SCRIPT_UPDATE_URL}" tmp own newv oldv
  own="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  oldv="$SCRIPT_VERSION"
  if [ -z "$src" ]; then
    # 没配 URL：先试本地 git 仓库（你现在就是这种：脚本在 /opt/ACXC-Sing-Box 里）
    if sbx_have git && sbx_repo_dir >/dev/null 2>&1; then
      sbx_update_from_git
      return $?
    fi
    warn "没有找到更新源"
    info "方式一：把仓库克隆到 /opt/ACXC-Sing-Box，之后这里就能一键 git pull"
    info "方式二：bash $0 --update-script /path/to/new.sh"
    info "方式三：把地址填进脚本顶部的 SCRIPT_UPDATE_URL"
    return 1
  fi
  tmp="$(mktemp)" || return 1
  case "$src" in
    http://*|https://*)
      info "下载新版本：$src"
      if ! curl -fsSL --retry 2 --connect-timeout 20 "$src" -o "$tmp" 2>/dev/null; then
        err "下载失败"; rm -f "$tmp"; return 1
      fi
      ;;
    *)
      [ -f "$src" ] || { err "文件不存在：$src"; rm -f "$tmp"; return 1; }
      cp -f "$src" "$tmp" || { rm -f "$tmp"; return 1; }
      ;;
  esac
  # 校验：能通过语法检查、是这份脚本、版本号能读出来
  if ! bash -n "$tmp" 2>/dev/null; then
    err "下载到的文件语法不合法，已放弃（保留当前版本）"
    rm -f "$tmp"; return 1
  fi
  if ! grep -q '^SCRIPT_NAME=' "$tmp" 2>/dev/null; then
    err "下载到的文件不像是本脚本，已放弃"
    rm -f "$tmp"; return 1
  fi
  newv="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)"
  if [ -n "$newv" ] && [ "$newv" = "$oldv" ]; then
    info "已经是最新版（v$oldv）"
    rm -f "$tmp"; return 0
  fi
  if [ "$SBX_DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将把 $own 更新为 v${newv:-?}"
    rm -f "$tmp"; return 0
  fi
  # 安装位置是软链（指向仓库）时不用覆盖，git pull 已经生效
  if [ -L "$SCRIPT_SELF_PATH" ]; then
    info "安装位置是软链，已跟着仓库更新（重新运行生效）"
    rm -f "$tmp"
    return 0
  fi
  [ -f "$own" ] && cp -a "$own" "${own}.bak" 2>/dev/null
  mkdir -p "$(dirname "$SCRIPT_SELF_PATH")" 2>/dev/null || true
  if ! install -m 755 "$tmp" "$SCRIPT_SELF_PATH" 2>/dev/null; then
    install -m 755 "$tmp" "$own" || { err "写入失败"; rm -f "$tmp"; return 1; }
  fi
  rm -f "$tmp"
  chmod +x "$SCRIPT_SELF_PATH" 2>/dev/null || true
  ln -sf "$SCRIPT_SELF_PATH" "$SBX_CMD_PATH" 2>/dev/null || true
  [ -L /usr/local/bin/sbx ] && rm -f /usr/local/bin/sbx 2>/dev/null || true
  ok "脚本已更新：v${oldv} → v${newv:-未知}（重新运行生效）"
  return 0
}

# 静默检查（24h 一次），有新版只提示
sbx_check_update_quiet() {
  local last now diff
  [ -n "$SCRIPT_UPDATE_URL" ] || return 0
  [ "$SBX_DRY_RUN" -eq 1 ] && return 0
  [ -r "$SBX_DATA/last_check" ] && last="$(cat "$SBX_DATA/last_check" 2>/dev/null)" || last=0
  now="$(date +%s)"
  diff=$((now - ${last:-0}))
  [ "$diff" -lt 86400 ] && return 0
  mkdir -p "$SBX_DATA" 2>/dev/null || true
  printf '%s' "$now" >"$SBX_DATA/last_check" 2>/dev/null || true
  local remote
  remote="$(curl -fsSL --max-time 8 "$SCRIPT_UPDATE_URL" 2>/dev/null | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)"
  [ -n "$remote" ] || return 0
  [ "$remote" = "$SCRIPT_VERSION" ] && return 0
  printf '%s\n' "  ${C_YEL}[提示]${C_RST} 脚本有新版本：v${SCRIPT_VERSION} → v${remote}（12) 更新脚本）"
  return 0
}

# ============================== 卸载 ========================================
sbx_cmd_uninstall() {
  local purge=0
  [ "${1:-}" = "--purge" ] && purge=1
  sbx_screen_header "卸载"
  printf '  这会：停止并删除 sing-box 服务、二进制、/etc/sing-box 配置\n'
  [ "$purge" -eq 1 ] && printf '  另外删除全部节点数据（/etc/acxc-singbox）\n' \
                     || printf '  节点数据会保留在 %s（加 --purge 才删）\n' "$SBX_DATA"
  printf '\n'
  sbx_ask_yn "确认卸载？" n || { info "已取消"; return 0; }
  sbx_run systemctl stop sing-box 2>/dev/null || true
  sbx_run systemctl disable sing-box 2>/dev/null || true
  sbx_run systemctl stop singbox-porthop 2>/dev/null || true
  sbx_run systemctl disable singbox-porthop 2>/dev/null || true
  [ "$SBX_DRY_RUN" -eq 0 ] && { nft delete table inet sbx_hop 2>/dev/null || true; }
  sbx_run rm -f "$SBX_UNIT" "$SBX_HOP_UNIT" "$SBX_LOGROTATE"
  sbx_run systemctl daemon-reload 2>/dev/null || true
  sbx_run rm -f "$SBX_BIN" "${SBX_BIN}.bak"
  sbx_run rm -rf "$SBX_DIR"
  [ "$purge" -eq 1 ] && sbx_run rm -rf "$SBX_DATA"
  sbx_run rm -f "$SBX_CMD_PATH" /usr/local/bin/sbx
  ok "已卸载"
  return 0
}

# ============================== 菜单 ========================================
# 大字图标（与主脚本 init.sh 同一套 ACXC 图标，只拼一次，之后复用）
SBX_BANNER=""
sbx_build_banner() {
  [ -n "$SBX_BANNER" ] && return 0
  local nl=$'\n' art=""
  art="${art}   █████   █████  ██   ██  █████ ${nl}"
  art="${art}  ██   ██ ██       ██ ██  ██     ${nl}"
  art="${art}  ███████ ██        ███   ██     ${nl}"
  art="${art}  ██   ██ ██       ██ ██  ██     ${nl}"
  art="${art}  ██   ██  █████  ██   ██  █████ ${nl}"
  SBX_BANNER="${art}"
  return 0
}

# 主菜单项目（顺序即编号，和下面的 case 一一对应）
SBX_MENU_ITEMS=(
  "查看节点配置"
  "添加协议"
  "删除协议"
  "修改协议端口"
  "HY2 端口跳跃"
  "节点信息"
  "启动服务"
  "停止服务"
  "重启服务"
  "查看运行日志"
  "更新 sing-box"
  "更新脚本"
  "卸载"
)

# 渲染菜单列表：编号右对齐，第 5、9 项后面空一行做视觉分组
sbx_menu_list() {
  local i=0 item
  for item in "${SBX_MENU_ITEMS[@]}"; do
    i=$((i + 1))
    printf '   %s%2d)%s %s\n' "$C_GRN" "$i" "$C_RST" "$item"
    case "$i" in 5|9) printf '\n' ;; esac
  done
  return 0
}

sbx_banner() {
  sbx_build_banner
  printf '%s' "${C_BLD}${C_CYN}${SBX_BANNER}${C_RST}"
  printf '\n  %s%sACXC-SINGBOX%s  %ssing-box 协议管理%s\n' \
    "$C_BLD" "$C_CYN" "$C_RST" "$C_DIM" "$C_RST"
  sbx_status_line
  printf '  %s──────────────────────────────────────────────%s\n\n' "$C_DIM" "$C_RST"
}

# 二级界面统一的头部：logo + 标题 + 分隔线。同一屏只画一次，嵌套调用不会重复
# 只在交互菜单里画；带参数跑命令行时保持纯文本输出
SBX_SCREEN_STARTED=0
SBX_IN_MENU=0
sbx_screen_header() { # $1=标题
  [ "${SBX_IN_MENU:-0}" = "1" ] || return 0
  [ "${SBX_SCREEN_STARTED:-0}" = "1" ] && return 0
  SBX_SCREEN_STARTED=1
  sbx_build_banner
  printf '%s' "${C_BLD}${C_CYN}${SBX_BANNER}${C_RST}"
  printf '\n  %s%s%s\n' "$C_BLD" "${1:-}" "$C_RST"
  printf '  %s──────────────────────────────────────────────%s\n\n' "$C_DIM" "$C_RST"
  return 0
}

# 把当前这份脚本装到标准位置，并建一个 sb 快捷命令
sbx_install_self() {
  local own
  own="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
  [ -f "$own" ] || { warn "找不到脚本自身：$own"; return 1; }
  if [ "$own" != "$SCRIPT_SELF_PATH" ]; then
    sbx_run mkdir -p "$(dirname "$SCRIPT_SELF_PATH")" || return 1
    sbx_run install -m 755 "$own" "$SCRIPT_SELF_PATH" || return 1
  fi
  sbx_run ln -sf "$SCRIPT_SELF_PATH" "$SBX_CMD_PATH" || return 1
  # 清掉旧版本留下的 sbx 命令
  [ -L /usr/local/bin/sbx ] && sbx_run rm -f /usr/local/bin/sbx
  [ "$SBX_DRY_RUN" -eq 1 ] && return 0
  if [ "$own" = "$SCRIPT_SELF_PATH" ]; then
    ok "已创建命令 ${SBX_CMD_PATH##*/}"
  else
    ok "已安装到 $SCRIPT_SELF_PATH，以后直接输入 ${SBX_CMD_PATH##*/} 就能打开"
  fi
  return 0
}

sbx_menu_main() {
  local choice need_self=0
  # 临时文件第一次运行：问要不要装成 sb 命令（装过就不问了）
  if [ "$SBX_EMBEDDED" != "1" ] && [ "$SBX_DRY_RUN" -eq 0 ] && [ ! -f "$SCRIPT_SELF_PATH" ]; then
    need_self=1
  fi
  # 首屏提示统一在需要时画一次 banner，避免连画两次
  if [ "$need_self" -eq 1 ] || ! sbx_sb_installed; then
    sbx_banner
  fi
  if [ "$need_self" -eq 1 ]; then
    info "当前是临时文件：$0"
    if sbx_ask_yn "装成命令 sb（以后直接输入 sb 打开）？" y; then
      sbx_install_self || warn "安装失败，不影响继续使用"
    fi
  fi
  # 第一次进菜单：没装 sing-box 就先问一句（--yes 时直接装）
  if ! sbx_sb_installed; then
    warn "还没有安装 sing-box"
    if sbx_ask_yn "现在安装 v${SBX_SB_VERSION}？" y; then
      sbx_cmd_install || warn "安装未完成，稍后可用 11) 更新 sing-box 再试"
    fi
  fi
  while :; do
    sbx_clear
    sbx_banner
    sbx_check_update_quiet
    printf '  %s操作菜单%s\n\n' "$C_BLD" "$C_RST"
    sbx_menu_list
    printf '\n   %s 0)%s 退出\n\n' "$C_DIM" "$C_RST"
    sbx_prompt "请选择（0-13）" "" || return 0
    choice="$SBX_REPLY"
    printf '\n'
    # 进二级界面前先清屏：主菜单和二级菜单不挤在同一屏
    case "$choice" in
      1|2|3|4|5|6|10) sbx_clear; SBX_IN_MENU=1; SBX_SCREEN_STARTED=0 ;;
    esac
    case "$choice" in
      0|q|Q|exit|quit) return 0 ;;
      1)
         sbx_cmd_list
         sbx_prompt "选择" "" || continue
         case "$SBX_REPLY" in
           '')  continue ;;   # 直接回车＝返回上级菜单
           *)   if sbx_resolve_node "$SBX_REPLY"; then
                  sbx_clear; SBX_IN_MENU=1; SBX_SCREEN_STARTED=0
                  sbx_show_node "$SBX_REPLY"
                else warn "找不到节点：$SBX_REPLY"; fi ;;
         esac
         sbx_pause ;;
      2) sbx_cmd_add; sbx_pause ;;
      3) sbx_cmd_del; sbx_pause ;;
      4) sbx_screen_header "修改协议端口"
         sbx_cmd_list
         sbx_prompt "要改端口的编号/名字" "" || continue
         [ -n "$SBX_REPLY" ] || continue
         sbx_resolve_node "$SBX_REPLY" || { err "找不到节点"; sbx_pause; continue; }
         local n="$SBX_REPLY"
         sbx_prompt "新端口" "$(sbx_node_get "$n" port)" || continue
         sbx_cmd_port "$n" "$SBX_REPLY"; sbx_pause ;;
      5) sbx_cmd_hop_menu; sbx_pause ;;
      6) sbx_cmd_info; sbx_pause ;;
      7) sbx_cmd_service start; sbx_pause ;;
      8) sbx_cmd_service stop; sbx_pause ;;
      9) sbx_cmd_service restart; sbx_pause ;;
      10) sbx_cmd_log 40; sbx_pause ;;
      11) sbx_cmd_update_singbox; sbx_pause ;;
      12) sbx_cmd_update_script; sbx_pause ;;
      13) sbx_cmd_uninstall; sbx_pause ;;
      *) warn "无效的选择：$choice" ;;
    esac
    SBX_PROTO_HINT=""; SBX_PORT_HINT=""; SBX_SNI_HINT=""; SBX_CERT_HINT=""; SBX_KEY_HINT=""
  done
}

sbx_cmd_hop_menu() {
  sbx_screen_header "HY2 端口跳跃"
  sbx_cmd_list
  local hy2="" name
  for name in $(sbx_node_names); do
    [ "$(sbx_node_get "$name" proto)" = hysteria2 ] && hy2="$hy2 $name"
  done
  if [ -z "$hy2" ]; then
    info "还没有 Hysteria2 节点（先 2) 添加协议）"
    return 0
  fi
  printf '  可用的 Hysteria2 节点：%s\n\n' "${hy2# }"
  sbx_prompt "节点编号/名字" "" || return 0
  [ -n "$SBX_REPLY" ] || return 0
  sbx_resolve_node "$SBX_REPLY" || { err "找不到节点"; return 1; }
  name="$SBX_REPLY"
  local cur; cur="$(sbx_node_get "$name" hop)"
  sbx_kv "当前设置" "${cur:-未开启}"
  info "输入 off 表示关闭端口跳跃"
  sbx_prompt "端口段" "${cur:-$SBX_DEFAULT_HOP_RANGE}" || return 0
  sbx_hop_apply "$name" "${SBX_REPLY:-$SBX_DEFAULT_HOP_RANGE}" || return 1
  printf '\n'
  warn "别忘了在云厂商安全组放行 UDP ${SBX_REPLY}（否则只有主端口可用）"
  sbx_show_node "$name" >/dev/null 2>&1 || true
  sbx_kv "新链接" "$(sbx_link_node "$name")"
  return 0
}

# ============================== 命令行 ======================================
sbx_usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

用法:
  bash $0                         交互式菜单
  bash $0 --install [--sb-version 1.14.3]
  bash $0 --add reality|hysteria2|shadowsocks|trojan [--name 名字] [--port 端口] [--sni 域名] [--remark 备注]
  bash $0 --list | --show <名字> | --link <名字> [--qr]
  bash $0 --clash <名字>           只输出这一个节点的 Clash 配置
  bash $0 --sub [clash|links]      生成订阅文件（clash.yaml / links.txt）
  bash $0 --del <名字> | --set-port <名字> <端口>
  bash $0 --hop <名字> <端口段|off>
  bash $0 --start | --stop | --restart | --status | --log [行数]
  bash $0 --update-singbox [--sb-version x.y.z]
  bash $0 --self-test               用临时目录验证四种协议配置是否合法
  bash $0 --update-script [本地文件|URL]
  bash $0 --uninstall [--purge]
  bash $0 --host <IP>              链接里使用的地址（默认自动探测）

通用选项:
  -y, --yes      无人值守（能用默认值的地方都用默认值）
      --dry-run  演练：只打印将要写什么，不改系统
      --no-color 关闭彩色输出
  -h, --help     显示本帮助
  -V, --version  显示脚本版本号
EOF
}

sbx_parse_args() {
  local a
  SBX_PROTO_HINT=""; SBX_PORT_HINT=""; SBX_SNI_HINT=""; SBX_CERT_HINT=""; SBX_KEY_HINT=""
  SBX_ARG_NAME=""; SBX_ARG_REMARK=""; SBX_ARG_HOST=""; SBX_ACTION=""; SBX_ACTION_ARG=""
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      -y|--yes) SBX_ASSUME_YES=1 ;;
      --dry-run) SBX_DRY_RUN=1 ;;
      --no-color) SBX_COLOR_OFF=1 ;;
      --qr) SBX_QR=1 ;;
      --version=*|--sb-version=*) SBX_SB_VERSION="${a#*=}" ;;
      --name) shift; SBX_ARG_NAME="${1-}" ;;
      --remark) shift; SBX_ARG_REMARK="${1-}" ;;
      --host) shift; SBX_ARG_HOST="${1-}" ;;
      --sni) shift; SBX_SNI_HINT="${1-}" ;;
      --port) shift; SBX_PORT_HINT="${1-}" ;;
      --cert) shift; SBX_CERT_HINT="${1-}" ;;
      --key) shift; SBX_KEY_HINT="${1-}" ;;
      --add) shift; SBX_ACTION="add"; SBX_PROTO_HINT="${1-}"; shift || true; continue ;;
      --del) shift; SBX_ACTION="del"; SBX_ACTION_ARG="${1-}"; shift || true; continue ;;
      --show) shift; SBX_ACTION="show"; SBX_ACTION_ARG="${1-}"; shift || true; continue ;;
      --link) shift; SBX_ACTION="link"; SBX_ACTION_ARG="${1-}"; shift || true; continue ;;
      --clash) shift; SBX_ACTION="clash"; SBX_ACTION_ARG="${1-}"; shift || true; continue ;;
      --sub) SBX_ACTION="sub"; SBX_ACTION_ARG="clash"
             if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then SBX_ACTION_ARG="$2"; shift; fi ;;
      --set-port) shift; SBX_ACTION="set-port"; SBX_ACTION_ARG="${1-}"; shift || true
                  SBX_PORT_HINT="${1-}"; shift || true; continue ;;
      --hop) shift; SBX_ACTION="hop"; SBX_ACTION_ARG="${1-}"; shift || true
             SBX_SNI_HINT="${1-}"; shift || true; continue ;;
      --version) printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; SBX_ACTION="exit"; return 0 ;;
      -h|--help) SBX_ACTION="help"; return 0 ;;
      --install) SBX_ACTION="install" ;;
      --list) SBX_ACTION="list" ;;
      --all-links) SBX_ACTION="links" ;;
      --start|--stop|--restart|--status) SBX_ACTION="${a#--}" ;;
      --log) shift; SBX_ACTION="log"; SBX_ACTION_ARG="${1:-40}" ;;
      --update-singbox) SBX_ACTION="update-singbox" ;;
      --self-test) SBX_ACTION="self-test" ;;
      --update-script) SBX_ACTION="update-script"
                       if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then SBX_ACTION_ARG="$2"; shift; fi ;;
      --uninstall) SBX_ACTION="uninstall" ;;
      --purge) SBX_ACTION_ARG="--purge" ;;
      -V) printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; SBX_ACTION="exit"; return 0 ;;
      *) err "未知参数：$1"; sbx_usage; return 2 ;;
    esac
    shift
  done
  return 0
}

# ============================== 主流程 ======================================
sbx_bootstrap() {
  sbx_init_colors
  sbx_prepare_log
  _sbx_log START "===== ${SCRIPT_NAME} v${SCRIPT_VERSION} 启动（参数：$*）=====" 2>/dev/null || true
  sbx_detect_tty
}

# 供主脚本调用的入口（父脚本 STEPS 表里直接指到这里）
sbx_step_menu() {
  SBX_EMBEDDED=1
  sbx_bootstrap || return 1
  sbx_require_root || return 1
  sbx_layout_init >/dev/null 2>&1 || true
  sbx_menu_main
  return $?
}

# 无人值守一键：装好 + 建一条 Reality（--yes 时用）
sbx_quickstart() {
  sbx_cmd_install || return 1
  SBX_PROTO_HINT="reality"
  sbx_cmd_add || return 1
  ok "完成。链接见上（12) 更新脚本 / 2) 添加协议 可继续加节点）"
  return 0
}

# 仓库里有新版但正在跑的是旧版时提醒一句（不然会出现"改了半天没生效"）
sbx_check_stale() {
  local d ver own_dir
  own_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")"
  for d in "${ACXC_SBX_REPO:-}" /opt/ACXC-Sing-Box "$own_dir"; do
    [ -n "$d" ] || continue
    [ -f "$d/acxc-singbox.sh" ] || continue
    [ "$d" = "$own_dir" ] && continue      # 自己就是仓库里那份，不用提示
    ver="$(grep -m1 '^SCRIPT_VERSION=' "$d/acxc-singbox.sh" 2>/dev/null | cut -d'"' -f2)"
    [ -n "$ver" ] || continue
    [ "$ver" = "$SCRIPT_VERSION" ] && continue
    warn "仓库里已是 v${ver}，但你运行的是 v${SCRIPT_VERSION}（菜单 12 更新脚本）"
    return 0
  done
  return 0
}

# 保证快捷命令存在（从旧版的 sbx 迁移到 sb 时靠这个自愈）
sbx_ensure_cmd() {
  [ "$SBX_DRY_RUN" -eq 1 ] && return 0
  [ -f "$SCRIPT_SELF_PATH" ] || return 0
  [ -x "$SBX_CMD_PATH" ] || ln -sf "$SCRIPT_SELF_PATH" "$SBX_CMD_PATH" 2>/dev/null || true
  [ -L /usr/local/bin/sbx ] && rm -f /usr/local/bin/sbx 2>/dev/null || true
  return 0
}

sbx_main() {
  SBX_ARGS=("$@")
  sbx_bootstrap "$@" || true
  sbx_parse_args "$@" || return $?

  case "${SBX_ACTION:-}" in
    exit)  return 0 ;;
    help)  sbx_usage; return 0 ;;
  esac

  sbx_require_root || return 1
  sbx_check_os || return 1
  sbx_check_deps || return 1
  sbx_layout_init || return 1
  sbx_ensure_cmd
  sbx_check_stale

  [ -n "${SBX_ARG_HOST:-}" ] && sbx_server_set public_ip "$SBX_ARG_HOST" >/dev/null 2>&1 || true

  case "${SBX_ACTION:-}" in
    "")          sbx_menu_main ;;
    install)     sbx_cmd_install ;;
    add)         sbx_cmd_add ;;
    del)         sbx_cmd_del "$SBX_ACTION_ARG" ;;
    show)        sbx_resolve_node "$SBX_ACTION_ARG" && sbx_show_node "$SBX_REPLY" ;;
    link)        sbx_resolve_node "$SBX_ACTION_ARG" || return 1
                 local l; l="$(sbx_link_node "$SBX_REPLY")" && printf '%s\n' "$l"
                 [ "${SBX_QR:-0}" = 1 ] && sbx_qr "$l"; return 0 ;;
    clash)       sbx_resolve_node "$SBX_ACTION_ARG" || return 1
                 sbx_clash_proxy "$SBX_REPLY" ;;
    sub)         sbx_cmd_sub "${SBX_ACTION_ARG:-clash}" ;;
    list)        sbx_cmd_list ;;
    links)       sbx_cmd_links ;;
    set-port)    sbx_resolve_node "$SBX_ACTION_ARG" && sbx_cmd_port "$SBX_REPLY" "$SBX_PORT_HINT" ;;
    hop)         sbx_resolve_node "$SBX_ACTION_ARG" || return 1
                 sbx_hop_apply "$SBX_REPLY" "${SBX_SNI_HINT:-$SBX_DEFAULT_HOP_RANGE}" ;;
    start|stop|restart|status) sbx_cmd_service "$SBX_ACTION" ;;
    log)         sbx_cmd_log "${SBX_ACTION_ARG:-40}" ;;
    update-singbox) sbx_cmd_update_singbox ;;
    self-test)   sbx_self_test ;;
    update-script)  sbx_cmd_update_script "$SBX_ACTION_ARG" ;;
    uninstall)   sbx_cmd_uninstall "$SBX_ACTION_ARG" ;;
    *) sbx_usage; return 2 ;;
  esac
  return $?
}

# 被 source（嵌进主脚本）时不自动执行
if [ "$SBX_EMBEDDED" != "1" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  sbx_main "$@"
  exit $?
fi
