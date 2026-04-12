#version 460 core
#include <flutter/runtime_effect.glsl>

// lut3d.frag — 33^3 3D LUT via sampler-emulated tiled 2D texture.
// The LUT asset is a 1089 x 33 PNG: 33 horizontal tiles of 33x33 each.
// u_lutTileSize = 33.0 (float for GLSL convenience).
precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform sampler2D u_lut;
uniform float u_lutTileSize; // 33
uniform float u_intensity;   // 0..1

out vec4 fragColor;

vec3 sampleLut(vec3 uvw, float tileSize) {
    float slice = uvw.z * (tileSize - 1.0);
    float sliceLo = floor(slice);
    float sliceHi = min(sliceLo + 1.0, tileSize - 1.0);
    float sliceMix = slice - sliceLo;
    float invWidth = 1.0 / (tileSize * tileSize);
    float invHeight = 1.0 / tileSize;
    vec2 uvLo;
    uvLo.x = (sliceLo * tileSize + uvw.x * (tileSize - 1.0) + 0.5) * invWidth;
    uvLo.y = (uvw.y * (tileSize - 1.0) + 0.5) * invHeight;
    vec2 uvHi = vec2((sliceHi * tileSize + uvw.x * (tileSize - 1.0) + 0.5) * invWidth, uvLo.y);
    vec3 colLo = texture(u_lut, uvLo).rgb;
    vec3 colHi = texture(u_lut, uvHi).rgb;
    return mix(colLo, colHi, sliceMix);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    vec3 graded = sampleLut(clamp(src.rgb, 0.0, 1.0), u_lutTileSize);
    fragColor = vec4(mix(src.rgb, graded, u_intensity), src.a);
}
