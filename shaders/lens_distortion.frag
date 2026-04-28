#version 460 core
#include <flutter/runtime_effect.glsl>

// lens_distortion.frag — radial Brown-Conrady distortion correction.
//
// XVI.46 — given the bundled EXIF lens profile's coefficients, we
// inverse-warp the source so the corrected output matches the way
// the world actually looked. The model is Lensfun's "ACM" form
// without tangential terms (which phone cameras almost never need
// at the magnitudes we care about):
//
//   src_r = out_r * (1 + k1 * r^2 + k2 * r^4)
//
// where r = distance from the principal point (image centre) in
// normalised [0, 0.5√2] units. Positive k1 = pincushion correction
// (push corners out), negative k1 = barrel correction (pull in).
// Phone cameras typically have a small negative k1 because their
// glass produces mild barrel distortion.
//
// At identity (k1 == 0 && k2 == 0) the math collapses to
// `src_uv = uv` and the shader is equivalent to a copy. The pass
// builder skips the pass entirely in that case so this branch is
// guarded; the shader still handles it correctly if invoked.
precision mediump float;
uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_k1;
uniform float u_k2;
out vec4 fragColor;
void main() {
    vec2 uv = FlutterFragCoord().xy / u_size;
    vec2 c = vec2(0.5, 0.5);
    vec2 d = uv - c;
    float r2 = dot(d, d);
    float factor = 1.0 + u_k1 * r2 + u_k2 * r2 * r2;
    vec2 src = c + d * factor;
    if (src.x < 0.0 || src.x > 1.0 || src.y < 0.0 || src.y > 1.0) {
        fragColor = vec4(0.0);
    } else {
        fragColor = texture(u_texture, src);
    }
}
