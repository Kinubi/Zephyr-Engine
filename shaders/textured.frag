#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_ARB_separate_shader_objects : enable

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
    float dt;
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
    
    // Sample albedo texture
    vec3 albedo = texture(textures[mat.albedoTextureIndex], uv).rgb;

    // Start with ambient lighting
    vec3 diffuseLight = ubo.ambientColor.xyz * ubo.ambientColor.w;
    vec3 surfaceNormal = normalize(normal);

    // Add point light contributions
    for (int i = 0; i < ubo.numPointLights; i++) {
        PointLight light = ubo.pointLights[i];
        vec3 directionToLight = light.position.xyz - positionWorld;
        float distanceSquared = dot(directionToLight, directionToLight);
        float distance = sqrt(distanceSquared);
        float attenuation = 1.0 / (1.0 + 0.09 * distance + 0.032 * distanceSquared);
        
        vec3 lightDir = normalize(directionToLight);
        float cosAngIncidence = max(dot(surfaceNormal, lightDir), 0.0);
        
        vec3 lightColor = light.color.xyz * light.color.w * attenuation;
        diffuseLight += lightColor * cosAngIncidence;
    }

    // Add emissive contribution if material has it
    vec3 emissive = mat.emissive_color.rgb * mat.emissive;
    
    outColor = vec4(diffuseLight * albedo + emissive, 1.0);
}