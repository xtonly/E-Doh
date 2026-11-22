cat << 'EOF' > /usr/local/bin/doh
#!/usr/bin/env bash
# ==============================================================================
# Project   : E-Doh Manager (v3.6 Release)
# Repo      : https://github.com/xtonly/E-Doh
# Features  : Dual-Column TUI | Public/NAT IPv4 Live Sync | TW ChangeIP | Purge
# Usage     : doh | doh --auto [global|tw|apac|eu|na|cn] | doh --changeip | doh --purge
# ==============================================================================

VERSION="3.6"
GH_REPO="xtonly/E-Doh"
GH_BRANCH="main"
SCRIPT_PATH="/usr/local/bin/doh"

RAW_URLS=(
    "https://raw.githubusercontent.com/${GH_REPO}/refs/heads/${GH_BRANCH}/doh.sh"
    "https://testingcf.jsdelivr.net/gh/${GH_REPO}@${GH_BRANCH}/doh.sh"
    "https://fastly.jsdelivr.net/gh/${GH_REPO}@${GH_BRANCH}/doh.sh"
    "https://cdn.jsdelivr.net/gh/${GH_REPO}@${GH_BRANCH}/doh.sh"
)

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
GRAY='\033[0;37m'
PLAIN='\033[0m'

WORK_DIR="/etc/easy-doh"
BACKUP_DIR="${WORK_DIR}/backups"
BIN_PATH="/usr/local/bin/dnsproxy"
CONF_FILE="${WORK_DIR}/config.yaml"
STATE_FILE="${WORK_DIR}/profile.state"
SERVICE_FILE="/etc/systemd/system/easy-doh.service"
ROUTE_SERVICE="/etc/systemd/system/edoh-isp-route.service"
DOCKER_DAEMON="/etc/docker/daemon.json"

ISP_API_IPS=("100.100.101.101" "100.100.101.102")
ISP_API_PORT="8002"
Q_WIRE="AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"

# 严格统一 76 列宽边界，适配所有 80 列标准 SSH 终端不折行
DIV_BOLD="${CYAN}============================================================================${PLAIN}"
DIV_THIN="${GRAY}----------------------------------------------------------------------------${PLAIN}"

# 公网 IP 会话级缓存 (兼顾菜单 0ms 响应与换 IP 后强制刷新)
CACHED_PUB_V4=""
CACHED_LOCAL_V4=""
CACHED_V6_STATE=""
IP_CACHE_TS=0

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[Error] 请使用 root 权限运行 (Please run as root: sudo doh)${PLAIN}"
    exit 1
fi

# 严格校验是否为真实公网 IPv4 (剔除 10.x / 172.16-31.x / 192.168.x / 100.64-127.x / 127.x 等内网段)
is_public_ipv4() {
    local ip="$1"
    echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    awk -F. '{
        if ($1>255 || $2>255 || $3>255 || $4>255) exit 1
        if ($1==10 || $1==127 || $1==0) exit 1
        if ($1==192 && $2==168) exit 1
        if ($1==172 && $2>=16 && $2<=31) exit 1
        if ($1==100 && $2>=64 && $2<=127) exit 1
        if ($1==169 && $2==254) exit 1
        exit 0
    }' <<< "$ip"
}

doh_lookup_ip() {
    local domain="$1" ip=""
    local apis=(
        "https://1.1.1.1/dns-query"
        "https://8.8.8.8/resolve"
        "https://101.101.101.101/dns-query"
        "https://94.140.14.140/dns-query"
        "https://223.5.5.5/resolve"
    )
    for api in "${apis[@]}"; do
        ip=$(curl -4 --noproxy "*" -ksL --connect-timeout 2 --max-time 3 \
            -H "accept: application/dns-json" "${api}?name=${domain}&type=A" 2>/dev/null \
            | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -n1 | cut -d'"' -f4)
        [ -n "$ip" ] && break
    done
    echo "$ip"
}

# 提取物理主网卡、内网网关与本机网卡 IPv4
get_wan_info() {
    local line gw dev src
    line=$(ip -4 route show table main default 2>/dev/null | grep -vE 'dev (tun|tap|wg|utun|docker|br-|veth|tailscale|clash|mihomo|sing)' | head -n1)
    [ -z "$line" ] && line=$(ip -4 route show default 2>/dev/null | head -n1)
    gw=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
    dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -n "$dev" ]; then
        src=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi
    echo "${gw}|${dev}|${src}"
}

get_wan_gw_dev() {
    local info
    info=$(get_wan_info)
    echo "${info%|*}"
}

# 抗 DNS 封锁、抗 NAT 误判、抗 UA 拦截的公网 IPv4 获取器
get_public_ipv4() {
    local pub="" rip=""

    # 1. 优先尝试标准公网 IP Echo 接口 (带 Mozilla UA 与 --noproxy 防代理环境变量干扰)
    for u in "https://api-ipv4.ip.sb/ip" "http://ip.sb" "https://ipv4.icanhazip.com" "https://api.ipify.org" "http://checkip.amazonaws.com"; do
        pub=$(curl -4 --noproxy "*" -A "Mozilla/5.0" -fsSL --connect-timeout 1.5 --max-time 2.5 "$u" 2>/dev/null | tr -d '[:space:]')
        if is_public_ipv4 "$pub"; then
            echo "$pub"
            return 0
        fi
    done

    # 2. 免 DNS 纯 IP 兜底 (当 53 端口瘫痪且尚未启动 DoH 时生效)
    for trace_ip in "1.1.1.1" "1.0.0.1"; do
        pub=$(curl -4 --noproxy "*" -ksL --connect-timeout 1.5 --max-time 2.5 "https://${trace_ip}/cdn-cgi/trace" 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]')
        if is_public_ipv4 "$pub"; then
            echo "$pub"
            return 0
        fi
    done

    # 3. 极端环境兜底 (53 端口被封 + 1.1.1.1 被黑洞时，经由存活 DoH 预解析直连 ip.sb)
    rip=$(doh_lookup_ip "api-ipv4.ip.sb")
    if [ -n "$rip" ]; then
        pub=$(curl -4 --noproxy "*" -A "Mozilla/5.0" -fsSL --connect-timeout 2 --max-time 3 \
            --resolve "api-ipv4.ip.sb:443:${rip}" "https://api-ipv4.ip.sb/ip" 2>/dev/null | tr -d '[:space:]')
        if is_public_ipv4 "$pub"; then
            echo "$pub"
            return 0
        fi
    fi

    echo "获取超时"
}

# 刷新公网/内网 IP 缓存 (传入 1 强制立即重抓，传入 0 则 60 秒内复用缓存)
refresh_ip_cache() {
    local force="${1:-0}" now
    now=$(date +%s)
    if [ "$force" -eq 1 ] || [ -z "$CACHED_PUB_V4" ] || [ $((now - IP_CACHE_TS)) -ge 60 ]; then
        local w_info
        w_info=$(get_wan_info)
        CACHED_LOCAL_V4="${w_info##*|}"
        CACHED_PUB_V4=$(get_public_ipv4)
        if ip -6 route show default 2>/dev/null | grep -q 'default'; then
            CACHED_V6_STATE="${GREEN}双栈已就绪${PLAIN}"
        else
            CACHED_V6_STATE="${GRAY}仅 IPv4${PLAIN}"
        fi
        IP_CACHE_TS="$now"
    fi
}

invalidate_ip_cache() {
    IP_CACHE_TS=0
    CACHED_PUB_V4=""
}

probe_doh_alive() {
    local url="$1" b_ip="${2:-}" host rip res_arg=() code
    host=$(echo "$url" | awk -F/ '{print $3}')
    if ! echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if [ -n "$b_ip" ]; then
            rip=$(curl -4 --noproxy "*" -ksL --connect-timeout 2 --max-time 3 -H "accept: application/dns-json" \
                "https://${b_ip}/dns-query?name=${host}&type=A" 2>/dev/null \
                | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -n1 | cut -d'"' -f4)
        fi
        [ -z "$rip" ] && rip=$(doh_lookup_ip "$host")
        [ -n "$rip" ] && res_arg=(--resolve "${host}:443:${rip}")
    fi

    code=$(curl -4 --noproxy "*" -s -o /dev/null "${res_arg[@]}" --connect-timeout 1.5 --max-time 2.5 \
        -H "accept: application/dns-message" -w "%{http_code}" "${url}?dns=${Q_WIRE}" 2>/dev/null | tr -d '\000')
    [ "$code" = "200" ]
}

pick_best_bootstrap() {
    local prefer="$1"
    local candidates=("$prefer" "8.8.8.8" "1.1.1.1" "94.140.14.140" "185.222.222.222" "101.101.101.101" "223.5.5.5")
    local seen="" ip code
    for ip in "${candidates[@]}"; do
        [ -z "$ip" ] && continue
        [[ "$seen" == *"|$ip|"* ]] && continue
        seen="${seen}|${ip}|"
        code=$(curl -4 --noproxy "*" -s -o /dev/null --connect-timeout 1.2 --max-time 2 \
            -H "accept: application/dns-message" -w "%{http_code}" \
            "https://${ip}/dns-query?dns=${Q_WIRE}" 2>/dev/null | tr -d '\000')
        if [ "$code" = "200" ]; then
            echo "$ip"
            return 0
        fi
    done
    echo "94.140.14.140"
}

fetch_remote_script() {
    local target="$1" url fetch_url host rip res_arg=()
    for url in "${RAW_URLS[@]}"; do
        host=$(echo "$url" | awk -F/ '{print $3}')
        res_arg=()
        if ! getent ahostsv4 "$host" >/dev/null 2>&1; then
            rip=$(doh_lookup_ip "$host")
            [ -n "$rip" ] && res_arg=(--resolve "${host}:443:${rip}")
        fi
        fetch_url="$url"
        [[ "$host" == "raw.githubusercontent.com" ]] && fetch_url="${url}?t=$(date +%s)"

        if curl -4 --noproxy "*" -fsSL "${res_arg[@]}" -H "Cache-Control: no-cache" --connect-timeout 5 --max-time 15 "$fetch_url" -o "$target" 2>/dev/null; then
            if grep -qE "(E-Doh|Easy-DoH) Manager" "$target" 2>/dev/null; then
                echo -e "${GRAY}  -> 成功命中源 (Source): ${host}${PLAIN}"
                return 0
            fi
        fi
    done
    return 1
}

bootstrap_self() {
    local self_real=""
    self_real=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ ! -f "$0" ] || [[ "$0" == *"/dev/fd/"* ]] || [ "$0" = "bash" ] || [ "$0" = "-bash" ]; then
        echo -e "${CYAN}[Init] 检测到远程管道执行，正在将管理命令固化至 ${SCRIPT_PATH} ...${PLAIN}"
        if fetch_remote_script "${SCRIPT_PATH}.tmp"; then
            mv -f "${SCRIPT_PATH}.tmp" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo -e "${GREEN}[OK] 命令固化成功！以后随时输入 'doh' 即可呼出面板。${PLAIN}"
            exec "$SCRIPT_PATH" "$@" </dev/tty
        else
            echo -e "${YELLOW}[Warn] 远程源拉取跳过，直接进入当前交互会话...${PLAIN}"
        fi
    elif [ "$self_real" != "$SCRIPT_PATH" ]; then
        cp -f "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi
}

pause_return() {
    echo ""
    read -rp "按回车键返回主菜单 / Press Enter to return..." _ </dev/tty
}

pause_submenu() {
    echo ""
    read -rp "按回车键返回上一级菜单 / Press Enter to go back..." _ </dev/tty
}

save_orig_resolv() {
    mkdir -p "$WORK_DIR" "$BACKUP_DIR"
    if [ ! -f "${WORK_DIR}/resolv.conf.orig" ] && [ ! -f "${WORK_DIR}/resolv.symlink" ]; then
        if [ -L /etc/resolv.conf ]; then
            readlink /etc/resolv.conf > "${WORK_DIR}/resolv.symlink"
        elif [ -f /etc/resolv.conf ]; then
            cp -f /etc/resolv.conf "${WORK_DIR}/resolv.conf.orig"
        fi
    fi
}

backup_configs() {
    mkdir -p "$WORK_DIR" "$BACKUP_DIR"
    save_orig_resolv
    local ts tar_file files_to_bak=()
    ts=$(date +%Y%m%d_%H%M%S)
    tar_file="${BACKUP_DIR}/dns_bak_${ts}.tar.gz"

    [ -f /etc/resolv.conf ] && files_to_bak+=("/etc/resolv.conf")
    [ -f "$DOCKER_DAEMON" ] && files_to_bak+=("$DOCKER_DAEMON")
    [ -f "$CONF_FILE" ] && files_to_bak+=("$CONF_FILE")

    if [ ${#files_to_bak[@]} -gt 0 ]; then
        tar -czf "$tar_file" "${files_to_bak[@]}" 2>/dev/null
        ls -1t "${BACKUP_DIR}"/dns_bak_*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
    fi
}

get_docker_ip() {
    if command -v docker >/dev/null 2>&1 && ip addr show docker0 >/dev/null 2>&1; then
        ip -4 addr show docker0 | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -n1
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "linux-amd64" ;;
        aarch64|arm64) echo "linux-arm64" ;;
        armv7l) echo "linux-armv7" ;;
        *) echo "unsupported" ;;
    esac
}

install_binary() {
    local check_update="${1:-0}" cur_ver=""
    if [ -x "$BIN_PATH" ] && "$BIN_PATH" --version >/dev/null 2>&1; then
        cur_ver=$("$BIN_PATH" --version 2>/dev/null | awk '{print $NF}')
        [ "$check_update" -eq 0 ] && return 0
    fi

    local arch api_ip gh_ip obj_ip ver pkg url tmp_tar
    arch=$(get_arch)
    [ "$arch" = "unsupported" ] && echo -e "${RED}[Error] 不支持的架构 / Unsupported arch: $(uname -m)${PLAIN}" && return 1

    echo -e "${CYAN}  -> 正在通过加密通道查询 GitHub 最新 dnsproxy 版本...${PLAIN}"
    api_ip=$(doh_lookup_ip "api.github.com"); [ -z "$api_ip" ] && api_ip="140.82.114.6"
    gh_ip=$(doh_lookup_ip "github.com");       [ -z "$gh_ip" ] && gh_ip="140.82.114.4"
    obj_ip=$(doh_lookup_ip "objects.githubusercontent.com"); [ -z "$obj_ip" ] && obj_ip="185.199.108.133"

    ver=$(curl -4 --noproxy "*" -ksL --connect-timeout 6 --resolve "api.github.com:443:${api_ip}" \
        "https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest" \
        | grep -oE '"tag_name": *"v[0-9.]+"' | head -n1 | cut -d'"' -f4)
    [ -z "$ver" ] && ver="v0.86.0"

    if [ "$check_update" -eq 1 ] && [ -n "$cur_ver" ] && [ "$cur_ver" = "$ver" ]; then
        echo -e "${GREEN}  -> 当前 dnsproxy 内核已是最新版本 (${cur_ver})，无需重复下载！${PLAIN}"
        return 0
    fi

    pkg="dnsproxy-${arch}-${ver}.tar.gz"
    url="https://github.com/AdguardTeam/dnsproxy/releases/download/${ver}/${pkg}"
    tmp_tar="/tmp/${pkg}"

    echo -e "${CYAN}  -> 正在直连下载 dnsproxy (${cur_ver:+${cur_ver} -> }${ver} / ${arch})...${PLAIN}"
    curl -4 --noproxy "*" -kL -# --connect-timeout 15 --retry 2 \
        --resolve "github.com:443:${gh_ip}" \
        --resolve "objects.githubusercontent.com:443:${obj_ip}" \
        --resolve "release-assets.githubusercontent.com:443:${obj_ip}" \
        -o "$tmp_tar" "$url"

    if [ ! -s "$tmp_tar" ]; then
        echo -e "${RED}[Error] 下载失败！可尝试主菜单 [2] 零下载启用系统原生 DoT。${PLAIN}"
        rm -f "$tmp_tar"
        return 1
    fi

    tar -xzf "$tmp_tar" -C /tmp && install -m 755 "/tmp/${arch}/dnsproxy" "${BIN_PATH}.new"
    rm -rf "$tmp_tar" "/tmp/${arch}"

    if "${BIN_PATH}.new" --version >/dev/null 2>&1; then
        mv -f "${BIN_PATH}.new" "$BIN_PATH"
        echo -e "${GREEN}  -> dnsproxy 校验通过: $("$BIN_PATH" --version)${PLAIN}"
        return 0
    fi
    rm -f "${BIN_PATH}.new"
    echo -e "${RED}[Error] 二进制校验未通过，已保留旧文件 (Lossless rollback).${PLAIN}"
    return 1
}

free_port_53() {
    if ss -tulnp | grep -qE '(:53 |127\.0\.0\.53:53)'; then
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "${YELLOW}  -> 释放 systemd-resolved 占用的 53 端口...${PLAIN}"
            mkdir -p /etc/systemd/resolved.conf.d
            cat << 'RES_EOF' > /etc/systemd/resolved.conf.d/99-easy-doh.conf
[Resolve]
DNSStubListener=no
RES_EOF
            systemctl restart systemd-resolved
            sleep 1
        fi
    fi
}

write_doh_config() {
    mkdir -p "$WORK_DIR"
    rm -f "${WORK_DIR}/split_dns.conf" 2>/dev/null || true
    local mode="${1:-global}" custom_u1="$2" custom_u2="$3" dip
    dip=$(get_docker_ip)

    local group_label="" pref_boot="8.8.8.8" candidates=()
    case "$mode" in
        tw|tw_opt)
            group_label="TW Local"
            pref_boot="8.8.8.8"
            candidates=(
                "HiNet|https://dns.hinet.net/dns-query"
                "Google|https://8.8.8.8/dns-query"
                "CF|https://1.1.1.1/dns-query"
                "AdGuard|https://94.140.14.140/dns-query"
                "DNS.SB|https://185.222.222.222/dns-query"
            )
            ;;
        apac|apac_opt)
            group_label="Asia-Pacific"
            pref_boot="185.222.222.222"
            candidates=(
                "DNS.SB|https://185.222.222.222/dns-query"
                "AdGuard|https://94.140.14.140/dns-query"
                "IIJ-JP|https://public.dns.iij.jp/dns-query"
                "CF|https://1.1.1.1/dns-query"
                "Google|https://8.8.8.8/dns-query"
            )
            ;;
        eu|eu_opt)
            group_label="Europe"
            pref_boot="9.9.9.11"
            candidates=(
                "Quad9-ECS|https://9.9.9.11/dns-query"
                "CF|https://1.1.1.1/dns-query"
                "Mullvad|https://194.242.2.2/dns-query"
                "DNS.SB|https://185.222.222.222/dns-query"
                "AdGuard|https://94.140.14.140/dns-query"
            )
            ;;
        na|na_opt)
            group_label="America"
            pref_boot="9.9.9.11"
            candidates=(
                "Quad9-ECS|https://9.9.9.11/dns-query"
                "CF|https://1.1.1.1/dns-query"
                "OpenDNS|https://doh.opendns.com/dns-query"
                "ControlD|https://freedns.controld.com/p0"
                "Google|https://8.8.8.8/dns-query"
            )
            ;;
        cn|cn_opt)
            group_label="Mainland"
            pref_boot="223.5.5.5"
            candidates=(
                "AliDNS-1|https://223.5.5.5/dns-query"
                "AliDNS-2|https://223.6.6.6/dns-query"
                "DNSPod|https://doh.pub/dns-query"
                "360DoH|https://doh.360.cn/dns-query"
            )
            ;;
        custom)
            group_label="Custom"
            pref_boot="94.140.14.140"
            candidates=(
                "Primary|${custom_u1}"
                "Backup|${custom_u2}"
            )
            ;;
        *)
            group_label="Global"
            pref_boot="9.9.9.11"
            candidates=(
                "Quad9-ECS|https://9.9.9.11/dns-query"
                "CF|https://1.1.1.1/dns-query"
                "Google|https://8.8.8.8/dns-query"
                "DNS.SB|https://185.222.222.222/dns-query"
                "AdGuard|https://94.140.14.140/dns-query"
            )
            ;;
    esac

    echo -e "${CYAN}  -> 正在探测当前机器可用 Bootstrap 与存活上游 (自动剔除黑洞节点)...${PLAIN}"
    local boot_ip
    boot_ip=$(pick_best_bootstrap "$pref_boot")

    local alive_urls=() alive_names=() dead_names=()
    for item in "${candidates[@]}"; do
        local n_tag="${item%%|*}"
        local n_url="${item##*|}"
        [ -z "$n_url" ] && continue
        if [[ "$mode" = "custom" ]] || probe_doh_alive "$n_url" "$boot_ip"; then
            alive_urls+=("$n_url")
            alive_names+=("$n_tag")
        else
            dead_names+=("$n_tag")
        fi
    done

    if [[ "$mode" == tw* ]] && [ ${#alive_urls[@]} -lt 2 ]; then
        if probe_doh_alive "https://101.101.101.101/dns-query" "$boot_ip"; then
            alive_urls+=("https://101.101.101.101/dns-query")
            alive_names+=("TWNIC")
        fi
    fi

    if [ ${#dead_names[@]} -gt 0 ]; then
        local dead_str
        dead_str=$(printf "%s, " "${dead_names[@]}")
        echo -e "${YELLOW}  -> [避坑] 已自动剔除本机超时的黑洞节点: ${dead_str%, }${PLAIN}"
    fi

    if [ ${#alive_urls[@]} -eq 0 ]; then
        alive_urls=("https://${boot_ip}/dns-query")
        alive_names=("Fallback-${boot_ip}")
    fi

    local joined_names
    if [ "$mode" = "custom" ]; then
        local short_u1="${custom_u1#https://}"; short_u1="${short_u1#tls://}"; short_u1="${short_u1%%/*}"
        joined_names="$short_u1"
    else
        joined_names=$(printf "%s / " "${alive_names[@]}")
        joined_names="${joined_names% / }"
    fi
    echo "${group_label} (${joined_names})" > "$STATE_FILE"
    echo -e "${GREEN}  -> 已启用存活节点: ${joined_names} (Bootstrap: ${boot_ip})${PLAIN}"

    cat << YAML_EOF > "$CONF_FILE"
# E-Doh Config v${VERSION} (Auto-Pruned Healthy Upstreams)
listen-addrs:
  - "127.0.0.1"
YAML_EOF
    [ -n "$dip" ] && echo "  - \"${dip}\"" >> "$CONF_FILE"

    cat << YAML_BODY >> "$CONF_FILE"
listen-ports:
  - 53
upstream-mode: load_balance
cache: true
cache-size: 4194304
cache-optimistic: true
timeout: 3s
bootstrap:
  - "https://${boot_ip}/dns-query"
upstream:
YAML_BODY

    for u in "${alive_urls[@]}"; do
        echo "  - \"${u}\"" >> "$CONF_FILE"
    done

    cat << YAML_FB >> "$CONF_FILE"
fallback:
  - "https://${boot_ip}/dns-query"
  - "tls://${boot_ip}:853"
YAML_FB
}

# ==============================================================================
# TW HiNet / Seednet 内网换 IP 静态路由守护与一键重拨模块 (100.100.101.101/102:8002)
# ==============================================================================
probe_tcp_8002() {
    local target_ip="$1" ec=0
    curl -4 --noproxy "*" -s -o /dev/null --connect-timeout 2 --max-time 3 "http://${target_ip}:${ISP_API_PORT}/" 2>/dev/null || ec=$?
    [ "$ec" -eq 0 ] || [ "$ec" -eq 52 ]
}

enable_isp_route() {
    local gw_dev gw dev
    gw_dev=$(get_wan_gw_dev)
    gw="${gw_dev%%|*}"
    dev="${gw_dev##*|}"

    if [ -z "$gw" ] || [ -z "$dev" ]; then
        echo -e "${RED}  [Error] 无法自动识别主网卡与内网网关，请检查 ip route 输出！${PLAIN}"
        return 1
    fi

    for aip in "${ISP_API_IPS[@]}"; do
        ip route replace "${aip}/32" via "$gw" dev "$dev"
    done

    cat << RT_EOF > "$ROUTE_SERVICE"
[Unit]
Description=E-Doh TW ISP ChangeIP Static Route Guard (100.100.101.101/102)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip route replace 100.100.101.101/32 via ${gw} dev ${dev} && ip route replace 100.100.101.102/32 via ${gw} dev ${dev}'
ExecStop=/bin/sh -c 'ip route del 100.100.101.101/32 2>/dev/null || true; ip route del 100.100.101.102/32 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
RT_EOF

    systemctl daemon-reload
    systemctl enable edoh-isp-route >/dev/null 2>&1 || true
    systemctl start edoh-isp-route >/dev/null 2>&1 || true
    echo -e "${GREEN}  -> 静态路由已挂载并开启自启: 100.100.101.101/102 via ${gw} dev ${dev}${PLAIN}"
    return 0
}

test_isp_api_port() {
    echo -e "${CYAN}  -> 正在静默检测内网换 IP 控制器 (${ISP_API_PORT} 端口) 连通性...${PLAIN}"
    local ok_cnt=0
    for aip in "${ISP_API_IPS[@]}"; do
        if probe_tcp_8002 "$aip"; then
            echo -e "    ${GREEN}[OK]${PLAIN}   http://${aip}:${ISP_API_PORT} -> TCP 握手成功 (通道畅通)"
            ok_cnt=$((ok_cnt + 1))
        else
            echo -e "    ${GRAY}[SKIP]${PLAIN} http://${aip}:${ISP_API_PORT} -> 备用节点未启用或不可达"
        fi
    done
    [ "$ok_cnt" -gt 0 ]
}

trigger_isp_changeip() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}执行 TW 动态家宽 API 换 IP / Trigger ISP Dynamic IP Rotation${PLAIN}"
    echo -e "${DIV_THIN}"

    enable_isp_route || return 1
    local old_ip new_ip="" resp="" hit_api="" ec=0
    old_ip=$(get_public_ipv4)
    echo -e "  更换前公网 IPv4 : ${YELLOW}${old_ip}${PLAIN}"

    for aip in "${ISP_API_IPS[@]}"; do
        echo -e "  -> 请求换 IP 接口: http://${aip}:${ISP_API_PORT}/changeip ..."
        ec=0
        resp=$(curl -4 --noproxy "*" -fsSL --connect-timeout 3 --max-time 15 "http://${aip}:${ISP_API_PORT}/changeip" 2>/dev/null) || ec=$?
        if [ "$ec" -eq 0 ] || [ "$ec" -eq 52 ] || [ "$ec" -eq 56 ]; then
            hit_api="$aip"
            [ -z "$resp" ] && resp="Triggered (接口已受理，PPPoE 重拨切换中)"
            break
        fi
    done

    if [ -z "$hit_api" ]; then
        echo -e "${RED}  [FAIL] 100.100.101.101 与 .102 接口均未响应，请确认是否为动态机型！${PLAIN}"
        echo -e "${DIV_BOLD}"
        return 1
    fi

    echo -e "  控制器返回响应  : ${GRAY}$(echo "$resp" | tr '\n' ' ' | cut -c1-52)${PLAIN}"
    echo -ne "${CYAN}  -> 等待重拨分配新公网 IP "

    # 轮询最多 8 次 (约 16 秒)，重拨后平滑重启 dnsproxy 释放绑定在旧公网 IP 上的残留长连接
    local restarted_doh=0
    for _ in 1 2 3 4 5 6 7 8; do
        echo -n "."
        sleep 2
        if [ "$restarted_doh" -eq 0 ] && systemctl is-active --quiet easy-doh; then
            systemctl restart easy-doh 2>/dev/null || true
            restarted_doh=1
        fi
        new_ip=$(get_public_ipv4)
        if [ "$new_ip" != "获取超时" ] && [ "$new_ip" != "$old_ip" ]; then
            break
        fi
    done
    echo -e "${PLAIN}"

    # 强制同步全局公网 IP 缓存，彻底杜绝面板残留旧 IP
    invalidate_ip_cache
    refresh_ip_cache 1
    [ "$CACHED_PUB_V4" != "获取超时" ] && new_ip="$CACHED_PUB_V4"

    if [ "$new_ip" != "获取超时" ] && [ "$new_ip" != "$old_ip" ]; then
        echo -e "  ${GREEN}[OK] 换 IP 成功 : ${YELLOW}${old_ip}${PLAIN} -> ${GREEN}${new_ip}${PLAIN}"
    else
        echo -e "  当前公网 IPv4   : ${CYAN}${new_ip}${PLAIN} (若处于商家冷却期内 IP 可能不变)"
    fi
    echo -e "${DIV_BOLD}"
}

remove_isp_route() {
    systemctl stop edoh-isp-route 2>/dev/null || true
    systemctl disable edoh-isp-route 2>/dev/null || true
    rm -f "$ROUTE_SERVICE"
    systemctl daemon-reload
    for aip in "${ISP_API_IPS[@]}"; do
        ip route del "${aip}/32" 2>/dev/null || true
    done
    echo -e "${GREEN}  [OK] 已移除 100.100.101.101/102 静态路由与开机自启服务！${PLAIN}"
}

manage_isp_changeip() {
    while true; do
        refresh_ip_cache 0
        local gw_dev gw dev cur_rt rt_display
        gw_dev=$(get_wan_gw_dev)
        gw="${gw_dev%%|*}"
        dev="${gw_dev##*|}"
        cur_rt=$(ip -4 route show 100.100.101.101/32 2>/dev/null | head -n1)

        if echo "$cur_rt" | grep -q "via "; then
            rt_display="${GREEN}100.100.101.101/102 via ${gw} dev ${dev} [已保护]${PLAIN}"
        elif [ -n "$cur_rt" ]; then
            rt_display="${YELLOW}${cur_rt} [异常作用域 -> 请按 1 修复]${PLAIN}"
        else
            rt_display="${GRAY}未挂载专有静态路由 (默认走公网出口)${PLAIN}"
        fi

        clear
        echo -e "${DIV_BOLD}"
        echo -e " ${CYAN}TW 动态家宽换 IP 助手与路由守护 (HiNet / Seednet 100.100.101.x)${PLAIN}"
        echo -e "${DIV_BOLD}"
        echo -e "  当前公网 IPv4 : ${GREEN}${CACHED_PUB_V4}${PLAIN}  (网卡: ${CYAN}${dev:-未知}${PLAIN} | 网关: ${CYAN}${gw:-未知}${PLAIN})"
        echo -e "  内网路由状态  : ${rt_display}"
        echo -e "${DIV_THIN}"
        echo -e "  ${GREEN}[1]${PLAIN} 挂载并开机固化 100.100.101.101/102 内网网关路由 (必选)"
        echo -e "  ${GREEN}[2]${PLAIN} 立即调用 API 换新 IP (:8002/changeip 自动重拨并同步新 IP)"
        echo -e "  ${GREEN}[3]${PLAIN} 静默测试 100.100.101.101/102:8002 端口握手连通性"
        echo -e "  ${GREEN}[4]${PLAIN} 移除内网静态路由与开机自启守护"
        echo -e "  ${GREEN}[0]${PLAIN} 返回主菜单 (Back)"
        echo -e "${DIV_BOLD}"
        local r_opt
        read -rp "请选择操作编号 / Select option [0-4]: " r_opt </dev/tty
        r_opt=$(echo "$r_opt" | tr -d '[:space:]')
        [ -z "$r_opt" ] && continue

        case "$r_opt" in
            0) return 0 ;;
            1) echo ""; enable_isp_route && test_isp_api_port; pause_submenu ;;
            2) trigger_isp_changeip; pause_submenu ;;
            3) echo ""; test_isp_api_port; pause_submenu ;;
            4) echo ""; remove_isp_route; pause_submenu ;;
            *)
                echo -e "\n${RED}[Warn] 无效选项 '${r_opt}'，请输入 0-4 之间的数字！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

activate_doh_service() {
    cat << SVC_EOF > "$SERVICE_FILE"
[Unit]
Description=E-Doh Local Encrypted DNS Proxy (TCP/UDP)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} --config-path=${CONF_FILE}
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC_EOF

    systemctl daemon-reload
    systemctl enable easy-doh >/dev/null 2>&1
    systemctl restart easy-doh
    sleep 1

    if ! systemctl is-active --quiet easy-doh; then
        echo -e "${RED}[Error] 服务启动失败，请按 [8] 查看运行日志！${PLAIN}"
        return 1
    fi

    chattr -i /etc/resolv.conf 2>/dev/null || true
    save_orig_resolv
    rm -f /etc/resolv.conf
    cat << 'R_EOF' > /etc/resolv.conf
# Managed by E-Doh (TCP+UDP 53 -> DoH/DoT)
nameserver 127.0.0.1
options edns0 trust-ad timeout:2 attempts:2
R_EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo -e "${GREEN}  -> 系统 /etc/resolv.conf 已接管并开启防篡改锁 (+i)。${PLAIN}"
    return 0
}

fix_docker_dns() {
    local silent_mode="${1:-0}"
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${GRAY}  -> 当前机器未安装 Docker，自动跳过容器避坑配置 (Skipped).${PLAIN}"
        return 0
    fi

    local dip reload_dk="y" need_restart=0
    dip=$(get_docker_ip)
    [ -z "$dip" ] && dip="172.17.0.1"

    mkdir -p /etc/docker "$WORK_DIR"
    echo "$dip" > "${WORK_DIR}/docker_ip.state"

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow in on docker0 to any port 53 >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -i docker0 -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i docker0 -p udp --dport 53 -j ACCEPT 2>/dev/null
        iptables -C INPUT -i docker0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i docker0 -p tcp --dport 53 -j ACCEPT 2>/dev/null
    fi

    if [ -f "$CONF_FILE" ] && ! grep -q "$dip" "$CONF_FILE"; then
        sed -i "/listen-addrs:/a \  - \"${dip}\"" "$CONF_FILE"
        systemctl restart easy-doh
    fi

    if [ -s "$DOCKER_DAEMON" ] && grep -q "\"${dip}\"" "$DOCKER_DAEMON" 2>/dev/null && ! grep -qE '"(8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1)"' "$DOCKER_DAEMON" 2>/dev/null; then
        echo -e "${GREEN}  -> Docker 容器网桥 DNS (${dip}:53) 已处于受保护状态！${PLAIN}"
        return 0
    fi

    echo -e "${CYAN}  -> 检测到 Docker，正在注入网桥 DNS (${dip}) 防回退 8.8.8.8...${PLAIN}"
    backup_configs

    if [ ! -s "$DOCKER_DAEMON" ] || [ "$(tr -d '[:space:]' < "$DOCKER_DAEMON")" = "{}" ]; then
        printf '{\n  "dns": ["%s"]\n}\n' "$dip" > "$DOCKER_DAEMON"
        need_restart=1
    elif command -v jq >/dev/null 2>&1; then
        local tmp_jq="${DOCKER_DAEMON}.tmp"
        if jq --arg dip "$dip" '.dns = ([$dip] + ((.dns // []) | map(select(. != $dip and . != "8.8.8.8" and . != "8.8.4.4" and . != "1.1.1.1"))))' "$DOCKER_DAEMON" > "$tmp_jq" 2>/dev/null && [ -s "$tmp_jq" ]; then
            mv -f "$tmp_jq" "$DOCKER_DAEMON"
            need_restart=1
        else
            rm -f "$tmp_jq"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$DOCKER_DAEMON" "$dip" << 'PY_EOF'
import json, sys, os
path, dip = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, 'r') as f:
        data = json.load(f)
dns_list = data.get("dns", [])
if dip not in dns_list:
    dns_list.insert(0, dip)
dns_list = [x for x in dns_list if x not in ("8.8.8.8", "8.8.4.4", "1.1.1.1")]
data["dns"] = dns_list
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PY_EOF
        need_restart=1
    elif ! grep -q '"dns"' "$DOCKER_DAEMON" 2>/dev/null; then
        sed -i "0,/{/s/{/{\n  \"dns\": [\"${dip}\"],/" "$DOCKER_DAEMON"
        need_restart=1
    else
        echo -e "${YELLOW}[Warn] 检测到自定义 daemon.json，请确认其中包含 \"dns\": [\"${dip}\"]${PLAIN}"
        return 0
    fi

    if [ "$need_restart" -eq 1 ]; then
        if [ "$silent_mode" -eq 0 ]; then
            read -rp "  -> 是否立即重启 Docker 使容器生效？(Restart Docker?) [Y/n]: " reload_dk </dev/tty
        fi
        if [[ ! "$reload_dk" =~ ^[Nn]$ ]]; then
            systemctl restart docker
            systemctl restart easy-doh
            echo -e "${GREEN}  -> Docker 容器 DNS 通道已打通 (${dip}:53 -> DoH)！${PLAIN}"
        fi
    fi
}

revert_docker_dns() {
    local dip=""
    [ -f "${WORK_DIR}/docker_ip.state" ] && dip=$(cat "${WORK_DIR}/docker_ip.state")
    [ -z "$dip" ] && dip=$(get_docker_ip)
    [ -z "$dip" ] && dip="172.17.0.1"

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow in on docker0 to any port 53 >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        while iptables -D INPUT -i docker0 -p udp --dport 53 -j ACCEPT 2>/dev/null; do :; done
        while iptables -D INPUT -i docker0 -p tcp --dport 53 -j ACCEPT 2>/dev/null; do :; done
    fi

    if [ -f "$DOCKER_DAEMON" ] && grep -q "$dip" "$DOCKER_DAEMON" 2>/dev/null; then
        if command -v jq >/dev/null 2>&1; then
            local tmp_jq="${DOCKER_DAEMON}.tmp"
            if jq --arg dip "$dip" 'if .dns then .dns |= map(select(. != $dip)) | if (.dns | length) == 0 then del(.dns) else . end else . end' "$DOCKER_DAEMON" > "$tmp_jq" 2>/dev/null; then
                if [ "$(tr -d '[:space:]' < "$tmp_jq")" = "{}" ]; then
                    rm -f "$DOCKER_DAEMON" "$tmp_jq"
                else
                    mv -f "$tmp_jq" "$DOCKER_DAEMON"
                fi
            fi
        elif command -v python3 >/dev/null 2>&1; then
            python3 - "$DOCKER_DAEMON" "$dip" << 'PY_CLEAN'
import json, sys, os
path, dip = sys.argv[1], sys.argv[2]
try:
    with open(path, 'r') as f:
        data = json.load(f)
    if "dns" in data and dip in data["dns"]:
        data["dns"] = [x for x in data["dns"] if x != dip]
        if not data["dns"]:
            del data["dns"]
    if not data:
        os.remove(path)
    else:
        with open(path, 'w') as f:
            json.dump(data, f, indent=2)
except Exception:
    pass
PY_CLEAN
        else
            sed -i "/\"dns\": \[\"${dip}\"\],*/d" "$DOCKER_DAEMON" 2>/dev/null || true
            [ "$(tr -d '[:space:]' < "$DOCKER_DAEMON" 2>/dev/null)" = "{}" ] && rm -f "$DOCKER_DAEMON"
        fi
        command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker && systemctl restart docker 2>/dev/null || true
    fi
}

enable_native_dot() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}启用系统原生 DoT 模式 / Native systemd-resolved DoT (Port 853)${PLAIN}"
    echo -e "${DIV_THIN}"
    if ! systemctl list-unit-files | grep -q "systemd-resolved"; then
        echo -e "${RED}[Error] 系统未安装 systemd-resolved，请使用选项 [1] 部署 DoH！${PLAIN}"
        return 1
    fi

    backup_configs
    systemctl stop easy-doh 2>/dev/null || true
    systemctl disable easy-doh 2>/dev/null || true
    rm -f /etc/systemd/resolved.conf.d/99-easy-doh.conf

    mkdir -p /etc/systemd/resolved.conf.d
    cat << 'DOT_EOF' > /etc/systemd/resolved.conf.d/99-native-dot.conf
[Resolve]
DNS=94.140.14.140#unfiltered.adguard-dns.com 185.222.222.222#dns.sb 1.1.1.1#cloudflare-dns.com
FallbackDNS=8.8.8.8#dns.google 101.101.101.101#dns.twnic.tw
DNSOverTLS=yes
DNSStubListener=yes
Cache=yes
DOT_EOF
    echo "Native DoT (853 TLS)" > "$STATE_FILE"
    systemctl enable --now systemd-resolved >/dev/null 2>&1
    systemctl restart systemd-resolved

    chattr -i /etc/resolv.conf 2>/dev/null || true
    save_orig_resolv
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    invalidate_ip_cache
    echo -e "${GREEN}[OK] 系统原生 DoT (853 端口) 已成功接管！${PLAIN}"
    test_all_dns
}

run_deploy_core() {
    local mode="$1" c1="$2" c2="$3" silent="${4:-0}"
    backup_configs
    echo -e "${CYAN}[1/4] 检查并准备 dnsproxy 核心组件...${PLAIN}"
    install_binary 0 || return 1
    echo -e "${CYAN}[2/4] 探测健康节点并配置本地 TCP+UDP 智能负载均衡...${PLAIN}"
    rm -f /etc/systemd/resolved.conf.d/99-native-dot.conf
    free_port_53
    write_doh_config "$mode" "$c1" "$c2"

    echo -e "${CYAN}[3/4] 启动守护进程并锁定 /etc/resolv.conf...${PLAIN}"
    activate_doh_service || return 1

    echo -e "${CYAN}[4/4] 检查 Docker 与台湾内网换 IP 路由环境...${PLAIN}"
    fix_docker_dns "$silent"

    if [[ "$mode" == tw* ]]; then
        local gw_dev gw dev
        gw_dev=$(get_wan_gw_dev)
        gw="${gw_dev%%|*}"
        dev="${gw_dev##*|}"
        if [ -n "$gw" ] && [ -n "$dev" ]; then
            ip route replace 100.100.101.101/32 via "$gw" dev "$dev" 2>/dev/null || true
            if probe_tcp_8002 "100.100.101.101"; then
                enable_isp_route
            else
                [ ! -f "$ROUTE_SERVICE" ] && ip route del 100.100.101.101/32 2>/dev/null || true
            fi
        fi
    fi

    invalidate_ip_cache
    test_all_dns
}

# 二级子菜单 [1]：严格 76 列宽对齐，独立驻留
deploy_doh_wizard() {
    while true; do
        local cur_up="None (未配置)"
        [ -f "$STATE_FILE" ] && cur_up=$(cat "$STATE_FILE")
        [ "${#cur_up}" -gt 54 ] && cur_up="${cur_up:0:51}..."

        clear
        echo -e "${DIV_BOLD}"
        echo -e " ${CYAN}安装 / 切换分地区 DoH 策略 (自动预检剔除本机黑洞节点)${PLAIN}"
        echo -e "${DIV_BOLD}"
        echo -e "  当前策略 : ${CYAN}${cur_up}${PLAIN}"
        echo -e "${DIV_THIN}"
        echo -e "  ${GREEN}[1]${PLAIN} 全球自动优选 (Global)   : Quad9-ECS / CF / Google / DNS.SB / AdGuard"
        echo -e "  ${GREEN}[2]${PLAIN} 台湾本土优化 (Taiwan)   : HiNet / Google / CF / AdGuard + 换IP路由"
        echo -e "  ${GREEN}[3]${PLAIN} 亚太新港日组 (APAC)     : DNS.SB / AdGuard / 日本IIJ / CF / Google"
        echo -e "  ${GREEN}[4]${PLAIN} 欧洲纯IP专线 (Europe)   : Quad9-ECS / CF / Mullvad / DNS.SB"
        echo -e "  ${GREEN}[5]${PLAIN} 北美极速专线 (America)  : Quad9-ECS / CF / OpenDNS / ControlD"
        echo -e "  ${GREEN}[6]${PLAIN} 中国大陆优化 (Mainland) : 阿里DoH / 腾讯DNSPod / 360DoH 负载均衡"
        echo -e "  ${GREEN}[7]${PLAIN} 自定义上游源 (Custom)   : 手动输入主/备 DoH 或 DoT 加密地址"
        echo -e "  ${GREEN}[0]${PLAIN} 返回主菜单   (Back)"
        echo -e "${DIV_BOLD}"
        local up_opt mode="" c1="" c2=""
        read -rp "请选择策略编号 / Select strategy [0-7]: " up_opt </dev/tty
        up_opt=$(echo "$up_opt" | tr -d '[:space:]')
        [ -z "$up_opt" ] && continue

        case "$up_opt" in
            0) return 0 ;;
            1) mode="global" ;;
            2) mode="tw_opt" ;;
            3) mode="apac_opt" ;;
            4) mode="eu_opt" ;;
            5) mode="na_opt" ;;
            6) mode="cn_opt" ;;
            7)
                mode="custom"
                echo ""
                read -rp "  请输入主加密 DNS (留空取消，如 https://dns.hinet.net/dns-query): " c1 </dev/tty
                c1=$(echo "$c1" | tr -d '[:space:]')
                if [ -z "$c1" ]; then
                    echo -e "  ${YELLOW}[Info] 输入为空，已取消自定义配置。${PLAIN}"
                    sleep 1
                    continue
                fi
                read -rp "  请输入备加密 DNS (回车默认 https://94.140.14.140/dns-query): " c2 </dev/tty
                c2=$(echo "$c2" | tr -d '[:space:]')
                [ -z "$c2" ] && c2="https://94.140.14.140/dns-query"
                ;;
            *)
                echo -e "\n${RED}[Warn] 无效选项 '${up_opt}'，请输入 0-7 之间的数字！${PLAIN}"
                sleep 1
                continue
                ;;
        esac
        echo ""
        run_deploy_core "$mode" "$c1" "$c2" 0
        pause_submenu
    done
}

# 严格 76 列宽并发测速表 (零右侧溢出)
benchmark_global_upstreams() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}全球 12 节点 DoH 并发测速 (Warm = HTTP/2 复用 | Cold = 首次握手)${PLAIN}"
    echo -e "${DIV_THIN}"
    echo -e "  ${CYAN}Status    Provider        |  Warm  |  Cold  | 节点地区与特性${PLAIN}"
    echo -e "${DIV_THIN}"

    local need_resolve=0
    getent ahostsv4 example.com >/dev/null 2>&1 || need_resolve=1

    local nodes=(
        "Quad9 ECS|https://9.9.9.11/dns-query|全球纯IP+ECS (9.9.9.11)"
        "Cloudflare|https://1.1.1.1/dns-query|全球泛播 (1.1.1.1)"
        "Google ECS|https://8.8.8.8/dns-query|全球泛播+ECS (8.8.8.8)"
        "DNS.SB (xTom)|https://185.222.222.222/dns-query|欧亚骨干+ECS (185.222)"
        "Mullvad EU|https://194.242.2.2/dns-query|欧洲纯IP隐私 (194.242)"
        "OpenDNS Cisco|https://doh.opendns.com/dns-query|欧美骨干 (opendns.com)"
        "Control D (p0)|https://freedns.controld.com/p0|北美纯净 (controld.com)"
        "AdGuard Pure|https://94.140.14.140/dns-query|全球纯净+ECS (94.140)"
        "IIJ Japan|https://public.dns.iij.jp/dns-query|日本骨干网 (iij.jp)"
        "HiNet Taiwan|https://dns.hinet.net/dns-query|台湾中华电信 (hinet)"
        "TWNIC Quad101|https://101.101.101.101/dns-query|台湾官方 (限台IP访问)"
        "AliDNS China|https://223.5.5.5/dns-query|中国大陆阿里 (223.5)"
    )

    local tmp_dir="/tmp/doh_bench_$$"
    mkdir -p "$tmp_dir"

    local idx=0
    for item in "${nodes[@]}"; do
        idx=$((idx + 1))
        (
            IFS='|' read -r name url desc <<< "$item"
            local host rip res_arg=()
            host=$(echo "$url" | awk -F/ '{print $3}')
            if [ "$need_resolve" -eq 1 ] && ! echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                rip=$(doh_lookup_ip "$host")
                [ -n "$rip" ] && res_arg=(--resolve "${host}:443:${rip}")
            fi

            local out c1 t1 ec1 c2 t2 ec2 ms_cold ms_warm err_tag
            out=$(curl -4 --noproxy "*" -s "${res_arg[@]}" \
                --connect-timeout 2 --max-time 3.5 \
                -H "accept: application/dns-message" \
                -w "%{http_code} %{time_total} %{exitcode}\n" \
                -o /dev/null "${url}?dns=${Q_WIRE}" \
                -o /dev/null "${url}?dns=${Q_WIRE}" 2>/dev/null | tr -d '\000')

            read -r c1 t1 ec1 <<< "$(echo "$out" | sed -n '1p')"
            read -r c2 t2 ec2 <<< "$(echo "$out" | sed -n '2p')"

            if [ "$c1" = "200" ]; then
                ms_cold=$(awk -v t="${t1:-0}" 'BEGIN { m=int(t*1000+0.5); print (m<1?1:m) }')
                if [ "$c2" = "200" ]; then
                    ms_warm=$(awk -v t="${t2:-0}" 'BEGIN { m=int(t*1000+0.5); print (m<1?1:m) }')
                else
                    ms_warm="$ms_cold"
                fi
                printf "%05d|  ${GREEN}[200 OK]${PLAIN}  %-15s | ${GREEN}%4d ms${PLAIN} | %4d ms | %s\n" \
                    "$ms_warm" "$name" "$ms_warm" "$ms_cold" "$desc" > "${tmp_dir}/${idx}.res"
            else
                if [ "${ec1:-0}" = "6" ]; then
                    err_tag="[DNS ERR]"
                elif [ "$c1" = "000" ] || [ -z "$c1" ]; then
                    err_tag="[TIMEOUT]"
                else
                    err_tag=$(printf "[HTTP%3s]" "$c1")
                fi
                printf "99999|  ${RED}%-9s${PLAIN} %-15s |    -   |    -   | %s\n" \
                    "$err_tag" "$name" "$desc" > "${tmp_dir}/${idx}.res"
            fi
        ) &
    done
    wait

    cat "${tmp_dir}"/*.res 2>/dev/null | sort -n | cut -d'|' -f2-
    rm -rf "$tmp_dir"
    echo -e "${DIV_BOLD}"
}

# 严格 76 列宽双栈解析实测表
test_all_dns() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}本地系统 DNS 双栈解析实测 / Local DNS Resolution Test${PLAIN}"
    echo -e "${DIV_THIN}"
    for domain in "google.com" "cloudflare.com" "github.com"; do
        local t1 t2 ms v4 v6 v6_short=""
        t1=$(date +%s%3N)
        v4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -n1)
        t2=$(date +%s%3N)
        ms=$((t2 - t1))
        v6=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | head -n1)
        if [ -n "$v6" ]; then
            [ "${#v6}" -gt 22 ] && v6="${v6:0:20}.."
            v6_short="| ${v6}"
        fi
        if [ -n "$v4" ]; then
            printf "  ${GREEN}[OK]${PLAIN}  %-14s | %-15s | %3d ms %s\n" "$domain" "$v4" "$ms" "$v6_short"
        else
            printf "  ${RED}[ERR]${PLAIN} %-14s | Resolution Timeout (解析超时)\n" "$domain"
        fi
    done

    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        local dip d_res=""
        dip=$(get_docker_ip)
        if [ -n "$dip" ]; then
            if command -v dig >/dev/null 2>&1; then
                d_res=$(dig +short +time=2 +tries=1 @"${dip}" google.com A 2>/dev/null | head -n1)
            elif command -v nslookup >/dev/null 2>&1; then
                d_res=$(nslookup google.com "${dip}" 2>/dev/null | awk '/^Address: / { print $2 }' | head -n1)
            fi
            if [ -n "$d_res" ]; then
                printf "  ${GREEN}[OK]${PLAIN}  %-14s | %-15s | @%s:53\n" "Docker Bridge" "$d_res" "$dip"
            fi
        fi
    fi
    echo -e "${DIV_BOLD}"
}

audit_leaks() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}全盘 53 端口泄漏审计 / Port 53 Leak & Hardcoded DNS Audit${PLAIN}"
    echo -e "${DIV_THIN}"

    echo -e " ${YELLOW}[1] Docker 容器 DNS 检查 (Container DNS Check):${PLAIN}"
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "     ${GRAY}未安装 Docker，无需检查 (Docker not installed - Clean).${PLAIN}"
    elif [ -z "$(docker ps -q 2>/dev/null)" ]; then
        echo -e "     ${GRAY}当前无运行中的容器 (No running containers - Clean).${PLAIN}"
    else
        for c in $(docker ps -q); do
            local cname cdns ext
            cname=$(docker inspect -f '{{.Name}} ({{.HostConfig.NetworkMode}})' "$c" | sed 's#^/##')
            cdns=$(docker exec "$c" grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd "," -)
            ext=$(docker exec "$c" grep 'ExtServers' /etc/resolv.conf 2>/dev/null || true)
            printf "     - %-28s -> %s %s\n" "$cname" "${cdns:-未知}" "$ext"
        done
    fi

    echo -e "\n ${YELLOW}[2] 代理与系统配置明文 DNS 扫描 (Config Hardcoded DNS Scan):${PLAIN}"
    local hits
    hits=$(grep -rnE '1\.1\.1\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9|168\.95\.1\.1|139\.175\.|10\.30\.' \
        /etc/ /opt/ /root/ /usr/local/etc/ /var/lib/ 2>/dev/null \
        | grep -vE '/etc/easy-doh|/usr/local/bin/doh|edoh-isp-route|99-native-dot|\.bak|\.orig|hosts|resolv\.conf|journal|\.log|overlay2|https://|tls://|quic://' \
        | grep -E '\.(json|yaml|yml|toml|conf|ini|service):' | head -n 20 || true)
    if [ -z "$hits" ]; then
        echo -e "     ${GREEN}[OK] 未发现写死明文公共 53 DNS 的配置文件！${PLAIN}"
    else
        echo -e "${hits}" | cut -c1-70 | sed 's/^/     /'
    fi

    echo -e "\n ${YELLOW}[3] 实时外部 53 端口连接抓捕 (Live Outbound Port 53 Sockets):${PLAIN}"
    local live_53
    live_53=$(ss -tunap 2>/dev/null | awk '$5 ~ /:53$/ && $5 !~ /127\.0\.0\.|172\.17\.0\.1|\*:53|0\.0\.0\.0:53|\[::\]:53/' || true)
    if [ -z "$live_53" ]; then
        echo -e "     ${GREEN}[OK] 完美！当前没有任何进程向公网 53 端口发起连接。${PLAIN}"
    else
        echo -e "${RED}${live_53}${PLAIN}" | sed 's/^/     /'
    fi
    echo -e "${DIV_BOLD}"
}

show_live_logs() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}当前实例运行日志 / Current Service Instance Logs${PLAIN}"
    echo -e "${DIV_THIN}"
    if systemctl is-active --quiet easy-doh; then
        local inv_id
        inv_id=$(systemctl show easy-doh -p InvocationID --value 2>/dev/null)
        if [ -n "$inv_id" ]; then
            journalctl _SYSTEMD_INVOCATION_ID="$inv_id" -n 30 --no-pager
        else
            journalctl -u easy-doh -n 25 --no-pager
        fi
    else
        echo -e "  ${GRAY}当前服务未运行 (Service is currently stopped).${PLAIN}"
    fi
    echo -e "${DIV_BOLD}"
}

toggle_resolv_lock() {
    if [ -L /etc/resolv.conf ]; then
        echo -e "\n${YELLOW}[Info] 当前 /etc/resolv.conf 为符号链接 (原生 DoT 模式)，不支持 chattr 加锁。${PLAIN}"
        return 0
    fi
    if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        echo -e "\n${YELLOW}[OK] 已解锁 /etc/resolv.conf，现在可手动编辑该文件。${PLAIN}"
    else
        chattr +i /etc/resolv.conf 2>/dev/null || true
        echo -e "\n${GREEN}[OK] 已开启 /etc/resolv.conf 防篡改锁定 (+i)！${PLAIN}"
    fi
}

update_self_and_core() {
    while true; do
        local cur_bin="未安装"
        [ -x "$BIN_PATH" ] && cur_bin=$("$BIN_PATH" --version 2>/dev/null | awk '{print $NF}')

        clear
        echo -e "${DIV_BOLD}"
        echo -e " ${CYAN}在线无损更新 / Lossless Update (Script + dnsproxy Core)${PLAIN}"
        echo -e "${DIV_BOLD}"
        echo -e "  当前脚本 : ${CYAN}v${VERSION}${PLAIN} (${GH_REPO})  |  当前内核 : ${CYAN}${cur_bin}${PLAIN}"
        echo -e "${DIV_THIN}"
        echo -e "  ${GREEN}[1]${PLAIN} 仅更新管理脚本 (${GH_REPO}) [GitHub 主源 + Cloudflare 回退]"
        echo -e "  ${GREEN}[2]${PLAIN} 仅检查并更新 AdGuard dnsproxy 内核二进制 (平滑热重启)"
        echo -e "  ${GREEN}[3]${PLAIN} 同时更新管理脚本 + dnsproxy 内核"
        echo -e "  ${GREEN}[0]${PLAIN} 返回主菜单 (Back)"
        echo -e "${DIV_BOLD}"
        local u_opt
        read -rp "请选择更新项 / Select option [0-3]: " u_opt </dev/tty
        u_opt=$(echo "$u_opt" | tr -d '[:space:]')
        [ -z "$u_opt" ] && continue

        case "$u_opt" in
            0) return 0 ;;
            1|2|3)
                echo ""
                if [[ "$u_opt" = "2" || "$u_opt" = "3" ]]; then
                    local old_bin_ver="" new_bin_ver=""
                    [ -x "$BIN_PATH" ] && old_bin_ver=$("$BIN_PATH" --version 2>/dev/null | awk '{print $NF}')
                    if install_binary 1; then
                        new_bin_ver=$("$BIN_PATH" --version 2>/dev/null | awk '{print $NF}')
                        if [ "$old_bin_ver" != "$new_bin_ver" ] && systemctl is-active --quiet easy-doh; then
                            systemctl restart easy-doh
                            echo -e "${GREEN}  -> 已平滑重启服务应用新内核 (${new_bin_ver})！${PLAIN}"
                        fi
                    fi
                fi

                if [[ "$u_opt" = "1" || "$u_opt" = "3" ]]; then
                    echo -e "${CYAN}  -> 正在从远程仓库 (${GH_REPO}) 拉取最新 doh.sh ...${PLAIN}"
                    if fetch_remote_script "${SCRIPT_PATH}.new"; then
                        local remote_ver
                        remote_ver=$(grep -m1 '^VERSION=' "${SCRIPT_PATH}.new" | cut -d'"' -f2)
                        mv -f "${SCRIPT_PATH}.new" "$SCRIPT_PATH"
                        chmod +x "$SCRIPT_PATH"
                        echo -e "${GREEN}  -> 脚本已更新 (v${VERSION} -> v${remote_ver:-latest})！按回车重载新面板...${PLAIN}"
                        read -rp "" _ </dev/tty
                        exec "$SCRIPT_PATH" </dev/tty
                    else
                        rm -f "${SCRIPT_PATH}.new"
                        echo -e "${RED}[Warn] 远程拉取失败（请确认仓库 ${GH_REPO} 已设为 Public）。${PLAIN}"
                    fi
                fi
                pause_submenu
                ;;
            *)
                echo -e "\n${RED}[Warn] 无效选项 '${u_opt}'，请输入 0-3 之间的数字！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

purge_core() {
    local remove_self="${1:-0}"

    echo -e "\n${CYAN}[1/4] 停止并移除加密 DNS 守护进程、换 IP 路由服务与历史日志...${PLAIN}"
    systemctl stop easy-doh 2>/dev/null || true
    systemctl disable easy-doh 2>/dev/null || true
    systemctl stop edoh-isp-route 2>/dev/null || true
    systemctl disable edoh-isp-route 2>/dev/null || true
    systemctl stop doh-proxy 2>/dev/null || true
    systemctl disable doh-proxy 2>/dev/null || true
    for aip in "${ISP_API_IPS[@]}"; do
        ip route del "${aip}/32" 2>/dev/null || true
    done
    rm -f "$SERVICE_FILE" "$ROUTE_SERVICE" /etc/systemd/system/doh-proxy.service /etc/default/doh-proxy
    rm -f /etc/systemd/resolved.conf.d/99-easy-doh.conf \
          /etc/systemd/resolved.conf.d/99-native-dot.conf \
          /etc/systemd/resolved.conf.d/nodnsstub.conf
    systemctl daemon-reload
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=1s --unit=easy-doh >/dev/null 2>&1 || true

    echo -e "${CYAN}[2/4] 恢复初始 /etc/resolv.conf 并解除防篡改锁...${PLAIN}"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    if [ -f "${WORK_DIR}/resolv.symlink" ]; then
        local sym_target
        sym_target=$(cat "${WORK_DIR}/resolv.symlink")
        rm -f /etc/resolv.conf
        ln -sf "$sym_target" /etc/resolv.conf
    elif [ -f "${WORK_DIR}/resolv.conf.orig" ]; then
        rm -f /etc/resolv.conf
        cp -f "${WORK_DIR}/resolv.conf.orig" /etc/resolv.conf
    elif [ -f /etc/resolv.conf.doh.bak ]; then
        mv -f /etc/resolv.conf.doh.bak /etc/resolv.conf
    elif systemctl list-unit-files 2>/dev/null | grep -q "systemd-resolved"; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
    systemctl is-enabled --quiet systemd-resolved 2>/dev/null && systemctl restart systemd-resolved 2>/dev/null || true

    echo -e "${CYAN}[3/4] 清理 Docker 网桥注入规则与防火墙策略...${PLAIN}"
    revert_docker_dns

    echo -e "${CYAN}[4/4] 彻底清空所有备份归档、缓存状态与二进制内核...${PLAIN}"
    rm -rf "$WORK_DIR"
    rm -f "$BIN_PATH" "${BIN_PATH}.new" /etc/resolv.conf.doh.bak /tmp/doh_bench_*
    invalidate_ip_cache

    if [ "$remove_self" -eq 1 ]; then
        rm -f "$SCRIPT_PATH" "${SCRIPT_PATH}.new" "${SCRIPT_PATH}.tmp"
        echo -e "\n${GREEN}[OK] 已完成 100% 零残留彻底卸载（含备份、路由、内核与 doh 命令）！${PLAIN}\n"
        exit 0
    else
        echo -e "\n${GREEN}[OK] 服务、内核、路由与全部历史备份已清空！(仅保留 doh 命令)${PLAIN}"
    fi
}

uninstall_all() {
    while true; do
        clear
        echo -e "${DIV_BOLD}"
        echo -e " ${CYAN}彻底卸载与无痕清理 / Complete Uninstall & Zero-Trace Purge${PLAIN}"
        echo -e "${DIV_BOLD}"
        echo -e "  ${YELLOW}[1]${PLAIN} 卸载服务 + 还原 DNS + ${RED}清空所有备份/路由/内核${PLAIN} (保留 doh 命令)"
        echo -e "  ${RED}[2]${PLAIN} 100% 零残留彻底抹除 (${RED}连同 /usr/local/bin/doh 一起自毁删除${PLAIN})"
        echo -e "  ${GREEN}[0]${PLAIN} 返回主菜单 (Back)"
        echo -e "${DIV_BOLD}"
        local u_mode confirm_yn
        read -rp "请选择清理级别 / Select purge level [0-2]: " u_mode </dev/tty
        u_mode=$(echo "$u_mode" | tr -d '[:space:]')
        [ -z "$u_mode" ] && continue

        case "$u_mode" in
            0) return 0 ;;
            1)
                read -rp "  确认卸载服务并清空所有备份与路由吗？[y/N]: " confirm_yn </dev/tty
                if [[ "$confirm_yn" =~ ^[Yy]$ ]]; then
                    purge_core 0
                    pause_submenu
                else
                    echo -e "  ${GRAY}已取消执行。${PLAIN}"
                    sleep 1
                fi
                ;;
            2)
                read -rp "  确认 100% 零残留彻底抹除 (含删除 doh 脚本本身) 吗？[y/N]: " confirm_yn </dev/tty
                if [[ "$confirm_yn" =~ ^[Yy]$ ]]; then
                    purge_core 1
                else
                    echo -e "  ${GRAY}已取消执行。${PLAIN}"
                    sleep 1
                fi
                ;;
            *)
                echo -e "\n${RED}[Warn] 无效选项 '${u_mode}'，请输入 0-2 之间的数字！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 76 列双栏对称紧凑看板 (所有状态行与双栏菜单严格 <= 75 列，永不超出边界)
render_menu() {
    refresh_ip_cache 0

    # 1. 公网 IPv4 + NAT 识别 + IPv6 状态
    local ip_str=""
    if [ "$CACHED_PUB_V4" = "获取超时" ]; then
        ip_str="${RED}获取超时${PLAIN}${CACHED_LOCAL_V4:+ (网卡: $CACHED_LOCAL_V4)}"
    elif [ -n "$CACHED_LOCAL_V4" ] && [ "$CACHED_LOCAL_V4" != "$CACHED_PUB_V4" ]; then
        ip_str="${GREEN}${CACHED_PUB_V4}${PLAIN} ${GRAY}(NAT: ${CACHED_LOCAL_V4})${PLAIN}"
    else
        ip_str="${GREEN}${CACHED_PUB_V4}${PLAIN} ${GRAY}(Direct 直连)${PLAIN}"
    fi

    # 2. 引擎与监听端点
    local eng_str="${RED}Stopped (未运行)${PLAIN}"
    local listen_str="N/A"
    if systemctl is-active --quiet easy-doh; then
        local bin_ver=""
        [ -x "$BIN_PATH" ] && bin_ver=$("$BIN_PATH" --version 2>/dev/null | awk '{print $NF}')
        eng_str="${GREEN}Active (dnsproxy ${bin_ver})${PLAIN}"
        local addrs
        addrs=$(grep -A3 'listen-addrs:' "$CONF_FILE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd "," -)
        listen_str="${addrs:-127.0.0.1}:53 (TCP+UDP)"
    elif [ -f /etc/systemd/resolved.conf.d/99-native-dot.conf ] && systemctl is-active --quiet systemd-resolved; then
        eng_str="${GREEN}Active (Native DoT 853)${PLAIN}"
        listen_str="127.0.0.53:53 (TCP+UDP)"
    fi

    # 3. 上游策略限宽截断保护
    local up_str="None (未部署)"
    [ -f "$STATE_FILE" ] && up_str=$(cat "$STATE_FILE")
    [ "${#up_str}" -gt 52 ] && up_str="${up_str:0:49}..."

    # 4. 紧凑三合一防护徽章 (DNS 锁 + Docker 防护 + 换 IP 路由)
    local b_lock="${YELLOW}未锁${PLAIN}"
    if [ ! -L /etc/resolv.conf ] && lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        b_lock="${GREEN}已锁+i${PLAIN}"
    fi

    local b_dk="${GRAY}未装${PLAIN}"
    if command -v docker >/dev/null 2>&1; then
        local dip
        dip=$(get_docker_ip)
        if grep -q "${dip:-172.17.0.1}" "$DOCKER_DAEMON" 2>/dev/null; then
            b_dk="${GREEN}已保护${PLAIN}"
        else
            b_dk="${YELLOW}待修复${PLAIN}"
        fi
    fi

    local b_rt="${GRAY}未启用${PLAIN}"
    local rt_line
    rt_line=$(ip -4 route show 100.100.101.101/32 2>/dev/null | head -n1)
    if echo "$rt_line" | grep -q "via "; then
        b_rt="${GREEN}已挂载${PLAIN}"
    elif [ -n "$rt_line" ]; then
        b_rt="${YELLOW}异常->按3${PLAIN}"
    fi

    local bak_cnt=0
    [ -d "$BACKUP_DIR" ] && bak_cnt=$(ls -1 "${BACKUP_DIR}"/dns_bak_*.tar.gz 2>/dev/null | wc -l)

    clear
    echo -e "${DIV_BOLD}"
    echo -e "  ${CYAN}E-Doh Manager v${VERSION}${PLAIN}  |  本地加密 DNS 与网络路由看板  (快捷命令: ${GREEN}doh${PLAIN})"
    echo -e "${DIV_BOLD}"
    echo -e "  公网地址 Public IP : ${ip_str} | ${CACHED_V6_STATE}"
    echo -e "  运行引擎 Engine    : ${eng_str}  [备份: ${bak_cnt}/3]"
    echo -e "  监听端点 Listen    : ${listen_str}"
    echo -e "  上游策略 Upstream  : ${CYAN}${up_str}${PLAIN}"
    echo -e "  系统防护 Guards    : DNS锁[${b_lock}] | Docker[${b_dk}] | 换IP路由[${b_rt}]"
    echo -e "${DIV_THIN}"
    echo -e "  ${GREEN}[1]${PLAIN} 安装/切换地区 DoH 策略          ${GREEN}[7]${PLAIN}  全盘扫描 53 端口泄漏"
    echo -e "  ${GREEN}[2]${PLAIN} 系统原生 DoT 急救模式           ${GREEN}[8]${PLAIN}  查看当前服务运行日志"
    echo -e "  ${GREEN}[3]${PLAIN} TW 动态换 IP 与内网路由         ${GREEN}[9]${PLAIN}  切换 DNS 防篡改锁 (+i)"
    echo -e "  ${GREEN}[4]${PLAIN} 修复 Docker 容器 DNS 泄漏       ${GREEN}[10]${PLAIN} 在线无损更新脚本与内核"
    echo -e "  ${GREEN}[5]${PLAIN} 实测本地 DNS 双栈解析           ${GREEN}[11]${PLAIN} 彻底卸载并清空全部备份"
    echo -e "  ${GREEN}[6]${PLAIN} 全球 12 节点 DoH 并发测速       ${GREEN}[R]${PLAIN}  强制刷新本机公网 IP"
    echo -e "${DIV_THIN}"
    echo -e "  ${GREEN}[0]${PLAIN} 退出管理面板 (Exit)"
    echo -e "${DIV_BOLD}"
}

case "${1:-}" in
    --auto)
        cp -f "$0" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH"
        run_deploy_core "${2:-global}" "" "" 1
        exit $?
        ;;
    --route-isp)
        enable_isp_route && test_isp_api_port
        exit $?
        ;;
    --changeip)
        trigger_isp_changeip
        exit $?
        ;;
    --purge)
        purge_core 1
        ;;
    --test)
        test_all_dns
        exit 0
        ;;
    --audit)
        audit_leaks
        exit 0
        ;;
esac

bootstrap_self "$@"
read -t 0.1 -n 10000 _discard 2>/dev/null || true

while true; do
    render_menu
    read -rp "请输入选项编号 / Select option [0-11, R]: " choice </dev/tty
    choice=$(echo "$choice" | tr -d '[:space:]')
    [ -z "$choice" ] && continue

    case "$choice" in
        1) deploy_doh_wizard ;;
        2) enable_native_dot; pause_return ;;
        3) manage_isp_changeip ;;
        4) echo ""; fix_docker_dns 0; pause_return ;;
        5) test_all_dns; pause_return ;;
        6) benchmark_global_upstreams; pause_return ;;
        7) audit_leaks; pause_return ;;
        8) show_live_logs; pause_return ;;
        9) toggle_resolv_lock; pause_return ;;
        10) update_self_and_core ;;
        11) uninstall_all ;;
        r|R)
            echo -ne "\n${CYAN}  -> 正在重新探测本机真实出口公网 IPv4 ...${PLAIN}"
            refresh_ip_cache 1
            echo -e " ${GREEN}${CACHED_PUB_V4}${PLAIN}"
            sleep 0.6
            ;;
        0) echo ""; exit 0 ;;
        *)
            echo -e "\n${RED}[Warn] 无效选项 '${choice}'，请输入 0-11 或 R！${PLAIN}"
            sleep 1
            ;;
    esac
done
EOF
chmod +x /usr/local/bin/doh && doh
