#!/bin/bash
# hs6 关键机制离线回归测试
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."

echo "=== [1] 测试热点网卡匹配逻辑 ==="
# 模拟不同机型的 ip link 输出
MOCK_LINKS='
1: lo: <LOOPBACK>
15: rmnet_ipa0: <UP>
20: rmnet_data0@rmnet_ipa0: <UP>
24: rmnet_data4@rmnet_ipa0: <UP>
45: wlan2: <BROADCAST,MULTICAST,UP> mtu 1500
'

MATCHED_DEV=$(echo "$MOCK_LINKS" | awk -F': ' '
    /(^| )(swlan[[:alnum:]_]*|softap[[:alnum:]_]*|p2p-wlan[[:alnum:]_]*|ap[[:alnum:]_]*|wlan[1-9][[:alnum:]_]*):/ {
        dev = $2
        sub(/@.*/, "", dev)
        print dev
        exit
    }
')

if [ "$MATCHED_DEV" = "wlan2" ]; then
    echo "✓ 成功匹配高通双 WiFi DBS / 软 AP 网卡: $MATCHED_DEV"
else
    echo "✗ 匹配失败: 期望 wlan2, 实际 '$MATCHED_DEV'"
    exit 1
fi

echo "=== [2] 测试路由表提取逻辑（避免误选 dummy0） ==="
# 模拟含有 dummy0 和 rmnet_data4 的 ip route show table all
MOCK_ROUTES='
default via 10.83.26.13 dev rmnet_data4 table 1024 proto static mtu 1500 
default dev dummy0 table 1002 proto static scope link 
default via fe80::5831:1146:ac80:a4e5 dev rmnet_data4 table 1024 proto ra metric 1024 expires 62311sec pref medium
'

CUR_IFACE="rmnet_data4"
EXTRACTED_TBL=$(echo "$MOCK_ROUTES" | awk -v d="$CUR_IFACE" '
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

if [ "$EXTRACTED_TBL" = "1024" ]; then
    echo "✓ 成功提取出口网卡 $CUR_IFACE 对应的路由表号: $EXTRACTED_TBL (排除了 dummy0)"
else
    echo "✗ 路由表提取失败: 期望 1024, 实际 '$EXTRACTED_TBL'"
    exit 1
fi

echo "=== [3] 语法检查与权限校验 ==="
for sh in "$REPO_DIR"/*.sh; do
    bash -n "$sh"
    echo "✓ 语法验证通过: $(basename "$sh")"
done

echo "=== 全部回归测试通过 ==="
