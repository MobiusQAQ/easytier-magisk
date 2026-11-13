#!/system/bin/sh
# EasyTier Magisk 一键现场诊断与日志打包脚本 (dump_debug.sh)
#
# 运行方式：
#   sh /data/adb/modules/easytier_magisk/dump_debug.sh
# 或在终端/Su中直接执行：
#   /data/adb/modules/easytier_magisk/action.sh dump

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/easytier_magisk"

DATE_STR=$(date '+%Y%m%d_%H%M%S')
DUMP_DIR="${MODDIR}/debug_dump_${DATE_STR}"
TAR_NAME="easytier_debug_${DATE_STR}.tar.gz"
OUTPUT_TAR="${MODDIR}/${TAR_NAME}"

mkdir -p "$DUMP_DIR" 2>/dev/null || DUMP_DIR="/data/local/tmp/easytier_debug_${DATE_STR}"
mkdir -p "$DUMP_DIR"

echo "=== 开始收集 EasyTier 现场诊断信息 ==="
echo "临时目录: $DUMP_DIR"

# 1. 设备与环境基本信息
{
    echo "=== 设备与系统信息 ==="
    echo "收集时间: $(date '+%F %T %Z')"
    echo "Linux 内核: $(uname -a 2>/dev/null)"
    echo "系统运行时间: $(uptime 2>/dev/null)"
    echo "设备型号: $(getprop ro.product.brand 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
    echo "Android 版本: $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null))"
    echo "ROM 标识: $(getprop ro.build.display.id 2>/dev/null)"
    echo "Root 环境: $([ -d /data/adb/ksu ] && echo 'KernelSU' || ([ -d /data/adb/ap ] && echo 'APatch' || echo 'Magisk'))"
} > "${DUMP_DIR}/device_info.txt" 2>&1

# 2. 模块自身状态与配置
{
    echo "=== module.prop ==="
    cat "${MODDIR}/module.prop" 2>/dev/null
    echo ""
    echo "=== .instances ==="
    cat "${MODDIR}/.instances" 2>/dev/null
    echo ""
    echo "=== 进程 PID 记录 ==="
    ls -la "${MODDIR}"/.pid-* 2>/dev/null
    for f in "${MODDIR}"/.pid-*; do
        [ -f "$f" ] && echo "$f: $(cat "$f")"
    done
    echo ""
    echo "=== 标记与规则缓存文件 ==="
    ls -la "${MODDIR}"/.* 2>/dev/null
    echo ""
    echo "=== .mesh_rules ==="
    cat "${MODDIR}/.mesh_rules" 2>/dev/null
    echo "=== .dns_rules ==="
    cat "${MODDIR}/.dns_rules" 2>/dev/null
    echo "=== .hotspot_cidr ==="
    cat "${MODDIR}/.hotspot_cidr" 2>/dev/null
    echo "=== .last_egress_iface ==="
    cat "${MODDIR}/.last_egress_iface" 2>/dev/null
} > "${DUMP_DIR}/module_state.txt" 2>&1

# 3. 配置文件（自动脱敏密码）
mkdir -p "${DUMP_DIR}/configs"
if [ -d "${MODDIR}/config" ]; then
    cp -a "${MODDIR}/config/." "${DUMP_DIR}/configs/" 2>/dev/null
    # 对所有 toml 中的 network_secret 进行脱敏
    find "${DUMP_DIR}/configs" -type f -name "*.toml" -o -name "*.conf" 2>/dev/null | while read -r cf; do
        sed -i -E 's/(network_secret[[:space:]]*=[[:space:]]*").*"/\1<redacted>"/g' "$cf" 2>/dev/null
    done
fi

# 4. 网络接口与 IP
{
    echo "=== ip link show ==="
    ip -d link show 2>/dev/null
    echo ""
    echo "=== ip -4 addr show ==="
    ip -4 addr show 2>/dev/null
    echo ""
    echo "=== ip -6 addr show ==="
    ip -6 addr show 2>/dev/null
} > "${DUMP_DIR}/network_interfaces.txt" 2>&1

# 5. 策略路由规则与各表路由
{
    echo "=== ip rule show ==="
    ip rule show 2>/dev/null
    echo ""
    echo "=== ip -6 rule show ==="
    ip -6 rule show 2>/dev/null
    echo ""
    echo "=== ip route show table main ==="
    ip route show table main 2>/dev/null
    echo ""
    echo "=== ip route show table all (默认路由与具名表) ==="
    ip route show table all 2>/dev/null
} > "${DUMP_DIR}/routing_snapshot.txt" 2>&1

# 6. iptables / ip6tables 防火墙规则
{
    echo "=== iptables-save ==="
    iptables-save 2>/dev/null
    echo ""
    echo "=== ip6tables-save ==="
    ip6tables-save 2>/dev/null
} > "${DUMP_DIR}/iptables_dump.txt" 2>&1

# 7. 系统与 DNS 连通性测试
{
    echo "=== 系统 DNS 配置 ==="
    echo "system/etc/resolv.conf:"
    cat "${MODDIR}/system/etc/resolv.conf" 2>/dev/null
    echo "/etc/resolv.conf:"
    cat /etc/resolv.conf 2>/dev/null
    echo "getprop net.dns:"
    getprop | grep -iE 'dns|rmnet|wlan' 2>/dev/null

    echo ""
    echo "=== Ping 测试 ==="
    echo "Ping 223.5.5.5 (阿里公共 DNS):"
    ping -c 2 -W 2 223.5.5.5 2>&1
    echo "Ping 119.29.29.29 (腾讯公共 DNS):"
    ping -c 2 -W 2 119.29.29.29 2>&1

    echo ""
    echo "=== 内核路由查找测试 (ip route get) ==="
    echo "ip route get 8.8.8.8:"
    ip route get 8.8.8.8 2>&1
    echo "ip route get 223.5.5.5:"
    ip route get 223.5.5.5 2>&1
    if [ -f "${MODDIR}/.mesh_rules" ]; then
        awk '{print $2}' "${MODDIR}/.mesh_rules" 2>/dev/null | head -n3 | while read -r cidr; do
            test_ip=$(echo "$cidr" | sed 's#/[0-9]*##; s#[0-9]*$#1#')
            echo "ip route get $test_ip (uid 0):"
            ip route get "$test_ip" 2>&1
            echo "ip route get $test_ip (mark 0x10064 App 视角):"
            ip route get "$test_ip" mark 0x10064 2>&1
        done
    fi
} > "${DUMP_DIR}/connectivity_test.txt" 2>&1

# 8. 进程信息与日志
{
    echo "=== EasyTier 进程列表 ==="
    ps -ef 2>/dev/null | grep -E 'easytier|hotspot|coexist' | grep -v grep
    echo ""
    for f in "${MODDIR}"/.pid-*; do
        [ -f "$f" ] || continue
        inst=$(basename "$f" | sed 's/^\.pid-//')
        pid=$(cat "$f" 2>/dev/null)
        echo "--- 实例 $inst (PID: $pid) ---"
        if [ -d "/proc/$pid" ]; then
            echo "cmdline: $(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
            echo "oom_score: $(cat "/proc/$pid/oom_score" 2>/dev/null), oom_score_adj: $(cat "/proc/$pid/oom_score_adj" 2>/dev/null)"
            grep -E 'State|VmRSS|Threads' "/proc/$pid/status" 2>/dev/null
        else
            echo "进程已不存在 (已挂或未启动)"
        fi
    done
} > "${DUMP_DIR}/process_status.txt" 2>&1

# 复制日志文件
mkdir -p "${DUMP_DIR}/logs"
[ -f "${MODDIR}/log.log" ] && cp -f "${MODDIR}/log.log" "${DUMP_DIR}/logs/" 2>/dev/null
for cf in "${MODDIR}"/core-*.log; do
    [ -f "$cf" ] && cp -f "$cf" "${DUMP_DIR}/logs/" 2>/dev/null
done
[ -f "${MODDIR}/daemon.log" ] && cp -f "${MODDIR}/daemon.log" "${DUMP_DIR}/logs/" 2>/dev/null

# 9. 内核与基带关键日志
{
    echo "=== dmesg (最新 300 行) ==="
    dmesg 2>/dev/null | tail -n 300
} > "${DUMP_DIR}/dmesg_tail.txt" 2>&1

if command -v dumpsys >/dev/null 2>&1; then
    dumpsys telephony.registry 2>/dev/null | head -n 120 > "${DUMP_DIR}/telephony_registry.txt" 2>&1
fi

# 10. 打包
cd "$DUMP_DIR/.."
tar -czf "$OUTPUT_TAR" "$(basename "$DUMP_DIR")" 2>/dev/null
rm -rf "$DUMP_DIR"

# 同时也拷贝一份到 /sdcard，方便用户直接从手机下载或微信/QQ发送
for sd in /sdcard /storage/emulated/0; do
    if [ -d "$sd" ]; then
        cp -f "$OUTPUT_TAR" "${sd}/${TAR_NAME}" 2>/dev/null
        cp -f "$OUTPUT_TAR" "${sd}/easytier_debug.tar.gz" 2>/dev/null
        echo "已同步导出到手机存储: ${sd}/${TAR_NAME}"
        break
    fi
done

echo "=== 现场诊断包收集完成 ==="
echo "模块包路径: $OUTPUT_TAR"
ls -lh "$OUTPUT_TAR" 2>/dev/null
