#include <metal_stdlib>
using namespace metal;

// Shared param structs used by both kernels and Swift dispatch code.
struct ConvertParams {
    uint width;
    uint height;
};

// Individual uint fields (not uint2) to guarantee identical memory layout with Swift's UInt32 struct.
struct AccumParams {
    uint outputOriginX;
    uint outputOriginY;
    uint innerOriginInTileX;
    uint innerOriginInTileY;
    uint innerSizeW;
    uint innerSizeH;
    // Overlap widths in upscaled-output pixels; 0 if this tile is at the corresponding edge.
    uint leftOverlap;
    uint rightOverlap;
    uint topOverlap;
    uint bottomOverlap;
};

// Feather weight for a position within the full write region (left_ovl + inner + right_ovl).
// Returns 1.0 in the inner area, falling linearly to ~0 at the seam edge of each overlap zone.
static float featherWeight(uint2 localPos, constant AccumParams& p) {
    float wx = 1.0f;
    float wy = 1.0f;

    if (p.leftOverlap > 0) {
        int leftDist = int(localPos.x) - int(p.leftOverlap);
        if (leftDist < 0)
            wx = min(wx, float(int(localPos.x) + 1) / float(p.leftOverlap + 1));
    }
    if (p.rightOverlap > 0) {
        int rightDist = int(p.innerSizeW + p.rightOverlap) - 1 - int(localPos.x);
        if (rightDist < int(p.rightOverlap))
            wx = min(wx, float(rightDist + 1) / float(p.rightOverlap + 1));
    }
    if (p.topOverlap > 0) {
        int topDist = int(localPos.y) - int(p.topOverlap);
        if (topDist < 0)
            wy = min(wy, float(int(localPos.y) + 1) / float(p.topOverlap + 1));
    }
    if (p.bottomOverlap > 0) {
        int bottomDist = int(p.innerSizeH + p.bottomOverlap) - 1 - int(localPos.y);
        if (bottomDist < int(p.bottomOverlap))
            wy = min(wy, float(bottomDist + 1) / float(p.bottomOverlap + 1));
    }

    return wx * wy;
}

// MARK: - Kernel 1: BGRA texture → planar float16 buffer
// Metal always exposes textures to shaders as RGBA regardless of bgra8Unorm storage order.
// So px.x=R, px.y=G, px.z=B, px.w=A. Model expects [1,3,H,W] with ch0=R, ch1=G, ch2=B.

kernel void bgra_to_planar_f16(
    texture2d<half, access::read> inTex [[texture(0)]],
    device half* outBuf               [[buffer(0)]],
    constant ConvertParams& params     [[buffer(1)]],
    uint2 gid                          [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) return;

    half4 px = inTex.read(gid);   // Metal presents bgra8Unorm as RGBA: .x=R, .y=G, .z=B
    uint planeStride = params.width * params.height;
    uint idx = gid.y * params.width + gid.x;

    outBuf[0 * planeStride + idx] = px.x;  // R → channel 0
    outBuf[1 * planeStride + idx] = px.y;  // G → channel 1
    outBuf[2 * planeStride + idx] = px.z;  // B → channel 2
}

// MARK: - Kernel 2: Planar float16 buffer → BGRA texture
// Model output: ch0=R, ch1=G, ch2=B. Metal write to bgra8Unorm: .x goes to R slot, .y→G, .z→B.

kernel void planar_f16_to_bgra(
    device const half* inBuf          [[buffer(0)]],
    texture2d<half, access::write> outTex [[texture(0)]],
    constant ConvertParams& params     [[buffer(1)]],
    uint2 gid                          [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint planeStride = params.width * params.height;
    uint idx = gid.y * params.width + gid.x;

    half r = clamp(inBuf[0 * planeStride + idx], 0.0h, 1.0h);  // channel 0 = Red
    half g = clamp(inBuf[1 * planeStride + idx], 0.0h, 1.0h);  // channel 1 = Green
    half b = clamp(inBuf[2 * planeStride + idx], 0.0h, 1.0h);  // channel 2 = Blue

    outTex.write(half4(r, g, b, 1.0h), gid);  // .x=R→R slot, .y=G→G slot, .z=B→B slot
}

// MARK: - Kernel 3: Accumulate weighted tile contribution

// Dispatched once per tile, over a grid covering the tile's FULL upscaled extent
// (inner size + overlap zones on each side that have neighbours).
// localPos runs over [0, leftOverlap+innerSize.x+rightOverlap) × [0, topOverlap+innerSize.y+bottomOverlap).
kernel void tile_accumulate(
    texture2d<half, access::read>        upscaledTile [[texture(0)]],
    texture2d<float, access::read_write> accumColor   [[texture(1)]],
    texture2d<float, access::read_write> accumWeight  [[texture(2)]],
    constant AccumParams& params                       [[buffer(0)]],
    uint2 gid                                          [[thread_position_in_grid]])
{
    uint writeW = params.innerSizeW + params.leftOverlap + params.rightOverlap;
    uint writeH = params.innerSizeH + params.topOverlap  + params.bottomOverlap;
    if (gid.x >= writeW || gid.y >= writeH) return;

    // Position in output texture (outputOrigin is inner-region start; extend into overlap zones).
    int outX = int(params.outputOriginX) - int(params.leftOverlap) + int(gid.x);
    int outY = int(params.outputOriginY) - int(params.topOverlap)  + int(gid.y);
    if (outX < 0 || outY < 0) return;
    uint2 outPos = uint2(outX, outY);

    // Position in upscaled tile texture (inner content starts at innerOriginInTile).
    int tileX = int(params.innerOriginInTileX) - int(params.leftOverlap) + int(gid.x);
    int tileY = int(params.innerOriginInTileY) - int(params.topOverlap)  + int(gid.y);
    if (tileX < 0 || tileY < 0 ||
        uint(tileX) >= upscaledTile.get_width() ||
        uint(tileY) >= upscaledTile.get_height()) return;

    float w = featherWeight(gid, params);
    half4 color = upscaledTile.read(uint2(tileX, tileY));

    float4 existingColor  = accumColor.read(outPos);
    float  existingWeight = accumWeight.read(outPos).r;

    accumColor.write(existingColor + float4(color) * w, outPos);
    accumWeight.write(float4(existingWeight + w, 0, 0, 0), outPos);
}

// MARK: - Kernel 4: Normalize accumulation → final BGRA output

kernel void tile_normalize(
    texture2d<float, access::read>   accumColor  [[texture(0)]],
    texture2d<float, access::read>   accumWeight [[texture(1)]],
    texture2d<half,  access::write>  outTex      [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 color  = accumColor.read(gid);
    float  weight = accumWeight.read(gid).r;

    half4 final = half4(color / max(weight, 1e-6f));
    final = clamp(final, 0.0h, 1.0h);
    final.w = 1.0h;
    outTex.write(final, gid);
}
