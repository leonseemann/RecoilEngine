#!/bin/bash
# Builds Mesa's EGL and Zink with the patches from installer/Mac/mesa-patches,
# using the same Mesa version as the installed Homebrew mesa (which still
# provides KosmicKrisp).
#
# Usage: make-mesa.sh <work dir> <install prefix>
# Env:
#   MESA_VERSION   default: version of the installed Homebrew mesa
#   MOLTENVK_DIR   default: $(brew --prefix molten-vk), only its headers are used
set -euo pipefail

WORK_DIR="$(mkdir -p "$1" && cd "$1" && pwd)"
PREFIX="$(mkdir -p "$2" && cd "$2" && pwd)"
SRC_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MESA_VERSION="${MESA_VERSION:-$(brew list --versions mesa | awk '{print $2}' | sed 's/_[0-9]*$//')}"
MOLTENVK_DIR="${MOLTENVK_DIR:-$(brew --prefix molten-vk)}"
MESA_SRC="$WORK_DIR/mesa-$MESA_VERSION"

if [ ! -d "$MESA_SRC" ]; then
	curl -fL -o "$WORK_DIR/mesa-$MESA_VERSION.tar.xz" "https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz"
	tar -xf "$WORK_DIR/mesa-$MESA_VERSION.tar.xz" -C "$WORK_DIR"
	for p in "$SRC_DIR"/installer/Mac/mesa-patches/*.patch; do
		patch -d "$MESA_SRC" -p1 < "$p"
	done
fi

# Mesa's code generators need mako and pyyaml, the build needs a newer bison
python3 -m venv "$WORK_DIR/venv"
"$WORK_DIR/venv/bin/pip" install -q mako pyyaml packaging
export PATH="$WORK_DIR/venv/bin:$(brew --prefix bison)/bin:$PATH"

RECONFIGURE=
[ -d "$WORK_DIR/build/meson-private" ] && RECONFIGURE=--reconfigure
meson setup $RECONFIGURE "$WORK_DIR/build" "$MESA_SRC" \
	--buildtype=release \
	--prefix="$PREFIX" \
	-Db_ndebug=true \
	-Dstrip=true \
	-Dplatforms=macos \
	-Dopengl=true \
	-Degl=enabled \
	-Dgles1=disabled \
	-Dgles2=enabled \
	-Dglx=disabled \
	-Dgallium-drivers=zink \
	-Dvulkan-drivers= \
	-Dvulkan-layers= \
	-Dgallium-rusticl=false \
	-Dvideo-codecs= \
	-Dtools= \
	-Dllvm=disabled \
	-Dmoltenvk-dir="$MOLTENVK_DIR" \
	-Dvulkan-loader-rpath=@loader_path/../lib
ninja -C "$WORK_DIR/build" install
