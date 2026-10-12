#!/bin/bash
# Builds a self-contained BAR.app (engine, pr-downloader, Mesa/Zink/KosmicKrisp)
# and optionally a DMG. Game content is not bundled, the app downloads it.
#
# Usage: make-bar-app.sh <build dir> <output dir>
# Env:
#   SIGN_IDENTITY  codesign identity, "-" (default) for ad-hoc
#   MESA_PREFIX    default: $(brew --prefix mesa)
#   VULKAN_PREFIX  default: $(brew --prefix vulkan-loader)
#   BUNDLE_ID      default: io.github.recoil.bar-mac
#   MAKE_DMG=1     also create <output dir>/BAR-<version>.dmg
set -euo pipefail

BUILD_DIR="$(cd "$1" && pwd)"
OUT_DIR="$2"
SRC_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MESA_PREFIX="${MESA_PREFIX:-$(brew --prefix mesa)}"
VULKAN_PREFIX="${VULKAN_PREFIX:-$(brew --prefix vulkan-loader)}"
SDL3_PREFIX="${SDL3_PREFIX:-$(brew --prefix sdl3)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.recoil.bar-mac}"
VERSION="$(head -n1 "$BUILD_DIR/VERSION")"
MIN_OS="$(sw_vers -productVersion | cut -d. -f1).0"

APP="$OUT_DIR/BAR.app"
ENGINE="$APP/Contents/Resources/engine"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$ENGINE/lib" "$ENGINE/mesa/lib" "$ENGINE/mesa/share/vulkan/icd.d" "$APP/Contents/Resources/licenses"

# bundle skeleton
sed -e "s/###VERSION###/$VERSION/g" -e "s/###BUNDLE_ID###/$BUNDLE_ID/g" -e "s/###MIN_OS###/$MIN_OS/g" \
	"$SRC_DIR/installer/Mac/bar/Info.plist" > "$APP/Contents/Info.plist"
install -m 755 "$SRC_DIR/installer/Mac/bar/launch.sh" "$APP/Contents/MacOS/BAR"
cp "$SRC_DIR/installer/Mac/spring.icns" "$APP/Contents/Resources/"

# engine
cp "$BUILD_DIR/spring" "$BUILD_DIR/libunitsync.dylib" "$BUILD_DIR/tools/pr-downloader/src/pr-downloader" "$ENGINE/"
cp -R "$BUILD_DIR/base" "$ENGINE/"
cp -R "$SRC_DIR/cont/fonts" "$SRC_DIR/cont/LuaUI" "$SRC_DIR/cont/cmdcolors.txt" "$SRC_DIR/cont/ctrlpanel.txt" "$SRC_DIR/cont/luaui.lua" "$ENGINE/"
cp "$BUILD_DIR/VERSION" "$SRC_DIR/installer/Mac/bar/fonts.conf" "$ENGINE/"

# skirmish AIs, if they were built
for ai in AI/Interfaces/C AI/Skirmish/NullAI AI/Skirmish/BARb; do
	if [ -f "$BUILD_DIR/$ai/cmake_install.cmake" ]; then
		cmake -DCMAKE_INSTALL_PREFIX="$ENGINE" -P "$BUILD_DIR/$ai/cmake_install.cmake"
	fi
done

# Mesa EGL + Zink + KosmicKrisp, loaded by MacEGLBridge from <engine>/mesa
cat > "$ENGINE/mesa/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json" <<EOF
{
    "ICD": {
        "api_version": "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ICD"]["api_version"])' "$MESA_PREFIX/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json")",
        "library_path": "../../../lib/libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.1"
}
EOF

# copy all non-system dylib dependencies and make every reference bundle relative;
# sdl2-compat dlopen()s SDL3 from next to itself
python3 "$SRC_DIR/installer/Mac/bundle-dylibs.py" "$ENGINE" "$APP/Contents/Resources/licenses" \
	"mesa=$MESA_PREFIX/lib/libEGL.1.dylib" \
	"mesa=$MESA_PREFIX/lib/libvulkan_kosmickrisp.dylib" \
	"mesa=$(ls "$MESA_PREFIX"/lib/libgallium-*.dylib)" \
	"mesa=$VULKAN_PREFIX/lib/libvulkan.1.dylib" \
	"lib=$SDL3_PREFIX/lib/libSDL3.0.dylib:libSDL3.dylib"

# licenses of everything shipped
cp "$SRC_DIR/LICENSE" "$SRC_DIR/gpl-2.0.txt" "$SRC_DIR/gpl-3.0.txt" "$APP/Contents/Resources/licenses/"
cp "$SRC_DIR/cont/fonts/COPYING" "$APP/Contents/Resources/licenses/fonts-COPYING"
cp "$SRC_DIR/installer/Mac/bar/README-licenses.txt" "$APP/Contents/Resources/licenses/README.txt"

# sign inside out
SIGN_ARGS=(--force --timestamp --options runtime -s "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" = "-" ] && SIGN_ARGS=(--force -s -)
find "$ENGINE" -name '*.dylib' -print0 | xargs -0 codesign "${SIGN_ARGS[@]}"
codesign "${SIGN_ARGS[@]}" "$ENGINE/pr-downloader"
codesign "${SIGN_ARGS[@]}" --entitlements "$SRC_DIR/installer/Mac/bar/entitlements.plist" "$ENGINE/spring"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

if [ "${MAKE_DMG:-0}" = 1 ]; then
	DMG="$OUT_DIR/BAR-$VERSION.dmg"
	STAGE="$(mktemp -d)"
	cp -R "$APP" "$STAGE/"
	ln -s /Applications "$STAGE/Applications"
	rm -f "$DMG"
	hdiutil create -volname "Beyond All Reason" -srcfolder "$STAGE" -format UDZO "$DMG"
	rm -rf "$STAGE"
	[ "$SIGN_IDENTITY" = "-" ] || codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
	echo "$DMG"
fi
