const std = @import("std");
const EntityId = @import("entity_registry.zig").EntityId;
const DenseSet = @import("dense_set.zig").DenseSet;
const World = @import("world.zig").World;

pub fn QueryIterator(comptime QueryStruct: type) type {
    return struct {
        const Self = @This();

        world: *World,
        // We need to store the storages for each field.
        // Since types are different, we can't store them in a simple array of pointers.
        // But we can store them as *anyopaque and cast them when needed,
        // OR we can use a tuple of typed pointers if we can construct it at comptime.
        // Actually, we can just look them up once in init and store them in a tuple.

        storages: StorageTuple,

        // Iterator state
        main_storage_index: usize,
        current_index: usize,
        count: usize,

        const Fields = std.meta.fields(QueryStruct);

        // Helper to determine component type from pointer type
        fn ComponentType(comptime PtrType: type) type {
            return switch (@typeInfo(PtrType)) {
                .pointer => |ptr| ptr.child,
                .optional => |opt| ComponentType(opt.child),
                else => @compileError("Query fields must be pointers or optional pointers"),
            };
        }

        // Helper to determine if field is optional
        fn IsOptional(comptime PtrType: type) bool {
            if (PtrType == EntityId) return false;
            return @typeInfo(PtrType) == .optional;
        }

        // Tuple type to hold pointers to DenseSet(T) for each field
        const StorageTuple = blk: {
            var types: [Fields.len]type = undefined;
            for (Fields, 0..) |field, i| {
                if (field.type == EntityId) {
                    types[i] = void;
                } else {
                    const CompT = ComponentType(field.type);
                    if (IsOptional(field.type)) {
                        types[i] = ?*DenseSet(CompT);
                    } else {
                        types[i] = *DenseSet(CompT);
                    }
                }
            }
            break :blk std.meta.Tuple(&types);
        };

        pub fn init(world: *World) !Self {
            // Ensure at least one required component exists to drive iteration
            comptime {
                var has_required = false;
                for (Fields) |field| {
                    if (field.type != EntityId and !IsOptional(field.type)) {
                        has_required = true;
                    }
                }
                if (!has_required) {
                    @compileError("Query must have at least one required component (not optional, not EntityId) to drive iteration.");
                }
            }

            var storages: StorageTuple = undefined;
            var min_count: usize = std.math.maxInt(usize);
            var main_idx: usize = 0;

            inline for (Fields, 0..) |field, i| {
                if (field.type == EntityId) {
                    storages[i] = {};
                    continue;
                }

                const CompT = ComponentType(field.type);
                const type_name = @typeName(CompT);

                // Get storage from world
                if (world.storages.get(type_name)) |storage_ptr| {
                    const storage: *DenseSet(CompT) = @ptrCast(@alignCast(storage_ptr));
                    storages[i] = storage;

                    // Find smallest storage to iterate over (optimization)
                    // Only consider non-optional components for the main iterator
                    if (!IsOptional(field.type)) {
                        const len = storage.len();
                        if (len < min_count) {
                            min_count = len;
                            main_idx = i;
                        }
                    }
                } else {
                    // Storage missing
                    if (comptime !IsOptional(field.type)) {
                        return error.ComponentNotRegistered;
                    }
                    storages[i] = null;
                }
            }

            return .{
                .world = world,
                .storages = storages,
                .main_storage_index = main_idx,
                .current_index = 0,
                .count = 0, // Will be set in next() logic or we can't know upfront easily
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn next(self: *Self) ?QueryStruct {
            // We need to access the main storage to iterate
            // We can't do `self.storages[self.main_storage_index]` at runtime because types differ.
            // We need to switch on main_storage_index or use a homogenous array of opaque pointers if we only needed entities.
            // But we have the tuple.

            // To iterate, we need the list of entities from the main storage.
            // We can get that by iterating `current_index`.

            // We need a way to get "entity at index i" from "storage at index main_idx".

            while (true) {
                var entity: EntityId = .invalid;
                var valid_index = false;

                // 1. Get candidate entity from main storage
                inline for (Fields, 0..) |field, i| {
                    if (field.type != EntityId) {
                        if (i == self.main_storage_index) {
                            const storage_maybe = self.storages[i];
                            switch (@typeInfo(@TypeOf(storage_maybe))) {
                                .optional => {},
                                else => {
                                    const storage = storage_maybe;
                                    if (self.current_index < storage.entities.items.len) {
                                        entity = storage.entities.items[self.current_index];
                                        valid_index = true;
                                    }
                                },
                            }
                        }
                    }
                }

                if (!valid_index) return null; // End of main storage
                self.current_index += 1;

                // 2. Check if entity exists in all other REQUIRED storages
                var all_present = true;
                inline for (Fields, 0..) |field, i| {
                    if (field.type == EntityId) continue;
                    if (i != self.main_storage_index) {
                        const storage_maybe = self.storages[i];
                        switch (@typeInfo(@TypeOf(storage_maybe))) {
                            .optional => {}, // Skip optional
                            else => {
                                const storage = storage_maybe;
                                if (!storage.has(entity)) {
                                    all_present = false;
                                }
                            }
                        }
                    }
                }

                if (!all_present) continue; // Try next entity

                // 3. Construct result
                var result: QueryStruct = undefined;

                inline for (Fields, 0..) |field, i| {
                    if (field.type == EntityId) {
                        @field(result, field.name) = entity;
                    } else {
                        if (comptime IsOptional(field.type)) {
                            // Optional: try get
                            if (self.storages[i]) |storage| {
                                if (storage.getMut(entity)) |ptr| {
                                    @field(result, field.name) = ptr;
                                } else {
                                    @field(result, field.name) = null;
                                }
                            } else {
                                @field(result, field.name) = null;
                            }
                        } else {
                            // Required: must exist (we checked)
                            const storage = self.storages[i];
                            if (storage.getMut(entity)) |ptr| {
                                @field(result, field.name) = ptr;
                            } else {
                                unreachable;
                            }
                        }
                    }
                }

                return result;
            }
        }
    };
}
