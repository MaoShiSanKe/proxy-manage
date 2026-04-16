# proxy-manage

> 个人自用的轻量代理节点管理脚本，无面板依赖，完全可控。  
> 支持 **VLESS + Reality + Vision** 和 **Hysteria2**，两者可同时运行互不干扰。

---

## 特性

- **双协议支持**：VLESS+Reality（TCP，无需域名/证书）+ Hysteria2（UDP，速度极快）
- **443 端口共存**：Reality 占用 TCP:443，Hysteria2 占用 UDP:443，协议层不冲突
- **多用户管理**：随时添加/删除用户，自动重载配置
- **证书灵活**：Hysteria2 支持自签证书（无域名）/ ACME 自动申请 / 自定义证书
- **防火墙自适应**：自动检测并配置 ufw / firewalld / iptables
- **BBR 加速**：一键检测并启用 BBR + fq，对 Hysteria2 效果显著
- **网络诊断**：端口监听检查、服务状态、外网连通性
- **全局命令**：安装后 `proxy-manage` 随时调出菜单
- **节点信息保存**：自动生成 `/root/proxy-nodes.txt`，含完整分享链接
- **内核更新**：Xray / Hysteria2 一键升级到最新版
- 适用：**Debian / Ubuntu**（推荐 Debian 11/12/13，Ubuntu 20.04+）

---

## 快速开始

```bash
# 下载脚本
wget -O proxy-manage.sh https://raw.githubusercontent.com/MaoShiSanKe/proxy-manage/main/proxy-manage.sh

# 赋予执行权限
chmod +x proxy-manage.sh

# 以 root 运行
sudo bash proxy-manage.sh
```

首次运行会自动：
1. 更新系统包索引，安装基础依赖（curl、openssl、ufw 等）
2. 检测并启用 BBR 加速
3. 注册全局命令 `proxy-manage`

之后直接输入 `proxy-manage` 即可打开菜单。

---

## 菜单结构

```
╔══════════════════════════════════════════════════════════╗
║        proxy-manage v1.0.0  —  代理节点管理脚本          ║
╠══════════════════════════════════════════════════════════╣
║  Reality  : ✓ 运行中        Hysteria2 : ✓ 运行中         ║
╠══════════════════════════════════════════════════════════╣
║  安装                                                    ║
║   1) 安装 VLESS + Reality + Vision                       ║
║   2) 安装 Hysteria2                                      ║
║   3) 同时安装两者（推荐）                                ║
╠══════════════════════════════════════════════════════════╣
║  管理                                                    ║
║   4) 查看节点信息 & 分享链接                             ║
║   5) 用户管理（添加/删除用户）                           ║
║   6) 修改配置（端口/SNI/证书/带宽等）                    ║
║   7) 服务管理（启停/重启/日志）                          ║
╠══════════════════════════════════════════════════════════╣
║  系统                                                    ║
║   8) 网络诊断（端口/防火墙/连通性检查）                  ║
║   9) 防火墙管理                                          ║
║  10) BBR 加速管理                                        ║
║  11) 更新内核 / 脚本                                     ║
║  12) 卸载                                               ║
╚══════════════════════════════════════════════════════════╝
```

---

## 协议说明

### VLESS + Reality + Vision

| 参数 | 说明 |
|------|------|
| 协议 | VLESS over TCP |
| 安全 | Reality（借用大网站 TLS 指纹） |
| 流控 | xtls-rprx-vision |
| 端口 | 默认 443/TCP |
| 是否需要域名 | **不需要** |
| 是否需要证书 | **不需要** |

Reality 的原理是伪装成访问真实大网站（如 `addons.mozilla.org`、`www.microsoft.com`）的 TLS 流量，通过自己的 `x25519` 密钥对加密，GFW 探测时看到的是正常的 TLS 握手。这与"偷取域名"无关，服务器不需要拥有那个域名，也不影响目标网站任何资源。

**SNI 目标选择建议**：

- `addons.mozilla.org` — Mozilla CDN，TLS 1.3，全球可达，推荐
- `www.microsoft.com` — 微软主域，稳定
- `www.apple.com` — 苹果，适合伪装 iOS 客户端流量
- `dl.google.com` — 谷歌下载，H2 支持好

选择原则：目标网站需支持 TLS 1.3 + HTTP/2，且在服务器所在地可正常访问。

---

### Hysteria2

| 参数 | 说明 |
|------|------|
| 协议 | Hysteria2 over QUIC/UDP |
| 端口 | 默认 443/UDP |
| 是否需要域名 | 不需要（自签证书模式） |
| 证书类型 | 自签 / ACME（Let's Encrypt）/ 自定义 |

**证书选择建议**：

- 有域名：选 ACME，客户端无需开启「允许不安全连接」，更稳定
- 无域名：选自签证书，客户端需开启 `insecure=1`，近期有小概率被随机阻断
- 自签伪装域名建议填一个真实存在的域名（如 `bing.com`），不填实际也可用

**注意事项**：

- Hysteria2 基于 UDP，Oracle Cloud、某些国内云服务商的**安全组**默认不放行 UDP，需要在控制台手动添加入站规则
- 如果遇到连接不上但服务正常运行，优先检查云厂商安全组

---

## Reality + Hysteria2 同时运行

两者可以同时监听 **同一端口（如 443）** 而不冲突：

```
客户端 ──TCP:443──→ Xray (Reality)     ← 处理 VLESS 流量
客户端 ──UDP:443──→ Hysteria2          ← 处理 Hy2 流量
```

TCP 和 UDP 是完全独立的协议栈，443/TCP 和 443/UDP 互不影响。

---

## 客户端推荐

| 平台 | 客户端 | 备注 |
|------|--------|------|
| Windows | [v2rayN](https://github.com/2dust/v2rayN) | 支持 Reality + Hy2 |
| Android | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) | 推荐，支持端口跳跃 |
| iOS | [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) | 付费，支持 Reality |
| iOS | [Stash](https://apps.apple.com/app/stash/id1596063349) | 支持 Hy2 |
| macOS | [Clash Verge](https://github.com/clash-verge-rev/clash-verge-rev) | sing-box 内核 |
| 全平台 | [sing-box](https://github.com/SagerNet/sing-box) | 原生支持两种协议 |

---

## 配置文件位置

| 文件 | 说明 |
|------|------|
| `/usr/local/etc/xray/config.json` | Xray Reality 配置 |
| `/etc/hysteria/config.yaml` | Hysteria2 配置 |
| `/etc/proxy-manage/state.conf` | 脚本状态持久化（UUID/密码/端口等） |
| `/root/proxy-nodes.txt` | 节点信息和分享链接（权限 600） |
| `/var/log/xray/` | Xray 日志目录 |

---

## 常用命令速查

```bash
# 打开管理菜单
proxy-manage

# 查看服务状态
systemctl status xray
systemctl status hysteria-server

# 重启服务
systemctl restart xray
systemctl restart hysteria-server

# 查看实时日志
journalctl -u xray -f
journalctl -u hysteria-server -f

# 手动校验 Xray 配置
xray -test -config /usr/local/etc/xray/config.json

# 查看节点信息
cat /root/proxy-nodes.txt
```

---

## 防火墙注意事项

脚本会自动检测并配置本机防火墙（ufw / firewalld / iptables），但以下情况需要**手动操作**：

1. **Oracle Cloud**：需在「VCN → 安全列表 → 入站规则」添加 TCP:443 和 UDP:443
2. **AWS / 腾讯云 / 阿里云**：需在「安全组 → 入方向」添加对应规则
3. **Hysteria2 特别注意**：UDP 端口在很多云服务商默认关闭，Reality 不成功但 Hy2 不通时先检查这里

脚本菜单 **9) 防火墙管理** 可查看当前防火墙规则，并手动开放额外端口。

---

## 故障排查

**Reality 连不上**
```bash
# 检查 Xray 是否正常运行
systemctl status xray

# 检查端口是否监听
ss -tlnp | grep :443

# 查看错误日志
journalctl -u xray -n 50 --no-pager

# 验证配置文件语法
xray -test -config /usr/local/etc/xray/config.json
```

**Hysteria2 连不上**
```bash
# 检查服务状态
systemctl status hysteria-server

# 检查 UDP 端口（注意是 -u）
ss -ulnp | grep :443

# 查看日志
journalctl -u hysteria-server -n 50 --no-pager

# 最常见原因：云服务商安全组未放行 UDP:443
```

**自签证书 Hy2 客户端报错**  
客户端配置中需设置：
- v2rayN：节点设置 → 跳过证书验证 ✓
- NekoBox：allow insecure ✓  
- 链接参数：`hy2://pass@ip:port?insecure=1&sni=bing.com#name`

---

## 目录结构

```
proxy-manage.sh          # 主脚本（单文件，所有功能）
README.md                # 本文档
```

---

## 技术细节

- **状态持久化**：所有配置（UUID、密码、端口、密钥）存储在 `/etc/proxy-manage/state.conf`，格式为 `KEY='VALUE'`，重装系统后手动恢复此文件即可还原节点。
- **多用户存储格式**：`uuid1|name1;uuid2|name2;...`，每次修改用户后自动重新生成配置文件并重载服务。
- **x25519 兼容性**：兼容 Xray v25.3.6 前后不同的 `xray x25519` 输出格式（`Private key:` / `PrivateKey:` / `Password:`）。
- **BBR**：写入 `/etc/sysctl.d/99-bbr.conf`，持久化跨重启生效。需内核 >= 4.9。

---

## License

MIT — 随便用，别删注释就行。
