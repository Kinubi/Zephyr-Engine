const std = @import("std");

const AssetId = @import("../../assets/asset_types.zig").AssetId;

/// ScriptComponent stores a snippet or reference to a script that can be
/// executed by the ScriptingSystem. By default it stores a `[]const u8` with
/// the script source; optionally it can reference an `AssetId` so the editor
/// and asset manager can track hot-reload and lifecycle.
pub const ScriptComponent = struct {
    pub const json_name = "ScriptComponent";
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
    /// If true, the script string is owned by this component and should be freed on deinit
    owns_memory: bool = false,

    pub fn init(script: []const u8, run_on_update: bool, run_once: bool) ScriptComponent {
        return ScriptComponent{
            .script = script,
            .asset = null,
            .enabled = true,
            .run_on_update = run_on_update,
            .run_once = run_once,
            .owns_memory = false,
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
            .owns_memory = false,
        };
    }

    /// Convenience initializer: apply the script but do NOT schedule it for
    /// automatic per-frame execution. This mirrors the "Apply" action in the
    /// editor: update the stored script without changing its execution state.
    pub fn initDefault(script: []const u8) ScriptComponent {
        return ScriptComponent{
            .script = script,
            .asset = null,
            .enabled = true,
            .run_on_update = false,
            .run_once = false,
            .owns_memory = false,
        };
    }

    pub fn deinit(self: ScriptComponent, allocator: std.mem.Allocator) void {
        if (self.owns_memory) {
            allocator.free(self.script);
        }
    }

    /// Serialize ScriptComponent
    pub fn jsonSerialize(self: ScriptComponent, serializer: anytype, writer: anytype) !void {
        try writer.beginObject();
        
        if (self.asset) |asset_id| {
            if (asset_id.isValid()) {
                if (serializer.getAssetPath(asset_id)) |path| {
                    try writer.objectField("asset");
                    try writer.write(path);
                }
            }
        }
        
        // If no asset, or as a fallback/override, we might want to save the script content?
        // For now, let's only save script content if there is no asset.
        if (self.asset == null or !self.asset.?.isValid()) {
            try writer.objectField("script");
            try writer.write(self.script);
        }
        
        try writer.objectField("enabled");
        try writer.write(self.enabled);
        
        try writer.objectField("run_on_update");
        try writer.write(self.run_on_update);
        
        try writer.objectField("run_once");
        try writer.write(self.run_once);
        
        try writer.endObject();
    }

    /// Deserialize ScriptComponent
    pub fn deserialize(serializer: anytype, value: std.json.Value) !ScriptComponent {
        var script_comp = ScriptComponent.initDefault("");
        
        if (value.object.get("asset")) |path_val| {
            if (path_val == .string) {
                if (serializer.getAssetId(path_val.string)) |id| {
                    script_comp.asset = id;
                }
            }
        }
        
        if (value.object.get("script")) |val| {
            if (val == .string) {
                script_comp.script = try serializer.allocator.dupe(u8, val.string);
                script_comp.owns_memory = true;
            }
        }
        
        if (value.object.get("enabled")) |val| {
            if (val == .bool) script_comp.enabled = val.bool;
        }
        
        if (value.object.get("run_on_update")) |val| {
            if (val == .bool) script_comp.run_on_update = val.bool;
        }
        
        if (value.object.get("run_once")) |val| {
            if (val == .bool) script_comp.run_once = val.bool;
        }
        
        return script_comp;
    }
};
