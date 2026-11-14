#version 440
// Orthographic globe. The texture is an equirectangular mask:
//   R = land, G = country borders, B = graticule
// Colours come from the theme as uniforms. Output is premultiplied alpha.

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float yaw;
    float pitch;
    float radius;
    vec2  center;
    vec2  resolution;
    vec4  oceanColor;
    vec4  landColor;
    vec4  borderColor;
    vec4  gratColor;
    vec4  atmoColor;
    vec4  strength;     // x = border, y = graticule, z = atmosphere
} ubuf;

layout(binding = 1) uniform sampler2D earth;

const float PI = 3.14159265359;
const float TEX_W = 4096.0;

void main() {
    vec2  d   = uv * ubuf.resolution - ubuf.center;
    vec2  nxy = vec2(d.x, -d.y) / ubuf.radius;
    float r   = length(nxy);
    float px  = 1.0 / ubuf.radius;            // one screen pixel in sphere units

    // Halo outside the limb.
    if (r >= 1.0 + px) {
        float g = exp(-(r - 1.0) * 16.0) * ubuf.strength.z * 0.55;
        g *= 1.0 - smoothstep(1.0, 1.25, r);
        fragColor = vec4(ubuf.atmoColor.rgb * g, g) * ubuf.qt_Opacity;
        return;
    }

    float nz = sqrt(max(1.0 - r * r, 0.0));
    vec3  cam = vec3(nxy, nz);

    // Inverse of GlobeProjection.rotate(): un-pitch, then un-yaw.
    float cp = cos(ubuf.pitch), sp = sin(ubuf.pitch);
    vec3 p1 = vec3(cam.x,
                   cp * cam.y + sp * cam.z,
                  -sp * cam.y + cp * cam.z);
    float cy = cos(ubuf.yaw), sy = sin(ubuf.yaw);
    vec3 w = vec3(cy * p1.x - sy * p1.z,
                  p1.y,
                  sy * p1.x + cy * p1.z);

    float lat = asin(clamp(w.y, -1.0, 1.0));
    float lng = atan(w.x, w.z);
    vec2  tuv = vec2((lng + PI) / (2.0 * PI), 0.5 - lat / PI);

    // Analytic mip level (derivatives jump at the lng seam).
    float footprint = px / max(nz, 0.12);
    float texels = (TEX_W / (2.0 * PI)) * footprint / max(cos(lat), 0.15);
    float lod = max(log2(max(texels, 1.0)), 0.0);
    vec3 m = textureLod(earth, tuv, lod).rgb;

    // Surface colour.
    vec3 col = mix(ubuf.oceanColor.rgb, ubuf.landColor.rgb, m.r);
    col = mix(col, ubuf.gratColor.rgb,   m.b * ubuf.strength.y * (1.0 - m.r * 0.6));
    col = mix(col, ubuf.borderColor.rgb, m.g * ubuf.strength.x * m.r);

    // Light from upper left of the viewer, plus a soft rim.
    vec3  L = normalize(vec3(-0.35, 0.45, 0.82));
    float lit = 0.45 + 0.55 * clamp(dot(cam, L), 0.0, 1.0);
    col *= lit;
    float rim = pow(1.0 - nz, 3.0);
    col += ubuf.atmoColor.rgb * rim * 0.35 * ubuf.strength.z;

    // Anti-aliased limb.
    float a = clamp((1.0 - r) / px, 0.0, 1.0);
    fragColor = vec4(col * a, a) * ubuf.qt_Opacity;
}
