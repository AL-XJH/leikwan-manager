#!/bin/bash
# ==============================================================================
# 利群管家 | LeiKwan Manager v1.3
# 包含: IPv6 智能管家 双线/DDNS + IPv4 PBR 自动化策略路由(端口分流/NAT) + WireGuard
# ------------------------------------------------------------------------------
# 由旧三合一 d.sh (v1.2-XJH-WG) 升级而来，融合以下新脚本：
#   * v6-mng.sh  v8.9-merged  —— IPv6 管理引擎：深度清理 / ping优先选源 /
#                                 metric受管路由 / 多provider DDNS(CF FQDN规范化、
#                                 重复记录清理、定期远端校验)
#   * dual-route-v4.5.sh      —— IPv4 多出口策略路由：端口精准分流 / fwmark / NAT伪装
#   * auto-wg.sh  v2.2        —— WireGuard 三模式：A 内网发起 / B 云端部署 / C 最终握手
# 同时修复旧三合一已知 bug（详见各模块注释）。
# ==============================================================================

CURRENT_VERSION="lk-manager-v1.3"

if locale -a 2>/dev/null | grep -qiE '^(C\.UTF-8|C\.utf8)$'; then
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
else
    export LC_ALL=C
    export LANG=C
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ==============================================================================
# UI 美化工具
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

v6_ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0

    echo -e "${YELLOW:-}检测到 jq 未安装，正在尝试自动安装...${NC:-}"

    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y jq
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release
        yum install -y jq
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq
    elif command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install jq
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm jq
    else
        echo -e "${RED:-}无法自动安装 jq，请手动安装 jq 后再运行脚本。${NC:-}"
        return 1
    fi

    command -v jq >/dev/null 2>&1 || {
        echo -e "${RED:-}jq 安装失败，请手动安装。${NC:-}"
        return 1
    }

    echo -e "${GREEN:-}jq 已安装。${NC:-}"
}

# 计算中英文混排的终端显示宽度
# ASCII 按 1 列，常见中文 UTF-8 3 字节按 2 列
v6_text_width() {
    local s="$1"
    local bytes nonascii ascii

    bytes=$(printf "%s" "$s" | LC_ALL=C wc -c | tr -d ' ')
    nonascii=$(printf "%s" "$s" | LC_ALL=C tr -cd '\200-\377' | wc -c | tr -d ' ')
    ascii=$((bytes - nonascii))

    printf "%s" $((ascii + nonascii * 2 / 3))
}

# 菜单项：ui_item "1" "自动选路" "设置默认 IPv6 出口"
ui_item() {
    local key="$1"
    local title="$2"
    local desc="${3:-}"

    # 右侧说明文字起始列
    local desc_col="${UI_DESC_COL:-34}"

    local left_plain="  ${key}. ${title}"
    local width pad

    # 没有说明文字时，普通输出
    if [[ -z "$desc" ]]; then
        printf "  %b%s%b. %s\n" "${CYAN:-}" "$key" "${NC:-}" "$title"
        return
    fi

    width=$(v6_text_width "$left_plain")
    pad=$((desc_col - width))
    (( pad < 2 )) && pad=2

    # 右侧说明使用浅灰色
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
    # 按显示宽度对齐（中文算 2 列），避免 %-14s 按字节补齐导致冒号参差
    w=$(v6_text_width "$key")
    pad=$((16 - w))
    (( pad < 1 )) && pad=1
    printf " ${GRAY}%s${NC}%*s: %b\n" "$key" "$pad" "" "$value"
}

ui_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

ui_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

ui_error() {
    echo -e "${RED}❌ $1${NC}"
}

ui_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

ui_pause() {
    echo
    read -n 1 -s -r -p "按任意键继续..."
}

mask_secret() {
    local s="$1"
    local len=${#s}

    if [[ -z "$s" ]]; then
        echo "未设置"
    elif [[ "$len" -le 8 ]]; then
        echo "********"
    else
        echo "${s:0:4}********${s: -4}"
    fi
}

if [[ $EUID -ne 0 ]]; then
    ui_error "此脚本必须以 root 权限运行。"
    exit 1
fi

# --- 管道运行兼容 (curl | bash) ---
# 一键安装场景：脚本由安装器下载到磁盘后 exec 执行，但继承的 stdin 可能是已关闭的管道，
# 恢复为 /dev/tty 才能让菜单 read 读取键盘。
# 若用户直接 `curl | bash` 管道运行主脚本本身（$0=bash），则提示改用一键安装，避免脚本读取错乱。
if [[ -z "${1:-}" && ! -t 0 ]]; then
    if [[ "$(basename "$0" 2>/dev/null)" == "bash" || "$(basename "$0" 2>/dev/null)" == "sh" ]]; then
        echo -e "${YELLOW}检测到直接管道运行主脚本。为避免菜单无法读取键盘，请使用一键安装：${NC}"
        echo "  curl -fsSL https://raw.githubusercontent.com/AL-XJH/leikwan-manager/main/install-leikwan.sh | bash"
        exit 1
    else
        # 脚本在磁盘上由安装器 exec 执行，安全恢复终端输入
        exec 0< /dev/tty 2>/dev/null || true
    fi
fi

# --- Debian 13 兼容性修复 ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ "$ID" == "debian" ]] && [[ "$VERSION_ID" == "13" || "$VERSION_CODENAME" == "trixie" ]]; then
        if [ ! -f /etc/iproute2/rt_tables ] || ! grep -q "253 default" /etc/iproute2/rt_tables; then
            mkdir -p /etc/iproute2
            echo -e "255 local\n254 main\n253 default\n0 unspec" > /etc/iproute2/rt_tables
        fi
    fi
fi

SCRIPT_PATH="$(realpath "$0")"

# ==============================================================================
# 模块 A: IPv6 智能管家
# ==============================================================================
V6_CONFIG_FILE="/etc/ipv6_manager.conf"
V6_LOG_FILE="/var/log/ipv6_manager.log"
V6_PING_TARGET="2400:3200::1"
# 本脚本创建的 IPv6 默认路由 metric，数值越小优先级越高；用于压过 RA 默认路由。
V6_MANAGED_METRIC="66"
touch "$V6_CONFIG_FILE" "$V6_LOG_FILE"

v6_log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${V6_LOG_FILE}" >&2
}

v6_kv_save() {
    local KEY="$1"
    local VALUE="$2"
    local tmpfile="$V6_CONFIG_FILE.tmp.$$"
    # 用 awk 安全替换，避免 token/secret 含 | & / 等字符时 sed 写坏配置
    if grep -q "^${KEY}=" "$V6_CONFIG_FILE"; then
        awk -v k="$KEY" -v v="$VALUE" '
            BEGIN { prefix = "^" k "=" }
            $0 ~ prefix { print k "=\"" v "\""; done=1; next }
            { print }
            END { if (!done) print k "=\"" v "\"" }
        ' "$V6_CONFIG_FILE" > "$tmpfile" && mv "$tmpfile" "$V6_CONFIG_FILE"
    else
        echo "${KEY}=\"${VALUE}\"" >> "$V6_CONFIG_FILE"
    fi
}

# --- 配置加载 (Bug 修复 #1) ---
# 旧实现直接 source 配置文件，存在配置注入风险。
# 现改为逐行安全解析：仅接受 KEY="value" 形式，key 做格式校验，value 用 printf -v 赋值。
v6_load_config() {
    DEFAULT_OUTBOUND_ISP=""
    IP_SELECT_MODE="latency"
    POLICY_ROUTE_ENABLED="false"
    POLICY_ROUTE_ISP=""
    POLICY_ROUTE_DEST_IP=""
    IFACE_CT="auto"
    IFACE_CU="auto"

    DDNS_CT_ENABLE="false"
    DDNS_CT_PROVIDER=""
    DDNS_CT_TOKEN=""
    DDNS_CT_ID=""
    DDNS_CT_SECRET=""
    DDNS_CT_DOMAIN=""
    DDNS_CT_HOST=""
    DDNS_CT_WEBHOOK=""
    DDNS_CT_EMAIL=""
    DDNS_CT_TTL="1"

    DDNS_CU_ENABLE="false"
    DDNS_CU_PROVIDER=""
    DDNS_CU_TOKEN=""
    DDNS_CU_ID=""
    DDNS_CU_SECRET=""
    DDNS_CU_DOMAIN=""
    DDNS_CU_HOST=""
    DDNS_CU_WEBHOOK=""
    DDNS_CU_EMAIL=""
    DDNS_CU_TTL="1"

    [ ! -f "$V6_CONFIG_FILE" ] && return

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key=$(echo "$key" | tr -d '[:space:]')
        [[ -z "$key" ]] && continue
        # 仅接受合法变量名，跳过注释/异常行
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # 去首尾双引号
        value="${value#\"}"
        value="${value%\"}"
        case "$key" in
            DEFAULT_OUTBOUND_ISP) DEFAULT_OUTBOUND_ISP="$value" ;;
            IP_SELECT_MODE) IP_SELECT_MODE="$value" ;;
            POLICY_ROUTE_ENABLED) POLICY_ROUTE_ENABLED="$value" ;;
            POLICY_ROUTE_ISP) POLICY_ROUTE_ISP="$value" ;;
            POLICY_ROUTE_DEST_IP) POLICY_ROUTE_DEST_IP="$value" ;;
            IFACE_CT) IFACE_CT="$value" ;;
            IFACE_CU) IFACE_CU="$value" ;;
            DDNS_CT_*|DDNS_CU_*) printf -v "$key" "%s" "$value" ;;
        esac
    done < "$V6_CONFIG_FILE"
}

v6_show_status_bar() {
    v6_load_config

    local last_time
    local last_change
    local last_change_isp
    local ct_ip
    local cu_ip
    local route_get
    local curr_src
    local curr_dev
    local curr_isp

    last_time=$(grep ">>> IPv6 自动任务启动 <<<" "$V6_LOG_FILE" 2>/dev/null | tail -n 1 | awk -F' - ' '{print $1}')

    last_change=$(cat "/tmp/ipv6_last_change_time.txt" 2>/dev/null)
    last_change_isp=$(cat "/tmp/ipv6_last_change_isp.txt" 2>/dev/null)

    case "$last_change_isp" in
        CT|ct)
            last_change_isp="电信"
            ;;
        CU|cu)
            last_change_isp="联通"
            ;;
    esac

    if [[ -n "$last_change" && -n "$last_change_isp" ]]; then
        last_change="${last_change}（${last_change_isp}）"
    fi

    ct_ip=$(cat "/tmp/ipv6_last_ddns_CT.txt" 2>/dev/null)
    cu_ip=$(cat "/tmp/ipv6_last_ddns_CU.txt" 2>/dev/null)

    # Bug 修复 #2: 用 route get 取真实出口，而不是 ip route show default 首行
    route_get=$(ip -6 route get "$V6_PING_TARGET" 2>/dev/null)
    curr_src=$(echo "$route_get" | awk '{for(i=1;i<=NF;i++){ if($i=="src"){print $(i+1); exit} }}')
    curr_dev=$(echo "$route_get" | awk '{for(i=1;i<=NF;i++){ if($i=="dev"){print $(i+1); exit} }}')
    curr_isp="未知"

    [[ "$curr_src" == 240e* ]] && curr_isp="电信"
    [[ "$curr_src" == 2408* ]] && curr_isp="联通"

    local ip_mode="延迟最佳"
    [[ "$IP_SELECT_MODE" == "latest" ]] && ip_mode="最新下发"

    local ct_st="${RED}关闭${NC}"
    local cu_st="${RED}关闭${NC}"
    [[ "$DDNS_CT_ENABLE" == "true" ]] && ct_st="${GREEN}开启${NC}"
    [[ "$DDNS_CU_ENABLE" == "true" ]] && cu_st="${GREEN}开启${NC}"

    echo -e "${CYAN}╭──────────────── IPv6 状态概览 ────────────────╮${NC}"
    ui_kv "任务最后运行" "${CYAN}${last_time:-从未运行}${NC}"
    ui_kv "上次 IP 变动" "${CYAN}${last_change:-从未记录}${NC}"
    ui_kv "当前出口" "${GREEN}${curr_isp}${NC} @ ${YELLOW}${curr_dev:-未知}${NC}"
    ui_kv "电信接口" "${YELLOW}${IFACE_CT:-auto}${NC}"
    ui_kv "联通接口" "${YELLOW}${IFACE_CU:-auto}${NC}"
    ui_kv "IP选择策略" "${BLUE}${ip_mode}${NC}"
    ui_kv "电信 DDNS" "$ct_st"
    ui_kv "联通 DDNS" "$cu_st"
    ui_kv "电信推送 IP" "${GREEN}${ct_ip:-未获取 / 未推送}${NC}"
    ui_kv "联通推送 IP" "${GREEN}${cu_ip:-未获取 / 未推送}${NC}"
    echo -e "${CYAN}╰──────────────────────────────────────────────╯${NC}"
}

# --- IPv6 地址清理与扫描 (v8.9 引擎) ---
v6_clean_and_scan() {
    # 1. 深度清理不适合 DDNS/选路使用的 IPv6 地址
    #    正常的 dynamic / mngtmpaddr 会保留；只清理：
    #    deprecated、preferred_lft 0、temporary、tentative、dadfailed
    ip -6 -o addr show scope global | while read -r line; do
        local dev="" ip_full="" pref_lft="" reason=""
        dev=$(echo "$line" | awk '{print $2}')
        ip_full=$(echo "$line" | awk '{for(i=1;i<=NF;i++){ if($i=="inet6"){print $(i+1); exit} }}')
        pref_lft=$(echo "$line" | awk '{for(i=1;i<=NF;i++){ if($i=="preferred_lft"){print $(i+1); exit} }}')

        [[ -z "$dev" || -z "$ip_full" ]] && continue

        [[ "$line" =~ deprecated ]] && reason="${reason:+$reason,}deprecated"
        [[ "$line" =~ temporary ]] && reason="${reason:+$reason,}temporary"
        [[ "$line" =~ tentative ]] && reason="${reason:+$reason,}tentative"
        [[ "$line" =~ dadfailed ]] && reason="${reason:+$reason,}dadfailed"
        [[ "$pref_lft" == "0" || "$pref_lft" == "0sec" ]] && reason="${reason:+$reason,}preferred_lft=0"

        if [[ -n "$reason" ]]; then
            v6_log "清理 IPv6 [$reason]: $ip_full dev $dev"
            ip -6 addr del "$ip_full" dev "$dev" 2>/dev/null || v6_log "清理失败: $ip_full dev $dev"
        fi
    done

    # 2. 扫描候选 IP
    #    240e:* = 电信   2408:* = 联通
    #    按“前缀 + 接口锁定”选源地址。
    BEST_TELECOM_IP=""
    BEST_TELECOM_IFACE=""
    BEST_UNICOM_IP=""
    BEST_UNICOM_IFACE=""

    local raw_list
    raw_list=$(ip -6 -o addr show scope global | awk '
        {
            iface=$2; ip_full=""; pref_lft="";
            for(i=1;i<=NF;i++) {
                if($i=="inet6") ip_full=$(i+1);
                if($i=="preferred_lft") pref_lft=$(i+1);
            }
            if(ip_full=="") next;
            if($0 ~ /deprecated|temporary|tentative|dadfailed/) next;
            if(pref_lft=="0" || pref_lft=="0sec") next;
            print ip_full, iface, pref_lft;
        }
    ')
    [ -z "$raw_list" ] && return

    if [[ "$IP_SELECT_MODE" == "latest" ]]; then
        # 最新下发模式: 取 preferred_lft 最大
        local best_tele_pref=-1 best_uni_pref=-1
        while read -r ip_full iface pref_lft; do
            local ip=${ip_full%/*}
            local isp=""

            [[ "$ip" == 240e:* ]] && isp="电信"
            [[ "$ip" == 2408:* ]] && isp="联通"
            [[ -z "$isp" ]] && continue

            [[ "$isp" == "电信" && "$IFACE_CT" != "auto" && "$iface" != "$IFACE_CT" ]] && continue
            [[ "$isp" == "联通" && "$IFACE_CU" != "auto" && "$iface" != "$IFACE_CU" ]] && continue

            local pref_num=0
            if [[ "$pref_lft" == "forever" ]]; then
                pref_num=999999999
            else
                pref_num=${pref_lft%sec}
                [[ "$pref_num" =~ ^[0-9]+$ ]] || pref_num=0
            fi

            if [[ "$isp" == "电信" && "$pref_num" -ge "$best_tele_pref" ]]; then
                best_tele_pref=$pref_num; BEST_TELECOM_IP=$ip; BEST_TELECOM_IFACE=$iface
            elif [[ "$isp" == "联通" && "$pref_num" -ge "$best_uni_pref" ]]; then
                best_uni_pref=$pref_num; BEST_UNICOM_IP=$ip; BEST_UNICOM_IFACE=$iface
            fi
        done <<< "$raw_list"
    else
        # 延迟最佳模式: ping 优先 (v8.9 逻辑，修复旧版 ping 全失败时选不出源的问题)
        local tele_has_ping=0 uni_has_ping=0
        local tele_best_lat=999999 uni_best_lat=999999
        local tele_best_pref=-1 uni_best_pref=-1

        while read -r ip_full iface pref_lft; do
            local ip=${ip_full%/*}
            local isp=""

            [[ "$ip" == 240e:* ]] && isp="电信"
            [[ "$ip" == 2408:* ]] && isp="联通"
            [[ -z "$isp" ]] && continue

            [[ "$isp" == "电信" && "$IFACE_CT" != "auto" && "$iface" != "$IFACE_CT" ]] && continue
            [[ "$isp" == "联通" && "$IFACE_CU" != "auto" && "$iface" != "$IFACE_CU" ]] && continue

            local pref_num=0
            if [[ "$pref_lft" == "forever" ]]; then
                pref_num=999999999
            else
                pref_num=${pref_lft%sec}
                [[ "$pref_num" =~ ^[0-9]+$ ]] || pref_num=0
            fi

            local ping_ok=0 lat=999999 res
            res=$(ping -6 -c 1 -w 1 -I "$ip" "$V6_PING_TARGET" 2>/dev/null)
            if [[ $? -eq 0 ]]; then
                ping_ok=1
                lat=$(echo "$res" | tail -1 | awk -F'/' '{print $5}' | awk '{printf "%.0f", $1}')
                [[ "$lat" =~ ^[0-9]+$ ]] || lat=999999
            fi

            if [[ "$isp" == "电信" ]]; then
                local accept=0
                if [[ $ping_ok -eq 1 && $tele_has_ping -eq 0 ]]; then
                    accept=1
                elif [[ $ping_ok -eq 1 && $tele_has_ping -eq 1 && $lat -lt $tele_best_lat ]]; then
                    accept=1
                elif [[ $ping_ok -eq 0 && $tele_has_ping -eq 0 && ( -z "$BEST_TELECOM_IP" || $pref_num -gt $tele_best_pref ) ]]; then
                    accept=1
                fi
                if [[ $accept -eq 1 ]]; then
                    BEST_TELECOM_IP="$ip"; BEST_TELECOM_IFACE="$iface"; tele_best_pref=$pref_num
                    if [[ $ping_ok -eq 1 ]]; then tele_has_ping=1; tele_best_lat=$lat; fi
                fi
            elif [[ "$isp" == "联通" ]]; then
                local accept=0
                if [[ $ping_ok -eq 1 && $uni_has_ping -eq 0 ]]; then
                    accept=1
                elif [[ $ping_ok -eq 1 && $uni_has_ping -eq 1 && $lat -lt $uni_best_lat ]]; then
                    accept=1
                elif [[ $ping_ok -eq 0 && $uni_has_ping -eq 0 && ( -z "$BEST_UNICOM_IP" || $pref_num -gt $uni_best_pref ) ]]; then
                    accept=1
                fi
                if [[ $accept -eq 1 ]]; then
                    BEST_UNICOM_IP="$ip"; BEST_UNICOM_IFACE="$iface"; uni_best_pref=$pref_num
                    if [[ $ping_ok -eq 1 ]]; then uni_has_ping=1; uni_best_lat=$lat; fi
                fi
            fi
        done <<< "$raw_list"
    fi

    [[ -n "$BEST_TELECOM_IP" ]] && v6_log "扫描结果: 电信 $BEST_TELECOM_IP ($BEST_TELECOM_IFACE)"
    [[ -n "$BEST_UNICOM_IP" ]] && v6_log "扫描结果: 联通 $BEST_UNICOM_IP ($BEST_UNICOM_IFACE)"
}

# --- 路由辅助 (v8.9) ---
v6_get_current_route_info() {
    ip -6 route get "$V6_PING_TARGET" 2>/dev/null | head -n1
}

v6_get_current_src() {
    v6_get_current_route_info | awk '{for(i=1;i<=NF;i++){ if($i=="src"){print $(i+1); exit} }}'
}

v6_get_current_dev() {
    v6_get_current_route_info | awk '{for(i=1;i<=NF;i++){ if($i=="dev"){print $(i+1); exit} }}'
}

v6_get_default_gw_for_iface() {
    local iface="$1"
    # 只接受真正的 IPv6 网关，避免把 metric/expires 数字误当成网关。
    ip -6 route show default dev "$iface" 2>/dev/null | awk '
        $1=="default" {
            for(i=1;i<=NF;i++) {
                if($i=="via" && $(i+1) ~ /:/) { print $(i+1); exit }
            }
        }
    ' | head -n1
}

v6_has_default_route_for_iface() {
    local iface="$1"
    ip -6 route show default dev "$iface" 2>/dev/null | awk '$1=="default"{found=1} END{exit found?0:1}'
}

v6_clear_managed_default_route() {
    # 清掉本脚本上次创建的低 metric 默认路由，避免从电信切到联通时旧路由还压着。
    while ip -6 route del default metric "$V6_MANAGED_METRIC" 2>/dev/null; do :; done
}

v6_apply_route() {
    local isp="$1"
    local ip="$2"
    local iface="$3"

    [[ -z "$ip" || -z "$iface" ]] && {
        v6_log "路由切换失败: IP 或接口为空 isp=$isp ip=$ip iface=$iface"
        return 1
    }

    [[ "$ip" != *:* ]] && {
        v6_log "路由切换失败: 源地址不是 IPv6 -> $ip"
        return 1
    }

    local gw cmd_out rc after_src after_dev
    gw=$(v6_get_default_gw_for_iface "$iface")

    if [[ -z "$gw" ]] && ! v6_has_default_route_for_iface "$iface"; then
        v6_log "路由切换失败: $iface 没有 IPv6 default 路由，不能切到 $isp。请先确认 ip -6 route 里有 default dev $iface"
        return 1
    fi

    v6_clear_managed_default_route

    if [[ -n "$gw" ]]; then
        cmd_out=$(ip -6 route replace default via "$gw" dev "$iface" src "$ip" metric "$V6_MANAGED_METRIC" 2>&1); rc=$?
    else
        # 部分环境是 on-link default，没有 via；这种不能硬填 via。
        cmd_out=$(ip -6 route replace default dev "$iface" src "$ip" metric "$V6_MANAGED_METRIC" 2>&1); rc=$?
    fi

    [[ $rc -ne 0 ]] && {
        v6_log "路由切换失败: $cmd_out"
        return 1
    }

    ip -6 route flush cache 2>/dev/null || true

    after_src=$(v6_get_current_src)
    after_dev=$(v6_get_current_dev)
    if [[ "$after_src" == "$ip" && "$after_dev" == "$iface" ]]; then
        v6_log "路由成功: 默认出口 -> $isp $ip ($iface${gw:+ via $gw}, metric $V6_MANAGED_METRIC)"
        return 0
    else
        v6_log "路由已写入，但当前检测出口为 ${after_src:-未知} @ ${after_dev:-未知}；请检查是否有更高优先级的 ip rule 或特殊路由。"
        return 0
    fi
}

# ==============================================================================
# DDNS API (多 provider + TTL)
# ==============================================================================

# 校验 curl 响应是否为合法 JSON，失败时输出诊断日志（含 curl 退出码 / HTTP 码 / 响应前120字符）。
# 用法: v6_check_json "<响应内容>" "<curl退出码>" "<HTTP码>" "<标签>"
v6_check_json() {
    local resp="$1"
    local curl_rc="$2"
    local http_code="$3"
    local label="$4"
    if [[ -z "$resp" ]]; then
        v6_log "$label: 响应为空 (curl退出码=$curl_rc, HTTP=$http_code) —— 网络不通/超时/被防火墙拦截"
        return 1
    fi
    if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
        v6_log "$label: 响应不是合法 JSON (curl退出码=$curl_rc, HTTP=$http_code)，前120字符: $(echo "$resp" | head -c 120)"
        return 1
    fi
    return 0
}

# 执行 curl 并捕获: 响应写入 outfile, HTTP 码存全局 V6_HTTP_CODE, 退出码存全局 V6_CURL_RC。
# 统一: 强制 IPv4 + 连接超时 5s + 总超时 10s。
# 用法: v6_curl_capture <outfile> [curl args...]
v6_curl_capture() {
    local outfile="$1"
    shift
    V6_HTTP_CODE=$(curl -s -4 --connect-timeout 5 --max-time 10 --noproxy '*' -o "$outfile" -w "%{http_code}" "$@" 2>/dev/null)
    V6_CURL_RC=$?
}

v6_ddns_api_webhook() {
    local url="${2//\{ip\}/$1}"
    v6_log "Webhook: $url"
    local res
    res=$(curl -s --connect-timeout 5 --max-time 10 --noproxy '*' -w "%{http_code}" -o /dev/null "$url")
    [[ "$res" == "200" ]] && return 0 || {
        v6_log "Webhook Error: HTTP $res"
        return 1
    }
}

# Cloudflare (v8.9 增强版): FQDN 规范化 + 重复记录清理 + PUT/PATCH 更新 + TTL
v6_ddns_api_cf() {
    local ip="$1"
    local token="$2"
    local domain="$3"
    local host="$4"
    local email="$5"
    local ttl="${6:-1}"

    # Bug 修复 #3: FQDN 规范化（修复 CF GET 查询必须用 FQDN 才能命中记录）
    host="${host%.}"
    if [[ "$host" == "@" || -z "$host" || "$host" == "$domain" ]]; then
        host="$domain"
    elif [[ "$host" != *."$domain" ]]; then
        host="${host}.${domain}"
    fi

    local hdrs=("-H" "Content-Type: application/json")
    if [[ -n "$email" ]]; then
        hdrs+=("-H" "X-Auth-Email: $email" "-H" "X-Auth-Key: $token")
    else
        hdrs+=("-H" "Authorization: Bearer $token")
    fi

    local tmpfile="/tmp/.ddns_cf_resp.$$"
    local z_res zid

    v6_curl_capture "$tmpfile" "${hdrs[@]}" "https://api.cloudflare.com/client/v4/zones?name=$domain"
    z_res=$(cat "$tmpfile" 2>/dev/null); rm -f "$tmpfile"
    v6_check_json "$z_res" "$V6_CURL_RC" "$V6_HTTP_CODE" "CF(zones)" || return 1

    zid=$(echo "$z_res" | jq -r '.result[0].id // empty')
    [[ -z "$zid" ]] && {
        v6_log "CF Error: ZoneID not found ($(echo "$z_res" | jq -r '.errors[0].message // "未知"'))"
        return 1
    }

    local r_res rec_count rid c_ip c_ttl

    v6_curl_capture "$tmpfile" "${hdrs[@]}" "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=AAAA&name=$host"
    r_res=$(cat "$tmpfile" 2>/dev/null); rm -f "$tmpfile"
    v6_check_json "$r_res" "$V6_CURL_RC" "$V6_HTTP_CODE" "CF(records)" || return 1

    rec_count=$(echo "$r_res" | jq -r '.result | length // 0')

    # Bug 修复 #4: 清理同名重复 AAAA 记录（保留第一条）
    if [[ "$rec_count" -gt 1 ]]; then
        v6_log "CF: 发现 $rec_count 条 $host 的 AAAA 记录，清理多余的 $((rec_count - 1)) 条..."
        local dup_ids did
        dup_ids=$(echo "$r_res" | jq -r '.result[1:] | .[].id')
        for did in $dup_ids; do
            [[ -n "$did" && "$did" != "null" ]] && curl -s -4 --connect-timeout 5 --max-time 10 --noproxy '*' -X DELETE "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$did" "${hdrs[@]}" >/dev/null 2>&1
            v6_log "CF: 删除重复记录 $did"
        done
    fi

    rid=$(echo "$r_res" | jq -r '.result[0].id // empty')
    c_ip=$(echo "$r_res" | jq -r '.result[0].content // empty')
    c_ttl=$(echo "$r_res" | jq -r '.result[0].ttl // empty')

    # IP 与 TTL 都一致则跳过（current_ip 为 null 说明首次创建）
    if [[ -n "$c_ip" && "$c_ip" == "$ip" && "$c_ttl" == "$ttl" ]]; then
        return 0
    fi

    local method="POST"
    local url="https://api.cloudflare.com/client/v4/zones/$zid/dns_records"
    if [[ -n "$rid" ]]; then
        method="PATCH"
        url="$url/$rid"
    fi

    local res
    v6_curl_capture "$tmpfile" -X "$method" "$url" "${hdrs[@]}" -d "{\"type\":\"AAAA\",\"name\":\"$host\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":false}"
    res=$(cat "$tmpfile" 2>/dev/null); rm -f "$tmpfile"
    v6_check_json "$res" "$V6_CURL_RC" "$V6_HTTP_CODE" "CF($method)" || return 1

    [[ $(echo "$res" | jq -r '.success') == "true" ]] && return 0 || {
        v6_log "CF Error: $(echo "$res" | jq -r '.errors[0].message // .messages[0]')"
        return 1
    }
}

# DNSPOD: 修复响应非 JSON / 为空时无法诊断的问题；检查业务错误码返回真实原因。
v6_ddns_api_dnspod() {
    local ip="$1"
    local token="$2"
    local domain="$3"
    local host="$4"
    local ttl="$5"

    [[ ! "$ttl" =~ ^[0-9]+$ || "$ttl" -lt 1 || "$ttl" == "1" ]] && ttl=600

    local c="login_token=$token&format=json&domain=$domain&sub_domain=$host"
    local tmpfile="/tmp/.ddns_dnspod_resp.$$"
    local r_res rid c_ip c_ttl

    v6_curl_capture "$tmpfile" -X POST "https://dnsapi.cn/Record.List" -d "$c&record_type=AAAA"
    r_res=$(cat "$tmpfile" 2>/dev/null); rm -f "$tmpfile"
    v6_check_json "$r_res" "$V6_CURL_RC" "$V6_HTTP_CODE" "DNSPOD(List)" || return 1

    # 业务错误（token 无效 / 域名不存在等）直接返回真实原因，避免后续 jq 解析误判
    local code
    code=$(echo "$r_res" | jq -r '.status.code // empty')
    if [[ -n "$code" && "$code" != "1" ]]; then
        v6_log "DNSPOD Error: $(echo "$r_res" | jq -r '.status.message // "未知"') (code=$code)"
        return 1
    fi

    rid=$(echo "$r_res" | jq -r '.records[0].id // empty')
    c_ip=$(echo "$r_res" | jq -r '.records[0].value // empty')
    c_ttl=$(echo "$r_res" | jq -r '.records[0].ttl // empty')

    [[ "$c_ip" == "$ip" && "$c_ttl" == "$ttl" ]] && return 0

    local api="Record.Create"
    local ex="&record_line=默认"
    [[ -n "$rid" ]] && {
        api="Record.Modify"
        ex="$ex&record_id=$rid"
    }

    local res
    v6_curl_capture "$tmpfile" -X POST "https://dnsapi.cn/$api" -d "$c&record_type=AAAA&value=$ip&ttl=$ttl$ex"
    res=$(cat "$tmpfile" 2>/dev/null); rm -f "$tmpfile"
    v6_check_json "$res" "$V6_CURL_RC" "$V6_HTTP_CODE" "DNSPOD($api)" || return 1

    local rcode rmsg
    rcode=$(echo "$res" | jq -r '.status.code // empty')
    rmsg=$(echo "$res" | jq -r '.status.message // empty')
    if [[ "$rcode" == "1" ]]; then
        return 0
    else
        v6_log "DNSPOD Error: $rmsg (code=$rcode)"
        return 1
    fi
}

v6_percent_encode() {
    echo -n "$1" | od -An -tx1 | tr ' ' '%' | tr '[:lower:]' '[:upper:]'
}

v6_ddns_api_alidns() {
    local ip="$1"
    local id="$2"
    local secret="$3"
    local domain="$4"
    local rr="$5"
    local ttl="$6"

    [[ ! "$ttl" =~ ^[0-9]+$ || "$ttl" -lt 1 || "$ttl" == "1" ]] && ttl=600

    local ts
    local nonce
    local p
    local s
    local str
    local sig
    local r_res
    local tmpfile="/tmp/.ddns_alidns_resp.$$"

    ts=$(date -u "+%Y-%m-%dT%H%%3A%M%%3A%SZ")
    nonce=$(date +%s%N)
    p="AccessKeyId=$id&Action=DescribeDomainRecords&DomainName=$domain&Format=JSON&RRKeyWord=$rr&SignatureMethod=HMAC-SHA1&SignatureNonce=$nonce&SignatureVersion=1.0&Timestamp=$ts&Type=AAAA&Version=2015-01-01"
    s=$(echo -n "$p" | tr '&' '\n' | sort | tr '\n' '&' | sed 's/&$//')
    str="GET&%2F&$(v6_percent_encode "$s" | sed 's/%3D/=/g' | sed 's/%26/&/g')"
    sig=$(echo -n "$str" | openssl dgst -sha1 -hmac "$secret&" -binary | base64)

    v6_curl_capture "$tmpfile" "https://alidns.aliyuncs.com/?$p&Signature=$(v6_percent_encode "$sig")"
    r_res=$(cat "$tmpfile" 2>/dev/null); rm -f "$tmpfile"
    v6_check_json "$r_res" "$V6_CURL_RC" "$V6_HTTP_CODE" "AliDNS(Find)" || return 1

    [[ $(echo "$r_res" | jq -r '.Code') != "null" ]] && {
        v6_log "AliDNS Find Error: $(echo "$r_res" | jq -r '.Message')"
        return 1
    }

    local rid
    local c_ip
    local c_ttl

    rid=$(echo "$r_res" | jq -r '.DomainRecords.Record[0].RecordId // empty')
    c_ip=$(echo "$r_res" | jq -r '.DomainRecords.Record[0].Value // empty')
    c_ttl=$(echo "$r_res" | jq -r '.DomainRecords.Record[0].TTL // empty')

    [[ "$c_ip" == "$ip" && "$c_ttl" == "$ttl" ]] && return 0

    local act="AddDomainRecord"
    local ex=""
    [[ -n "$rid" ]] && {
        act="UpdateDomainRecord"
        ex="&RecordId=$rid"
    }

    nonce=$(date +%s%N)
    p="AccessKeyId=$id&Action=$act&DomainName=$domain$ex&Format=JSON&RR=$rr&SignatureMethod=HMAC-SHA1&SignatureNonce=$nonce&SignatureVersion=1.0&TTL=$ttl&Timestamp=$ts&Type=AAAA&Value=$ip&Version=2015-01-01"
    s=$(echo -n "$p" | tr '&' '\n' | sort | tr '\n' '&' | sed 's/&$//')
    str="GET&%2F&$(v6_percent_encode "$s" | sed 's/%3D/=/g' | sed 's/%26/&/g')"
    sig=$(echo -n "$str" | openssl dgst -sha1 -hmac "$secret&" -binary | base64)

    local res
    v6_curl_capture "$tmpfile" "https://alidns.aliyuncs.com/?$p&Signature=$(v6_percent_encode "$sig")"
    res=$(cat "$tmpfile" 2>/dev/null); rm -f "$tmpfile"
    v6_check_json "$res" "$V6_CURL_RC" "$V6_HTTP_CODE" "AliDNS($act)" || return 1

    [[ -n $(echo "$res" | jq -r '.RecordId // empty') ]] && return 0 || {
        v6_log "AliDNS Update Error: $(echo "$res" | jq -r '.Message')"
        return 1
    }
}

# --- DDNS worker (v8.9): 缓存跳过 + 定期强制远端校验 + 多 provider ---
v6_run_ddns_worker() {
    local LINE="$1"
    local IP="$2"
    local en_var="DDNS_${LINE}_ENABLE"
    [[ "${!en_var}" != "true" || -z "$IP" ]] && return

    local prov_var="DDNS_${LINE}_PROVIDER"
    local prov="${!prov_var}"
    local host_var="DDNS_${LINE}_HOST"
    local host="${!host_var}"
    local last_file="/tmp/ipv6_last_ddns_${LINE}.txt"
    local last_ip=""
    [[ -f "$last_file" ]] && last_ip=$(cat "$last_file" 2>/dev/null)

    # Bug 修复 #5: 本地 IP 未变时，对支持"查询远端"的 provider 定期强制校验一次，
    # 以修复 CF/远端被手动改动或外部工具改动导致的本地缓存与远端漂移。
    # webhook 无远端状态可比对，不参与强制校验。
    local VERIFY_INTERVAL=600   # 秒，默认 10 分钟
    local force_check=0
    if [[ "$prov" != "webhook" && -f "$last_file" ]]; then
        local mtime
        mtime=$(stat -c %Y "$last_file" 2>/dev/null || echo 0)
        [[ $(( $(date +%s) - mtime )) -gt "$VERIFY_INTERVAL" ]] && force_check=1
    fi

    if [[ "$IP" == "$last_ip" && "$force_check" -eq 0 ]]; then return; fi
    if [[ "$force_check" -eq 1 && "$IP" == "$last_ip" ]]; then
        v6_log "DDNS [$LINE]: 定期校验远端记录一致性..."
    else
        v6_log "DDNS [$LINE]: 触发更新检测 ($last_ip -> $IP)..."
    fi

    local res=1
    case "$prov" in
        "cloudflare")
            local t="DDNS_${LINE}_TOKEN"
            local d="DDNS_${LINE}_DOMAIN"
            local e="DDNS_${LINE}_EMAIL"
            local ttl="DDNS_${LINE}_TTL"
            v6_ddns_api_cf "$IP" "${!t}" "${!d}" "$host" "${!e}" "${!ttl}"
            res=$?
            ;;
        "dnspod")
            local t="DDNS_${LINE}_TOKEN"
            local d="DDNS_${LINE}_DOMAIN"
            local ttl="DDNS_${LINE}_TTL"
            v6_ddns_api_dnspod "$IP" "${!t}" "${!d}" "$host" "${!ttl}"
            res=$?
            ;;
        "alidns")
            local i="DDNS_${LINE}_ID"
            local s="DDNS_${LINE}_SECRET"
            local d="DDNS_${LINE}_DOMAIN"
            local ttl="DDNS_${LINE}_TTL"
            v6_ddns_api_alidns "$IP" "${!i}" "${!s}" "${!d}" "$host" "${!ttl}"
            res=$?
            ;;
        "webhook")
            local u="DDNS_${LINE}_WEBHOOK"
            v6_ddns_api_webhook "$IP" "${!u}"
            res=$?
            ;;
        *)
            v6_log "DDNS [$LINE]: 未配置 Provider"
            return 1
            ;;
    esac

    if [[ $res -eq 0 ]]; then
        echo "$IP" > "$last_file"
        v6_log "DDNS [$LINE]: 成功 -> $host"
    else
        v6_log "DDNS [$LINE]: 失败或未改变!"
    fi
}

v6_save_ip_change_info() {
    local isp="$1"
    local isp_name

    case "$isp" in
        CT|ct|电信)
            isp_name="电信"
            ;;
        CU|cu|联通)
            isp_name="联通"
            ;;
        "电信、联通"|"联通、电信")
            isp_name="电信、联通"
            ;;
        *)
            isp_name="${isp:-未知}"
            ;;
    esac

    echo "$(date '+%Y-%m-%d %H:%M:%S')" > "/tmp/ipv6_last_change_time.txt"
    echo "$isp_name" > "/tmp/ipv6_last_change_isp.txt"
}

v6_run_auto_task() {
    v6_log ">>> IPv6 自动任务启动 <<<"
    v6_load_config
    v6_clean_and_scan

    # --- IP 变动检测 / 记录 (d.sh) ---
    local current_ips="${BEST_TELECOM_IP}_${BEST_UNICOM_IP}"
    local saved_ips_file="/tmp/ipv6_saved_ips.txt"
    local saved_ips=""
    local saved_ct_ip=""
    local saved_cu_ip=""
    local changed_isp=""

    saved_ips=$(cat "$saved_ips_file" 2>/dev/null)

    if [[ "$saved_ips" == *_* ]]; then
        saved_ct_ip="${saved_ips%%_*}"
        saved_cu_ip="${saved_ips#*_}"
    fi

    if [[ "$current_ips" != "$saved_ips" && -n "${current_ips//_/}" ]]; then
        changed_isp=""

        if [[ -n "$BEST_TELECOM_IP" && "$BEST_TELECOM_IP" != "$saved_ct_ip" ]]; then
            changed_isp="电信"
        fi

        if [[ -n "$BEST_UNICOM_IP" && "$BEST_UNICOM_IP" != "$saved_cu_ip" ]]; then
            if [[ -n "$changed_isp" ]]; then
                changed_isp="${changed_isp}、联通"
            else
                changed_isp="联通"
            fi
        fi

        [[ -z "$changed_isp" ]] && changed_isp="未知"

        v6_save_ip_change_info "$changed_isp"
        echo "$current_ips" > "$saved_ips_file"

        v6_log "IPv6 地址变动: ${changed_isp} ${saved_ips:-无记录} -> ${current_ips}"
    fi

    # --- 默认出口选路 (Bug 修复 #2: 用 route get 判断当前出口) ---
    if [[ -n "$DEFAULT_OUTBOUND_ISP" ]]; then
        local target_ip=""
        local target_iface=""

        if [[ "$DEFAULT_OUTBOUND_ISP" == "电信" ]]; then
            target_ip="$BEST_TELECOM_IP"
            target_iface="$BEST_TELECOM_IFACE"
        elif [[ "$DEFAULT_OUTBOUND_ISP" == "联通" ]]; then
            target_ip="$BEST_UNICOM_IP"
            target_iface="$BEST_UNICOM_IFACE"
        fi

        if [[ -n "$target_ip" ]]; then
            local curr
            curr=$(v6_get_current_src)

            if [[ "$curr" != "$target_ip" ]]; then
                v6_log "路由更新: ${curr:-未设置} -> $target_ip ($target_iface)"
                v6_apply_route "$DEFAULT_OUTBOUND_ISP" "$target_ip" "$target_iface"
            else
                v6_log "路由保持: 当前已经是 $DEFAULT_OUTBOUND_ISP $target_ip"
            fi
        else
            v6_log "自动选路跳过: 没有找到 $DEFAULT_OUTBOUND_ISP 的可用 IPv6"
        fi
    fi

    v6_run_ddns_worker "CT" "$BEST_TELECOM_IP"
    v6_run_ddns_worker "CU" "$BEST_UNICOM_IP"

    # --- IPv6 策略路由 (v8.9: flush table + 重建 rule + 出口验证) ---
    if [[ "$POLICY_ROUTE_ENABLED" == "true" && -n "$POLICY_ROUTE_DEST_IP" ]]; then
        local p_ip=""
        local p_if=""
        local gw=""
        local cmd_out=""
        local rc=1

        if [[ "$POLICY_ROUTE_ISP" == "电信" ]]; then
            p_ip="$BEST_TELECOM_IP"
            p_if="$BEST_TELECOM_IFACE"
        elif [[ "$POLICY_ROUTE_ISP" == "联通" ]]; then
            p_ip="$BEST_UNICOM_IP"
            p_if="$BEST_UNICOM_IFACE"
        fi

        if [[ -n "$p_ip" && -n "$p_if" ]]; then
            gw=$(v6_get_default_gw_for_iface "$p_if")

            while ip -6 rule del to "$POLICY_ROUTE_DEST_IP" lookup 101 priority 1000 2>/dev/null; do :; done
            ip -6 route flush table 101 2>/dev/null || true
            ip -6 rule add to "$POLICY_ROUTE_DEST_IP" lookup 101 priority 1000 2>/dev/null

            if [[ -n "$gw" ]]; then
                cmd_out=$(ip -6 route replace default via "$gw" dev "$p_if" src "$p_ip" table 101 2>&1); rc=$?
            elif v6_has_default_route_for_iface "$p_if"; then
                cmd_out=$(ip -6 route replace default dev "$p_if" src "$p_ip" table 101 2>&1); rc=$?
            else
                v6_log "IPv6 策略路由失败: $p_if 没有 IPv6 default 路由"
                rc=1
            fi

            if [[ $rc -eq 0 ]]; then
                v6_log "IPv6 策略路由成功: $POLICY_ROUTE_DEST_IP -> $POLICY_ROUTE_ISP $p_ip ($p_if${gw:+ via $gw})"
            else
                v6_log "IPv6 策略路由失败: $cmd_out"
            fi
        else
            v6_log "IPv6 策略路由跳过: 没有找到 $POLICY_ROUTE_ISP 的可用 IPv6"
        fi
    fi

    v6_log ">>> 完成 <<<"
}

v6_configure_interfaces() {
    while true; do
        ui_header "IPv6 网络接口绑定"
        v6_show_status_bar

        local ifaces
        ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")

        ui_section "接口绑定"
        ui_item "1" "设置电信接口"
        ui_item "2" "设置联通接口"
        ui_item "0" "返回"

        read -rp "$(echo -e "${YELLOW}请选择:${NC} ")" c

        case $c in
            1 | 2)
                local target="CT"
                local tname="电信"
                [[ "$c" == "2" ]] && {
                    target="CU"
                    tname="联通"
                }

                echo
                echo -e "请选择 ${CYAN}${tname}${NC} 要绑定的网卡："
                select iface in "auto" $ifaces "取消"; do
                    [[ "$iface" == "取消" ]] && break
                    if [[ -n "$iface" ]]; then
                        v6_kv_save "IFACE_${target}" "$iface"
                        ui_success "已锁定为 $iface"
                        sleep 1
                        break
                    fi
                done
                ;;
            0)
                break
                ;;
            *)
                ui_warn "无效输入"
                sleep 1
                ;;
        esac
    done

    v6_load_config
}

# --- DDNS 配置 (改进: 已有参数保留, 回车即保留原值; 支持单项修改) ---

# 读取字段: 显示当前值, 直接回车保留原值; secret 类型显示掩码。
# 返回新值(或原值), 供调用方捕获。
v6_ask_field() {
    local prompt="$1"
    local cur="${2:-}"
    local secret="${3:-0}"
    local input=""

    if [[ $secret -eq 1 ]]; then
        if [[ -n "$cur" ]]; then
            read -rp "$prompt (当前: $(mask_secret "$cur"), 回车保留): " input
        else
            read -rsp "$prompt (未设置, 留空取消): " input
            echo >&2   # 换行提示输出到 stderr，避免污染 $(...) 捕获的返回值
        fi
    else
        read -rp "$prompt (当前: ${cur:-未设置}, 回车保留): " input
    fi

    # read 默认按 IFS 去首尾空白；返回输入值或保留原值
    echo "${input:-$cur}"
}

# 配置 / 重配一个 provider: 同 provider 预填当前值回车保留；切换 provider 清空重填。
v6_configure_ddns_provider() {
    local LINE="$1"
    local LINE_NAME="$2"
    local prov="$3"
    ui_header "配置 ${LINE_NAME} DDNS - ${prov}"

    # 判断是否从其他 provider 切换过来（各运营商字段语义不同，不能残留旧值）
    local cur_prov_var="DDNS_${LINE}_PROVIDER"
    local cur_prov="${!cur_prov_var}"

    # 读取已有配置作为默认值
    local cur_token="" cur_id="" cur_secret="" cur_domain="" cur_host="" cur_email="" cur_webhook=""
    local v
    v="DDNS_${LINE}_TOKEN";   cur_token="${!v}"
    v="DDNS_${LINE}_ID";      cur_id="${!v}"
    v="DDNS_${LINE}_SECRET";  cur_secret="${!v}"
    v="DDNS_${LINE}_DOMAIN";  cur_domain="${!v}"
    v="DDNS_${LINE}_HOST";    cur_host="${!v}"
    v="DDNS_${LINE}_EMAIL";   cur_email="${!v}"
    v="DDNS_${LINE}_WEBHOOK"; cur_webhook="${!v}"

    # 切换 provider：清空预填，避免残留上一个运营商的值（如 DNSPOD 的 TOKEN ≠ CF 的 TOKEN）
    if [[ -n "$cur_prov" && "$cur_prov" != "$prov" ]]; then
        ui_warn "检测到从 ${cur_prov} 切换为 ${prov}，两者参数不同，请重新填写。"
        cur_token=""; cur_id=""; cur_secret=""; cur_domain=""; cur_host=""; cur_email=""; cur_webhook=""
    fi

    echo
    echo -e "${GRAY}提示: 每项会显示当前值，直接回车表示保留原值。TTL 固定为自动。${NC}"
    echo

    local cancel=0
    local token id secret domain host email webhook
    token="$cur_token"; id="$cur_id"; secret="$cur_secret"
    domain="$cur_domain"; host="$cur_host"; email="$cur_email"
    webhook="$cur_webhook"

    case "$prov" in
        cloudflare)
            local auth_mode="token"
            [[ -n "$cur_email" ]] && auth_mode="global"
            echo "当前验证方式: $([[ "$auth_mode" == "global" ]] && echo "Global Key" || echo "API Token")"
            echo " 1. API Token"
            echo " 2. Global API Key"
            read -rp "选择 回车保持: " cf_type
            if [[ -n "$cf_type" ]]; then
                [[ "$cf_type" == "2" ]] && auth_mode="global" || auth_mode="token"
            fi

            local cur_auth="token"
            [[ -n "$cur_email" ]] && cur_auth="global"
            local switched=0
            [[ "$auth_mode" != "$cur_auth" ]] && switched=1

            if [[ "$auth_mode" == "global" ]]; then
                if [[ $switched -eq 1 ]]; then
                    email=$(v6_ask_field "账户邮箱" "")
                    [[ -z "$email" ]] && { ui_warn "邮箱不能为空，已取消。"; sleep 1; return 1; }
                    token=$(v6_ask_field "Global Key" "" 1)
                    [[ -z "$token" ]] && { ui_warn "Global Key 不能为空，已取消。"; sleep 1; return 1; }
                else
                    email=$(v6_ask_field "账户邮箱" "$cur_email")
                    [[ -z "$email" ]] && { ui_warn "邮箱不能为空，已取消。"; sleep 1; return 1; }
                    token=$(v6_ask_field "Global Key" "$cur_token" 1)
                fi
            else
                if [[ $switched -eq 1 ]]; then
                    token=$(v6_ask_field "API Token" "" 1)
                    [[ -z "$token" ]] && { ui_warn "API Token 不能为空，已取消。"; sleep 1; return 1; }
                    email=""
                else
                    token=$(v6_ask_field "API Token" "$cur_token" 1)
                    [[ -z "$token" && -z "$cur_token" ]] && { ui_warn "API Token 不能为空，已取消。"; sleep 1; return 1; }
                    email=""
                fi
            fi

            domain=$(v6_ask_field "Domain 如 example.com" "$cur_domain")
            host=$(v6_ask_field "Host 如 abc.example.com 或 abc 或 @" "$cur_host")
            if [[ -z "$domain" || -z "$host" ]]; then
                ui_warn "Domain / Host 不能为空，已取消。"; sleep 1; return 1
            fi

            v6_kv_save "DDNS_${LINE}_PROVIDER" "cloudflare"
            v6_kv_save "DDNS_${LINE}_TOKEN" "$token"
            v6_kv_save "DDNS_${LINE}_EMAIL" "$email"
            v6_kv_save "DDNS_${LINE}_DOMAIN" "$domain"
            v6_kv_save "DDNS_${LINE}_HOST" "$host"
            v6_kv_save "DDNS_${LINE}_TTL" "1"
            v6_kv_save "DDNS_${LINE}_ENABLE" "true"
            v6_kv_save "DDNS_${LINE}_ID" ""
            v6_kv_save "DDNS_${LINE}_SECRET" ""
            v6_kv_save "DDNS_${LINE}_WEBHOOK" ""
            ;;

        dnspod)
            token=$(v6_ask_field "ID,Token" "$cur_token" 1)
            if [[ -z "$token" && -z "$cur_token" ]]; then
                ui_warn "ID,Token 不能为空，已取消。"; sleep 1; return 1
            fi
            domain=$(v6_ask_field "Domain 如 example.com" "$cur_domain")
            host=$(v6_ask_field "Sub 如 www 或 @" "$cur_host")
            if [[ -z "$domain" || -z "$host" ]]; then
                ui_warn "Domain / Host 不能为空，已取消。"; sleep 1; return 1
            fi
            v6_kv_save "DDNS_${LINE}_PROVIDER" "dnspod"
            v6_kv_save "DDNS_${LINE}_TOKEN" "$token"
            v6_kv_save "DDNS_${LINE}_DOMAIN" "$domain"
            v6_kv_save "DDNS_${LINE}_HOST" "$host"
            v6_kv_save "DDNS_${LINE}_TTL" "1"
            v6_kv_save "DDNS_${LINE}_ENABLE" "true"
            v6_kv_save "DDNS_${LINE}_ID" ""
            v6_kv_save "DDNS_${LINE}_SECRET" ""
            v6_kv_save "DDNS_${LINE}_WEBHOOK" ""
            v6_kv_save "DDNS_${LINE}_EMAIL" ""
            ;;

        alidns)
            id=$(v6_ask_field "AccessKey ID" "$cur_id")
            secret=$(v6_ask_field "AccessKey Secret" "$cur_secret" 1)
            if [[ ( -z "$id" && -z "$cur_id" ) || ( -z "$secret" && -z "$cur_secret" ) ]]; then
                ui_warn "AccessKey ID / Secret 不能为空，已取消。"; sleep 1; return 1
            fi
            domain=$(v6_ask_field "Domain 如 example.com" "$cur_domain")
            host=$(v6_ask_field "RR 如 www 或 @" "$cur_host")
            if [[ -z "$domain" || -z "$host" ]]; then
                ui_warn "Domain / Host 不能为空，已取消。"; sleep 1; return 1
            fi
            v6_kv_save "DDNS_${LINE}_PROVIDER" "alidns"
            v6_kv_save "DDNS_${LINE}_ID" "$id"
            v6_kv_save "DDNS_${LINE}_SECRET" "$secret"
            v6_kv_save "DDNS_${LINE}_DOMAIN" "$domain"
            v6_kv_save "DDNS_${LINE}_HOST" "$host"
            v6_kv_save "DDNS_${LINE}_TTL" "1"
            v6_kv_save "DDNS_${LINE}_ENABLE" "true"
            v6_kv_save "DDNS_${LINE}_TOKEN" ""
            v6_kv_save "DDNS_${LINE}_WEBHOOK" ""
            v6_kv_save "DDNS_${LINE}_EMAIL" ""
            ;;

        webhook)
            webhook=$(v6_ask_field "Webhook URL 含{ip}占位" "$cur_webhook")
            if [[ -z "$webhook" && -z "$cur_webhook" ]]; then
                ui_warn "Webhook URL 不能为空，已取消。"; sleep 1; return 1
            fi
            v6_kv_save "DDNS_${LINE}_PROVIDER" "webhook"
            v6_kv_save "DDNS_${LINE}_WEBHOOK" "$webhook"
            v6_kv_save "DDNS_${LINE}_ENABLE" "true"
            v6_kv_save "DDNS_${LINE}_TOKEN" ""
            v6_kv_save "DDNS_${LINE}_DOMAIN" ""
            v6_kv_save "DDNS_${LINE}_HOST" ""
            v6_kv_save "DDNS_${LINE}_EMAIL" ""
            v6_kv_save "DDNS_${LINE}_ID" ""
            v6_kv_save "DDNS_${LINE}_SECRET" ""
            v6_kv_save "DDNS_${LINE}_TTL" "1"
            ;;
    esac

    rm -f "/tmp/ipv6_last_ddns_${LINE}.txt"
    v6_load_config
    ui_success "${prov} DDNS 已保存（可随时选 5 修改单项）"
    sleep 1
}

# 单项修改: 只改选中的项, 其他参数全部保留。
v6_configure_ddns_edit() {
    local LINE="$1"
    local LINE_NAME="$2"
    v6_load_config
    local p_prov_var="DDNS_${LINE}_PROVIDER"
    local prov="${!p_prov_var}"
    if [[ -z "$prov" ]]; then
        ui_warn "尚未配置服务商，请先选 1-4 配置。"
        sleep 1
        return
    fi

    while true; do
        v6_load_config
        ui_header "修改 ${LINE_NAME} DDNS 参数 (${prov})"

        case "$prov" in
            cloudflare)
                local v_t="DDNS_${LINE}_TOKEN" v_e="DDNS_${LINE}_EMAIL" v_d="DDNS_${LINE}_DOMAIN" v_h="DDNS_${LINE}_HOST"
                ui_kv "验证方式" "$([[ -n "${!v_e}" ]] && echo -e "${GREEN}Global Key${NC}" || echo -e "${GREEN}API Token${NC}")"
                ui_kv "Token / Key" "${GRAY}$(mask_secret "${!v_t}")${NC}"
                ui_kv "Domain" "${YELLOW}${!v_d}${NC}"
                ui_kv "Host" "${YELLOW}${!v_h}${NC}"
                ui_section "选择要修改的项"
                ui_item "1" "Token / Key"
                ui_item "2" "Domain 主域名"
                ui_item "3" "Host 记录名"
                ui_item "0" "返回"
                read -rp "$(echo -e "${YELLOW}选择:${NC} ")" m
                case $m in
                    1) read -rsp "新的 Token / Key (留空取消): " nv; echo; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_TOKEN" "$nv"; ui_success "已更新 Token / Key" ;;
                    2) read -rp "新的 Domain (留空取消): " nv; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_DOMAIN" "$nv"; ui_success "已更新 Domain" ;;
                    3) read -rp "新的 Host (留空取消): " nv; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_HOST" "$nv"; ui_success "已更新 Host" ;;
                    0) break ;;
                    *) ui_warn "无效输入"; sleep 1 ;;
                esac
                ;;
            dnspod)
                local v_t="DDNS_${LINE}_TOKEN" v_d="DDNS_${LINE}_DOMAIN" v_h="DDNS_${LINE}_HOST"
                ui_kv "ID,Token" "${GRAY}$(mask_secret "${!v_t}")${NC}"
                ui_kv "Domain" "${YELLOW}${!v_d}${NC}"
                ui_kv "Sub" "${YELLOW}${!v_h}${NC}"
                ui_section "选择要修改的项"
                ui_item "1" "ID,Token"
                ui_item "2" "Domain 主域名"
                ui_item "3" "Sub 记录名"
                ui_item "0" "返回"
                read -rp "$(echo -e "${YELLOW}选择:${NC} ")" m
                case $m in
                    1) read -rsp "新的 ID,Token (留空取消): " nv; echo; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_TOKEN" "$nv"; ui_success "已更新 ID,Token" ;;
                    2) read -rp "新的 Domain (留空取消): " nv; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_DOMAIN" "$nv"; ui_success "已更新 Domain" ;;
                    3) read -rp "新的 Sub (留空取消): " nv; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_HOST" "$nv"; ui_success "已更新 Sub" ;;
                    0) break ;;
                    *) ui_warn "无效输入"; sleep 1 ;;
                esac
                ;;
            alidns)
                local v_i="DDNS_${LINE}_ID" v_s="DDNS_${LINE}_SECRET" v_d="DDNS_${LINE}_DOMAIN" v_h="DDNS_${LINE}_HOST"
                ui_kv "AccessKey ID" "${GRAY}${!v_i}${NC}"
                ui_kv "Secret" "${GRAY}$(mask_secret "${!v_s}")${NC}"
                ui_kv "Domain" "${YELLOW}${!v_d}${NC}"
                ui_kv "RR" "${YELLOW}${!v_h}${NC}"
                ui_section "选择要修改的项"
                ui_item "1" "AccessKey ID"
                ui_item "2" "AccessKey Secret"
                ui_item "3" "Domain 主域名"
                ui_item "4" "RR 记录名"
                ui_item "0" "返回"
                read -rp "$(echo -e "${YELLOW}选择:${NC} ")" m
                case $m in
                    1) read -rp "新的 AccessKey ID (留空取消): " nv; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_ID" "$nv"; ui_success "已更新 AccessKey ID" ;;
                    2) read -rsp "新的 Secret (留空取消): " nv; echo; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_SECRET" "$nv"; ui_success "已更新 Secret" ;;
                    3) read -rp "新的 Domain (留空取消): " nv; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_DOMAIN" "$nv"; ui_success "已更新 Domain" ;;
                    4) read -rp "新的 RR (留空取消): " nv; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_HOST" "$nv"; ui_success "已更新 RR" ;;
                    0) break ;;
                    *) ui_warn "无效输入"; sleep 1 ;;
                esac
                ;;
            webhook)
                local v_w="DDNS_${LINE}_WEBHOOK"
                ui_kv "Webhook URL" "${YELLOW}${!v_w}${NC}"
                ui_section "选择要修改的项"
                ui_item "1" "Webhook URL"
                ui_item "0" "返回"
                read -rp "$(echo -e "${YELLOW}选择:${NC} ")" m
                case $m in
                    1) read -rp "新的 Webhook URL (留空取消): " nv; [[ -z "$nv" ]] && continue; v6_kv_save "DDNS_${LINE}_WEBHOOK" "$nv"; ui_success "已更新 Webhook URL" ;;
                    0) break ;;
                    *) ui_warn "无效输入"; sleep 1 ;;
                esac
                ;;
            *)
                break
                ;;
        esac

        # 修改后清理缓存，改动随下次自动任务（或菜单 5 立即运行）同步到远端
        rm -f "/tmp/ipv6_last_ddns_${LINE}.txt"
        v6_load_config
        ui_pause
    done
}

# --- DDNS 配置主入口 ---
v6_configure_ddns_entry() {
    local LINE="$1"
    local LINE_NAME="$2"

    while true; do
        v6_load_config
        ui_header "配置 ${LINE_NAME} IPv6 DDNS"
        local curr_prov="DDNS_${LINE}_PROVIDER"
        local curr_host="DDNS_${LINE}_HOST"
        local curr_enable="DDNS_${LINE}_ENABLE"

        ui_kv "当前状态" "$([[ "${!curr_enable}" == "true" ]] && echo -e "${GREEN}开启${NC}" || echo -e "${RED}关闭${NC}")"
        ui_kv "服务商" "${CYAN}${!curr_prov:-未配置}${NC}"
        ui_kv "记录名" "${YELLOW}${!curr_host:-未配置}${NC}"
        ui_kv "TTL" "${BLUE}自动${NC}"

        ui_section "DDNS 服务商"
        ui_item "1" "Cloudflare" "配置 / 重配，回车保留原值"
        ui_item "2" "DNSPOD (腾讯云)" "配置 / 重配，回车保留原值"
        ui_item "3" "AliDNS (阿里云)" "配置 / 重配，回车保留原值"
        ui_item "4" "Webhook" "配置 / 重配，回车保留原值"
        ui_item "5" "修改现有参数" "只改单一项，其他保留"
        ui_item "6" "禁用 / 清除"
        ui_item "0" "返回"

        read -rp "$(echo -e "${YELLOW}请选择:${NC} ")" c

        case $c in
            1)
                v6_configure_ddns_provider "$LINE" "$LINE_NAME" "cloudflare"
                ;;
            2)
                v6_configure_ddns_provider "$LINE" "$LINE_NAME" "dnspod"
                ;;
            3)
                v6_configure_ddns_provider "$LINE" "$LINE_NAME" "alidns"
                ;;
            4)
                v6_configure_ddns_provider "$LINE" "$LINE_NAME" "webhook"
                ;;
            5)
                v6_configure_ddns_edit "$LINE" "$LINE_NAME"
                ;;
            6)
                v6_kv_save "DDNS_${LINE}_ENABLE" "false"
                v6_kv_save "DDNS_${LINE}_PROVIDER" ""
                v6_kv_save "DDNS_${LINE}_TOKEN" ""
                v6_kv_save "DDNS_${LINE}_DOMAIN" ""
                v6_kv_save "DDNS_${LINE}_HOST" ""
                v6_kv_save "DDNS_${LINE}_TTL" ""
                v6_kv_save "DDNS_${LINE}_ID" ""
                v6_kv_save "DDNS_${LINE}_SECRET" ""
                v6_kv_save "DDNS_${LINE}_WEBHOOK" ""
                v6_kv_save "DDNS_${LINE}_EMAIL" ""
                rm -f "/tmp/ipv6_last_ddns_${LINE}.txt"
                ui_success "已禁用并清除 ${LINE_NAME} DDNS"
                sleep 1
                ;;
            0)
                break
                ;;
            *)
                ui_warn "无效输入"
                sleep 1
                ;;
        esac
    done

    v6_load_config
}

v6_configure_policy_route() {
    while true; do
        ui_header "IPv6 策略路由"
        ui_info "正在扫描可用源 IP..."
        v6_clean_and_scan

        ui_header "IPv6 策略路由"
        v6_show_status_bar

        local p_status="${RED}已禁用${NC}"
        [[ "$POLICY_ROUTE_ENABLED" == "true" ]] && p_status="${GREEN}已启用${NC}"

        ui_kv "策略状态" "$p_status"
        [[ "$POLICY_ROUTE_ENABLED" == "true" ]] && {
            ui_kv "目标 IP" "${CYAN}${POLICY_ROUTE_DEST_IP}${NC}"
            ui_kv "指定出口" "${CYAN}${POLICY_ROUTE_ISP}${NC}"
        }

        ui_section "策略路由菜单"
        ui_item "1" "设置 / 修改策略路由"
        ui_item "2" "禁用 / 清除策略路由"
        ui_item "0" "返回"

        read -rp "$(echo -e "${YELLOW}请选择:${NC} ")" c

        case $c in
            1)
                read -rp "目标网段 如 2400:3200::1 留空取消: " d
                [[ -z "$d" ]] && continue

                echo "请选择指定出口线路:"
                select i in "电信" "联通" "取消"; do
                    [[ "$i" == "取消" ]] && break
                    if [[ -n "$i" ]]; then
                        v6_kv_save "POLICY_ROUTE_ENABLED" "true"
                        v6_kv_save "POLICY_ROUTE_DEST_IP" "$d"
                        v6_kv_save "POLICY_ROUTE_ISP" "$i"
                        ui_success "策略已保存"
                        sleep 1
                        break
                    fi
                done
                ;;
            2)
                v6_kv_save "POLICY_ROUTE_ENABLED" "false"
                v6_kv_save "POLICY_ROUTE_DEST_IP" ""
                v6_kv_save "POLICY_ROUTE_ISP" ""
                # 删净所有旧 rule（多次配置可能残留多条），再清空路由表
                while ip -6 rule del lookup 101 priority 1000 2>/dev/null; do :; done
                ip -6 route flush table 101 2>/dev/null || true
                ui_success "已清除"
                sleep 1
                ;;
            0)
                break
                ;;
            *)
                ui_warn "无效输入"
                sleep 1
                ;;
        esac

        v6_load_config
    done
}

v6_main_menu() {
    while true; do
        ui_header "IPv6 智能管家"
        v6_show_status_bar

        ui_section "功能菜单"
        ui_item "1" "自动选路" "设置默认 IPv6 出口"
        ui_item "2" "DDNS 配置" "CF / DNSPOD / AliDNS / Webhook"
        ui_item "3" "网络接口绑定" "锁定电信 / 联通接口"
        ui_item "4" "策略路由配置" "指定 IPv6 目标走指定线路"
        ui_item "5" "立即运行" "手动执行一次自动任务"
        ui_item "6" "查看运行日志" "最近 20 条日志"
        ui_item "7" "IP 选择策略" "延迟最佳 / 最新下发"
        ui_item "0" "返回主菜单"

        ui_line "─"

        read -rp "$(echo -e "${YELLOW}请输入选项:${NC} ")" choice

        case $choice in
            1)
                echo
                echo "优先出口:"
                select isp in "电信" "联通" "禁用" "取消"; do
                    [[ "$isp" == "取消" ]] && break
                    if [[ -n "$isp" ]]; then
                        [[ "$isp" == "禁用" ]] && isp=""
                        v6_kv_save "DEFAULT_OUTBOUND_ISP" "$isp"
                        ui_success "已保存，正在应用..."

                        # 自动任务里如果包含 DDNS，可能需要 jq
                        v6_ensure_jq >/dev/null 2>&1

                        v6_run_auto_task >/dev/null 2>&1
                        sleep 1
                        break
                    fi
                done
                ;;

            2)
                v6_ensure_jq || {
                    ui_warn "jq 未安装，无法进入 DDNS 配置"
                    ui_pause
                    continue
                }

                while true; do
                    ui_header "IPv6 DDNS 配置"
                    v6_show_status_bar

                    ui_section "DDNS 菜单"
                    ui_item "1" "电信 DDNS"
                    ui_item "2" "联通 DDNS"
                    ui_item "3" "查看 DDNS 日志"
                    ui_item "0" "返回"

                    read -rp "$(echo -e "${YELLOW}请选择:${NC} ")" c

                    case $c in
                        1)
                            v6_configure_ddns_entry "CT" "电信"
                            ;;
                        2)
                            v6_configure_ddns_entry "CU" "联通"
                            ;;
                        3)
                            if [[ -f "$V6_LOG_FILE" ]]; then
                                tail -n 10 "$V6_LOG_FILE"
                            else
                                ui_warn "暂无日志"
                            fi
                            ui_pause
                            ;;
                        0)
                            break
                            ;;
                        *)
                            ui_warn "无效输入"
                            sleep 1
                            ;;
                    esac
                done
                ;;

            3)
                v6_configure_interfaces
                ;;

            4)
                v6_configure_policy_route
                ;;

            5)
                v6_ensure_jq || {
                    ui_warn "jq 未安装，无法执行 DDNS 相关任务"
                    ui_pause
                    continue
                }

                v6_run_auto_task
                ui_pause
                ;;

            6)
                if [[ -f "$V6_LOG_FILE" ]]; then
                    tail -n 20 "$V6_LOG_FILE"
                else
                    ui_warn "暂无日志"
                fi
                ui_pause
                ;;

            7)
                echo
                echo "IP 获取策略:"
                select m in "延迟最佳" "最新下发" "取消"; do
                    [[ "$m" == "取消" ]] && break
                    if [[ -n "$m" ]]; then
                        if [[ "$m" == "最新下发" ]]; then
                            v6_kv_save "IP_SELECT_MODE" "latest"
                        else
                            v6_kv_save "IP_SELECT_MODE" "latency"
                        fi
                        ui_success "已保存"
                        sleep 1
                        break
                    fi
                done
                ;;

            0)
                break
                ;;

            *)
                ui_warn "无效输入"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 模块 B: IPv4 PBR 自动化策略路由 (dual-route-v4.5 完整版: 端口分流 + NAT)
# ==============================================================================
V4_CONFIG_FILE="/etc/custom_policy_routes.conf"
V4_DDNS_CONFIG_FILE="/etc/custom_policy_ddns.conf"
V4_RT_TABLES_FILE="/etc/iproute2/rt_tables"
touch "$V4_CONFIG_FILE" "$V4_DDNS_CONFIG_FILE"

V4_RAW_DEFINITIONS="
9929 10.7.0.1 ^10\.7\.
CN2 10.8.0.1 ^10\.8\.
JPSDWAN 10.3.0.1 ^10\.3\.[0-3]\.
DESDWAN 10.3.10.1 ^10\.3\.(8|9|10|11)\.
KRSDWAN 10.4.0.1 ^10\.4\.[0-3]\.
HKSDWAN 10.3.50.1 ^10\.3\.(48|49|50|51)\.
TWSDWAN 10.3.100.1 ^10\.3\.(100|101|102|103)\.
USSDWAN-SEATTLE 10.3.160.1 ^10\.3\.(160|161)\.
MOSCOW 10.3.170.1 ^10\.3\.(170|171)\.
SINGAPORE 10.3.180.1 ^10\.3\.180\.
USSDWAN-LAX 10.3.150.1 ^10\.3\.(150|151)\.
"

V4_PRIO_STATIC=15000
V4_PRIO_FWMARK=14999
V4_PRIO_DDNS=15005

declare -a V4_FOUND_NAMES V4_FOUND_GWS V4_FOUND_IDS
V4_SELECTED_IDX=0

v4_fix_multigateway_conflict() {
    local verbose=true
    [[ "${1:-}" == "quiet" ]] && verbose=false

    local current_defaults
    current_defaults=$(ip route show default)
    [[ $(echo "$current_defaults" | wc -l) -le 1 ]] && return 0

    echo "$V4_RAW_DEFINITIONS" | while read -r name gw pattern; do
        [[ -z "$name" ]] && continue
        if echo "$current_defaults" | grep -q "via $gw"; then
            if [[ $(ip route show default | grep -v "via $gw" | wc -l) -ge 1 ]]; then
                $verbose && ui_warn "路由冲突修复，剔除冲突网关: $gw ($name)"
                ip route del default via "$gw" 2>/dev/null || true
            fi
        fi
    done
}

v4_detect_available_routes() {
    local mode="${1:-}"
    [[ "$mode" != "silent" && "$mode" != "quiet" ]] && ui_info "正在检测本机可用线路组..."

    v4_fix_multigateway_conflict "quiet"

    V4_FOUND_NAMES=()
    V4_FOUND_GWS=()
    V4_FOUND_IDS=()

    local table_base_id=101
    local added_count=0
    local all_ips
    all_ips=$(ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1)

    while read -r def_name def_gw def_pattern; do
        [[ -z "$def_name" || "$def_name" =~ ^# ]] && continue

        local matched=0
        for ip in $all_ips; do
            [[ "$ip" =~ $def_pattern ]] && {
                matched=1
                break
            }
        done

        if [[ $matched -eq 1 ]]; then
            V4_FOUND_NAMES+=("$def_name")
            V4_FOUND_GWS+=("$def_gw")

            local current_id=$((table_base_id + added_count))
            V4_FOUND_IDS+=("$current_id")

            grep -qE "^[0-9]+[[:space:]]+T_${def_name}([[:space:]]|$)" "$V4_RT_TABLES_FILE" || echo "$current_id T_${def_name}" >> "$V4_RT_TABLES_FILE"
            ((added_count++))
        fi
    done <<< "$V4_RAW_DEFINITIONS"

    if [[ ${#V4_FOUND_NAMES[@]} -eq 0 ]]; then
        [[ "$mode" != "silent" && "$mode" != "quiet" ]] && ui_error "未检测到任何匹配的线路组。"
        return 1
    else
        if [[ "$mode" != "silent" && "$mode" != "quiet" ]]; then
            ui_success "检测完成，可用线路如下："
            printf "%-4s %-14s %-15s\n" "No." "线路名称" "网关"
            echo "--------------------------------"
            for ((i = 0; i < ${#V4_FOUND_NAMES[@]}; i++)); do
                printf "%-4d %-14s %-15s\n" "$((i + 1))" "${V4_FOUND_NAMES[$i]}" "${V4_FOUND_GWS[$i]}"
            done
            echo
        fi
        return 0
    fi
}

# 初始化自定义策略路由表：link 子网 + default 入表
v4_init_routing_tables() {
    for ((i = 0; i < ${#V4_FOUND_NAMES[@]}; i++)); do
        local table_id="${V4_FOUND_IDS[$i]}"
        local gateway="${V4_FOUND_GWS[$i]}"

        local route_info
        local dev
        local src
        route_info=$(ip route get "$gateway" 2>/dev/null | head -n 1)
        dev=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
        src=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

        if [[ -n "$dev" && -n "$src" ]]; then
            local subnet
            subnet=$(ip route show dev "$dev" scope link 2>/dev/null | awk '{print $1}' | head -n 1)
            if [ -n "$subnet" ]; then
                ip route replace "$subnet" dev "$dev" scope link src "$src" table "$table_id" 2>/dev/null
            fi
            ip route replace default via "$gateway" dev "$dev" src "$src" table "$table_id" 2>/dev/null
        else
            ip route replace default via "$gateway" table "$table_id" 2>/dev/null
        fi
    done
}

v4_select_route_group() {
    v4_detect_available_routes "silent" || return 1

    local count=${#V4_FOUND_NAMES[@]}
    [[ "$count" -eq 0 ]] && return 1

    echo "------------------------------"
    printf "%-4s %-14s %-15s\n" "No." "线路名称" "网关IP"
    echo "------------------------------"

    for ((i = 0; i < count; i++)); do
        printf "%-4d %-14s %-15s\n" "$((i + 1))" "${V4_FOUND_NAMES[$i]}" "${V4_FOUND_GWS[$i]}"
    done

    local choice
    read -rp "请输入数字选择线路 留空取消: " choice
    [[ -z "$choice" ]] && return 255

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        ui_warn "无效选项。"
        return 1
    fi

    V4_SELECTED_IDX=$((choice - 1))
    return 0
}

# 添加静态规则：批量 CIDR (d.sh) + 协议/端口分流 (dual-route)
v4_add_rule() {
    v4_select_route_group
    local ret=$?

    [[ $ret -eq 255 ]] && {
        ui_info "已取消"
        return 1
    }

    [[ $ret -ne 0 ]] && return 1

    local idx=$V4_SELECTED_IDX
    local selected_name="${V4_FOUND_NAMES[$idx]}"
    local gateway="${V4_FOUND_GWS[$idx]}"
    local table_id="${V4_FOUND_IDS[$idx]}"

    echo
    read -rp "请输入目标 IP/CIDR 可多个用逗号分隔 留空取消: " input_cidrs
    [[ -z "$input_cidrs" ]] && {
        ui_info "已取消"
        return 1
    }

    IFS=',' read -r -a cidr_items <<< "$(echo "$input_cidrs" | tr -d '[:space:]')"

    local proto="all"
    local port="all"

    read -rp "协议 (tcp/udp/all, 默认all): " proto
    proto=${proto:-all}
    if [[ "$proto" != "tcp" && "$proto" != "udp" && "$proto" != "all" ]]; then
        ui_warn "协议只能是 tcp, udp 或 all。"
        return 1
    fi

    if [[ "$proto" != "all" ]]; then
        read -rp "目标端口 (例如 443, 留空所有端口): " port
        port=${port:-all}
        if [[ "$port" != "all" && ! "$port" =~ ^[0-9]+$ ]]; then
            ui_warn "端口必须是数字。"
            return 1
        fi
    fi

    local success=0
    local skipped=0

    ip route replace default via "$gateway" table "$table_id" 2>/dev/null

    for cidr in "${cidr_items[@]}"; do
        [[ -z "$cidr" ]] && {
            ((skipped++))
            continue
        }

        [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && cidr="${cidr}/32"

        if ! [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            ui_warn "跳过无效 CIDR: $cidr"
            ((skipped++))
            continue
        fi

        local dup_line="${cidr} ${proto} ${port} ${selected_name}"
        if grep -qE "^${cidr}[[:space:]]+${proto}[[:space:]]+${port}[[:space:]]+${selected_name}$" "$V4_CONFIG_FILE"; then
            ui_warn "跳过已存在规则: $cidr"
            ((skipped++))
            continue
        fi

        echo "$dup_line" >> "$V4_CONFIG_FILE"
        ((success++))
    done

    ui_success "处理完成：成功 $success 条，跳过 $skipped 条。"
    v4_apply_saved_rules >/dev/null 2>&1
}

v4_add_ddns_rule() {
    ui_header "添加 DDNS 域名分流规则"

    v4_select_route_group
    local ret=$?

    [[ $ret -eq 255 ]] && {
        ui_info "已取消"
        return 1
    }

    [[ $ret -ne 0 ]] && return 1

    local selected_name="${V4_FOUND_NAMES[$V4_SELECTED_IDX]}"

    echo
    read -rp "请输入域名 A记录 可多个用逗号分隔 留空取消: " input_domains
    [[ -z "$input_domains" ]] && return 1

    IFS=',' read -r -a domain_items <<< "$(echo "$input_domains" | tr -d '[:space:]')"

    local success=0
    local skipped=0

    for domain in "${domain_items[@]}"; do
        [[ -z "$domain" ]] && continue

        if ! getent hosts "$domain" >/dev/null; then
            ui_warn "当前无法解析域名 '$domain'。"
            read -rp "是否继续强制添加? y/n: " confirm
            [[ "$confirm" != "y" ]] && {
                ((skipped++))
                continue
            }
        fi

        if grep -qE "^${domain}[[:space:]]+${selected_name}$" "$V4_DDNS_CONFIG_FILE"; then
            ui_warn "跳过已存在规则: $domain"
            ((skipped++))
            continue
        fi

        echo "$domain $selected_name" >> "$V4_DDNS_CONFIG_FILE"
        ((success++))
    done

    [[ "$success" -gt 0 ]] && {
        ui_info "规则已保存，正在执行一次刷新..."
        v4_refresh_ddns_rules
    }

    ui_success "处理完成：成功 $success 条，跳过 $skipped 条。"

    # cron 统一用 bash + 引号包裹脚本路径，路径含空格也能运行
    local cron_cmd="v4_ddns"
    if ! crontab -l 2>/dev/null | grep -q "$cron_cmd"; then
        read -rp "检测到未配置自动更新，是否立即添加 每5分钟? y/n: " ask_cron
        [[ "$ask_cron" == "y" ]] && {
            (crontab -l 2>/dev/null; echo ""; echo "*/5 * * * * bash \"${SCRIPT_PATH}\" v4_ddns >/dev/null 2>&1") | crontab -
            ui_success "已添加自动更新。"
        }
    fi
}

v4_delete_rule() {
    echo "1) 删除静态 IP/端口 规则"
    echo "2) 删除 DDNS 域名规则"
    read -rp "请选择: " dtype

    local target_file=""
    [[ "$dtype" == "1" ]] && target_file="$V4_CONFIG_FILE"
    [[ "$dtype" == "2" ]] && target_file="$V4_DDNS_CONFIG_FILE"

    [[ -z "$target_file" || ! -s "$target_file" ]] && {
        ui_warn "配置为空或无效。"
        return
    }

    awk '{print NR") "$0}' "$target_file"
    read -rp "输入要删除的编号 多选逗号分隔 留空取消: " input_nums
    [[ -z "$input_nums" ]] && return

    local total_lines
    total_lines=$(wc -l < "$target_file")
    IFS=',' read -r -a nums <<< "$(echo "$input_nums" | tr -d '[:space:]')"

    local -a valid_nums=()
    declare -A seen=()

    for n in "${nums[@]}"; do
        if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "$total_lines" && -z "${seen[$n]+x}" ]]; then
            valid_nums+=("$n")
            seen[$n]=1
        fi
    done

    mapfile -t sorted_nums < <(printf "%s\n" "${valid_nums[@]}" | sort -rn)

    for line_num in "${sorted_nums[@]}"; do
        if [[ "$dtype" == "1" ]]; then
            local cidr_del proto_del
            cidr_del=$(awk "NR==$line_num {print \$1}" "$target_file")
            proto_del=$(awk "NR==$line_num {print \$2}" "$target_file")
            # 只有纯 CIDR 规则（2列 或 proto=all）才单独删 rule；端口规则由全量重建清除
            if [[ -z "$proto_del" || "$proto_del" == "all" ]]; then
                ip rule del to "$cidr_del" priority "$V4_PRIO_STATIC" 2>/dev/null || true
            fi
        fi
        sed -i "${line_num}d" "$target_file"
    done

    if [[ "$dtype" == "1" ]]; then
        v4_apply_saved_rules >/dev/null 2>&1
    else
        v4_refresh_ddns_rules "quiet"
    fi

    ui_success "已成功删除编号: $(IFS=,; echo "${sorted_nums[*]}")"
}

v4_modify_rule() {
    echo "1) 修改静态 IP/端口 规则"
    echo "2) 修改 DDNS 域名规则"
    read -rp "请选择: " mtype
    [[ -z "$mtype" ]] && return

    local file=""
    [[ "$mtype" == "1" ]] && file="$V4_CONFIG_FILE" || file="$V4_DDNS_CONFIG_FILE"

    [[ ! -s "$file" ]] && {
        ui_warn "规则为空。"
        return 1
    }

    awk '{print NR") "$0}' "$file"
    read -rp "输入要修改的编号: " line_num
    [[ ! "$line_num" =~ ^[0-9]+$ ]] && return 1

    local old_val
    local old_name
    local old_proto
    local old_port
    old_val=$(awk "NR==$line_num {print \$1}" "$file")
    old_name=$(awk "NR==$line_num {print \$(NF)}" "$file")
    old_proto=$(awk "NR==$line_num {print \$2}" "$file")
    old_port=$(awk "NR==$line_num {print \$3}" "$file")
    [[ -z "$old_proto" ]] && old_proto="all"
    [[ -z "$old_port" ]] && old_port="all"

    local prompt="请输入新的目标IP/CIDR"
    [[ "$mtype" == "2" ]] && prompt="请输入新的域名 A记录"

    read -rp "$prompt 回车保持 ${old_val}: " new_val
    [[ -z "$new_val" ]] && new_val="$old_val"

    if [[ "$mtype" == "1" ]]; then
        if [[ "$new_val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            new_val="${new_val}/32"
        fi
        if ! [[ "$new_val" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            ui_warn "CIDR 格式不正确"
            return 1
        fi
    fi

    local new_name="$old_name"

    if [[ "$mtype" == "1" ]]; then
        v4_detect_available_routes silent || return 1

        echo "可用线路组 当前: ${old_name}:"
        for ((i = 0; i < ${#V4_FOUND_NAMES[@]}; i++)); do
            printf "%d) %s\n" "$((i + 1))" "${V4_FOUND_NAMES[$i]}"
        done

        read -rp "请输入新的线路组编号 回车保持 ${old_name}: " route_choice
        [[ -n "$route_choice" && "$route_choice" =~ ^[0-9]+$ && "$route_choice" -le "${#V4_FOUND_NAMES[@]}" ]] && new_name="${V4_FOUND_NAMES[$((route_choice - 1))]}"

        read -rp "协议 (tcp/udp/all, 回车保持 ${old_proto}): " new_proto
        new_proto=${new_proto:-$old_proto}
        if [[ "$new_proto" != "tcp" && "$new_proto" != "udp" && "$new_proto" != "all" ]]; then
            ui_warn "协议无效"
            return 1
        fi

        read -rp "目标端口 (回车保持 ${old_port}): " new_port
        new_port=${new_port:-$old_port}
        if [[ "$new_port" != "all" && ! "$new_port" =~ ^[0-9]+$ ]]; then
            ui_warn "端口无效"
            return 1
        fi

        local new_line="${new_val} ${new_proto} ${new_port} ${new_name}"
    else
        local new_line="${new_val} ${new_name}"
    fi

    # 重复检查
    if awk -v n="$line_num" -v l="$new_line" 'NR!=n && $0==l{found=1} END{exit !found}' "$file"; then
        ui_warn "规则已存在。"
        return 1
    fi

    sed -i "${line_num}c${new_line}" "$file"

    if [[ "$mtype" == "1" ]]; then
        v4_apply_saved_rules >/dev/null 2>&1
    else
        v4_refresh_ddns_rules "quiet"
    fi

    ui_success "修改成功。"
}

v4_refresh_ddns_rules() {
    while ip rule del priority "$V4_PRIO_DDNS" 2>/dev/null; do :; done

    [[ ! -s "$V4_DDNS_CONFIG_FILE" ]] && return 0

    v4_detect_available_routes "quiet" || return 0
    v4_init_routing_tables

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local domain
        local group
        domain=$(echo "$line" | awk '{print $1}')
        group=$(echo "$line" | awk '{print $2}')

        local found_idx=-1

        for ((i = 0; i < ${#V4_FOUND_NAMES[@]}; i++)); do
            [[ "${V4_FOUND_NAMES[$i]}" == "$group" ]] && {
                found_idx=$i
                break
            }
        done

        if [[ "$found_idx" -ge 0 ]]; then
            local gateway="${V4_FOUND_GWS[$found_idx]}"
            local table_id="${V4_FOUND_IDS[$found_idx]}"

            ip route replace default via "$gateway" table "$table_id" 2>/dev/null

            local ips
            ips=$(getent hosts "$domain" | awk '{ print $1 }' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)

            for ip_addr in $ips; do
                ip rule add to "${ip_addr}/32" table "$table_id" priority "$V4_PRIO_DDNS" 2>/dev/null || true
            done

            [[ "${1:-}" != "quiet" && -n "$ips" ]] && ui_success "DDNS更新: $domain -> $group"
        fi
    done < "$V4_DDNS_CONFIG_FILE"
}

v4_manage_cron() {
    ui_header "IPv4 DDNS 自动更新配置"

    # 检测标识统一为子命令名，与 v4_add_ddns_rule 添加的行一致
    local cron_marker="v4_ddns"

    if crontab -l 2>/dev/null | grep -q "$cron_marker"; then
        ui_kv "状态" "${GREEN}已启用${NC}"
        read -rp "是否移除自动更新? y/n: " opt
        [[ "$opt" == "y" ]] && {
            crontab -l 2>/dev/null | grep -v "$cron_marker" | crontab -
            ui_success "已移除。"
        }
    else
        ui_kv "状态" "${RED}未启用${NC}"
        read -rp "是否添加每 5 分钟自动更新? y/n: " opt
        [[ "$opt" == "y" ]] && {
            (crontab -l 2>/dev/null; echo ""; echo "*/5 * * * * bash \"${SCRIPT_PATH}\" v4_ddns >/dev/null 2>&1") | crontab -
            ui_success "已添加。"
        }
    fi
}

# 应用所有 IPv4 规则：mangle 打标 + fwmark rule + NAT MASQUERADE (dual-route 完整版)
v4_apply_saved_rules() {
    ui_info "正在初始化 IPv4 网络规则..."

    v4_fix_multigateway_conflict "quiet"
    v4_detect_available_routes "quiet" || true
    v4_init_routing_tables

    while ip rule del priority "$V4_PRIO_STATIC" 2>/dev/null; do :; done
    while ip rule del priority "$V4_PRIO_FWMARK" 2>/dev/null; do :; done

    # 1. mangle 表链重建
    iptables -t mangle -D OUTPUT -j CUSTOM_PBR 2>/dev/null
    iptables -t mangle -D PREROUTING -j CUSTOM_PBR 2>/dev/null
    iptables -t mangle -F CUSTOM_PBR 2>/dev/null
    iptables -t mangle -X CUSTOM_PBR 2>/dev/null
    iptables -t mangle -N CUSTOM_PBR
    iptables -t mangle -A OUTPUT -j CUSTOM_PBR
    iptables -t mangle -A PREROUTING -j CUSTOM_PBR

    # 2. nat 表源地址伪装链重建
    iptables -t nat -D POSTROUTING -j CUSTOM_PBR_NAT 2>/dev/null
    iptables -t nat -F CUSTOM_PBR_NAT 2>/dev/null
    iptables -t nat -X CUSTOM_PBR_NAT 2>/dev/null
    iptables -t nat -N CUSTOM_PBR_NAT
    iptables -t nat -A POSTROUTING -j CUSTOM_PBR_NAT

    for ((i = 0; i < ${#V4_FOUND_NAMES[@]}; i++)); do
        local table_id="${V4_FOUND_IDS[$i]}"
        local name="${V4_FOUND_NAMES[$i]}"
        ip rule add fwmark "$table_id" table "T_${name}" priority "$V4_PRIO_FWMARK" 2>/dev/null
        iptables -t nat -A CUSTOM_PBR_NAT -m mark --mark "$table_id" -j MASQUERADE 2>/dev/null
    done

    if [[ -s "$V4_CONFIG_FILE" ]]; then
        while IFS= read -r rule || [[ -n "$rule" ]]; do
            [[ -z "$rule" || "$rule" =~ ^[[:space:]]*# ]] && continue

            local col_count
            local cidr
            local proto
            local port
            local name
            col_count=$(echo "$rule" | awk '{print NF}')
            cidr=$(echo "$rule" | awk '{print $1}')
            proto="all"
            port="all"
            name=""

            if [ "$col_count" -eq 2 ]; then
                name=$(echo "$rule" | awk '{print $2}')
            elif [ "$col_count" -ge 4 ]; then
                proto=$(echo "$rule" | awk '{print $2}')
                port=$(echo "$rule" | awk '{print $3}')
                name=$(echo "$rule" | awk '{print $4}')
            else
                continue
            fi

            local found_idx=-1
            for ((i = 0; i < ${#V4_FOUND_NAMES[@]}; i++)); do
                if [[ "${V4_FOUND_NAMES[$i]}" == "$name" ]]; then
                    found_idx=$i
                    break
                fi
            done

            if [[ $found_idx -ge 0 ]]; then
                local table_id="${V4_FOUND_IDS[$found_idx]}"

                if [[ "$proto" == "all" && "$port" == "all" ]]; then
                    ip rule add to "$cidr" table "T_${name}" priority "$V4_PRIO_STATIC" 2>/dev/null
                else
                    if [[ "$port" == "all" ]]; then
                        iptables -t mangle -A CUSTOM_PBR -d "$cidr" -p "$proto" -j MARK --set-mark "$table_id"
                    else
                        iptables -t mangle -A CUSTOM_PBR -d "$cidr" -p "$proto" --dport "$port" -j MARK --set-mark "$table_id"
                    fi
                fi
            fi
        done < "$V4_CONFIG_FILE"
    fi

    v4_refresh_ddns_rules "quiet"
    ip route flush cache 2>/dev/null || true

    ui_success "IPv4 规则应用完毕。"
}

v4_main_menu() {
    v4_detect_available_routes "quiet" || true

    while true; do
        ui_header "IPv4 多出口策略路由"

        ui_kv "静态规则文件" "${CYAN}${V4_CONFIG_FILE}${NC}"
        ui_kv "DDNS规则文件" "${CYAN}${V4_DDNS_CONFIG_FILE}${NC}"
        ui_kv "静态优先级" "${YELLOW}${V4_PRIO_STATIC}${NC}"
        ui_kv "端口分流" "${GREEN}fwmark + NAT 伪装已启用${NC}"

        ui_section "功能菜单"
        ui_item "1" "添加静态路由" "IP/CIDR/端口 走指定出口"
        ui_item "2" "添加动态路由" "域名 DDNS 走指定出口"
        ui_item "3" "删除规则" "支持批量删除"
        ui_item "4" "修改现有规则"
        ui_item "5" "查看所有配置"
        ui_item "6" "配置自动更新" "Cron / DDNS 需要"
        ui_item "7" "强制刷新所有规则" "含网关冲突修复"
        ui_item "0" "返回主菜单"

        ui_line "─"

        read -rp "$(echo -e "${YELLOW}请选择:${NC} ")" choice

        case "$choice" in
            1)
                v4_add_rule
                ;;
            2)
                v4_add_ddns_rule
                ;;
            3)
                v4_delete_rule
                ;;
            4)
                v4_modify_rule
                ;;
            5)
                ui_section "静态规则"
                cat "$V4_CONFIG_FILE"
                echo
                ui_section "DDNS 规则"
                cat "$V4_DDNS_CONFIG_FILE"
                echo
                ui_section "系统生效规则"
                ip rule show | grep -E "priority ($V4_PRIO_STATIC|$V4_PRIO_FWMARK|$V4_PRIO_DDNS)" || echo "无"
                echo
                ui_section "mangle 端口分流规则"
                iptables -t mangle -S CUSTOM_PBR 2>/dev/null || echo "无防火墙分流规则"
                ;;
            6)
                v4_manage_cron
                ;;
            7)
                v4_apply_saved_rules
                ;;
            0)
                break
                ;;
            *)
                ui_warn "无效输入。"
                ;;
        esac

        ui_pause
    done
}

# ==============================================================================
# 模块 C: WireGuard 利群主机端 (auto-wg 三模式 + d.sh 加固)
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

# Bug 修复 #10: 接口名校验
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
            # 未运行时从配置文件读取
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
        echo "1. 去云端 / 公网 B 机器，用本脚本的 B 模式或你的方式部署 WireGuard 服务端。"
        echo "2. 在 B 的 Peer 中填写 A 的 PublicKey，并允许 A 的 WireGuard IP。"
        echo "3. 拿到 B 的 公网IP:端口、PublicKey、WireGuard IP。"
        echo "4. 回到本机 WireGuard 菜单，选择 3 最终握手。"
    fi
}

# --- B 云端公网服务器部署 (Bug 修复 #8: 新增) ---
wg_logic_b() {
    ui_header "WireGuard - B 云端公网服务器部署"
    wg_ask_interface

    echo
    echo -e "${YELLOW}A 机器（利群主机）是否已完成第一步 A？${NC}"
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
    wg_card "复制回 A 机器" \
        "B 的 公网 IP:端口 : ${public_ip}:${listen_port}" \
        "B 的 PublicKey    : ${WG_PUB_KEY}" \
        "B 的 WireGuard IP : ${my_ip}"
    ui_warn "请回到 A 机器，在 WireGuard 菜单选择 3 最终握手，填入上述信息。"
}

# --- C 最终握手 (Bug 修复 #9: 重复 PublicKey 不再追加) ---
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
        ui_header "WireGuard 利群主机端"

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
        ui_item "0" "返回主菜单"

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
                break
                ;;
            *)
                ui_warn "无效输入，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 模块 D: 统一管理与入口
# ==============================================================================
install_unified_services() {
    ui_header "一键安装守护服务 & 快捷键"

    read -rp "IPv6 自动任务检查频率 分钟 建议 2: " INTERVAL
    [[ -z "$INTERVAL" ]] && INTERVAL=2
    # 校验必须为数字，防止写出非法 systemd timer 配置
    [[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=2

    cat > "/etc/systemd/system/ipv6_manager.service" <<EOF
[Unit]
Description=LeiKwan Host IPv6 Manager
After=network-online.target

[Service]
Type=oneshot
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart="${SCRIPT_PATH}" v6_auto
User=root
EOF

    # Bug 修复 #11: 去掉无效的 OnActiveSec=10s，仅保留 OnBootSec + OnUnitActiveSec
    cat > "/etc/systemd/system/ipv6_manager.timer" <<EOF
[Unit]
Description=Run IPv6 Manager

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}m
Unit=ipv6_manager.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ipv6_manager.timer
    systemctl start ipv6_manager.service

    ui_success "IPv6 定时任务已启动。"

    cat > "/etc/systemd/system/ipv4_custom_routing.service" <<EOF
[Unit]
Description=LeiKwan Host IPv4 Custom Routing
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart="${SCRIPT_PATH}" v4_apply
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable --now ipv4_custom_routing.service

    ui_success "IPv4 开机自启路由服务已启动。"

    ln -sf "$SCRIPT_PATH" /usr/bin/d
    chmod +x "$SCRIPT_PATH"

    ui_success "快捷键 d 已创建。"

    echo
    echo -e "${YELLOW}>>> 安装完成！以后在任何地方输入字母 d 即可打开本菜单。 <<<${NC}"
    sleep 3
}

# ==============================================================================
# 模块 E: 一键替换 Debian APT 源为内网源
# ==============================================================================
# 解决 CN2/9929/浦东电信 机型拉取 Debian apt 卡顿问题（利群内网 APT 源）。
apt_switch_mirror() {
    ui_header "一键替换 Debian APT 源为内网源"
    echo -e "${GRAY}解决 CN2 / 9929 / 浦东电信 机型拉取 Debian apt 卡顿问题（内网 APT 源）${NC}"
    echo
    ui_warn "提示: 我们的 Debian 11 系统镜像不需要运行此脚本。"
    echo

    # 预检内网源域名解析：内网域名公网 DNS 通常解析不到，解析不了就写入 /etc/hosts
    if ! getent hosts files.leikwanhost.com >/dev/null 2>&1; then
        ui_warn "files.leikwanhost.com 无法解析（内网域名），正在写入内网 IP 到 /etc/hosts ..."
        grep -q "files.leikwanhost.com" /etc/hosts || echo "10.10.10.10 files.leikwanhost.com" >> /etc/hosts
        ui_success "已添加: 10.10.10.10 files.leikwanhost.com"
    else
        ui_success "files.leikwanhost.com 解析正常。"
    fi

    echo
    ui_info "正在下载内网 APT 源替换脚本..."
    if wget -q --timeout=10 -O /tmp/apt-leikwan.sh http://files.leikwanhost.com/apt-leikwan.sh; then
        ui_success "下载成功，开始执行替换..."
        echo
        bash /tmp/apt-leikwan.sh
        local rc=$?
        if [ "$rc" -eq 0 ]; then
            echo
            ui_info "替换完成，正在 apt update 验证..."
            apt update
            ui_success "APT 源替换完成。"
        else
            ui_warn "内网源脚本执行返回码 $rc，请检查上方输出。"
        fi
    else
        ui_error "下载失败。请确认可访问 files.leikwanhost.com，或手动执行:"
        echo "  wget http://files.leikwanhost.com/apt-leikwan.sh && bash apt-leikwan.sh"
    fi
    ui_pause
}

main_menu() {
    while true; do
        ui_header "利群管家 | LeiKwan Manager"

        ui_kv "当前版本" "${GREEN}${CURRENT_VERSION}${NC}"
        ui_kv "脚本路径" "${CYAN}${SCRIPT_PATH}${NC}"
        ui_kv "运行用户" "${GREEN}root${NC}"

        ui_section "主菜单"
        ui_item "1" "IPv6 智能管家" "双线选路 / DDNS 推送 / 防跳动"
        ui_item "2" "IPv4 多出口策略路由" "SDWAN / 端口分流 / NAT / PBR"
        ui_item "3" "WireGuard 利群主机端" "A内网 / B云端 / C握手"
        ui_item "4" "一键安装守护服务" "systemd 定时器 / 开机自启 / 快捷键 d"
        ui_item "5" "替换 APT 源为内网源" "CN2/9929/浦东电信 拉取卡顿"
        ui_item "0" "退出脚本"

        ui_line "─"

        read -rp "$(echo -e "${YELLOW}请输入选项:${NC} ")" choice

        case $choice in
            1)
                v6_main_menu
                ;;
            2)
                v4_main_menu
                ;;
            3)
                wg_main_menu
                ;;
            4)
                install_unified_services
                ;;
            5)
                apt_switch_mirror
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
    v6_auto)
        v6_run_auto_task
        ;;
    v4_apply)
        v4_apply_saved_rules
        ;;
    v4_ddns)
        v4_refresh_ddns_rules "quiet"
        ;;
    wg)
        wg_main_menu
        ;;
    *)
        main_menu
        ;;
esac
