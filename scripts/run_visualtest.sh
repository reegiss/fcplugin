#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.benchmark_build"
SRC="$REPO_ROOT/AIUpscaler/AIUpscaler"

INPUT="${1:-}"
OUTPUT="${2:-/tmp/aiupscaler_test}"

if [ -z "$INPUT" ]; then
  echo "Usage: $0 <input.png> [output_dir]"
  exit 1
fi

if [ ! -d "$SRC/Resources/realesrgan_4x.mlmodelc" ]; then
  echo "Error: realesrgan_4x.mlmodelc not found."
  exit 1
fi

mkdir -p "$BUILD_DIR" "$OUTPUT"

echo "▸ Compiling Metal shaders..."
xcrun -sdk macosx metal -O2 \
  "$SRC/Shaders/TileUpscaler.metal" \
  -o "$BUILD_DIR/default.metallib"

echo "▸ Compiling Swift sources..."
cp "$REPO_ROOT/scripts/visualtest.swift" "$BUILD_DIR/main.swift"
swiftc -O \
  "$SRC/Engine/CoreMLUpscaler.swift" \
  "$SRC/Engine/MPSUpscaler.swift" \
  "$SRC/Engine/UpscalerEngine.swift" \
  "$SRC/Error/UpscalerError.swift" \
  "$SRC/Tiling/TileProcessor.swift" \
  "$BUILD_DIR/main.swift" \
  -framework Metal \
  -framework MetalPerformanceShaders \
  -framework CoreML \
  -framework Accelerate \
  -framework CoreGraphics \
  -framework ImageIO \
  -target arm64-apple-macos13.5 \
  -o "$BUILD_DIR/visualtest"

echo "▸ Copying resources..."
cp -Rf "$SRC/Resources/realesrgan_4x.mlmodelc" "$BUILD_DIR/"

echo "▸ Running..."
echo ""
"$BUILD_DIR/visualtest" "$INPUT" "$OUTPUT"
