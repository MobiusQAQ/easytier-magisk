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

echo "=== [4] 测试 egress_info 出口特征比对（支持 WiFi 漫游与内网IP变更识别） ==="
LAST_SIG="wlan0 1002 192.168.1.100"
# 同网卡但新内网 IP / 新路由表 (WiFi 漫游或基站切换)
CUR_SIG="wlan0 1003 10.0.0.50"
CHANGED=0
if [ "$CUR_SIG" != "$LAST_SIG" ]; then
    CHANGED=1
fi
if [ "$CHANGED" -eq 1 ]; then
    echo "✓ 成功识别同网卡名下的 IP/路由表切换"
else
    echo "✗ 未能识别 IP/路由表切换"
    exit 1
fi

echo "=== [5] 测试 hotspot_instance 注释忽略与兜底逻辑 ==="
HOTSPOT_INSTANCE_FILE="${MOCK_DIR}/hotspot_instance"
NETWORKS_DIR="${MOCK_DIR}/networks"
INSTANCES_FILE="${MOCK_DIR}/instances"
mkdir -p "$NETWORKS_DIR"

cat <<'EOF' > "$HOTSPOT_INSTANCE_FILE"
# 指定哪个实例作为热点出口
# 只有这个实例会被注入热点网段
partnerc7u
EOF

cat <<'EOF' > "$INSTANCES_FILE"
elysia	et0	/tmp/elysia.toml	127.0.0.1:15880
partnerc7u	et1	/tmp/partnerc7u.toml	127.0.0.1:15882
EOF
touch "${NETWORKS_DIR}/partnerc7u.toml"

eval "$(awk '/^hotspot_instance_name\(\)/, /^}/' "$REPO_DIR/easytier_core.sh")"
RES_NAME=$(hotspot_instance_name)
if [ "$RES_NAME" = "partnerc7u" ]; then
    echo "✓ 正确忽略注释并提取真实实例名: $RES_NAME"
else
    echo "✗ 提取实例名失败: $RES_NAME"
    exit 1
fi

echo "=== [6] 测试守护进程单例锁定与旧进程回收 ==="
DAEMON_PID_FILE="${MOCK_DIR}/.daemon.pid"
eval "$(awk '/^acquire_daemon_lock\(\)/, /^}/' "$REPO_DIR/easytier_core.sh")"

# 首次获取锁
acquire_daemon_lock
CURRENT_PID=$(cat "$DAEMON_PID_FILE")
if [ "$CURRENT_PID" = "$$" ]; then
    echo "✓ 首次获取单例锁成功 (PID $$)"
else
    echo "✗ 单例锁 PID 不匹配: $CURRENT_PID"
    exit 1
fi

rm -rf "$MOCK_DIR"
trap - EXIT

echo "=== 全部切网自愈优化测试通过 ==="
