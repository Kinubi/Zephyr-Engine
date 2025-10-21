const DenseSet = @import("component_dense_set.zig").DenseSet;

pub fn View(comptime T: type) type {
    return struct {
        ents: []usize,
        comps: []T,

        pub fn init(ents: []usize, comps: []T) View(T) {
            return View(T){ .ents = ents, .comps = comps };
        }

        pub fn each(self: *View(T), callback: fn (usize, *T) void) void {
            var i: usize = 0;
            while (i < self.comps.len) : (i += 1) {
                callback(self.ents[i], &self.comps[i]);
            }
        }
    };
}
