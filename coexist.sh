#!/system/bin/sh
# 与 TPROXY 透明代理（Clash/sing-box 等）共存
#   OUTPUT     : easytier 自身 socket（SO_MARK）存 connmark 并放行
#   PREROUTING : connmark / mesh 与热点网段 / easytier 监听端口放行
#   策略路由    : fwmark -> lookup <有默认路由的物理表>，pref 小于代理规则
#
# ⚠️ v2.7.0-hs2 关键修正（hs1 在真机上直接断网的原因）
#   Android 的 main 表一般是空的；默认路由在 netd 以网卡名命名的表里
#   （wlan0 / rmnet_data0 / ccmni0 ...），而 netd 的路由规则匹配
#   `fwmark 0x0/0xffff`，只对“未打标记”的包生效。若把 easytier 的 fwmark
#   指向 main 表，命中后 main 表无路由，内核继续下坠到 netd 的兜底规则
#   `32000: from all unreachable` => ENETUNREACH(101)。
#   真机表现：log 里成百上千条 `lookup_ip failed ... Network unreachable`，
#   easytier 连 225284.xyz 这种域名都解析不了，一个 peer 都连不上。
#   因此本版：
#     1) fwmark 规则指向“确实有默认路由”的物理表；
#     2) 加规则后立刻用 `ip route get <ip> mark <mark>` 实测，不通过就撤销；
#     3) easytier_core.sh 启动前再验一次，不通过就不带 --socket-mark 启动。
MODDIR=${0%/*}
CONFIG_FILE="${MODDIR}/config/config.toml"
COMMAND_ARGS="${MODDIR}/config/command_args"
COEXIST_CONF="${MODDIR}/config/coexist.conf"
HOTSPOT_CIDR_FILE="${MODDIR}/.hotspot_cidr"
INSTANCES_FILE="${MODDIR}/.instances"
MARK_USED_FILE="${MODDIR}/.coexist_mark_used"
LOG_FILE="${MODDIR}/log.log"

log() { echo "[ET-COEXIST] $1" >> "$LOG_FILE"; }

# 只在内容变化时写，避免守护循环每轮重复刷屏、把 log.log 撑爆
log_once() {
    LINE="[ET-COEXIST] $1"
    [ -f "$LOG_FILE" ] && [ "$(tail -n1 "$LOG_FILE" 2>/dev/null)" = "$LINE" ] && return 0
    echo "$LINE" >> "$LOG_FILE"
}

# ===== 配置（默认关闭，需显式 COEXIST_ENABLE=1）=====
COEXIST_ENABLE=0
ET_SOCKET_MARK=20052
MAIN_RULE_PREF=80
[ -f "$COEXIST_CONF" ] && . "$COEXIST_CONF"

# 把十进制 mark 转成 ip rule 显示用的十六进制形式。
#
# ⚠️ 必须严格校验：空值/非数字如果被硬转，会得到 "0x0"，
# 而 `ip rule show` 里 netd 的基础规则是
#   `16000: from all fwmark 0x0/0x10000 iif lo uidrange 0-0 lookup main`
# 用 "fwmark 0x0([ /]|$)" 去匹配会正好命中它 —— flush 时就会把
# Android 的基础路由规则删掉，导致整机断网（比 hs1 更严重）。
# 因此这里校验失败一律返回空串，调用方据此跳过。
mark_hex() {
    case "${ET_SOCKET_MARK:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # 排除 0：0 等于"未打标记"，与 netd 的基础规则语义冲突
    [ "$ET_SOCKET_MARK" -gt 0 ] 2>/dev/null || return 1
    printf '0x%x' "$ET_SOCKET_MARK"
}

# 是否应启用共存
coexist_enabled() {
    [ -f "${MODDIR}/disable_coexist" ] && return 1
    [ "${COEXIST_ENABLE}" = "1" ] || return 1
    [ -n "${ET_SOCKET_MARK}" ] || return 1
    return 0
}

hotspot_name() {
    H=$(head -n1 "${MODDIR}/config/hotspot_instance" 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$H" ] && { printf '%s' "$H"; return; }
    [ -f "$INSTANCES_FILE" ] && awk -F'\t' 'NR == 1 { print $1; exit }' "$INSTANCES_FILE"
}

# 热点出口实例的 tun（多实例时读 .instances）
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

# 所有实例的 tun 网段（多实例时都要放行）
all_tun_cidrs() {
    if [ -f "$INSTANCES_FILE" ]; then
        awk -F'\t' '$2 != "" { print $2 }' "$INSTANCES_FILE" | while read -r d; do
            iface_cidrs "$d"
        done
    fi
}

get_tun_iface() {
    ip link | awk -F': ' '/ tun[[:alnum:]]+/ {print $2; exit}'
}

# 接口地址 -> 网络地址（192.168.43.1/24 -> 192.168.43.0/24）
to_net_cidr() {
    [ -n "$1" ] || return 0
    ip="$1"; plen="${1#*/}"; [ "$plen" = "$1" ] && plen=32
    a=$(echo "$ip" | cut -d/ -f1)
    o1=$(echo "$a" | cut -d. -f1); o2=$(echo "$a" | cut -d. -f2)
    o3=$(echo "$a" | cut -d. -f3); o4=$(echo "$a" | cut -d. -f4)
    [ -z "$o4" ] && return 0
    case "$plen" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$plen" -le 8 ]; then o2=0; o3=0; o4=0
    elif [ "$plen" -le 16 ]; then o3=0; o4=0
    elif [ "$plen" -le 24 ]; then o4=0
    else M=$(( (256 - (1 << (32 - plen))) & 255 )); o4=$(( o4 & M ))
    fi
    echo "${o1}.${o2}.${o3}.${o4}/${plen}"
}

iface_cidrs() {
    [ -n "$1" ] || return 0
    ip -4 route show dev "$1" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// {print $1}'
}

forward_cidrs() {
    ET_IFACE=$(get_et_iface)
    [ -z "$ET_IFACE" ] && ET_IFACE="$(get_tun_iface)"
    {
        iface_cidrs "$ET_IFACE"
        cat "${HOTSPOT_CIDR_FILE}" 2>/dev/null | tr ' ' '\n'
        if [ ! -s "${HOTSPOT_CIDR_FILE}" ]; then
            for d in ap0 ap1 swlan0 swlan1 softap p2p-wlan0-0 rndis0 usb0 eth0; do
                ip -4 addr show dev "$d" 2>/dev/null | awk '/inet /{print $2}' | while read -r c; do
                    to_net_cidr "$c"
                done
            done
        fi
    } 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | sort -u
}

listener_ports() {
    {
        if [ -f "$COMMAND_ARGS" ]; then
            tr '\r\n' ' ' < "$COMMAND_ARGS" | grep -oE '(tcp|udp|wg|ws|wss|quic|faketcp)://[0-9.]+:[0-9]+' | grep -oE '[0-9]+$'
            tr '\r\n' ' ' < "$COMMAND_ARGS" | grep -oE '(tcp|udp|wg|quic|faketcp):[0-9]+' | grep -oE '[0-9]+$'
        fi
        if [ -f "$CONFIG_FILE" ]; then
            grep -oE '(tcp|udp|wg|ws|wss|quic|faketcp)://[0-9.:/]+:[0-9]+' "$CONFIG_FILE" | grep -oE '[0-9]+$'
        fi
    } | sort -un
}

# ===== 物理出口 / 路由表探测 =====
# Android 的 ip 是 toybox 实现，`ip route show table all`、`ip route get ... mark`
# 未必都支持，所以每一步都留降级路径。

route_field() { awk -v f="$1" '{ for (i = 1; i <= NF; i++) if ($i == f) { print $(i + 1); exit } }'; }

# 未打标记时的真实出口网卡（netd 用 fwmark 0x0/0xffff 把普通流量导向物理表，
# 所以 root 下裸跑 ip route get 拿到的就是物理出口，而不是代理 tun）
egress_dev() { ip route get 8.8.8.8 2>/dev/null | route_field dev; }

# 所有带默认路由的物理网卡（排除本模块 tun 与常见代理 tun）
physical_ifaces() {
    D=$(egress_dev)
    {
        [ -n "$D" ] && echo "$D"
        ip -4 route show table all 2>/dev/null \
            | awk '/^default/ { for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }'
        ip -4 route show 2>/dev/null \
            | awk '/^default/ { for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }'
    } 2>/dev/null | grep -vE '^(tun|et[0-9]|xray|clash|utun|wg|ppp|ipsec|dummy)' | grep -v '^$' | sort -u
}

# 为 fwmark 选表：优先按网卡名命名的表，其次数字表，最后 main
route_table_for_mark() {
    for dev in $(physical_ifaces); do
        if ip -4 route show table "$dev" 2>/dev/null | grep -q '^default'; then
            echo "$dev"
            return 0
        fi
    done
    for t in $(ip -4 route show table all 2>/dev/null \
                | awk '/^default/ { for (i = 1; i <= NF; i++) if ($i == "table") print $(i + 1) }' | sort -u); do
        if ip -4 route show table "$t" 2>/dev/null | grep -q '^default'; then
            echo "$t"
            return 0
        fi
    done
    if ip -4 route show table main 2>/dev/null | grep -q '^default'; then
        echo main
        return 0
    fi
    return 1
}

# 清理本 mark 的所有 fwmark 规则。
# 注意 ip rule show 以十六进制显示 mark，必须按 hex 匹配；
# 这里不依赖“记得当初加到哪个表”，直接按 mark 扫，兼容 hs1 留下的
# `fwmark 0x4e54 lookup main` 这种有害残留。
flush_mark_rules() {
    # mark 非法（空/0/非数字）时绝不动规则表：
    # 此时 HEX 会退化成 0x0，而 netd 的 `fwmark 0x0/0x10000 lookup main`
    # 正会被匹配到，删掉它就等于拆掉 Android 的基础路由。
    HEX=$(mark_hex) || { log_once "WARN: ET_SOCKET_MARK 非法([${ET_SOCKET_MARK:-空}])，跳过规则清理"; return 0; }

    i=0
    while [ $i -lt 8 ]; do
        LINE=$(ip rule show 2>/dev/null | grep -E "fwmark ${HEX}([ /]|\$)" | head -n1)
        [ -n "$LINE" ] || break
        PREF=$(printf '%s' "$LINE" | cut -d: -f1)
        [ -n "$PREF" ] || break
        # 双重保险：只删我们自己建的（lookup 目标不是 main 且不含 netd 的 uidrange/iif/oif 特征）。
        # 万一有别的工具也用同一个 mark，至少不会连带删掉它的规则。
        case "$LINE" in
            *uidrange*|*" iif "*|*" oif "*)
                log_once "WARN: 规则 pref=$PREF 带 netd 特征，拒绝删除: $LINE"
                break
                ;;
        esac
        ip rule del pref "$PREF" 2>/dev/null || break
        i=$((i + 1))
    done
    rm -f "$MARK_USED_FILE" 2>/dev/null
}

# 带 mark 的流量是否真能出网 —— 最关键的护栏
verify_mark_route() {
    [ -n "$ET_SOCKET_MARK" ] || return 0
    TBL=$(route_table_for_mark) || {
        log "VERIFY FAIL: 找不到可用于 fwmark ${ET_SOCKET_MARK} 的物理路由表"
        return 1
    }
    OUT=$(ip route get 8.8.8.8 mark "$ET_SOCKET_MARK" 2>&1)
    RC=$?
    case "$OUT" in
        *unreachable*|*"Network is unreachable"*|*"Network unreachable"*)
            log "VERIFY FAIL: fwmark $(mark_hex) -> table ${TBL} 不可达：${OUT}"
            return 1
            ;;
    esac
    if [ $RC -eq 0 ] && [ -n "$OUT" ]; then
        return 0
    fi
    # toybox ip 可能不支持 `route get ... mark ...`：证伪不了，
    # 只要目标表确实有默认路由就放行
    if ip -4 route show table "$TBL" 2>/dev/null | grep -q '^default'; then
        log "VERIFY: 无法实测 mark 路由（ip 不支持），table=${TBL} 有默认路由，放行"
        return 0
    fi
    log "VERIFY FAIL: table ${TBL} 无默认路由"
    return 1
}

apply_rules() {
    # 无论启用与否，先清掉本 mark 的历史规则（含 hs1 遗留的 lookup main）。
    # 否则升级后手机仍是断网状态，必须能自愈。
    flush_mark_rules

    coexist_enabled || {
        log_once "Coexist disabled (COEXIST_ENABLE=${COEXIST_ENABLE}), stale rules cleaned."
        return 0
    }

    TBL=$(route_table_for_mark) || {
        log "WARN: 无可用物理默认路由表，跳过共存"
        return 1
    }

    PREF="$MAIN_RULE_PREF"
    i=0
    while [ $i -lt 200 ] && ip -o rule show 2>/dev/null \
        | awk -v p="$PREF" '{ gsub(":", "", $1); if ($1 + 0 == p + 0) exit 0 } END { exit 1 }'; do
        PREF=$((PREF + 1))
        i=$((i + 1))
    done

    if ! ip rule add pref "$PREF" fwmark "$ET_SOCKET_MARK" lookup "$TBL" 2>/dev/null; then
        log "WARN: 添加 fwmark 规则失败 (pref=$PREF table=$TBL)，跳过共存"
        return 1
    fi

    # 立刻实测：不通过就撤销，绝不带着会断网的规则走
    if ! verify_mark_route; then
        flush_mark_rules
        log "WARN: fwmark $(mark_hex) 路由校验失败，已撤销规则（easytier 将以无 mark 启动）"
        return 1
    fi
    echo "$ET_SOCKET_MARK" > "$MARK_USED_FILE"

    # 1a) OUTPUT：标记包存 connmark 再放行（回程包由此可被识别）
    iptables -t mangle -N ET_COEX_OUT 2>/dev/null
    iptables -t mangle -C OUTPUT -j ET_COEX_OUT 2>/dev/null || \
        iptables -t mangle -I OUTPUT 1 -j ET_COEX_OUT
    iptables -t mangle -F ET_COEX_OUT 2>/dev/null
    iptables -t mangle -A ET_COEX_OUT -m mark --mark "$ET_SOCKET_MARK" -j CONNMARK --save-mark
    iptables -t mangle -A ET_COEX_OUT -m mark --mark "$ET_SOCKET_MARK" -j ACCEPT

    # 1b) PREROUTING：connmark / mesh 与热点网段 / 监听端口，全部排在 TPROXY 之前
    iptables -t mangle -N ET_COEX_IN 2>/dev/null
    iptables -t mangle -C PREROUTING -j ET_COEX_IN 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -j ET_COEX_IN
    iptables -t mangle -F ET_COEX_IN 2>/dev/null
    iptables -t mangle -A ET_COEX_IN -m connmark --mark "$ET_SOCKET_MARK" -j ACCEPT
    for cidr in $(forward_cidrs); do
        iptables -t mangle -A ET_COEX_IN -s "$cidr" -j ACCEPT
        iptables -t mangle -A ET_COEX_IN -d "$cidr" -j ACCEPT
    done
    for port in $(listener_ports); do
        iptables -t mangle -A ET_COEX_IN -p tcp --dport "$port" -j ACCEPT
        iptables -t mangle -A ET_COEX_IN -p udp --dport "$port" -j ACCEPT
    done

    log "Coexist rules applied: mark=$ET_SOCKET_MARK($(mark_hex)) pref=$PREF table=$TBL"
    return 0
}

flush_rules() {
    iptables -t mangle -D OUTPUT -j ET_COEX_OUT 2>/dev/null
    iptables -t mangle -F ET_COEX_OUT 2>/dev/null
    iptables -t mangle -X ET_COEX_OUT 2>/dev/null
    iptables -t mangle -D PREROUTING -j ET_COEX_IN 2>/dev/null
    iptables -t mangle -F ET_COEX_IN 2>/dev/null
    iptables -t mangle -X ET_COEX_IN 2>/dev/null
    flush_mark_rules
    log "Coexist rules flushed."
}

case "$1" in
    apply)   apply_rules ;;
    flush)   flush_rules ;;
    verify)  verify_mark_route ;;
    enabled) coexist_enabled ;;
    table)   route_table_for_mark || echo "" ;;
    *)       echo "Usage: $0 [apply|flush|verify|enabled|table]"; exit 1 ;;
esac
