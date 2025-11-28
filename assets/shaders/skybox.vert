#version 450

// Fullscreen triangle - no vertex input needed
// Generates a triangle that covers the entire screen

layout(location = 0) out vec2 fragUV;

void main() {
    // Generate fullscreen triangle vertices
    // Vertex 0: (-1, -1), Vertex 1: (3, -1), Vertex 2: (-1, 3)
    vec2 positions[3] = vec2[](
        vec2(-1.0, -1.0),
        vec2( 3.0, -1.0),
        vec2(-1.0,  3.0)
    );
    
    vec2 pos = positions[gl_VertexIndex];
    gl_Position = vec4(pos, 0.9999, 1.0); // Near far plane (but not exactly 1.0)
    
    // UV coordinates for sampling
    fragUV = pos * 0.5 + 0.5;
}
