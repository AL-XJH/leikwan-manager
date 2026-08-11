[README.md](https://github.com/user-attachments/files/30939196/README.md)
# 利群管家 | LeiKwan Manager

一款面向 Debian 服务器的**一体化网络管理脚本**，把 IPv6 智能选路 / IPv4 多出口策略路由 / WireGuard 组网整合到一个菜单里，开箱即用。

> 由「利群主機」自用脚本迭代而来，当前版本 **v1.3**（`lk-manager-v1.3`）。

---

## ✨ 功能总览

| 模块 | 能力 |
|------|------|
| **IPv6 智能管家** | 电信/联通双线自动选路、防跳动、多平台 DDNS 推送、指定目标策略路由 |
| **IPv4 多出口策略路由** | SDWAN 线路分流、IP/端口精准分流、NAT 源地址伪装、域名 DDNS 分流 |
| **WireGuard 组网** | A（内网发起）/ B（云端部署）/ C（最终握手）三模式，多接口管理 |
| **守护服务** | 一键安装 systemd 定时任务 + 开机自启 + 全局快捷键 `d` |
| **APT 源优化** | 一键替换为内网源，解决 CN2/9929/浦东电信机型拉取 Debian 包卡顿 |

---

## 🚀 快速安装

### 一键安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/AL-XJH/leikwan-manager/main/install-leikwan.sh | bash
```

安装器会自动：
- 下载主脚本到 `/usr/local/bin/LeiKwanManager.sh`
- 创建全局快捷键 `d` → 主脚本
- 安装 WG 专用脚本 `/usr/local/bin/wg-liqun`
- 启动菜单

### 手动安装

```bash
# 下载主脚本
curl -fsSL -o /usr/local/bin/LeiKwanManager.sh \
  https://raw.githubusercontent.com/AL-XJH/leikwan-manager/main/LeiKwanManager.sh
chmod +x /usr/local/bin/LeiKwanManager.sh

# 下载 WG 脚本（可选，B 服务器用）
curl -fsSL -o /usr/local/bin/wg-liqun \
  https://raw.githubusercontent.com/AL-XJH/leikwan-manager/main/wg-liqun.sh
chmod +x /usr/local/bin/wg-liqun

# 创建快捷键
ln -sf /usr/local/bin/LeiKwanManager.sh /usr/bin/d

# 运行
/usr/local/bin/LeiKwanManager.sh
```

> ⚠️ 需要 **root** 权限运行。不支持直接 `curl | bash` 运行主脚本（会导致菜单无法读取键盘），请走一键安装或手动安装。

---

## 🎮 使用说明

### 主菜单

```
利群管家 | LeiKwan Manager
  1. IPv6 智能管家        双线选路 / DDNS 推送 / 防跳动
  2. IPv4 多出口策略路由   SDWAN / 端口分流 / NAT / PBR
  3. WireGuard 利群主机端  A内网 / B云端 / C握手
  4. 一键安装守护服务      systemd 定时器 / 开机自启 / 快捷键 d
  5. 替换 APT 源为内网源   CN2/9929/浦东电信 拉取卡顿
  0. 退出脚本
```

### 子命令（供 systemd / cron 调用）

```bash
d v6_auto     # 执行一次 IPv6 自动任务（清理+选路+DDNS+策略路由）
d v4_apply    # 应用全部 IPv4 分流规则
d v4_ddns     # 刷新 IPv4 域名 DDNS 规则
d wg          # 直接进入 WireGuard 菜单
```

### 守护服务

主菜单选 **4** 后安装：
- `ipv6_manager.timer` —— 默认每 2 分钟跑一次 IPv6 自动任务（频率可自定义）
- `ipv4_custom_routing.service` —— 开机自动应用 IPv4 分流规则
- 快捷键 `d`

---

## 🌐 IPv6 智能管家

适合服务器同时有**电信(240e) + 联通(2408)** 双线 IPv6 的环境。

### 能力
- **深度地址清理**：自动清理 deprecated / temporary / tentative / dadfailed / preferred_lft=0 的 IPv6 地址
- **智能选源**：延迟最佳（ping 优先）或最新下发（preferred_lft 最大）两种策略
- **防跳动**：可把电信/联通各自锁定到指定网卡
- **出口切换**：以 metric 受管路由压过 RA 自动路由，写入后自动验证实际出口
- **DDNS 推送**：电信/联通线路独立配置，支持
  - Cloudflare（自动补全 FQDN、自动清理重复 AAAA 记录）
  - DNSPod（腾讯云）
  - Aliyun（阿里云）
  - Webhook
  - 本地 IP 未变时跳过 API 调用省配额，每 10 分钟强制校验一次远端一致性
- **策略路由**：指定某个 IPv6 目标走指定线路

### 配置文件
`/etc/ipv6_manager.conf` —— 各项配置（含密钥），脚本自动读写。
日志：`/var/log/ipv6_manager.log`

---

## 🗺️ IPv4 多出口策略路由

适合通过 **SDWAN / 多运营商线路** 出口的服务器。内置线路定义：

```
9929 10.7.0.1          CN2 10.8.0.1
JPSDWAN 10.3.0.1       DESDWAN 10.3.10.1
KRSDWAN 10.4.0.1       HKSDWAN 10.3.50.1
TWSDWAN 10.3.100.1     USSDWAN-SEATTLE 10.3.160.1
MOSCOW 10.3.170.1      SINGAPORE 10.3.180.1
USSDWAN-LAX 10.3.150.1
```

### 能力
- **静态分流**：目标 IP/CIDR（支持批量、逗号分隔）走指定线路
- **端口精准分流**：tcp/udp + 端口 → fwmark → 独立路由表，mangle 打标 + NAT MASQUERADE
- **域名分流**：域名 DDNS 规则，自动解析 A 记录生成 ip rule，cron 每 5 分钟刷新
- **多网关冲突修复**：自动剔除冲突的默认路由
- **批量管理**：增删改查，批量删除

### 配置文件
- `/etc/custom_policy_routes.conf` —— 静态规则
- `/etc/custom_policy_ddns.conf` —— 域名规则

---

## 🔐 WireGuard 组网

用于**利群主机（内网）↔ 云端服务器**建立隧道，默认网段 `10.198.1.0/24`、MTU `1280`。

### 三种模式
| 模式 | 在哪运行 | 作用 |
|------|---------|------|
| A 内网发起 | 利群主机 | 生成本机配置与 PublicKey |
| B 云端部署 | 云端/公网服务器 | 自动部署服务端，返回 公网IP:端口 + PublicKey |
| C 最终握手 | 利群主机 | 填入 B 的信息，启动隧道并 ping 验证 |

### 多接口管理
菜单内支持 **多接口总览**（wg0/wg1… 状态、端口、地址、最新握手）、**切换操作接口**、**启动/停止指定接口**，A/B/C 模式默认作用于当前操作接口。

### 独立 WG 脚本
B 服务器可单独使用 `wg-liqun.sh`（与主脚本同源）：

```bash
bash /usr/local/bin/wg-liqun        # 进入菜单，选 2 B 模式
# 或直接: bash /usr/local/bin/wg-liqun b
```

---

## 🔧 常见问题

**Q：菜单里的 read 一直卡住/按不了键？**
主脚本不能用 `curl | bash` 直接管道运行。请用一键安装脚本，或先下载到磁盘再执行。

**Q：DDNS 推送失败，日志里报 `响应不是合法 JSON`？**
日志会显示 curl 退出码 / HTTP 码 / 响应前 120 字符。常见原因：
- HTTP 401 + nginx 页面 → token 为空或格式错误，进 DDNS 配置重新填写
- 响应为空 + curl 退出码 28 → 超时，检查服务器到 DDNS 服务商网络

**Q：切换 DDNS 运营商（如 DNSPod → Cloudflare）时表单是空的？**
这是设计行为：各运营商参数语义不同，为避免残留旧值，切换时清空重填；同一运营商重配则回车保留原值。

**Q：脚本路径包含空格时服务/cron 不生效？**
脚本内 systemd 单元与 cron 已对路径加引号处理，只要用新版脚本重新安装守护服务（主菜单 4）即可。

**Q：如何卸载？**
```bash
systemctl stop ipv6_manager.timer ipv4_custom_routing.service 2>/dev/null
systemctl disable ipv6_manager.timer ipv4_custom_routing.service 2>/dev/null
rm -f /usr/bin/d /usr/local/bin/LeiKwanManager.sh /usr/local/bin/wg-liqun
# 如需清配置：rm -f /etc/ipv6_manager.conf /etc/custom_policy_routes.conf /etc/custom_policy_ddns.conf
```

---

## 📄 文件清单

| 文件 | 说明 |
|------|------|
| `LeiKwanManager.sh` | 利群管家主脚本（三合一） |
| `wg-liqun.sh` | WireGuard 专用脚本（B 服务器用） |
| `install-leikwan.sh` | 一键安装脚本 |
| `README.md` | 本文档 |

---

## 🗓️ 更新日志

### v1.3 (lk-manager-v1.3)
- 整合 IPv6 / IPv4 PBR / WireGuard 三大模块
- IPv6：多平台 DDNS、FQDN 规范化、重复记录清理、定期远端校验、IP 选择策略
- IPv4：端口精准分流、fwmark + NAT、批量规则管理
- WG：三模式、多接口总览与切换、防误覆盖
- 一键安装脚本，兼容 `curl | bash`
- 大量健壮性修复：配置安全解析、DDNS 诊断、systemd 路径引号等

---

## ⚖️ 许可

仅供个人/内部使用。请勿用于非法用途。使用本脚本造成的任何后果由使用者自行承担。
