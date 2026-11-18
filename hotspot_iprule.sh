#!/system/bin/sh
MODDIR=${0%/*}
CONFIG_FILE="${MODDIR}/config/config.toml"
LOG_FILE="${MODDIR}/log.log"
ACTION="$1"  # 参数：add add_once del probe
HOTSPOT_CIDR_FILE="${MODDIR}/.hotspot_cidr"
INSTANCES_FILE="${MODDIR}/.instances"
HOTSPOT_INSTANCE_FILE="${MODDIR}/config/hotspot_instance"


# 获取接口/IP
# 热点出口实例名（config/hotspot_instance 的内容，缺省取第一个实例）
hotspot_name() {
    H=$(head -n1 "$HOTSPOT_INSTANCE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$H" ] && { printf '%s' "$H"; return; }
    [ -f "$INSTANCES_FILE" ] && awk -F'\t' 'NR == 1 { print $1; exit }' "$INSTANCES_FILE"
}

# 出口实例的 tun 设备名。
# 多实例时 .instances 由 easytier_core.sh 生成（名字<TAB>dev<TAB>cfg），
# 单实例兼容路径则回退到读 config.toml 的 dev_name。
get_et_iface() {
    H=$(hotspot_name)
    if [ -n "$H" ] && [ -f "$INSTANCES_FILE" ]; then
        D=$(awk -F'\t' -v n="$H" '$1 == n { print $2; exit }' "$INSTANCES_FILE")
        [ -n "$D" ] && { printf '%s' "$D"; return; }
    fi
    awk '
        BEGIN { IGNORECASE = 1 }
        /^[[:space:]]*dev_name[[:space:]]*=/ {
            val = $0
            sub(/^[^=]*=[[:space:]]*/, "", val)
            gsub(/[" \t]/, "", val)
            print val
            exit
        }
    ' "$CONFIG_FILE"
}
get_tun_iface() {
    ip link | awk -F': ' '/ tun[[:alnum:]]+/ {print $2; exit}'
}
get_hot_iface() {
    # 策略 1：从 Android netd 的 tethering 策略路由反查（最准确，覆盖所有机型）
    # netd 开启热点后会固定添加形如：21000: from all iif <dev> lookup <tbl>
    NETD_HOT=$(ip rule show 2>/dev/null | awk '
        /from all iif [^ ]+ lookup/ {
            for (i = 1; i < NF; i++) {
                if ($i == "iif") {
                    dev = $(i + 1)
                    if (dev !~ /^(lo|dummy|et|tun|rmnet)/) {
                        print dev
                        exit
                    }
                }
            }
        }
    ')
    if [ -n "$NETD_HOT" ] && ip link show "$NETD_HOT" >/dev/null 2>&1; then
        printf '%s' "$NETD_HOT"
        return 0
    fi

    # 策略 2：正则匹配所有已知 Wi-Fi 热点接口名
    # 包括高通双 WiFi DBS (wlan1/wlan2)、MTK (ap0/ap1)、原生 softap/swlan
    ip link | awk -F': ' '
        /(^| )(swlan[[:alnum:]_]*|softap[[:alnum:]_]*|p2p-wlan[[:alnum:]_]*|ap[[:alnum:]_]*|wlan[1-9][[:alnum:]_]*):/ {
            dev = $2
            sub(/@.*/, "", dev)
            print dev
            exit
        }
    '
}
get_usb_iface() {
    ip link | awk -F': ' '/(^| )(usb[[:alnum:]_]*|rndis[[:alnum:]_]*|eth[[:alnum:]_]*|ncm[[:alnum:]_]*):/ {print $2; exit}' | cut -d'@' -f1 | head -n1
}
get_hot_cidr() {
    [ -n "$1" ] || return 0
    ip -4 addr show dev "$1" 2>/dev/null | awk '/inet /{print $2; exit}'
}

# 内核转发开关 + 反向路径过滤（热点设备流量经主表路由到 tun 必需）
ensure_sysctls() {
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
    ET_IFACE=$(get_et_iface)
    [ -z "$ET_IFACE" ] && ET_IFACE="$(get_tun_iface)"
    for iface in all default "$ET_IFACE" "$(get_hot_iface)" "$(get_usb_iface)"; do
        [ -n "$iface" ] || continue
        echo 2 > "/proc/sys/net/ipv4/conf/$iface/rp_filter" 2>/dev/null
        echo 1 > "/proc/sys/net/ipv4/conf/$iface/forwarding" 2>/dev/null
    done
}

# 本模块是否已有实例在运行（按 .instances 里的 tun 或配置路径判断）
module_instance_running() {
    [ -f "$INSTANCES_FILE" ] || return 1
    while IFS="$(printf '\t')" read -r n d c; do
        [ -z "$c" ] && continue
        pgrep -f -- "-c ${c}" >/dev/null 2>&1 && return 0
    done < "$INSTANCES_FILE"
    return 1
}

# 探测当前热点/USB 网段并写入 .hotspot_cidr；变化时标记重启主程序
# 把 192.168.43.1/24 规范成 192.168.43.0/24。
# --proxy-networks 只接受网络地址，传接口地址会让 easytier 报
# `failed to merge config from cli` 并直接退出（实例起不来）。
to_net_cidr() {
    [ -n "$1" ] || return 0
    ip="$1"; plen="${1#*/}"; [ "$plen" = "$1" ] && plen=32
    a=$(echo "$ip" | cut -d/ -f1)
    o1=$(echo "$a" | cut -d. -f1); o2=$(echo "$a" | cut -d. -f2)
    o3=$(echo "$a" | cut -d. -f3); o4=$(echo "$a" | cut -d. -f4)
    [ -z "$o4" ] && return 0
    case "$plen" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ "$plen" -le 8 ]; then o2=0; o3=0; o4=0
    elif [ "$plen" -le 16 ]; then o3=0; o4=0
    elif [ "$plen" -le 24 ]; then o4=0
    else
        # 25~32 位的少见场景：按 2 的幂做位掩码
        M=$(( (256 - (1 << (32 - plen))) & 255 ))
        o4=$(( o4 & M ))
    fi
    echo "${o1}.${o2}.${o3}.${o4}/${plen}"
}

probe_cidrs() {
    NEW_HOT=$(to_net_cidr "$(get_hot_cidr "$(get_hot_iface)")")
    NEW_USB=$(to_net_cidr "$(get_hot_cidr "$(get_usb_iface)")")
    OLD=$(cat "${HOTSPOT_CIDR_FILE}" 2>/dev/null)
    OLD_HOT=$(echo "$OLD" | awk '{print $1}')
    NOW="${NEW_HOT} ${NEW_USB}"
    # 规范化后再比较：`$(cat)` 会吃掉尾部空白/换行，
    # 若不规范化，"192.168.43.1/24 " 与 "192.168.43.1/24" 永远不相等，
    # 会每轮都误判成"网段变化"而反复重启全部实例。
    NOW_N=$(printf '%s' "$NOW" | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')
    OLD_N=$(printf '%s' "$OLD" | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')
    if [ "$NOW_N" != "$OLD_N" ]; then
        echo "$NOW" > "${HOTSPOT_CIDR_FILE}"
        # 已开启转发且热点网段变化 => 主程序需以新的 --proxy-networks 重启
        # 只有"本模块自己的实例"在跑时才请求重启。
        # 不能用 `pgrep -x easytier-core` —— 系统里可能有别的 easytier 进程，
        # 会造成首次探测就误触发、进而反复重启所有实例。
        if [ -f "${MODDIR}/enable_IP_rule" ] && [ -n "$NEW_HOT" ] \
            && [ "$NEW_HOT" != "$OLD_HOT" ] && module_instance_running; then
            touch "${MODDIR}/.restart_easytier"
        fi
    fi
}

set_nat_rules() {
    ET_IFACE=$(get_et_iface)
    [ -z "$ET_IFACE" ] && ET_IFACE="$(get_tun_iface)"
    HOT_IFACE=$(get_hot_iface)
    USB_IFACE=$(get_usb_iface)
    HOT_CIDR=$(get_hot_cidr "$HOT_IFACE")
    USB_CIDR=$(get_hot_cidr "$USB_IFACE")

    # sysctl 与热点是否在线无关，必须无条件先做：
    # 热点可能是后开的，届时 ensure_sysctls 早已因下面 return 而被跳过，
    # 导致 ip_forward=0 / rp_filter=1，热点设备的包被内核丢弃。
    ensure_sysctls

    # 如果热点关闭就删除自定义链
    [ -n "$ET_IFACE" ] && { [ -n "$HOT_CIDR" ] || [ -n "$USB_CIDR" ]; } || return 1

    # 创建自定义链（如不存在）
    iptables -t nat -N ET_NAT 2>/dev/null
    iptables -N ET_FWD 2>/dev/null

    # 确保主链首条跳转到自定义链
    iptables -t nat -C POSTROUTING -j ET_NAT 2>/dev/null || \
        iptables -t nat -I POSTROUTING 1 -j ET_NAT
    iptables -C FORWARD -j ET_FWD 2>/dev/null || \
        iptables -I FORWARD 1 -j ET_FWD

    # 守护 Android 系统原生热点外网 NAT 链（避免意外被断开导致热点设备上不了外网）
    if iptables -t nat -S tetherctrl_nat_POSTROUTING >/dev/null 2>&1; then
        iptables -t nat -C POSTROUTING -j tetherctrl_nat_POSTROUTING 2>/dev/null || \
            iptables -t nat -A POSTROUTING -j tetherctrl_nat_POSTROUTING
    fi

    # 先清空自定义链，避免每次刷新重复累积 MASQUERADE/FORWARD（幂等）
    iptables -t nat -F ET_NAT 2>/dev/null
    iptables -F ET_FWD 2>/dev/null

    # 添加规则
    if [ -n "$HOT_CIDR" ]; then
        iptables -t nat -A ET_NAT -s "$HOT_CIDR" -o "$ET_IFACE" -j MASQUERADE
        iptables -A ET_FWD -i "$HOT_IFACE" -o "$ET_IFACE" \
            -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
        iptables -A ET_FWD -i "$ET_IFACE" -o "$HOT_IFACE" \
            -m state --state ESTABLISHED,RELATED -j ACCEPT
        echo "[ET-NAT] Rules applied: $HOT_IFACE $HOT_CIDR ↔ $ET_IFACE" >> "$LOG_FILE"
    fi
    if [ -n "$USB_CIDR" ]; then
        iptables -t nat -A ET_NAT -s "$USB_CIDR" -o "$ET_IFACE" -j MASQUERADE
        iptables -A ET_FWD -i "$USB_IFACE" -o "$ET_IFACE" \
            -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
        iptables -A ET_FWD -i "$ET_IFACE" -o "$USB_IFACE" \
            -m state --state ESTABLISHED,RELATED -j ACCEPT
        echo "[ET-NAT] Rules applied: $USB_IFACE $USB_CIDR ↔ $ET_IFACE" >> "$LOG_FILE"
    fi
}

# 只在内容真的变化时写日志。
# `ip monitor link addr` 会在接口抖动时连续触发（用户日志里出现过 30 条
# "Custom chains flushed" 刷屏），逐条写日志会把 log.log 撑爆且掩盖真实事件。
log_nat_once() {
    LINE="[ET-NAT] $1"
    [ -f "$LOG_FILE" ] && [ "$(tail -n1 "$LOG_FILE" 2>/dev/null)" = "$LINE" ] && return 0
    echo "$LINE" >> "$LOG_FILE"
}

flush_rules() {
    iptables -t nat -F ET_NAT 2>/dev/null
    iptables -F ET_FWD 2>/dev/null
    log_nat_once "Custom chains flushed."
}

# 彻底拆除：连跳到自定义链的钩子一起删掉，并把 sysctl 恢复成保守值。
# 用于「出问题要一键回滚」的场景（action.sh 关转发、或手动执行 clean）。
clean_rules() {
    iptables -t nat -F ET_NAT 2>/dev/null
    iptables -t nat -D POSTROUTING -j ET_NAT 2>/dev/null
    iptables -t nat -X ET_NAT 2>/dev/null
    iptables -F ET_FWD 2>/dev/null
    iptables -D FORWARD -j ET_FWD 2>/dev/null
    iptables -X ET_FWD 2>/dev/null
    echo "[ET-NAT] Custom chains + hooks removed." >> "$LOG_FILE"
}

case "$ACTION" in
    add)
        probe_cidrs
        # 只有用户显式开启转发（enable_IP_rule）才建 NAT 规则，
        # 避免没开功能时也往 POSTROUTING/FORWARD 里插钩子
        if [ -f "${MODDIR}/enable_IP_rule" ]; then
            set_nat_rules
        fi
        echo "[ET-NAT] Guard started." >> "$LOG_FILE"
        ip monitor link addr | while read -r _; do
            if [ -f "${MODDIR}/enable_IP_rule" ]; then
                probe_cidrs
                flush_rules
                set_nat_rules
            fi
        done
        ;;
    add_once)
        probe_cidrs
        flush_rules
        set_nat_rules
        echo "[ET-NAT] One-time rules applied." >> "$LOG_FILE"
        ;;
    del)
        clean_rules
        ;;
    probe)
        probe_cidrs
        ;;
    *)
        echo "Usage: $0 [add|add_once|del|probe]"
        exit 1
        ;;
esac
