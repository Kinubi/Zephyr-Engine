const std = @import("std");
const ShaderCompiler = @import("shader_compiler.zig");

// Shader caching system with file hashing for change detection
// Compiles raw GLSL/HLSL to SPIR-V only when source files have changed

pub const ShaderCache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,

    // Maps shader file path to cached metadata
    cache_metadata: std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    cache_mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8) !Self {
        // Ensure cache directory exists
        std.fs.cwd().makeDir(cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK, directory exists
            else => return err,
        };

        var cache = Self{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .cache_metadata = std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };

        // Load existing cache metadata
        try cache.loadCacheMetadata();

        return cache;
    }

    pub fn deinit(self: *Self) void {
        // Save cache metadata before cleanup
        self.saveCacheMetadata() catch |err| {
            std.log.warn("Failed to save shader cache metadata: {}", .{err});
        };

        // Clean up memory
        // Guard access with mutex in case other threads still reference cache (defensive)
        self.cache_mutex.lock();
        var iterator = self.cache_metadata.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.cached_spirv_path);
        }
        self.cache_mutex.unlock();
        self.cache_metadata.deinit();
        self.allocator.free(self.cache_dir);
    }

    /// Get compiled SPIR-V for a shader, compiling if necessary
    pub fn getCompiledShader(self: *Self, compiler: *ShaderCompiler.ShaderCompiler, source_path: []const u8, options: ShaderCompiler.CompilationOptions) !ShaderCompiler.CompiledShader {

        // Calculate file hash to detect changes
        const file_hash = try self.calculateFileHash(source_path);
        const path_key = try self.allocator.dupe(u8, source_path);

        // Check if we have a valid cached version
        self.cache_mutex.lock();
        if (self.cache_metadata.get(source_path)) |entry| {
            if (entry.file_hash == file_hash and entry.options_hash == self.calculateOptionsHash(options)) {
                // Cache hit - load existing SPIR-V (include reflection)
                const cached_path = entry.cached_spirv_path;
                const cached_hash = entry.file_hash;
                self.cache_mutex.unlock();
                return try self.loadCachedSpirv(compiler, cached_path, cached_hash);
            } else {
                // Cache invalidated - clean up old entry

                // Clean up old cache entry
                const old_path = entry.cached_spirv_path;
                self.cache_mutex.unlock();
                self.allocator.free(old_path);
            }
        } else {
            self.cache_mutex.unlock();
            // New shader compilation needed
        }

        // Cache miss or invalid - compile the shader
        const compiled = try compiler.compileFromFile(source_path, options);

        // Generate cache file path
        const spirv_cache_path = try self.generateCachePath(source_path);

        // Save compiled SPIR-V to cache
        try self.saveSpirvToCache(compiled.spirv_code, spirv_cache_path);

        // Update cache metadata
        const cache_entry = CacheEntry{
            .cached_spirv_path = try self.allocator.dupe(u8, spirv_cache_path),
            .file_hash = file_hash,
            .options_hash = self.calculateOptionsHash(options),
            .compile_time = std.time.timestamp(),
        };

        // Insert metadata under lock
        self.cache_mutex.lock();
        try self.cache_metadata.put(path_key, cache_entry);
        self.cache_mutex.unlock();

        // Save updated metadata to disk
        self.saveCacheMetadata() catch |err| {
            std.log.warn("Failed to save cache metadata: {}", .{err});
        };

        return compiled;
    }

    /// Get compiled SPIR-V from raw shader source
    pub fn getCompiledShaderFromSource(
        self: *Self,
        compiler: *ShaderCompiler.ShaderCompiler,
        source: ShaderCompiler.ShaderSource,
        source_identifier: []const u8, // Unique identifier for this source
        options: ShaderCompiler.CompilationOptions,
    ) !ShaderCompiler.CompiledShader {

        // Calculate source hash to detect changes
        const source_hash = std.hash_map.hashString(source.code);
        const identifier_key = try self.allocator.dupe(u8, source_identifier);

        // Check if we have a valid cached version
        self.cache_mutex.lock();
        if (self.cache_metadata.get(source_identifier)) |entry| {
            if (entry.file_hash == source_hash and entry.options_hash == self.calculateOptionsHash(options)) {
                const cached_path = entry.cached_spirv_path;
                self.cache_mutex.unlock();
                // Cache hit - load existing SPIR-V
                return try self.loadCachedSpirv(compiler, cached_path, source_hash);
            }
        }
        self.cache_mutex.unlock();

        // Cache miss or invalid - compile the shader
        const compiled = try compiler.compile(source, options);

        // Generate cache file path for source
        const spirv_cache_path = try self.generateSourceCachePath(source_identifier, source.stage);

        // Save compiled SPIR-V to cache
        try self.saveSpirvToCache(compiled.spirv_code, spirv_cache_path);

        // Update cache metadata
        const cache_entry = CacheEntry{
            .cached_spirv_path = try self.allocator.dupe(u8, spirv_cache_path),
            .file_hash = source_hash,
            .options_hash = self.calculateOptionsHash(options),
            .compile_time = std.time.timestamp(),
        };

        self.cache_mutex.lock();
        try self.cache_metadata.put(identifier_key, cache_entry);
        self.cache_mutex.unlock();

        // Save updated metadata to disk
        self.saveCacheMetadata() catch |err| {
            std.log.warn("Failed to save cache metadata: {}", .{err});
        };

        return compiled;
    }

    /// Clear all cached shaders
    pub fn clearCache(self: *Self) !void {
        // Remove all cached SPIR-V files
        self.cache_mutex.lock();
        var iterator = self.cache_metadata.iterator();
        while (iterator.next()) |entry| {
            std.fs.cwd().deleteFile(entry.value_ptr.cached_spirv_path) catch |err| switch (err) {
                error.FileNotFound => {}, // Already deleted, that's fine
                else => std.log.warn("Failed to delete cached file {s}: {}", .{ entry.value_ptr.cached_spirv_path, err }),
            };

            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.cached_spirv_path);
        }
        // Clear metadata
        self.cache_metadata.clearAndFree();
        self.cache_mutex.unlock();
    }

    /// Remove a single cache entry (invalidate cached SPIR-V for a given key)
    pub fn removeCacheEntry(self: *Self, key: []const u8) !void {
        self.cache_mutex.lock();
        if (self.cache_metadata.fetchRemove(key)) |entry| {
            // Remove entry while holding lock, then unlock before file ops
            self.cache_mutex.unlock();
            std.fs.cwd().deleteFile(entry.value.cached_spirv_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.log.warn("Failed to delete cached file {s}: {}", .{ entry.value.cached_spirv_path, err }),
            };

            // Free memory used by stored strings
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.cached_spirv_path);
            return; // we've unlocked and finished
        }
        self.cache_mutex.unlock();
    }

    pub fn getCacheStats(self: *Self) CacheStats {
        return CacheStats{
            .total_cached_shaders = @intCast(self.cache_metadata.count()),
            .cache_directory = self.cache_dir,
        };
    }

    // Private helper functions

    fn calculateFileHash(self: *Self, file_path: []const u8) !u64 {
        const file_content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 16 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read file for hashing: {s}", .{file_path});
            return err;
        };
        defer self.allocator.free(file_content);

        // Use a simple but effective hash
        return std.hash_map.hashString(file_content);
    }

    fn calculateOptionsHash(self: *Self, options: ShaderCompiler.CompilationOptions) u64 {
        _ = self;

        // Create a simple hash of compilation options to detect changes
        var hasher = std.hash.Wyhash.init(0);

        // Hash the target
        hasher.update(std.mem.asBytes(&options.target));

        // Hash optimization level
        hasher.update(std.mem.asBytes(&options.optimization_level));

        // Hash vulkan semantics flag
        hasher.update(std.mem.asBytes(&options.vulkan_semantics));

        return hasher.final();
    }

    fn generateCachePath(self: *Self, source_path: []const u8) ![]const u8 {
        // Convert source path to cache filename
        // e.g., "shaders/simple.vert" -> "shaders/cached/simple.vert.spv"

        const basename = std.fs.path.basename(source_path);
        const cache_filename = try std.fmt.allocPrint(self.allocator, "{s}.spv", .{basename});
        defer self.allocator.free(cache_filename);

        return try std.fs.path.join(self.allocator, &[_][]const u8{ self.cache_dir, cache_filename });
    }

    fn generateSourceCachePath(self: *Self, identifier: []const u8, stage: ShaderCompiler.ShaderStage) ![]const u8 {
        // Generate cache path for inline shader source
        // e.g., "my_shader" + vertex -> "shaders/cached/my_shader.vert.spv"

        const stage_ext = switch (stage) {
            .vertex => "vert",
            .fragment => "frag",
            .compute => "comp",
            .geometry => "geom",
            .tessellation_control => "tesc",
            .tessellation_evaluation => "tese",
            .raygen => "rgen",
            .any_hit => "rahit",
            .closest_hit => "rchit",
            .miss => "rmiss",
            .intersection => "rint",
            .callable => "rcall",
        };

        const cache_filename = try std.fmt.allocPrint(self.allocator, "{s}.{s}.spv", .{ identifier, stage_ext });
        defer self.allocator.free(cache_filename);

        return try std.fs.path.join(self.allocator, &[_][]const u8{ self.cache_dir, cache_filename });
    }

    fn saveSpirvToCache(self: *Self, spirv_data: []const u8, cache_path: []const u8) !void {
        _ = self;

        // Ensure the cache directory exists
        const cache_dir_path = std.fs.path.dirname(cache_path) orelse return error.InvalidCachePath;
        std.fs.cwd().makePath(cache_dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK
            else => return err,
        };

        // Write SPIR-V data to cache file
        try std.fs.cwd().writeFile(.{ .sub_path = cache_path, .data = spirv_data });
    }

    fn loadCachedSpirv(self: *Self, compiler: *ShaderCompiler.ShaderCompiler, cache_path: []const u8, expected_hash: u64) !ShaderCompiler.CompiledShader {
        const spirv_data = std.fs.cwd().readFileAlloc(self.allocator, cache_path, 16 * 1024 * 1024) catch |err| {
            std.log.warn("Failed to load cached SPIR-V from {s}: {}", .{ cache_path, err });
            return err;
        };
        // Use the compiler to parse words and generate reflection
        const spirv_bytes = spirv_data; // already read using self.allocator

        // parseSpirv expects a byte slice; it returns allocated u32 words owned by compiler. Use that to generate reflection.
        const reflection = try compiler.generateReflectionFromSpirv(spirv_bytes);

        // Duplicate the raw SPIR-V bytes into the cache allocator so ownership is consistent
        const spirv_owned = try self.allocator.dupe(u8, spirv_bytes);

        return ShaderCompiler.CompiledShader{
            .spirv_code = spirv_owned,
            .reflection = reflection,
            .source_hash = expected_hash,
        };
    }

    fn loadCacheMetadata(self: *Self) !void {
        const metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.cache_dir, "cache_metadata.json" });
        defer self.allocator.free(metadata_path);

        const metadata_content = std.fs.cwd().readFileAlloc(self.allocator, metadata_path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                return; // No existing metadata, that's fine
            },
            else => return err,
        };
        defer self.allocator.free(metadata_content);

        // Parse JSON metadata
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, metadata_content, .{}) catch |err| {
            std.log.warn("Failed to parse cache metadata JSON: {}, starting fresh", .{err});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            std.log.warn("Cache metadata root is not an object, starting fresh", .{});
            return;
        }

        const entries = root.object.get("entries") orelse {
            std.log.warn("Cache metadata missing 'entries' field, starting fresh", .{});
            return;
        };

        if (entries != .object) {
            std.log.warn("Cache metadata 'entries' is not an object, starting fresh", .{});
            return;
        }

        // Load each cache entry
        var entry_iterator = entries.object.iterator();
        while (entry_iterator.next()) |entry| {
            const shader_id = entry.key_ptr.*;
            const entry_obj = entry.value_ptr.*;

            if (entry_obj != .object) continue;

            const cached_path = entry_obj.object.get("cached_spirv_path");
            const file_hash = entry_obj.object.get("file_hash");
            const options_hash = entry_obj.object.get("options_hash");
            const compile_time = entry_obj.object.get("compile_time");

            if (cached_path != null and cached_path.? == .string and
                file_hash != null and file_hash.? == .string and
                options_hash != null and options_hash.? == .string and
                compile_time != null and compile_time.? == .integer)
            {
                const parsed_file_hash = std.fmt.parseInt(u64, file_hash.?.string, 10) catch {
                    std.log.debug("Failed to parse file_hash for {s}", .{shader_id});
                    continue;
                };
                const parsed_options_hash = std.fmt.parseInt(u64, options_hash.?.string, 10) catch {
                    std.log.debug("Failed to parse options_hash for {s}", .{shader_id});
                    continue;
                };

                const cache_entry = CacheEntry{
                    .cached_spirv_path = try self.allocator.dupe(u8, cached_path.?.string),
                    .file_hash = parsed_file_hash,
                    .options_hash = parsed_options_hash,
                    .compile_time = compile_time.?.integer,
                };

                // Verify the cached SPIR-V file still exists
                std.fs.cwd().access(cache_entry.cached_spirv_path, .{}) catch {
                    std.log.debug("Cached SPIR-V file no longer exists: {s}", .{cache_entry.cached_spirv_path});
                    self.allocator.free(cache_entry.cached_spirv_path);
                    continue;
                };

                const key = try self.allocator.dupe(u8, shader_id);
                try self.cache_metadata.put(key, cache_entry);
            }
        }
    }

    fn saveCacheMetadata(self: *Self) !void {
        const metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.cache_dir, "cache_metadata.json" });
        defer self.allocator.free(metadata_path);

        // Ensure cache directory exists
        std.fs.cwd().makePath(self.cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK
            else => return err,
        };

        // Create JSON manually to avoid API compatibility issues
        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(self.allocator);

        try buffer.appendSlice(self.allocator, "{\n  \"version\": 1,\n  \"entries\": {\n");

        var json_cache_iterator = self.cache_metadata.iterator();
        var first = true;
        while (json_cache_iterator.next()) |entry| {
            if (!first) try buffer.appendSlice(self.allocator, ",\n");
            first = false;

            const entry_json = try std.fmt.allocPrint(self.allocator, "    \"{s}\": {{\n      \"cached_spirv_path\": \"{s}\",\n      \"file_hash\": \"{d}\",\n      \"options_hash\": \"{d}\",\n      \"compile_time\": {d}\n    }}", .{ entry.key_ptr.*, entry.value_ptr.cached_spirv_path, entry.value_ptr.file_hash, entry.value_ptr.options_hash, entry.value_ptr.compile_time });
            defer self.allocator.free(entry_json);
            try buffer.appendSlice(self.allocator, entry_json);
        }

        try buffer.appendSlice(self.allocator, "\n  }\n}");

        // Write to file
        try std.fs.cwd().writeFile(.{ .sub_path = metadata_path, .data = buffer.items });
    }
};

// Supporting types

pub const CacheEntry = struct {
    cached_spirv_path: []const u8,
    file_hash: u64,
    options_hash: u64,
    compile_time: i64,
};

pub const CacheStats = struct {
    total_cached_shaders: u32,
    cache_directory: []const u8,
};

// Tests
test "ShaderCache basic operations" {
    const allocator = std.testing.allocator;

    var cache = try ShaderCache.init(allocator, "test_cache");
    defer cache.deinit();

    const stats = cache.getCacheStats();
    try std.testing.expect(stats.total_cached_shaders == 0);
}
