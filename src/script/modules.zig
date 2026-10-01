//! How `require` finds modules: an ordinary Lua `package.path`, the same in
//! every Lua state (the configuration, the layout, each surface).
//!
//! Whirlpool loads one file, the configuration. Everything else is a plain Lua
//! module that it, or the layout and surfaces it names, `require`s on demand:
//! the standard library (`whirlpool`, `whirlpool.*`) first, so nothing beside a
//! configuration can shadow it (a configuration is usually itself called
//! `whirlpool.lua`); then modules beside the configuration (`lib/bar.lua` is
//! `lib.bar`); then the example library this build installs, which a
//! configuration may build on.

const std = @import("std");
const lua_vm = @import("lua_vm.zig");

pub const Error = std.mem.Allocator.Error || error{InvalidModuleRoot};

/// A `package.path` searching `roots` in order, for `?.lua` and `?/init.lua`.
pub fn searchPath(allocator: std.mem.Allocator, roots: []const []const u8) Error![]u8 {
    var path = std.ArrayList(u8).empty;
    errdefer path.deinit(allocator);
    for (roots) |root| {
        // `;` separates templates and `?` is the name placeholder.
        if (root.len == 0 or std.mem.indexOfAny(u8, root, ";?") != null) return error.InvalidModuleRoot;
        if (path.items.len != 0) try path.append(allocator, ';');
        try path.print(allocator, "{s}/?.lua;{s}/?/init.lua", .{ root, root });
    }
    return path.toOwnedSlice(allocator);
}

/// The search path for the configuration at `config_path`, given the prefix
/// this executable is installed in: `<prefix>/share/whirlpool/lua`, the
/// configuration's directory, the directories in `WHIRLPOOL_MODULES` (a
/// colon-separated list, for modules generated outside the configuration,
/// such as a home-manager theme), then `<prefix>/share/whirlpool/config`.
pub fn defaultSearchPath(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Error![]u8 {
    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    var roots = std.ArrayList([]const u8).empty;
    defer roots.deinit(allocator);
    const injected: []const u8 = if (std.c.getenv("WHIRLPOOL_MODULES")) |value| std.mem.span(value) else "";
    const executable_dir = std.process.executableDirPathAlloc(io, allocator) catch {
        try roots.append(allocator, config_dir);
        try appendRoots(allocator, &roots, injected);
        return searchPath(allocator, roots.items);
    };
    defer allocator.free(executable_dir);
    const library = try std.fs.path.join(allocator, &.{ executable_dir, "..", "share", "whirlpool", "lua" });
    defer allocator.free(library);
    const examples = try std.fs.path.join(allocator, &.{ executable_dir, "..", "share", "whirlpool", "config" });
    defer allocator.free(examples);
    try roots.appendSlice(allocator, &.{ library, config_dir });
    try appendRoots(allocator, &roots, injected);
    try roots.append(allocator, examples);
    return searchPath(allocator, roots.items);
}

/// The non-empty entries of a colon-separated directory list.
fn appendRoots(allocator: std.mem.Allocator, roots: *std.ArrayList([]const u8), list: []const u8) Error!void {
    var entries = std.mem.tokenizeScalar(u8, list, ':');
    while (entries.next()) |entry| try roots.append(allocator, entry);
}

/// Set a Lua state's `require` to search `search_path` and nothing else (no
/// native modules).
pub fn install(vm: *lua_vm.Vm, search_path: []const u8) lua_vm.Error!void {
    vm.pushString(search_path);
    vm.setGlobal("whirlpool_module_path");
    try vm.run(
        \\package.path, package.cpath = whirlpool_module_path, ""
        \\whirlpool_module_path = nil
    , "=whirlpool.modules");
}

/// The repository's own layout, for tests and development tools run from it.
pub const source_tree_path = "lua/?.lua;lua/?/init.lua;config/?.lua;config/?/init.lua";

test "require finds modules on the search path, only when asked for" {
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try install(&vm, source_tree_path);
    try std.testing.expectEqual(@as(i64, 1), try vm.evalInteger(
        \\assert(type(require("whirlpool").bind) == "function")
        \\assert(type(require("lib.marks").bind) == "function")
        \\assert(not pcall(require, "lib.nonexistent"))
        \\return package.loaded["lib.bar"] == nil and 1 or 0
    , "=test"));
}

test "search path roots cannot smuggle in Lua path syntax" {
    try std.testing.expectError(error.InvalidModuleRoot, searchPath(std.testing.allocator, &.{"/a;/b"}));
}
