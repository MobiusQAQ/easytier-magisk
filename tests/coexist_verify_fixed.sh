#!/bin/bash
# 共存机制验证（v3，符合 TPROXY 语义的正确写法）
#
# TPROXY 只能用于 PREROUTING（内核限制，OUTPUT 链加 TPROXY 会 EINVAL）。
# 模拟真实 clash 的 dual-path：
#   出向: OUTPUT 给"本机新发起"的 TCP 打 mark 0x1 -> 策略路由进 table 100
#   入向: PREROUTING 对带 mark 的包 TPROXY 到本地代理端口
# easytier 用 --socket-mark $MARK 给自身 socket 打 SO_MARK，
# 再配 ip rule pref 80 fwmark $MARK lookup main 让这些包直连、不进 table 100。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; D="${D:-$SCRIPT_DIR/..}"
CORE=$D/easytier-core; CLI=$D/easytier-cli
MARK=20052
RNET=rem

clean() {
  # 只杀真正的 easytier-core 进程（-x 精确匹配进程名），
  # 绝不能用 pkill -f "$CORE" —— 会匹配到本脚本自身的命令行把自己杀掉
  pkill -9 -x easytier-core 2>/dev/null
  ip netns del $RNET 2>/dev/null
  ip link del p-rem 2>/dev/null
  sleep 0.5
  iptables -t mangle -D PREROUTING -j TPX 2>/dev/null
  iptables -t mangle -D OUTPUT -j CLASHOUT 2>/dev/null
  for c in TPX CLASHOUT; do iptables -t mangle -F $c 2>/dev/null; iptables -t mangle -X $c 2>/dev/null; done
  ip rule del fwmark $MARK lookup main 2>/dev/null
  ip rule del pref 100 2>/dev/null
  ip route flush table 100 2>/dev/null
}

# 模拟 clash：只劫持"去往 B 隧道端口 30002"的出向 TCP（真实 clash 按规则分流，
# 不会劫持本机监听端口的 accept 路径，否则任何程序都无法监听）
tproxy_on() {
  ip route add local default dev lo table 100 2>/dev/null
  ip rule add pref 100 fwmark 0x1 lookup 100 2>/dev/null
  # 出向：仅对 dport=30002 的新连接打 mark 0x1
  iptables -t mangle -N CLASHOUT 2>/dev/null
  iptables -t mangle -A CLASHOUT -p tcp --dport 30002 -j MARK --set-mark 0x1 2>/dev/null
  iptables -t mangle -I OUTPUT 1 -j CLASHOUT 2>/dev/null
  # 入向：带 mark 的包 TPROXY 到本地代理端口 9999
  iptables -t mangle -N TPX 2>/dev/null
  iptables -t mangle -A TPX -p tcp -m mark --mark 0x1 -j TPROXY \
      --on-ip 0.0.0.0 --on-port 9999 --tproxy-mark 0x1 2>/dev/null
  iptables -t mangle -I PREROUTING 1 -j TPX 2>/dev/null
}

# easytier 共存：SO_MARK=$MARK 的包走 main 表，先于 pref 100 命中
coex_on() {
  ip rule add pref 80 fwmark $MARK lookup main 2>/dev/null
}

setup_topo() {
  ip netns add $RNET
  ip link add p-rem type veth peer name r-rem
  ip link set r-rem netns $RNET
  ip -4 addr add 10.90.0.1/24 dev p-rem; ip link set p-rem up
  ip netns exec $RNET ip link set lo up
  ip netns exec $RNET ip link set r-rem up
  ip netns exec $RNET ip -4 addr add 10.90.0.2/24 dev r-rem
  ip netns exec $RNET ip route add default via 10.90.0.1 dev r-rem
  sleep 0.5
}

run() {
  echo "########## $1 ##########"
  clean
  setup_topo
  ip netns exec $RNET $CORE --ipv4 10.126.128.2/24 --listeners tcp://0.0.0.0:30002 \
      --hostname B --network-name t --network-secret s \
      --rpc-portal 127.0.0.1:15902 --no-tun >/tmp/rb.log 2>&1 &
  sleep 2
  tproxy_on
  [ -n "$2" ] && coex_on
  $CORE --ipv4 10.126.128.1/24 --listeners tcp://0.0.0.0:30001 $2 \
      --peers tcp://10.90.0.2:30002 --hostname A --network-name t --network-secret s \
      --rpc-portal 127.0.0.1:15901 --no-tun >/tmp/ra.log 2>&1 &
  ok=no
  for i in 1 2 3 4 5 6; do
    sleep 2
    timeout 3 $CLI --rpc-portal 127.0.0.1:15901 peer list 2>/dev/null \
        | grep -q 10.126.128.2 && { ok=YES; break; }
    grep -q "failed to listen\|error=" /tmp/ra.log && break
  done
  echo "  A 存活: $(pgrep -f "$CORE --ipv4 10.126.128.1" >/dev/null && echo 是 || echo 否)"
  echo "  A-B 建连: $ok"
  echo "  原因: $(grep -oE 'failed to listen|new peer added|timeout|error=[^ ]*' /tmp/ra.log | tail -1)"
  clean
}

run "对照1: 模拟 clash 劫持，easytier 无 socket-mark（应失败/超时）" ""
run "实验2: 同一劫持 + socket-mark=20052 & pref80->main（应成功）" "--socket-mark $MARK"
echo DONE
