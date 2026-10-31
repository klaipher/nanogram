#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4 primaryRow0;
    float4 primaryRow1;
    float4 primaryRow2;
    float4 primaryOffset;
    float4 primarySource;

    float4 secondaryRow0;
    float4 secondaryRow1;
    float4 secondaryRow2;
    float4 secondaryOffset;
    float4 secondarySource;

    float4 blend;
    float4 decoration;
};

static float2 sourceCoordinate(float2 outputCoordinate, float4 source) {
    uint rotation = uint(source.z + 0.5);
    bool mirrored = source.w > 0.5;

    float2 orientedSize = (rotation == 1 || rotation == 3) ? source.yx : source.xy;
    float shortestSide = min(orientedSize.x, orientedSize.y);
    float2 coordinate = outputCoordinate;
    coordinate.x = 0.5 + (coordinate.x - 0.5) * shortestSide / orientedSize.x;
    coordinate.y = 0.5 + (coordinate.y - 0.5) * shortestSide / orientedSize.y;

    if (mirrored) {
        coordinate.x = 1.0 - coordinate.x;
    }

    switch (rotation) {
    case 1:
        return float2(coordinate.y, 1.0 - coordinate.x);
    case 2:
        return 1.0 - coordinate;
    case 3:
        return float2(1.0 - coordinate.y, coordinate.x);
    default:
        return coordinate;
    }
}

static float3 readRgb(
    texture2d<float, access::sample> yTexture,
    texture2d<float, access::sample> cbcrTexture,
    sampler textureSampler,
    float2 coordinate,
    float4 row0,
    float4 row1,
    float4 row2,
    float4 offset
) {
    float y = yTexture.sample(textureSampler, coordinate).r;
    float2 cbcr = cbcrTexture.sample(textureSampler, coordinate).rg;
    float3 yuv = float3(y, cbcr) + offset.xyz;
    return saturate(float3(
        dot(row0.xyz, yuv),
        dot(row1.xyz, yuv),
        dot(row2.xyz, yuv)
    ));
}

// One bilinear tap per output pixel is a 2x2 box only up to a 2x downscale; past that
// (rear 1080 crop = 2.25x, front 1440 fallback = 3x) it skips source texels and aliases.
// Above 2x, luma is averaged over 4 taps at +-0.25 output pixel (each through
// sourceCoordinate, so rotation and mirroring hold); chroma keeps its single centre tap,
// since its plane is half resolution and needs no supersampling at these ratios.
// At 2x or less (front 960 crop, VGA, Lanczos-prescaled input, multi-cam 720p) this is
// exactly readRgb at the centre coordinate.
static float3 readRgbSupersampled(
    texture2d<float, access::sample> yTexture,
    texture2d<float, access::sample> cbcrTexture,
    sampler textureSampler,
    float2 outputCoordinate,
    float2 outputSize,
    float4 source,
    float4 row0,
    float4 row1,
    float4 row2,
    float4 offset
) {
    float2 coordinate = sourceCoordinate(outputCoordinate, source);
    if (min(source.x, source.y) <= 2.0 * min(outputSize.x, outputSize.y)) {
        return readRgb(yTexture, cbcrTexture, textureSampler, coordinate, row0, row1, row2, offset);
    }

    float2 d = 0.25 / outputSize;
    float y = 0.25 * (
        yTexture.sample(textureSampler, sourceCoordinate(outputCoordinate + float2(-d.x, -d.y), source)).r +
        yTexture.sample(textureSampler, sourceCoordinate(outputCoordinate + float2(d.x, -d.y), source)).r +
        yTexture.sample(textureSampler, sourceCoordinate(outputCoordinate + float2(-d.x, d.y), source)).r +
        yTexture.sample(textureSampler, sourceCoordinate(outputCoordinate + float2(d.x, d.y), source)).r
    );
    float2 cbcr = cbcrTexture.sample(textureSampler, coordinate).rg;
    float3 yuv = float3(y, cbcr) + offset.xyz;
    return saturate(float3(
        dot(row0.xyz, yuv),
        dot(row1.xyz, yuv),
        dot(row2.xyz, yuv)
    ));
}

static float3 readCompositeRgb(
    texture2d<float, access::sample> primaryY,
    texture2d<float, access::sample> primaryCbCr,
    texture2d<float, access::sample> secondaryY,
    texture2d<float, access::sample> secondaryCbCr,
    sampler textureSampler,
    float2 outputCoordinate,
    float2 supersampleOutputSize,
    constant FrameUniforms &uniforms
) {
    // supersampleOutputSize is (0, 0) for a single tap (the blur source); otherwise the
    // output size readRgbSupersampled gates on.
    float2 outputSize = supersampleOutputSize.x > 0.0 ? supersampleOutputSize : float2(1.0e9);
    float3 primaryRgb = readRgbSupersampled(
        primaryY,
        primaryCbCr,
        textureSampler,
        outputCoordinate,
        outputSize,
        uniforms.primarySource,
        uniforms.primaryRow0,
        uniforms.primaryRow1,
        uniforms.primaryRow2,
        uniforms.primaryOffset
    );

    if (uniforms.blend.y > 0.5 && uniforms.blend.x > 0.0) {
        float3 secondaryRgb = readRgbSupersampled(
            secondaryY,
            secondaryCbCr,
            textureSampler,
            outputCoordinate,
            outputSize,
            uniforms.secondarySource,
            uniforms.secondaryRow0,
            uniforms.secondaryRow1,
            uniforms.secondaryRow2,
            uniforms.secondaryOffset
        );
        return mix(primaryRgb, secondaryRgb, saturate(uniforms.blend.x));
    }
    return primaryRgb;
}

static float3 sourceOver(float4 overlay, float3 background) {
    return saturate(overlay.rgb + background * (1.0 - overlay.a));
}

kernel void convertNV12(
    texture2d<float, access::sample> primaryY [[texture(0)]],
    texture2d<float, access::sample> primaryCbCr [[texture(1)]],
    texture2d<float, access::sample> secondaryY [[texture(2)]],
    texture2d<float, access::sample> secondaryCbCr [[texture(3)]],
    texture2d<float, access::write> output [[texture(4)]],
    constant FrameUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    constexpr sampler textureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 outputSize = float2(output.get_width(), output.get_height());
    float2 pixelCoordinate = float2(gid) + 0.5;
    float2 outputCoordinate = pixelCoordinate / outputSize;

    float3 primaryRgb = readRgbSupersampled(
        primaryY,
        primaryCbCr,
        textureSampler,
        outputCoordinate,
        outputSize,
        uniforms.primarySource,
        uniforms.primaryRow0,
        uniforms.primaryRow1,
        uniforms.primaryRow2,
        uniforms.primaryOffset
    );

    float3 result = primaryRgb;
    if (uniforms.blend.y > 0.5 && uniforms.blend.x > 0.0) {
        float3 secondaryRgb = readRgbSupersampled(
            secondaryY,
            secondaryCbCr,
            textureSampler,
            outputCoordinate,
            outputSize,
            uniforms.secondarySource,
            uniforms.secondaryRow0,
            uniforms.secondaryRow1,
            uniforms.secondaryRow2,
            uniforms.secondaryOffset
        );
        result = mix(primaryRgb, secondaryRgb, saturate(uniforms.blend.x));
    }

    float radius = min(outputSize.x, outputSize.y) * 0.5 + 2.0;
    float circleMask = 1.0 - smoothstep(radius - 0.5, radius + 0.5, distance(pixelCoordinate, outputSize * 0.5));
    result = mix(float3(1.0), result, circleMask);

    output.write(float4(result, 1.0), gid);
}

kernel void downsampleNV12(
    texture2d<float, access::sample> primaryY [[texture(0)]],
    texture2d<float, access::sample> primaryCbCr [[texture(1)]],
    texture2d<float, access::sample> secondaryY [[texture(2)]],
    texture2d<float, access::sample> secondaryCbCr [[texture(3)]],
    texture2d<float, access::write> output [[texture(4)]],
    constant FrameUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    constexpr sampler textureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 outputCoordinate = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 result = readCompositeRgb(
        primaryY,
        primaryCbCr,
        secondaryY,
        secondaryCbCr,
        textureSampler,
        outputCoordinate,
        float2(0.0),
        uniforms
    );
    output.write(float4(result, 1.0), gid);
}

kernel void compositeRoundVideo(
    texture2d<float, access::sample> primaryY [[texture(0)]],
    texture2d<float, access::sample> primaryCbCr [[texture(1)]],
    texture2d<float, access::sample> secondaryY [[texture(2)]],
    texture2d<float, access::sample> secondaryCbCr [[texture(3)]],
    texture2d<float, access::write> output [[texture(4)]],
    texture2d<float, access::sample> blurred [[texture(5)]],
    texture2d<float, access::sample> watermark [[texture(6)]],
    texture2d<float, access::sample> planeAtlas [[texture(7)]],
    constant FrameUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    constexpr sampler textureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 outputSize = float2(output.get_width(), output.get_height());
    float2 pixelCoordinate = float2(gid) + 0.5;
    float2 outputCoordinate = pixelCoordinate / outputSize;

    float3 sharp = readCompositeRgb(
        primaryY,
        primaryCbCr,
        secondaryY,
        secondaryCbCr,
        textureSampler,
        outputCoordinate,
        outputSize,
        uniforms
    );
    float3 darkenedBlur = blurred.sample(textureSampler, outputCoordinate).rgb * 0.25;
    float circleMask = 1.0 - smoothstep(201.5, 202.5, distance(pixelCoordinate, outputSize * 0.5));
    float3 result = mix(darkenedBlur, sharp, circleMask);

    constexpr float watermarkSize = 100.0;
    float2 watermarkOrigin = outputSize - float2(watermarkSize);
    if (pixelCoordinate.x >= watermarkOrigin.x && pixelCoordinate.y >= watermarkOrigin.y) {
        float2 watermarkCoordinate = (pixelCoordinate - watermarkOrigin) / watermarkSize;
        result = sourceOver(watermark.sample(textureSampler, watermarkCoordinate), result);
    }

    constexpr float planeSize = 68.0;
    float2 planeOrigin = float2(0.0, outputSize.y - planeSize);
    if (pixelCoordinate.x < planeSize && pixelCoordinate.y >= planeOrigin.y) {
        uint frameIndex = uint(uniforms.decoration.x + 0.5);
        uint columns = max(1u, uint(uniforms.decoration.y + 0.5));
        uint column = frameIndex % columns;
        uint row = frameIndex / columns;
        float2 localCoordinate = pixelCoordinate - planeOrigin;
        float2 atlasPixel = float2(float(column), float(row)) * planeSize + localCoordinate;
        float2 atlasCoordinate = atlasPixel / float2(planeAtlas.get_width(), planeAtlas.get_height());
        result = sourceOver(planeAtlas.sample(textureSampler, atlasCoordinate), result);
    }

    output.write(float4(result, 1.0), gid);
}
