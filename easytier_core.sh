#!/system/bin/sh
# 多网络实例守护进程
#
# 结构：
#   config/networks/*.toml  每个文件 = 一个独立的 EasyTier 网络实例（独立进程）
#   config/config.toml      旧版单实例兼容（networks/ 为空时使用）
#   config/command_args     旧版启动参数模式（存在时优先，单实例）
#   config/hotspot_instance 指定哪个实例作为热点出口（写实例名，默认第一个）
#
# 每个实例独立进程、独立日志、独立崩溃重启，互不影响。
# 自动分配 dev_name / rpc_portal / instance_name，避免多实例互相踩踏。

MODDIR=${0%/*}
CONFIG_DIR="${MODDIR}/config"
NETWORKS_DIR="${CONFIG_DIR}/networks"
LEGACY_CONFIG="${CONFIG_DIR}/config.toml"
COMMAND_ARGS="${CONFIG_DIR}/command_args"
HOTSPOT_INSTANCE_FILE="${CONFIG_DIR}/hotspot_instance"
INSTANCES_FILE="${MODDIR}/.instances"
COEXIST_CONF="${CONFIG_DIR}/coexist.conf"
HOTSPOT_SCRIPT="${MODDIR}/hotspot_iprule.sh"
COEXIST_SCRIPT="${MODDIR}/coexist.sh"
LOG_FILE="${MODDIR}/log.log"
MODULE_PROP="${MODDIR}/module.prop"
EASYTIER="${MODDIR}/easytier-core"
HOTSPOT_CIDR_FILE="${MODDIR}/.hotspot_cidr"
DEBUG_CONF="${CONFIG_DIR}/debug.conf"
DEBUG_FLAG="${MODDIR}/enable_debug"

BRAND=$(getprop ro.product.brand 2>/dev/null | tr ' ' '-')
MODEL=$(getprop ro.product.model 2>/dev/null | tr ' ' '-')
DEVICE_HOSTNAME="${BRAND}-${MODEL}"
[ "$DEVICE_HOSTNAME" = "-" ] && DEVICE_HOSTNAME="android"

REDIR_STATUS=""
ET_SOCKET_MARK=""
COEXIST_ENABLE=0
[ -f "$COEXIST_CONF" ] && . "$COEXIST_CONF" 2>/dev/null

is_debug_mode() {
    [ -f "$DEBUG_FLAG" ] && return 0
    if [ -f "$DEBUG_CONF" ]; then
        grep -qE '^[[:space:]]*DEBUG[[:space:]]*=[[:space:]]*[1-9]' "$DEBUG_CONF" 2>/dev/null && return 0
    fi
    return 1
}

log() { echo "[ET] $(date '+%F %T') $1" >> "$LOG_FILE"; }
debug_log() {
    is_debug_mode || return 0
    echo "[ET-DEBUG] $(date '+%F %T') $1" >> "$LOG_FILE"
}

# log.log 是只追加的事件日志，长期运行会无限增长。
# 超过 256KB 时只保留最后 500 行（相当于滚动），避免塞满 /data。
trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 262144 ] || return 0
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
}

# ===== 工具 =====

# 从 toml 里读一个标量键（取第一条匹配）
toml_get() {
    [ -f "$1" ] || return 0
    awk -v k="$2" '
        BEGIN { IGNORECASE = 1 }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            v = $0
            sub(/^[^=]*=[[:space:]]*/, "", v)
            gsub(/["\047]/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v
            exit
        }
    ' "$1" 2>/dev/null
}

# 文件名 -> 安全的实例名（字母数字下划线横杠，最长 32）
safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-32
}

# 列出所有配置：输出 "名字<TAB>路径"
list_configs() {
    if [ -f "$COMMAND_ARGS" ]; then
        printf 'default\t%s\n' "$COMMAND_ARGS"
        return
    fi
    if [ -d "$NETWORKS_DIR" ] && [ -n "$(ls -1 "$NETWORKS_DIR"/*.toml 2>/dev/null)" ]; then
        for f in "$NETWORKS_DIR"/*.toml; do
            [ -f "$f" ] || continue
            base=$(basename "$f" .toml)
            printf '%s\t%s\n' "$(safe_name "$base")" "$f"
        done
        return
    fi
    if [ -f "$LEGACY_CONFIG" ]; then
        printf 'default\t%s\n' "$LEGACY_CONFIG"
    fi
}

# 配置是参数文件（而不是 toml）
is_args_config() { [ "$1" = "$COMMAND_ARGS" ]; }

# 热点出口实例名
hotspot_instance_name() {
    H=$(head -n1 "$HOTSPOT_INSTANCE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$H" ]; then
        printf '%s' "$H"
    else
        list_configs | head -n1 | cut -f1
    fi
}

# 统计本模块实际在跑的实例数（按配置路径精确匹配，
# 不会把系统里无关的 easytier-core 进程算进来）
count_core() {
    N=0
    LISTF="${MODDIR}/.configlist.count"
    list_configs > "$LISTF" 2>/dev/null
    while IFS="$(printf '\t')" read -r name cfg; do
        [ -z "$cfg" ] && continue
        instance_running "$cfg" && N=$((N + 1))
    done < "$LISTF"
    rm -f "$LISTF"
    printf '%s' "$N"
}

# 快速判断单个 PID 是否对应目标配置
pid_matches_config() {
    PID="$1"; TARGET="$2"
    [ -n "$PID" ] && [ -d "/proc/$PID" ] || return 1
    [ -r "/proc/$PID/cmdline" ] || return 1
    CMD=$(tr '\000' ' ' < "/proc/$PID/cmdline" 2>/dev/null)
    case "$CMD" in
        *easytier-core*"-c ${TARGET} "*|*easytier-core*"-c ${TARGET}") return 0 ;;
        *) return 1 ;;
    esac
}

# 找出以某个配置文件启动的 easytier-core 进程 PID。
# 优化：
#   1. 优先查 .pid-* 记录，命中即 O(1) 返回，彻底杜绝轮询遍历 /proc 带来的性能卡顿
#   2. 兜底逐个检查 /proc/<pid>/cmdline
pids_for_config() {
    TARGET="$1"
    # 优先查 pid 缓存文件
    for f in "${MODDIR}"/.pid-*; do
        [ -f "$f" ] || continue
        P=$(cat "$f" 2>/dev/null)
        if pid_matches_config "$P" "$TARGET"; then
            echo "$P"
            return 0
        fi
    done

    # 兜底：扫描 /proc
    for pdir in /proc/[0-9]*; do
        [ -r "${pdir}/cmdline" ] || continue
        P="${pdir#/proc/}"
        pid_matches_config "$P" "$TARGET" && echo "$P"
    done
}

instance_running() { [ -n "$(pids_for_config "$1")" ]; }

kill_instance() {
    pids_for_config "$1" | while read -r p; do kill "$p" 2>/dev/null; done
}


kill_all() {
    for f in "${MODDIR}"/.pid-*; do
        [ -f "$f" ] || continue
        p=$(cat "$f" 2>/dev/null)
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    list_configs 2>/dev/null | while IFS="$(printf '\t')" read -r name cfg; do
        [ -n "$cfg" ] && kill_instance "$cfg"
    done
    sleep 2s
    for f in "${MODDIR}"/.pid-*; do
        [ -f "$f" ] || continue
        p=$(cat "$f" 2>/dev/null)
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null
        rm -f "$f"
    done
    list_configs 2>/dev/null | while IFS="$(printf '\t')" read -r name cfg; do
        [ -z "$cfg" ] && continue
        pids_for_config "$cfg" | while read -r p; do kill -9 "$p" 2>/dev/null; done
    done
}

# ===== 物理网卡 / 出网可用性 =====

# 系统当前用来出网的物理网卡（默认路由所在接口）。
# Android 的 main 表通常没有默认路由，默认路由在 netd 的具名表里，
# 所以 `ip route get` 出来的 dev 就是当前"活跃"网卡，这里据此判断。
egress_iface() {
    # 技巧 1：优先 ip route get（快，且给出"此刻真的会走哪块"）
    D=$(ip route get 8.8.8.8 2>/dev/null \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    case "$D" in
        et*|tun*|dummy*|lo|"") D="" ;;
        *) printf '%s' "$D"; return 0 ;;
    esac

    # 技巧 2：Android 上 main 表往往是空的，默认路由在 netd 的具名表里。
    # 扫所有表里的 default 路由，排除虚拟/回环网卡。
    ip route show table all 2>/dev/null | awk '
        /^default/ {
            for (i = 1; i < NF; i++) {
                if ($i == "dev") {
                    dev = $(i + 1)
                    if (dev !~ /^(et|tun|dummy|lo)/) {
                        print dev
                        exit
                    }
                }
            }
        }
    '
}

# 这个内核上"未绑定网卡的 socket 能否出网"。
# 这是 hs1/hs2 断网问题的另一种成因：netd 的规则带 `oif <iface>`，
# 只匹配已绑定该网卡的 socket。未绑定的 socket 没有 oif，
# 一路落到 `32000: from all unreachable` → ENETUNREACH(101)。
unbound_can_route() {
    # 用 main 表判定：未绑定网卡的 socket 只按 main 表找路
    # （netd 的具名表规则都带 `oif <iface>`，未绑定 socket 没有 oif，匹配不到）。
    ip route show table main 2>/dev/null | grep -q '^default' && return 0
    # main 没有默认路由时，再看内核给不给 out（部分 ROM 会在 main 里放 default）
    R=$(ip route get 8.8.8.8 2>&1)
    case "$R" in
        *unreachable*|*"Network is unreachable"*|"") return 1 ;;
    esac
    return 0
}

# 是否给 easytier 加 --bind-device（默认开启）。
#
# ⚠️ 为什么默认开启、而不是"探测到有问题才开"：
# hs4 早期版本只在「启动那一刻未绑定 socket 出不去」时才加 --bind-device。
# 但真机案例证明这不够——启动时 WiFi 正常（未绑定的 socket 能出网），
# 于是没加；几分钟后 WiFi 断开切到移动数据，netd 规则换成
# `oif rmnet_data2` 形态，未绑定的 socket 立刻变成 101，
# 所有 peer 同时掉线且再也连不回来（core 日志里 4 条 peer removed 同一秒发生）。
#
# 实测结论（netns + 真实 peer）：
#   - 未绑定的 socket 在 Android oif 规则下拿到 101（内核直接拒发）；
#   - bind_device=true 后同一个 peer 变成 "connect timeout"（SYN 已发出）；
#   - 绑定后能真实连上 peer（new peer added）；
#   - **网络切换（wlan0→rmnet）后自动跟随，无需重启进程**；
#   - 在正常网络（main 表有默认路由）下同样能正常连 peer，无副作用；
#   - 不影响 tun 建立与 [[proxy_network]] 热点代理。
#
# 所以一律开启更稳：它没有已知副作用，却能免疫切网。
should_bind_device() {
    # 用户显式关掉就不碰
    [ -f "${MODDIR}/disable_bind_device" ] && return 1
    return 0
}

# ===== mesh 网段可达性修复 =====
#
# 问题：Android netd 的规则普遍带 `uidrange 0-0` 或 `iif lo` 限定，
# 而普通 App（Termux、浏览器）发出的包带 netId fwmark（如 0x10064），
# 既不是 uid 0、也不带 oif，于是匹配不到任何具名表规则，
# 一路落到 `32000: from all unreachable` → ping 自己的 mesh 虚拟 IP 也报
# `Network is unreachable`，表现为「peer 明明连上了，却 ping 不通 10.10.0.x」。
#
# 实测（内核路由查找，最准确的判据）：
#   ip route get 10.10.0.1              -> 10.10.0.1 dev etC src 10.10.0.3 uid 0
#   ip route get 10.10.0.1 mark 0x10064 -> Network is unreachable   ← App 的真实遭遇
# 加一条 `pref 1000 to 10.10.0.0/24 lookup main` 后：
#   ip route get 10.10.0.1 mark 0x10064 -> 10.10.0.1 dev etC src 10.10.0.3
#   ping 10.10.0.1 -> 2 received, 0% packet loss
#
# 为什么是 to <mesh cidr> 而不是改 main 表的默认路由：
#   只影响「发往 mesh 网段」的包，其它流量完全不受影响，
#   也不会干扰 netd 的 fwmark 分流（那是运营商计费/VPN 判定的基础）。

MESH_RULE_PREF=1000
MESH_RULES_FILE="${MODDIR}/.mesh_rules"

flush_mesh_rules() {
    [ -f "$MESH_RULES_FILE" ] || return 0
    while read -r pref cidr; do
        [ -n "$pref" ] && [ -n "$cidr" ] || continue
        ip rule del pref "$pref" to "$cidr" 2>/dev/null
    done < "$MESH_RULES_FILE"
    : > "$MESH_RULES_FILE"
}

# 给每个实例的 tun 网段加一条直达 main 表的规则。
#
# 两个安全约束：
#   1. 该网段必须真的指向我们的 tun 设备（防止物理 LAN 恰好同段时把内网流量
#      导进隧道 —— 例如常见冲突：物理内网 10.20.1.0/24 与 mesh 同段）；
#   2. 幂等：已存在的规则不重复添加、也不拆了重建，避免每轮出现可达性空窗。
ensure_mesh_rules() {
    [ -f "${MODDIR}/disable_mesh_route" ] && { flush_mesh_rules; return 0; }

    : > "${MESH_RULES_FILE}.new"
    N_NEW=0
    for cidr in $(mesh_cidrs); do
        [ -n "$cidr" ] || continue
        # 约束 1：main 表里这个网段必须指向 et* 设备
        DEV=$(ip route show table main 2>/dev/null \
            | awk -v c="$cidr" '$1 == c { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
        case "$DEV" in et[0-9]*) ;; *) continue ;; esac

        # 约束 2：已存在就不动
        if ip rule show 2>/dev/null | grep -qE "^${MESH_RULE_PREF}:.*to ${cidr}([ /]|$)"; then
            printf '%s %s\n' "$MESH_RULE_PREF" "$cidr" >> "${MESH_RULES_FILE}.new"
            continue
        fi

        if ip rule add pref "$MESH_RULE_PREF" to "$cidr" lookup main 2>/dev/null; then
            printf '%s %s\n' "$MESH_RULE_PREF" "$cidr" >> "${MESH_RULES_FILE}.new"
            N_NEW=$((N_NEW + 1))
        fi
    done

    # 清理"规则存在但网段已失效"的旧条目（实例被删/改网段）
    if [ -f "$MESH_RULES_FILE" ]; then
        while read -r pref old; do
            [ -n "$pref" ] && [ -n "$old" ] || continue
            grep -qxF "$pref $old" "${MESH_RULES_FILE}.new" 2>/dev/null && continue
            ip rule del pref "$pref" to "$old" 2>/dev/null
        done < "$MESH_RULES_FILE"
    fi
    mv -f "${MESH_RULES_FILE}.new" "$MESH_RULES_FILE" 2>/dev/null

    [ "$N_NEW" -gt 0 ] && log "已放行 ${N_NEW} 个 mesh 网段（App 可 ping 虚拟 IP）"
    return 0
}

# 收集所有实例 tun 的网段（规范化为网络地址/前缀）
# 注意：这里不调用 coexist.sh 里的 iface_cidrs —— 两个脚本是独立进程，
# 不能跨文件依赖函数，就地实现一份。
mesh_cidrs() {
    for d in $(tun_devices); do
        [ -n "$d" ] || continue
        ip -4 route show dev "$d" 2>/dev/null \
            | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// { print $1 }'
    done | sort -u
}

tun_devices() {
    if [ -f "$INSTANCES_FILE" ]; then
        awk -F'\t' '$2 != "" { print $2 }' "$INSTANCES_FILE"
    fi
    # 兜底：扫系统里所有 et* 接口（多实例时 .instances 可能还没写全）
    ip -o link show 2>/dev/null | awk -F': ' '{ print $2 }' | grep -E '^et[0-9]+$'
}

# ===== DNS 可达性修复 =====
#
# 问题：Android 的 netd 规则形如
#   `19000: from all iif lo oif wlan0 uidrange 0-0 lookup wlan0`
# 带 `oif <物理网卡>`，只匹配「已绑定该网卡」的 socket。
# easytier 的 --bind-device 只覆盖隧道 socket，**DNS 解析用的 socket 没被绑定**，
# 于是 DNS 查询一路落到 `32000: from all unreachable` → ENETUNREACH(101)，
# 日志表现为：
#   hickory dns lookup_ip failed, host: xxx
#   Os { code: 101, message: "Network unreachable" }
# 而它连的是域名 peer，于是「本机明明有网，easytier 一个 peer 都连不上」。
#
# 修复：给每个配置的 DNS 服务器加一条
#   `ip rule add pref <DNS_RULE_PREF> to <dns-ip>/32 lookup <物理表>`
# 只放行「发往 DNS 服务器」的包，其它流量仍按原规则走，不影响系统行为。
# 注意：往 main 表加主机路由是**没用的** ——
# `32000: from all unreachable` 排在 `32766: lookup main` 之前，先命中就断了。

DNS_RULE_PREF=79
DNS_RULES_FILE="${MODDIR}/.dns_rules"

# 读出配置里的域名，反查出它们当前用到的 DNS 服务器地址
configured_dns_servers() {
    {
        # 模块自带的 resolv.conf 覆盖层
        awk '/^nameserver/ { print $2 }' "${MODDIR}/system/etc/resolv.conf" 2>/dev/null
        # 系统实际用的（Android 上通常是 127.0.0.1，走 netd dnsproxy，不需要放行）
        awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null
    } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | grep -vE '^127\.' \
      | sort -u
}

flush_dns_rules() {
    [ -f "$DNS_RULES_FILE" ] || return 0
    while read -r pref ip; do
        [ -n "$pref" ] && [ -n "$ip" ] || continue
        ip rule del pref "$pref" to "${ip}/32" 2>/dev/null
    done < "$DNS_RULES_FILE"
    : > "$DNS_RULES_FILE"
}

# 确保每个配置的 DNS 服务器均有直达物理出口表的路由规则。
# 根因修复：未绑定网卡的 hickory-dns UDP 请求会落到 32000 unreachable，
# 导致全部域名 peer 报 resolve timeout 连不上。
ensure_dns_rules() {
    [ -f "${MODDIR}/disable_dns_rule" ] && return 0

    TBL=$(route_table_for_egress) || return 0
    [ -n "$TBL" ] || return 0

    LAST_TBL=$(cat "${MODDIR}/.last_dns_table" 2>/dev/null)
    if [ -n "$LAST_TBL" ] && [ "$TBL" != "$LAST_TBL" ]; then
        flush_dns_rules
    fi
    printf '%s' "$TBL" > "${MODDIR}/.last_dns_table"

    N=0
    for ip in $(configured_dns_servers); do
        if ip rule show 2>/dev/null | grep -qE "^${DNS_RULE_PREF}:.*to ${ip}([ /]|$)"; then
            continue
        fi
        if ip rule add pref "$DNS_RULE_PREF" to "${ip}/32" lookup "$TBL" 2>/dev/null; then
            printf '%s %s\n' "$DNS_RULE_PREF" "$ip" >> "$DNS_RULES_FILE"
            N=$((N + 1))
        fi
    done
    [ "$N" -gt 0 ] && log "已放行 ${N} 个 DNS 服务器（table=${TBL}），修复域名 peer 解析超时"
    return 0
}

# 找到当前物理出口网卡对应的具名/编号路由表，用于 DNS 放行
route_table_for_egress() {
    CUR=$(egress_iface)
    [ -n "$CUR" ] || return 1

    # 优先：从路由表中查找绑定该网卡的 default 路由表
    TBL=$(ip route show table all 2>/dev/null | awk -v d="$CUR" '
        /^default/ {
            is_dev = 0; tbl = ""
            for (i = 1; i < NF; i++) {
                if ($i == "dev" && $(i + 1) == d) is_dev = 1
                if ($i == "table") tbl = $(i + 1)
            }
            if (is_dev) {
                print (tbl != "" ? tbl : "main")
                exit
            }
        }
    ')
    if [ -n "$TBL" ]; then
        printf '%s' "$TBL"
        return 0
    fi

    # 兜底：从 ip rule 中查找匹配 oif $CUR 的表号
    TBL=$(ip rule show 2>/dev/null | awk -v d="$CUR" '
        $0 ~ ("oif " d) {
            for (i = 1; i < NF; i++) if ($i == "lookup") { print $(i + 1); exit }
        }
    ' | head -n1)
    [ -n "$TBL" ] && { printf '%s' "$TBL"; return 0; }

    return 1
}

# ===== 每实例参数 =====
# 自动分配规则（只在该字段缺失/冲突时生效，不改动用户的 toml 文件）：
#   dev_name      缺省 -> et<序号>            冲突 -> et<序号>
#   instance_name 缺省 -> 文件名
#   rpc_portal    缺省 -> 127.0.0.1:1588<序号> 冲突 -> 递增
#   hostname      缺省 -> 设备型号

# 扫描所有配置，收集已显式声明的 dev_name / rpc_portal
collect_declared() {
    DECLARED_DEVS=""
    DECLARED_RPCS=""
    list_configs | while IFS="$(printf '\t')" read -r name cfg; do
        is_args_config "$cfg" && continue
        d=$(toml_get "$cfg" dev_name)
        r=$(toml_get "$cfg" rpc_portal)
        [ -n "$d" ] && echo "D $d"
        [ -n "$r" ] && echo "R $r"
    done
}

# 生成 .instances（供 hotspot_iprule.sh / coexist.sh 复用），
# 同时把每实例的最终 dev_name 定下来。
# 注意：全部用 here-doc 喂数据、不用管道，避免子 shell 里变量丢失。
write_instances() {
    TMP="${INSTANCES_FILE}.tmp"
    : > "$TMP"

    LISTF="${MODDIR}/.configlist.tmp"
    list_configs > "$LISTF"

    # 第一轮：登记用户显式声明的 dev_name，避免自动分配撞上
    USED_DEVS=" "
    while IFS="$(printf '\t')" read -r name cfg; do
        [ -z "$name" ] && continue
        is_args_config "$cfg" && continue
        d=$(toml_get "$cfg" dev_name)
        [ -n "$d" ] && USED_DEVS="${USED_DEVS}${d} "
    done < "$LISTF"

    # 第二轮：给缺 dev_name 的分配未占用的名字
    IDX=0
    while IFS="$(printf '\t')" read -r name cfg; do
        [ -z "$name" ] && continue
        IDX=$((IDX + 1))

        if is_args_config "$cfg"; then
            DEV=$(get_tun_iface_lazy)
            RPC=$(awk '
                {
                    for (i=1; i<=NF; i++) {
                        if ($i == "-r" || $i == "--rpc-portal") {
                            print $(i+1)
                            exit
                        }
                    }
                }
            ' "$cfg" 2>/dev/null)
            [ -z "$RPC" ] && RPC="127.0.0.1:15888"
            printf '%s\t%s\t%s\t%s\n' "$name" "$DEV" "$cfg" "$RPC" >> "$TMP"
            continue
        fi

        DEV=$(toml_get "$cfg" dev_name)
        if [ -z "$DEV" ]; then
            N=0
            while [ $N -lt 32 ]; do
                CAND="et${N}"
                case "$USED_DEVS" in
                    *" $CAND "*) N=$((N + 1)) ;;
                    *) DEV="$CAND"; USED_DEVS="${USED_DEVS}${CAND} "; break ;;
                esac
            done
            [ -z "$DEV" ] && DEV="et${IDX}"
        fi

        RPC=$(toml_get "$cfg" rpc_portal)
        [ -z "$RPC" ] && RPC="127.0.0.1:1588$((IDX - 1))"

        printf '%s\t%s\t%s\t%s\n' "$name" "$DEV" "$cfg" "$RPC" >> "$TMP"
    done < "$LISTF"

    rm -f "$LISTF"
    mv -f "$TMP" "$INSTANCES_FILE" 2>/dev/null
}

get_tun_iface_lazy() {
    ip link 2>/dev/null | awk -F': ' '/ tun[[:alnum:]]+/ {print $2; exit}'
}

# 该名字是否已在 .instances 里
instance_dev() {
    awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' "$INSTANCES_FILE" 2>/dev/null
}

# 该名字对应的 RPC 地址
instance_rpc() {
    awk -F'\t' -v n="$1" '$1 == n { print $4; exit }' "$INSTANCES_FILE" 2>/dev/null
}

# ===== 模块描述 =====
update_module_description() {
    [ -f "${MODULE_PROP}" ] || return 0
    CUR=$(grep "^description=" "${MODULE_PROP}")
    NEW="description=[状态] $1"
    [ "${CUR}" = "${NEW}" ] || sed -i "s#^description=.*#${NEW}#" "${MODULE_PROP}"
}

# ===== TUN 准备 =====
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net 2>/dev/null
    ln -s /dev/tun /dev/net/tun 2>/dev/null
fi

# ===== 子网代理网段收集 =====
CIDR_RE='[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+(->[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+)?'

# 从单个配置里取用户已写的 proxy 网段，兼容两种语法：
#   顶层 proxy_networks = [ "a/b", ... ]
#   [[proxy_network]] + cidr = "a/b"
collect_user_proxies_for() {
    cfg="$1"
    [ -f "$cfg" ] || return 0
    {
        awk '
            /^[[:space:]]*proxy_networks[[:space:]]*=/ { inarr = 1 }
            inarr { print }
            inarr && /\]/ { inarr = 0 }
        ' "$cfg"
        awk '
            /^[[:space:]]*\[\[proxy_network\]\]/ { next }
            /^[[:space:]]*cidr[[:space:]]*=/ { print }
        ' "$cfg"
    } 2>/dev/null | grep -oE "$CIDR_RE" | sort -u
}

# ===== 启动单个实例 =====
start_instance() {
    NAME="$1"
    CFG="$2"
    LOG="${MODDIR}/core-${NAME}.log"

    # core 日志超过 1MB 清空
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        : > "$LOG"
    fi

    EXTRA=""

    if is_args_config "$CFG"; then
        CMD_CONTENT=$(tr '\r\n' ' ' < "$CFG")
        if echo "$CMD_CONTENT" | grep -q -- "--hostname"; then
            BASE_ARGS="$CMD_CONTENT"
        else
            BASE_ARGS="$CMD_CONTENT --hostname $DEVICE_HOSTNAME"
        fi
        # 参数模式：热点网段只能追加 --proxy-networks（若用户没写）
        if [ "$NAME" = "$HOTSPOT_NAME" ] && [ -f "${MODDIR}/enable_IP_rule" ] \
            && [ -f "$HOTSPOT_CIDR_FILE" ]; then
            HOT_ARG=$(tr ' ' '\n' < "$HOTSPOT_CIDR_FILE" 2>/dev/null | grep -E '^[0-9]' | tr '\n' ' ')
            [ -n "$HOT_ARG" ] && EXTRA="--proxy-networks $HOT_ARG"
        fi
    else
        DEV=$(toml_get "$CFG" dev_name)
        [ -z "$DEV" ] && DEV=$(instance_dev "$NAME")
        INST=$(toml_get "$CFG" instance_name)
        [ -z "$INST" ] && INST="$NAME"
        RPC=$(instance_rpc "$NAME")
        [ -z "$RPC" ] && RPC=$(toml_get "$CFG" rpc_portal)
        if [ -z "$RPC" ]; then
            IDX=0
            for n in $(list_configs | cut -f1); do
                IDX=$((IDX + 1))
                [ "$n" = "$NAME" ] && break
            done
            RPC="127.0.0.1:1588$((IDX - 1))"
        fi

        BASE_ARGS="-c $CFG"
        # 只要 toml 没显式声明 rpc_portal，注入分配的 -r 参数
        if [ -z "$(toml_get "$CFG" rpc_portal)" ]; then
            BASE_ARGS="$BASE_ARGS -r $RPC"
        fi
        [ -n "$DEV" ] && BASE_ARGS="$BASE_ARGS --dev-name $DEV"
        BASE_ARGS="$BASE_ARGS -m $INST"
        [ -z "$(toml_get "$CFG" hostname)" ] && BASE_ARGS="$BASE_ARGS --hostname $DEVICE_HOSTNAME"

        # 只有热点出口实例才注入热点网段，并保留用户自己写的网段
        if [ "$NAME" = "$HOTSPOT_NAME" ] && [ -f "${MODDIR}/enable_IP_rule" ] \
            && [ -f "$HOTSPOT_CIDR_FILE" ]; then
            HOT_ARG=$(tr ' ' '\n' < "$HOTSPOT_CIDR_FILE" 2>/dev/null | grep -E '^[0-9]' | tr '\n' ' ')
            if [ -n "$HOT_ARG" ]; then
                MERGED=$( { echo "$HOT_ARG"; collect_user_proxies_for "$CFG"; } \
                    | grep -oE "$CIDR_RE" | sort -u | tr '\n' ' ')
                EXTRA="$EXTRA --proxy-networks $MERGED"
            fi
        fi
    fi

    # 物理网卡绑定：未绑定 socket 在 Android 式路由下会 101 断网。
    # 这是"本机有网但 easytier 连不上"最常见的原因。
    BIND_DEV=$(egress_iface)
    if should_bind_device; then
        EXTRA="$EXTRA --bind-device true"
        if unbound_can_route; then
            log "实例 ${NAME} 绑定物理网卡${BIND_DEV:+ ${BIND_DEV}}（默认开启，免疫切网）"
        else
            log "检测到未绑定 socket 无法出网，实例 ${NAME} 绑定物理网卡 ${BIND_DEV}"
        fi
    fi

    # fwmark 共存：每个进程都加，规则只需一条
    if [ "$COEXIST_ENABLE" = "1" ] && [ -n "$ET_SOCKET_MARK" ] && [ ! -f "${MODDIR}/disable_coexist" ]; then
        if "${COEXIST_SCRIPT}" verify >/dev/null 2>&1; then
            EXTRA="$EXTRA --socket-mark $ET_SOCKET_MARK"
        fi
    fi

    # Debug 日志等级环境变量注入
    ENV_EXTRA=""
    if is_debug_mode; then
        LVL="debug"
        [ -f "$DEBUG_CONF" ] && LVL=$(awk -F= '/^[[:space:]]*CORE_LOG_LEVEL[[:space:]]*=/ {gsub(/["[:space:]]/, "", $2); print $2}' "$DEBUG_CONF" 2>/dev/null)
        [ -z "$LVL" ] && LVL="debug"
        ENV_EXTRA="RUST_LOG=${LVL},easytier=trace"
        debug_log "实例 ${NAME} 注入环境变量: ${ENV_EXTRA}"
    fi

    log "启动实例 ${NAME}: dev=${DEV:-auto}${EXTRA:+ | $EXTRA}"
    TZ=Asia/Shanghai env $ENV_EXTRA "$EASYTIER" $BASE_ARGS $EXTRA > "$LOG" 2>&1 &
    PID=$!
    echo $PID > "${MODDIR}/.pid-${NAME}"

    # 进程优先级与防冻结保护（防止 Android 低内存 OOM 杀进程，或 MIUI/HyperOS millet 冻结）
    echo -1000 > "/proc/$PID/oom_score_adj" 2>/dev/null
    for cpuset in /dev/cpuset/foreground /dev/cpuset/top-app /sys/fs/cgroup/freezer; do
        [ -w "${cpuset}/cgroup.procs" ] && echo $PID > "${cpuset}/cgroup.procs" 2>/dev/null
        [ -w "${cpuset}/tasks" ] && echo $PID > "${cpuset}/tasks" 2>/dev/null
    done
}

# ===== 主循环 =====
HOTSPOT_NAME=$(hotspot_instance_name)

while true; do
    # 状态串
    NCFG=$(list_configs | grep -c . 2>/dev/null)
    [ -f "${MODDIR}/enable_IP_rule" ] && REDIR_STATUS="转发已激活" || REDIR_STATUS="转发已禁用"

    # 模块被停用
    if [ -f "${MODDIR}/disable" ]; then
        update_module_description "主程序已关闭 | ${REDIR_STATUS}"
        [ "$(count_core)" -gt 0 ] && kill_all
        flush_dns_rules
        flush_mesh_rules
        sleep 10s
        continue
    fi

    # 热点网段变化 -> 全部重启（只有出口实例参数会变）
    if [ -f "${MODDIR}/.restart_easytier" ]; then
        rm -f "${MODDIR}/.restart_easytier"
        log "热点网段变化，重启所有实例"
        kill_all
    fi

    # 默认出口网卡变化（WiFi <-> 移动数据切换）-> 重启所有实例。
    #
    # 为什么必须重启：切网后 netd 会把规则换成 `oif <新网卡>` 形态，
    # 旧进程即使开着 --bind-device 也仍绑定在已消失的网卡上，
    # 结果是所有 peer 同时掉线且再也连不回来。
    # （实测 --bind-device 能跟随"默认路由变化"，但无法跟随"网卡消失"，稳妥起见直接重启。）
    CUR_IFACE=$(egress_iface)
    LAST_IFACE=$(cat "${MODDIR}/.last_egress_iface" 2>/dev/null)
    if [ -n "$CUR_IFACE" ] && [ -n "$LAST_IFACE" ] && [ "$CUR_IFACE" != "$LAST_IFACE" ]; then
        log "默认出口网卡变化 ${LAST_IFACE} -> ${CUR_IFACE}，重启所有实例"
        kill_all
    fi
    [ -n "$CUR_IFACE" ] && printf '%s' "$CUR_IFACE" > "${MODDIR}/.last_egress_iface"

    # 无配置
    if [ "$NCFG" -eq 0 ]; then
        update_module_description "缺少配置文件（config/networks/*.toml）"
        sleep 10s
        continue
    fi

    HOTSPOT_NAME=$(hotspot_instance_name)

    # 刷新热点 CIDR
    [ -x "$HOTSPOT_SCRIPT" ] && "$HOTSPOT_SCRIPT" probe >/dev/null 2>&1

    # 共存规则先就位（verify 依赖 ip rule）
    [ -x "$COEXIST_SCRIPT" ] && "$COEXIST_SCRIPT" apply >/dev/null 2>&1

    # DNS 放行规则：域名 peer 解析失败（code 101）的根因修复
    ensure_dns_rules

    # mesh 网段规则：App ping 不通虚拟 IP 的根因修复
    # 放在启动之后立刻补一次：首轮 tun 还没 up，等下一轮会白等 10 秒
    ensure_mesh_rules

    write_instances

    # 逐个检查并拉起
    STARTED=0
    list_configs | while IFS="$(printf '\t')" read -r name cfg; do
        [ -z "$name" ] && continue
        if ! instance_running "$cfg"; then
            start_instance "$name" "$cfg"
            sleep 2s
        fi
    done

    sleep 3s

    # tun 起来之后再补一次 mesh 规则（首轮调用时 tun 往往还没 up）
    ensure_mesh_rules

    RUNNING=$(count_core)
    if is_debug_mode; then
        debug_log "心跳: 物理出口=${CUR_IFACE:-无}, 活跃实例=${RUNNING}/${NCFG}, 转发=${REDIR_STATUS}"
    fi

    if [ "$RUNNING" -gt 0 ]; then
        update_module_description "运行中 ${RUNNING}/${NCFG} 个实例 | ${REDIR_STATUS}"
    else
        update_module_description "全部启动失败，请检查 config/networks/ | ${REDIR_STATUS}"
    fi

    trim_log
    sleep 10s
done
