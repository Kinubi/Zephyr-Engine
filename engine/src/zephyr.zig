// Zephyr Engine - Main module export
// This is what users import: @import("zephyr")

// Zephyr Engine Public API
// This is the main entry point for using the engine

const std = @import("std");

// ===== Constants =====
/// Maximum number of frames that can be in-flight simultaneously
/// This affects command buffer allocation and synchronization
pub const MAX_FRAMES_IN_FLIGHT: u32 = 3;

// ===== Core Engine =====
pub const Engine = @import("core/engine.zig").Engine;
pub const EngineConfig = Engine.Config;

// ========== Core Types ==========
pub const Layer = @import("core/layer.zig").Layer;
pub const LayerStack = @import("core/layer_stack.zig").LayerStack;
pub const Event = @import("core/event.zig").Event;
pub const EventType = @import("core/event.zig").EventType;
pub const EventCategory = @import("core/event.zig").EventCategory;
pub const EventBus = @import("core/event_bus.zig").EventBus;
pub const Window = @import("core/window.zig").Window;
pub const WindowProps = @import("core/window.zig").WindowProps;

// ========== Graphics ==========
pub const GraphicsContext = @import("core/graphics_context.zig").GraphicsContext;
pub const Swapchain = @import("core/swapchain.zig").Swapchain;
pub const Buffer = @import("core/buffer.zig").Buffer;
pub const Shader = @import("core/shader.zig").Shader;
pub const Texture = @import("core/texture.zig").Texture;
pub const Descriptors = @import("core/descriptors.zig");

// ========== Rendering ==========
pub const Camera = @import("rendering/camera.zig").Camera;
pub const FrameInfo = @import("rendering/frameinfo.zig").FrameInfo;
pub const GlobalUbo = FrameInfo.GlobalUbo;
pub const GlobalUboSet = @import("rendering/ubo_set.zig").GlobalUboSet;
pub const PerformanceMonitor = @import("rendering/performance_monitor.zig").PerformanceMonitor;
pub const PerformanceStats = @import("rendering/performance_monitor.zig").PerformanceStats;
pub const RenderGraph = @import("rendering/render_graph.zig");
pub const UnifiedPipelineSystem = @import("rendering/unified_pipeline_system.zig").UnifiedPipelineSystem;
pub const PipelineId = @import("rendering/unified_pipeline_system.zig").PipelineId;
pub const Resource = @import("rendering/unified_pipeline_system.zig").Resource;
pub const ResourceBinder = @import("rendering/resource_binder.zig").ResourceBinder;
pub const Mesh = @import("rendering/mesh.zig");
pub const Vertex = Mesh.Vertex;
pub const Model = Mesh.Model;
pub const PipelineBuilder = @import("rendering/pipeline_builder.zig");

// ========== Threading ==========
pub const ThreadPool = @import("threading/thread_pool.zig").ThreadPool;
pub const RenderThreadContext = @import("threading/render_thread.zig").RenderThreadContext;
pub const startRenderThread = @import("threading/render_thread.zig").startRenderThread;
pub const stopRenderThread = @import("threading/render_thread.zig").stopRenderThread;
pub const mainThreadUpdate = @import("threading/render_thread.zig").mainThreadUpdate;
pub const GameStateSnapshot = @import("threading/game_state_snapshot.zig").GameStateSnapshot;
pub const captureSnapshot = @import("threading/game_state_snapshot.zig").captureSnapshot;

// ========== ECS ==========
pub const ecs = @import("ecs.zig");
pub const World = ecs.World;
pub const Entity = @import("ecs/entity_registry.zig").EntityId;
pub const EntityRegistry = @import("ecs/entity_registry.zig").EntityRegistry;
pub const MeshRenderer = @import("ecs/components/mesh_renderer.zig").MeshRenderer;
pub const Transform = @import("ecs/components/transform.zig").Transform;

// ========== Scene ==========
pub const Scene = @import("scene/scene.zig").Scene;
pub const GameObject = @import("scene/game_object.zig").GameObject;

// ========== Assets ==========
pub const AssetManager = @import("assets/asset_manager.zig").AssetManager;
pub const AssetRegistry = @import("assets/asset_registry.zig").AssetRegistry;
pub const AssetLoader = @import("assets/asset_loader.zig").AssetLoader;
pub const Material = @import("assets/asset_manager.zig").Material;
pub const ShaderManager = @import("assets/shader_manager.zig").ShaderManager;

// ========== Layers (Engine-Provided) ==========
pub const PerformanceLayer = @import("layers/performance_layer.zig").PerformanceLayer;
pub const RenderLayer = @import("layers/render_layer.zig").RenderLayer;
pub const SceneLayer = @import("layers/scene_layer.zig").SceneLayer;
// TODO: InputLayer and UILayer have editor dependencies, need refactoring
// pub const InputLayer = @import("layers/input_layer.zig").InputLayer;
// pub const UILayer = @import("layers/ui_layer.zig").UILayer;

// ========== Utils ==========
pub const math = @import("utils/math.zig");
pub const log = @import("utils/log.zig").log;
pub const DynamicRenderingHelper = @import("utils/dynamic_rendering.zig").DynamicRenderingHelper;
pub const FileWatcher = @import("utils/file_watcher.zig").FileWatcher;

// ========== Scripting (expose for examples/tests) ==========
pub const scripting = @import("scripting/script_runner.zig");
pub const ScriptRunner = scripting.ScriptRunner;
pub const StatePool = @import("scripting/state_pool.zig").StatePool;
pub const ActionQueue = @import("scripting/action_queue.zig").ActionQueue;
