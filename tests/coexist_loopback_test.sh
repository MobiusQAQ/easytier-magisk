#!/bin/bash
# 机制验证: 两个 easytier 实例走 127.0.0.1, 主机 TPROXY 劫持所有 TCP,
# 对照「无共存」vs「有共存(socket-mark + mangle 放行 + fwmark main)」
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; D="${D:-$SCRIPT_DIR/..}"
CORE=$D/easytier-core; CLI=$D/easytier-cli
IT=iptables
MARK=20052

cleanup() {
  for p in 29001 29002; do pkill -9 -f "listeners tcp://0.0.0.0:$p" 2>/dev/null; done
  $IT -t mangle -D PREROUTING -j TPX 2>/dev/null; $IT -t mangle -D OUTPUT -j TPX 2>/dev/null
  $IT -t mangle -F TPX 2>/dev/null; $IT -t mangle -X TPX 2>/dev/null
  $IT -t mangle -D OUTPUT -j CO 2>/dev/null; $IT -t mangle -D PREROUTING -j CO 2>/dev/null
  $IT -t mangle -F CO 2>/dev/null; $IT -t mangle -X CO 2>/dev/null
  ip rule del pref 100 2>/dev/null; ip rule del pref 80 2>/dev/null
  ip route flush table 100 2>/dev/null
  conntrack -D -p tcp 2>/dev/null >/dev/null
  sleep 1
}

tpx_on() {
  ip route add local default dev lo table 100
  ip rule add pref 100 fwmark 0x1 lookup 100
  $IT -t mangle -N TPX
  $IT -t mangle -A TPX -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port 9999 --tproxy-mark 0x1/0x1
  $IT -t mangle -A PREROUTING -j TPX
  $IT -t mangle -A OUTPUT -j TPX
}

coex_on() {   # 等价 coexist.sh apply_rules（本机回环版）
  $IT -t mangle -N CO
  $IT -t mangle -I OUTPUT 1 -j CO
  $IT -t mangle -A CO -m mark --mark $MARK -j CONNMARK --save-mark
  $IT -t mangle -A CO -m mark --mark $MARK -j ACCEPT
  $IT -t mangle -I PREROUTING 1 -j CO
  $IT -t mangle -A CO -m connmark --mark $MARK -j ACCEPT
  ip rule add pref 80 fwmark $MARK lookup main
}

# <label> <markA> <markB> <apply_coex>
run() {
  local L=$1 MA=$2 MB=$3 CX=$4
  echo "===== $L ====="
  cleanup
  tpx_on; [ "$CX" = 1 ] && coex_on
  $CORE --ipv4 10.126.127.2/24 --listeners tcp://0.0.0.0:29002 $MB \
    --hostname NB --network-name t --network-secret s --rpc-portal 127.0.0.1:15897 \
    --no-tun >/tmp/nb.log 2>&1 &
  sleep 2
  $CORE --ipv4 10.126.127.1/24 --listeners tcp://0.0.0.0:29001 $MA --peers tcp://127.0.0.1:29002 \
    --hostname NA --network-name t --network-secret s --rpc-portal 127.0.0.1:15896 \
    --no-tun >/tmp/na.log 2>&1 &
  local ok=no
  for i in 1 2 3 4 5 6 7 8; do
    sleep 3
    timeout 4 $CLI --rpc-portal 127.0.0.1:15896 peer list 2>/dev/null | grep -q "10.126.127.2" && { ok=YES; break; }
  done
  echo "peer 建连: $ok"
  echo "TPX 计数: $($IT -t mangle -L TPX -n 2>/dev/null | sed -n 3p | awk '{print $1, $2}') 包/字节"
  echo "na.log 尾: $(tail -1 /tmp/na.log | cut -c1-140)"
  cleanup
}

run "对照: TPROXY 劫持, 无共存" "" "" 0
run "共存: socket-mark + mangle + fwmark rule" "--socket-mark $MARK" "--socket-mark $MARK" 1
echo DONE
