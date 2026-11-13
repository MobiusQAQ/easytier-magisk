MODDIR=${0%/*}
# 多实例：先按 .pid-* 干净地杀掉，再兜底全杀
for f in "${MODDIR}"/.pid-*; do
    [ -f "$f" ] || continue
    kill "$(cat "$f" 2>/dev/null)" 2>/dev/null
done
pkill -f "${MODDIR}/easytier-core" 2>/dev/null
sleep 1s
pkill -9 -f "${MODDIR}/easytier-core" 2>/dev/null

# 卸载前把内核态残留清干净（不依赖脚本之后还能跑）
# 1) 热点转发链
iptables -t nat -F ET_NAT 2>/dev/null
iptables -t nat -D POSTROUTING -j ET_NAT 2>/dev/null
iptables -t nat -X ET_NAT 2>/dev/null
iptables -F ET_FWD 2>/dev/null
iptables -D FORWARD -j ET_FWD 2>/dev/null
iptables -X ET_FWD 2>/dev/null

# 2) TPROXY 共存链
iptables -t mangle -D OUTPUT -j ET_COEX_OUT 2>/dev/null
iptables -t mangle -F ET_COEX_OUT 2>/dev/null
iptables -t mangle -X ET_COEX_OUT 2>/dev/null
iptables -t mangle -D PREROUTING -j ET_COEX_IN 2>/dev/null
iptables -t mangle -F ET_COEX_IN 2>/dev/null
iptables -t mangle -X ET_COEX_IN 2>/dev/null

# 3) DNS 放行规则
if [ -f "${MODDIR}/.dns_rules" ]; then
    while read -r pref ip; do
        [ -n "$pref" ] && [ -n "$ip" ] || continue
        ip rule del pref "$pref" to "${ip}/32" 2>/dev/null
    done < "${MODDIR}/.dns_rules"
fi
rm -f "${MODDIR}/.dns_rules"

# 3.5) mesh 网段规则
if [ -f "${MODDIR}/.mesh_rules" ]; then
    while read -r pref cidr; do
        [ -n "$pref" ] && [ -n "$cidr" ] || continue
        ip rule del pref "$pref" to "$cidr" 2>/dev/null
    done < "${MODDIR}/.mesh_rules"
fi
rm -f "${MODDIR}/.mesh_rules"

# 4) 本模块加的 fwmark 策略路由规则（按 mark 扫，兼容历史遗留）
[ -x "${MODDIR}/coexist.sh" ] && "${MODDIR}/coexist.sh" flush >/dev/null 2>&1
i=0
while [ $i -lt 8 ] && ip rule show 2>/dev/null | grep -q 'fwmark 0x4e54'; do
    PREF=$(ip rule show 2>/dev/null | grep 'fwmark 0x4e54' | head -n1 | cut -d: -f1)
    [ -n "$PREF" ] || break
    ip rule del pref "$PREF" 2>/dev/null || break
    i=$((i + 1))
done

# 使用 ${MODDIR:?} 确保变量非空，避免执行 rm -rf /*
rm -rf "${MODDIR:?}/"*
