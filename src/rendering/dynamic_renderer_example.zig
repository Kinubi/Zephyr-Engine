const std = @import("std");
const vk = @import("vulkan");
const DynamicPipelineManager = @import("dynamic_pipeline_manager.zig").DynamicPipelineManager;
const PipelineTemplate = @import("dynamic_pipeline_manager.zig").PipelineTemplate;
const PipelineBuilder = @import("pipeline_builder.zig").PipelineBuilder;
const GraphicsContext = @import("../core/graphics_context.zig").GraphicsContext;
const FrameInfo = @import("frameinfo.zig").FrameInfo;
const log = @import("../utils/log.zig").log;

/// Example renderer that demonstrates dynamic pipeline usage
pub const DynamicRenderer = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    graphics_context: *GraphicsContext,
    pipeline_manager: *DynamicPipelineManager,
    
    // Render data
    vertex_buffer: ?vk.Buffer = null,
    index_buffer: ?vk.Buffer = null,
    uniform_buffer: ?vk.Buffer = null,
    descriptor_set: ?vk.DescriptorSet = null,
    
    // Pipeline names for different rendering modes
    basic_pipeline: []const u8 = "basic_lit",
    textured_pipeline: []const u8 = "textured_lit", 
    wireframe_pipeline: []const u8 = "wireframe",
    
    pub fn init(
        allocator: std.mem.Allocator,
        graphics_context: *GraphicsContext,
        pipeline_manager: *DynamicPipelineManager
    ) !Self {
        var renderer = Self{
            .allocator = allocator,
            .graphics_context = graphics_context,
            .pipeline_manager = pipeline_manager,
        };
        
        // Register pipeline templates
        try renderer.registerPipelineTemplates();
        
        log(.INFO, "dynamic_renderer", "Dynamic renderer initialized", .{});
        return renderer;
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up buffers and descriptor sets
        // (Implementation would go here)
        _ = self;
    }
    
    /// Register all pipeline templates this renderer uses
    fn registerPipelineTemplates(self: *Self) !void {
        // Basic lit pipeline
        const basic_template = PipelineTemplate{
            .name = self.basic_pipeline,
            .vertex_shader = "shaders/simple.vert",
            .fragment_shader = "shaders/simple.frag",
            
            .vertex_bindings = &[_]PipelineBuilder.VertexInputBinding{
                PipelineBuilder.VertexInputBinding.create(0, @sizeOf(Vertex)),
            },
            
            .vertex_attributes = &[_]PipelineBuilder.VertexInputAttribute{
                PipelineBuilder.VertexInputAttribute.create(0, 0, .r32g32b32_sfloat, @offsetOf(Vertex, "position")),
                PipelineBuilder.VertexInputAttribute.create(1, 0, .r32g32b32_sfloat, @offsetOf(Vertex, "normal")),
                PipelineBuilder.VertexInputAttribute.create(2, 0, .r32g32_sfloat, @offsetOf(Vertex, "uv")),
            },
            
            .descriptor_bindings = &[_]PipelineBuilder.DescriptorBinding{
                PipelineBuilder.DescriptorBinding.uniformBuffer(0, .{ .vertex_bit = true, .fragment_bit = true }),
            },
            
            .push_constant_ranges = &[_]PipelineBuilder.PushConstantRange{
                PipelineBuilder.PushConstantRange{
                    .stage_flags = .{ .vertex_bit = true },
                    .offset = 0,
                    .size = @sizeOf(PushConstants),
                },
            },
            
            .depth_test_enable = true,
            .depth_write_enable = true,
            .cull_mode = .{ .back_bit = true },
        };
        
        try self.pipeline_manager.registerPipeline(basic_template);
        
        // Textured pipeline
        const textured_template = PipelineTemplate{
            .name = self.textured_pipeline,
            .vertex_shader = "shaders/textured.vert",
            .fragment_shader = "shaders/textured.frag",
            
            .vertex_bindings = &[_]PipelineBuilder.VertexInputBinding{
                PipelineBuilder.VertexInputBinding.create(0, @sizeOf(Vertex)),
            },
            
            .vertex_attributes = &[_]PipelineBuilder.VertexInputAttribute{
                PipelineBuilder.VertexInputAttribute.create(0, 0, .r32g32b32_sfloat, @offsetOf(Vertex, "position")),
                PipelineBuilder.VertexInputAttribute.create(1, 0, .r32g32b32_sfloat, @offsetOf(Vertex, "normal")),
                PipelineBuilder.VertexInputAttribute.create(2, 0, .r32g32_sfloat, @offsetOf(Vertex, "uv")),
            },
            
            .descriptor_bindings = &[_]PipelineBuilder.DescriptorBinding{
                PipelineBuilder.DescriptorBinding.uniformBuffer(0, .{ .vertex_bit = true, .fragment_bit = true }),
                PipelineBuilder.DescriptorBinding.combinedImageSampler(1, .{ .fragment_bit = true }),
            },
            
            .push_constant_ranges = &[_]PipelineBuilder.PushConstantRange{
                PipelineBuilder.PushConstantRange{
                    .stage_flags = .{ .vertex_bit = true },
                    .offset = 0,
                    .size = @sizeOf(PushConstants),
                },
            },
            
            .depth_test_enable = true,
            .depth_write_enable = true,
            .cull_mode = .{ .back_bit = true },
        };
        
        try self.pipeline_manager.registerPipeline(textured_template);
        
        // Wireframe pipeline
        const wireframe_template = PipelineTemplate{
            .name = self.wireframe_pipeline,
            .vertex_shader = "shaders/simple.vert",
            .fragment_shader = "shaders/simple.frag",
            
            .vertex_bindings = &[_]PipelineBuilder.VertexInputBinding{
                PipelineBuilder.VertexInputBinding.create(0, @sizeOf(Vertex)),
            },
            
            .vertex_attributes = &[_]PipelineBuilder.VertexInputAttribute{
                PipelineBuilder.VertexInputAttribute.create(0, 0, .r32g32b32_sfloat, @offsetOf(Vertex, "position")),
                PipelineBuilder.VertexInputAttribute.create(1, 0, .r32g32b32_sfloat, @offsetOf(Vertex, "normal")),
                PipelineBuilder.VertexInputAttribute.create(2, 0, .r32g32_sfloat, @offsetOf(Vertex, "uv")),
            },
            
            .descriptor_bindings = &[_]PipelineBuilder.DescriptorBinding{
                PipelineBuilder.DescriptorBinding.uniformBuffer(0, .{ .vertex_bit = true, .fragment_bit = true }),
            },
            
            .push_constant_ranges = &[_]PipelineBuilder.PushConstantRange{
                PipelineBuilder.PushConstantRange{
                    .stage_flags = .{ .vertex_bit = true },
                    .offset = 0,
                    .size = @sizeOf(PushConstants),
                },
            },
            
            // Wireframe-specific settings
            .polygon_mode = .line,
            .depth_test_enable = true,
            .depth_write_enable = true,
            .cull_mode = .{ .none_bit = true }, // Don't cull in wireframe mode
        };
        
        try self.pipeline_manager.registerPipeline(wireframe_template);
        
        log(.INFO, "dynamic_renderer", "Registered {} pipeline templates", .{3});
    }
    
    /// Render with dynamic pipeline selection
    pub fn render(self: *Self, frame_info: FrameInfo, render_pass: vk.RenderPass, render_mode: RenderMode) !void {
        // Select pipeline based on render mode
        const pipeline_name = switch (render_mode) {
            .basic => self.basic_pipeline,
            .textured => self.textured_pipeline,
            .wireframe => self.wireframe_pipeline,
        };
        
        // Get the pipeline (will build if necessary)
        const pipeline = self.pipeline_manager.getPipeline(pipeline_name, render_pass) catch |err| {
            log(.ERROR, "dynamic_renderer", "Failed to get pipeline '{s}': {}", .{pipeline_name, err});
            return;
        };
        
        if (pipeline == null) {
            log(.WARN, "dynamic_renderer", "Pipeline '{s}' not available", .{pipeline_name});
            return;
        }
        
        const pipeline_layout = self.pipeline_manager.getPipelineLayout(pipeline_name);
        if (pipeline_layout == null) {
            log(.WARN, "dynamic_renderer", "Pipeline layout for '{s}' not available", .{pipeline_name});
            return;
        }
        
        // Bind the pipeline
        frame_info.command_buffer.cmdBindPipeline(.graphics, pipeline.?);
        
        // Bind descriptor sets if available
        if (self.descriptor_set) |desc_set| {
            frame_info.command_buffer.cmdBindDescriptorSets(
                .graphics,
                pipeline_layout.?,
                0,
                1,
                @ptrCast(&desc_set),
                0,
                null
            );
        }
        
        // Push constants example
        const push_constants = PushConstants{
            .model_matrix = frame_info.camera.view_matrix, // Example data
            .material_id = switch (render_mode) {
                .basic => 0,
                .textured => 1,
                .wireframe => 2,
            },
        };
        
        frame_info.command_buffer.cmdPushConstants(
            pipeline_layout.?,
            .{ .vertex_bit = true },
            0,
            @sizeOf(PushConstants),
            &push_constants
        );
        
        // Bind vertex/index buffers and draw
        if (self.vertex_buffer) |vb| {
            const offsets = [_]vk.DeviceSize{0};
            frame_info.command_buffer.cmdBindVertexBuffers(0, 1, @ptrCast(&vb), &offsets);
        }
        
        if (self.index_buffer) |ib| {
            frame_info.command_buffer.cmdBindIndexBuffer(ib, 0, .uint32);
            frame_info.command_buffer.cmdDrawIndexed(36, 1, 0, 0, 0); // Example: cube indices
        } else {
            frame_info.command_buffer.cmdDraw(3, 1, 0, 0); // Example: triangle
        }
        
        log(.DEBUG, "dynamic_renderer", "Rendered with pipeline: {s}", .{pipeline_name});
    }
    
    /// Update function (process pipeline rebuilds)
    pub fn update(self: *Self, render_pass: vk.RenderPass) void {
        // Process any pending pipeline rebuilds
        self.pipeline_manager.processRebuildQueue(render_pass);
    }
    
    /// Get pipeline statistics
    pub fn getStats(self: *Self) @import("dynamic_pipeline_manager.zig").PipelineStatistics {
        return self.pipeline_manager.getStatistics();
    }
};

/// Render mode selection
pub const RenderMode = enum {
    basic,
    textured,
    wireframe,
};

/// Example vertex structure
const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
};

/// Example push constants
const PushConstants = struct {
    model_matrix: [16]f32,
    material_id: u32,
};