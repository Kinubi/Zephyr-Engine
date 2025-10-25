const std = @import("std");
const cimgui = @import("cimgui_zig");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .native } });

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // ========== VULKAN BINDINGS (shared by engine and editor) ==========
    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig = b.addModule("vulkan-zig", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });

    // ========== ENGINE MODULE ==========
    // Create engine as a module that can be imported
    const engine_mod = b.addModule("zulkan", .{
        .root_source_file = b.path("engine/src/zulkan.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies to engine module
    engine_mod.addImport("vulkan", vulkan_zig);

    const obj_mod = b.dependency("zig-obj", .{ .target = target, .optimize = optimize });
    engine_mod.addImport("zig-obj", obj_mod.module("obj"));

    const zstbi = b.dependency("zstbi", .{});
    engine_mod.addImport("zstbi", zstbi.module("root"));

    // ========== EDITOR EXECUTABLE ==========
    const editor_mod = b.createModule(.{
        .root_source_file = b.path("editor/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const editor = b.addExecutable(.{
        .name = "ZulkanEditor",
        .root_module = editor_mod,
    });

    // Add engine module import to editor
    editor.root_module.addImport("zulkan", engine_mod);

    // Add vulkan module to editor (needed for editor-specific code)
    editor.root_module.addImport("vulkan", vulkan_zig);

    // Link system libraries needed by engine
    editor.linkSystemLibrary("glfw");
    editor.linkSystemLibrary("x11");
    editor.linkSystemLibrary("shaderc");
    editor.linkSystemLibrary("pthread");
    editor.linkLibC();

    // SPIRV-Cross for shader reflection (needed by engine)
    addSpirvCross(b, editor);

    // Add ImGui for editor UI
    const cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = cimgui.Platform.GLFW,
        .renderer = cimgui.Renderer.Vulkan,
    });
    editor.linkLibrary(cimgui_dep.artifact("cimgui"));

    // Install editor
    b.installArtifact(editor);

    // ========== RUN COMMAND ==========
    const run_cmd = b.addRunArtifact(editor);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);

    // ========== TESTS ==========
    const editor_test_mod = b.createModule(.{
        .root_source_file = b.path("editor/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const editor_tests = b.addTest(.{
        .root_module = editor_test_mod,
    });
    editor_tests.root_module.addImport("zulkan", engine_mod);

    const run_editor_tests = b.addRunArtifact(editor_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_editor_tests.step);
}

// Helper function to add SPIRV-Cross to a compile step
fn addSpirvCross(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const spirv_cross_sources = [_][]const u8{
        "third-party/SPIRV-Cross/spirv_cross.cpp",
        "third-party/SPIRV-Cross/spirv_parser.cpp",
        "third-party/SPIRV-Cross/spirv_cross_parsed_ir.cpp",
        "third-party/SPIRV-Cross/spirv_cfg.cpp",
        "third-party/SPIRV-Cross/spirv_cross_c.cpp",
        "third-party/SPIRV-Cross/spirv_glsl.cpp",
        "third-party/SPIRV-Cross/spirv_hlsl.cpp",
        "third-party/SPIRV-Cross/spirv_reflect.cpp",
        "third-party/SPIRV-Cross/spirv_cross_util.cpp",
    };

    compile.addCSourceFiles(.{
        .files = &spirv_cross_sources,
        .flags = &[_][]const u8{
            "-std=c++11",
            "-DSPIRV_CROSS_C_API_GLSL=1",
            "-DSPIRV_CROSS_C_API_HLSL=1",
            "-DSPIRV_CROSS_C_API_REFLECT=1",
        },
    });

    compile.addIncludePath(b.path("third-party/SPIRV-Cross"));
    compile.linkLibCpp();
}
