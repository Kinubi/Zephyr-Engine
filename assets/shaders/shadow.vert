#version 450
#extension GL_EXT_multiview : enable

// Cube shadow map vertex shader - multiview renders all lights simultaneously
// gl_ViewIndex = which light (0 to N-1)
// push.faceIndex = which cube face (0 to 5)

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec3 normal;

layout(location = 0) out vec3 fragWorldPos;
layout(location = 1) flat out uint outLightIndex;

// Push constant contains model matrix and face index
layout(push_constant) uniform Push {
    mat4 modelMatrix;
    uint faceIndex;
    uint _padding[3];
} push;

// Shadow light data from SSBO
struct ShadowLightGPU {
    vec4 lightPos;      // xyz = position, w = far plane
    float shadowBias;
    uint shadowEnabled;
    uint lightIndex;
    float _padding;
    mat4 faceViewProjs[6];  // 6 face view*projection matrices
};

layout(set = 0, binding = 0) readonly buffer ShadowDataSSBO {
    uint numShadowLights;
    uint maxShadowLights;
    uint _padding[2];
    ShadowLightGPU lights[8];  // MAX_SHADOW_LIGHTS
} shadowData;

void main() {
    // gl_ViewIndex tells us which light we're rendering for
    uint lightIdx = gl_ViewIndex;
    
    // Get the view*proj matrix for this light and face
    mat4 viewProj = shadowData.lights[lightIdx].faceViewProjs[push.faceIndex];
    
    vec4 worldPos = push.modelMatrix * vec4(position, 1.0);
    fragWorldPos = worldPos.xyz;
    outLightIndex = lightIdx;
    
    gl_Position = viewProj * worldPos;
}
