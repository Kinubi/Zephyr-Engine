/* Copyright (c) 2024, Sascha Willems
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 the "License";
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#define HitTriangleVertexPositionsKHR 5335
#define RayTracingPositionFetchKHR 5336

struct Attributes
{
    float2 bary;
};

struct Payload
{
    [[vk::location(0)]] float3 hitValue;
};
struct Vertex
{
  float3 pos;
  float3 color;
  float3 normal;
  float2 uv;
};

struct Material {
    uint albedoTextureIndex;
};


StructuredBuffer<Vertex> vertex_buffer[] : register(t3);
StructuredBuffer<uint> index_buffer[]: register(t4);
StructuredBuffer<Material> material_buffer: register(t5);
Texture2D texture_buffer[] : register(t6);
SamplerState sampler0 : register(s6);






[shader("closesthit")]
void main(
    inout Payload p,
    in Attributes attribs
)
{
    uint primID = PrimitiveIndex();
    uint instID = InstanceIndex();
    uint customIndex = InstanceID();


    uint i0 = index_buffer[instID][primID * 3 + 0];
    uint i1 = index_buffer[instID][primID * 3 + 1];
    uint i2 = index_buffer[instID][primID * 3 + 2];

    Vertex v0 = vertex_buffer[instID][i0];
    Vertex v1 = vertex_buffer[instID][i1];
    Vertex v2 = vertex_buffer[instID][i2];

    float3 bary = float3(1.0f - attribs.bary.x - attribs.bary.y, attribs.bary.x, attribs.bary.y);
    float3 normal = normalize(
        v0.normal +
        v1.normal +
        v2.normal
    );

    if (customIndex >= 0) {
        Material mat = material_buffer[customIndex];
        Texture2D tex = texture_buffer[mat.albedoTextureIndex];

        float2 uv = v0.uv * bary.x + v1.uv * bary.y + v2.uv * bary.z;
   
        float3 albedo = tex.SampleLevel(sampler0, uv, 0).rgb;
        p.hitValue = albedo;
    } else {
        p.hitValue = normal * 0.5 + 0.5; 
    }
    

}