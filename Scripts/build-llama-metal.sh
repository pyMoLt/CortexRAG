#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b11461
COMMIT=4d756bc72bf00a4aacf410ae15a2d315f3db400d
PATCHES=(Scripts/llama.cpp-no-logits.patch Scripts/llama.cpp-metal-idle.patch)
SOURCE="${LLAMA_SOURCE:-Vendor/llama.cpp}"
BUILD="${LLAMA_BUILD:-Vendor/llama-build}"
OUT=Vendor/llama
FLAVOR=metal

STAMP="$TAG $(cat "${PATCHES[@]}" | shasum -a 256 | cut -c1-12) $FLAVOR"
if [[ -f "$OUT/lib/libllamacpp.a" && "$(cat "$OUT/BUILD" 2>/dev/null || true)" == "$STAMP" ]]; then
  echo "llama.cpp $TAG already built in $OUT"
  exit 0
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ ! -d "$SOURCE" ]]; then
  git -c advice.detachedHead=false -c core.autocrlf=false clone --quiet --depth 1 --branch "$TAG" \
    https://github.com/ggml-org/llama.cpp "$SOURCE"
elif [[ "$(git -C "$SOURCE" describe --tags --exact-match 2>/dev/null || true)" != "$TAG" ]]; then
  git -C "$SOURCE" fetch --quiet --depth 1 origin tag "$TAG"
  git -C "$SOURCE" checkout --quiet --force "$TAG"
fi

if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo "llama.cpp's $TAG isn't commit $COMMIT" >&2
  exit 1
fi

for PATCH in "${PATCHES[@]}"; do
  if git -C "$SOURCE" apply --check "$PWD/$PATCH" 2>/dev/null; then
    git -C "$SOURCE" apply "$PWD/$PATCH"
  elif ! git -C "$SOURCE" apply --reverse --check "$PWD/$PATCH" 2>/dev/null; then
    echo "$PATCH doesn't apply to $SOURCE" >&2
    exit 1
  fi
done

export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
if ! command -v cmake > /dev/null; then
  if [[ ! -x Vendor/cmake-venv/bin/cmake ]]; then
    uv venv --quiet Vendor/cmake-venv --python 3.12
    uv pip install --quiet --python Vendor/cmake-venv/bin/python cmake==4.4.4 ninja==1.13.2
  fi
  export PATH="$PWD/Vendor/cmake-venv/bin:$PATH"
fi

GENERATOR=$(command -v ninja > /dev/null && echo Ninja || echo "Unix Makefiles")
cmake -S "$SOURCE" -B "$BUILD" -G "$GENERATOR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_BUILD_MTMD=ON \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF > /dev/null
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" --target llama mtmd > /dev/null

B="$BUILD"
mkdir -p "$OUT/lib" "$OUT/include"
xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libllamacpp.a" \
  $B/src/libllama.a $B/tools/mtmd/libmtmd.a $B/ggml/src/libggml.a $B/ggml/src/libggml-base.a \
  $B/ggml/src/libggml-cpu.a $B/ggml/src/ggml-metal/libggml-metal.a $B/ggml/src/ggml-blas/libggml-blas.a \
  $B/vendor/hash/libvendor-hash.a

cp "$SOURCE/include/llama.h" "$SOURCE"/ggml/include/*.h "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" \
  "$OUT/include/"
printf '// Written by Scripts/build-llama-metal.sh.\n#define LLAMA_BUILD_TAG "%s"\n' "$TAG" > "$OUT/include/llama-build.h"
echo "$STAMP" > "$OUT/BUILD"
echo "Built llama.cpp $TAG (patched, $FLAVOR) into $OUT"
