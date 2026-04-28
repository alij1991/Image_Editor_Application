#version 460 core
#include <flutter/runtime_effect.glsl>

// vibrance.frag — smart saturation: boosts less-saturated colors more.
//
// Phase XVI.26 — skin-tone protect. Pre-XVI.26 the vibrance amount
// was uniform across the hue wheel, so a +1 vibrance slider made
// faces look neon-orange. The new math attenuates the boost inside
// the orange-red band (centre ≈ 25°, half-width ≈ 30°) by up to 50%
// at the band centre, fading via a cosine taper to full strength at
// the band edges. Mirrors `VibranceMath.applyRgb` in
// `lib/engine/color/vibrance_math.dart` — keep both in sync.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_vibrance; // -1..+1
out vec4 fragColor;

const float SKIN_HUE_CENTER = 25.0;
const float SKIN_HUE_HALF_WIDTH = 30.0;
const float SKIN_ATTENUATION_DEPTH = 0.5;

float skinMask(float hueDeg) {
    float dh = abs(hueDeg - SKIN_HUE_CENTER);
    if (dh > 180.0) dh = 360.0 - dh;
    if (dh >= SKIN_HUE_HALF_WIDTH) return 0.0;
    return cos(dh / SKIN_HUE_HALF_WIDTH * 1.5707963); // π/2
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);
    float maxC = max(src.r, max(src.g, src.b));
    float minC = min(src.r, min(src.g, src.b));
    float sat = maxC - minC;

    // Hue in [0, 360). Achromatic pixels (sat ≈ 0) have undefined
    // hue — return a sentinel that skinMask reads as "no skin
    // attenuation" (anything outside [SKIN_HUE_CENTER ± half-width]).
    float hueDeg = 720.0; // safe sentinel: skinMask returns 0
    if (sat > 1e-4) {
        float h;
        if (maxC == src.r) {
            h = mod((src.g - src.b) / sat, 6.0);
        } else if (maxC == src.g) {
            h = (src.b - src.r) / sat + 2.0;
        } else {
            h = (src.r - src.g) / sat + 4.0;
        }
        h *= 60.0;
        if (h < 0.0) h += 360.0;
        hueDeg = h;
    }
    float skin = skinMask(hueDeg);
    float effectiveVibrance = u_vibrance * (1.0 - SKIN_ATTENUATION_DEPTH * skin);

    // Vibrance boosts low-saturation pixels more, leaves saturated ones alone.
    // Clamp scale to [0, 2.5] to prevent inversion or extreme overshoot.
    float scale = clamp(1.0 + effectiveVibrance * 1.5 * (1.0 - sat), 0.0, 2.5);
    float lum = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 outColor = mix(vec3(lum), src.rgb, scale);
    fragColor = vec4(clamp(outColor, 0.0, 1.0), src.a);
}
