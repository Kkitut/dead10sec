#version 450

layout(push_constant) uniform Push {
    vec4 color;
    vec2 screen;
    vec2 pos;
    vec2 size;
    float rot;
    float scale;
    vec2 uv0;
    vec2 uv1;
} push;

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;

layout(location = 0) out vec2 fragUV;

void main() {

    vec2 p = (inPos - 0.5) * push.size * push.scale;

    float c = cos(push.rot);
    float s = sin(push.rot);

    mat2 rotMat = mat2(
        c, -s,
        s,  c
    );

    p = rotMat * p;

    vec2 world = push.pos + 0.5 * push.size * push.scale + p;

    vec2 ndc;
    ndc.x = (world.x / push.screen.x) * 2.0 - 1.0;
    ndc.y = (world.y / push.screen.y) * 2.0 - 1.0;

    gl_Position = vec4(ndc, 0.0, 1.0);
    fragUV = mix(push.uv0, push.uv1, inUV);
}