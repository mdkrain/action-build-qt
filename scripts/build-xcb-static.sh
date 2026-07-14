#!/usr/bin/env bash
# =============================================================================
# Build static XCB / X11 / xkbcommon libraries on Linux.
#
# Qt's XCB QPA plugin references symbols from:
#   libxcb, libxcb-icccm, libxcb-image, libxcb-keysyms,
#   libxcb-render-util, libxcb-cursor, libxkbcommon, libxkbcommon-x11,
#   libX11, libX11-xcb, libXau, libXdmcp
#
# Building these as static-only (.a) libraries and pointing Qt's CMake at
# the resulting prefix eliminates ~15 dynamic dependencies from the final
# executable. OpenGL (libGL/libEGL) and glibc remain dynamic by design.
#
# Output: $XCB_STATIC_PREFIX contains lib/, include/, lib/pkgconfig/
#         with static-only .a files and .pc files whose Libs.private
#         lists all transitive dependencies.
#
# Usage:
#   XCB_STATIC_PREFIX=/path/to/prefix bash scripts/build-xcb-static.sh
# =============================================================================

set -euo pipefail

# === Helpers ==================================================================
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

# === Configuration ============================================================
PREFIX="${XCB_STATIC_PREFIX:-${RUNNER_WORKSPACE:-$HOME/qt-build-work}/xcb-static}"
SRC_DIR="${RUNNER_WORKSPACE:-$HOME/qt-build-work}/xcb-src"
NPROC="${PARALLEL_JOBS:-0}"
# 0 means auto-detect (same convention as build-qt-unix.sh).
# make -j0 is invalid on GNU make, so resolve to actual CPU count.
if [[ "$NPROC" -le 0 ]]; then
    NPROC="$(nproc 2>/dev/null || echo 4)"
fi

mkdir -p "$PREFIX" "$SRC_DIR"

# Make our prefix visible to pkg-config for all subsequent builds.
# System pkg-config paths are still searched (for xcb-proto, etc.).
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
# Use --static so .pc files return Libs.private (transitive deps).
export PKG_CONFIG="pkg-config --static"

log_step "Static XCB stack build parameters"
echo "Prefix          : $PREFIX"
echo "Source dir      : $SRC_DIR"
echo "Parallel jobs   : $NPROC"
echo "PKG_CONFIG_PATH : $PKG_CONFIG_PATH"
echo "PKG_CONFIG      : $PKG_CONFIG"

# === Verify build tools =======================================================
for tool in curl tar make gcc pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not in PATH: $tool"
done

# Autotools needs autoconf/automake/libtool; meson for xkbcommon.
for tool in autoconf automake libtoolize meson ninja; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not in PATH: $tool"
done

# xcb-proto provides the Python module xcbgen and XML descriptions needed
# by libxcb's configure. On Debian/Ubuntu it is installed via xcb-proto.
pkg-config --exists xcb-proto || die "xcb-proto not found (apt install xcb-proto)"
echo "xcb-proto xcbincludedir: $(pkg-config --variable=xcbincludedir xcb-proto)"
echo "xcb-proto pythondir     : $(pkg-config --variable=pythondir xcb-proto)"

# === Helper: download + extract ==============================================
download_and_extract() {
    local url="$1" dirname="$2"
    local filename
    filename="$(basename "$url")"
    cd "$SRC_DIR"
    if [[ ! -f "$filename" ]]; then
        echo "Downloading: $url"
        curl -L --fail --retry 3 --retry-delay 5 -o "$filename" "$url"
    else
        echo "Already downloaded: $filename"
    fi
    rm -rf "$dirname"
    tar xf "$filename"
    [[ -d "$dirname" ]] || die "Extracted dir not found: $dirname"
    cd "$dirname"
}

# === Helper: build autotools package =========================================
build_autotools() {
    local url="$1" dirname="$2"
    shift 2
    local extra_args=("$@")

    log_step "Building: $dirname (autotools)"

    download_and_extract "$url" "$dirname"

    # --enable-static --disable-shared  => static-only .a files
    # --with-pic                        => position-independent code (for shared Qt)
    # CFLAGS/CXXFLAGS=-fPIC             => ensure PIC even if configure misses it
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --with-pic \
        CFLAGS="-fPIC -O2" \
        CXXFLAGS="-fPIC -O2" \
        "${extra_args[@]}"

    make -j"$NPROC"
    make install
}

# === Helper: build meson package =============================================
build_meson() {
    local url="$1" dirname="$2"
    shift 2
    local extra_args=("$@")

    log_step "Building: $dirname (meson)"

    download_and_extract "$url" "$dirname"

    rm -rf build
    meson setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        -Dc_args="-fPIC -O2" \
        -Dcpp_args="-fPIC -O2" \
        "${extra_args[@]}"

    ninja -C build
    ninja -C build install
}

# === 1. libXau (no deps) =====================================================
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/libXau-1.0.11.tar.xz" \
    "libXau-1.0.11"

# === 2. libXdmcp (no deps) ===================================================
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/libXdmcp-1.1.5.tar.xz" \
    "libXdmcp-1.1.5"

# === 3. libxcb (depends on Xau, Xdmcp, xcb-proto) ============================
# All extensions (randr, render, shm, sync, xfixes, shape, xkb, xinput,
# xinerama, glx, present, etc.) are built by default in libxcb 1.17+.
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/libxcb-1.17.0.tar.xz" \
    "libxcb-1.17.0" \
    --enable-xinput=yes \
    --enable-xkb=yes

# === 4. xcb-util (base utility lib) ==========================================
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/xcb-util-0.4.1.tar.xz" \
    "xcb-util-0.4.1"

# === 5. xcb-util-wm (ICCCM, EWMH) ============================================
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/xcb-util-wm-0.4.2.tar.xz" \
    "xcb-util-wm-0.4.2"

# === 6. xcb-util-image =======================================================
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/xcb-util-image-0.4.1.tar.xz" \
    "xcb-util-image-0.4.1"

# === 7. xcb-util-keysyms =====================================================
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/xcb-util-keysyms-0.4.1.tar.xz" \
    "xcb-util-keysyms-0.4.1"

# === 8. xcb-util-renderutil ==================================================
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/xcb-util-renderutil-0.3.10.tar.xz" \
    "xcb-util-renderutil-0.3.10"

# === 9. xcb-util-cursor (depends on renderutil + image) ======================
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/xcb-util-cursor-0.1.5.tar.xz" \
    "xcb-util-cursor-0.1.5"

# === 10. libxkbcommon + libxkbcommon-x11 (meson) ============================
# -Denable-x11=true builds libxkbcommon-x11 (depends on xcb).
# -Denable-wayland=false: not needed here (Wayland uses its own protocol).
build_meson \
    "https://xkbcommon.org/download/libxkbcommon-1.7.2.tar.xz" \
    "libxkbcommon-1.7.2" \
    -Denable-docs=false \
    -Denable-x11=true \
    -Denable-wayland=false

# === 11. libX11 + libX11-xcb (autotools) =====================================
# libX11's source tree also builds libX11-xcb (the XGetXCBConnection shim).
# --without-xmlto / --disable-specs: avoid XML doc build tools.
build_autotools \
    "https://xorg.freedesktop.org/archive/individual/lib/libX11-1.8.10.tar.xz" \
    "libX11-1.8.10" \
    --disable-specs \
    --without-xmlto \
    --without-fop \
    --without-xsltproc

# === Verify output ============================================================
log_step "Static XCB stack build complete"
echo "Installed .a files:"
ls -1 "$PREFIX/lib/"*.a 2>/dev/null | sed 's|.*/|  |'
echo ""
echo "Installed .pc files:"
ls -1 "$PREFIX/lib/pkgconfig/"*.pc 2>/dev/null | sed 's|.*/|  |'
echo ""
echo "Verify pkg-config --static --libs xcb:"
pkg-config --static --libs xcb
echo ""
echo "Verify pkg-config --static --libs xkbcommon-x11:"
pkg-config --static --libs xkbcommon-x11
echo ""
echo "Prefix: $PREFIX"
