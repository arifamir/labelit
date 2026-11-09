#!/bin/bash
# Builds llama.cpp (MIT) for EmbeddingGemma 2 as one static library, with its headers. Pinned to the same tag and patch
# as DigUp (https://github.com/ARahim3/DigUp, MIT), whose build script this follows. Does nothing if already built.
#
#   macOS: Metal, arm64          → Vendor/llama/{lib/libllamacpp.a,include}
#   Linux: CPU                   → Vendor/linux/llama/{lib/libllamacpp.a,include}, plus stb_image.h in Vendor/linux/stb
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b11461   # first tags with EmbeddingGemma 2 (text + vision) are b11452+
COMMIT=4d756bc72bf00a4aacf410ae15a2d315f3db400d
PATCH=scripts/llama.cpp-no-logits.patch   # skips 1 MiB of unused logits per token

case "$(uname -s)" in
  Darwin)
    PLATFORM="metal-arm64"
    ROOT=Vendor
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    BACKEND=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64)
    JOBS=$(sysctl -n hw.ncpu)
    ;;
  Linux)
    PLATFORM="cpu-$(uname -m)"
    ROOT=Vendor/linux
    # No OpenMP (ggml's own threads instead: one less runtime to ship); position-independent for Swift's executables.
    BACKEND=(-DGGML_METAL=OFF -DGGML_OPENMP=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
    JOBS=$(nproc)
    ;;
  *) echo "build-llama.sh: unsupported system $(uname -s)" >&2; exit 1 ;;
esac

SOURCE=$ROOT/llama.cpp
BUILD=$ROOT/llama-build
OUT=$ROOT/llama
STAMP="$TAG $(sed -n '/^diff --git/,$p' "$PATCH" | shasum -a 256 | cut -c1-12) $PLATFORM"   # the diff only, not the comment above it
if [[ -f "$OUT/lib/libllamacpp.a" && "$(cat "$OUT/BUILD" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi

if [[ ! -d "$SOURCE" ]]; then
  mkdir -p "$ROOT"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SOURCE"
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo "llama.cpp $TAG isn't commit $COMMIT: not building it" >&2
  exit 1
fi
if git -C "$SOURCE" apply --check "$PWD/$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "$PWD/$PATCH"
elif ! git -C "$SOURCE" apply --reverse --check "$PWD/$PATCH" 2>/dev/null; then
  echo "$PATCH doesn't apply: not building" >&2
  exit 1
fi

GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")
cmake -S "$SOURCE" -B "$BUILD" -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release "${BACKEND[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DLLAMA_BUILD_MTMD=ON \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_CURL=OFF > /dev/null
cmake --build "$BUILD" --config Release -j "$JOBS" --target llama mtmd > /dev/null

# Every static library the two targets produced, combined into one.
mkdir -p "$OUT/lib" "$OUT/include"
LIBS=$(find "$BUILD" -name '*.a' -not -name 'libllamacpp.a' | sort)
rm -f "$OUT/lib/libllamacpp.a"
if [[ "$(uname -s)" == Darwin ]]; then
  # shellcheck disable=SC2086
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libllamacpp.a" $LIBS
else
  { echo "CREATE $OUT/lib/libllamacpp.a"; for lib in $LIBS; do echo "ADDLIB $lib"; done; echo "SAVE"; echo "END"; } | ar -M
fi
cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" \
  "$OUT/include/"
if [[ "$(uname -s)" == Linux ]]; then
  mkdir -p "$ROOT/stb"
  cp "$SOURCE/vendor/stb/stb_image.h" "$ROOT/stb/"
fi
echo "$STAMP" > "$OUT/BUILD"
echo "Built llama.cpp $TAG (patched, $PLATFORM) into $OUT"
