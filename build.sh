#!/bin/bash
# MKDJ: single-invocation swiftc build (no xcodebuild project).
# App -> MKDJ.app at the repo root; headless CLI -> build/mkdjprobe.
# The Signalsmith Stretch C++ shim is compiled once with clang++ (-O2 always:
# debug builds of the DSP are ~10× slower) and linked into both binaries.
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --show-sdk-path)"
APP="MKDJ.app"   # built at the repo root, like BPMPLS
OUT="build"      # probe CLI + its dylib dir stay under build/
BUILD="build"    # object-file staging
SHIM_H="Sources/Audio/Stretch/mk_bridging.h"
STOUCH_CPP="Sources/Audio/Stretch/soundtouch_shim.cpp"
STOUCH_O="$BUILD/soundtouch_shim.o"
STOUCH_DIR="Sources/Audio/Stretch/vendor/soundtouch"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT" "$BUILD"

# Grep gate: the custom DJFader is dead — if it returns, a patch
# silently missed. (Native NSSliders own all faders now.)
if grep -rq "struct DJFader" Sources/; then
  echo "ERROR: DJFader found in Sources — native slider conversion regressed"; exit 1
fi

# Grep gate: frame-rate .id() on a lane view tears down in-flight
# DragGestures (identity churn 30-60x/s while playing) — the drag-loop /
# dead-overview-seek regression. Lane redraws invalidate via @Published
# observation (clock.tick read in body), never via identity.
# Also: MKDJ typography law — no monospace fonts in the UI; the
# hierarchy is size/weight/color only (by design).
if grep -rq "monospaced\|design: .monospaced" Sources/Views/; then
  echo "ERROR: monospace font found in Sources/Views — use size/weight/color hierarchy"; exit 1
fi

if grep -rq "\.id(clock" Sources/Views/; then
  echo "ERROR: .id(clock...) found in Sources/Views — use observation-driven invalidation, never identity, on gesture hosts"; exit 1
fi

# beep guard (NSBeep suppression) — split from the retired stretch
# shim; Signalsmith itself is no longer compiled (the
# push-path deletion removed its only callers; keylock = in-render SoundTouch).
BEEP_O="$BUILD/beep_guard.o"
clang++ -O2 -c Sources/Audio/Stretch/beep_guard.cpp -o "$BEEP_O"

# fishhook (BSD) — runtime symbol rebinding for the NSBeep suppression
# (static __interpose is ignored under arm64 chained fixups).
FISHHOOK_O="$BUILD/fishhook.o"
clang -O2 -c Sources/Audio/Stretch/vendor/fishhook.c -o "$FISHHOOK_O"

# FFmpeg minimal (LGPL-2.1+, vendored dylibs in vendor/ffmpeg) — decode
# extension for ogg/opus/wma/amr.
FFV="Sources/Audio/Stretch/vendor/ffmpeg"
FFMPEG_O="$BUILD/ffmpeg_shim.o"
clang++ -O2 -std=c++11 \
  -I Sources/Audio/Stretch -I "$FFV/include" \
  -c Sources/Audio/Stretch/ffmpeg_shim.cpp -o "$FFMPEG_O"
FF_LIB_FLAGS="-L$FFV/lib -lavformat -lavcodec -lavutil -lswresample"

# SoundTouch 2.4.1 (LGPL, vendored) — third time-stretch engine.
# FLOAT_SAMPLES selects the float sample type; the arm64 stub replaces the
# x86-only cpu detection. One object per source into $BUILD.
for f in "$STOUCH_DIR"/*.cpp; do
  clang++ -O2 -std=c++11 -DFLOAT_SAMPLES -I "$STOUCH_DIR" \
    -c "$f" -o "$BUILD/st_$(basename "$f" .cpp).o"
done
STOUCH_LIB_OBJS=$(ls "$BUILD"/st_*.o)

clang++ -O2 -std=c++11 -DFLOAT_SAMPLES \
  -I Sources/Audio/Stretch/vendor -I Sources/Audio/Stretch \
  -c "$STOUCH_CPP" -o "$STOUCH_O"

FLAGS=(
  -swift-version 5
  -sdk "$SDK"
  -O
  -framework SwiftUI
  -framework AppKit
  -framework AVFoundation
  -framework Accelerate
  -framework UniformTypeIdentifiers
  -target arm64-apple-macosx14.0
  -import-objc-header "$SHIM_H"
  "$STOUCH_O"
  $STOUCH_LIB_OBJS
  "$FFMPEG_O"
  "$FISHHOOK_O"
  -lc++
  $FF_LIB_FLAGS
)

# App: everything under Sources (has @main in MKApp.swift).
# rpath-based dylib refs (the vendored dylibs' IDs are @rpath) — the
# deliverables must never depend on volatile /tmp paths.
swiftc $(find Sources -name '*.swift' | sort) "${FLAGS[@]}" "$BEEP_O" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$APP/Contents/MacOS/MKDJ"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Frameworks"

# App icon (generated, like BPMPLS): SF Symbol on the theme's dark base.
ICONSET="$BUILD/AppIcon.iconset"
swift Tools/makeicon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp -P "$FFV"/lib/libavcodec*.dylib "$FFV"/lib/libavformat*.dylib \
      "$FFV"/lib/libavutil*.dylib "$FFV"/lib/libswresample*.dylib \
      "$APP/Contents/Frameworks/" 2>/dev/null || true
mkdir -p "$OUT/lib"
cp -P "$FFV"/lib/libavcodec*.dylib "$FFV"/lib/libavformat*.dylib \
      "$FFV"/lib/libavutil*.dylib "$FFV"/lib/libswresample*.dylib \
      "$OUT/lib/" 2>/dev/null || true
touch "$APP"
# Resources were added after the linker's adhoc signature — re-affix it,
# or Gatekeeper/codesign --verify reject the bundle.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Probe CLI: engine sources without the app entry point, plus Probe/main.swift.
# Its embedded Info.plist names MKApplication as principal class, so the
# hotkey-during-drag gate can exercise the tracking-pump rescue in-probe.
swiftc $(find Sources -name '*.swift' ! -name 'MKApp.swift' | sort) Probe/main.swift "$BEEP_O" \
  "${FLAGS[@]}" -Xlinker -rpath -Xlinker @executable_path/lib \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Probe/probe-Info.plist \
  -o "$OUT/mkdjprobe"

# Newest execs ALWAYS go to the project-level _executable dir (the
# standing launch location). ditto preserves the adhoc signature;
# re-affix anyway.
DEPLOY="../../_executable"
mkdir -p "$DEPLOY"
ditto "$APP" "$DEPLOY/MKDJ.app"
codesign --force --sign - "$DEPLOY/MKDJ.app" >/dev/null 2>&1 || true
mkdir -p "$DEPLOY/lib"
ditto "$OUT/lib" "$DEPLOY/lib"
ditto "$OUT/mkdjprobe" "$DEPLOY/mkdjprobe"

echo "Built $APP and $OUT/mkdjprobe (arm64) — deployed to $DEPLOY"
