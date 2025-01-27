#version 450

layout (location = 0) out vec4 outColor;

layout(location = 1) in vec3 color;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec3 normal;
layout(location = 4) in vec3 positionWorld;

struct PointLight {
    vec4 position;
    vec4 color;
};

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientColor;
    PointLight pointLights[16];
    int numPointLights;
} ubo;

layout(push_constant) uniform Push {
    mat4 projectionView;
    mat4 normalMatrix;
} push;

void main() {
    vec3 diffuseLight = ubo.ambientColor.xyz * ubo.ambientColor.w;
    vec3 surfaceNormal = normalize(push.normalMatrix * vec4(normal, 1.0)).xyz;

    for (int i = 0; i < ubo.numPointLights; i++) {
        PointLight light = ubo.pointLights[i];
        vec3 directionToLight = light.position.xyz - positionWorld;
        float attenuation = 1.0 / dot(directionToLight, directionToLight); // distance squared  
        float cosAngIncidence = max(dot(surfaceNormal, normalize(directionToLight)), 0);
        vec3 lightColor = light.color.xyz * light.color.w * attenuation;

        diffuseLight += lightColor * cosAngIncidence;
    }

    outColor = vec4(diffuseLight * color, 1.0);
}