#version 460 core
#include <flutter/runtime_effect.glsl>

// curves.frag — master + per-channel tone curves via a 256x5 RGBA LUT.
// Row 0 = master (applied to each RGB channel), rows 1..3 = R/G/B,
// row 4 = luma (XVI.24, applied post-master+RGB on perceptual Y).
// The curve LUT is baked on the Dart side in
// engine/color/curve_lut_baker.dart from Bezier control points, so a
// single sampler lookup evaluates the curve.
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform sampler2D u_curveLut;
uniform float u_enabled; // 1.0 = apply, 0.0 = passthrough

out vec4 fragColor;

float sampleCurve(float v, float row) {
    // LUT is 256 wide, 5 tall (XVI.24: was 4, now 4 + luma row).
    // y-center for row i is (i + 0.5)/5.
    return texture(u_curveLut, vec2(clamp(v, 0.0, 1.0), (row + 0.5) / 5.0)).r;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    // Apply master first, then per-channel.
    float rm = sampleCurve(src.r, 0.0);
    float gm = sampleCurve(src.g, 0.0);
    float bm = sampleCurve(src.b, 0.0);

    float r = sampleCurve(rm, 1.0);
    float g = sampleCurve(gm, 2.0);
    float b = sampleCurve(bm, 3.0);

    // XVI.24: Luma curve. Apply on the perceptual Y of the post-
    // master+RGB result so chroma direction is preserved. An identity
    // luma row returns Ymapped == Y, so ratio == 1 and rgb stays
    // unchanged — zero perceptual cost when the user hasn't authored
    // a luma curve.
    vec3 rgbAfter = vec3(r, g, b);
    float Y = dot(rgbAfter, vec3(0.2126, 0.7152, 0.0722));
    float Ymapped = sampleCurve(Y, 4.0);
    float ratio = Ymapped / max(Y, 1e-4);
    vec3 finalRgb = clamp(rgbAfter * ratio, 0.0, 1.0);

    vec3 outColor = u_enabled > 0.5 ? finalRgb : src.rgb;
    fragColor = vec4(outColor, src.a);
}
