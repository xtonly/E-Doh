#!/usr/bin/env bash
# ==============================================================================
# Project   : E-Doh Manager (v3.0 Release)
# Repo      : https://github.com/xtonly/E-Doh
# Features  : Dead-Node Auto-Prune | Multi-API Bootstrap | Docker Guard | Purge
# Usage     : Interactive -> doh | CLI -> doh --auto [global|tw|apac|eu|na|cn] | doh --purge
# ==============================================================================

VERSION="3.0"
GH_REPO="xtonly/E-Doh"
GH_BRANCH="main"
SCRIPT_PATH="/usr/local/bin/doh"

# 多源回退链：GitHub Raw 主源优先 -> Cloudflare CDN 次选 -> Fastly / Global jsDelivr 兜底
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
DOCKER_DAEMON="/etc/docker/daemon.json"

# 标准 RFC 8484 Wireformat 查询串 (example.com IN A)
Q_WIRE="AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"

DIV_BOLD="${CYAN}========================================================================${PLAIN}"
DIV_THIN="${GRAY}------------------------------------------------------------------------${PLAIN}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[Error] 请使用 root 权限运行 (Please run as root: sudo doh)${PLAIN}"
    exit 1
fi

# 多路纯 IP DoH 容灾解析 (防 1.1.1.1 / 8.8.8.8 被黑洞的环境)
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
        ip=$(curl -4 -ksL --connect-timeout 2 --max-time 3 -H "accept: application/dns-json" "${api}?name=${domain}&type=A" \
            | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -n1 | cut -d'"' -f4)
        [ -n "$ip" ] && break
    done
    echo "$ip"
}

# 快速探测单个 DoH 节点是否存活
probe_doh_alive() {
    local url="$1" b_ip="${2:-}" host rip res_arg=() code
    host=$(echo "$url" | awk -F/ '{print $3}')
    if ! echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if [ -n "$b_ip" ]; then
            rip=$(curl -4 -ksL --connect-timeout 2 --max-time 3 -H "accept: application/dns-json" \
                "https://${b_ip}/dns-query?name=${host}&type=A" 2>/dev/null \
                | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -n1 | cut -d'"' -f4)
        fi
        [ -z "$rip" ] && rip=$(doh_lookup_ip "$host")
        [ -n "$rip" ] && res_arg=(--resolve "${host}:443:${rip}")
    fi

    code=$(curl -4 -s -o /dev/null "${res_arg[@]}" --connect-timeout 1.5 --max-time 2.5 \
        -H "accept: application/dns-message" -w "%{http_code}" "${url}?dns=${Q_WIRE}" 2>/dev/null | tr -d '\000')
    [ "$code" = "200" ]
}

# 自动优选本机存活的单一纯 IP Bootstrap
pick_best_bootstrap() {
    local prefer="$1"
    local candidates=("$prefer" "101.101.101.101" "94.140.14.140" "185.222.222.222" "8.8.8.8" "1.1.1.1" "223.5.5.5")
    local seen="" ip code
    for ip in "${candidates[@]}"; do
        [ -z "$ip" ] && continue
        [[ "$seen" == *"|$ip|"* ]] && continue
        seen="${seen}|${ip}|"
        code=$(curl -4 -s -o /dev/null --connect-timeout 1.2 --max-time 2 \
            -H "accept: application/dns-message" -w "%{http_code}" \
            "https://${ip}/dns-query?dns=${Q_WIRE}" 2>/dev/null | tr -d '\000')
        if [ "$code" = "200" ]; then
            echo "$ip"
            return 0
        fi
    done
    echo "94.140.14.140"
}

# 支持免 DNS 环境拉取远程脚本 (GitHub 主源附带防缓存参数，失败自动切换 Cloudflare jsDelivr)
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

        if curl -4 -fsSL "${res_arg[@]}" -H "Cache-Control: no-cache" --connect-timeout 5 --max-time 15 "$fetch_url" -o "$target" 2>/dev/null; then
            if grep -qE "(E-Doh|Easy-DoH) Manager" "$target" 2>/dev/null; then
                echo -e "${GRAY}  -> 成功命中源 (Source): ${host}${PLAIN}"
                return 0
            fi
        fi
    done
    return 1
}

bootstrap_self() {
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
    elif [ "$(realpath "$0" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
        cp -f "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi
}

pause_return() {
    echo ""
    read -rp "按回车键返回主菜单 / Press Enter to return..." _ </dev/tty
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

    ver=$(curl -4 -ksL --connect-timeout 6 --resolve "api.github.com:443:${api_ip}" \
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
    curl -4 -kL -# --connect-timeout 15 --retry 2 \
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
    local mode="${1:-global}" custom_u1="$2" custom_u2="$3" dip
    dip=$(get_docker_ip)

    local group_label="" pref_boot="8.8.8.8" candidates=()
    case "$mode" in
        tw|tw_opt)
            group_label="TW Local"
            pref_boot="101.101.101.101"
            candidates=(
                "TWNIC|https://101.101.101.101/dns-query"
                "HiNet|https://dns.hinet.net/dns-query"
                "AdGuard|https://94.140.14.140/dns-query"
                "DNS.SB|https://185.222.222.222/dns-query"
                "Google|https://8.8.8.8/dns-query"
                "CF|https://1.1.1.1/dns-query"
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
            group_label="Europe Pure-IP"
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
            group_label="North America"
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
            group_label="CN Mainland"
            pref_boot="223.5.5.5"
            candidates=(
                "AliDNS-1|https://223.5.5.5/dns-query"
                "AliDNS-2|https://223.6.6.6/dns-query"
                "DNSPod|https://doh.pub/dns-query"
                "360DoH|https://doh.360.cn/dns-query"
            )
            ;;
        custom)
            group_label="Custom DoH"
            pref_boot="101.101.101.101"
            candidates=(
                "Primary|${custom_u1}"
                "Secondary|${custom_u2}"
            )
            ;;
        *)
            group_label="Global Auto"
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

    if [ ${#dead_names[@]} -gt 0 ]; then
        echo -e "${YELLOW}  -> [避坑] 已自动剔除本机超时的黑洞节点: $(IFS=', '; echo "${dead_names[*]}")${PLAIN}"
    fi

    if [ ${#alive_urls[@]} -eq 0 ]; then
        alive_urls=("https://${boot_ip}/dns-query")
        alive_names=("Fallback-${boot_ip}")
    fi

    local joined_names
    joined_names=$(IFS=' + '; echo "${alive_names[*]}")
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
        echo -e "${RED}[Error] 服务启动失败，请按 [7] 查看运行日志！${PLAIN}"
        return 1
    fi

    chattr -i /etc/resolv.conf 2>/dev/null
    save_orig_resolv
    rm -f /etc/resolv.conf
    cat << 'R_EOF' > /etc/resolv.conf
# Managed by E-Doh (TCP+UDP 53 -> DoH/DoT)
nameserver 127.0.0.1
options edns0 trust-ad timeout:2 attempts:2
R_EOF
    chattr +i /etc/resolv.conf 2>/dev/null
    echo -e "${GREEN}  -> 系统 /etc/resolv.conf 已接管并开启防篡改锁 (+i)。${PLAIN}"
    return 0
}

fix_docker_dns() {
    local silent_mode="${1:-0}"
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${GRAY}  -> 当前机器未安装 Docker，自动跳过容器避坑配置 (Skipped).${PLAIN}"
        return 0
    fi

    local dip reload_dk="y"
    dip=$(get_docker_ip)
    [ -z "$dip" ] && dip="172.17.0.1"

    echo -e "${CYAN}  -> 检测到 Docker，正在注入网桥 DNS (${dip}) 防回退 8.8.8.8...${PLAIN}"
    backup_configs
    mkdir -p /etc/docker
    echo "$dip" > "${WORK_DIR}/docker_ip.state"

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow in on docker0 to any port 53 >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -i docker0 -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i docker0 -p udp --dport 53 -j ACCEPT 2>/dev/null
        iptables -C INPUT -i docker0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i docker0 -p tcp --dport 53 -j ACCEPT 2>/dev/null
    fi

    if command -v python3 >/dev/null 2>&1; then
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
    elif [ ! -s "$DOCKER_DAEMON" ]; then
        printf '{\n  "dns": ["%s"]\n}\n' "$dip" > "$DOCKER_DAEMON"
    else
        echo -e "${YELLOW}[Warn] 请手动在 ${DOCKER_DAEMON} 中加入 \"dns\": [\"${dip}\"]${PLAIN}"
        return 0
    fi

    if [ -f "$CONF_FILE" ] && ! grep -q "$dip" "$CONF_FILE"; then
        sed -i "/listen-addrs:/a \  - \"${dip}\"" "$CONF_FILE"
        systemctl restart easy-doh
    fi

    if [ "$silent_mode" -eq 0 ]; then
        read -rp "  -> 是否立即重启 Docker 使容器生效？(Restart Docker now?) [Y/n]: " reload_dk </dev/tty
    fi
    if [[ ! "$reload_dk" =~ ^[Nn]$ ]]; then
        systemctl restart docker
        systemctl restart easy-doh
        echo -e "${GREEN}  -> Docker 容器 DNS 通道已打通 (${dip}:53 -> DoH)！${PLAIN}"
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
        if command -v python3 >/dev/null 2>&1; then
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
    systemctl stop easy-doh 2>/dev/null
    systemctl disable easy-doh 2>/dev/null
    rm -f /etc/systemd/resolved.conf.d/99-easy-doh.conf

    mkdir -p /etc/systemd/resolved.conf.d
    cat << 'DOT_EOF' > /etc/systemd/resolved.conf.d/99-native-dot.conf
[Resolve]
DNS=101.101.101.101#dns.twnic.tw 94.140.14.140#unfiltered.adguard-dns.com 185.222.222.222#dns.sb
FallbackDNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
DNSOverTLS=yes
DNSStubListener=yes
Cache=yes
DOT_EOF
    echo "Native DoT (853 TLS)" > "$STATE_FILE"
    systemctl enable --now systemd-resolved >/dev/null 2>&1
    systemctl restart systemd-resolved

    chattr -i /etc/resolv.conf 2>/dev/null
    save_orig_resolv
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

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

    echo -e "${CYAN}[4/4] 检查 Docker 环境...${PLAIN}"
    fix_docker_dns "$silent"
    test_all_dns
}

deploy_doh_wizard() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}选择分地区加密 DNS 负载均衡组 (自动预检剔除本机不可达节点)${PLAIN}"
    echo -e "${DIV_THIN}"
    echo -e "  ${GREEN}[1]${PLAIN} 全球自动优选组 (Global Auto)   : Quad9-ECS + CF + Google + DNS.SB + AdGuard [默认]"
    echo -e "  ${GREEN}[2]${PLAIN} 台湾本土流媒体 (Taiwan Local)  : TWNIC(101.101) + HiNet + AdGuard + DNS.SB"
    echo -e "  ${GREEN}[3]${PLAIN} 亚太新港日优化 (HK / JP / SG)  : DNS.SB + AdGuard + 日本IIJ + CF + Google"
    echo -e "  ${GREEN}[4]${PLAIN} 欧洲纯 IP 专线 (UK / DE / NL)  : Quad9-ECS + CF + Mullvad(194.242) + DNS.SB"
    echo -e "  ${GREEN}[5]${PLAIN} 北美专线极速组 (US / CA)       : Quad9-ECS + CF + OpenDNS + ControlD(p0)"
    echo -e "  ${GREEN}[6]${PLAIN} 中国大陆防限速 (CN Mainland)   : 阿里DoH + 腾讯doh.pub + 360DoH 负载均衡"
    echo -e "  ${GREEN}[7]${PLAIN} 自定义加密上游 (Custom URL)    : 手动输入主/备 DoH 或 DoT 地址"
    echo -e "${DIV_THIN}"
    local up_opt mode="global" c1="" c2=""
    read -rp "请选择策略 [1-7, 回车默认 1]: " up_opt </dev/tty
    up_opt=$(echo "$up_opt" | tr -d '[:space:]')
    case "$up_opt" in
        2) mode="tw_opt" ;;
        3) mode="apac_opt" ;;
        4) mode="eu_opt" ;;
        5) mode="na_opt" ;;
        6) mode="cn_opt" ;;
        7)
            mode="custom"
            read -rp "  请输入主加密 DNS (如 https://101.101.101.101/dns-query): " c1 </dev/tty
            [ -z "$c1" ] && echo -e "${YELLOW}输入为空，已取消。${PLAIN}" && return 0
            read -rp "  请输入备加密 DNS (回车默认 https://94.140.14.140/dns-query): " c2 </dev/tty
            [ -z "$c2" ] && c2="https://94.140.14.140/dns-query"
            ;;
        *) mode="global" ;;
    esac
    echo ""
    run_deploy_core "$mode" "$c1" "$c2" 0
}

benchmark_global_upstreams() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}全球 12 大主流 DoH 并发测速 / Global DoH Speedtest (HTTPS 443 IPv4)${PLAIN}"
    echo -e " ${GRAY}指标: Warm = HTTP/2 连接复用真实解析耗时 | Cold = 首次 TCP+TLS 握手总耗时${PLAIN}"
    echo -e "${DIV_THIN}"
    echo -e "  ${CYAN}Status     Provider           | Warm    | Cold    | Region / 节点特性${PLAIN}"
    echo -e "${DIV_THIN}"

    local need_resolve=0
    getent ahostsv4 example.com >/dev/null 2>&1 || need_resolve=1

    local nodes=(
        "Quad9 ECS|https://9.9.9.11/dns-query|欧美/全球纯IP + ECS (9.9.9.11)"
        "Cloudflare|https://1.1.1.1/dns-query|全球泛播 Anycast (1.1.1.1)"
        "Google ECS|https://8.8.8.8/dns-query|全球泛播 + ECS (8.8.8.8)"
        "DNS.SB (xTom)|https://185.222.222.222/dns-query|欧/亚太骨干 + ECS (185.222)"
        "Mullvad Europe|https://194.242.2.2/dns-query|欧洲纯IP高隐私 (194.242.2.2)"
        "OpenDNS Cisco|https://doh.opendns.com/dns-query|北美/欧洲骨干网 (opendns.com)"
        "Control D (p0)|https://freedns.controld.com/p0|北美/全球纯净版 (controld.com)"
        "AdGuard Pure|https://94.140.14.140/dns-query|全球无过滤 + ECS (94.140.14.140)"
        "IIJ Japan|https://public.dns.iij.jp/dns-query|日本本土骨干网 (iij.jp)"
        "HiNet Taiwan|https://dns.hinet.net/dns-query|台湾中华电信 (dns.hinet.net)"
        "TWNIC Quad101|https://101.101.101.101/dns-query|台湾官方原生 (限台湾IP访问)"
        "AliDNS China|https://223.5.5.5/dns-query|中国大陆阿里云 (223.5.5.5)"
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
            out=$(curl -4 -s "${res_arg[@]}" \
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
                printf "%05d|  ${GREEN}[200 OK] ${PLAIN}  %-16s | ${GREEN}%4d ms${PLAIN} | %4d ms | %s\n" \
                    "$ms_warm" "$name" "$ms_warm" "$ms_cold" "$desc" > "${tmp_dir}/${idx}.res"
            else
                if [ "${ec1:-0}" = "6" ]; then
                    err_tag="[DNS ERR]"
                elif [ "$c1" = "000" ] || [ -z "$c1" ]; then
                    err_tag="[TIMEOUT]"
                else
                    err_tag=$(printf "[HTTP%3s]" "$c1")
                fi
                printf "99999|  ${RED}%-9s${PLAIN}  %-16s |    -    |    -    | %s\n" \
                    "$err_tag" "$name" "$desc" > "${tmp_dir}/${idx}.res"
            fi
        ) &
    done
    wait

    cat "${tmp_dir}"/*.res 2>/dev/null | sort -n | cut -d'|' -f2-
    rm -rf "$tmp_dir"
    echo -e "${DIV_BOLD}"
}

test_all_dns() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}本地系统 DNS 解析实测 / Local DNS Resolution Test (IPv4 & IPv6)${PLAIN}"
    echo -e "${DIV_THIN}"
    for domain in "google.com" "cloudflare.com" "github.com"; do
        local t1 t2 ms v4 v6
        t1=$(date +%s%3N)
        v4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -n1)
        t2=$(date +%s%3N)
        ms=$((t2 - t1))
        v6=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | head -n1)
        if [ -n "$v4" ]; then
            printf "  ${GREEN}[OK]${PLAIN}   %-15s | %-15s | %3d ms %s\n" "$domain" "$v4" "$ms" "${v6:+| IPv6: $v6}"
        else
            printf "  ${RED}[FAIL]${PLAIN} %-15s | Resolution Timeout (解析超时)\n" "$domain"
        fi
    done

    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        local dip d_res
        dip=$(get_docker_ip)
        if [ -n "$dip" ]; then
            if command -v dig >/dev/null 2>&1; then
                d_res=$(dig +short +time=2 +tries=1 @"${dip}" google.com A 2>/dev/null | head -n1)
            elif command -v nslookup >/dev/null 2>&1; then
                d_res=$(nslookup google.com "${dip}" 2>/dev/null | awk '/^Address: / { print $2 }' | head -n1)
            fi
            if [ -n "$d_res" ]; then
                echo -e "  ${GREEN}[OK]${PLAIN}   Docker Bridge   | @${dip}:53 -> ${d_res}"
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
            printf "     - %-30s -> %s %s\n" "$cname" "${cdns:-未知}" "$ext"
        done
    fi

    echo -e "\n ${YELLOW}[2] 代理与系统配置明文 DNS 扫描 (Config Hardcoded DNS Scan):${PLAIN}"
    local hits
    hits=$(grep -rnE '1\.1\.1\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9|168\.95\.1\.1|139\.175\.|10\.30\.' \
        /etc/ /opt/ /root/ /usr/local/etc/ /var/lib/ 2>/dev/null \
        | grep -vE '/etc/easy-doh|/usr/local/bin/doh|99-native-dot|\.bak|\.orig|hosts|resolv\.conf|journal|\.log|overlay2|https://|tls://|quic://' \
        | grep -E '\.(json|yaml|yml|toml|conf|ini|service):' | head -n 20 || true)
    if [ -z "$hits" ]; then
        echo -e "     ${GREEN}[OK] 未发现写死明文公共 53 DNS 的配置文件！${PLAIN}"
    else
        echo -e "${hits}" | sed 's/^/     /'
    fi

    echo -e "\n ${YELLOW}[3] 实时外部 53 端口连接抓捕 (Live Outbound Port 53 Sockets):${PLAIN}"
    local live_53
    live_53=$(ss -tunap 2>/dev/null | awk '$5 ~ /:53$/ && $5 !~ /127\.0\.0\.|172\.17\.0\.1|\*:53|0\.0\.0\.0:53|\[::\]:53/' || true)
    if [ -z "$live_53" ]; then
        echo -e "     ${GREEN}[OK] 完美！当前没有任何进程向外部 53 端口发起连接。${PLAIN}"
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
        local since_ts
        since_ts=$(systemctl show easy-doh -p ActiveEnterTimestamp --value 2>/dev/null)
        if [ -n "$since_ts" ]; then
            journalctl -u easy-doh --since "$since_ts" -n 30 --no-pager
        else
            journalctl -u easy-doh -n 25 --no-pager
        fi
    else
        echo -e "  ${GRAY}当前服务未运行 (Service is currently stopped).${PLAIN}"
    fi
    echo -e "${DIV_BOLD}"
}

update_self_and_core() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}在线无损更新 / Lossless Update (Script + dnsproxy Core)${PLAIN}"
    echo -e "${DIV_THIN}"
    echo -e "  ${GREEN}[1]${PLAIN} 仅更新管理脚本 (${GH_REPO}) [GitHub 主源 + Cloudflare 回退]"
    echo -e "  ${GREEN}[2]${PLAIN} 仅检查并更新 AdGuard dnsproxy 内核二进制 (平滑热重启)"
    echo -e "  ${GREEN}[3]${PLAIN} 同时更新管理脚本 + dnsproxy 内核"
    echo -e "${DIV_THIN}"
    local u_opt
    read -rp "请选择更新项 [1-3, 回车取消]: " u_opt </dev/tty
    u_opt=$(echo "$u_opt" | tr -d '[:space:]')

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
            echo -e "${GREEN}  -> 脚本已同步至最新 (v${VERSION} -> v${remote_ver:-latest})！正在重载面板...${PLAIN}"
            sleep 1
            exec "$SCRIPT_PATH" </dev/tty
        else
            rm -f "${SCRIPT_PATH}.new"
            echo -e "${RED}[Warn] 远程拉取失败（请确认 GitHub 仓库 ${GH_REPO} 已设为 Public 且存在 doh.sh）。${PLAIN}"
        fi
    fi
}

purge_core() {
    local remove_self="${1:-0}"

    echo -e "\n${CYAN}[1/4] 停止并移除加密 DNS 守护进程与全部历史日志...${PLAIN}"
    systemctl stop easy-doh 2>/dev/null || true
    systemctl disable easy-doh 2>/dev/null || true
    systemctl stop doh-proxy 2>/dev/null || true
    systemctl disable doh-proxy 2>/dev/null || true
    rm -f "$SERVICE_FILE" /etc/systemd/system/doh-proxy.service /etc/default/doh-proxy
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

    if [ "$remove_self" -eq 1 ]; then
        rm -f "$SCRIPT_PATH" "${SCRIPT_PATH}.new" "${SCRIPT_PATH}.tmp"
        echo -e "\n${GREEN}[OK] 已完成 100% 零残留彻底卸载（包含所有备份、日志、内核与 doh 命令本身）！${PLAIN}\n"
        exit 0
    else
        echo -e "\n${GREEN}[OK] 服务、内核、日志与全部历史备份已彻底清空！(仅保留 doh 管理脚本)${PLAIN}"
    fi
}

uninstall_all() {
    echo -e "\n${DIV_BOLD}"
    echo -e " ${CYAN}彻底卸载与无痕清理 / Complete Uninstall & Zero-Trace Purge${PLAIN}"
    echo -e "${DIV_THIN}"
    echo -e "  ${YELLOW}[1]${PLAIN} 卸载服务 + 还原 DNS + ${RED}清空所有备份与内核${PLAIN} (保留 doh 命令备用)"
    echo -e "  ${RED}[2]${PLAIN} 100% 零残留彻底抹除 (${RED}连同 /usr/local/bin/doh 脚本一起自毁删除${PLAIN})"
    echo -e "  ${GRAY}[0]${PLAIN} 取消返回 (Cancel)"
    echo -e "${DIV_THIN}"
    local u_mode
    read -rp "请选择清理级别 / Select purge level [0-2]: " u_mode </dev/tty
    u_mode=$(echo "$u_mode" | tr -d '[:space:]')
    case "$u_mode" in
        1) purge_core 0 ;;
        2) purge_core 1 ;;
        *) echo -e "${GRAY}已取消卸载操作。${PLAIN}" ;;
    esac
}

render_menu() {
    local eng_str="${RED}○ Stopped (未运行)${PLAIN}"
    local listen_str="N/A"
    local up_str="None"
    [ -f "$STATE_FILE" ] && up_str=$(cat "$STATE_FILE")

    if systemctl is-active --quiet easy-doh; then
        local bin_ver=""
        [ -x "$BIN_PATH" ] && bin_ver=$("$BIN_PATH" --version 2>/dev/null | awk '{print $NF}')
        eng_str="${GREEN}● Active  (dnsproxy ${bin_ver})${PLAIN}"
        local addrs
        addrs=$(grep -A3 'listen-addrs:' "$CONF_FILE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | paste -sd "," -)
        listen_str="${addrs:-127.0.0.1}:53 (TCP + UDP)"
    elif [ -f /etc/systemd/resolved.conf.d/99-native-dot.conf ] && systemctl is-active --quiet systemd-resolved; then
        eng_str="${GREEN}● Active  (Native DoT 853)${PLAIN}"
        listen_str="127.0.0.53:53 (TCP + UDP)"
    fi

    local lock_str="${YELLOW}Unlocked (未锁定)${PLAIN}"
    lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i' && lock_str="${GREEN}Locked +i (防篡改已锁)${PLAIN}"

    local dk_str="${GRAY}Not Installed (未安装 Docker)${PLAIN}"
    if command -v docker >/dev/null 2>&1; then
        local dip
        dip=$(get_docker_ip)
        if grep -q "${dip:-172.17.0.1}" "$DOCKER_DAEMON" 2>/dev/null; then
            dk_str="${GREEN}Protected (${dip:-172.17.0.1}:53)${PLAIN}"
        else
            dk_str="${YELLOW}Unconfigured (建议执行 [3] 接管)${PLAIN}"
        fi
    fi

    local bak_cnt=0
    [ -d "$BACKUP_DIR" ] && bak_cnt=$(ls -1 "${BACKUP_DIR}"/dns_bak_*.tar.gz 2>/dev/null | wc -l)

    clear
    echo -e "${DIV_BOLD}"
    echo -e "   ${CYAN}E-Doh Manager v${VERSION}${PLAIN}  |  本地加密 DNS 与全球分流管理面板 (cmd: ${GREEN}doh${PLAIN})"
    echo -e "${DIV_BOLD}"
    echo -e "  运行状态 Engine   : ${eng_str}"
    echo -e "  监听端点 Listen   : ${listen_str}"
    echo -e "  上游策略 Upstream : ${CYAN}${up_str}${PLAIN}"
    echo -e "  系统锁定 Resolv   : ${lock_str}  [备份 Backups: ${bak_cnt}/3]"
    echo -e "  容器环境 Docker   : ${dk_str}"
    echo -e "${DIV_THIN}"
    echo -e "  ${GREEN}[1]${PLAIN} 安装 / 切换分地区 DoH 策略    (Install / Switch Regional DoH)"
    echo -e "  ${GREEN}[2]${PLAIN} 启用系统原生 DoT 急救模式     (Enable Native DoT 853)"
    echo -e "  ${GREEN}[3]${PLAIN} 修复 Docker 容器 DNS 防回退   (Fix Docker Bridge DNS)"
    echo -e "  ${GREEN}[4]${PLAIN} 实测本地 DNS 解析 (IPv4/IPv6) (Test Local DNS Resolution)"
    echo -e "  ${GREEN}[5]${PLAIN} 全球 12 大 DoH 并发测速排行   (Global DoH Upstream Speedtest)"
    echo -e "  ${GREEN}[6]${PLAIN} 全盘扫描 53 端口漏网之鱼      (Audit Port 53 Leaks)"
    echo -e "  ${GREEN}[7]${PLAIN} 查看当前实例运行日志          (View Current Instance Logs)"
    echo -e "  ${GREEN}[8]${PLAIN} 解锁 / 锁定 /etc/resolv.conf  (Toggle Resolv +i Lock)"
    echo -e "  ${GREEN}[9]${PLAIN} 在线无损更新脚本与内核        (Lossless Update Script & Core)"
    echo -e "  ${GREEN}[10]${PLAIN} 彻底卸载并清空全部备份       (Complete Uninstall & Purge)"
    echo -e "  ${GREEN}[0]${PLAIN} 退出管理面板                  (Exit)"
    echo -e "${DIV_BOLD}"
}

case "${1:-}" in
    --auto)
        cp -f "$0" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH"
        run_deploy_core "${2:-global}" "" "" 1
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
    read -rp "请输入选项编号 / Select option [0-10]: " choice </dev/tty
    choice=$(echo "$choice" | tr -d '[:space:]')
    [ -z "$choice" ] && continue

    case "$choice" in
        1) deploy_doh_wizard; pause_return ;;
        2) enable_native_dot; pause_return ;;
        3) fix_docker_dns 0; pause_return ;;
        4) test_all_dns; pause_return ;;
        5) benchmark_global_upstreams; pause_return ;;
        6) audit_leaks; pause_return ;;
        7) show_live_logs; pause_return ;;
        8)
            if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
                chattr -i /etc/resolv.conf
                echo -e "\n${YELLOW}[OK] 已解锁 /etc/resolv.conf (Unlocked).${PLAIN}"
            else
                chattr +i /etc/resolv.conf
                echo -e "\n${GREEN}[OK] 已锁定 /etc/resolv.conf (Locked +i).${PLAIN}"
            fi
            pause_return
            ;;
        9) update_self_and_core; pause_return ;;
        10) uninstall_all; pause_return ;;
        0) echo ""; exit 0 ;;
        *)
            echo -e "\n${RED}[Warn] 无效选项 '${choice}'，请输入 0-10 之间的数字！${PLAIN}"
            sleep 1
            ;;
    esac
done
