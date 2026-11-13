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

ZIP_NAME="Easytier-Magisk-${VERSION}.zip"
OUTPUT_DIR="${SCRIPT_DIR}/dist"
mkdir -p "$OUTPUT_DIR"
OUTPUT_PATH="${OUTPUT_DIR}/${ZIP_NAME}"

rm -f "$OUTPUT_PATH"

echo "Building Magisk module: ${ZIP_NAME}..."

# Zip module files excluding git, tests, dist and local artifacts
zip -r9 "$OUTPUT_PATH" . \
    -x ".git/*" \
    -x ".gitignore" \
    -x "tests/*" \
    -x "dist/*" \
    -x "build.sh" \
    -x "*.zip" \
    -x "*.bak" \
    -x "*.log" \
    -x ".DS_Store"

echo "Successfully built: ${OUTPUT_PATH}"
ls -lh "$OUTPUT_PATH"
