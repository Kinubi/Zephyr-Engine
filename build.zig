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

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "ZulkanZengine",
        .root_module = exe_mod,
    });

    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("x11");
    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);
    // Get the (lazy) path to vk.xml:
    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    // Get generator executable reference
    const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
    // Set up a run step to generate the bindings
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    // Pass the registry to the generator
    vk_generate_cmd.addFileArg(registry);
    // Create a module from the generator's output...
    const vulkan_zig = b.addModule("vulkan-zig", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });
    // ... and pass it as a module to your executable's build command
    exe.root_module.addImport("vulkan", vulkan_zig);

    // Add zig-obj to our library and executable
    const obj_mod = b.dependency("zig-obj", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zig-obj", obj_mod.module("obj"));

    const zstbi = b.dependency("zstbi", .{});
    exe.root_module.addImport("zstbi", zstbi.module("root"));

    const cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = cimgui.Platform.GLFW,
        .renderer = cimgui.Renderer.Vulkan,
    });

    exe.linkLibrary(cimgui_dep.artifact("cimgui"));

    // Build SPIRV-Cross as a static library with C API
    const spirv_cross_sources = [_][]const u8{
        "third-party/SPIRV-Cross/spirv_cross.cpp",
        "third-party/SPIRV-Cross/spirv_parser.cpp",
        "third-party/SPIRV-Cross/spirv_cross_parsed_ir.cpp",
        "third-party/SPIRV-Cross/spirv_cfg.cpp",
        "third-party/SPIRV-Cross/spirv_cross_c.cpp", // C API wrapper
        "third-party/SPIRV-Cross/spirv_glsl.cpp",
        "third-party/SPIRV-Cross/spirv_hlsl.cpp",
        "third-party/SPIRV-Cross/spirv_reflect.cpp",
        "third-party/SPIRV-Cross/spirv_cross_util.cpp",
    };

    // Add SPIRV-Cross C++ source files directly to the executable
    exe.addCSourceFiles(.{
        .files = &spirv_cross_sources,
        .flags = &[_][]const u8{
            "-std=c++11",
            "-DSPIRV_CROSS_C_API_GLSL=1",
            "-DSPIRV_CROSS_C_API_HLSL=1",
            "-DSPIRV_CROSS_C_API_REFLECT=1",
        },
    });

    // Add SPIRV-Cross include directory
    exe.addIncludePath(b.path("third-party/SPIRV-Cross"));

    // Link C++ standard library
    exe.linkLibCpp();

    // Use system shaderc library
    exe.linkSystemLibrary("shaderc");

    // Link against required system libraries
    exe.linkSystemLibrary("pthread");

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    // const lib_unit_tests = b.addTest(.{
    //     .root_module = lib_mod,
    // });

    //const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    // SPIRV-Cross test module and executable
    const spirv_test_mod = b.createModule(.{
        .root_source_file = b.path("test_spirv_cross.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const spirv_test = b.addExecutable(.{
        .name = "test_spirv_cross",
        .root_module = spirv_test_mod,
    });

    // Add SPIRV-Cross sources to the test
    spirv_test.addCSourceFiles(.{
        .files = &spirv_cross_sources,
        .flags = &[_][]const u8{
            "-std=c++11",
            "-DSPIRV_CROSS_C_API_GLSL=1",
            "-DSPIRV_CROSS_C_API_HLSL=1",
            "-DSPIRV_CROSS_C_API_REFLECT=1",
        },
    });
    spirv_test.addIncludePath(b.path("third-party/SPIRV-Cross"));
    spirv_test.linkLibCpp();
    spirv_test.linkSystemLibrary("c");

    // Install and run the SPIRV-Cross test
    const install_spirv_test = b.addInstallArtifact(spirv_test, .{});
    const run_spirv_test = b.addRunArtifact(spirv_test);
    run_spirv_test.step.dependOn(&install_spirv_test.step);

    const spirv_test_step = b.step("test-spirv", "Test SPIRV-Cross integration");
    spirv_test_step.dependOn(&run_spirv_test.step);

    const test_step = b.step("test", "Run unit tests");
    //test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
