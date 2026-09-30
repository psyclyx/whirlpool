//! Atomic commands over compositor resources and flat workspace membership.

const ids = @import("ids.zig");
const types = @import("types.zig");

pub const Focus = union(enum) { window: ids.WindowId, output: ids.OutputId, clear };
pub const Tag = union(enum) {
    activate: struct { output: ids.OutputId, tag: ids.TagId },
    toggle: struct { output: ids.OutputId, tag: ids.TagId },
    rename: struct { tag: ids.TagId, name: []const u8 },
    remove: ids.TagId,
};
pub const Output = union(enum) {
    update: struct {
        output: ids.OutputId,
        active_tag: ids.TagId,
        bounds: types.Rect,
        usable: types.Rect,
        configuration: types.OutputConfig = .{},
    },
    configure: struct { output: ids.OutputId, configuration: types.OutputConfig },
    remove: ids.OutputId,
};
pub const Window = union(enum) {
    assign: struct { window: ids.WindowId, tag: ids.TagId },
    set_placement: struct { window: ids.WindowId, placement: types.Placement },
    transition_placement: struct { window: ids.WindowId, transition: types.PlacementTransition },
    set_floating_geometry: struct { window: ids.WindowId, geometry: types.Rect },
    update_sizing: struct {
        window: ids.WindowId,
        hints: types.SizeHints,
        actual: ?types.Size,
        proposed: ?types.Size,
    },
    set_transient: struct { window: ids.WindowId, transient: bool },
    manage: ids.WindowId,
    begin_close: ids.WindowId,
    destroy: ids.WindowId,
};
pub const Command = union(enum) { focus: Focus, tag: Tag, output: Output, window: Window };
pub const Batch = []const Command;

test "commands expose only resource-level effects" {
    const window = ids.WindowId.fromParts(2, 1);
    const tag = ids.TagId.fromParts(3, 1);
    const value: Command = .{ .window = .{ .assign = .{ .window = window, .tag = tag } } };
    try @import("std").testing.expectEqual(window, value.window.assign.window);
}
