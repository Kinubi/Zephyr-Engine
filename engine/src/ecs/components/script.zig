const std = @import("std");

const AssetId = @import("../../assets/asset_types.zig").AssetId;

/// ScriptComponent stores a snippet or reference to a script that can be
/// executed by the ScriptingSystem. By default it stores a `[]const u8` with
/// the script source; optionally it can reference an `AssetId` so the editor
/// and asset manager can track hot-reload and lifecycle.
pub const ScriptComponent = struct {
    /// Pointer to NUL-terminated script source or a slice owned elsewhere
    script: []const u8,
    /// Optional asset ID if this script was registered as an asset
    asset: ?AssetId = null,
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
        return ScriptComponent{
            .script = script,
            .asset = null,
            .enabled = true,
            .run_on_update = run_on_update,
            .run_once = run_once,
        };
    }

    /// Initialize with an associated AssetId (best used when the script was
    /// registered with the AssetManager). The `script` slice should remain
    /// valid for the component's lifetime (Scene allocator is recommended).
    pub fn initWithAsset(script: []const u8, asset: AssetId, run_on_update: bool, run_once: bool) ScriptComponent {
        return ScriptComponent{
            .script = script,
            .asset = asset,
            .enabled = true,
            .run_on_update = run_on_update,
            .run_once = run_once,
        };
    }

    /// Convenience initializer: apply the script but do NOT schedule it for
    /// automatic per-frame execution. This mirrors the "Apply" action in the
    /// editor: update the stored script without changing its execution state.
    pub fn initDefault(script: []const u8) ScriptComponent {
        return ScriptComponent.init(script, false, false);
    }

    /// Convenience initializer for one-shot execution on the next update tick.
    /// This mirrors the "Run Next Update" button in the editor.
    pub fn initOneShot(script: []const u8) ScriptComponent {
        return ScriptComponent.init(script, true, true);
    }

    /// Component-level update (called by World.update when iterating components)
    /// Script execution itself is performed by the ScriptingSystem so this
    /// method is a no-op; it exists to satisfy the `World.update` contract.
    pub fn update(self: *ScriptComponent, dt: f32) void {
        _ = self;
        _ = dt; // no-op; ScriptingSystem will poll ScriptComponent entries
    }
};
