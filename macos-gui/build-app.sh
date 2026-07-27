#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build/macos-gui}"
APP_DIR="${BUILD_DIR}/Pikafish.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENGINE_NAME="pikafish-fastwin"
ARCH="${ARCH:-apple-silicon}"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The native GUI can only be built on macOS." >&2
    exit 1
fi

if [[ ! -f "${REPO_ROOT}/src/pikafish.nnue" ]]; then
    make -C "${REPO_ROOT}/src" net
fi

make -C "${REPO_ROOT}/src" -j"${JOBS}" build \
    ARCH="${ARCH}" \
    COMP=clang \
    EXE="${ENGINE_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

xcrun swiftc \
    -O \
    -framework AppKit \
    "${SCRIPT_DIR}/Sources/PikafishGUI/main.swift" \
    -o "${MACOS_DIR}/PikafishGUI"

cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${REPO_ROOT}/src/${ENGINE_NAME}" "${RESOURCES_DIR}/${ENGINE_NAME}"
cp "${REPO_ROOT}/src/pikafish.nnue" "${RESOURCES_DIR}/pikafish.nnue"
cp "${SCRIPT_DIR}"/Resources/* "${RESOURCES_DIR}/"

chmod +x "${MACOS_DIR}/PikafishGUI" "${RESOURCES_DIR}/${ENGINE_NAME}"
codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "Built ${APP_DIR}"
