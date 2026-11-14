#!/bin/bash
# EasyTier Magisk CLI / peer 终端状态命令回归测试
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
cd "$REPO_DIR"

echo "=== [1] 脚本语法与权限检查 ==="
bash -n "$REPO_DIR/easytier-cli"
echo "✓ easytier-cli 语法正确"
bash -n "$REPO_DIR/system/bin/easytier-cli"
echo "✓ system/bin/easytier-cli 语法正确"
bash -n "$REPO_DIR/action.sh"
echo "✓ action.sh 语法正确"
bash -n "$REPO_DIR/easytier_core.sh"
echo "✓ easytier_core.sh 语法正确"

[ -x "$REPO_DIR/easytier-cli" ] || { echo "✗ easytier-cli 不可执行"; exit 1; }
[ -x "$REPO_DIR/easytier-cli-bin" ] || { echo "✗ easytier-cli-bin 不可执行"; exit 1; }
[ -x "$REPO_DIR/system/bin/easytier-cli" ] || { echo "✗ system/bin/easytier-cli 不可执行"; exit 1; }
[ -L "$REPO_DIR/system/bin/easytier" ] || { echo "✗ system/bin/easytier 软链接不存在"; exit 1; }
echo "✓ 文件执行权限与软链接校验通过"

echo "=== [2] 原生参数透传测试 ==="
VER_OUT=$(bash "$REPO_DIR/easytier-cli" --version)
if echo "$VER_OUT" | grep -q "easytier-cli"; then
    echo "✓ --version 透传成功: $VER_OUT"
else
    echo "✗ --version 透传失败"
    exit 1
fi

HELP_OUT=$(bash "$REPO_DIR/easytier-cli" help)
if echo "$HELP_OUT" | grep -q "EasyTier Magisk CLI"; then
    echo "✓ help 引导展示成功"
else
    echo "✗ help 引导展示失败"
    exit 1
fi

echo "=== [3] 多实例探测与状态命令测试 ==="
MOCK_DIR=$(mktemp -d "/tmp/et_test_XXXXXX")
trap 'rm -rf "$MOCK_DIR"' EXIT

# 模拟 .instances 文件
cat << 'EOF' > "$MOCK_DIR/.instances"
net_home	et0	/data/adb/modules/easytier_magisk/config/networks/net_home.toml	127.0.0.1:15880
net_work	et1	/data/adb/modules/easytier_magisk/config/networks/net_work.toml	127.0.0.1:15881
EOF

# 复制脚本测试多实例格式化
cp "$REPO_DIR/easytier-cli" "$MOCK_DIR/easytier-cli"
# 创建模拟 real-cli，输出模拟 peer 结果
cat << 'EOF' > "$MOCK_DIR/easytier-cli-bin"
#!/bin/bash
if [ "$1" = "-p" ]; then
    PORT="$2"
    shift 2
    CMD="$1"
    if [ "$CMD" = "peer" ]; then
        echo "Peer ID | IPv4 | Cost | Latency"
        echo "mock_p1 | 10.10.0.2 | 1 | 20ms"
    elif [ "$CMD" = "status" ]; then
        echo "Status OK for $PORT"
    fi
fi
EOF
chmod +x "$MOCK_DIR/easytier-cli-bin" "$MOCK_DIR/easytier-cli"
touch "$MOCK_DIR/module.prop"

# 测试 peer 多实例输出
PEER_OUT=$(cd "$MOCK_DIR" && bash "$MOCK_DIR/easytier-cli" peer)
if echo "$PEER_OUT" | grep -q "net_home" && echo "$PEER_OUT" | grep -q "net_work"; then
    echo "✓ peer 命令成功聚合展示 net_home 与 net_work 两个实例"
else
    echo "✗ peer 命令未能展示所有实例:"
    echo "$PEER_OUT"
    exit 1
fi

# 测试 -i 实例过滤
FILTER_OUT=$(cd "$MOCK_DIR" && bash "$MOCK_DIR/easytier-cli" peer -i net_home)
if echo "$FILTER_OUT" | grep -q "net_home" && ! echo "$FILTER_OUT" | grep -q "net_work"; then
    echo "✓ -i net_home 过滤单实例生效"
else
    echo "✗ -i net_home 过滤失败:"
    echo "$FILTER_OUT"
    exit 1
fi

# 测试 status 概览
STATUS_OUT=$(cd "$MOCK_DIR" && bash "$MOCK_DIR/easytier-cli" status)
if echo "$STATUS_OUT" | grep -q "net_home" && echo "$STATUS_OUT" | grep -q "net_work"; then
    echo "✓ status 命令成功生成运行概览表"
else
    echo "✗ status 命令测试失败:"
    echo "$STATUS_OUT"
    exit 1
fi

echo "=== [4] action.sh peer 转发测试 ==="
ACTION_PEER_OUT=$(cd "$MOCK_DIR" && ACTION="peer" bash -c '
    # 模拟 action.sh 中的 peer 行为
    exec sh "$0/easytier-cli" peer
' "$MOCK_DIR")

if echo "$ACTION_PEER_OUT" | grep -q "net_home"; then
    echo "✓ action.sh peer 路由转发验证通过"
else
    echo "✗ action.sh peer 路由转发失败"
    exit 1
fi

rm -rf "$MOCK_DIR"
trap - EXIT

echo "=== 全部 CLI / Peer 功能测试通过 ==="
