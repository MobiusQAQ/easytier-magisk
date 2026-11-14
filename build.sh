#!/bin/bash
set -euo pipefail

# EasyTier Magisk module package & release script
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

generate_checksums() {
    echo "==> Generating SHA256 checksums..."
    (
        cd "$OUTPUT_DIR"
        rm -f SHA256SUMS.txt
        if ls *.zip >/dev/null 2>&1; then
            sha256sum *.zip > SHA256SUMS.txt
            echo "Generated ${OUTPUT_DIR}/SHA256SUMS.txt:"
            cat SHA256SUMS.txt
        fi
    )
}

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

    # 打包（排除源码控制、测试文件与 CI/CD 配置）
    (
        cd "$tmp_dir"
        zip -r9 "$output_path" . \
            -x ".git/*" \
            -x ".github/*" \
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

publish_release() {
    local target_ver="$1"
    echo "==> Preparing to publish release ${target_ver}..."

    if ! command -v gh >/dev/null 2>&1; then
        echo "Error: GitHub CLI (gh) is not installed." >&2
        exit 1
    fi

    # 运行回归测试
    for t in "${SCRIPT_DIR}/tests"/regression_*.sh "${SCRIPT_DIR}/tests"/peer_cli_test.sh; do
        if [ -f "$t" ]; then
            echo "==> Running test: $(basename "$t")..."
            bash "$t"
        fi
    done

    # 构建所有包并生成校验码
    build_release "${target_ver}" 0
    build_release "${target_ver}-debug" 1
    generate_checksums

    local rel_zip="${OUTPUT_DIR}/Easytier-Magisk-${target_ver}.zip"
    local dbg_zip="${OUTPUT_DIR}/Easytier-Magisk-${target_ver}-debug.zip"
    local sum_file="${OUTPUT_DIR}/SHA256SUMS.txt"

    # 检查 Git 标签
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if ! git rev-parse -q --verify "refs/tags/${target_ver}" >/dev/null 2>&1; then
            echo "==> Git tag '${target_ver}' not found. Creating local tag..."
            git tag -a "${target_ver}" -m "Release ${target_ver}"
        fi

        if git remote get-url origin >/dev/null 2>&1; then
            echo "==> Pushing tag '${target_ver}' to remote origin..."
            git push origin "${target_ver}" || echo "Notice: Push tag failed or already on remote."
        fi
    fi

    # 发布至 GitHub Releases
    echo "==> Uploading release assets to GitHub Releases..."
    if gh release view "${target_ver}" >/dev/null 2>&1; then
        echo "==> Release '${target_ver}' exists. Uploading/updating assets..."
        gh release upload "${target_ver}" "$rel_zip" "$dbg_zip" "$sum_file" --clobber
    else
        echo "==> Creating new GitHub Release for '${target_ver}'..."
        gh release create "${target_ver}" "$rel_zip" "$dbg_zip" "$sum_file" \
            --title "EasyTier Magisk ${target_ver}" \
            --generate-notes
    fi

    echo "==> Successfully published release ${target_ver}!"
    gh release view "${target_ver}"
}

MODE="${1:-all}"
case "$MODE" in
    debug|--debug|-d)
        build_release "${VERSION}-debug" 1
        generate_checksums
        ;;
    release|--release|-r)
        build_release "${VERSION}" 0
        generate_checksums
        ;;
    all|--all)
        build_release "${VERSION}" 0
        build_release "${VERSION}-debug" 1
        generate_checksums
        ;;
    publish|--publish|-p)
        publish_release "${VERSION}"
        ;;
    *)
        echo "Usage: $0 [release|debug|all|publish]"
        echo "  release : Build standard release zip"
        echo "  debug   : Build debug variant zip"
        echo "  all     : Build both release and debug zips (default)"
        echo "  publish : Build all, generate SHA256 checksums, tag, and publish to GitHub Releases via gh CLI"
        exit 1
        ;;
esac
