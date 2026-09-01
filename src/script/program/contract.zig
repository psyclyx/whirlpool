//! Data-only contract shared by program loading and Lua execution.

pub const Limits = struct {
    max_module_bytes: usize = 256 * 1024,
    max_modules: usize = 64,
    max_module_name_bytes: usize = 128,
    max_operations: usize = 16 * 1024,
    max_property_bytes: usize = 4096,
    max_property_items: usize = 64,
    max_property_depth: usize = 4,
};

pub const Module = struct {
    name: []const u8,
    source: []const u8,
};

pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
};

pub const NodeKind = enum {
    row,
    column,
    stack,
    spacer,
    shape,
    polygon,
    text,
    icon,
};

pub const NodeId = u32;

pub const Update = struct {
    service: []const u8,
    values: []const Value = &.{},
};

/// A host implements this structural operation sink for retained programs.
pub const Sink = struct {
    context: ?*anyopaque = null,
    begin: *const fn (?*anyopaque) anyerror!void,
    create: *const fn (?*anyopaque, NodeId, NodeKind, ?NodeId) anyerror!void,
    set: *const fn (?*anyopaque, NodeId, []const u8, Value) anyerror!void,
    finish: *const fn (?*anyopaque) anyerror!void,
};
