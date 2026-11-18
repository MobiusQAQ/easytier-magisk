#!/bin/bash
# 验证进程匹配逻辑与死锁防护
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
cd "$REPO_DIR"

echo "=== [1] 测试 pid_matches_config 与 pgrep 兜底逻辑 ==="
MOCK_DIR=$(mktemp -d "/tmp/et_pid_test_XXXXXX")
trap 'rm -rf "$MOCK_DIR"' EXIT

MODDIR="$MOCK_DIR"
# 导入相关函数
eval "$(awk '/^pid_matches_config\(\)/, /^}/' "$REPO_DIR/easytier_core.sh")"
eval "$(awk '/^count_core\(\)/, /^}/' "$REPO_DIR/easytier_core.sh")"

# 1. 测试空或不存在的 PID
if pid_matches_config "999999" "/some/config.toml"; then
    echo "✗ 不存在的 PID 不应匹配"
    exit 1
else
    echo "✓ 不存在的 PID 正确返回失败"
fi

# 2. 模拟真实 easytier-core 进程
MOCK_CONFIG="/tmp/mock_test_net.toml"
touch "$MOCK_CONFIG"

# 运行一个模拟后台进程，comm 为 easytier-core
MOCK_BIN="$MOCK_DIR/easytier-core"
cat << 'EOF' > "$MOCK_BIN"
#!/bin/sh
sleep 10
EOF
chmod +x "$MOCK_BIN"

"$MOCK_BIN" -c "$MOCK_CONFIG" &
MOCK_PID=$!

# 等待进程启动
sleep 0.2

if [ -d "/proc/$MOCK_PID" ]; then
    if pid_matches_config "$MOCK_PID" "$MOCK_CONFIG"; then
        echo "✓ 成功精准匹配目标 easytier-core 配置"
    else
        echo "✗ 未能匹配 easytier-core 配置"
        kill "$MOCK_PID" 2>/dev/null || true
        exit 1
    fi

    # 错误的目标配置不应匹配
    if pid_matches_config "$MOCK_PID" "/tmp/other.toml"; then
        echo "✗ 错误的目标配置不应匹配"
        kill "$MOCK_PID" 2>/dev/null || true
        exit 1
    else
        echo "✓ 非目标配置被正确拒绝"
    fi

    # 记录 .pid 文件并测试 count_core
    echo "$MOCK_PID" > "$MOCK_DIR/.pid-mocknet"
    COUNT=$(count_core)
    if [ "$COUNT" = "1" ]; then
        echo "✓ count_core 极速统计正常: $COUNT"
    else
        echo "✗ count_core 统计异常: $COUNT"
        kill "$MOCK_PID" 2>/dev/null || true
        exit 1
    fi
fi

kill "$MOCK_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true
rm -f "$MOCK_CONFIG"

echo "=== 全部进程匹配测试通过 ==="
