#version 440
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 uv;

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

void main() {
    uv = qt_MultiTexCoord0;
    gl_Position = ubuf.qt_Matrix * qt_Vertex;
}
