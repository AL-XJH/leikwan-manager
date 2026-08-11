#!/bin/bash
# ==============================================================================
# 利群管家 | LeiKwan Manager - WireGuard 专用脚本 v2.3
# ------------------------------------------------------------------------------
# 与「利群管家 d-v1.3.sh」的 WireGuard 模块同源，可独立部署在：
#   * B 服务器（云端 / 公网）—— 选「2 B 模式」，与 A 端利群管家搭配组网
#   * A 服务器（利群主机 / 内网）—— 也可用于 A / C 模式
# 三模式: A 内网发起 / B 云端部署 / C 最终握手
# 网段 10.198.1.0/24 | MTU 1280
#
# B 服务器快速使用:
#   bash wg-liqun.sh          → 进入菜单，选 2 (B 模式)
#   bash wg-liqun.sh b        → 直接进入 B 模式
# ==============================================================================

CURRENT_VERSION="lk-wg-v2.3"

export LC_ALL=C
export LANG=C

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================================================
# UI 工具（与三合一脚本保持一致）
# ==============================================================================
UI_WIDTH=64

ui_repeat() {
    local char="${1:-─}"
    local count="${2:-$UI_WIDTH}"
    local i
    for ((i = 0; i < count; i++)); do
        printf "%s" "$char"
    done
}

ui_line() {
    local char="${1:-─}"
    printf "%b" "$CYAN"
    ui_repeat "$char" "$UI_WIDTH"
    printf "%b\n" "$NC"
}

ui_header() {
    local title="$1"
    local tlen pad
    clear
    echo -e "${CYAN}╭$(ui_repeat "─" $((UI_WIDTH - 2)))╮${NC}"
    # 按显示宽度补齐（中文算 2 列），避免 %-*s 按字节补齐导致标题框右边界错位
    tlen=$(v6_text_width "$title")
    pad=$((UI_WIDTH - 4 - tlen))
    (( pad < 1 )) && pad=1
    printf "${CYAN}│${NC} ${BOLD}${WHITE}%s${NC}${CYAN}%*s${NC}${CYAN}│${NC}\n" "$title" "$pad" ""
    echo -e "${CYAN}╰$(ui_repeat "─" $((UI_WIDTH - 2)))╯${NC}"
}

ui_section() {
    echo
    echo -e "${BLUE}${BOLD}▶ $1${NC}"
    ui_line "─"
}

# 计算中英文混排的终端显示宽度（ASCII 1 列，中文 UTF-8 3 字节按 2 列）
v6_text_width() {
    local s="$1"
    local bytes nonascii ascii
    bytes=$(printf "%s" "$s" | LC_ALL=C wc -c | tr -d ' ')
    nonascii=$(printf "%s" "$s" | LC_ALL=C tr -cd '\200-\377' | wc -c | tr -d ' ')
    ascii=$((bytes - nonascii))
    printf "%s" $((ascii + nonascii * 2 / 3))
}

ui_item() {
    local key="$1"
    local title="$2"
    local desc="${3:-}"
    local desc_col="${UI_DESC_COL:-34}"
    local left_plain="  ${key}. ${title}"
    local width pad

    if [[ -z "$desc" ]]; then
        printf "  %b%s%b. %s\n" "${CYAN:-}" "$key" "${NC:-}" "$title"
        return
    fi

    width=$(v6_text_width "$left_plain")
    pad=$((desc_col - width))
    (( pad < 2 )) && pad=2

    printf "  %b%s%b. %s%*s%b%s%b\n" \
        "${CYAN:-}" "$key" "${NC:-}" \
        "$title" \
        "$pad" "" \
        "${GRAY:-}" "$desc" "${NC:-}"
}

ui_kv() {
    local key="$1"
    local value="$2"
    local w pad
    w=$(v6_text_width "$key")
    pad=$((16 - w))
    (( pad < 1 )) && pad=1
    printf " ${GRAY}%s${NC}%*s: %b\n" "$key" "$pad" "" "$value"
}

ui_success() { echo -e "${GREEN}✅ $1${NC}"; }
ui_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
ui_error()   { echo -e "${RED}❌ $1${NC}"; }
ui_info()    { echo -e "${CYAN}ℹ️  $1${NC}"; }

ui_pause() {
    echo
    read -n 1 -s -r -p "按任意键继续..."
}

if [[ $EUID -ne 0 ]]; then
    ui_error "此脚本必须以 root 权限运行。"
    exit 1
fi

# --- 管道运行兼容 (curl | bash) ---
# 一键安装场景：脚本由安装器下载到磁盘后 exec 执行，但继承的 stdin 可能是已关闭的管道，
# 恢复为 /dev/tty 才能让菜单 read 读取键盘。
if [[ -z "${1:-}" && ! -t 0 ]]; then
    if [[ "$(basename "$0" 2>/dev/null)" == "bash" || "$(basename "$0" 2>/dev/null)" == "sh" ]]; then
        echo -e "${YELLOW}检测到直接管道运行本脚本。为避免菜单无法读取键盘，请先下载到本地再执行：${NC}"
        echo "  curl -fsSL -o /usr/local/bin/wg-liqun.sh https://raw.githubusercontent.com/AL-XJH/leikwan-manager/main/wg-liqun.sh && bash /usr/local/bin/wg-liqun.sh"
        exit 1
    else
        exec 0< /dev/tty 2>/dev/null || true
    fi
fi

# ==============================================================================
# WireGuard 模块（与 d-v1.3.sh 同源）
# ==============================================================================
WG_IFACE="wg0"
WG_CONF=""
WG_PRIVATE_KEY_FILE=""
WG_PUBLIC_KEY_FILE=""
WG_SERVICE_NAME=""
WG_PRIV_KEY=""
WG_PUB_KEY=""

wg_update_vars() {
    WG_CONF="/etc/wireguard/${WG_IFACE}.conf"
    WG_PRIVATE_KEY_FILE="/etc/wireguard/${WG_IFACE}_privatekey"
    WG_PUBLIC_KEY_FILE="/etc/wireguard/${WG_IFACE}_publickey"
    WG_SERVICE_NAME="wg-quick@${WG_IFACE}"
}

wg_update_vars

# 接口名校验，防止注入非法参数
wg_valid_iface() {
    [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]
}

wg_card() {
    local title="$1"
    shift
    echo
    echo -e "${CYAN}╭──────────────── ${title} ────────────────╮${NC}"
    for line in "$@"; do
        echo -e " ${WHITE}${line}${NC}"
    done
    echo -e "${CYAN}╰──────────────────────────────────────────╯${NC}"
    echo
}

# --- 多接口支持辅助函数 ---

# 列出所有已配置的 WG 接口（扫描 /etc/wireguard/*.conf）
wg_list_existing() {
    ls /etc/wireguard/*.conf 2>/dev/null | sed 's|.*/||; s|\.conf$||' | sort -u
}

# 接口运行状态: active / inactive
wg_iface_state() {
    local iface="$1"
    if systemctl is-active "wg-quick@${iface}" >/dev/null 2>&1; then
        echo "active"
    elif [[ -n "$iface" ]] && ip link show "$iface" >/dev/null 2>&1; then
        echo "active"
    else
        echo "inactive"
    fi
}

# 接口监听端口
wg_listen_port() {
    local iface="$1"
    local p
    p=$(wg show "$iface" listen-port 2>/dev/null)
    [[ -n "$p" ]] && echo "$p" || echo "—"
}

# 接口本端 IP（优先读配置 Address，退化为 ip addr 的 inet/inet6）
wg_iface_addr() {
    local iface="$1"
    local a
    a=$(grep -E '^[[:space:]]*Address' "/etc/wireguard/${iface}.conf" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1 | head -n1)
    [[ -z "$a" ]] && a=$(ip addr show dev "$iface" 2>/dev/null | awk '/inet /{gsub(/\/.*/,"",$2); print $2; exit}')
    [[ -z "$a" ]] && a=$(ip addr show dev "$iface" 2>/dev/null | awk '/inet6 /{gsub(/\/.*/,"",$2); print $2; exit}')
    echo "${a:-—}"
}

# 最新握手时间（秒 → 时间）
wg_latest_handshake() {
    local iface="$1"
    local h
    h=$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    if [[ -n "$h" && "$h" != "0" ]]; then
        date -d "@$h" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "近期"
    else
        echo "无"
    fi
}

# 全部接口总览（表格）
wg_overview() {
    local ifaces state port addr hs iface
    ifaces=$(wg_list_existing)
    if [[ -z "$ifaces" ]]; then
        echo "  （尚未配置任何 WireGuard 接口，可用 1/2/3 模式创建）"
        return
    fi
    echo -e "  ${GRAY}接口        状态       监听端口   本端地址          最新握手${NC}"
    echo -e "  ${GRAY}----------------------------------------------------------------${NC}"
    for iface in $ifaces; do
        state=$(wg_iface_state "$iface")
        if [[ "$state" == "active" ]]; then
            port=$(wg_listen_port "$iface")
            addr=$(wg_iface_addr "$iface")
            hs=$(wg_latest_handshake "$iface")
        else
            port=$(grep -E '^ListenPort' "/etc/wireguard/${iface}.conf" 2>/dev/null | awk '{print $3}')
            addr=$(grep -E '^Address' "/etc/wireguard/${iface}.conf" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)
            hs="—"
        fi
        [[ -z "$port" ]] && port="—"
        [[ -z "$addr" ]] && addr="—"
        if [[ "$iface" == "$WG_IFACE" ]]; then
            printf "  ${GREEN}▶ %-8s${NC} %-9s %-11s %-17s %s\n" "$iface" "$state" "$port" "$addr" "$hs"
        else
            printf "  %-10s %-9s %-11s %-17s %s\n" "$iface" "$state" "$port" "$addr" "$hs"
        fi
    done
    echo -e "  ${GRAY}----------------------------------------------------------------${NC}"
}

# 切换操作接口
wg_select_interface() {
    ui_header "切换 WireGuard 操作接口"
    local ifaces
    ifaces=$(wg_list_existing)
    echo -e "当前操作接口: ${GREEN}${WG_IFACE}${NC}"
    echo
    if [[ -n "$ifaces" ]]; then
        echo -e "已配置接口:"
        local i
        i=0
        for iface in $ifaces; do
            i=$((i + 1))
            printf "  %d) %s  [%s]\n" "$i" "$iface" "$(wg_iface_state "$iface")"
        done
        echo
    fi
    read -rp "输入要切换的接口名，或回车保持 ${WG_IFACE}: " new_iface
    if [[ -n "$new_iface" ]]; then
        if wg_valid_iface "$new_iface"; then
            WG_IFACE="$new_iface"
            wg_update_vars
            ui_success "已切换操作接口为 ${WG_IFACE}"
        else
            ui_warn "接口名不合法，保持 ${WG_IFACE}"
        fi
    else
        ui_info "保持 ${WG_IFACE}"
    fi
}

# 启动一个已配置的接口
wg_start_interface() {
    ui_header "启动 WireGuard 接口"
    wg_ask_interface

    if [[ ! -f "$WG_CONF" ]]; then
        ui_error "未找到配置文件：${WG_CONF}"
        ui_warn "请先用 A/B/C 模式创建 ${WG_IFACE} 的配置。"
        return 1
    fi

    wg_enable_restart
}

wg_ask_interface() {
    echo
    echo -e "${YELLOW}WireGuard 接口名称${NC}"
    echo -e "当前操作接口: ${GREEN}${WG_IFACE}${NC}"
    read -rp "回车使用 ${WG_IFACE}，或输入新接口名 如 wg0/wg1/tun0: " input_iface

    if [[ -n "$input_iface" ]]; then
        if wg_valid_iface "$input_iface"; then
            WG_IFACE="$input_iface"
        else
            ui_warn "接口名只能包含字母、数字、下划线、点、横线。保持 ${WG_IFACE}。"
        fi
    fi

    wg_update_vars
    ui_kv "接口名称" "${GREEN}${WG_IFACE}${NC}"
    ui_kv "配置文件" "${CYAN}${WG_CONF}${NC}"
}

wg_install() {
    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
        ui_info "WireGuard 已安装。"
        return 0
    fi

    ui_info "正在安装 WireGuard..."

    if command -v apt >/dev/null 2>&1; then
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y wireguard curl iproute2 iputils-ping >/dev/null
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard curl iproute2 iputils-ping >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wireguard-tools curl iproute iputils >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y wireguard-tools curl iproute iputils >/dev/null
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache wireguard-tools curl iproute2 iputils >/dev/null
    else
        ui_error "当前系统暂不支持自动安装，请手动安装 wireguard / wireguard-tools / curl。"
        return 1
    fi

    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
        ui_success "WireGuard 安装完成。"
        return 0
    else
        ui_error "WireGuard 安装失败，请检查系统源。"
        return 1
    fi
}

wg_gen_keys() {
    umask 077
    mkdir -p /etc/wireguard

    if [[ ! -f "$WG_PRIVATE_KEY_FILE" ]]; then
        wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey > "$WG_PUBLIC_KEY_FILE"
        chmod 600 "$WG_PRIVATE_KEY_FILE" "$WG_PUBLIC_KEY_FILE"
        ui_success "密钥已生成。"
    else
        ui_info "发现已有密钥，继续使用。"
        if [[ ! -f "$WG_PUBLIC_KEY_FILE" ]]; then
            wg pubkey < "$WG_PRIVATE_KEY_FILE" > "$WG_PUBLIC_KEY_FILE"
            chmod 600 "$WG_PUBLIC_KEY_FILE"
        fi
    fi

    WG_PRIV_KEY="$(cat "$WG_PRIVATE_KEY_FILE" 2>/dev/null)"
    WG_PUB_KEY="$(cat "$WG_PUBLIC_KEY_FILE" 2>/dev/null)"

    [[ -z "$WG_PRIV_KEY" || -z "$WG_PUB_KEY" ]] && {
        ui_error "密钥读取失败。"
        return 1
    }
    return 0
}

wg_random_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 8000-9000 -n 1
    else
        echo $((8000 + RANDOM % 1001))
    fi
}

wg_guess_next_ip() {
    local ip="$1"
    local fallback="$2"
    local base_ip
    local last_octet

    base_ip="$(echo "$ip" | awk -F. 'NF==4 {print $1"."$2"."$3}')"
    last_octet="$(echo "$ip" | awk -F. 'NF==4 {print $4}')"

    if [[ -n "$base_ip" && "$last_octet" =~ ^[0-9]+$ && "$last_octet" -lt 254 ]]; then
        echo "${base_ip}.$((last_octet + 1))"
    else
        echo "$fallback"
    fi
}

wg_enable_restart() {
    ui_info "正在启动 WireGuard 服务：${WG_SERVICE_NAME}"

    if ! command -v systemctl >/dev/null 2>&1; then
        ui_error "当前系统没有 systemctl，无法自动启动 wg-quick 服务。"
        ui_warn "你可以手动执行：wg-quick up ${WG_IFACE}"
        return 1
    fi

    systemctl enable "$WG_SERVICE_NAME" >/dev/null 2>&1 || true

    if systemctl restart "$WG_SERVICE_NAME"; then
        ui_success "WireGuard 已启动。"
        return 0
    else
        ui_error "WireGuard 启动失败。"
        echo
        systemctl status "$WG_SERVICE_NAME" --no-pager -l | sed -n '1,16p' || true
        return 1
    fi
}

# --- A 利群主机（内网发起端）---
wg_logic_a() {
    ui_header "WireGuard - A 利群主机 / 内网发起端"
    wg_ask_interface

    echo
    echo -e "${YELLOW}B 机器 云端 / 公网 是否已经部署完成？${NC}"
    read -rp "如果 B 已完成请输入 y，否则输入 n: " b_ready

    wg_install || return 1
    wg_gen_keys || return 1

    echo
    read -rp "本机内网 WireGuard IP，默认 10.198.1.1: " local_ip
    local_ip="${local_ip:-10.198.1.1}"

    # 防误覆盖：目标接口已有配置时需确认
    if [[ -f "$WG_CONF" ]]; then
        ui_warn "配置文件 ${WG_CONF} 已存在，将被覆盖重建。"
        read -rp "确认覆盖并继续? y/n: " ov
        [[ "$ov" != "y" && "$ov" != "Y" ]] && {
            ui_info "已取消。"
            return 1
        }
    fi

    cat > "$WG_CONF" <<__LK_WGCONF_A__
[Interface]
# Generated by LeiKwan Host Script
PrivateKey = $WG_PRIV_KEY
Address = $local_ip/24
MTU = 1280
__LK_WGCONF_A__

    chmod 600 "$WG_CONF"

    if [[ "$b_ready" == "y" || "$b_ready" == "Y" ]]; then
        echo
        echo -e "${GREEN}请输入 B 机器信息${NC}"
        read -rp "B 的公网 IP:端口: " b_endpoint
        read -rp "B 的 PublicKey: " b_pubkey

        if [[ -z "$b_endpoint" || -z "$b_pubkey" ]]; then
            ui_error "B 的 IP:端口 或 PublicKey 不能为空。"
            return 1
        fi

        local auto_b_ip
        auto_b_ip="$(wg_guess_next_ip "$local_ip" "10.198.1.2")"
        read -rp "B 的 WireGuard 内网 IP，默认 ${auto_b_ip}: " b_internal_ip
        b_internal_ip="${b_internal_ip:-$auto_b_ip}"

        cat >> "$WG_CONF" <<__LK_WGCONF_A_PEER__

[Peer]
PublicKey = $b_pubkey
Endpoint = $b_endpoint
AllowedIPs = $b_internal_ip/32
PersistentKeepalive = 25
__LK_WGCONF_A_PEER__

        wg_enable_restart || return 1

        echo
        ui_info "正在测试连接：ping ${b_internal_ip}"
        ping -c 3 -W 1 "$b_internal_ip" || true
    else
        ui_success "A 机器基础配置已生成。"

        wg_card "复制到云端 B 机器" \
            "A 的 WireGuard IP : $local_ip" \
            "A 的 PublicKey    : $WG_PUB_KEY"

        ui_warn "下一步："
        echo "1. 去云端 / 公网 B 机器，运行本脚本（wg-liqun.sh）选择 B 模式。"
        echo "2. 在 B 的 Peer 中填写 A 的 PublicKey，并允许 A 的 WireGuard IP。"
        echo "3. 拿到 B 的 公网IP:端口、PublicKey、WireGuard IP。"
        echo "4. 回到本机 WireGuard 菜单，选择 3 最终握手。"
    fi
}

# --- B 云端公网服务器部署（与 A 端三合一搭配）---
wg_logic_b() {
    ui_header "WireGuard - B 云端公网服务器部署"
    wg_ask_interface

    echo
    echo -e "${YELLOW}A 机器（利群主机，运行三合一脚本）是否已完成第一步 A？${NC}"
    read -rp "A 已完成请输入 y，否则退出: " a_done
    [[ "$a_done" != "y" && "$a_done" != "Y" ]] && {
        ui_error "请先在 A 机器上完成第一步。"
        return 1
    }

    echo
    echo -e "${GREEN}请输入 A 机器提供的信息${NC}"
    read -rp "A 的 PublicKey: " a_pubkey
    read -rp "A 的 WireGuard 内网 IP 如 10.198.1.1: " a_internal_ip

    if [[ -z "$a_pubkey" || -z "$a_internal_ip" ]]; then
        ui_error "输入不能为空。"
        return 1
    fi

    wg_install || return 1
    wg_gen_keys || return 1

    local listen_port
    listen_port=$(wg_random_port)

    local base_ip
    local my_octet
    local default_my_ip
    local my_ip
    base_ip="$(echo "$a_internal_ip" | awk -F. 'NF==4 {print $1"."$2"."$3}')"
    my_octet="$(echo "$a_internal_ip" | awk -F. 'NF==4 {print $4}')"
    if [[ -n "$base_ip" && "$my_octet" =~ ^[0-9]+$ && "$my_octet" -lt 254 ]]; then
        default_my_ip="${base_ip}.$((my_octet + 1))"
    else
        default_my_ip="10.198.1.2"
    fi

    read -rp "本机 WireGuard 内网 IP，默认 ${default_my_ip}: " my_ip
    my_ip="${my_ip:-$default_my_ip}"

    # 防误覆盖：目标接口已有配置时需确认
    if [[ -f "$WG_CONF" ]]; then
        ui_warn "配置文件 ${WG_CONF} 已存在，将被覆盖重建。"
        read -rp "确认覆盖并继续? y/n: " ov
        [[ "$ov" != "y" && "$ov" != "Y" ]] && {
            ui_info "已取消。"
            return 1
        }
    fi

    ui_info "正在检测公网 IPv4..."
    local public_ip
    public_ip=$(curl -4 -s --max-time 3 --noproxy '*' ifconfig.me)
    [[ -z "$public_ip" ]] && public_ip=$(curl -s --max-time 3 --noproxy '*' ifconfig.me)
    if [[ -z "$public_ip" ]]; then
        read -rp "公网 IP 检测失败，请手动输入: " public_ip
    else
        ui_info "检测到公网 IP: $public_ip"
    fi

    cat > "$WG_CONF" <<__LK_WGCONF_B__
[Interface]
# Generated by LeiKwan Host Script
PrivateKey = $WG_PRIV_KEY
Address = $my_ip/24
ListenPort = $listen_port
MTU = 1280
PreUp = sysctl -w net.ipv4.ip_forward=1

[Peer]
PublicKey = $a_pubkey
AllowedIPs = $a_internal_ip/32
__LK_WGCONF_B__

    chmod 600 "$WG_CONF"

    wg_enable_restart || return 1

    ui_success "B 机器配置完成。"
    wg_card "复制回 A 机器（最终握手用）" \
        "B 的 公网 IP:端口 : ${public_ip}:${listen_port}" \
        "B 的 PublicKey    : ${WG_PUB_KEY}" \
        "B 的 WireGuard IP : ${my_ip}"
    ui_warn "请回到 A 机器，在 WireGuard 菜单选择 3 最终握手，填入上述信息。"
}

# --- C 最终握手（重复 PublicKey 不再追加，避免 wg-quick 启动失败）---
wg_logic_c() {
    ui_header "WireGuard - 最终握手 / 输入云端 B 信息"
    wg_ask_interface

    if [[ ! -f "$WG_CONF" ]]; then
        ui_error "未找到配置文件：${WG_CONF}"
        ui_warn "请先执行 WireGuard 菜单 1，初始化本机并生成 A 信息。"
        return 1
    fi

    echo
    echo -e "${GREEN}请输入 B 机器返回的信息${NC}"
    read -rp "B 的公网 IP:端口: " b_endpoint
    read -rp "B 的 PublicKey: " b_pubkey
    read -rp "B 的 WireGuard 内网 IP，默认 10.198.1.2: " b_ip
    b_ip="${b_ip:-10.198.1.2}"

    if [[ -z "$b_endpoint" || -z "$b_pubkey" || -z "$b_ip" ]]; then
        ui_error "B 的 IP:端口 / PublicKey / 内网 IP 不能为空。"
        return 1
    fi

    if grep -qF "$b_pubkey" "$WG_CONF"; then
        ui_warn "配置中已经存在该 PublicKey，为避免 WireGuard 启动失败，不再重复追加。"
        return 0
    fi

    cat >> "$WG_CONF" <<__LK_WGCONF_C__

[Peer]
PublicKey = $b_pubkey
Endpoint = $b_endpoint
AllowedIPs = $b_ip/32
PersistentKeepalive = 25
__LK_WGCONF_C__

    chmod 600 "$WG_CONF"

    wg_enable_restart || return 1

    echo
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN} WireGuard 隧道已建立：${WG_IFACE}${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo

    ui_info "正在测试连接：ping ${b_ip}"
    ping -c 3 -W 1 "$b_ip" || true
}

wg_show_status() {
    ui_header "WireGuard 状态查看"

    echo
    ui_section "全部 WireGuard 接口"
    wg_overview

    wg_ask_interface

    echo
    ui_kv "接口名称" "${GREEN}${WG_IFACE}${NC}"
    ui_kv "配置文件" "${CYAN}${WG_CONF}${NC}"
    ui_kv "服务名称" "${YELLOW}${WG_SERVICE_NAME}${NC}"
    if [[ "$(wg_iface_state "$WG_IFACE")" == "active" ]]; then
        ui_kv "运行状态" "${GREEN}运行中${NC}"
        ui_kv "监听端口" "${CYAN}$(wg_listen_port "$WG_IFACE")${NC}"
        ui_kv "本端地址" "${CYAN}$(wg_iface_addr "$WG_IFACE")${NC}"
        ui_kv "最新握手" "${GREEN}$(wg_latest_handshake "$WG_IFACE")${NC}"
    else
        ui_kv "运行状态" "${RED}未运行${NC}"
    fi

    echo
    ui_section "systemd 状态"
    systemctl status "$WG_SERVICE_NAME" --no-pager -l | sed -n '1,16p' || true

    echo
    ui_section "wg show ${WG_IFACE}"
    wg show "$WG_IFACE" 2>/dev/null || wg show 2>/dev/null || ui_warn "暂无 WireGuard 运行状态。"
}

wg_stop_disable() {
    ui_header "WireGuard 停止 / 禁用"
    local ifaces state iface
    ifaces=$(wg_list_existing)
    if [[ -z "$ifaces" ]]; then
        ui_warn "尚无已配置接口。"
        return 1
    fi

    echo -e "选择要停止并禁用的接口："
    local i
    i=0
    for iface in $ifaces; do
        i=$((i + 1))
        state=$(wg_iface_state "$iface")
        if [[ "$state" == "active" ]]; then
            printf "  %d) %s  [${GREEN}运行中${NC}]\n" "$i" "$iface"
        else
            printf "  %d) %s  [${RED}未运行${NC}]\n" "$i" "$iface"
        fi
    done
    echo "  0) 取消"
    read -rp "选择接口编号: " sel
    if [[ -z "$sel" || "$sel" == "0" ]]; then return 0; fi
    [[ "$sel" =~ ^[0-9]+$ ]] || { ui_warn "无效输入。"; return 1; }

    local iface_list
    iface_list=($(echo "$ifaces"))
    [[ "$sel" -lt 1 || "$sel" -gt "${#iface_list[@]}" ]] && { ui_warn "无效编号。"; return 1; }

    local target="${iface_list[$((sel - 1))]}"
    local svc="wg-quick@${target}"
    read -rp "确认停止并禁用 ${target} ? y/n: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0

    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true

    ui_success "已停止并禁用 ${target}"
}

wg_main_menu() {
    while true; do
        ui_header "WireGuard 专用脚本 ${CURRENT_VERSION}"

        ui_kv "当前操作接口" "${GREEN}${WG_IFACE}${NC}  [$([[ "$(wg_iface_state "$WG_IFACE")" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}")]"
        ui_kv "默认网段" "${GREEN}10.198.1.0/24${NC}"
        ui_kv "默认 MTU" "${YELLOW}1280${NC}"

        echo
        ui_section "已配置接口总览"
        wg_overview

        ui_section "功能菜单"
        ui_item "1" "A 模式" "初始化本机 / 生成 A 信息"
        ui_item "2" "B 模式" "云端公网服务器部署"
        ui_item "3" "C 最终握手" "输入云端 B 信息"
        ui_item "4" "查看 WireGuard 状态"
        ui_item "5" "切换操作接口" "多接口时选择要操作的接口"
        ui_item "6" "启动接口" "启动已配置但未运行的接口"
        ui_item "7" "停止 / 禁用接口" "选择要停止并禁用的接口"
        ui_item "0" "退出"

        ui_line "─"

        read -rp "$(echo -e "${YELLOW}请输入选项:${NC} ")" choice

        case "$choice" in
            1 | a | A)
                wg_logic_a
                ui_pause
                ;;
            2 | b | B)
                wg_logic_b
                ui_pause
                ;;
            3 | c | C)
                wg_logic_c
                ui_pause
                ;;
            4)
                wg_show_status
                ui_pause
                ;;
            5)
                wg_select_interface
                ui_pause
                ;;
            6)
                wg_start_interface
                ui_pause
                ;;
            7)
                wg_stop_disable
                ui_pause
                ;;
            0)
                clear
                ui_success "已退出。"
                exit 0
                ;;
            *)
                ui_warn "无效输入，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

case "${1:-}" in
    a|A) wg_logic_a ;;
    b|B) wg_logic_b ;;
    c|C) wg_logic_c ;;
    status) wg_show_status ;;
    stop) wg_stop_disable ;;
    *) wg_main_menu ;;
esac
