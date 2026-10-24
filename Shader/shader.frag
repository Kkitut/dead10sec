#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 outColor;

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

layout(binding = 0) uniform sampler2D texSampler;

void main() {
    vec2 uv = vec2(fragUV.x, 1.0 - fragUV.y);

    vec4 tex = texture(texSampler, uv);

    outColor = tex * push.color;
}