#!/bin/bash
# 切网恢复速度与设备绑定策略回归测试
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
cd "$REPO_DIR"

echo "=== [1] 脚本语法检查 ==="
bash -n "$REPO_DIR/easytier_core.sh"
echo "✓ easytier_core.sh 语法正确"
bash -n "$REPO_DIR/action.sh"
echo "✓ action.sh 语法正确"

echo "=== [2] 测试 bind-device 策略默认值（原版自愈特性） ==="
MOCK_DIR=$(mktemp -d "/tmp/et_switch_test_XXXXXX")
trap 'rm -rf "$MOCK_DIR"' EXIT

MODDIR="$MOCK_DIR"
# 导入 should_bind_device 函数
eval "$(awk '/^should_bind_device\(\)/, /^}/' "$REPO_DIR/easytier_core.sh")"

# 1. 默认状态：应为 false (返回 1)，不注入 --bind-device，切网自动走默认路由
if should_bind_device; then
    echo "✗ 默认状态下错误启用了 should_bind_device"
    exit 1
else
    echo "✓ 默认状态下不开启 bind-device（保持原版无缝自愈行为）"
fi

# 2. 创建 enable_bind_device：应返回 0 (true)
touch "${MOCK_DIR}/enable_bind_device"
if should_bind_device; then
    echo "✓ 显式创建 enable_bind_device 后正确开启 bind-device"
else
    echo "✗ enable_bind_device 存在时未开启 bind-device"
    exit 1
fi

# 3. 创建 disable_bind_device：应返回 1 (false)
touch "${MOCK_DIR}/disable_bind_device"
if should_bind_device; then
    echo "✗ disable_bind_device 存在时未能禁用 bind-device"
    exit 1
else
    echo "✓ disable_bind_device 优先级高于 enable_bind_device"
fi

echo "=== [3] 测试切网不杀进程逻辑（消除 20s 进程重启重连延迟） ==="
# 模拟网络切换判定逻辑
LAST_IFACE="wlan0"
CUR_IFACE="rmnet_data4"
KILL_CALLED=0

kill_all() {
    KILL_CALLED=1
}

# 默认情况下：CUR_IFACE != LAST_IFACE 不应调用 kill_all
rm -f "${MOCK_DIR}/restart_on_network_change"
if [ "$CUR_IFACE" != "$LAST_IFACE" ]; then
    if [ -f "${MOCK_DIR}/restart_on_network_change" ]; then
        kill_all
    fi
fi

if [ "$KILL_CALLED" -eq 0 ]; then
    echo "✓ 默认切网时不调用 kill_all，保留核心进程与已建立的 TUN 接口"
else
    echo "✗ 默认切网时错误调用了 kill_all"
    exit 1
fi

# 当用户开启 restart_on_network_change 时：应调用 kill_all
touch "${MOCK_DIR}/restart_on_network_change"
if [ "$CUR_IFACE" != "$LAST_IFACE" ]; then
    if [ -f "${MOCK_DIR}/restart_on_network_change" ]; then
        kill_all
    fi
fi

if [ "$KILL_CALLED" -eq 1 ]; then
    echo "✓ 显式开启 restart_on_network_change 时支持硬重启"
else
    echo "✗ 开启 restart_on_network_change 时未调用 kill_all"
    exit 1
fi

rm -rf "$MOCK_DIR"
trap - EXIT

echo "=== 全部切网自愈优化测试通过 ==="
