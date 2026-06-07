#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.benchmark_build"
SRC="$REPO_ROOT/AIUpscaler/AIUpscaler"

# Check for model files before doing any compilation work
if [ ! -d "$SRC/Resources/realesrgan_2x.mlmodelc" ]; then
  echo "Error: $SRC/Resources/realesrgan_2x.mlmodelc not found."
  echo "Run scripts/convert_realesrgan.py to generate it."
  exit 1
fi
if [ ! -d "$SRC/Resources/realesrgan_4x.mlmodelc" ]; then
  echo "Error: $SRC/Resources/realesrgan_4x.mlmodelc not found."
  echo "Run scripts/convert_realesrgan.py to generate it."
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "▸ Compiling Metal shaders..."
xcrun -sdk macosx metal -O2 \
  "$SRC/Shaders/TileUpscaler.metal" \
  -o "$BUILD_DIR/default.metallib"

echo "▸ Compiling Swift sources..."
# benchmark.swift must be named main.swift so swiftc treats it as the entry point
cp "$REPO_ROOT/scripts/benchmark.swift" "$BUILD_DIR/main.swift"
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
  -target arm64-apple-macos13.5 \
  -o "$BUILD_DIR/benchmark"

echo "▸ Copying resources..."
cp -R "$SRC/Resources/realesrgan_2x.mlmodelc" "$BUILD_DIR/"
cp -R "$SRC/Resources/realesrgan_4x.mlmodelc" "$BUILD_DIR/"

echo "▸ Running benchmark..."
echo ""
"$BUILD_DIR/benchmark"
