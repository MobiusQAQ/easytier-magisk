#!/bin/bash
# 端到端验证: TPROXY 共存 + 热点共享内网 (网桥模拟, 每轮独立环境)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; D="${D:-$SCRIPT_DIR/..}"
CORE=$D/easytier-core; CLI=$D/easytier-cli
MARK=20052
IT=iptables

pre_clean() {
  pkill -9 -f "$CORE" 2>/dev/null
  ip link del tun0 2>/dev/null; sleep 1; ip link del tun0 2>/dev/null
  for n in bhost mesh client; do ip netns del $n 2>/dev/null; done
  for l in br-h bh-eth bh-m bh-c vhost vmesh; do ip link del $l 2>/dev/null; done
  $IT -t mangle -S 2>/dev/null | awk '/^-A (PREROUTING|OUTPUT).*(TPX|COEX|CONNMARK)/ {print}' | \
    sed "s/-A \(PREROUTING\|OUTPUT\) /-D \1 /" | while read -r r; do $IT -t mangle $r 2>/dev/null; done
  for c in TPX ET_COEX_IN ET_COEX_OUT; do $IT -t mangle -F $c 2>/dev/null; $IT -t mangle -X $c 2>/dev/null; done
  ip rule del pref 100 2>/dev/null; ip rule del pref 80 2>/dev/null
  ip netns exec mesh iptables -t mangle -S 2>/dev/null | grep -q TPX && {
    ip netns exec mesh iptables -t mangle -D PREROUTING -j TPX 2>/dev/null
    ip netns exec mesh iptables -t mangle -D OUTPUT -j TPX 2>/dev/null
    ip netns exec mesh iptables -t mangle -F TPX 2>/dev/null
    ip netns exec mesh iptables -t mangle -X TPX 2>/dev/null
    ip netns exec mesh ip rule del pref 100 2>/dev/null
  }
  conntrack -F 2>/dev/null
  sleep 2
}

topo_up() {
  mkdir -p /run/netns
  ip netns add mesh; ip netns add client
  ip link add br-h type bridge
  ip link add bh-eth type dummy; ip link set bh-eth master br-h; ip link set bh-eth up
  ip link add vhost type veth peer name vmesh
  ip link set vhost master br-h; ip link set vhost up
  ip link set vmesh netns mesh
  ip link add bh-c type veth peer name bc
  ip link set bh-c master br-h; ip link set bh-c up
  ip link set bc netns client; ip netns exec client ip link set bc up
  ip -4 addr add 10.99.0.1/24 dev br-h; ip link set br-h up
  ip netns exec mesh ip link set lo up
  ip netns exec mesh ip link set vmesh up
  ip -4 addr add 10.99.0.2/24 dev vmesh
  ip netns exec mesh ip route add default via 10.99.0.1
  ip netns exec client ip link set lo up
  ip -4 addr add 192.168.43.100/24 dev bc
  ip netns exec client ip route add default via 10.99.0.1 192.168.43.100 dev bc 2>/dev/null || \
    ip netns exec client ip route add default via 10.99.0.1 dev bc
  ip link set lo up
  echo 1 > /proc/sys/net/ipv4/ip_forward
  for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 2 > "$f" 2>/dev/null; done
}

tproxy_on_phone() {   # 模拟 Clash: 手机 host netns 劫持所有 TCP
  ip route add local default dev lo table 100
  ip rule add pref 100 fwmark 0x1 lookup 100
  $IT -t mangle -N TPX
  $IT -t mangle -A TPX -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port 9999 --tproxy-mark 0x1/0x1
  $IT -t mangle -A PREROUTING -j TPX
  $IT -t mangle -A OUTPUT -j TPX
}

coex_on_phone() {    # 模拟 coexist.sh apply_rules（手机 host netns）
  $IT -t mangle -N ET_COEX_OUT
  $IT -t mangle -I OUTPUT 1 -j ET_COEX_OUT
  $IT -t mangle -A ET_COEX_OUT -m mark --mark $MARK -j CONNMARK --save-mark
  $IT -t mangle -A ET_COEX_OUT -m mark --mark $MARK -j ACCEPT
  $IT -t mangle -N ET_COEX_IN
  $IT -t mangle -I PREROUTING 1 -j ET_COEX_IN
  $IT -t mangle -A ET_COEX_IN -m connmark --mark $MARK -j ACCEPT
  $IT -t mangle -A ET_COEX_IN -s 10.126.126.0/24 -j ACCEPT
  $IT -t mangle -A ET_COEX_IN -d 10.126.126.0/24 -j ACCEPT
  ip rule add pref 80 fwmark $MARK lookup main
}

# run_round <portB> <coex 0/1> <extraA>
run_round() {
  local PB=$1 COEX=$2 EXTRA=$3
  echo "########## 轮: portB=$PB coexist=$COEX ##########"
  pre_clean
  topo_up
  ip netns exec mesh $CORE --ipv4 10.126.126.2/24 --listeners tcp://0.0.0.0:$PB \
    --hostname B --network-name t --network-secret s --rpc-portal 127.0.0.1:15879 \
    >/tmp/B_$PB.log 2>&1 &
  sleep 3
  tproxy_on_phone
  [ "$COEX" = 1 ] && coex_on_phone
  $CORE --ipv4 10.126.126.1/24 --listeners tcp://0.0.0.0:27111 \
    --peers tcp://10.99.0.2:$PB --hostname A --network-name t --network-secret s \
    --rpc-portal 127.0.0.1:15878 $EXTRA >/tmp/A_$PB.log 2>&1 &
  local ok=0
  for i in 1 2 3 4 5 6; do
    sleep 5
    timeout 5 $CLI --rpc-portal 127.0.0.1:15878 peer list 2>/dev/null | grep -q 10.126.126.2 && { ok=1; break; }
  done
  if [ "$ok" = 1 ]; then
    echo "peer: ✓ 建连 (穿过 TPROXY)"
    # 热点转发规则（手机侧,等价 hotspot_iprule.sh add_once 在 enable 时叠加的 proxy-networks）
    $IT -t nat -N ET_NAT 2>/dev/null; $IT -t nat -F ET_NAT
    $IT -t nat -C POSTROUTING -j ET_NAT 2>/dev/null || $IT -t nat -I POSTROUTING 1 -j ET_NAT
    $IT -t nat -A ET_NAT -s 192.168.43.0/24 -o tun0 -j MASQUERADE
    $IT -N ET_FWD 2>/dev/null; $IT -F ET_FWD
    $IT -C FORWARD -j ET_FWD 2>/dev/null || $IT -I FORWARD 1 -j ET_FWD
    $IT -A ET_FWD -i br-h -o tun0 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    $IT -A ET_FWD -i tun0 -o br-h -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    echo "--- client(192.168.43.100) ping mesh B(10.126.126.2):"
    ip netns exec client ping -c 3 -W 2 10.126.126.2 2>&1 | grep -E "packets transmitted|rtt"
    echo "--- B 侧看到 proxy CIDR:"; grep "proxy CIDRs" /tmp/B_$PB.log | tail -1
  else
    echo "peer: ✗ 未建连"
    tail -2 /tmp/A_$PB.log
    echo "TPX 命中:"; $IT -t mangle -L TPX -n -v 2>/dev/null | sed -n 3p
  fi
  pkill -9 -f "$CORE" 2>/dev/null
}

run_round 25112 0 ""
run_round 26112 1 "--socket-mark $MARK"
pre_clean
echo DONE
