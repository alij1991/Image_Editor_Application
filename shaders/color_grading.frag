#version 460 core
#include <flutter/runtime_effect.glsl>

// color_grading.frag
// Applies the composed color matrix plus a few non-matrix adjustments that
// need dedicated math: exposure (stops), temperature (Kelvin-ish), tint.
// The matrix is pre-multiplied on the Dart side in matrix_composer.dart
// so brightness/contrast/saturation/hue/channel-mixer cost zero extra math.

precision mediump float;

uniform vec2 u_size;
uniform sampler2D u_texture;

// Pre-composed 4x4 color matrix (row-major laid into columns here).
// Row 0..2 are rgb output coeffs; row 3 is alpha passthrough.
uniform mat4 u_colorMatrix;
// Offset vector added after the matrix multiplication (for brightness bias).
uniform vec4 u_colorOffset;

// Extra adjustments that are not linear in RGB.
uniform float u_exposure;    // stops, typical range -4..+4
uniform float u_temperature; // -1..+1, cool..warm
uniform float u_tint;        // -1..+1, green..magenta

out vec4 fragColor;

vec3 applyTemperatureTint(vec3 c, float temp, float tint) {
    // Simple bluish-yellow for temperature, green-magenta for tint.
    // Strength is capped by ~0.15 per unit to avoid clipping.
    c.r += temp * 0.15;
    c.b -= temp * 0.15;
    c.g += tint * 0.15;
    return c;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec4 src = texture(u_texture, uv);

    // Exposure: multiply linear light. We approximate gamma=2.2 by squaring.
    vec3 linear = pow(max(src.rgb, 0.0), vec3(2.2));
    linear *= pow(2.0, u_exposure);
    vec3 srgb = pow(linear, vec3(1.0 / 2.2));

    // Matrix + offset (brightness/contrast/sat/hue/channel mixer).
    vec4 m = u_colorMatrix * vec4(srgb, src.a) + u_colorOffset;

    // Temperature + tint.
    vec3 tinted = applyTemperatureTint(m.rgb, u_temperature, u_tint);

    fragColor = vec4(clamp(tinted, 0.0, 1.0), m.a);
}
