# Fix: Remove NeedsFullBuffer — Clip Content Cropping

**Date:** 2026-06-06
**Status:** Approved

## Problem

When a 720p clip is placed in a 4K timeline and the AI Upscaler effect is applied, the clip content is cropped — the center appears but the right, left, top, and bottom edges are lost.

**Root cause:** `kFxPropertyKey_NeedsFullBuffer = true` causes FCP to provide the full 4K timeline buffer as the source image, with the 720p clip embedded at its position within the frame (typically centered). `destinationImageRect` multiplies these 4K bounds by the scale factor, returning 8K/16K. FCP clamps the destination tile to 4K. During render, the plugin upscales the full 4K buffer → 8K result, then `blit.copy` copies only the top-left 3840×2160 of that 8K result — which corresponds to the top-left quadrant of the upscaled content. The 720p clip content, previously centered in the 4K source, is partially outside this quadrant, so its edges are cropped.

## Goal

When the user applies AI Upscaler to a 720p clip in a 4K timeline, the plugin upscales the clip content by 2× or 4× (to 1440p or 2880p). FCP then composites the upscaled output into the timeline. No clip content is lost.

## Design

### Change

Remove `kFxPropertyKey_NeedsFullBuffer` from the properties dictionary in `UpscalerEffect.properties()`.

**File:** `AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift`, method `properties(_:)`.

```swift
// Before
func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
    properties?.pointee = [
        kFxPropertyKey_NeedsFullBuffer:           NSNumber(booleanLiteral: true),
        kFxPropertyKey_MayRemapTime:              NSNumber(booleanLiteral: false),
        kFxPropertyKey_ChangesOutputSize:         NSNumber(booleanLiteral: true),
        kFxPropertyKey_VariesWhenParamsAreStatic: NSNumber(booleanLiteral: false),
    ] as NSDictionary
}

// After
func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
    properties?.pointee = [
        kFxPropertyKey_MayRemapTime:              NSNumber(booleanLiteral: false),
        kFxPropertyKey_ChangesOutputSize:         NSNumber(booleanLiteral: true),
        kFxPropertyKey_VariesWhenParamsAreStatic: NSNumber(booleanLiteral: false),
    ] as NSDictionary
}
```

### Why this works

With `NeedsFullBuffer` absent (defaults to false), FCP provides the source image at the clip's native resolution and coordinate space. For a 720p clip:

- `sourceImages[0].imagePixelBounds` → `{0, 0, 1280, 720}`
- `destinationImageRect` returns `{0, 0, 2560, 1440}` (2×) or `{0, 0, 5120, 2880}` (4×)
- FCP creates a destination tile matching the declared output size
- `sourceTileRect` returns full source bounds — FCP provides the full 720p clip
- `TileProcessor` receives a 1280×720 texture, tiles it into 512×512 chunks, upscales each
- `blit.copy` copies the 1440p/2880p result to a same-sized destination — no cropping

### No other changes required

- `sourceTileRect` already returns the full source bounds unconditionally — correct for a full-frame upscaler
- `destinationImageRect` already multiplies source bounds by scale factor — correct once source is at native resolution
- `TileProcessor` is agnostic to input size — works on any resolution via 512×512 tiling
- `kFxPropertyKey_ChangesOutputSize = true` remains — the output is larger than the input

### Known trade-off

Without `NeedsFullBuffer`, FCP may tile the destination and call `renderDestinationImage` multiple times per frame. Each call requests the full source (via `sourceTileRect`), so the full-source upscale runs once per destination tile. For v1 this is acceptable. A future optimization would cache the upscaled result within a single frame render.

## Files Changed

| File | Change |
|------|--------|
| `AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift` | Remove `kFxPropertyKey_NeedsFullBuffer` line from `properties(_:)` |

## Testing

1. Build and install the plugin (see CLAUDE.md install sequence)
2. Create a 4K timeline in FCP
3. Add a 720p clip
4. Apply AI Upscaler effect with Scale = 2×, Engine = Fast
5. Verify: full clip content visible, no edge cropping
6. Repeat with Scale = 4×
7. Repeat with a clip that has content at all four edges (confirms no cropping)
8. Verify the existing test suite still passes: `xcodebuild test -scheme AIUpscalerTests`
