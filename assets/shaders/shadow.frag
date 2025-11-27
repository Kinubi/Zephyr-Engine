#version 450

// Cube shadow map fragment shader - writes linear depth

layout(location = 0) in vec3 fragWorldPos;

layout(push_constant) uniform Push {
    mat4 modelMatrix;
    vec4 lightPos;      // xyz = light position, w = far plane
    mat4 viewProj;      // view * projection for current face
} push;

void main() {
    // Calculate distance from light to fragment
    float lightDistance = length(fragWorldPos - push.lightPos.xyz);
    
    // Normalize to [0, 1] range using far plane
    float normalizedDepth = lightDistance / push.lightPos.w;
    
    // Write to depth buffer
    gl_FragDepth = normalizedDepth;
}
