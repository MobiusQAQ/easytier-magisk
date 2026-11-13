#!/bin/bash
set -euo pipefail

# EasyTier Magisk module package script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f "module.prop" ]; then
    echo "Error: module.prop not found in $SCRIPT_DIR" >&2
    exit 1
fi

VERSION=$(grep '^version=' module.prop | cut -d= -f2 | tr -d '\r')
if [ -z "$VERSION" ]; then
    VERSION="latest"
fi

OUTPUT_DIR="${SCRIPT_DIR}/dist"
mkdir -p "$OUTPUT_DIR"

build_release() {
    local target_ver="$1"
    local is_debug="${2:-0}"
    local zip_name="Easytier-Magisk-${target_ver}.zip"
    local output_path="${OUTPUT_DIR}/${zip_name}"

    echo "==> Building ${zip_name} (is_debug=${is_debug})..."
    rm -f "$output_path"

    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/easytier_build_XXXXXX")
    trap 'rm -rf "$tmp_dir"' EXIT

    # 复制所有仓库文件到构建目录
    cp -a . "$tmp_dir/"

    if [ "$is_debug" = "1" ]; then
        # 针对 Debug 版配置：更新 module.prop 并生成 enable_debug 开关
        sed -i "s#^version=.*#version=${target_ver}#" "$tmp_dir/module.prop"
        sed -i 's#^name=.*#name=EasyTier_Magisk (Debug)#' "$tmp_dir/module.prop"
        touch "$tmp_dir/enable_debug"
        if [ -f "$tmp_dir/config/debug.conf" ]; then
            sed -i 's/^DEBUG=.*/DEBUG=1/' "$tmp_dir/config/debug.conf"
        fi
    else
        # Release 版确保不带调试开关
        rm -f "$tmp_dir/enable_debug"
        if [ -f "$tmp_dir/config/debug.conf" ]; then
            sed -i 's/^DEBUG=.*/DEBUG=0/' "$tmp_dir/config/debug.conf"
        fi
    fi

    # 打包
    (
        cd "$tmp_dir"
        zip -r9 "$output_path" . \
            -x ".git/*" \
            -x ".gitignore" \
            -x "tests/*" \
            -x "dist/*" \
            -x "build.sh" \
            -x "*.zip" \
            -x "*.bak" \
            -x "*.log" \
            -x ".DS_Store" >/dev/null
    )

    echo "Successfully built: ${output_path}"
    ls -lh "$output_path"
    rm -rf "$tmp_dir"
    trap - EXIT
}

MODE="${1:-all}"
case "$MODE" in
    debug|--debug|-d)
        build_release "${VERSION}-debug" 1
        ;;
    release|--release|-r)
        build_release "${VERSION}" 0
        ;;
    all|--all)
        build_release "${VERSION}" 0
        build_release "${VERSION}-debug" 1
        ;;
    *)
        echo "Usage: $0 [release|debug|all]"
        exit 1
        ;;
esac
