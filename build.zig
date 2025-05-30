const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    // const lib_mod = b.createModule(.{
    //     // `root_source_file` is the Zig "entry point" of the module. If a module
    //     // only contains e.g. external object files, you can make this `null`.
    //     // In this case the main source file is merely a path, however, in more
    //     // complicated build scripts, this could be a generated file.
    //     .root_source_file = b.path("src/root.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });

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

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".

    // Shader compilation step: compile all .hlsl files in src/shaders/ to .spv
    const shader_dir = "shaders";
    var dir = try std.fs.cwd().openDir(shader_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".hlsl") and !std.mem.eql(u8, entry.name, "NRI.hlsl")) {
            const hlsl_path = std.fs.path.join(b.allocator, &[_][]const u8{ shader_dir, entry.name }) catch unreachable;
            const spv_name = b.allocator.alloc(u8, entry.name.len + 4) catch unreachable;
            std.mem.copyForwards(u8, spv_name[0..entry.name.len], entry.name);
            std.mem.copyForwards(u8, spv_name[entry.name.len..], ".spv");
            const spv_path = std.fs.path.join(b.allocator, &[_][]const u8{ shader_dir, spv_name }) catch unreachable;
            exe.step.dependOn(&b.addSystemCommand(&[_][]const u8{
                "dxc",
                "-Ivendor/NRIFramework/External/NRI/Include",
                "-fspv-target-env=vulkan1.2",
                "-T",
                "lib_6_3",
                "-spirv",
                "-Fo",
                spv_path,
                hlsl_path,
            }).step);
        }
    }

    // Compile the vertex shader at build time so that it can be imported with '@embedFile'.
    const vert_cmd = b.addSystemCommand(&.{ "glslc", "-o" });
    const vert_spv = vert_cmd.addOutputFileArg("vert.spv");
    vert_cmd.addFileArg(b.path("shaders/simple.vert"));
    exe.root_module.addAnonymousImport("simple_vert", .{ .root_source_file = vert_spv });

    const frag_cmd = b.addSystemCommand(&.{ "glslc", "-o" });
    const frag_spv = frag_cmd.addOutputFileArg("frag.spv");
    frag_cmd.addFileArg(b.path("shaders/simple.frag"));
    exe.root_module.addAnonymousImport("simple_frag", .{ .root_source_file = frag_spv });

    const vert_point_cmd = b.addSystemCommand(&.{ "glslc", "-o" });
    const vert_point_spv = vert_point_cmd.addOutputFileArg("vert_point.spv");
    vert_point_cmd.addFileArg(b.path("shaders/point_light.vert"));
    exe.root_module.addAnonymousImport("point_light_vert", .{ .root_source_file = vert_point_spv });

    const frag_point_cmd = b.addSystemCommand(&.{ "glslc", "-o" });
    const frag_point_spv = frag_point_cmd.addOutputFileArg("frag_point.spv");
    frag_point_cmd.addFileArg(b.path("shaders/point_light.frag"));
    exe.root_module.addAnonymousImport("point_light_frag", .{ .root_source_file = frag_point_spv });

    exe.root_module.addAnonymousImport("smooth_vase", .{ .root_source_file = b.path("models/smooth_vase.obj") });
    exe.root_module.addAnonymousImport("cube", .{ .root_source_file = b.path("models/cube.obj") });

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
    const test_step = b.step("test", "Run unit tests");
    //test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
