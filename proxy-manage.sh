#!/bin/bash
# ================================================================
#  proxy-manage — VLESS+Reality & Hysteria2 一键管理脚本
#  支持：Debian / Ubuntu，无面板依赖，个人自用
#  GitHub: https://github.com/MaoShiSanKe/proxy-manage
#  版本：1.0.0
# ================================================================
set -euo pipefail

# ── 版本 ─────────────────────────────────────────────────────────
VERSION="1.0.0"
SCRIPT_PATH="$(realpath "$0")"

# ── 颜色 ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── 输出函数 ──────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERR ]${NC} $*"; }
die()     { err "$*"; exit 1; }
section() { echo -e "\n${BLUE}${BOLD}═══ $* ═══${NC}"; }
tip()     { echo -e "${DIM}  → $*${NC}"; }

# ── 路径常量 ──────────────────────────────────────────────────────
XRAY_BIN="/usr/local/bin/xray"
HY2_BIN="/usr/local/bin/hysteria"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CERT="/etc/hysteria/server.crt"
HY2_KEY="/etc/hysteria/server.key"
STATE_DIR="/etc/proxy-manage"
STATE_FILE="${STATE_DIR}/state.conf"   # 持久化配置
LOG_DIR="/var/log/proxy-manage"

# ── 初始化目录 ────────────────────────────────────────────────────
init_dirs() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" /usr/local/etc/xray /var/log/xray /etc/hysteria
}

# ================================================================
# 状态持久化：读写 /etc/proxy-manage/state.conf
# 格式：KEY=VALUE（每行一个，支持注释）
# ================================================================
state_get() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 1
    grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "'"
}

state_set() {
    local key="$1" val="$2"
    init_dirs
    if [[ -f "$STATE_FILE" ]] && grep -qE "^${key}=" "$STATE_FILE"; then
        sed -i "s|^${key}=.*|${key}='${val}'|" "$STATE_FILE"
    else
        echo "${key}='${val}'" >> "$STATE_FILE"
    fi
}

state_del() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] && sed -i "/^${key}=/d" "$STATE_FILE"
}

# ================================================================
# 系统检测
# ================================================================
check_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 身份运行（sudo -i 后执行）"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VER="${VERSION_ID:-0}"
    else
        die "无法识别操作系统"
    fi
    case "$OS_ID" in
        debian|ubuntu) ;;
        *) warn "当前系统 $OS_ID 未经充分测试，可能存在兼容性问题" ;;
    esac
}

get_server_ip() {
    local ip
    ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null) \
        || ip="YOUR_IP"
    echo "$ip"
}

# ================================================================
# 防火墙统一管理
# 支持：ufw / firewalld / iptables（按优先级检测）
# ================================================================
detect_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status:"; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

# $1=port $2=proto(tcp/udp)
fw_allow() {
    local port="$1" proto="${2:-tcp}"
    local fw
    fw=$(detect_firewall)
    case "$fw" in
        ufw)
            ufw allow "${port}/${proto}" comment "proxy-manage" &>/dev/null && ok "ufw: 已开放 ${port}/${proto}"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/${proto}" &>/dev/null
            firewall-cmd --reload &>/dev/null && ok "firewalld: 已开放 ${port}/${proto}"
            ;;
        iptables)
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
            # 持久化（Debian）
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            ok "iptables: 已开放 ${port}/${proto}"
            ;;
        none)
            warn "未检测到防火墙工具，请手动确认 ${port}/${proto} 已开放"
            ;;
    esac
}

fw_status() {
    local fw
    fw=$(detect_firewall)
    section "防火墙状态 (${fw})"
    case "$fw" in
        ufw)       ufw status numbered ;;
        firewalld) firewall-cmd --list-all ;;
        iptables)  iptables -L INPUT -n --line-numbers ;;
        none)      warn "未检测到防火墙" ;;
    esac
}

# 检查端口是否真正可达（本地监听）
check_port_listening() {
    local port="$1" proto="${2:-tcp}"
    if [[ "$proto" == "tcp" ]]; then
        ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    else
        ss -ulnp 2>/dev/null | grep -q ":${port} " && return 0
    fi
    return 1
}

# ================================================================
# BBR / 内核网络优化
# ================================================================
check_bbr() {
    local current
    current=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo "$current"
}

enable_bbr() {
    section "启用 BBR + fq 拥塞控制"
    local current
    current=$(check_bbr)
    if [[ "$current" == "bbr" ]]; then
        ok "BBR 已经启用"
        return 0
    fi

    # 检查内核版本 >= 4.9
    local kver
    kver=$(uname -r | cut -d. -f1-2 | tr -d '.')
    if (( kver < 49 )); then
        warn "内核版本过低（$(uname -r)），BBR 需要 >= 4.9"
        return 1
    fi

    cat >> /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-bbr.conf &>/dev/null
    local after
    after=$(check_bbr)
    if [[ "$after" == "bbr" ]]; then
        ok "BBR 已成功启用"
    else
        warn "BBR 启用失败（当前：${after}），可能需要重启"
    fi
}

# ================================================================
# 依赖安装
# ================================================================
install_deps() {
    info "更新包索引 & 安装基础依赖..."
    apt-get update -qq
    apt-get install -y -q curl wget unzip openssl ufw \
        ca-certificates gnupg lsb-release python3 socat cron 2>/dev/null || true
    ok "基础依赖安装完成"
}

# ================================================================
# Xray 安装 / 更新
# ================================================================
install_xray() {
    info "安装/更新 Xray（官方脚本）..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
    [[ -x "$XRAY_BIN" ]] || die "Xray 安装失败，请检查网络"
    ok "Xray $(${XRAY_BIN} version 2>/dev/null | head -1)"
}

update_xray() {
    section "更新 Xray 内核"
    local old_ver new_ver
    old_ver=$("$XRAY_BIN" version 2>/dev/null | head -1 || echo "未安装")
    install_xray
    new_ver=$("$XRAY_BIN" version 2>/dev/null | head -1)
    if [[ "$old_ver" == "$new_ver" ]]; then
        ok "Xray 已是最新版（${new_ver}）"
    else
        ok "Xray 更新完成：${old_ver} → ${new_ver}"
    fi
    systemctl is-active --quiet xray && systemctl restart xray && ok "Xray 服务已重启"
}

# ================================================================
# Hysteria2 安装 / 更新
# ================================================================
install_hy2_binary() {
    info "安装/更新 Hysteria2（官方脚本）..."
    bash -c "$(curl -fsSL https://get.hy2.sh/)" -- install
    HY2_BIN=$(command -v hysteria || echo "/usr/local/bin/hysteria")
    [[ -x "$HY2_BIN" ]] || die "Hysteria2 安装失败，请检查网络"
    ok "Hysteria2 $($HY2_BIN version 2>/dev/null | head -1)"
}

update_hy2() {
    section "更新 Hysteria2 内核"
    local old_ver new_ver
    old_ver=$("$HY2_BIN" version 2>/dev/null | head -1 || echo "未安装")
    install_hy2_binary
    new_ver=$("$HY2_BIN" version 2>/dev/null | head -1)
    if [[ "$old_ver" == "$new_ver" ]]; then
        ok "Hysteria2 已是最新版"
    else
        ok "Hysteria2 更新完成：${old_ver} → ${new_ver}"
    fi
    systemctl is-active --quiet hysteria-server && systemctl restart hysteria-server && ok "Hysteria2 服务已重启"
}

# ================================================================
# 生成 x25519 密钥（兼容新旧 xray 输出格式）
# ================================================================
gen_x25519() {
    local out
    out=$("$XRAY_BIN" x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$out" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$out"  | grep -iE "public|password" | grep -iv hash | awk '{print $NF}')
    [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] \
        || die "x25519 密钥解析失败，原始输出：\n${out}"
}

# ================================================================
# ACME 证书申请（使用 acme.sh + Let's Encrypt）
# ================================================================
install_acme() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        info "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="${1:-admin@example.com}" &>/dev/null
        ok "acme.sh 安装完成"
    fi
}

issue_cert() {
    local domain="$1" email="${2:-admin@example.com}"
    install_acme "$email"

    # 停止占用 80 的服务
    local stopped_nginx=0
    if ss -tlnp | grep -q ":80 "; then
        warn "端口 80 被占用，尝试临时停止 nginx..."
        systemctl stop nginx 2>/dev/null && stopped_nginx=1
    fi

    info "申请证书：${domain}（使用 standalone 模式）..."
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone \
        --server letsencrypt --keylength ec-256 \
        --fullchain-file "$HY2_CERT" \
        --key-file "$HY2_KEY" \
        --force 2>&1 | tail -5

    local ret=${PIPESTATUS[0]}

    [[ $stopped_nginx -eq 1 ]] && systemctl start nginx 2>/dev/null

    if [[ $ret -ne 0 ]]; then
        warn "证书申请失败（可能原因：域名未解析到此IP，或80端口被占用）"
        return 1
    fi

    chown hysteria "$HY2_CERT" "$HY2_KEY" 2>/dev/null || true
    ok "证书申请成功：${domain}"

    # 设置自动续期 cron
    ~/.acme.sh/acme.sh --install-cronjob &>/dev/null || true
    ok "已设置自动续期"
}

# 生成自签证书
gen_self_signed_cert() {
    local fake_domain="${1:-bing.com}"
    openssl req -x509 -nodes \
        -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$HY2_KEY" \
        -out "$HY2_CERT" \
        -subj "/CN=${fake_domain}" \
        -days 36500 2>/dev/null
    chown hysteria "$HY2_CERT" "$HY2_KEY" 2>/dev/null || true
    ok "自签证书生成完成（伪装域名：${fake_domain}，100年有效期）"
}

# 确保 hysteria 用户存在
ensure_hy2_user() {
    if ! id hysteria &>/dev/null; then
        useradd -r -s /sbin/nologin hysteria 2>/dev/null || true
    fi
}

# ================================================================
# Reality 用户 JSON 片段生成（多用户支持）
# ================================================================
# 从 state 读取所有 reality 用户，生成 JSON clients 数组
build_reality_clients_json() {
    local users_raw
    users_raw=$(state_get "REALITY_USERS" 2>/dev/null || echo "")
    if [[ -z "$users_raw" ]]; then
        echo "[]"
        return
    fi
    local json="["
    local first=1
    while IFS='|' read -r uuid name; do
        [[ -z "$uuid" ]] && continue
        [[ $first -eq 0 ]] && json+=","
        json+="{\"id\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"${name}\"}"
        first=0
    done <<< "$(echo "$users_raw" | tr ';' '\n')"
    json+="]"
    echo "$json"
}

# 从 state 读取所有 hy2 用户，生成 YAML userpass 块
build_hy2_users_yaml() {
    local users_raw
    users_raw=$(state_get "HY2_USERS" 2>/dev/null || echo "")
    if [[ -z "$users_raw" ]]; then
        echo "    default: 'change_me'"
        return
    fi
    local yaml=""
    while IFS='|' read -r pass name; do
        [[ -z "$pass" ]] && continue
        yaml+="    ${name}: '${pass}'\n"
    done <<< "$(echo "$users_raw" | tr ';' '\n')"
    echo -e "$yaml"
}

# ================================================================
# 写入 Xray Reality 配置
# ================================================================
write_xray_config() {
    local port uuid private_key public_key sni short_id1 short_id2 clients_json
    port=$(state_get "REALITY_PORT")
    sni=$(state_get "REALITY_SNI")
    private_key=$(state_get "REALITY_PRIVATE_KEY")
    short_id1=$(state_get "REALITY_SHORT_ID1")
    short_id2=$(state_get "REALITY_SHORT_ID2")
    clients_json=$(build_reality_clients_json)

    mkdir -p /usr/local/etc/xray /var/log/xray

    cat > "$XRAY_CONFIG" << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1", "localhost"]
  },
  "inbounds": [
    {
      "port": ${port},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": ${clients_json},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${sni}:443",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${private_key}",
          "shortIds": ["${short_id1}", "${short_id2}", ""]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    "$XRAY_BIN" -test -config "$XRAY_CONFIG" &>/dev/null \
        || die "Xray 配置校验失败，请检查参数"
    ok "Xray 配置已写入并校验通过"
}

# ================================================================
# 写入 Hysteria2 配置
# ================================================================
write_hy2_config() {
    local port masquerade_url users_yaml bandwidth_up bandwidth_down
    port=$(state_get "HY2_PORT")
    masquerade_url=$(state_get "HY2_MASQUERADE" || echo "https://www.bing.com/")
    bandwidth_up=$(state_get "HY2_BW_UP" || echo "")
    bandwidth_down=$(state_get "HY2_BW_DOWN" || echo "")
    users_yaml=$(build_hy2_users_yaml)

    mkdir -p /etc/hysteria

    # 带宽配置（可选）
    local bw_block=""
    if [[ -n "$bandwidth_up" && -n "$bandwidth_down" ]]; then
        bw_block="bandwidth:
  up: ${bandwidth_up} mbps
  down: ${bandwidth_down} mbps"
    fi

    cat > "$HY2_CONFIG" << EOF
listen: :${port}

tls:
  cert: ${HY2_CERT}
  key: ${HY2_KEY}

auth:
  type: userpass
  userpass:
${users_yaml}
${bw_block}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade_url}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

    ok "Hysteria2 配置已写入"
}

# ================================================================
# systemd 服务管理
# ================================================================
enable_service() {
    local svc="$1"
    systemctl daemon-reload
    systemctl enable "$svc" &>/dev/null
    systemctl restart "$svc"
    sleep 2
    if systemctl is-active --quiet "$svc"; then
        ok "${svc} 运行正常"
    else
        err "${svc} 启动失败，日志如下："
        journalctl -u "$svc" -n 20 --no-pager
        return 1
    fi
}

# ================================================================
# 保存节点信息到文件
# ================================================================
SAVE_FILE="/root/proxy-nodes.txt"

save_node_info() {
    local server_ip
    server_ip=$(get_server_ip)

    {
        echo "# ====================================================="
        echo "# proxy-manage 节点信息"
        echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "# ====================================================="
        echo ""

        if [[ "$(state_get REALITY_INSTALLED)" == "1" ]]; then
            local port sni pubkey short_id fp
            port=$(state_get "REALITY_PORT")
            sni=$(state_get "REALITY_SNI")
            pubkey=$(state_get "REALITY_PUBLIC_KEY")
            short_id=$(state_get "REALITY_SHORT_ID1")
            fp=$(state_get "REALITY_FP" || echo "chrome")
            echo "# ── VLESS + Reality ──────────────────────────────────"
            echo "协议     : VLESS + Reality + xtls-rprx-vision"
            echo "地址     : ${server_ip}"
            echo "端口     : ${port}"
            echo "公钥     : ${pubkey}"
            echo "Short ID : ${short_id}"
            echo "SNI      : ${sni}"
            echo "指纹     : ${fp}"
            echo ""
            echo "# 用户列表："
            local users_raw
            users_raw=$(state_get "REALITY_USERS" || echo "")
            while IFS='|' read -r uuid name; do
                [[ -z "$uuid" ]] && continue
                local link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pubkey}&sid=${short_id}&type=tcp&headerType=none#${name}"
                echo "  [${name}]"
                echo "  ${link}"
            done <<< "$(echo "$users_raw" | tr ';' '\n')"
            echo ""
        fi

        if [[ "$(state_get HY2_INSTALLED)" == "1" ]]; then
            local port insecure sni_hy2
            port=$(state_get "HY2_PORT")
            insecure=$(state_get "HY2_INSECURE" || echo "0")
            sni_hy2=$(state_get "HY2_CERT_DOMAIN" || echo "$server_ip")
            echo "# ── Hysteria2 ────────────────────────────────────────"
            echo "协议     : Hysteria2"
            echo "地址     : ${server_ip}"
            echo "端口     : ${port} (UDP)"
            echo "证书类型 : $(state_get HY2_CERT_TYPE || echo "自签")"
            echo ""
            echo "# 用户列表："
            local hy2_users
            hy2_users=$(state_get "HY2_USERS" || echo "")
            while IFS='|' read -r pass name; do
                [[ -z "$pass" ]] && continue
                local sni_param="${sni_hy2}"
                local ins_param=""
                [[ "$insecure" == "1" ]] && ins_param="&insecure=1"
                local hy2link="hy2://${pass}@${server_ip}:${port}?sni=${sni_param}${ins_param}#${name}"
                echo "  [${name}]"
                echo "  ${hy2link}"
            done <<< "$(echo "$hy2_users" | tr ';' '\n')"
            echo ""
        fi

        echo "# ── 常用命令 ─────────────────────────────────────────"
        echo "  proxy-manage                    # 打开管理菜单"
        echo "  systemctl status xray           # Xray 状态"
        echo "  systemctl status hysteria-server # Hy2 状态"
        echo "  journalctl -u xray -f           # Xray 实时日志"
        echo "  journalctl -u hysteria-server -f # Hy2 实时日志"

    } > "$SAVE_FILE"

    chmod 600 "$SAVE_FILE"
    ok "节点信息已保存至 ${SAVE_FILE}（权限 600）"
}

# ================================================================
# 显示节点信息（终端彩色）
# ================================================================
show_node_info() {
    local server_ip
    server_ip=$(get_server_ip)

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║              proxy-manage 节点信息                   ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

    if [[ "$(state_get REALITY_INSTALLED)" != "1" && "$(state_get HY2_INSTALLED)" != "1" ]]; then
        warn "尚未安装任何协议"
        return
    fi

    if [[ "$(state_get REALITY_INSTALLED)" == "1" ]]; then
        local port sni pubkey short_id fp
        port=$(state_get "REALITY_PORT")
        sni=$(state_get "REALITY_SNI")
        pubkey=$(state_get "REALITY_PUBLIC_KEY")
        short_id=$(state_get "REALITY_SHORT_ID1")
        fp=$(state_get "REALITY_FP" || echo "chrome")

        echo ""
        echo -e "${CYAN}${BOLD}▶ VLESS + Reality + Vision${NC}"
        echo -e "  地址    : ${BOLD}${server_ip}:${port}${NC}"
        echo -e "  SNI     : ${sni}"
        echo -e "  公钥    : ${pubkey}"
        echo -e "  Short ID: ${short_id}"
        echo -e "  指纹    : ${fp}"
        echo ""

        local users_raw
        users_raw=$(state_get "REALITY_USERS" || echo "")
        while IFS='|' read -r uuid name; do
            [[ -z "$uuid" ]] && continue
            local link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pubkey}&sid=${short_id}&type=tcp&headerType=none#${name}"
            echo -e "  ${YELLOW}[${name}]${NC}"
            echo -e "  ${DIM}UUID: ${uuid}${NC}"
            echo -e "  ${link}"
            echo ""
        done <<< "$(echo "$users_raw" | tr ';' '\n')"
    fi

    if [[ "$(state_get HY2_INSTALLED)" == "1" ]]; then
        local port insecure sni_hy2
        port=$(state_get "HY2_PORT")
        insecure=$(state_get "HY2_INSECURE" || echo "0")
        sni_hy2=$(state_get "HY2_CERT_DOMAIN" || echo "$server_ip")

        echo ""
        echo -e "${MAGENTA}${BOLD}▶ Hysteria2${NC}"
        echo -e "  地址    : ${BOLD}${server_ip}:${port} (UDP)${NC}"
        echo -e "  证书    : $(state_get HY2_CERT_TYPE || echo "自签")"
        [[ "$insecure" == "1" ]] && echo -e "  ${YELLOW}[注意] 自签证书，客户端需开启「允许不安全连接」${NC}"
        echo ""

        local hy2_users
        hy2_users=$(state_get "HY2_USERS" || echo "")
        while IFS='|' read -r pass name; do
            [[ -z "$pass" ]] && continue
            local sni_param="${sni_hy2}"
            local ins_param=""
            [[ "$insecure" == "1" ]] && ins_param="&insecure=1"
            local hy2link="hy2://${pass}@${server_ip}:${port}?sni=${sni_param}${ins_param}#${name}"
            echo -e "  ${YELLOW}[${name}]${NC}"
            echo -e "  ${DIM}密码: ${pass}${NC}"
            echo -e "  ${hy2link}"
            echo ""
        done <<< "$(echo "$hy2_users" | tr ';' '\n')"
    fi

    save_node_info
}

# ================================================================
# 网络环境诊断
# ================================================================
network_check() {
    section "网络环境诊断"

    local server_ip
    server_ip=$(get_server_ip)
    echo -e "  公网IP   : ${BOLD}${server_ip}${NC}"
    echo -e "  内核     : $(uname -r)"
    echo -e "  BBR状态  : $(check_bbr)"
    echo ""

    local fw
    fw=$(detect_firewall)
    echo -e "  防火墙   : ${fw}"

    echo ""
    echo -e "${CYAN}  端口监听状态：${NC}"
    printf "  %-10s %-8s %-12s\n" "端口" "协议" "状态"
    printf "  %-10s %-8s %-12s\n" "────" "────" "────"

    for entry in "REALITY_PORT:tcp:Reality" "HY2_PORT:udp:Hysteria2"; do
        IFS=':' read -r key proto label <<< "$entry"
        local port
        port=$(state_get "$key" 2>/dev/null || echo "")
        [[ -z "$port" ]] && continue
        if check_port_listening "$port" "$proto"; then
            printf "  %-10s %-8s ${GREEN}%-12s${NC}\n" "$port" "$proto" "监听中 ✓"
        else
            printf "  %-10s %-8s ${YELLOW}%-12s${NC}\n" "$port" "$proto" "未监听 ✗"
        fi
    done

    echo ""
    echo -e "${CYAN}  服务状态：${NC}"
    for svc in "xray:Xray" "hysteria-server:Hysteria2"; do
        IFS=':' read -r name label <<< "$svc"
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} ${label}: 运行中"
        elif systemctl list-units --type=service 2>/dev/null | grep -q "$name"; then
            echo -e "  ${RED}●${NC} ${label}: 已停止"
        else
            echo -e "  ${DIM}●${NC} ${label}: 未安装"
        fi
    done

    echo ""
    echo -e "${CYAN}  外部连通性测试：${NC}"
    for host in "8.8.8.8:Google DNS" "1.1.1.1:Cloudflare DNS"; do
        IFS=':' read -r ip label <<< "$host"
        if ping -c 1 -W 2 "$ip" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${label} (${ip})"
        else
            echo -e "  ${RED}✗${NC} ${label} (${ip})"
        fi
    done
}

# ================================================================
# 安装 Reality
# ================================================================
install_reality() {
    section "安装 VLESS + Reality + Vision"

    # ── 端口 ──────────────────────────────────────────────────────
    echo ""
    read -rp "  监听端口 [默认 443]：" port_in
    local port="${port_in:-443}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
        || die "端口无效：${port}"

    # 检查端口冲突
    local conflict
    conflict=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -v "xray" || true)
    if [[ -n "$conflict" ]]; then
        warn "端口 ${port}/TCP 被占用："
        echo "$conflict"
        read -rp "  是否继续（强制，可能失败）？[y/N]：" fc
        [[ "$fc" =~ ^[Yy]$ ]] || return 1
    fi

    # ── SNI 目标 ──────────────────────────────────────────────────
    echo ""
    echo "  选择伪装目标（SNI）— 选 TLS 1.3 + H2 支持的大网站："
    echo "  1) addons.mozilla.org   （推荐，Mozilla CDN）"
    echo "  2) www.microsoft.com    （微软，稳定）"
    echo "  3) www.apple.com        （苹果）"
    echo "  4) dl.google.com        （谷歌下载）"
    echo "  5) 自定义"
    echo ""
    read -rp "  选择 [1-5，默认 1]：" sni_choice
    sni_choice="${sni_choice:-1}"
    local sni
    case "$sni_choice" in
        1) sni="addons.mozilla.org" ;;
        2) sni="www.microsoft.com" ;;
        3) sni="www.apple.com" ;;
        4) sni="dl.google.com" ;;
        5)
            read -rp "  输入自定义 SNI（需支持 TLS 1.3）：" sni
            [[ -n "$sni" ]] || die "SNI 不能为空"
            ;;
        *) sni="addons.mozilla.org" ;;
    esac
    ok "SNI：${sni}"

    # ── TLS 指纹 ──────────────────────────────────────────────────
    echo ""
    echo "  选择 TLS 指纹（fp）："
    echo "  1) chrome   （推荐）"
    echo "  2) firefox"
    echo "  3) safari"
    echo "  4) edge"
    echo "  5) random   （随机）"
    read -rp "  选择 [1-5，默认 1]：" fp_choice
    local fp
    case "${fp_choice:-1}" in
        1) fp="chrome" ;;
        2) fp="firefox" ;;
        3) fp="safari" ;;
        4) fp="edge" ;;
        5) fp="random" ;;
        *) fp="chrome" ;;
    esac

    # ── 初始用户 ──────────────────────────────────────────────────
    echo ""
    read -rp "  初始用户名 [默认 default]：" uname_in
    local uname="${uname_in:-default}"
    read -rp "  UUID（留空自动生成）：" uuid_in
    local uuid="${uuid_in:-$("$XRAY_BIN" uuid)}"

    # ── 生成密钥 ──────────────────────────────────────────────────
    gen_x25519
    local short_id1 short_id2
    short_id1=$(openssl rand -hex 4)
    short_id2=$(openssl rand -hex 8)

    # ── 写入 state ────────────────────────────────────────────────
    state_set "REALITY_INSTALLED" "1"
    state_set "REALITY_PORT" "$port"
    state_set "REALITY_SNI" "$sni"
    state_set "REALITY_FP" "$fp"
    state_set "REALITY_PRIVATE_KEY" "$PRIVATE_KEY"
    state_set "REALITY_PUBLIC_KEY" "$PUBLIC_KEY"
    state_set "REALITY_SHORT_ID1" "$short_id1"
    state_set "REALITY_SHORT_ID2" "$short_id2"
    state_set "REALITY_USERS" "${uuid}|${uname}"

    # ── 写配置 & 启动 ─────────────────────────────────────────────
    write_xray_config
    fw_allow "$port" "tcp"
    enable_service "xray"

    ok "VLESS+Reality 安装完成"
    echo ""
    echo -e "  ${DIM}UUID     : ${uuid}${NC}"
    echo -e "  ${DIM}公钥     : ${PUBLIC_KEY}${NC}"
    echo -e "  ${DIM}Short ID : ${short_id1}${NC}"
}

# ================================================================
# 安装 Hysteria2
# ================================================================
install_hysteria2() {
    section "安装 Hysteria2"
    ensure_hy2_user

    # ── 端口 ──────────────────────────────────────────────────────
    echo ""
    read -rp "  监听端口 [默认 443]：" port_in
    local port="${port_in:-443}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
        || die "端口无效：${port}"

    # ── 证书类型 ──────────────────────────────────────────────────
    echo ""
    echo "  选择证书类型："
    echo "  1) 自签证书  — 无需域名，客户端需开启「允许不安全连接」"
    echo "     ${DIM}注意：自签证书近期有随机阻断风险，推荐有域名用户选 2${NC}"
    echo "  2) ACME证书  — 需要域名且已解析到本机 IP，安全性更好"
    echo "  3) 已有证书  — 使用已存在的证书文件"
    echo ""
    read -rp "  选择 [1-3，默认 1]：" cert_choice
    cert_choice="${cert_choice:-1}"

    local cert_type insecure cert_domain
    case "$cert_choice" in
        1)
            cert_type="selfsigned"
            insecure="1"
            read -rp "  自签证书伪装域名 [默认 bing.com]：" fd
            cert_domain="${fd:-bing.com}"
            gen_self_signed_cert "$cert_domain"
            ;;
        2)
            cert_type="acme"
            insecure="0"
            read -rp "  输入域名（需已解析到本机）：" cert_domain
            [[ -n "$cert_domain" ]] || die "域名不能为空"
            read -rp "  ACME 邮箱 [默认 admin@example.com]：" acme_email
            acme_email="${acme_email:-admin@example.com}"
            issue_cert "$cert_domain" "$acme_email" || {
                warn "ACME 证书申请失败，是否回退到自签证书？[y/N]："
                read -r fallback
                if [[ "$fallback" =~ ^[Yy]$ ]]; then
                    cert_type="selfsigned"
                    insecure="1"
                    cert_domain="bing.com"
                    gen_self_signed_cert "$cert_domain"
                else
                    return 1
                fi
            }
            ;;
        3)
            cert_type="custom"
            insecure="0"
            read -rp "  证书文件路径（.crt/.pem）：" custom_cert
            read -rp "  私钥文件路径（.key）：" custom_key
            [[ -f "$custom_cert" && -f "$custom_key" ]] || die "证书文件不存在"
            cp "$custom_cert" "$HY2_CERT"
            cp "$custom_key" "$HY2_KEY"
            read -rp "  证书对应域名（用于 SNI）：" cert_domain
            ;;
    esac

    # ── 初始用户 ──────────────────────────────────────────────────
    echo ""
    read -rp "  初始用户名 [默认 default]：" uname_in
    local uname="${uname_in:-default}"
    read -rp "  密码（留空自动生成）：" pass_in
    local pass="${pass_in:-$(openssl rand -hex 16)}"

    # ── 带宽限制（可选）──────────────────────────────────────────
    echo ""
    read -rp "  上行带宽限制 Mbps（留空不限）：" bw_up
    read -rp "  下行带宽限制 Mbps（留空不限）：" bw_down

    # ── 伪装目标 ──────────────────────────────────────────────────
    echo ""
    read -rp "  伪装目标 URL [默认 https://www.bing.com/]：" masq_in
    local masquerade="${masq_in:-https://www.bing.com/}"

    # ── 写入 state ────────────────────────────────────────────────
    state_set "HY2_INSTALLED" "1"
    state_set "HY2_PORT" "$port"
    state_set "HY2_CERT_TYPE" "$cert_type"
    state_set "HY2_CERT_DOMAIN" "${cert_domain:-$port}"
    state_set "HY2_INSECURE" "$insecure"
    state_set "HY2_MASQUERADE" "$masquerade"
    state_set "HY2_USERS" "${pass}|${uname}"
    [[ -n "$bw_up" ]]   && state_set "HY2_BW_UP" "$bw_up"
    [[ -n "$bw_down" ]] && state_set "HY2_BW_DOWN" "$bw_down"

    # ── 写配置 & 启动 ─────────────────────────────────────────────
    write_hy2_config
    fw_allow "$port" "udp"
    # Hy2 需要 UDP，某些云防火墙可能只开 TCP
    echo ""
    warn "Hysteria2 使用 UDP 协议，请同时确认云服务商控制台（Oracle/AWS 等安全组）已开放 UDP:${port}"
    enable_service "hysteria-server"

    ok "Hysteria2 安装完成"
    echo ""
    [[ "$insecure" == "1" ]] && warn "自签证书：客户端需开启「允许不安全连接 / skip cert verify」"
    echo -e "  ${DIM}密码: ${pass}${NC}"
}

# ================================================================
# 用户管理
# ================================================================
manage_users() {
    while true; do
        echo ""
        echo -e "${BOLD}用户管理${NC}"
        echo "  1) 查看所有用户"
        echo "  2) 添加 Reality 用户"
        echo "  3) 删除 Reality 用户"
        echo "  4) 添加 Hysteria2 用户"
        echo "  5) 删除 Hysteria2 用户"
        echo "  0) 返回"
        echo ""
        read -rp "  选择：" choice

        case "$choice" in
            1) list_users ;;
            2) add_reality_user ;;
            3) del_reality_user ;;
            4) add_hy2_user ;;
            5) del_hy2_user ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

list_users() {
    echo ""
    if [[ "$(state_get REALITY_INSTALLED)" == "1" ]]; then
        echo -e "${CYAN}Reality 用户：${NC}"
        local users_raw
        users_raw=$(state_get "REALITY_USERS" || echo "")
        local i=1
        while IFS='|' read -r uuid name; do
            [[ -z "$uuid" ]] && continue
            echo "  ${i}) ${name} — ${uuid}"
            (( i++ ))
        done <<< "$(echo "$users_raw" | tr ';' '\n')"
    fi
    echo ""
    if [[ "$(state_get HY2_INSTALLED)" == "1" ]]; then
        echo -e "${MAGENTA}Hysteria2 用户：${NC}"
        local hy2_users
        hy2_users=$(state_get "HY2_USERS" || echo "")
        local i=1
        while IFS='|' read -r pass name; do
            [[ -z "$pass" ]] && continue
            echo "  ${i}) ${name} — ${pass}"
            (( i++ ))
        done <<< "$(echo "$hy2_users" | tr ';' '\n')"
    fi
}

add_reality_user() {
    [[ "$(state_get REALITY_INSTALLED)" == "1" ]] || { warn "Reality 未安装"; return; }
    read -rp "  用户名：" uname
    [[ -n "$uname" ]] || { warn "用户名不能为空"; return; }
    read -rp "  UUID（留空自动生成）：" uuid_in
    local uuid="${uuid_in:-$("$XRAY_BIN" uuid)}"

    local current
    current=$(state_get "REALITY_USERS" || echo "")
    if [[ -z "$current" ]]; then
        state_set "REALITY_USERS" "${uuid}|${uname}"
    else
        state_set "REALITY_USERS" "${current};${uuid}|${uname}"
    fi

    write_xray_config
    systemctl reload xray 2>/dev/null || systemctl restart xray
    ok "已添加 Reality 用户：${uname}（${uuid}）"
}

del_reality_user() {
    [[ "$(state_get REALITY_INSTALLED)" == "1" ]] || { warn "Reality 未安装"; return; }
    list_users
    read -rp "  输入要删除的用户名：" del_name
    local current
    current=$(state_get "REALITY_USERS" || echo "")
    local new_users=""
    while IFS='|' read -r uuid name; do
        [[ -z "$uuid" ]] && continue
        if [[ "$name" != "$del_name" ]]; then
            [[ -z "$new_users" ]] && new_users="${uuid}|${name}" \
                || new_users="${new_users};${uuid}|${name}"
        fi
    done <<< "$(echo "$current" | tr ';' '\n')"
    state_set "REALITY_USERS" "$new_users"
    write_xray_config
    systemctl restart xray
    ok "已删除 Reality 用户：${del_name}"
}

add_hy2_user() {
    [[ "$(state_get HY2_INSTALLED)" == "1" ]] || { warn "Hysteria2 未安装"; return; }
    read -rp "  用户名：" uname
    [[ -n "$uname" ]] || { warn "用户名不能为空"; return; }
    read -rp "  密码（留空自动生成）：" pass_in
    local pass="${pass_in:-$(openssl rand -hex 16)}"

    local current
    current=$(state_get "HY2_USERS" || echo "")
    if [[ -z "$current" ]]; then
        state_set "HY2_USERS" "${pass}|${uname}"
    else
        state_set "HY2_USERS" "${current};${pass}|${uname}"
    fi

    write_hy2_config
    systemctl restart hysteria-server
    ok "已添加 Hysteria2 用户：${uname}（密码：${pass}）"
}

del_hy2_user() {
    [[ "$(state_get HY2_INSTALLED)" == "1" ]] || { warn "Hysteria2 未安装"; return; }
    list_users
    read -rp "  输入要删除的用户名：" del_name
    local current
    current=$(state_get "HY2_USERS" || echo "")
    local new_users=""
    while IFS='|' read -r pass name; do
        [[ -z "$pass" ]] && continue
        if [[ "$name" != "$del_name" ]]; then
            [[ -z "$new_users" ]] && new_users="${pass}|${name}" \
                || new_users="${new_users};${pass}|${name}"
        fi
    done <<< "$(echo "$current" | tr ';' '\n')"
    state_set "HY2_USERS" "$new_users"
    write_hy2_config
    systemctl restart hysteria-server
    ok "已删除 Hysteria2 用户：${del_name}"
}

# ================================================================
# 修改配置
# ================================================================
modify_config() {
    while true; do
        echo ""
        echo -e "${BOLD}修改配置${NC}"
        echo "  ── Reality ──────────────────────────────"
        echo "  1) 修改 Reality 端口"
        echo "  2) 修改 Reality SNI 目标"
        echo "  3) 修改 Reality TLS 指纹"
        echo "  4) 重新生成 Reality 密钥对"
        echo "  ── Hysteria2 ────────────────────────────"
        echo "  5) 修改 Hysteria2 端口"
        echo "  6) 修改 Hysteria2 带宽限制"
        echo "  7) 修改 Hysteria2 伪装目标"
        echo "  8) 重新申请/更换证书"
        echo "  0) 返回"
        echo ""
        read -rp "  选择：" choice

        case "$choice" in
            1)
                [[ "$(state_get REALITY_INSTALLED)" == "1" ]] || { warn "Reality 未安装"; continue; }
                read -rp "  新端口：" p
                [[ "$p" =~ ^[0-9]+$ ]] || { warn "端口无效"; continue; }
                state_set "REALITY_PORT" "$p"
                write_xray_config; fw_allow "$p" tcp
                systemctl restart xray && ok "Reality 端口已改为 ${p}"
                ;;
            2)
                [[ "$(state_get REALITY_INSTALLED)" == "1" ]] || { warn "Reality 未安装"; continue; }
                read -rp "  新 SNI：" s
                [[ -n "$s" ]] || { warn "SNI 不能为空"; continue; }
                state_set "REALITY_SNI" "$s"
                write_xray_config; systemctl restart xray && ok "SNI 已改为 ${s}"
                ;;
            3)
                [[ "$(state_get REALITY_INSTALLED)" == "1" ]] || { warn "Reality 未安装"; continue; }
                echo "  chrome / firefox / safari / edge / random"
                read -rp "  新指纹：" fp
                state_set "REALITY_FP" "$fp"
                ok "指纹已更新（仅影响客户端配置，服务端无需重启）"
                ;;
            4)
                [[ "$(state_get REALITY_INSTALLED)" == "1" ]] || { warn "Reality 未安装"; continue; }
                gen_x25519
                local sid1 sid2
                sid1=$(openssl rand -hex 4); sid2=$(openssl rand -hex 8)
                state_set "REALITY_PRIVATE_KEY" "$PRIVATE_KEY"
                state_set "REALITY_PUBLIC_KEY" "$PUBLIC_KEY"
                state_set "REALITY_SHORT_ID1" "$sid1"
                state_set "REALITY_SHORT_ID2" "$sid2"
                write_xray_config; systemctl restart xray
                ok "密钥对已重新生成，请更新所有客户端配置"
                ;;
            5)
                [[ "$(state_get HY2_INSTALLED)" == "1" ]] || { warn "Hysteria2 未安装"; continue; }
                read -rp "  新端口：" p
                [[ "$p" =~ ^[0-9]+$ ]] || { warn "端口无效"; continue; }
                state_set "HY2_PORT" "$p"
                write_hy2_config; fw_allow "$p" udp
                systemctl restart hysteria-server && ok "Hysteria2 端口已改为 ${p}"
                ;;
            6)
                [[ "$(state_get HY2_INSTALLED)" == "1" ]] || { warn "Hysteria2 未安装"; continue; }
                read -rp "  上行带宽 Mbps（留空清除限制）：" bw_up
                read -rp "  下行带宽 Mbps（留空清除限制）：" bw_down
                if [[ -n "$bw_up" ]]; then state_set "HY2_BW_UP" "$bw_up"; else state_del "HY2_BW_UP"; fi
                if [[ -n "$bw_down" ]]; then state_set "HY2_BW_DOWN" "$bw_down"; else state_del "HY2_BW_DOWN"; fi
                write_hy2_config; systemctl restart hysteria-server && ok "带宽设置已更新"
                ;;
            7)
                [[ "$(state_get HY2_INSTALLED)" == "1" ]] || { warn "Hysteria2 未安装"; continue; }
                read -rp "  新伪装目标 URL：" masq
                [[ -n "$masq" ]] || { warn "URL 不能为空"; continue; }
                state_set "HY2_MASQUERADE" "$masq"
                write_hy2_config; systemctl restart hysteria-server && ok "伪装目标已更新"
                ;;
            8)
                [[ "$(state_get HY2_INSTALLED)" == "1" ]] || { warn "Hysteria2 未安装"; continue; }
                echo "  1) 自签证书  2) ACME证书  3) 自定义证书"
                read -rp "  选择：" cc
                case "$cc" in
                    1)
                        read -rp "  伪装域名 [默认 bing.com]：" fd
                        cert_domain="${fd:-bing.com}"
                        gen_self_signed_cert "$cert_domain"
                        state_set "HY2_CERT_TYPE" "selfsigned"
                        state_set "HY2_CERT_DOMAIN" "$cert_domain"
                        state_set "HY2_INSECURE" "1"
                        ;;
                    2)
                        read -rp "  域名：" cd; read -rp "  邮箱：" em
                        issue_cert "$cd" "${em:-admin@example.com}"
                        state_set "HY2_CERT_TYPE" "acme"
                        state_set "HY2_CERT_DOMAIN" "$cd"
                        state_set "HY2_INSECURE" "0"
                        ;;
                    3)
                        read -rp "  cert 路径：" cp2; read -rp "  key 路径：" kp
                        [[ -f "$cp2" && -f "$kp" ]] || { warn "文件不存在"; continue; }
                        cp "$cp2" "$HY2_CERT"; cp "$kp" "$HY2_KEY"
                        read -rp "  域名：" cd
                        state_set "HY2_CERT_TYPE" "custom"
                        state_set "HY2_CERT_DOMAIN" "$cd"
                        state_set "HY2_INSECURE" "0"
                        ;;
                esac
                write_hy2_config; systemctl restart hysteria-server && ok "证书已更换"
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ================================================================
# 服务管理
# ================================================================
service_manage() {
    while true; do
        echo ""
        echo -e "${BOLD}服务管理${NC}"
        echo "  1) 查看所有服务状态"
        echo "  2) 重启 Xray"
        echo "  3) 重启 Hysteria2"
        echo "  4) 重启全部"
        echo "  5) 停止 Xray"
        echo "  6) 停止 Hysteria2"
        echo "  7) 查看 Xray 实时日志"
        echo "  8) 查看 Hysteria2 实时日志"
        echo "  9) 清空日志文件"
        echo "  0) 返回"
        echo ""
        read -rp "  选择：" choice

        case "$choice" in
            1)
                echo ""
                systemctl status xray --no-pager -l 2>/dev/null || echo "Xray 未安装"
                echo ""
                systemctl status hysteria-server --no-pager -l 2>/dev/null || echo "Hysteria2 未安装"
                ;;
            2) systemctl restart xray && ok "Xray 已重启" ;;
            3) systemctl restart hysteria-server && ok "Hysteria2 已重启" ;;
            4)
                systemctl restart xray 2>/dev/null; systemctl restart hysteria-server 2>/dev/null
                ok "全部服务已重启"
                ;;
            5) systemctl stop xray && ok "Xray 已停止" ;;
            6) systemctl stop hysteria-server && ok "Hysteria2 已停止" ;;
            7) journalctl -u xray -f --no-pager ;;
            8) journalctl -u hysteria-server -f --no-pager ;;
            9)
                > /var/log/xray/access.log 2>/dev/null
                > /var/log/xray/error.log  2>/dev/null
                journalctl --rotate &>/dev/null; journalctl --vacuum-time=1s &>/dev/null
                ok "日志已清空"
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ================================================================
# 更新内核
# ================================================================
update_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}更新内核${NC}"
        echo "  1) 更新 Xray"
        echo "  2) 更新 Hysteria2"
        echo "  3) 更新全部"
        echo "  4) 更新本脚本（proxy-manage）"
        echo "  0) 返回"
        echo ""
        read -rp "  选择：" choice

        case "$choice" in
            1) [[ -x "$XRAY_BIN" ]] && update_xray || warn "Xray 未安装" ;;
            2) [[ -x "$HY2_BIN"  ]] && update_hy2  || warn "Hysteria2 未安装" ;;
            3)
                [[ -x "$XRAY_BIN" ]] && update_xray
                [[ -x "$HY2_BIN"  ]] && update_hy2
                ;;
            4) self_update ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

self_update() {
    info "检查脚本更新..."
    local remote_url="https://raw.githubusercontent.com/MaoShiSanKe/proxy-manage/main/proxy-manage.sh"
    local tmp="/tmp/proxy-manage-new.sh"
    if curl -fsSL --max-time 15 "$remote_url" -o "$tmp" 2>/dev/null; then
        chmod +x "$tmp"
        cp "$tmp" "$SCRIPT_PATH"
        ok "脚本已更新，请重新运行 proxy-manage"
        exit 0
    else
        warn "下载失败，请手动更新"
    fi
}

# ================================================================
# 卸载
# ================================================================
uninstall_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${RED}卸载${NC}"
        echo "  1) 卸载 Xray（Reality）"
        echo "  2) 卸载 Hysteria2"
        echo "  3) 卸载全部（含配置和状态）"
        echo "  0) 返回"
        echo ""
        read -rp "  选择：" choice

        case "$choice" in
            1)
                read -rp "  确认卸载 Xray？[y/N]：" c
                [[ "$c" =~ ^[Yy]$ ]] || continue
                systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null
                bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null
                state_set "REALITY_INSTALLED" "0"
                ok "Xray 已卸载"
                ;;
            2)
                read -rp "  确认卸载 Hysteria2？[y/N]：" c
                [[ "$c" =~ ^[Yy]$ ]] || continue
                systemctl stop hysteria-server 2>/dev/null; systemctl disable hysteria-server 2>/dev/null
                bash -c "$(curl -fsSL https://get.hy2.sh/)" -- remove 2>/dev/null
                rm -f "$HY2_CERT" "$HY2_KEY" "$HY2_CONFIG"
                state_set "HY2_INSTALLED" "0"
                ok "Hysteria2 已卸载"
                ;;
            3)
                read -rp "  确认卸载全部并清除所有配置？[y/N]：" c
                [[ "$c" =~ ^[Yy]$ ]] || continue
                systemctl stop xray hysteria-server 2>/dev/null
                systemctl disable xray hysteria-server 2>/dev/null
                bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null
                bash -c "$(curl -fsSL https://get.hy2.sh/)" -- remove 2>/dev/null
                rm -rf "$STATE_DIR" /etc/hysteria "$LOG_DIR"
                # 移除全局命令
                rm -f /usr/local/bin/proxy-manage
                ok "全部卸载完成"
                exit 0
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ================================================================
# 全局命令安装（proxy-manage）
# ================================================================
install_global_cmd() {
    local target="/usr/local/bin/proxy-manage"
    if [[ "$SCRIPT_PATH" != "$target" ]]; then
        cp "$SCRIPT_PATH" "$target"
        chmod +x "$target"
        ok "已注册全局命令：proxy-manage"
        tip "以后直接输入 proxy-manage 即可打开管理菜单"
    fi
}

# ================================================================
# 主菜单
# ================================================================
main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}${BOLD}║        proxy-manage v${VERSION}  —  代理节点管理脚本            ║${NC}"
        echo -e "${BLUE}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"

        # 状态指示
        local r_status="${RED}✗ 未安装${NC}"
        local h_status="${RED}✗ 未安装${NC}"
        [[ "$(state_get REALITY_INSTALLED)" == "1" ]] && {
            systemctl is-active --quiet xray 2>/dev/null \
                && r_status="${GREEN}✓ 运行中${NC}" \
                || r_status="${YELLOW}⚠ 已停止${NC}"
        }
        [[ "$(state_get HY2_INSTALLED)" == "1" ]] && {
            systemctl is-active --quiet hysteria-server 2>/dev/null \
                && h_status="${GREEN}✓ 运行中${NC}" \
                || h_status="${YELLOW}⚠ 已停止${NC}"
        }

        echo -e "${BLUE}║${NC}  Reality  : $(printf '%-20b' "$r_status")  Hysteria2 : $(printf '%-20b' "$h_status")   ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  安装                                                    ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}1)${NC} 安装 VLESS + Reality + Vision                      ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}2)${NC} 安装 Hysteria2                                      ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}3)${NC} 同时安装两者（推荐，互不干扰）                     ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  管理                                                    ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}4)${NC} 查看节点信息 & 分享链接                            ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}5)${NC} 用户管理（添加/删除用户）                          ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}6)${NC} 修改配置（端口/SNI/证书/带宽等）                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}7)${NC} 服务管理（启停/重启/日志）                         ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  系统                                                    ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}8)${NC} 网络诊断（端口/防火墙/连通性检查）                 ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}9)${NC} 防火墙管理                                          ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}10)${NC} BBR 加速管理                                        ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}11)${NC} 更新内核 / 脚本                                     ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}12)${NC} 卸载                                                ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}   ${RED}0)${NC} 退出                                                ${BLUE}║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "  请选择 [0-12]：" choice

        case "$choice" in
            1)
                [[ -x "$XRAY_BIN" ]] || install_xray
                install_reality && show_node_info
                ;;
            2)
                [[ -x "$HY2_BIN" ]] || install_hy2_binary
                install_hysteria2 && show_node_info
                ;;
            3)
                section "同时安装 Reality + Hysteria2"
                [[ -x "$XRAY_BIN" ]] || install_xray
                [[ -x "$HY2_BIN"  ]] || install_hy2_binary
                install_reality
                echo ""
                install_hysteria2
                echo ""
                show_node_info
                ;;
            4) show_node_info ;;
            5) manage_users ;;
            6) modify_config ;;
            7) service_manage ;;
            8) network_check ;;
            9)
                fw_status
                echo ""
                read -rp "  手动开放端口（格式 端口/协议，如 8443/tcp）：" fw_in
                if [[ -n "$fw_in" ]]; then
                    IFS='/' read -r fw_p fw_proto <<< "$fw_in"
                    fw_allow "$fw_p" "${fw_proto:-tcp}"
                fi
                ;;
            10)
                section "BBR 加速"
                echo -e "  当前拥塞控制：$(check_bbr)"
                echo ""
                echo "  1) 启用 BBR + fq"
                echo "  2) 查看可用算法"
                echo "  0) 返回"
                read -rp "  选择：" bbr_c
                case "$bbr_c" in
                    1) enable_bbr ;;
                    2) sysctl net.ipv4.tcp_available_congestion_control ;;
                esac
                ;;
            11) update_menu ;;
            12) uninstall_menu ;;
            0)
                echo -e "\n${DIM}  再见 (＿ ＿*)ノ彡${NC}\n"
                exit 0
                ;;
            *) warn "无效选项，请输入 0-12" ;;
        esac

        echo ""
        read -rp "  按 Enter 返回菜单..." _
    done
}

# ================================================================
# 首次运行：安装依赖
# ================================================================
first_run_setup() {
    if [[ ! -f "${STATE_DIR}/.initialized" ]]; then
        section "首次运行初始化"
        detect_os
        install_deps
        enable_bbr
        install_global_cmd
        init_dirs
        touch "${STATE_DIR}/.initialized"
        ok "初始化完成"
        echo ""
    fi
}

# ================================================================
# 入口
# ================================================================
check_root
init_dirs
first_run_setup
main_menu
