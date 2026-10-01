//! Lua module sources shared by every Lua state: the embedded standard library
//! and the configuration directory's own modules.
//!
//! A configuration's modules are named by their path below the directory that
//! holds the configuration file: `lib/bar.lua` is `lib.bar`, `lib/x/init.lua`
//! is `lib.x`. They are read once, when the configuration loads, so a surface
//! or layout state never touches the file system to resolve `require`.

const std = @import("std");
const lua_vm = @import("lua_vm.zig");
const stdlib = @import("whirlpool-lua-stdlib");

pub const max_modules = 128;
pub const max_module_bytes = 256 * 1024;
/// How deep below the configuration directory modules are looked for.
pub const max_depth = 4;

pub const Module = @import("program/contract.zig").Module;

pub const Error = std.mem.Allocator.Error || error{ TooManyModules, ModuleTooLarge, ModuleUnreadable };

pub const Set = struct {
    allocator: std.mem.Allocator,
    /// Standard library first, then the configuration's, sorted by name.
    modules: []Module,
    /// How many leading `modules` are embedded (and so not owned).
    embedded: usize,

    pub fn deinit(self: *Set) void {
        for (self.modules[self.embedded..]) |module| {
            self.allocator.free(module.name);
            self.allocator.free(module.source);
        }
        self.allocator.free(self.modules);
        self.* = undefined;
    }

    pub fn find(self: *const Set, name: []const u8) ?Module {
        for (self.modules) |module| if (std.mem.eql(u8, module.name, name)) return module;
        return null;
    }

    /// Only the embedded standard library.
    pub fn standard(allocator: std.mem.Allocator) Error!Set {
        return collect(allocator, undefined, null);
    }
};

/// The standard library plus every `.lua` file below `root`. Hidden files and
/// directories are skipped. A configuration module may not reuse a standard
/// library name: `whirlpool.*` always means the installed library.
pub fn collect(allocator: std.mem.Allocator, io: std.Io, root: ?[]const u8) Error!Set {
    var list = std.ArrayList(Module).empty;
    var owned_from: usize = 0;
    errdefer {
        for (list.items[owned_from..]) |module| {
            allocator.free(module.name);
            allocator.free(module.source);
        }
        list.deinit(allocator);
    }
    for (stdlib.modules) |module| try list.append(allocator, .{ .name = module.name, .source = module.source });
    owned_from = list.items.len;

    if (root) |path| collectDirectory(allocator, io, path, &list) catch |err| switch (err) {
        error.OutOfMemory, error.TooManyModules, error.ModuleTooLarge => |e| return e,
        else => return error.ModuleUnreadable,
    };
    const configured = list.items[owned_from..];
    std.mem.sort(Module, configured, {}, struct {
        fn lessThan(_: void, a: Module, b: Module) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return .{ .allocator = allocator, .modules = try list.toOwnedSlice(allocator), .embedded = owned_from };
}

fn collectDirectory(allocator: std.mem.Allocator, io: std.Io, root: []const u8, list: *std.ArrayList(Module)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.basename.len == 0 or entry.basename[0] == '.') {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        if (entry.kind == .directory) {
            if (entry.depth() >= max_depth) walker.leave(io);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".lua")) continue;
        const name = try moduleName(allocator, entry.path);
        errdefer allocator.free(name);
        if (std.mem.eql(u8, name, "whirlpool") or std.mem.startsWith(u8, name, "whirlpool.")) {
            allocator.free(name);
            continue;
        }
        if (list.items.len >= max_modules) return error.TooManyModules;
        const source = entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(max_module_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ModuleTooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ModuleUnreadable,
        };
        errdefer allocator.free(source);
        try list.append(allocator, .{ .name = name, .source = source });
    }
}

/// `lib/bar.lua` -> `lib.bar`; `lib/x/init.lua` -> `lib.x`.
fn moduleName(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var stem = path[0 .. path.len - ".lua".len];
    if (std.mem.endsWith(u8, stem, "/init")) stem = stem[0 .. stem.len - "/init".len];
    const name = try allocator.dupe(u8, stem);
    std.mem.replaceScalar(u8, name, '/', '.');
    std.mem.replaceScalar(u8, name, std.fs.path.sep, '.');
    return name;
}

/// Make `modules` what `require` finds in a full Lua state (the configuration
/// and layout states), and nothing else: no search path is consulted.
pub fn install(vm: *lua_vm.Vm, modules: []const Module) lua_vm.Error!void {
    vm.createTable(0, @intCast(modules.len));
    for (modules) |module| {
        vm.pushString(module.source);
        var name_buffer: [256:0]u8 = undefined;
        if (module.name.len >= name_buffer.len) continue;
        @memcpy(name_buffer[0..module.name.len], module.name);
        name_buffer[module.name.len] = 0;
        vm.setField(-2, name_buffer[0..module.name.len :0]);
    }
    vm.setGlobal("whirlpool_module_sources");
    try vm.run(
        \\local sources = whirlpool_module_sources
        \\whirlpool_module_sources = nil
        \\package.path, package.cpath = "", ""
        \\for name, source in pairs(sources) do
        \\  package.preload[name] = function(...)
        \\    return assert(load(source, "@" .. name:gsub("%.", "/") .. ".lua"))(...)
        \\  end
        \\end
    , "=whirlpool.modules");
}

test "module names follow paths below the configuration directory" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{ .{ "lib/bar.lua", "lib.bar" }, .{ "lib/x/init.lua", "lib.x" }, .{ "top.lua", "top" } };
    for (cases) |case| {
        const name = try moduleName(allocator, case[0]);
        defer allocator.free(name);
        try std.testing.expectEqualStrings(case[1], name);
    }
}

test "the configuration directory's modules are collected beside the standard library" {
    var set = try collect(std.testing.allocator, std.testing.io, "config");
    defer set.deinit();
    try std.testing.expect(set.find("whirlpool") != null);
    try std.testing.expect(set.find("lib.scrolling") != null);
    try std.testing.expect(set.find("lib.bar") != null);
}

test "installed modules are what require finds" {
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try install(&vm, &.{
        .{ .name = "lib.answer", .source = "return { value = 42 }" },
        .{ .name = "lib.user", .source = "return require('lib.answer').value + 1" },
    });
    try std.testing.expectEqual(@as(i64, 43), try vm.evalInteger("return require('lib.user')", "=test"));
}
