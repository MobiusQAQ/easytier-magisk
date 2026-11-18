#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; D="${D:-$SCRIPT_DIR/..}"; CORE="${CORE:-$D/easytier-core}"
mkdir -p /run/netns; mount -t tmpfs tmpfs /run/netns 2>/dev/null

ip netns add mesh 2>/dev/null; ip netns add client 2>/dev/null

# BASE(手机) ph-pub <-> mesh(内网对端B) m-pub  —— 模拟手机蜂窝公网侧
ip link add ph-pub type veth peer name m-pub
ip link set m-pub netns mesh
ip -4 addr add 10.99.0.1/24 dev ph-pub; ip link set ph-pub up
ip netns exec mesh ip link set lo up
ip netns exec mesh ip -4 addr add 10.99.0.2/24 dev m-pub
ip netns exec mesh ip link set m-pub up

# BASE(手机) ph-ap <-> client(热点设备) c-ap —— 模拟热点局域网 192.168.43.0/24
ip link add ph-ap type veth peer name c-ap
ip link set c-ap netns client
ip -4 addr add 192.168.43.1/24 dev ph-ap; ip link set ph-ap up
ip netns exec client ip link set lo up
ip netns exec client ip -4 addr add 192.168.43.100/24 dev c-ap
ip netns exec client ip link set c-ap up
ip netns exec client ip route add default via 192.168.43.1

ip link set lo up
echo 1 > /proc/sys/net/ipv4/ip_forward
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 2 > "$f" 2>/dev/null; done

# B = 内网对端(10.126.126.2), A = 手机网关(10.126.126.1) 连到 B
ip netns exec mesh $CORE --ipv4 10.126.126.2/24 --listeners tcp://0.0.0.0:11010 \
    --hostname B --network-name t --network-secret s --rpc-portal 127.0.0.1:15889 \
    >/tmp/B.log 2>&1 &
BP=$!
$CORE --ipv4 10.126.126.1/24 --listeners tcp://0.0.0.0:11011 \
    --peers tcp://10.99.0.2:11010 --hostname A --network-name t --network-secret s \
    --rpc-portal 127.0.0.1:15888 --proxy-networks 192.168.43.0/24 \
    >/tmp/A.log 2>&1 &
AP=$!
sleep 10

echo "===== [1] 手机A 的 main 路由表 ====="; ip route | grep -E "tun|10.126|10.99|local"
echo "===== [2] mesh里B 的 tun 地址 ====="; ip netns exec mesh ip -br addr | grep tun
echo "===== [3] A/B 是否建立 mesh peer ====="
$CORE -h >/dev/null 2>&1; CLI="${CLI:-$D/easytier-cli}"
timeout 6 $CLI --rpc-portal 127.0.0.1:15888 peer list 2>&1 | head -8
echo "--- A.log 尾 ---"; tail -3 /tmp/A.log

# 手机对出隧道流量做 SNAT + 放行转发（这步是官方脚本没自动加的）
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o tun0 -j MASQUERADE 2>/dev/null
iptables -A FORWARD -i ph-ap -o tun0 -j ACCEPT 2>/dev/null
iptables -A FORWARD -i tun0 -o ph-ap -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

echo "===== [4] 关键实验: 热点client -> 内网B(10.126.126.2) ping ====="
ip netns exec client ping -c 4 -W 2 10.126.126.2 2>&1 | tail -6

echo "===== [5] 对照: rp_filter 严格(=1) 后 ping ====="
for f in /proc/sys/net/ipv4/conf/all/rp_filter /proc/sys/net/ipv4/conf/tun0/rp_filter; do echo 1 > "$f" 2>/dev/null; done
ip netns exec client ping -c 3 -W 2 10.126.126.2 2>&1 | tail -4
for f in /proc/sys/net/ipv4/conf/all/rp_filter /proc/sys/net/ipv4/conf/tun0/rp_filter; do echo 2 > "$f" 2>/dev/null; done

echo "===== [6] 去掉 MASQUERADE(源IP=192.168.43.100 裸奔) 会怎样 ====="
iptables -t nat -D POSTROUTING -s 192.168.43.0/24 -o tun0 -j MASQUERADE 2>/dev/null
iptables -D FORWARD -i ph-ap -o tun0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -i tun0 -o ph-ap -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
ip netns exec client ping -c 3 -W 2 10.126.126.2 2>&1 | tail -4

echo "===== [7] 回环: client ping 手机自己 192.168.43.1 ====="
ip netns exec client ping -c 2 -W 2 192.168.43.1 2>&1 | tail -2
echo "===== [8] B.log 尾 ====="; tail -3 /tmp/B.log

kill $AP $BP 2>/dev/null; sleep 1
for n in mesh client; do ip netns del $n 2>/dev/null; done
echo "DONE"
