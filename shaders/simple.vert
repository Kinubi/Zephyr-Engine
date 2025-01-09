
#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;

layout(location = 1) out vec3 v_color;

layout(push_constant) uniform Push {
    mat4 transform;
    mat4 projection;
    mat4 view;
    vec3 color;
} push;

void main() {
    gl_Position = push.view * push.projection * push.transform * vec4(position, 1.0);
    v_color = color;
}
