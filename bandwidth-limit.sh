#!/bin/bash
# ============================================================================
# 服务器带宽限速脚本（菜单式） —— 防止腾讯云/阿里云轻量服务器被降速到 1Mbps
#
# 运行后直接进入菜单，自动检测当前是否已限速并显示在菜单顶部。
# 同时限制「上传(出口)」和「下载(入口)」带宽，重启后自动生效（systemd）。
#
# 用法：sudo bash bandwidth-limit.sh
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[信息]${NC} $1"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }

# ---------- 安装 vsl 快捷命令（大小写不敏感） ----------
SCRIPT_URL="https://raw.githubusercontent.com/hankepeng/vps-speed-limit/main/bandwidth-limit.sh"
CMD_PATH="/root/vps-speed-limit"
HISTORY_DIR="/root/speedtest_history"
VERSION="1.0.0"

install_command() {
    if ! command -v curl >/dev/null 2>&1; then
        return 0
    fi
    local tmp="${CMD_PATH}.tmp.$$"
    if curl -Ls "$SCRIPT_URL" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        chmod +x "$tmp" 2>/dev/null
        mv -f "$tmp" "$CMD_PATH"
    fi
    rm -f "$tmp"
    for name in vsl Vsl vSl VSl vsL VsL vSL VSL; do
        ln -sf "$CMD_PATH" "/usr/local/bin/$name" 2>/dev/null
    done
}

# ---------- 更新脚本到最新版本 ----------
update_script() {
    if ! command -v curl >/dev/null 2>&1; then
        error "未安装 curl，无法更新。"
        read -r -p "按回车返回菜单..." _
        return
    fi
    info "正在检查最新脚本地址..."
    local tmp="${CMD_PATH}.update.$$"
    if curl -fsSL "$SCRIPT_URL" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        # 能正常下载：删除本地遗留脚本并替换为最新版
        rm -f "$CMD_PATH"
        chmod +x "$tmp" 2>/dev/null
        mv -f "$tmp" "$CMD_PATH"
        for name in vsl Vsl vSl VSl vsL VsL vSL VSL; do
            ln -sf "$CMD_PATH" "/usr/local/bin/$name" 2>/dev/null
        done
        info "已重新下载最新脚本，正在重新启动..."
        sleep 1
        exec bash "$CMD_PATH"
    else
        # 不能下载：不更新，并告知
        rm -f "$tmp"
        error "脚本无法下载，请检查网络后重试，或手动前往以下地址下载："
        echo -e "  ${CYAN}${SCRIPT_URL}${NC}"
        read -r -p "按回车返回菜单..." _
    fi
}

# ---------- 自动识别主网卡 ----------
IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
if [ -z "$IFACE" ]; then
    IFACE=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | head -1)
fi

# ---------- 提取某网卡当前的限速值 ----------
rate_of() {
    local dev="$1" r
    r=$(tc class show dev "$dev" 2>/dev/null | grep -oE 'rate [0-9]+[KMG]?bit' | head -1 | awk '{print $2}')
    echo "${r:-无}"
}

# ---------- 获取限速状态 ----------
get_status() {
    UP=$(rate_of "$IFACE")
    DOWN=$(rate_of "ifb0")
    if [ "$UP" = "无" ] && [ "$DOWN" = "无" ]; then
        STATUS="未限速"
    else
        STATUS="已限速"
    fi
    if systemctl is-enabled bandwidth-limit.service >/dev/null 2>&1; then
        AUTO="已开启"
    else
        AUTO="未开启"
    fi
}

# ---------- 运行测速（实时动态显示进度，并保存干净结果） ----------
run_speedtest() {
    local ts outfile rawfile
    ts=$(date '+%Y%m%d_%H%M%S')
    mkdir -p "$HISTORY_DIR"
    outfile="$HISTORY_DIR/speedtest_${ts}.txt"
    echo "$(date '+%Y/%m/%d %H:%M')" > "$outfile"

    # 关键：speedtest 只有在 stdout 是终端(TTY)时才会显示实时动态刷新的数字。
    # 一旦用管道(如 | tee)就会退化为静态最终值。这里用 script 伪造一个 TTY，
    # 既让用户在终端看到动态进度，又把原始输出记录下来，随后清洗成干净文本保存。
    if command -v script >/dev/null 2>&1; then
        rawfile="$HISTORY_DIR/.raw_${ts}.$$"
        script -qec "speedtest --accept-license --accept-gdpr" "$rawfile"
        # 过滤 script 自带的开始/结束行；去 ANSI；先去掉行尾 CR(CRLF 残留)，
        # 再处理行中间的回车覆盖，保证最终结果不被误删。
        if command -v perl >/dev/null 2>&1; then
            grep -v -E '^Script (started|done) ' "$rawfile" \
              | perl -pe 's/\e\[[0-9]*G/\r/g; s/\e\[[0-9;?]*[A-Za-z]//g; s/\e\][^\a]*\a//g; s/\e[()][0-9A-B]//g; s/\r$//; s/.*\r//g' \
              | sed '/^[[:space:]]*$/d' >> "$outfile"
        else
            grep -v -E '^Script (started|done) ' "$rawfile" \
              | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][0-9A-B]//g' \
              | tr -d '\r' | sed '/^[[:space:]]*$/d' >> "$outfile"
        fi
        rm -f "$rawfile"
    else
        speedtest --accept-license --accept-gdpr 2>/dev/null | tee -a "$outfile"
    fi

    if [ "$(wc -l < "$outfile" 2>/dev/null)" -le 1 ]; then
        rm -f "$outfile"
        return 1
    fi
    return 0
}

# ---------- 从测速结果文件中解析摘要 ----------
# 输出：server|download(Mbps)|upload(Mbps)|download延迟(ms)|upload延迟(ms)
parse_speed() {
    local file="$1"
    awk '
    function num(x) {
        if (x == "") return "0"
        if (match(x, /[0-9]+(\.[0-9]+)?/)) return substr(x, RSTART, RLENGTH)
        return "0"
    }
    /^[[:space:]]*Server:/ && server=="" {
        s=$0; sub(/^[[:space:]]*Server:[[:space:]]*/,"",s); sub(/[[:space:]]*\(id:.*/,"",s); server=s
    }
    /^[[:space:]]*Download:/ {
        d=$0; if (getline > 0 && $0 ~ /ms/) dlat=$0
    }
    /^[[:space:]]*Upload:/ {
        u=$0; if (getline > 0 && $0 ~ /ms/) ulat=$0
    }
    END { print server "|" num(d) "|" num(u) "|" num(dlat) "|" num(ulat) }' "$file" 2>/dev/null
}

# ---------- 读取最后一次测速结果 ----------
read_last_speed() {
    local latest
    LAST_TS=""; LAST_SERVER=""; LAST_DOWN=""; LAST_UP=""; LAST_DLAT=""; LAST_ULAT=""
    latest=$(ls -1 "$HISTORY_DIR"/speedtest_*.txt 2>/dev/null | sort | tail -1)
    [ -n "$latest" ] || return 0
    LAST_TS=$(head -1 "$latest")
    IFS='|' read -r LAST_SERVER LAST_DOWN LAST_UP LAST_DLAT LAST_ULAT <<< "$(parse_speed "$latest")"
}

# ---------- 显示菜单 ----------
show_menu() {
    get_status
    read_last_speed
    local d u dl ul
    d=$(printf '%.0f' "$LAST_DOWN" 2>/dev/null)
    u=$(printf '%.0f' "$LAST_UP" 2>/dev/null)
    dl=$(printf '%.2f' "$LAST_DLAT" 2>/dev/null)
    ul=$(printf '%.2f' "$LAST_ULAT" 2>/dev/null)
    clear 2>/dev/null
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}          服务器带宽限速管理 v${VERSION}${NC}"
    echo -e " ${CYAN}https://github.com/hankepeng/vps-speed-limit${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "  网卡：${BOLD}${IFACE}${NC}"
    echo -e "  开机自启：${AUTO}"
    echo -e "  ${CYAN}输入vsl可打开本菜单${NC}"
    if [ "$STATUS" = "已限速" ]; then
        echo -e "  限速状态：${GREEN}已限速${NC}（上传 ${UP} / 下载 ${DOWN}）"
    else
        echo -e "  限速状态：${YELLOW}未限速${NC}"
    fi
    if [ -n "$LAST_DOWN" ]; then
        echo -e "  最近测速：上传 ${u}Mb ${ul}ms / 下载 ${d}Mb ${dl}ms"
        echo -e "  测速信息：${LAST_TS} ${LAST_SERVER}"
    fi
    echo -e "${BOLD}${CYAN}----------------------------------------------${NC}"
    echo "  1) 设置 / 修改限速"
    echo "  2) 查看当前限速规则"
    echo "  3) 临时取消限速"
    echo "  4) 永久取消限速"
    echo "  5) 测试当前网速"
    echo "  6) 脚本更新"
    echo "  0) 退出"
    echo ""
}

# ---------- 设置 / 修改限速 ----------
set_limit() {
    local up down
    read -p "请输入 上传(出口) 限速 Mbps（例如 140，填 0 表示不限速）：" up
    read -p "请输入 下载(入口) 限速 Mbps（例如 140，填 0 表示不限速）：" down
    case "$up"   in ''|*[!0-9]*) error "上传限速必须是数字"; return;; esac
    case "$down" in ''|*[!0-9]*) error "下载限速必须是数字"; return;; esac

    mkdir -p /root
    cat > /root/bandwidth-limit.sh << 'SCRIPT'
#!/bin/bash
# 服务器带宽限速（由菜单脚本自动生成，请勿手工修改）
IFACE="__IFACE__"
UP_MBPS="__UP_MBPS__"
DOWN_MBPS="__DOWN_MBPS__"

if [ "$UP_MBPS" -gt 0 ]; then
    tc qdisc del dev $IFACE root 2>/dev/null
    tc qdisc add dev $IFACE root handle 1: htb default 10
    tc class add dev $IFACE parent 1: classid 1:1 htb rate ${UP_MBPS}mbit ceil ${UP_MBPS}mbit
    tc class add dev $IFACE parent 1:1 classid 1:10 htb rate ${UP_MBPS}mbit ceil ${UP_MBPS}mbit
fi

if [ "$DOWN_MBPS" -gt 0 ]; then
    modprobe ifb numifbs=1 2>/dev/null
    ip link set dev ifb0 up 2>/dev/null
    tc qdisc del dev $IFACE ingress 2>/dev/null
    tc qdisc add dev $IFACE ingress
    tc filter add dev $IFACE parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev ifb0
    tc qdisc del dev ifb0 root 2>/dev/null
    tc qdisc add dev ifb0 root handle 2: htb default 20
    tc class add dev ifb0 parent 2: classid 2:1 htb rate ${DOWN_MBPS}mbit ceil ${DOWN_MBPS}mbit
    tc class add dev ifb0 parent 2:1 classid 2:20 htb rate ${DOWN_MBPS}mbit ceil ${DOWN_MBPS}mbit
fi
SCRIPT
    sed -i "s/__IFACE__/$IFACE/g; s/__UP_MBPS__/$up/g; s/__DOWN_MBPS__/$down/g" /root/bandwidth-limit.sh
    chmod +x /root/bandwidth-limit.sh

    cat > /etc/systemd/system/bandwidth-limit.service << EOF
[Unit]
Description=Server bandwidth limit (upload ${up}Mbps / download ${down}Mbps)
After=network.target

[Service]
Type=oneshot
ExecStart=/root/bandwidth-limit.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bandwidth-limit.service >/dev/null 2>&1
    systemctl restart bandwidth-limit.service
    info "限速已应用：上传 ${up} Mbps / 下载 ${down} Mbps，并已开启开机自启。"
    echo
    read -r -p "按回车返回菜单..." _
}

# ---------- 查看当前规则 ----------
view_rules() {
    echo -e "${CYAN}--- 上传(出口) 规则（${IFACE}） ---${NC}"
    tc -s qdisc show dev "$IFACE"
    echo
    echo -e "${CYAN}--- 下载(入口) 规则（ifb0） ---${NC}"
    tc -s qdisc show dev ifb0 2>/dev/null || echo "（无，未设置下载限速）"
    echo
    read -r -p "按回车返回菜单..." _
}

# ---------- 临时取消限速 ----------
temp_off() {
    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc del dev "$IFACE" ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    info "已临时取消限速（若服务仍启用，重启后会自动恢复）。"
    echo
    read -r -p "按回车返回菜单..." _
}

# ---------- 永久取消限速 ----------
perm_off() {
    systemctl disable --now bandwidth-limit.service >/dev/null 2>&1
    rm -f /root/bandwidth-limit.sh /etc/systemd/system/bandwidth-limit.service
    rm -f /root/vps-speed-limit
    for name in vsl Vsl vSl VSl vsL VsL vSL VSL; do
        rm -f "/usr/local/bin/$name" 2>/dev/null
    done
    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc del dev "$IFACE" ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    info "已永久取消限速并删除服务与脚本。"
    echo
    read -r -p "按回车返回菜单..." _
}

# ---------- 确保 speedtest 已安装 ----------
ensure_speedtest() {
    command -v speedtest >/dev/null 2>&1 && return 0
    info "未检测到 speedtest，尝试自动安装..."
    # 方式一：apt 安装（Debian/Ubuntu）
    if command -v apt-get >/dev/null 2>&1; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash >/dev/null 2>&1
        apt-get install -y speedtest >/dev/null 2>&1
    fi
    # 方式二：二进制安装（备用，含 Alpine 等无 apt 的发行版）
    if ! command -v speedtest >/dev/null 2>&1; then
        local arch url
        arch=$(uname -m)
        case "$arch" in
            x86_64|amd64)  url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz" ;;
            aarch64|arm64) url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz" ;;
            armv7l|armhf)  url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-armhf.tgz" ;;
            i386|i686)     url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-i386.tgz" ;;
            *) error "不支持的架构：$arch"; return 1 ;;
        esac
        info "改用二进制安装..."
        curl -Ls "$url" -o /tmp/speedtest.tgz 2>/dev/null
        tar zxf /tmp/speedtest.tgz -C /tmp/ 2>/dev/null
        mv -f /tmp/speedtest /usr/local/bin/speedtest 2>/dev/null
        chmod +x /usr/local/bin/speedtest 2>/dev/null
        rm -f /tmp/speedtest.tgz
    fi
    command -v speedtest >/dev/null 2>&1
}

# ---------- 测试当前网速 ----------
test_speed() {
    local avg avg_d avg_u avg_dl avg_ul ans files f ftime i
    echo -e "${CYAN}--- 测速记录 ---${NC}"
    files=$(ls -1 "$HISTORY_DIR"/speedtest_*.txt 2>/dev/null | sort | tail -3)
    if [ -n "$files" ]; then
        i=0
        while IFS= read -r f; do
            i=$((i+1))
            ftime=$(head -1 "$f")
            echo "--------------------------------------"
            echo -e "  ${CYAN}最近第${i}次测速，时间：${ftime}${NC}"
            tail -n +2 "$f"
            echo
        done <<< "$files"
        avg=$(for f in $files; do parse_speed "$f"; done | awk -F'|' '{d+=$2; u+=$3; dl+=$4; ul+=$5; n++} END{if(n>0) printf "%.0f|%.0f|%.2f|%.2f", d/n, u/n, dl/n, ul/n}')
        if [ -n "$avg" ]; then
            IFS='|' read -r avg_d avg_u avg_dl avg_ul <<< "$avg"
            echo -e "  ${CYAN}平均：上传 ${avg_u}Mb ${avg_ul}ms / 下载 ${avg_d}Mb ${avg_dl}ms${NC}"
        fi
        echo -e "  ${CYAN}输入 vsl -t 可直接测速${NC}"
        echo
        read -r -p "输入 y 开始测速，按回车返回菜单：" ans
        case "$ans" in
            [yY]) ;;
            *) return ;;
        esac
    else
        echo "  暂无测速记录，直接开始测速..."
    fi

    # 确保 speedtest 已安装
    if ! ensure_speedtest; then
        error "speedtest 安装失败，请手动安装后重试。"
        read -r -p "按回车返回菜单..." _
        return
    fi

    run_speedtest || error "测速失败，请检查网络。"
    echo
    read -r -p "按回车返回菜单..." _
}

# ---------- 入口 ----------
if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 运行：sudo bash $0"
    exit 1
fi
if ! command -v tc >/dev/null 2>&1; then
    error "未安装 tc，请先安装：apt install iproute2 或 yum install iproute"
    exit 1
fi

install_command

# 支持 vsl -t 直接测速
if [ "$1" = "-t" ] || [ "$1" = "--test" ]; then
    if ensure_speedtest; then
        run_speedtest || error "测速失败，请检查网络。"
    else
        error "speedtest 安装失败，请手动安装后重试。"
    fi
    exit 0
fi

while true; do
    show_menu
    read -r -p "请选择 [0-6]：" choice
    case "$choice" in
        1) set_limit ;;
        2) view_rules ;;
        3) temp_off ;;
        4) perm_off ;;
        5) test_speed ;;
        6) update_script ;;
        0) echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
