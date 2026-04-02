#!/bin/bash
# ================================================================
# Oracle 1c1g  VLESS + Reality + xtls-rprx-vision  一键脚本
# 适用：Debian / Ubuntu，纯手工维护，无面板依赖
# ================================================================
set -e

# ── 0. 权限检查 ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] 请用 root 身份运行此脚本（sudo -i 后再执行）"
  exit 1
fi

# ── 1. 系统更新 & 依赖 ──────────────────────────────────────────
echo ""
echo "=== [1/6] 更新系统 & 安装依赖 ==="
apt update -y && apt upgrade -y
apt install -y curl unzip openssl ufw

# ── 2. 安装 Xray（官方脚本，最新正式版）────────────────────────
echo ""
echo "=== [2/6] 安装 Xray ==="
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 确认 xray 可执行
XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
if [[ ! -x "$XRAY_BIN" ]]; then
  echo "[ERROR] Xray 安装失败，请检查网络后重试"
  exit 1
fi
echo "[OK] Xray 版本：$($XRAY_BIN version | head -1)"

# ── 3. 生成密钥材料 ─────────────────────────────────────────────
echo ""
echo "=== [3/6] 生成配置密钥 ==="

UUID=$($XRAY_BIN uuid)

# x25519 输出格式：
#   Private key: <key>
#   Public key:  <key>
X25519=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$X25519" | awk '/Private key:/{print $NF}')
PUBLIC_KEY=$(echo  "$X25519" | awk '/Public key:/{print $NF}')

SHORT_ID_1=$(openssl rand -hex 4)          # 8 位
SHORT_ID_2=$(openssl rand -hex 8)          # 16 位

echo "  UUID        : $UUID"
echo "  Private Key : $PRIVATE_KEY"
echo "  Public Key  : $PUBLIC_KEY"
echo "  Short ID 1  : $SHORT_ID_1"
echo "  Short ID 2  : $SHORT_ID_2"
echo "  SNI / dest  : addons.mozilla.org"

# ── 4. 写入 Xray 配置 ───────────────────────────────────────────
echo ""
echo "=== [4/6] 写入 Xray 配置 ==="
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
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
          "dest": "addons.mozilla.org:443",
          "xver": 0,
          "serverNames": [
            "addons.mozilla.org"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID_1",
            "$SHORT_ID_2"
          ]
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
echo "[OK] 配置已写入 /usr/local/etc/xray/config.json"

# 语法校验
if ! $XRAY_BIN -test -config /usr/local/etc/xray/config.json; then
  echo "[ERROR] 配置语法校验失败，请检查上方错误信息"
  exit 1
fi
echo "[OK] 配置语法校验通过"

# ── 5. 防火墙 ───────────────────────────────────────────────────
echo ""
echo "=== [5/6] 配置防火墙 ==="

# 保证 SSH 不被锁死再操作 ufw
ufw allow 22/tcp   comment 'SSH'
ufw allow 443/tcp  comment 'Xray-Reality'

# 检查 ufw 当前状态：若已启用则 reload，否则初次 enable
UFW_STATUS=$(ufw status | head -1)
if echo "$UFW_STATUS" | grep -q "active"; then
  ufw reload
  echo "[OK] ufw 已重载规则"
else
  ufw --force enable
  echo "[OK] ufw 已启用"
fi

# ── 6. 启动 Xray ────────────────────────────────────────────────
echo ""
echo "=== [6/6] 启动 Xray 服务 ==="
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
  echo "[OK] Xray 服务运行正常"
else
  echo "[ERROR] Xray 启动失败，查看日志："
  journalctl -u xray -n 30 --no-pager
  exit 1
fi

# ── 输出节点信息 ────────────────────────────────────────────────
echo ""
echo "================================================================"

# 自动获取公网 IP（优先 IPv4）
SERVER_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || \
            curl -s  https://api.ipify.org 2>/dev/null || \
            echo "YOUR_SERVER_IP")

VLESS_LINK="vless://${UUID}@${SERVER_IP}:443\
?encryption=none\
&flow=xtls-rprx-vision\
&security=reality\
&sni=addons.mozilla.org\
&fp=chrome\
&pbk=${PUBLIC_KEY}\
&sid=${SHORT_ID_1}\
&type=tcp\
&headerType=none\
#Oracle-Reality"

echo ""
echo "  ✅ 节点搭建完成！以下信息请立即复制保存"
echo ""
echo "  协议     : VLESS + Reality + xtls-rprx-vision"
echo "  地址     : $SERVER_IP"
echo "  端口     : 443"
echo "  UUID     : $UUID"
echo "  公钥     : $PUBLIC_KEY"
echo "  Short ID : $SHORT_ID_1  （客户端填这个）"
echo "  SNI      : addons.mozilla.org"
echo "  指纹     : chrome"
echo ""
echo "  VLESS 链接（可直接导入客户端）："
echo ""
echo "  $VLESS_LINK"
echo ""
echo "================================================================"

# 保存到文件
SAVE_FILE="/root/xray-config.txt"
cat > "$SAVE_FILE" << SAVEEOF
# Xray Reality 节点信息
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S %Z')

地址        : $SERVER_IP
端口        : 443
UUID        : $UUID
私钥        : $PRIVATE_KEY
公钥        : $PUBLIC_KEY
Short ID 1  : $SHORT_ID_1
Short ID 2  : $SHORT_ID_2
SNI         : addons.mozilla.org
指纹        : chrome
流控        : xtls-rprx-vision

VLESS 链接：
$VLESS_LINK

配置文件路径 : /usr/local/etc/xray/config.json
日志路径     : /var/log/xray/
常用命令：
  systemctl status xray
  systemctl restart xray
  journalctl -u xray -f
SAVEEOF

chmod 600 "$SAVE_FILE"
echo "  📄 以上信息已保存至 $SAVE_FILE（权限 600）"
echo ""
