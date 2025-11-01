const std = @import("std");

/// ScriptComponent stores a snippet or reference to a script that can be
/// executed by the ScriptingSystem. This component is intentionally small
/// and stores a `[]const u8` reference to the script source. The Scene or
/// asset system should ensure the lifetime of the referenced buffer.
pub const ScriptComponent = struct {
    /// Pointer to NUL-terminated script source or a slice owned elsewhere
    script: []const u8,
    /// If true, the scripting system will attempt to execute the script
    enabled: bool,
    /// If true, the script will be executed every frame (when the scripting
    /// system's `update` runs). If false, the system will not auto-run it.
    run_on_update: bool,
    /// If true, the script will be executed only once and then `enabled`
    /// will be set to false by the ScriptingSystem (useful for one-shot
    /// initialization scripts attached to entities).
    run_once: bool,

    pub fn init(script: []const u8, run_on_update: bool, run_once: bool) ScriptComponent {
        return .{
            .script = script,
            .enabled = true,
            .run_on_update = run_on_update,
            .run_once = run_once,
        };
    }

    /// Component-level update (called by World.update when iterating components)
    /// Script execution itself is performed by the ScriptingSystem so this
    /// method is a no-op; it exists to satisfy the `World.update` contract.
    pub fn update(self: *ScriptComponent, dt: f32) void {
        _ = self;
        _ = dt; // no-op; ScriptingSystem will poll ScriptComponent entries
    }
};
