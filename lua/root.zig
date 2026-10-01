//! Whirlpool's Lua standard library, embedded so every Lua state (the
//! configuration, the layout, each surface) resolves it identically and no
//! search path is involved.

pub const Module = struct { name: []const u8, source: []const u8 };

pub const modules = [_]Module{
    .{ .name = "whirlpool", .source = @embedFile("whirlpool/init.lua") },
    .{ .name = "whirlpool.surface", .source = @embedFile("whirlpool/surface.lua") },
    .{ .name = "whirlpool.format", .source = @embedFile("whirlpool/format.lua") },
    .{ .name = "whirlpool.series", .source = @embedFile("whirlpool/series.lua") },
    .{ .name = "whirlpool.pointer", .source = @embedFile("whirlpool/pointer.lua") },
    .{ .name = "whirlpool.scroll", .source = @embedFile("whirlpool/scroll.lua") },
};
