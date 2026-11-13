#!/bin/bash
# 核心机制验证：TPROXY 劫持出站 vs socket-mark 放行
# 拓扑: host(手机, 跑 A + TPROXY) -- veth --> netns:rem(内网, 跑 B)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; D="${D:-$SCRIPT_DIR/..}"
CORE=$D/easytier-core; CLI=$D/easytier-cli
IT=iptables
MARK=20052
RNET=rem

hard_clean() {
  pkill -9 -f "$CORE --ipv4 10.126.1" 2>/dev/null
  ip netns del $RNET 2>/dev/null
  ip link del p-rem 2>/dev/null
  sleep 1; ip link del p-rem 2>/dev/null
  for j in "PREROUTING -j TPX" "OUTPUT -j TPX" "PREROUTING -j CO" "OUTPUT -j CO"; do
    $IT -t mangle -D $j 2>/dev/null
  done
  for c in TPX CO; do $IT -t mangle -F $c 2>/dev/null; $IT -t mangle -X $c 2>/dev/null; done
  ip rule del pref 100 2>/dev/null; ip rule del pref 80 2>/dev/null
  ip route flush table 100 2>/dev/null
  conntrack -D -p tcp 2>/dev/null >/dev/null
}

tproxy_on() {
  ip route add local default dev lo table 100
  ip rule add pref 100 fwmark 0x1 lookup 100
  $IT -t mangle -N TPX
  $IT -t mangle -A TPX -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port 9999 --tproxy-mark 0x1/0x1
  $IT -t mangle -A PREROUTING -j TPX
  $IT -t mangle -A OUTPUT -j TPX
}

coex_on() {
  $IT -t mangle -N CO
  $IT -t mangle -I OUTPUT 1 -j CO
  $IT -t mangle -A CO -m mark --mark $MARK -j CONNMARK --save-mark
  $IT -t mangle -A CO -m mark --mark $MARK -j ACCEPT
  $IT -t mangle -I PREROUTING 1 -j CO
  $IT -t mangle -A CO -m connmark --mark $MARK -j ACCEPT
  $IT -t mangle -A CO -d 10.126.128.0/24 -j ACCEPT
  ip rule add pref 80 fwmark $MARK lookup main
}

# $1=label $2=A额外参数 $3=是否开共存(1/0)
run() {
  echo "########## $1 ##########"
  hard_clean
  ip netns add $RNET
  ip link add p-rem type veth peer name r-rem
  ip link set r-rem netns $RNET
  ip -4 addr add 10.90.0.1/24 dev p-rem 2>/dev/null || ip -4 addr add 10.90.0.1/24 dev p-rem
  ip link set p-rem up
  ip netns exec $RNET ip link set lo up
  ip netns exec $RNET ip link set r-rem up
  ip netns exec $RNET ip -4 addr add 10.90.0.2/24 dev r-rem
  ip netns exec $RNET ip route add default via 10.90.0.1 dev r-rem
  sleep 1
  echo "  [拓扑] host ping rem:"; ping -c1 -W2 10.90.0.2 >/dev/null 2>&1 && echo "    ok" || echo "    FAIL"
  # B 在 rem netns
  ip netns exec $RNET $CORE --ipv4 10.126.128.2/24 --listeners tcp://0.0.0.0:30002 \
    --hostname B --network-name t --network-secret s --rpc-portal 127.0.0.1:15902 \
    --no-tun >/tmp/rb.log 2>&1 &
  sleep 2
  tproxy_on
  [ "$3" = 1 ] && coex_on
  # A 在 host
  $CORE --ipv4 10.126.128.1/24 --listeners tcp://0.0.0.0:30001 $2 --peers tcp://10.90.0.2:30002 \
    --hostname A --network-name t --network-secret s --rpc-portal 127.0.0.1:15901 \
    --no-tun >/tmp/ra.log 2>&1 &
  local ok=no
  for i in $(seq 8); do
    sleep 3
    timeout 4 $CLI --rpc-portal 127.0.0.1:15901 peer list 2>/dev/null | grep -q 10.126.128.2 && { ok=YES; break; }
  done
  echo "  A-B 建连: $ok"
  echo "  TPX 命中包数: $($IT -t mangle -L TPX -n -v 2>/dev/null | awk 'NR==3{print $1}')"
  [ "$ok" = no ] && echo "  A 尾: $(tail -1 /tmp/ra.log | sed 's/.*INFO//;s/^ *//;s/^[A-Z:_0-9* ]*//' | cut -c1-120)"
  pkill -9 -f "$CORE --ipv4 10.126.1" 2>/dev/null
  hard_clean
}

# 注意: --no-tun 下 A 仍有 ipv4 但 B 侧 peer 用真实 tcp。peer list 里对端显示其 ipv4。
run "对照: 仅 TPROXY 劫持（无共存）" "" 0
run "测试: TPROXY + socket-mark 共存" "--socket-mark $MARK" 1
echo "DONE"
