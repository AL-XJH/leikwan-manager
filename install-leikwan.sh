#!/bin/bash
# ==============================================================================
# 利群管家 | LeiKwan Manager 一键安装脚本
# ------------------------------------------------------------------------------
# 用法: curl -fsSL <安装脚本URL> | bash
# 该脚本会把主脚本和 WG 脚本下载到磁盘后安装，避免 curl|bash 管道 stdin 问题。
# ==============================================================================

set -e

# --- 基础信息（仓库地址）---
INSTALL_VERSION="1.3"
MAIN_URL="https://raw.githubusercontent.com/AL-XJH/leikwan-manager/main/LeiKwanManager.sh"
WG_URL="https://raw.githubusercontent.com/AL-XJH/leikwan-manager/main/wg-liqun.sh"

MAIN_INSTALL_PATH="/usr/local/bin/LeiKwanManager.sh"
WG_INSTALL_PATH="/usr/local/bin/wg-liqun"
ALIAS_PATH="/usr/bin/d"

# --- 简易颜色 ---
C_GREEN='\033[0;32m'; C_CYAN='\033[0;36m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_NC='\033[0m'
ok()   { echo -e "${C_GREEN}[OK]${C_NC} $1"; }
info() { echo -e "${C_CYAN}[..]${C_NC} $1"; }
warn() { echo -e "${C_YELLOW}[!]${C_NC} $1"; }
err()  { echo -e "${C_RED}[X]${C_NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    err "此安装脚本需要 root 权限：sudo bash <(curl -fsSL URL) 或先 sudo su"
    exit 1
fi

# 注意：这里【不要】执行 exec 0< /dev/tty。
# 当本安装器被 `curl URL | bash` 管道执行时，bash 正从管道读脚本，
# 若此刻把 stdin 切到 /dev/tty，bash 就读不到剩余脚本内容而卡死。
# 安装器本身无键盘输入；需要终端的是主脚本，在最后的 exec 里显式 < /dev/tty 即可。

echo
info "利群管家一键安装脚本 v${INSTALL_VERSION}"
echo

# ---------- 下载并安装主脚本 ----------
info "下载主脚本 LeiKwanManager.sh ..."
if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$MAIN_INSTALL_PATH" "$MAIN_URL"; then
    err "主脚本下载失败。请检查网络，或确认仓库地址配置是否正确。"
    exit 1
fi

# 校验下载内容
if ! head -n 1 "$MAIN_INSTALL_PATH" 2>/dev/null | grep -q "^#!/bin/bash"; then
    err "下载的文件不是有效的脚本（首行非 #!/bin/bash），可能是仓库地址错误或返回了错误页。"
    exit 1
fi

chmod +x "$MAIN_INSTALL_PATH"
ok "主脚本已安装到 ${MAIN_INSTALL_PATH}"

# ---------- 创建 d 快捷键 ----------
ln -sf "$MAIN_INSTALL_PATH" "$ALIAS_PATH" 2>/dev/null || cp -f "$MAIN_INSTALL_PATH" "$ALIAS_PATH"
chmod +x "$ALIAS_PATH" 2>/dev/null || true
ok "已创建快捷键 d -> ${MAIN_INSTALL_PATH}"

# ---------- 尝试下载 WG 脚本（可选，失败不影响主脚本） ----------
if curl -fsSL --connect-timeout 10 --max-time 120 -o "$WG_INSTALL_PATH" "$WG_URL" 2>/dev/null && \
   head -n 1 "$WG_INSTALL_PATH" | grep -q "^#!/bin/bash"; then
    chmod +x "$WG_INSTALL_PATH"
    ok "WG 专用脚本已安装到 ${WG_INSTALL_PATH}"
else
    warn "WG 脚本未安装（仓库中可能没有该文件，可忽略）"
fi

echo
info "安装完成！正在启动利群管家菜单..."

# 以磁盘文件方式 exec 主脚本，并显式把 stdin 指向终端，
# 这样即使安装器是被 `curl | bash` 管道执行的，主脚本菜单 read 也能从键盘读到输入。
# 注意：启动时【不能】对 stderr 做 2>/dev/null —— 菜单的 `read -p` 提示符是输出到
# stderr 的，一旦被重定向就会导致“看不见 请输入选项:”。这里用 /dev/tty 是否存在来判断，
# 而不是用错误抑制。
if [[ -r /dev/tty ]]; then
    exec bash "$MAIN_INSTALL_PATH" < /dev/tty
else
    exec bash "$MAIN_INSTALL_PATH"
fi
