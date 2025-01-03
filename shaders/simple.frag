#version 450

layout(location = 0) out vec4 fragColor;
layout (location  = 0) in vec2 fragOffset;


void main() {
    fragColor = vec4(fragOffset.x, fragOffset.y, fragOffset.x/fragOffset.y, 1.0);
}