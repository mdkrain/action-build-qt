#!/usr/bin/env bash
# =============================================================================
# 在 macOS 或 Linux 上构建静态 Qt。
#
# 本脚本假设以下环境变量已被 workflow 通过 scripts/read-config.py 设置：
#   QT_VERSION                Qt 版本（例如 6.10.2）
#   QT_SOURCE_URL             Qt 源码下载地址
#   QT_SOURCE_SHA256           源码 SHA-256（可选，空则跳过校验）
#   SUBMODULES                要构建的子模块，逗号分隔
#   SKIP_MODULES              要跳过的子模块，逗号分隔
#   CONFIGURE_OPTIONS_COMMON  通用 configure 参数（空格分隔）
#   CONFIGURE_OPTIONS_LINUX   Linux 专属 configure 参数（仅 Linux 用）
#   CONFIGURE_OPTIONS_MACOS   macOS 专属 configure 参数（仅 macOS 用）
#   CMAKE_EXTRA_ARGS_COMMON   通用 CMake 参数
#   CMAKE_EXTRA_ARGS_LINUX    Linux 专属 CMake 参数
#   CMAKE_EXTRA_ARGS_MACOS    macOS 专属 CMake 参数
#   STRIP_DEBUG_SYMBOLS       是否 strip 调试符号（true/false）
#   PARALLEL_JOBS             并行任务数（0=自动）
#   PACKAGE_NAME_TEMPLATE     产物包命名模板
#
# 用法:
#   bash scripts/build-qt-unix.sh [--work-dir DIR] [--install-prefix DIR]
# =============================================================================

set -euo pipefail

# ── 辅助函数 ──────────────────────────────────────────────────────────────────
log_step() {
    echo ""
    echo "========================================"
    echo "  $1"
    echo "========================================"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# 检测平台
detect_platform() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       die "Unsupported OS: $(uname -s)" ;;
    esac
}

PLATFORM="$(detect_platform)"
echo "Detected platform: $PLATFORM"

# ── 参数解析 ──────────────────────────────────────────────────────────────────
WORK_DIR="${RUNNER_WORKSPACE:-$HOME/qt-build-work}"
INSTALL_PREFIX=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        --install-prefix)
            INSTALL_PREFIX="$2"
            shift 2
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

# ── 校验环境变量 ──────────────────────────────────────────────────────────────
: "${QT_VERSION:?Missing QT_VERSION (run scripts/read-config.py first)}"
: "${QT_SOURCE_URL:?Missing QT_SOURCE_URL}"
: "${SUBMODULES:?Missing SUBMODULES}"
: "${CONFIGURE_OPTIONS_COMMON:?Missing CONFIGURE_OPTIONS_COMMON}"

QT_VERSION="$QT_VERSION"
SOURCE_URL="$QT_SOURCE_URL"
SOURCE_SHA256="${QT_SOURCE_SHA256:-}"
SUBMODULES="$SUBMODULES"
SKIP_MODULES="${SKIP_MODULES:-}"
COMMON_OPTS="$CONFIGURE_OPTIONS_COMMON"
if [[ "$PLATFORM" == "linux" ]]; then
    PLATFORM_OPTS="${CONFIGURE_OPTIONS_LINUX:-}"
    CMAKE_PLATFORM="${CMAKE_EXTRA_ARGS_LINUX:-}"
else
    PLATFORM_OPTS="${CONFIGURE_OPTIONS_MACOS:-}"
    CMAKE_PLATFORM="${CMAKE_EXTRA_ARGS_MACOS:-}"
fi
CMAKE_COMMON="${CMAKE_EXTRA_ARGS_COMMON:-}"
STRIP_DEBUG="${STRIP_DEBUG_SYMBOLS:-false}"
PARALLEL_JOBS="${PARALLEL_JOBS:-0}"
PACKAGE_TEMPLATE="${PACKAGE_NAME_TEMPLATE:-qt-{version}-static-{platform}}"

if [[ "$PARALLEL_JOBS" -le 0 ]]; then
    if [[ "$PLATFORM" == "macos" ]]; then
        PARALLEL_JOBS="$(sysctl -n hw.ncpu)"
    else
        PARALLEL_JOBS="$(nproc)"
    fi
fi

if [[ -z "$INSTALL_PREFIX" ]]; then
    INSTALL_PREFIX="$WORK_DIR/qt-install"
fi

# 替换模板
PACKAGE_NAME="${PACKAGE_TEMPLATE/\{version\}/$QT_VERSION}"
PACKAGE_NAME="${PACKAGE_NAME/\{platform\}/$PLATFORM}"

# ── 目录规划 ──────────────────────────────────────────────────────────────────
SRC_DIR="$WORK_DIR/qt-src"
BUILD_DIR="$WORK_DIR/qt-build"
INSTALL_DIR="$INSTALL_PREFIX"
ARTIFACT_DIR="$WORK_DIR/artifacts"

mkdir -p "$WORK_DIR" "$SRC_DIR" "$BUILD_DIR" "$INSTALL_DIR" "$ARTIFACT_DIR"

log_step "Qt 静态构建参数（$PLATFORM）"
echo "Qt 版本          : $QT_VERSION"
echo "源码 URL         : $SOURCE_URL"
echo "子模块           : $SUBMODULES"
echo "跳过模块         : ${SKIP_MODULES:-（无）}"
echo "通用 configure   : $COMMON_OPTS"
echo "$PLATFORM configure: $PLATFORM_OPTS"
echo "通用 CMake       : ${CMAKE_COMMON:-（无）}"
echo "$PLATFORM CMake    : ${CMAKE_PLATFORM:-（无）}"
echo "并行任务数       : $PARALLEL_JOBS"
echo "Strip 调试符号   : $STRIP_DEBUG"
echo "工作目录         : $WORK_DIR"
echo "安装前缀         : $INSTALL_DIR"
echo "产物包名         : $PACKAGE_NAME"

# ── Step 1: 验证构建工具 ──────────────────────────────────────────────────────
log_step "Step 1: 验证构建工具"
for tool in cmake ninja python3 perl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        die "Required tool not in PATH: $tool"
    fi
    echo "$(printf '%-10s' "$tool"): $(command -v "$tool")"
done

# macOS 需要 Xcode 命令行工具（提供 clang）
if [[ "$PLATFORM" == "macos" ]]; then
    if ! xcode-select -p >/dev/null 2>&1; then
        die "Xcode command line tools not installed. Run: xcode-select --install"
    fi
    echo "Xcode path        : $(xcode-select -p)"
fi

# ── Step 2: 下载 Qt 源码 ──────────────────────────────────────────────────────
log_step "Step 2: 下载 Qt 源码"

if [[ -f "$SRC_DIR/configure" ]]; then
    echo "Qt 源码已存在，跳过下载: $SRC_DIR"
else
    ARCHIVE_PATH="$WORK_DIR/qt-src.tar.xz"
    if [[ -f "$ARCHIVE_PATH" ]]; then
        echo "归档已存在，跳过下载: $ARCHIVE_PATH"
    else
        echo "下载: $SOURCE_URL"
        # 使用 curl 支持断点续传
        curl -L --fail --retry 3 --retry-delay 5 -C - -o "$ARCHIVE_PATH" "$SOURCE_URL"
    fi

    # SHA-256 校验
    if [[ -n "$SOURCE_SHA256" ]]; then
        echo "校验 SHA-256 ..."
        ACTUAL_HASH="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
        if [[ "${ACTUAL_HASH,,}" != "${SOURCE_SHA256,,}" ]]; then
            die "SHA-256 mismatch: expected=$SOURCE_SHA256 actual=$ACTUAL_HASH"
        fi
        echo "SHA-256 校验通过"
    else
        echo "未提供 SHA-256，跳过校验"
    fi

    # 解压到 srcDir
    echo "解压到: $SRC_DIR"
    # Qt 源码归档内含一层目录（qt-everywhere-src-<version>），先解压到临时目录再移动
    EXTRACT_TMP="$WORK_DIR/qt-extract-tmp"
    rm -rf "$EXTRACT_TMP"
    mkdir -p "$EXTRACT_TMP"
    tar -xf "$ARCHIVE_PATH" -C "$EXTRACT_TMP"

    # 将内层目录移动到 $SRC_DIR
    INNER_DIR="$(find "$EXTRACT_TMP" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [[ -n "$INNER_DIR" ]]; then
        # 用 rsync 保留属性；若没有 rsync 用 mv
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "$INNER_DIR/" "$SRC_DIR/"
        else
            mv "$INNER_DIR"/* "$SRC_DIR/" 2>/dev/null || true
            mv "$INNER_DIR"/.* "$SRC_DIR/" 2>/dev/null || true
        fi
    fi
    rm -rf "$EXTRACT_TMP"
fi

# 验证源码
CONFIGURE_SCRIPT="$SRC_DIR/configure"
if [[ ! -f "$CONFIGURE_SCRIPT" ]]; then
    die "configure script not found in source dir: $SRC_DIR"
fi

# ── Step 3: 配置 Qt ──────────────────────────────────────────────────────────
log_step "Step 3: 配置 Qt"

# 清理 build 目录确保干净环境
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    echo "清理旧的 CMakeCache.txt ..."
    rm -f "$BUILD_DIR/CMakeCache.txt"
fi

cd "$BUILD_DIR"

# 构造 configure 参数数组
CONFIGURE_ARGS=()
CONFIGURE_ARGS+=("$SRC_DIR/configure")

# 通用选项
if [[ -n "$COMMON_OPTS" ]]; then
    # shellcheck disable=SC2206
    CONFIGURE_ARGS+=($COMMON_OPTS)
fi
# 平台专属选项
if [[ -n "$PLATFORM_OPTS" ]]; then
    # shellcheck disable=SC2206
    CONFIGURE_ARGS+=($PLATFORM_OPTS)
fi
# 子模块
if [[ -n "$SUBMODULES" ]]; then
    CONFIGURE_ARGS+=("-submodules" "$SUBMODULES")
fi
# 跳过模块
if [[ -n "$SKIP_MODULES" ]]; then
    CONFIGURE_ARGS+=("-skip" "$SKIP_MODULES")
fi
# 安装前缀
CONFIGURE_ARGS+=("-prefix" "$INSTALL_DIR")

# 透传 CMake 参数（通过 -- 分隔）
CMAKE_ARGS_STR="$CMAKE_COMMON $CMAKE_PLATFORM"
CMAKE_ARGS_STR="${CMAKE_ARGS_STR#"${CMAKE_ARGS_STR%%[![:space:]]*}"}"  # 去除前导空格
if [[ -n "$CMAKE_ARGS_STR" ]]; then
    CONFIGURE_ARGS+=("--")
    # shellcheck disable=SC2206
    CONFIGURE_ARGS+=($CMAKE_ARGS_STR)
fi

echo "调用 configure ..."
echo "参数: ${CONFIGURE_ARGS[*]}"
"${CONFIGURE_ARGS[@]}"

# ── Step 4: 构建 Qt ──────────────────────────────────────────────────────────
log_step "Step 4: 构建 Qt（并行任务数: $PARALLEL_JOBS）"
cmake --build . --parallel "$PARALLEL_JOBS"

# ── Step 5: 安装 Qt ──────────────────────────────────────────────────────────
log_step "Step 5: 安装 Qt 到 $INSTALL_DIR"
cmake --install .

# ── Step 6: strip 调试符号（可选）──────────────────────────────────────────────
if [[ "$STRIP_DEBUG" == "true" ]]; then
    log_step "Step 6: strip 静态库调试符号"
    echo "在 $INSTALL_DIR 中查找 .a 文件 ..."
    FOUND_COUNT=0
    while IFS= read -r -d '' lib_file; do
        # 仅 strip 静态库的调试符号，保留符号表
        strip --strip-debug "$lib_file" 2>/dev/null || true
        FOUND_COUNT=$((FOUND_COUNT + 1))
    done < <(find "$INSTALL_DIR" -type f -name '*.a' -print0)
    echo "已 strip $FOUND_COUNT 个静态库文件"
else
    log_step "Step 6: 跳过 strip 调试符号"
fi

# ── Step 7: 写入环境信息（供下游项目使用）──────────────────────────────────────
log_step "Step 7: 写入 Qt 环境信息"
QT_CONF_PATH="$INSTALL_DIR/qt-static-build-info.json"
HOST_ARCH="$(uname -m)"
COMPILER_NAME="gcc"
[[ "$PLATFORM" == "macos" ]] && COMPILER_NAME="clang"

cat > "$QT_CONF_PATH" <<EOF
{
  "version": "$QT_VERSION",
  "prefix": "$INSTALL_DIR",
  "host": "$PLATFORM-$HOST_ARCH",
  "static": true,
  "modules": [$(echo "$SUBMODULES" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | paste -sd,)],
  "skip": [$(echo "$SKIP_MODULES" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | paste -sd,)],
  "compiler": "$COMPILER_NAME"
}
EOF
echo "已写入构建信息: $QT_CONF_PATH"

# ── Step 8: 打包产物 ─────────────────────────────────────────────────────────
log_step "Step 8: 打包产物"
ARCHIVE_PATH="$ARTIFACT_DIR/$PACKAGE_NAME.tar.xz"
rm -f "$ARCHIVE_PATH"

echo "压缩 $INSTALL_DIR → $ARCHIVE_PATH"
# 使用 xz 压缩（Linux/macOS 通用，压缩率高于 gz）
# -C $INSTALL_DIR：进入安装目录后再打包，避免归档内嵌套 qt-install/ 路径
# 使用 transform 去掉路径前缀
tar -cJf "$ARCHIVE_PATH" -C "$(dirname "$INSTALL_DIR")" "$(basename "$INSTALL_DIR")"

echo ""
echo "========================================"
echo "  构建成功"
echo "========================================"
echo "产物路径: $ARCHIVE_PATH"
echo "安装前缀: $INSTALL_DIR"

# 输出产物路径到 GITHUB_OUTPUT（供 workflow 后续步骤使用）
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "artifact_path=$ARCHIVE_PATH" >> "$GITHUB_OUTPUT"
    echo "install_prefix=$INSTALL_DIR" >> "$GITHUB_OUTPUT"
    echo "package_name=$PACKAGE_NAME" >> "$GITHUB_OUTPUT"
fi
