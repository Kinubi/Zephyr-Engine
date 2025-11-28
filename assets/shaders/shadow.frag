#version 450

// Cube shadow map fragment shader - writes linear depth

layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) flat in uint lightIndex;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    uint numActiveLights;
    uint _padding[3];
} push;

// Shadow light data from SSBO
struct ShadowLightGPU {
    vec4 lightPos;      // xyz = position, w = far plane
    float shadowBias;
    uint shadowEnabled;
    uint lightIndex;
    float _padding;
    mat4 faceViewProjs[6];
};

layout(set = 0, binding = 0) readonly buffer ShadowDataSSBO {
    uint numShadowLights;
    uint maxShadowLights;

    ShadowLightGPU lights[8];
} shadowData;

void main() {
    // Get light position and far plane from SSBO
    vec3 lightPos = shadowData.lights[lightIndex].lightPos.xyz;
    float farPlane = shadowData.lights[lightIndex].lightPos.w;
    
    // Calculate distance from light to fragment
    float lightDistance = length(fragWorldPos - lightPos);
    
    // Normalize to [0, 1] range using far plane
    float normalizedDepth = lightDistance / farPlane;
    
    // Write to depth buffer
    gl_FragDepth = normalizedDepth;
}
