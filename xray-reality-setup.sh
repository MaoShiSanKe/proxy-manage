#!/bin/bash
# ================================================================
# VLESS + Reality + xtls-rprx-vision 一键脚本
# 支持：纯节点模式 / 与 nginx Web 服务共存模式
# 适用：Debian / Ubuntu，无面板依赖
# ================================================================
set -e

# ── 颜色输出 ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR ]${NC} $*"; exit 1; }
section() { echo -e "\n${BLUE}=== $* ===${NC}"; }

# ── 0. 权限检查 ─────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请用 root 身份运行（sudo -i 后执行）"

XRAY_BIN=""
CONFIG_FILE="/usr/local/etc/xray/config.json"
SAVE_FILE="/root/xray-config.txt"

# ================================================================
# 1. 系统更新 & 依赖
# ================================================================
section "1/6  更新系统 & 安装依赖"
apt update -y && apt upgrade -y
apt install -y curl unzip openssl ufw
ok "依赖安装完成"

# ================================================================
# 2. 安装 Xray
# ================================================================
section "2/6  安装 Xray（官方最新正式版）"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
[[ ! -x "$XRAY_BIN" ]] && error "Xray 安装失败，请检查网络后重试"
ok "Xray 版本：$($XRAY_BIN version | head -1)"

# ================================================================
# 3. 交互选项
# ================================================================
section "3/6  配置选项"

# ── 模式选择 ────────────────────────────────────────────────────
echo ""
echo "  请选择部署模式："
echo "  1) 纯节点模式    — Xray 独占端口，无其他 Web 服务"
echo "  2) 共存模式      — 服务器已有 nginx Web 服务，自动处理冲突"
echo ""
while true; do
    read -rp "  输入选项 [1/2]：" MODE_CHOICE
    case "$MODE_CHOICE" in
        1) MODE="standalone"; break ;;
        2) MODE="coexist";    break ;;
        *) warn "请输入 1 或 2" ;;
    esac
done

# ── 端口选择 ────────────────────────────────────────────────────
echo ""
if [[ "$MODE" == "standalone" ]]; then
    read -rp "  监听端口 [直接回车默认 443]：" PORT_INPUT
    PORT="${PORT_INPUT:-443}"
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        error "端口无效：$PORT"
    fi
else
    PORT="443"
    info "共存模式固定使用 443，将自动处理 nginx 冲突"
fi
ok "节点端口：$PORT"

# ── SNI 选择 ────────────────────────────────────────────────────
echo ""
echo "  请选择伪装目标站点（SNI）："
echo "  1) addons.mozilla.org  — 推荐，Mozilla CDN，TLS 1.3，延迟低"
echo "  2) www.microsoft.com   — 备选，稳定"
echo "  3) 自定义"
echo ""
while true; do
    read -rp "  输入选项 [1/2/3，默认 1]：" SNI_CHOICE
    SNI_CHOICE="${SNI_CHOICE:-1}"
    case "$SNI_CHOICE" in
        1) SNI="addons.mozilla.org"; break ;;
        2) SNI="www.microsoft.com";  break ;;
        3)
            read -rp "  输入自定义 SNI（需支持 TLS 1.3 和 H2）：" SNI
            [[ -z "$SNI" ]] && warn "SNI 不能为空" || break
            ;;
        *) warn "请输入 1、2 或 3" ;;
    esac
done
ok "SNI：$SNI"

# ================================================================
# 4. 生成密钥
# ================================================================
section "4/6  生成密钥材料"

UUID=$($XRAY_BIN uuid)

# 兼容 xray x25519 全部历史输出格式：
#   旧版 (<v25.3.6):  "Private key: X"   / "Public key: X"
#   新版 (>=v25.3.6): "PrivateKey: X"    / "Password: X"
#   更新版:           "PrivateKey: X"    / "Password (PublicKey): X"
X25519=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$X25519" | grep -i "private"             | awk '{print $NF}')
PUBLIC_KEY=$( echo "$X25519" | grep -i "public\|password" | grep -iv "hash" | awk '{print $NF}')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "x25519 密钥解析失败，原始输出：\n$X25519"
fi

SHORT_ID_1=$(openssl rand -hex 4)   # 8位
SHORT_ID_2=$(openssl rand -hex 8)   # 16位

ok "UUID        : $UUID"
ok "Private Key : $PRIVATE_KEY"
ok "Public Key  : $PUBLIC_KEY"
ok "Short ID 1  : $SHORT_ID_1"
ok "Short ID 2  : $SHORT_ID_2"

# ================================================================
# 5a. 处理端口冲突（共存模式）
# ================================================================
if [[ "$MODE" == "coexist" ]]; then
    section "5a/6  检测并处理 nginx 443 冲突"

    NGINX_ON_443=$(ss -tlnp | grep ":443" | grep nginx || true)

    if [[ -z "$NGINX_ON_443" ]]; then
        info "443 未被 nginx 占用，无需处理"
    else
        info "检测到 nginx 占用 443，开始自动迁移..."

        # 找到所有实际含 listen 443 的配置文件（排除注释行和备份）
        NGINX_CONF_FILES=$(grep -rl "^\s*listen 443" /etc/nginx/ 2>/dev/null | grep -v "\.bak" || true)

        if [[ -z "$NGINX_CONF_FILES" ]]; then
            warn "未能自动定位 nginx 配置文件"
            warn "请手动将 nginx 的 listen 443 改为 listen 80 并删除 SSL 相关配置"
        else
            for CONF_FILE in $NGINX_CONF_FILES; do
                info "处理配置文件：$CONF_FILE"
                cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
                ok "已备份至 ${CONF_FILE}.bak.*"

                # 修改监听端口，删除 SSL 相关配置行
                sed -i \
                    -e 's|^\(\s*\)listen 443 ssl;.*|\1listen 80;|' \
                    -e 's|^\(\s*\)listen \[::\]:443 ssl;.*|\1listen [::]:80;|' \
                    -e '/^\s*ssl_certificate\b/d' \
                    -e '/^\s*ssl_certificate_key\b/d' \
                    -e '/^\s*ssl_dhparam\b/d' \
                    -e '/^\s*include.*options-ssl-nginx/d' \
                    -e '/# managed by Certbot/d' \
                    "$CONF_FILE"

                # 删除 Certbot 自动生成的 301 redirect server block
                python3 - "$CONF_FILE" << 'PYEOF'
import re, sys
with open(sys.argv[1], 'r') as f:
    content = f.read()
content = re.sub(
    r'server\s*\{[^{}]*return 301 https[^{}]*\}',
    '',
    content,
    flags=re.DOTALL
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF
                ok "已修改：$CONF_FILE"
            done

            if nginx -t 2>/dev/null; then
                systemctl reload nginx
                ok "nginx 重载成功，现在监听 80"
            else
                error "nginx 配置校验失败，请检查配置文件，原始备份在 *.bak.*"
            fi
        fi
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  【需手动操作】Cloudflare DNS 设置：${NC}"
    echo -e "${YELLOW}  1. 域名 A 记录指向本机 IP，开启橙色云朵（代理模式）${NC}"
    echo -e "${YELLOW}  2. SSL/TLS 模式设为「灵活（Flexible）」${NC}"
    echo -e "${YELLOW}  完成后 Cloudflare 负责 HTTPS，nginx 只处理 HTTP:80${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -rp "  已了解，继续 [回车]：" _
fi

# ================================================================
# 5b. 写入 Xray 配置
# ================================================================
section "5b/6  写入 Xray 配置"
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID_1", "$SHORT_ID_2"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

if ! $XRAY_BIN -test -config "$CONFIG_FILE"; then
    error "Xray 配置语法校验失败"
fi
ok "配置写入并校验通过：$CONFIG_FILE"

# ================================================================
# 6. 防火墙
# ================================================================
section "6/6  配置防火墙"

ufw allow 22/tcp          comment 'SSH'
ufw allow "${PORT}/tcp"   comment 'Xray-Reality'

if ufw status | grep -q "active"; then
    ufw reload && ok "ufw 已重载"
else
    ufw --force enable && ok "ufw 已启用"
fi

# ================================================================
# 7. 启动 Xray
# ================================================================
section "启动 Xray 服务"

# 纯节点模式：检查端口冲突
if [[ "$MODE" == "standalone" ]]; then
    CONFLICT=$(ss -tlnp | grep ":${PORT}" | grep -v xray || true)
    if [[ -n "$CONFLICT" ]]; then
        warn "端口 $PORT 被以下进程占用："
        echo "$CONFLICT"
        read -rp "  是否强制停止占用进程？[y/N]：" KILL_CHOICE
        if [[ "$KILL_CHOICE" =~ ^[Yy]$ ]]; then
            PID=$(echo "$CONFLICT" | grep -oP 'pid=\K[0-9]+' | head -1)
            [[ -n "$PID" ]] && kill "$PID" && sleep 1 && ok "已停止 PID $PID"
        else
            error "端口冲突未解决，退出"
        fi
    fi
fi

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    ok "Xray 服务运行正常"
else
    echo ""
    journalctl -u xray -n 20 --no-pager
    error "Xray 启动失败，查看以上日志"
fi

# ================================================================
# 输出节点信息
# ================================================================
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s  --max-time 5 https://api.ipify.org 2>/dev/null || \
            echo "YOUR_SERVER_IP")

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID_1}&type=tcp&headerType=none#$(hostname)-Reality"

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  ✅ 节点搭建完成！${NC}"
echo ""
echo "  模式     : $([ "$MODE" == "standalone" ] && echo "纯节点" || echo "与 nginx 共存")"
echo "  地址     : $SERVER_IP"
echo "  端口     : $PORT"
echo "  UUID     : $UUID"
echo "  公钥     : $PUBLIC_KEY"
echo "  Short ID : $SHORT_ID_1"
echo "  SNI      : $SNI"
echo "  指纹     : chrome"
echo "  流控     : xtls-rprx-vision"
echo ""
echo "  VLESS 链接："
echo ""
echo "  $VLESS_LINK"
echo ""
echo -e "${GREEN}================================================================${NC}"

# 保存节点信息
cat > "$SAVE_FILE" << SAVEEOF
# Xray Reality 节点信息
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S %Z')
# 部署模式：$([ "$MODE" == "standalone" ] && echo "纯节点" || echo "与 nginx 共存")

地址        : $SERVER_IP
端口        : $PORT
UUID        : $UUID
私钥        : $PRIVATE_KEY
公钥        : $PUBLIC_KEY
Short ID 1  : $SHORT_ID_1
Short ID 2  : $SHORT_ID_2
SNI         : $SNI
指纹        : chrome
流控        : xtls-rprx-vision

VLESS 链接：
$VLESS_LINK

配置文件    : $CONFIG_FILE
日志目录    : /var/log/xray/

常用命令：
  systemctl status xray            # 查看状态
  systemctl restart xray           # 重启
  journalctl -u xray -f            # 实时日志
  xray -test -config $CONFIG_FILE  # 校验配置
SAVEEOF

chmod 600 "$SAVE_FILE"
echo ""
echo "  📄 节点信息已保存至 $SAVE_FILE（权限 600）"
echo ""
