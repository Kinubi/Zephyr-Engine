#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout (location = 0) out vec4 outColor;

layout(location = 1) in vec3 color;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec3 normal;
layout(location = 4) in vec3 positionWorld;
layout(location = 5) in flat uint materialIndex;

struct PointLight {
    vec4 position;
    vec4 color;
};

struct Material {
    uint albedoTextureIndex;
    float roughness;
    float metallic;
    float emissive;
    vec4 emissive_color;
};

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientColor;
    PointLight pointLights[16];
    int numPointLights;
} ubo;

layout(set = 1, binding = 0) readonly buffer MaterialBuffer {
    Material materials[];
};

layout(set = 1, binding = 1) uniform sampler2D textures[];

layout(push_constant) uniform Push {
    mat4 transform;
    mat4 normalMatrix;
    uint materialIndex;
} push;

void main() {
    // Get material for this object
    Material mat = materials[materialIndex];
    
    // Start with vertex color as default
    vec3 albedo = color;

    albedo = texture(textures[mat.albedoTextureIndex], uv).rgb;


    outColor = vec4(albedo, 1.0);
    // vec3 diffuseLight = ubo.ambientColor.xyz * ubo.ambientColor.w;
    // vec3 surfaceNormal = normalize(normal);

    // for (int i = 0; i < ubo.numPointLights; i++) {
    //     PointLight light = ubo.pointLights[i];
    //     vec3 directionToLight = light.position.xyz - positionWorld;
    //     float attenuation = 1.0 / dot(directionToLight, directionToLight);
    //     float cosAngIncidence = max(dot(surfaceNormal, normalize(directionToLight)), 0);
    //     vec3 lightColor = light.color.xyz * light.color.w * attenuation;
    //     diffuseLight += lightColor * cosAngIncidence;
    // }

    // outColor = vec4(diffuseLight * albedo, 1.0);
}