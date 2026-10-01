#!/usr/bin/env bash
#
# reality-deploy —— Xray (VLESS + REALITY + Vision) 一键部署脚本
#
# 适用对象: 单台使用 systemd 的 Linux VPS，需以 root (或 sudo) 运行。
# 单条命令即可完成: 环境检查 → 安装 Xray → 生成密钥与配置 → 启动服务 → 状态校验。
#
# 用法示例:
#   sudo bash deploy.sh                                  # 默认参数一键部署
#   sudo bash deploy.sh --sni www.apple.com              # 指定 SNI
#   sudo bash deploy.sh --dry-run                        # 只做环境检查，不改动系统
#   sudo bash deploy.sh --server 1.2.3.4 --generate-link # 部署并生成 Shadowrocket 链接
#
# 所有参数均可经环境变量预设，命令行参数优先级更高。详见下方 "可配置参数"。
#
# 安全声明:
#   - 本脚本仅在你的自有 VPS 上安装并写入服务端配置；私钥、UUID、short ID 仅存于服务端。
#   - 部署完成后打印的内容含有可连接凭据(UUID / 公钥 / short ID)，请按密码保管，不要公开。
#   - 单 VPS 方案不保证 IP 不被网络管控方封锁；本脚本不提供任何规避法律风险的保证。

set -euo pipefail
set -E

# ============================ 可配置参数 ============================
# 环境变量优先级低于同名命令行参数。以下为默认值。
: "${REALITY_SNI:=www.apple.com}"          # TLS Server Name（同时作为默认 dest 主机与 serverNames）
: "${REALITY_DEST:=${REALITY_SNI}:443}"     # REALITY 目标站 host:port
: "${REALITY_SERVER_NAMES:=${REALITY_SNI}}" # 逗号分隔的 serverNames 列表
: "${XRAY_PORT:=443}"                       # 监听端口
: "${XRAY_CONFIG_PATH:=/usr/local/etc/xray/config.json}" # 服务端配置写入路径
: "${CLIENT_PARAMS_FILE:=/usr/local/etc/xray/client-params.json}" # 客户端参数保存路径（--show 读取）
: "${SERVER_IP:=}"                          # 对外 IP（默认自动探测，仅用于生成客户端参数）
: "${NODE_NAME:=My-VPS}"                    # 客户端节点显示名
: "${SKIP_INSTALL:=0}"                      # 设为 1 则跳过 Xray 安装（复用已安装的 xray）
: "${FORCE:=0}"                             # 设为 1 则强制重新生成密钥并覆盖已有配置
: "${DRY_RUN:=0}"                           # 设为 1 或 --dry-run 仅做环境检查
: "${GENERATE_LINK:=0}"                     # 设为 1 或 --generate-link 部署后生成 Shadowrocket 链接
: "${SHOW:=0}"                              # 设为 1 或 --show 仅展示已部署的客户端 VLESS 配置
: "${QR_OUT:=}"                             # 可选：Shadowrocket 二维码 PNG 输出路径

XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# ============================ 颜色与日志 ============================
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''
fi

log_info() { printf '%s[INFO]%s %s\n'  "$C_BLU" "$C_RST" "$*"; }
log_ok()   { printf '%s[ OK ]%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
log_warn() { printf '%s[WARN]%s %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
log_step() { printf '\n%s=== %s ===%s\n' "$C_BLU" "$*" "$C_RST"; }

die() {
  printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RST" "$*" >&2
  exit 1
}

err_trap() {
  local code=$1 line=$2
  printf '%s[ERROR]%s 部署在步骤失败（exit=%s, line=%s）\n' "$C_RED" "$C_RST" "$code" "$line" >&2
}
trap 'err_trap $? $LINENO' ERR

# 临时文件清理
TMP_CONFIG="$(mktemp /tmp/xray-config.XXXXXX.json)"
trap 'rm -f "$TMP_CONFIG" 2>/dev/null' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================ 帮助 ============================
usage() {
  cat <<EOF
reality-deploy 一键部署脚本

用法: sudo bash deploy.sh [选项]

选项:
  --sni <host>             TLS Server Name（默认 www.apple.com）
  --dest <host:port>       REALITY 目标站（默认 <sni>:443）
  --server-names <列表>    逗号分隔的 serverNames（默认同 --sni）
  --port <端口>            Xray 监听端口（默认 443）
  --config <路径>          服务端配置写入路径（默认 /usr/local/etc/xray/config.json）
  --server <IP/域名>       服务器对外地址（默认自动探测，仅用于客户端参数）
  --node-name <名称>       客户端节点显示名（默认 My-VPS）
  --skip-install           跳过 Xray 安装，复用已安装的 xray
  --force                  强制重新生成密钥并覆盖已有配置
  --dry-run                仅做环境检查，不安装/不改系统
  --generate-link          部署后生成 Shadowrocket 节点链接（URI / 二维码）
  --qr-out <路径>          Shadowrocket 二维码 PNG 输出路径（需 qrencode）
  --show                   仅展示已部署的客户端 VLESS 配置（读取 client-params.json，不改动系统）
  -h, --help               显示本帮助

同名环境变量亦可预设，命令行参数优先级更高。
查看已部署配置示例: sudo bash deploy.sh --show [--server <IP>] [--qr-out node.png]
EOF
}

# ============================ 参数解析 ============================
# 便捷子命令：直接展示已部署配置
if [[ "${1:-}" == "show" ]]; then SHOW=1; shift; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sni)           REALITY_SNI="$2"; shift 2;;
    --dest)          REALITY_DEST="$2"; shift 2;;
    --server-names)  REALITY_SERVER_NAMES="$2"; shift 2;;
    --port)          XRAY_PORT="$2"; shift 2;;
    --config)        XRAY_CONFIG_PATH="$2"; shift 2;;
    --server)        SERVER_IP="$2"; shift 2;;
    --node-name)     NODE_NAME="$2"; shift 2;;
    --skip-install)  SKIP_INSTALL=1; shift;;
    --force)         FORCE=1; shift;;
    --dry-run)       DRY_RUN=1; shift;;
    --generate-link) GENERATE_LINK=1; shift;;
    --qr-out)        QR_OUT="$2"; shift 2;;
    --show)          SHOW=1; shift;;
    -h|--help)       usage; exit 0;;
    *) die "未知参数: $1（使用 -h 查看帮助）";;
  esac
done

# ============================ 工具函数 ============================
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令: $1（请先在系统中安装后再运行）"
}

# ============================ 阶段 1: 环境检查 ============================
check_environment() {
  log_step "阶段 1/6 · 环境检查"

  # 必须是 Linux
  if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]]; then
    die "本脚本仅支持 Linux VPS（当前系统: $(uname -s 2>/dev/null)）。请在目标服务器上运行。"
  fi
  log_ok "操作系统: $(uname -s) $(uname -m)"

  # 需要 root
  if [[ "$(id -u)" -ne 0 ]]; then
    die "请以 root 运行（使用 sudo bash deploy.sh）。当前 EUID=$(id -u)。"
  fi
  log_ok "权限: root"

  # systemd 检查
  if ! command -v systemctl >/dev/null 2>&1; then
    die "未检测到 systemctl，本脚本面向 systemd 系统。请改用对应发行版的服务管理方式。"
  fi
  if [[ "$(ps -p 1 -o comm= 2>/dev/null || echo unknown)" != "systemd" ]]; then
    die "PID 1 不是 systemd（实际: $(ps -p 1 -o comm= 2>/dev/null)），无法使用 systemctl 管理 Xray 服务。"
  fi
  log_ok "初始化系统: systemd"

  # 必需工具
  need_cmd curl
  need_cmd python3
  log_ok "基础工具: curl / python3 可用"

  # 端口占用检查（仅在非 force 时阻断）
  local port_in_use=0
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 'sport = :'"$XRAY_PORT" 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"; then
      port_in_use=1
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -ltn 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"; then
      port_in_use=1
    fi
  else
    log_warn "未检测到 ss/netstat，跳过端口占用检查；请自行确认 ${XRAY_PORT} 未被占用。"
  fi

  if [[ "$port_in_use" -eq 1 ]]; then
    if [[ "$FORCE" == "1" ]]; then
      log_warn "端口 ${XRAY_PORT} 已被占用；--force 已启用，将覆盖现有 Xray 配置。"
    else
      die "端口 ${XRAY_PORT} 已被占用。请释放该端口，或确认是否为旧 Xray 实例；如需覆盖请加 --force。"
    fi
  else
    log_ok "端口 ${XRAY_PORT} 当前空闲"
  fi

  # 若已有配置且服务在运行，给出幂等提示
  if [[ -f "$XRAY_CONFIG_PATH" ]] && [[ "$FORCE" != "1" ]] \
     && ! grep -q '<UUID>' "$XRAY_CONFIG_PATH" 2>/dev/null \
     && systemctl is-active xray >/dev/null 2>&1; then
    log_ok "检测到已部署且服务运行中。如需重新生成密钥请加 --force；否则直接退出。"
    exit 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log_ok "环境检查通过（dry-run，未做任何改动）。"
    exit 0
  fi
}

# ============================ 阶段 2: 安装 Xray ============================
install_xray() {
  log_step "阶段 2/6 · 安装 Xray-core"

  if command -v xray >/dev/null 2>&1; then
    if [[ "$SKIP_INSTALL" == "1" ]]; then
      log_ok "检测到已安装 xray，按 --skip-install 复用: $(xray version 2>&1 | head -n1)"
      return 0
    fi
    log_info "检测到已安装 xray: $(xray version 2>&1 | head -n1)；将重新安装以确保为最新版。"
  fi

  log_info "下载并运行官方安装器…"
  local installer="/tmp/xray-install.sh"
  if ! curl -fsSL --max-time 60 "$XRAY_INSTALLER_URL" -o "$installer"; then
    die "下载 Xray 安装器失败（URL: $XRAY_INSTALLER_URL）。请检查网络连通性。"
  fi
  if ! bash "$installer" @ install; then
    rm -f "$installer"
    die "Xray 安装失败。请查看上方报错。"
  fi
  rm -f "$installer"

  need_cmd xray
  log_ok "Xray 安装完成: $(xray version 2>&1 | head -n1)"
}

# ============================ 阶段 3: 生成密钥与 UUID ============================
UUID=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
generate_credentials() {
  log_step "阶段 3/6 · 生成 REALITY 密钥与 UUID"

  need_cmd xray

  local out
  out="$(xray x25519)" || die "xray x25519 执行失败。"
  PRIVATE_KEY="$(printf '%s\n' "$out" | awk -F': ' '/Private key/{print $2}')"
  PUBLIC_KEY="$(printf '%s\n' "$out"  | awk -F': ' '/Public key/{print $2}')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "未能解析 X25519 密钥对。"

  UUID="$(xray uuid)" || die "xray uuid 执行失败。"
  [[ -n "$UUID" ]] || die "未能生成 UUID。"

  SHORT_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  [[ -n "$SHORT_ID" ]] || die "未能生成 short ID。"

  log_ok "X25519 密钥对 / UUID / short ID 已生成（私钥仅写入服务端配置）"
}

# ============================ 阶段 4: 生成并校验配置 ============================
build_config() {
  log_step "阶段 4/6 · 生成服务端配置"

  local tpl="$SCRIPT_DIR/server-config.json"
  [[ -f "$tpl" ]] || die "找不到配置模板: $tpl"

  # 使用 python3 安全地写入真实字段（避免 sed 处理特殊字符出错）
  REALITY_DEST="$REALITY_DEST" \
  REALITY_SERVER_NAMES="$REALITY_SERVER_NAMES" \
  XRAY_PORT="$XRAY_PORT" \
  UUID="$UUID" PRIVATE_KEY="$PRIVATE_KEY" SHORT_ID="$SHORT_ID" \
  python3 - "$tpl" "$TMP_CONFIG" <<'PY'
import json, os, sys
tpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tpl_path, encoding="utf-8") as f:
    cfg = json.load(f)

ib = cfg["inbounds"][0]
ib["port"] = int(os.environ["XRAY_PORT"])

rs = ib["streamSettings"]["realitySettings"]
rs["dest"] = os.environ["REALITY_DEST"]
names = [n.strip() for n in os.environ["REALITY_SERVER_NAMES"].split(",") if n.strip()]
if names:
    rs["serverNames"] = names

ib["settings"]["clients"][0]["id"] = os.environ["UUID"]
rs["privateKey"] = os.environ["PRIVATE_KEY"]
rs["shortIds"] = [os.environ["SHORT_ID"]] if os.environ["SHORT_ID"] else []

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

  log_info "以 xray run -test 校验配置…"
  if ! xray run -test -config "$TMP_CONFIG" >/tmp/xray-test.log 2>&1; then
    die "配置校验失败:\n$(cat /tmp/xray-test.log)"
  fi
  log_ok "配置语法校验通过"
}

# ============================ 阶段 5: 安装并启动服务 ============================
start_service() {
  log_step "阶段 5/6 · 安装配置并启动服务"

  install -d -m 755 /usr/local/etc/xray

  local xray_user xray_group
  xray_user="$(systemctl show xray -p User --value 2>/dev/null || true)"
  [[ -n "$xray_user" ]] || xray_user=root
  xray_group="$(systemctl show xray -p Group --value 2>/dev/null || true)"
  [[ -n "$xray_group" ]] || xray_group="$(id -gn "$xray_user")"

  install -o root -g "$xray_group" -m 640 "$TMP_CONFIG" "$XRAY_CONFIG_PATH"
  log_ok "配置已写入 $XRAY_CONFIG_PATH（权限 0640，属主 root:$xray_group）"

  if ! sudo -u "$xray_user" test -r "$XRAY_CONFIG_PATH" 2>/dev/null; then
    die "Xray 运行用户($xray_user)无法读取配置文件，请检查权限。"
  fi

  log_info "启用并启动 xray 服务…"
  systemctl daemon-reload
  if ! systemctl enable --now xray; then
    die "systemctl enable --now xray 失败。查看: journalctl -u xray -n 50"
  fi
  log_ok "xray 服务已启用并启动"
}

# ============================ 阶段 6: 部署后状态校验 ============================
verify_deployment() {
  log_step "阶段 6/6 · 部署后状态校验"

  local ok=1

  # 1) 服务状态
  if systemctl is-active xray >/dev/null 2>&1; then
    log_ok "systemd 服务状态: active"
  else
    log_warn "systemd 服务状态: 非 active（查看 journalctl -u xray）"
    ok=0
  fi

  # 2) 配置再次测试
  if xray run -test -config "$XRAY_CONFIG_PATH" >/dev/null 2>&1; then
    log_ok "服务端配置测试: 通过"
  else
    log_warn "服务端配置测试: 未通过"
    ok=0
  fi

  # 3) 端口监听
  local listening=0
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 'sport = :'"$XRAY_PORT" 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"; then
      listening=1
    fi
  fi
  if [[ "$listening" -eq 1 ]]; then
    log_ok "端口 ${XRAY_PORT} 监听中"
  else
    log_warn "未检测到端口 ${XRAY_PORT} 监听（ss 不可用或尚未就绪）"
    ok=0
  fi

  if [[ "$ok" -ne 1 ]]; then
    die "部署后校验未全部通过，请按上方 WARN 排查。"
  fi

  # 服务器 IP（用于客户端参数）
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$SERVER_IP" ]] && SERVER_IP="$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"
  fi

  # 持久化客户端参数，供 --show 回看（仅存公钥，不含私钥）
  save_client_params

  echo
  printf '%s========== 部署成功 ==========%s\n' "$C_GRN" "$C_RST"
  echo "请使用以下参数在客户端（Shadowrocket / sing-box / v2rayN）导入节点："
  echo "  服务器地址 : ${SERVER_IP:-<请手动填写 VPS IP>}"
  echo "  端口       : ${XRAY_PORT}"
  echo "  协议       : VLESS"
  echo "  UUID       : ${UUID}"
  echo "  流控 flow  : xtls-rprx-vision"
  echo "  security   : reality"
  echo "  SNI        : ${REALITY_SNI}"
  echo "  public key : ${PUBLIC_KEY}"
  echo "  short ID   : ${SHORT_ID}"
  echo "  目标站 dest: ${REALITY_DEST}"
  echo
  echo "⚠️ 上述 UUID / public key / short ID 为可连接凭据，请妥善保管，不要公开提交或转发。"

  if [[ "$GENERATE_LINK" == "1" ]]; then
    generate_link
  fi

  echo
  log_info "如需验收：在客户端连接后访问 IP 查询站点，确认出口 IP 为本机；并放行 VPS 防火墙 TCP ${XRAY_PORT}。"
}

# 生成 Shadowrocket 链接（脚本在可信服务端运行，凭据不离开本机）
generate_link() {
  local py="$SCRIPT_DIR/generate_shadowrocket_link.py"
  [[ -f "$py" ]] || { log_warn "未找到 $py，跳过链接生成。"; return 0; }
  [[ -n "$SERVER_IP" ]] || { log_warn "无法探测服务器 IP，跳过链接生成；可用 --server 指定。"; return 0; }

  log_info "生成 Shadowrocket 节点链接…"
  if [[ -n "$QR_OUT" ]]; then
    if ! python3 "$py" \
          --server "$SERVER_IP" --port "$XRAY_PORT" \
          --uuid "$UUID" --public-key "$PUBLIC_KEY" --short-id "$SHORT_ID" \
          --sni "$REALITY_SNI" --name "$NODE_NAME" --qr-out "$QR_OUT"; then
      log_warn "Shadowrocket 链接生成失败（详见上方输出）。"
    fi
  else
    if ! python3 "$py" \
          --server "$SERVER_IP" --port "$XRAY_PORT" \
          --uuid "$UUID" --public-key "$PUBLIC_KEY" --short-id "$SHORT_ID" \
          --sni "$REALITY_SNI" --name "$NODE_NAME"; then
      log_warn "Shadowrocket 链接生成失败（详见上方输出）。"
    fi
  fi
}

# 持久化客户端参数（仅含公钥，不含服务端私钥），供 --show 复用
save_client_params() {
  [[ -n "$UUID" && -n "$PUBLIC_KEY" ]] || return 0
  install -d -m 755 /usr/local/etc/xray
  CLIENT_PARAMS_FILE="$CLIENT_PARAMS_FILE" UUID="$UUID" PUBLIC_KEY="$PUBLIC_KEY" \
  SHORT_ID="$SHORT_ID" REALITY_SNI="$REALITY_SNI" XRAY_PORT="$XRAY_PORT" \
  SERVER_IP="${SERVER_IP:-}" python3 - "$CLIENT_PARAMS_FILE" <<'PY'
import json, os
path = os.sys.argv[1]
d = {
    "uuid": os.environ["UUID"],
    "publicKey": os.environ["PUBLIC_KEY"],
    "shortId": os.environ["SHORT_ID"],
    "sni": os.environ["REALITY_SNI"],
    "port": int(os.environ["XRAY_PORT"]),
    "server": os.environ.get("SERVER_IP", ""),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
  chown root:"${XRAY_GROUP:-root}" "$CLIENT_PARAMS_FILE" 2>/dev/null || chown root "$CLIENT_PARAMS_FILE" 2>/dev/null
  chmod 600 "$CLIENT_PARAMS_FILE"
  log_ok "客户端参数已保存至 $CLIENT_PARAMS_FILE（权限 0600，--show 可回看）"
}

# 直接展示已部署的客户端 VLESS 配置（不改动系统）
show_config() {
  # 本函数为只读展示，调用后立即 exit，故直接关闭 nounset，
  # 规避部分 bash 版本下「local 变量经赋值/重赋值后在 set -u 下被误报 unbound」的已知缺陷。
  set +u
  if [[ ! -r "$CLIENT_PARAMS_FILE" ]]; then
    die "未找到客户端参数文件（$CLIENT_PARAMS_FILE）。请先完成一次完整部署：sudo bash deploy.sh"
  fi
  local params
  params="$(python3 - "$CLIENT_PARAMS_FILE" <<'PY'
import json, os
d = json.load(open(os.sys.argv[1], encoding="utf-8"))
print("UUID=%s" % d["uuid"])
print("PBK=%s" % d["publicKey"])
print("SID=%s" % d.get("shortId", ""))
print("SNI=%s" % d["sni"])
print("PORT=%s" % d["port"])
print("SRV=%s" % d.get("server", ""))
PY
)"
  eval "$params"

  local s_server="$SERVER_IP"
  [[ -z "$s_server" ]] && s_server="$SRV"
  [[ -z "$s_server" ]] && s_server="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$s_server" ]] && s_server="$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"
  [[ -z "$s_server" ]] && die "无法确定服务器 IP，请用 --show --server <IP> 指定。"

  log_step "已部署的 VLESS 客户端配置"
  echo "  服务器地址 : $s_server"
  echo "  端口       : $PORT"
  echo "  协议       : VLESS"
  echo "  flow       : xtls-rprx-vision"
  echo "  security   : reality"
  echo "  SNI        : $SNI"
  echo "  UUID       : $UUID"
  echo "  public key : $PBK"
  echo "  short ID   : $SID"

  local py="$SCRIPT_DIR/generate_shadowrocket_link.py"
  [[ -f "$py" ]] || { log_warn "未找到 $py，跳过链接生成。"; return 0; }
  log_info "vless:// 导入链接："
  if [[ -n "$QR_OUT" ]]; then
    python3 "$py" --server "$s_server" --port "$PORT" --uuid "$UUID" \
          --public-key "$PBK" --short-id "$SID" --sni "$SNI" --name "$NODE_NAME" --qr-out "$QR_OUT"
  else
    python3 "$py" --server "$s_server" --port "$PORT" --uuid "$UUID" \
          --public-key "$PBK" --short-id "$SID" --sni "$SNI" --name "$NODE_NAME"
  fi
}

# ============================ 主流程 ============================
main() {
  if [[ "$SHOW" == "1" ]]; then
    show_config
    exit 0
  fi
  log_step "reality-deploy 一键部署（SNI=${REALITY_SNI}, 端口=${XRAY_PORT}）"
  check_environment
  install_xray
  generate_credentials
  build_config
  start_service
  verify_deployment
}

main "$@"
