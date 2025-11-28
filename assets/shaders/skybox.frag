#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 outColor;

// Global UBO for camera matrices
layout(set = 0, binding = 0) uniform GlobalUBO {
    mat4 projection;
    mat4 view;
    mat4 projectionView;
    vec3 cameraPosition;
    float time;
} ubo;

// Skybox settings via push constants
layout(push_constant) uniform SkyboxPushConstants {
    float rotation;      // Y-axis rotation in radians
    float exposure;      // Brightness multiplier
    vec2 _pad0;
    vec4 tint;          // Color tint (xyz) + padding
    int sourceType;     // 0 = equirectangular, 1 = cubemap, 2 = procedural
    int _pad1[3];
    vec4 sunDirection;  // xyz = direction
    vec4 groundColor;   // xyz = color
    vec4 horizonColor;  // xyz = color
    vec4 zenithColor;   // xyz = color
} skybox;

// Environment map (equirectangular HDR)
layout(set = 0, binding = 1) uniform sampler2D envMap;

const float PI = 3.14159265359;

// Convert screen UV to world direction
vec3 uvToWorldDir(vec2 uv) {
    // Convert UV to NDC
    vec2 ndc = uv * 2.0 - 1.0;
    
    // Create clip space position at far plane
    vec4 clipPos = vec4(ndc, 1.0, 1.0);
    
    // Transform to view space
    mat4 invProj = inverse(ubo.projection);
    vec4 viewPos = invProj * clipPos;
    viewPos /= viewPos.w;
    
    // Transform to world space direction
    mat4 invView = inverse(ubo.view);
    vec3 worldDir = (invView * vec4(viewPos.xyz, 0.0)).xyz;
    
    return normalize(worldDir);
}

// Sample equirectangular environment map
vec3 sampleEquirectangular(vec3 dir) {
    // Apply rotation around Y axis
    float cosR = cos(skybox.rotation);
    float sinR = sin(skybox.rotation);
    vec3 rotatedDir = vec3(
        dir.x * cosR - dir.z * sinR,
        dir.y,
        dir.x * sinR + dir.z * cosR
    );
    
    // Convert direction to equirectangular UV
    float phi = atan(rotatedDir.z, rotatedDir.x); // -PI to PI
    float theta = asin(clamp(rotatedDir.y, -1.0, 1.0)); // -PI/2 to PI/2
    
    vec2 envUV = vec2(
        (phi + PI) / (2.0 * PI),  // 0 to 1
        (theta + PI * 0.5) / PI   // 0 to 1
    );
    
    return texture(envMap, envUV).rgb;
}

// Procedural sky gradient
vec3 proceduralSky(vec3 dir) {
    float y = dir.y;
    
    // Ground to horizon to zenith gradient
    vec3 color;
    if (y < 0.0) {
        // Below horizon - ground color
        color = skybox.groundColor.xyz;
    } else {
        // Above horizon - blend from horizon to zenith
        float t = pow(y, 0.4); // Non-linear blend for more interesting gradient
        color = mix(skybox.horizonColor.xyz, skybox.zenithColor.xyz, t);
    }
    
    // Simple sun disc
    float sunDot = max(dot(dir, skybox.sunDirection.xyz), 0.0);
    float sunDisc = smoothstep(0.995, 0.999, sunDot);
    color += vec3(1.0, 0.9, 0.7) * sunDisc * 10.0;
    
    // Sun glow
    float sunGlow = pow(sunDot, 8.0);
    color += vec3(1.0, 0.7, 0.4) * sunGlow * 0.5;
    
    return color;
}

void main() {
    vec3 worldDir = uvToWorldDir(fragUV);
    vec3 color;
    
    if (skybox.sourceType == 2) {
        // Procedural sky
        color = proceduralSky(worldDir);
    } else {
        // Equirectangular HDR
        color = sampleEquirectangular(worldDir);
    }
    
    // Apply exposure and tint
    color *= skybox.exposure;
    color *= skybox.tint.xyz;
    
    outColor = vec4(color, 1.0);
}
