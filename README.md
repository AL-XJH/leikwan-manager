# 利群管家 · LeiKwan Manager

Debian 服务器一体化网络管理脚本。整合 IPv6 双线智能选路、IPv4 多出口策略路由与 WireGuard 组网，一套菜单管理全部。

**版本** `v1.3` · **环境** Debian 10+（root）

---

## 功能

| 模块 | 能力 |
|---|---|
| IPv6 智能管家 | 电信/联通双线选路、防跳动、DDNS 推送（Cloudflare / DNSPod / AliDNS / Webhook）、策略路由 |
| IPv4 策略路由 | SDWAN 多线路分流、IP/端口精准分流、NAT 伪装、域名 DDNS 分流 |
| WireGuard | A（内网发起）/ B（云端部署）/ C（最终握手）三模式，多接口管理 |
| 守护服务 | systemd 定时任务 + 开机自启 + 全局快捷键 `d` |
| APT 优化 | 一键替换内网源，解决 CN2/9929/浦电机型拉取卡顿 |

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/AL-XJH/leikwan-manager/main/install-leikwan.sh | bash
```

安装完成后输入 `d` 即可打开菜单。

> 需 root 权限。安装器自动安装主脚本、创建 `d` 快捷键及 WG 专用脚本。

## 命令

```bash
d                  # 打开主菜单
d v6_auto          # 执行 IPv6 自动任务
d v4_apply         # 应用 IPv4 分流规则
d v4_ddns          # 刷新 IPv4 域名规则
d wg               # WireGuard 菜单
```

## 配置文件

```
/etc/ipv6_manager.conf          # IPv6 配置
/etc/custom_policy_routes.conf  # IPv4 静态规则
/etc/custom_policy_ddns.conf    # IPv4 域名规则
/var/log/ipv6_manager.log       # IPv6 日志
```

## 项目文件

| 文件 | 说明 |
|---|---|
| `LeiKwanManager.sh` | 主脚本 |
| `wg-liqun.sh` | WireGuard 专用脚本（B 服务器） |
| `install-leikwan.sh` | 一键安装脚本 |
| `README.md` | 本文件 |

## 许可

仅供内部使用，使用后果自负。
