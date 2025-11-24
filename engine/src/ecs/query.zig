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
            return @typeInfo(PtrType) == .optional;
        }

        // Tuple type to hold pointers to DenseSet(T) for each field
        const StorageTuple = blk: {
            var types: [Fields.len]type = undefined;
            for (Fields, 0..) |field, i| {
                const CompT = ComponentType(field.type);
                types[i] = *DenseSet(CompT);
            }
            break :blk std.meta.Tuple(&types);
        };

        pub fn init(world: *World) !Self {
            var storages: StorageTuple = undefined;
            var min_count: usize = std.math.maxInt(usize);
            var main_idx: usize = 0;

            inline for (Fields, 0..) |field, i| {
                const CompT = ComponentType(field.type);
                const type_name = @typeName(CompT);

                // Get storage from world
                const storage_ptr = world.storages.get(type_name) orelse {
                    // If a required component storage doesn't exist, the query is empty (unless it's optional)
                    if (!IsOptional(field.type)) {
                        // For now, if storage is missing, we can't even get the pointer to it.
                        // But wait, if storage is missing, it means no entities have this component.
                        // So if it's required, the query result is empty.
                        // We can handle this by returning an empty iterator or error.
                        // Returning error.ComponentNotRegistered is consistent with View.
                        return error.ComponentNotRegistered;
                    }
                    // If optional and missing, we still need a "null" storage or handle it.
                    // But DenseSet pointer cannot be null in our tuple.
                    // Actually, if it's optional and missing, we can just treat it as always null.
                    // But for simplicity, let's assume all storages exist for now, or fail.
                    // A better approach for optional missing storage:
                    // We can't easily put a null in the tuple if the type is *DenseSet(T).
                    // We might need to change StorageTuple to hold ?*DenseSet(T).
                    return error.ComponentNotRegistered;
                };

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
            }

            // If all fields are optional, we need to pick one.
            // But usually queries have at least one required component.
            // If all are optional, we should probably iterate over all entities in the world?
            // That's expensive. Let's assume at least one required for now or just pick the first one.
            // If min_count is still maxInt, it means all were optional.
            if (min_count == std.math.maxInt(usize)) {
                // Pick the first one (even if optional)
                if (Fields.len > 0) {
                    main_idx = 0;
                    // We need to check len of the first one
                    // But we can't access storages[0] generically easily at runtime without inline loop or switch.
                    // Actually we can using inline for loop to find the one matching main_idx.
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
                inline for (Fields, 0..) |_, i| {
                    if (i == self.main_storage_index) {
                        const storage = self.storages[i];
                        if (self.current_index < storage.entities.items.len) {
                            entity = storage.entities.items[self.current_index];
                            valid_index = true;
                        }
                    }
                }

                if (!valid_index) return null; // End of main storage
                self.current_index += 1;

                // 2. Check if entity exists in all other REQUIRED storages
                var all_present = true;
                inline for (Fields, 0..) |field, i| {
                    if (i != self.main_storage_index and !IsOptional(field.type)) {
                        const storage = self.storages[i];
                        if (!storage.has(entity)) {
                            all_present = false;
                            // break; // Can't break inline loop
                        }
                    }
                }

                if (!all_present) continue; // Try next entity

                // 3. Construct result
                var result: QueryStruct = undefined;

                inline for (Fields, 0..) |field, i| {
                    const storage = self.storages[i];
                    switch (@typeInfo(field.type)) {
                        .optional => {
                            // Optional: try get
                            if (storage.getMut(entity)) |ptr| {
                                @field(result, field.name) = ptr;
                            } else {
                                @field(result, field.name) = null;
                            }
                        },
                        else => {
                            // Required: must exist (we checked)
                            if (storage.getMut(entity)) |ptr| {
                                @field(result, field.name) = ptr;
                            } else {
                                unreachable;
                            }
                        },
                    }
                }

                return result;
            }
        }
    };
}
