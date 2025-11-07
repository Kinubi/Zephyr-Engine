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
    uint albedo_idx;
    uint roughness_idx;
    uint metallic_idx;
    uint normal_idx;
    uint emissive_idx;
    uint occlusion_idx;
    
    vec4 albedo_tint;
    float roughness_factor;
    float metallic_factor;
    float normal_strength;
    float emissive_intensity;
    vec3 emissive_color;
    float occlusion_strength;
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
    
    // Sample albedo texture and apply tint
    vec3 albedo;
    if (mat.albedo_idx == 0) {
        // No texture - use tint as albedo color
        albedo = mat.albedo_tint.rgb;
    } else {
        // Sample texture and multiply with tint
        albedo = texture(textures[mat.albedo_idx], uv).rgb * mat.albedo_tint.rgb;
    }

    // Sample roughness texture or use factor
    float roughness;
    if (mat.roughness_idx == 0) {
        roughness = mat.roughness_factor;
    } else {
        roughness = texture(textures[mat.roughness_idx], uv).r * mat.roughness_factor;
    }

    // Sample metallic texture or use factor
    float metallic;
    if (mat.metallic_idx == 0) {
        metallic = mat.metallic_factor;
    } else {
        metallic = texture(textures[mat.metallic_idx], uv).r * mat.metallic_factor;
    }

    // Sample normal map if present
    vec3 surfaceNormal;
    if (mat.normal_idx == 0) {
        surfaceNormal = normalize(normal);
    } else {
        // Sample normal map and transform to world space (simplified - should use TBN matrix)
        vec3 normalMap = texture(textures[mat.normal_idx], uv).xyz * 2.0 - 1.0;
        surfaceNormal = normalize(normal + normalMap * mat.normal_strength);
    }

    // Sample occlusion if present
    float occlusion = 1.0;
    if (mat.occlusion_idx != 0) {
        occlusion = mix(1.0, texture(textures[mat.occlusion_idx], uv).r, mat.occlusion_strength);
    }

    // Start with ambient lighting
    vec3 diffuseLight = ubo.ambientColor.xyz * ubo.ambientColor.w * occlusion;

    // Add point light contributions
    for (int i = 0; i < ubo.numPointLights; i++) {
        PointLight light = ubo.pointLights[i];
        vec3 directionToLight = light.position.xyz - positionWorld;
        float distanceSquared = dot(directionToLight, directionToLight);
        float distance = sqrt(distanceSquared);
        float attenuation = 1.0 / (1.0 + 0.09 * distance + 0.032 * distanceSquared);
        
        vec3 lightDir = normalize(directionToLight);
        float cosAngIncidence = max(dot(surfaceNormal, lightDir), 0.0);
        
        // Simple roughness and metallic-based shading
        float diffuseFactor = cosAngIncidence * (1.0 - roughness * 0.5) * (1.0 - metallic * 0.8);
        
        vec3 lightColor = light.color.xyz * light.color.w * attenuation;
        diffuseLight += lightColor * diffuseFactor * occlusion;
    }

    // Add emissive contribution
    vec3 emissive = mat.emissive_color * mat.emissive_intensity;
    if (mat.emissive_idx != 0) {
        emissive *= texture(textures[mat.emissive_idx], uv).rgb;
    }
    
    outColor = vec4(diffuseLight * albedo + emissive, mat.albedo_tint.a);
}