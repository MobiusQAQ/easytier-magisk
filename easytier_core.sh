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
[ -f "${MODDIR}/module.prop" ] || MODDIR="/data/adb/modules/easytier_magisk"
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
CLI_BIN="${MODDIR}/easytier-cli-bin"
[ -x "$CLI_BIN" ] || CLI_BIN="${MODDIR}/easytier-cli"
DAEMON_PID_FILE="${MODDIR}/.daemon.pid"

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

# log.log 与 core-*.log 日志滚动修剪，避免长期运行或调试模式塞满 /data
trim_log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 262144 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
    for clog in "${MODDIR}"/core-*.log; do
        [ -f "$clog" ] || continue
        if [ "$(wc -c < "$clog" 2>/dev/null || echo 0)" -gt 5242880 ]; then
            tail -n 2000 "$clog" > "${clog}.tmp" 2>/dev/null && mv -f "${clog}.tmp" "$clog"
        fi
    done
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
    H=$(grep -vE '^[[:space:]]*(#|$)' "$HOTSPOT_INSTANCE_FILE" 2>/dev/null | head -n1 | tr -d ' \t\r\n')
    if [ -n "$H" ] && { [ -f "${NETWORKS_DIR}/${H}.toml" ] || grep -qE "^${H}[[:space:]]" "$INSTANCES_FILE" 2>/dev/null; }; then
        printf '%s' "$H"
    else
        list_configs | head -n1 | cut -f1
    fi
}

# 统计本模块实际在跑的实例数（极速无损统计，避免重复扫描与子进程膨胀，自动回收失效 pid）
count_core() {
    local n=0
    for f in "${MODDIR}"/.pid-*; do
        [ -f "$f" ] || continue
        local p
        p=$(cat "$f" 2>/dev/null)
        if [ -n "$p" ] && [ -d "/proc/$p" ] && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "easytier-core" ]; then
            n=$((n + 1))
        else
            rm -f "$f" 2>/dev/null
        fi
    done
    printf '%s' "$n"
}

# 快速判断单个 PID 是否对应目标配置
pid_matches_config() {
    PID="$1"; TARGET="$2"
    [ -n "$PID" ] && [ -d "/proc/$PID" ] || return 1
    # 优先校验进程名称，非 easytier-core 立即跳过，避免无谓读取 cmdline
    [ "$(cat "/proc/$PID/comm" 2>/dev/null)" = "easytier-core" ] || return 1
    # 避免使用 tr 直接读取 procfs（Toybox tr 在目标进程并发死亡报错 ESRCH 时会陷入 100% CPU 死循环）
    grep -q -F "$TARGET" "/proc/$PID/cmdline" 2>/dev/null
}

# 找出以某个配置文件启动的 easytier-core 进程 PID。
# 优化：
#   1. 优先查 .pid-* 记录，命中即 O(1) 返回，彻底杜绝轮询遍历 /proc 带来的性能卡顿
#   2. 次级兜底：使用 pgrep 精准定位系统中的 easytier-core 进程
#   3. 终极兜底：仅对 comm 为 easytier-core 的进程进行匹配
pids_for_config() {
    TARGET="$1"
    # 1. 优先查 pid 缓存文件
    for f in "${MODDIR}"/.pid-*; do
        [ -f "$f" ] || continue
        P=$(cat "$f" 2>/dev/null)
        if pid_matches_config "$P" "$TARGET"; then
            echo "$P"
            return 0
        else
            if [ -n "$P" ] && [ ! -d "/proc/$P" ]; then
                rm -f "$f" 2>/dev/null
            fi
        fi
    done

    # 2. 次级兜底：使用 pgrep 直接定位 easytier-core 进程
    if command -v pgrep >/dev/null 2>&1 || [ -x /system/bin/pgrep ]; then
        for P in $(/system/bin/pgrep -f easytier-core 2>/dev/null || pgrep -f easytier-core 2>/dev/null); do
            if pid_matches_config "$P" "$TARGET"; then
                echo "$P"
                return 0
            fi
        done
        return 0
    fi

    # 3. 终极兜底：扫描 /proc，先校验 comm == easytier-core
    for pdir in /proc/[0-9]*; do
        P="${pdir#/proc/}"
        if pid_matches_config "$P" "$TARGET"; then
            echo "$P"
            return 0
        fi
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

# 系统当前物理出口特征：网卡 路由表 源IP
# 相比单网卡名，能精准捕捉同网卡重连（如 WiFi 漫游、基站切新内网IP、Android netd 重建路由表）
egress_info() {
    # 策略 1：优先通过 ip route get 8.8.8.8 获取当前生效出口特征
    D=$(ip route get 8.8.8.8 2>/dev/null | awk '
        {
            for (i = 1; i < NF; i++) {
                if ($i == "dev") dev = $(i + 1)
                if ($i == "table") tbl = $(i + 1)
                if ($i == "src") src = $(i + 1)
            }
            if (dev != "" && dev !~ /^(et|tun|dummy|lo)/) {
                print dev, (tbl != "" ? tbl : "main"), (src != "" ? src : "none")
                exit
            }
        }
    ')
    if [ -n "$D" ]; then
        printf '%s' "$D"
        return 0
    fi

    # 策略 2：兜底扫描系统默认路由
    ip route show table all 2>/dev/null | awk '
        /^default/ {
            for (i = 1; i < NF; i++) {
                if ($i == "dev") {
                    dev = $(i + 1)
                    if (dev !~ /^(et|tun|dummy|lo)/) {
                        tbl = ""
                        for (j = 1; j < NF; j++) if ($j == "table") tbl = $(j + 1)
                        print dev, (tbl != "" ? tbl : "main"), "none"
                        exit
                    }
                }
            }
        }
    '
}

# 系统当前用来出网的物理网卡（默认路由所在接口）。
egress_iface() {
    egress_info | awk '{print $1}'
}

# 触发所有实例进行一次 STUN 刷新（快速上报新公网 IP/端口至中心节点）
trigger_stun_refresh() {
    [ -x "$CLI_BIN" ] || return 0
    [ -f "$INSTANCES_FILE" ] || return 0
    # 防抖：若已存在活跃的 stun 探测，不重复堆叠并发
    if pgrep -f "easytier-cli.*stun" >/dev/null 2>&1; then
        return 0
    fi
    debug_log "触发所有运行中实例的 STUN 刷新以加速恢复网络..."
    for irpc in $(awk -F'\t' '{print $4}' "$INSTANCES_FILE" 2>/dev/null); do
        [ -n "$irpc" ] || continue
        (
            "$CLI_BIN" -p "$irpc" stun >/dev/null 2>&1
        ) &
    done
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

# 是否给 easytier 加 --bind-device
# 
# 默认保持关闭（同原版行为），允许 socket 在网络切换时随默认路由自由漂移，实现秒级重连；
# 避免使用 SO_BINDTODEVICE 将 socket 强行锁死在已失效的物理网卡上导致掉线。
# 仅当用户显式创建 enable_bind_device 开关时才注入 --bind-device。
should_bind_device() {
    [ -f "${MODDIR}/disable_bind_device" ] && return 1
    [ -f "${MODDIR}/enable_bind_device" ] && return 0
    return 1
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
    if [ -f "$DNS_RULES_FILE" ]; then
        while read -r pref ip; do
            [ -n "$pref" ] && [ -n "$ip" ] || continue
            ip rule del pref "$pref" to "${ip}/32" 2>/dev/null
        done < "$DNS_RULES_FILE"
        : > "$DNS_RULES_FILE"
    fi
    for ip in $(configured_dns_servers); do
        ip rule del pref "$DNS_RULE_PREF" to "${ip}/32" 2>/dev/null || true
    done
}

# 确保每个配置的 DNS 服务器均有直达物理出口表的路由规则。
# 根因修复：未绑定网卡的 hickory-dns UDP 请求会落到 32000 unreachable，
# 导致全部域名 peer 报 resolve timeout 连不上。
ensure_dns_rules() {
    [ -f "${MODDIR}/disable_dns_rule" ] && return 0

    TBL=$(route_table_for_egress) || return 0
    [ -n "$TBL" ] || return 0

    LAST_TBL=$(cat "${MODDIR}/.last_dns_table" 2>/dev/null)
    if [ "$TBL" != "$LAST_TBL" ]; then
        flush_dns_rules
    fi
    printf '%s' "$TBL" > "${MODDIR}/.last_dns_table"

    N=0
    for ip in $(configured_dns_servers); do
        if ip rule show 2>/dev/null | grep -qE "^${DNS_RULE_PREF}:.*to ${ip}([ /]|$).*lookup ${TBL}([ /]|$)"; then
            continue
        fi
        ip rule del pref "$DNS_RULE_PREF" to "${ip}/32" 2>/dev/null || true
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
    INFO=$(egress_info)
    TBL=$(printf '%s' "$INFO" | awk '{print $2}')
    if [ -n "$TBL" ] && [ "$TBL" != "main" ] && [ "$TBL" != "none" ]; then
        printf '%s' "$TBL"
        return 0
    fi
    CUR=$(printf '%s' "$INFO" | awk '{print $1}')
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
            case "$RPC" in
                0.0.0.0:*|\[::\]:*) RPC="127.0.0.1:${RPC##*:}" ;;
                :*) RPC="127.0.0.1:${RPC##*:}" ;;
            esac
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
        case "$RPC" in
            0.0.0.0:*|\[::\]:*) RPC="127.0.0.1:${RPC##*:}" ;;
            :*) RPC="127.0.0.1:${RPC##*:}" ;;
        esac

        printf '%s\t%s\t%s\t%s\n' "$name" "$DEV" "$cfg" "$RPC" >> "$TMP"
    done < "$LISTF"

    rm -f "$LISTF"
    # 只有内容发生实质变化才覆盖写入，避免频繁刷写闪存与唤醒 I/O
    if [ ! -f "$INSTANCES_FILE" ] || ! cmp -s "$TMP" "$INSTANCES_FILE" 2>/dev/null; then
        mv -f "$TMP" "$INSTANCES_FILE" 2>/dev/null
    else
        rm -f "$TMP" 2>/dev/null
    fi
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

    # 物理网卡绑定：当且仅当用户显式开启 enable_bind_device 时启用。
    # 原版 EasyTier 默认不绑定设备，切网时内核自动走新出口，恢复仅需 1~2 秒。
    BIND_DEV=$(egress_iface)
    if should_bind_device; then
        EXTRA="$EXTRA --bind-device true"
        log "实例 ${NAME} 绑定物理网卡${BIND_DEV:+ ${BIND_DEV}}（已启用 enable_bind_device 开关）"
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
        ENV_EXTRA="RUST_LOG=${LVL}"
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

# 单例保护：确保只有一个守护循环在运行，杜绝并发竞争与僵尸进程
acquire_daemon_lock() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null | tr -d ' \r\n')
        if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && [ -d "/proc/$old_pid" ]; then
            if grep -q -F "easytier_core.sh" "/proc/$old_pid/cmdline" 2>/dev/null; then
                log "终止旧守护进程 (PID $old_pid)，接管后台守护"
                kill -9 "$old_pid" 2>/dev/null
            fi
        fi
    fi
    echo "$$" > "$DAEMON_PID_FILE"
}

# 支持 --refresh-network 命令行快速刷新网络与 DNS（供 action.sh reconnect / 脚本直接调用）
if [ "${1:-}" = "--refresh-network" ]; then
    rm -f "${MODDIR}/.last_dns_table" "${MODDIR}/.last_egress_info" "${MODDIR}/.last_egress_iface"
    ensure_dns_rules
    ensure_mesh_rules
    [ "$COEXIST_ENABLE" = "1" ] && [ -x "$COEXIST_SCRIPT" ] && "$COEXIST_SCRIPT" apply >/dev/null 2>&1
    trigger_stun_refresh
    exit 0
fi

# 启动守护单例锁定
acquire_daemon_lock
trap 'rm -f "${DAEMON_PID_FILE}" 2>/dev/null' EXIT INT TERM

# 启动初始共存检查
[ -x "$COEXIST_SCRIPT" ] && "$COEXIST_SCRIPT" apply >/dev/null 2>&1

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

    # 默认出口网卡/路由特征变化（WiFi <-> 移动数据切换 / WiFi 漫游切网）
    # 机制：保持核心进程存活，不销毁 tun 与已有 socket，由协议层直接在几十毫秒~1秒内恢复连接；
    # 仅动态刷新当前出口网卡的 DNS 放行规则与策略路由，并并发触发 STUN 探测快速建立打洞。
    # 若特定 ROM 遇到极端异常需要硬重启进程，可创建 restart_on_network_change 开关。
    CUR_EGRESS_INFO=$(egress_info)
    CUR_IFACE=$(printf '%s' "$CUR_EGRESS_INFO" | awk '{print $1}')
    LAST_EGRESS_INFO=$(cat "${MODDIR}/.last_egress_info" 2>/dev/null || true)
    if [ -n "$CUR_IFACE" ] && [ -n "$LAST_EGRESS_INFO" ] && [ "$CUR_EGRESS_INFO" != "$LAST_EGRESS_INFO" ]; then
        if [ -f "${MODDIR}/restart_on_network_change" ]; then
            log "物理出口网络变化 [${LAST_EGRESS_INFO}] -> [${CUR_EGRESS_INFO}]（启用了 restart_on_network_change 开关），重启所有实例"
            kill_all
        else
            log "物理出口网络变化 [${LAST_EGRESS_INFO}] -> [${CUR_EGRESS_INFO}]，立即刷新 DNS 与策略路由并触发 STUN 快速重连"
            rm -f "${MODDIR}/.last_dns_table"
            ensure_dns_rules
            ensure_mesh_rules
            [ "$COEXIST_ENABLE" = "1" ] && [ -x "$COEXIST_SCRIPT" ] && "$COEXIST_SCRIPT" apply >/dev/null 2>&1
            trigger_stun_refresh
        fi
    fi
    [ -n "$CUR_IFACE" ] && printf '%s' "$CUR_EGRESS_INFO" > "${MODDIR}/.last_egress_info"
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

    # 共存规则（仅在明确启用时维护）
    [ "$COEXIST_ENABLE" = "1" ] && [ -x "$COEXIST_SCRIPT" ] && "$COEXIST_SCRIPT" apply >/dev/null 2>&1

    # DNS 放行规则：域名 peer 解析失败（code 101）的根因修复
    ensure_dns_rules

    # mesh 网段规则：App ping 不通虚拟 IP 的根因修复
    ensure_mesh_rules

    write_instances

    # 逐个检查并拉起，同步实时 PID
    list_configs | while IFS="$(printf '\t')" read -r name cfg; do
        [ -z "$name" ] && continue
        PID=$(pids_for_config "$cfg")
        if [ -n "$PID" ]; then
            echo "$PID" > "${MODDIR}/.pid-${name}"
        else
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
    sleep 3s
done
