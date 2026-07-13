#!/usr/bin/env bash
# =============================================================================
# Build static Qt on macOS or Linux (vcpkg-style: per-module CMake builds).
#
# Each submodule is downloaded, configured, built, and installed independently
# via CMake (not via the top-level configure wrapper).
#
# Required environment variables (set by scripts/read-config.py):
#   QT_VERSION                  Qt version (e.g. 6.10.2)
#   SUBMODULE_URL_TEMPLATE      URL template with {submodule} placeholder
#   SUBMODULES                  Comma-separated list (in dependency order)
#   CMAKE_OPTIONS_COMMON        CMake options for ALL modules
#   CMAKE_OPTIONS_QTBASE        Extra CMake options for qtbase only
#   CMAKE_OPTIONS_QTBASE_LINUX  Linux-specific qtbase options
#   CMAKE_OPTIONS_QTBASE_MACOS  macOS-specific qtbase options
#   STRIP_DEBUG_SYMBOLS         Strip debug symbols (true/false)
#   PARALLEL_JOBS               Parallel job count (0 = auto)
#   PACKAGE_NAME_TEMPLATE       Artifact package name template
#
# Usage:
#   bash scripts/build-qt-unix.sh [--work-dir DIR] [--install-prefix DIR]
# =============================================================================

set -euo pipefail

# === Helper functions ========================================================
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

detect_platform() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       die "Unsupported OS: $(uname -s)" ;;
    esac
}

PLATFORM="$(detect_platform)"
echo "Detected platform: $PLATFORM"

# === Argument parsing =========================================================
WORK_DIR="${RUNNER_WORKSPACE:-$HOME/qt-build-work}"
INSTALL_PREFIX=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir)       WORK_DIR="$2";       shift 2 ;;
        --install-prefix) INSTALL_PREFIX="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# === Validate environment variables ===========================================
: "${QT_VERSION:?Missing QT_VERSION (run scripts/read-config.py first)}"
: "${SUBMODULE_URL_TEMPLATE:?Missing SUBMODULE_URL_TEMPLATE}"
: "${SUBMODULES:?Missing SUBMODULES}"
: "${CMAKE_OPTIONS_COMMON:?Missing CMAKE_OPTIONS_COMMON}"

IFS=',' read -ra MODULE_LIST <<< "$SUBMODULES"

# Platform-specific qtbase options
case "$PLATFORM" in
    linux)  QTBASE_PLATFORM_OPTS="${CMAKE_OPTIONS_QTBASE_LINUX:-}" ;;
    macos)  QTBASE_PLATFORM_OPTS="${CMAKE_OPTIONS_QTBASE_MACOS:-}" ;;
esac

STRIP_DEBUG="${STRIP_DEBUG_SYMBOLS:-false}"
PARALLEL_JOBS="${PARALLEL_JOBS:-0}"

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

# Substitute package name template
PACKAGE_TEMPLATE="${PACKAGE_NAME_TEMPLATE:-qt-{version}-static-{platform}}"
PACKAGE_NAME="${PACKAGE_TEMPLATE/\{version\}/$QT_VERSION}"
PACKAGE_NAME="${PACKAGE_NAME/\{platform\}/$PLATFORM}"

# === Directory layout =========================================================
INSTALL_DIR="$INSTALL_PREFIX"
ARTIFACT_DIR="$WORK_DIR/artifacts"

mkdir -p "$WORK_DIR" "$INSTALL_DIR" "$ARTIFACT_DIR"

log_step "Qt static build parameters (${PLATFORM})"
echo "Qt version        : $QT_VERSION"
echo "Submodules        : ${MODULE_LIST[*]}"
echo "Common CMake opts : $CMAKE_OPTIONS_COMMON"
echo "QtBase CMake opts : ${CMAKE_OPTIONS_QTBASE:-(none)}"
echo "QtBase platform   : ${QTBASE_PLATFORM_OPTS:-(none)}"
echo "Parallel jobs     : $PARALLEL_JOBS"
echo "Strip debug syms  : $STRIP_DEBUG"
echo "Work directory    : $WORK_DIR"
echo "Install prefix    : $INSTALL_DIR"
echo "Package name      : $PACKAGE_NAME"

# === Verify build tools =======================================================
log_step "Step 0: Verify build tools"
for tool in cmake ninja python3 perl; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not in PATH: $tool"
    echo "$(printf '%-10s' "$tool"): $(command -v "$tool")"
done

if [[ "$PLATFORM" == "macos" ]]; then
    xcode-select -p >/dev/null 2>&1 || die "Xcode command line tools not installed"
    echo "Xcode path        : $(xcode-select -p)"
fi

# === Build each submodule =====================================================
build_submodule() {
    local module="$1"
    local src_dir="$WORK_DIR/${module}-src"
    local build_dir="$WORK_DIR/${module}-build"
    local archive_path="$WORK_DIR/${module}.tar.xz"

    log_step "Building: ${module}"

    # --- Download ---
    local download_url="${SUBMODULE_URL_TEMPLATE/\{submodule\}/$module}"
    if [[ -f "$src_dir/CMakeLists.txt" ]]; then
        echo "Source already exists, skipping download: $src_dir"
    else
        if [[ ! -f "$archive_path" ]]; then
            echo "Downloading: $download_url"
            curl -L --fail --retry 3 --retry-delay 5 -C - -o "$archive_path" "$download_url"
        else
            echo "Archive already exists: $archive_path"
        fi

        # Extract (archive contains a top-level dir, move contents to src_dir)
        echo "Extracting to: $src_dir"
        local extract_tmp="$WORK_DIR/${module}-extract-tmp"
        rm -rf "$extract_tmp"
        mkdir -p "$extract_tmp"
        tar -xf "$archive_path" -C "$extract_tmp"

        local inner_dir
        inner_dir="$(find "$extract_tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
        if [[ -n "$inner_dir" ]]; then
            mkdir -p "$src_dir"
            if command -v rsync >/dev/null 2>&1; then
                rsync -a "$inner_dir/" "$src_dir/"
            else
                cp -a "$inner_dir/." "$src_dir/"
            fi
        fi
        rm -rf "$extract_tmp"
    fi

    [[ -f "$src_dir/CMakeLists.txt" ]] || die "CMakeLists.txt not found in $src_dir"

    # --- CMake configure ---
    # Build the CMake options array
    local cmake_args=()
    cmake_args+=("-S" "$src_dir" "-B" "$build_dir" "-G" "Ninja")
    cmake_args+=("-DCMAKE_INSTALL_PREFIX=$INSTALL_DIR")

    # Modules after qtbase need to find the installed qtbase
    if [[ "$module" != "qtbase" ]]; then
        cmake_args+=("-DCMAKE_PREFIX_PATH=$INSTALL_DIR")
    fi

    # Common options
    # shellcheck disable=SC2206
    cmake_args+=($CMAKE_OPTIONS_COMMON)

    # qtbase-specific options
    if [[ "$module" == "qtbase" ]]; then
        if [[ -n "${CMAKE_OPTIONS_QTBASE:-}" ]]; then
            # shellcheck disable=SC2206
            cmake_args+=($CMAKE_OPTIONS_QTBASE)
        fi
        if [[ -n "${QTBASE_PLATFORM_OPTS:-}" ]]; then
            # shellcheck disable=SC2206
            cmake_args+=($QTBASE_PLATFORM_OPTS)
        fi
    fi

    echo "CMake configure options:"
    printf '  %s\n' "${cmake_args[@]}"

    cmake "${cmake_args[@]}"

    # --- Build ---
    echo "Building ${module} (parallel: ${PARALLEL_JOBS}) ..."
    cmake --build "$build_dir" --parallel "$PARALLEL_JOBS"

    # --- Install ---
    echo "Installing ${module} to ${INSTALL_DIR} ..."
    cmake --install "$build_dir"

    echo "Done: ${module}"
}

# Build all submodules in order
TOTAL_MODULES=${#MODULE_LIST[@]}
CURRENT=0
for module in "${MODULE_LIST[@]}"; do
    CURRENT=$((CURRENT + 1))
    log_step "Module ${CURRENT}/${TOTAL_MODULES}: ${module}"
    build_submodule "$module"
done

# === Copy static OpenSSL into Qt prefix (Linux only) =========================
# When OPENSSL_ROOT_DIR is set (Linux), copy the static OpenSSL .a files and
# headers into the Qt install directory so they are included in the package.
# This allows downstream projects (RainBook) to use the same static OpenSSL.
if [[ -n "${OPENSSL_ROOT_DIR:-}" && -d "${OPENSSL_ROOT_DIR}/lib" ]]; then
    log_step "Copy static OpenSSL into Qt prefix"
    echo "OPENSSL_ROOT_DIR=$OPENSSL_ROOT_DIR"
    mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/include"

    # Copy static libraries (.a files)
    for lib in "$OPENSSL_ROOT_DIR/lib/"*.a; do
        [[ -f "$lib" ]] && cp -a "$lib" "$INSTALL_DIR/lib/"
    done

    # Copy headers
    if [[ -d "$OPENSSL_ROOT_DIR/include/openssl" ]]; then
        cp -a "$OPENSSL_ROOT_DIR/include/openssl" "$INSTALL_DIR/include/"
    fi

    # Copy pkg-config files (helps CMake find_package(OpenSSL))
    if [[ -d "$OPENSSL_ROOT_DIR/lib/pkgconfig" ]]; then
        mkdir -p "$INSTALL_DIR/lib/pkgconfig"
        cp -a "$OPENSSL_ROOT_DIR/lib/pkgconfig/"*.pc "$INSTALL_DIR/lib/pkgconfig/" 2>/dev/null || true
    fi

    echo "OpenSSL static libraries and headers copied to $INSTALL_DIR"
fi

# === Strip debug symbols (optional) ==========================================
if [[ "$STRIP_DEBUG" == "true" ]]; then
    log_step "Strip debug symbols from static libraries"
    FOUND_COUNT=0
    while IFS= read -r -d '' lib_file; do
        strip --strip-debug "$lib_file" 2>/dev/null || true
        FOUND_COUNT=$((FOUND_COUNT + 1))
    done < <(find "$INSTALL_DIR" -type f -name '*.a' -print0)
    echo "Stripped $FOUND_COUNT static library files"
fi

# === Write build info ==========================================================
log_step "Write Qt build info"
HOST_ARCH="$(uname -m)"
COMPILER_NAME="gcc"
[[ "$PLATFORM" == "macos" ]] && COMPILER_NAME="clang"

QT_CONF_PATH="$INSTALL_DIR/qt-static-build-info.json"
cat > "$QT_CONF_PATH" <<EOF
{
  "version": "$QT_VERSION",
  "prefix": "$INSTALL_DIR",
  "host": "$PLATFORM-$HOST_ARCH",
  "static": true,
  "modules": [$(echo "$SUBMODULES" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | paste -sd,)],
  "compiler": "$COMPILER_NAME"
}
EOF
echo "Build info written to: $QT_CONF_PATH"

# === Package artifact ==========================================================
log_step "Package artifact"
ARCHIVE_PATH="$ARTIFACT_DIR/$PACKAGE_NAME.tar.xz"
rm -f "$ARCHIVE_PATH"

echo "Compressing $INSTALL_DIR -> $ARCHIVE_PATH"
tar -cJf "$ARCHIVE_PATH" -C "$(dirname "$INSTALL_DIR")" "$(basename "$INSTALL_DIR")"

echo ""
echo "========================================"
echo "  Build succeeded"
echo "========================================"
echo "Artifact path: $ARCHIVE_PATH"
echo "Install prefix: $INSTALL_DIR"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "artifact_path=$ARCHIVE_PATH" >> "$GITHUB_OUTPUT"
    echo "install_prefix=$INSTALL_DIR" >> "$GITHUB_OUTPUT"
    echo "package_name=$PACKAGE_NAME" >> "$GITHUB_OUTPUT"
fi
