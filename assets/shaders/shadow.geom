#version 450

// Geometry shader for single-pass cube shadow map rendering
// Uses 6 invocations (one per cube face) - lights handled via instancing
// Each invocation outputs to layer = face * MAX_LIGHTS + lightIdx (from instance)

layout(triangles, invocations = 6) in;  // 6 faces
layout(triangle_strip, max_vertices = 3) out;

// Input from vertex shader
layout(location = 0) in vec3 inWorldPos[];
layout(location = 1) flat in uint inLightIndex[];  // From instance ID in vertex shader

// Output to fragment shader
layout(location = 0) out vec3 fragWorldPos;
layout(location = 1) flat out uint outLightIndex;

// Push constant
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
    // gl_InvocationID = which face (0-5)
    // inLightIndex = which light (from vertex shader via instancing)
    uint faceIdx = uint(gl_InvocationID);
    uint lightIdx = inLightIndex[0];  // Same for all vertices in the primitive
    
    // Skip if this light is not active
    if (lightIdx >= shadowData.numShadowLights) {
        return;
    }
    
    // Get view-projection for this face/light
    mat4 viewProj = shadowData.lights[lightIdx].faceViewProjs[faceIdx];
    
    // Output layer = face * MAX_LIGHTS + light
    gl_Layer = int(faceIdx * shadowData.maxShadowLights + lightIdx);
    
    // Emit the triangle
    for (int v = 0; v < 3; v++) {
        fragWorldPos = inWorldPos[v];
        outLightIndex = lightIdx;
        gl_Position = viewProj * vec4(inWorldPos[v], 1.0);
        EmitVertex();
    }
    EndPrimitive();
}
