//! User-facing Lua configuration.
//!
//! A configuration is a Lua file that registers bindings, a layout and
//! surfaces through `require("whirlpool")`; see `lua/whirlpool/init.lua`. This
//! is the typed extraction boundary: native providers receive copied policy and
//! surface descriptors, never compositor handles or borrowed Lua values.
//!
//! Modules beside the configuration file (`lib/bar.lua` is `lib.bar`) are read
//! here, once, and handed to every Lua state that needs them.

const std = @import("std");
const lua_vm = @import("lua_vm.zig");
const binding_config = @import("config/bindings.zig");
pub const modules = @import("modules.zig");

pub const MaxConfigBytes: usize = 256 * 1024;
pub const MaxBindings = binding_config.MaxBindings;
pub const MaxArguments = binding_config.MaxArguments;
pub const default_mode = binding_config.default_mode;
pub const MaxSurfaces: usize = 64;
pub const MaxSurfaceSourceBytes: usize = 256 * 1024;
pub const MaxLayoutSourceBytes: usize = 256 * 1024;
pub const MaxOptionsBytes: usize = 64 * 1024;

pub const SurfaceSpec = struct {
    name: []u8,
    provider: []u8,
    role: []u8,
    placement: []u8,
    /// Lua source that mounts the surface: requires its content module and
    /// calls it with its options.
    content: []u8,
    edge: []u8,
    height: u32 = 0,
    exclusive_zone: u32 = 0,
    /// The modules `content` may require; borrowed from the owning `Config`.
    modules: []const modules.Module = &.{},

    pub fn deinit(self: *SurfaceSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.edge);
        allocator.free(self.placement);
        allocator.free(self.role);
        allocator.free(self.provider);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Action = binding_config.Action;
pub const Binding = binding_config.Binding;

pub const Config = struct {
    allocator: std.mem.Allocator,
    bindings: []Binding,
    surfaces: []SurfaceSpec,
    /// Lua source producing the layout controller.
    layout_source: []u8,
    modules: modules.Set,

    pub fn deinit(self: *Config) void {
        for (self.bindings) |*binding| binding.deinit(self.allocator);
        self.allocator.free(self.bindings);
        for (self.surfaces) |*descriptor| descriptor.deinit(self.allocator);
        self.allocator.free(self.surfaces);
        self.allocator.free(self.layout_source);
        self.modules.deinit();
        self.* = undefined;
    }

    pub fn surface(self: *const Config, provider: []const u8, role: []const u8) ?*const SurfaceSpec {
        for (self.surfaces) |*candidate| {
            if (std.mem.eql(u8, candidate.provider, provider) and std.mem.eql(u8, candidate.role, role))
                return candidate;
        }
        return null;
    }
};

pub const Error = std.mem.Allocator.Error || lua_vm.Error || binding_config.Error || modules.Error || error{
    ConfigTooLarge,
    ConfigLoadFailed,
    InvalidProgram,
    InvalidLayout,
    InvalidSurfaces,
    InvalidSurface,
    DuplicateSurface,
    TooManySurfaces,
    InvalidContent,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error!Config {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MaxConfigBytes)) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConfigLoadFailed,
        };
    };
    defer allocator.free(source);
    var set = try modules.collect(allocator, io, std.fs.path.dirname(path) orelse ".");
    errdefer set.deinit();
    return loadSource(allocator, source, set);
}

/// Run a configuration's source with `set` as its modules. Takes ownership of
/// `set` on success.
pub fn loadSource(allocator: std.mem.Allocator, source: []const u8, set: modules.Set) Error!Config {
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try modules.install(&vm, set.modules);
    try vm.run(source, "=whirlpool.config");
    try vm.evalValue("return require('whirlpool')._build()", "=whirlpool.build");
    defer vm.setTop(0);
    if (vm.luaType(-1) != .table) return error.InvalidProgram;

    vm.getField(-1, "layout");
    const layout_source = try layoutEntry(allocator, &vm);
    errdefer allocator.free(layout_source);
    vm.setTop(1);

    vm.getField(-1, "surfaces");
    const surfaces = try parseSurfaces(allocator, &vm);
    errdefer {
        for (surfaces) |*surface| surface.deinit(allocator);
        allocator.free(surfaces);
    }
    for (surfaces) |*surface| surface.modules = set.modules;
    vm.setTop(1);

    vm.getField(-1, "bindings");
    const bindings = try binding_config.parse(allocator, &vm);
    vm.setTop(0);
    return .{
        .allocator = allocator,
        .bindings = bindings,
        .surfaces = surfaces,
        .layout_source = layout_source,
        .modules = set,
    };
}

/// `{ module = "lib.scrolling", options = "<lua literal>" }` as the layout
/// state's provider chunk.
fn layoutEntry(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error![]u8 {
    if (vm.luaType(-1) != .table) return error.InvalidLayout;
    const base: c_int = @intCast(vm.stackDepth());
    vm.getField(-1, "module");
    const module = vm.string(-1) orelse return error.InvalidLayout;
    if (!validModuleName(module)) return error.InvalidLayout;
    vm.getField(base, "options");
    const options = vm.string(-1) orelse return error.InvalidLayout;
    if (options.len > MaxOptionsBytes) return error.InvalidLayout;
    defer vm.setTop(base);
    return std.fmt.allocPrint(allocator,
        \\local provider = require("{s}")
        \\if type(provider) == "table" and type(provider.new) == "function" then
        \\  provider = provider.new({s})
        \\end
        \\return provider
    , .{ module, options });
}

/// The surface state's entry: mount the content module with its options and
/// route service updates to it (a returned controller's `update`, and the
/// handlers it registered with `whirlpool.surface`).
fn surfaceEntry(allocator: std.mem.Allocator, module: []const u8, options: []const u8) Error![]u8 {
    if (!validModuleName(module)) return error.InvalidContent;
    if (options.len > MaxOptionsBytes) return error.InvalidContent;
    return std.fmt.allocPrint(allocator,
        \\local surface = require("whirlpool.surface")
        \\local main = require("{s}")
        \\return function(root)
        \\  local controller = main(root, {s})
        \\  return {{ update = function(_, service, values)
        \\    if type(controller) == "table" and controller.update then controller:update(service, values) end
        \\    surface.dispatch(service, values)
        \\  end }}
        \\end
    , .{ module, options });
}

/// Module names come from file paths: letters, digits, `_`, `-` and dots.
fn validModuleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

fn parseSurfaces(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error![]SurfaceSpec {
    if (vm.luaType(-1) != .table) return error.InvalidSurfaces;
    const count = vm.rawLength(-1);
    if (count > MaxSurfaces) return error.TooManySurfaces;
    const surfaces = try allocator.alloc(SurfaceSpec, count);
    var initialized: usize = 0;
    errdefer {
        for (surfaces[0..initialized]) |*surface| surface.deinit(allocator);
        allocator.free(surfaces);
    }
    while (initialized < count) : (initialized += 1) {
        vm.rawGetInteger(-1, @intCast(initialized + 1));
        surfaces[initialized] = try parseSurface(allocator, vm);
        vm.setTop(2);
        for (surfaces[0..initialized]) |previous| {
            if (std.mem.eql(u8, previous.provider, surfaces[initialized].provider) and
                std.mem.eql(u8, previous.role, surfaces[initialized].role))
                return error.DuplicateSurface;
        }
    }
    return surfaces;
}

fn parseSurface(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error!SurfaceSpec {
    if (vm.luaType(-1) != .table) return error.InvalidSurface;
    const base: c_int = @intCast(vm.stackDepth());
    const name = try dupeField(allocator, vm, base, "name", error.InvalidSurface);
    errdefer allocator.free(name);
    const provider = try dupeField(allocator, vm, base, "provider", error.InvalidSurface);
    errdefer allocator.free(provider);
    const role = try dupeField(allocator, vm, base, "role", error.InvalidSurface);
    errdefer allocator.free(role);
    const placement = try dupeField(allocator, vm, base, "placement", error.InvalidSurface);
    errdefer allocator.free(placement);
    const module = try dupeField(allocator, vm, base, "content", error.InvalidContent);
    defer allocator.free(module);
    const options = try dupeOptionalField(allocator, vm, base, "options", "{}");
    defer allocator.free(options);
    const content = try surfaceEntry(allocator, module, options);
    errdefer allocator.free(content);
    const edge = try dupeOptionalField(allocator, vm, base, "edge", "top");
    errdefer allocator.free(edge);
    if (content.len > MaxSurfaceSourceBytes) return error.InvalidContent;
    const height = try optionalU32Field(vm, base, "height");
    const exclusive_zone = try optionalU32Field(vm, base, "exclusive_zone");
    if (!std.mem.eql(u8, edge, "top") and !std.mem.eql(u8, edge, "bottom")) return error.InvalidSurface;
    return .{
        .name = name,
        .provider = provider,
        .role = role,
        .placement = placement,
        .content = content,
        .edge = edge,
        .height = height,
        .exclusive_zone = exclusive_zone,
    };
}

fn dupeField(allocator: std.mem.Allocator, vm: *lua_vm.Vm, base: c_int, comptime name: [:0]const u8, failure: Error) Error![]u8 {
    vm.getField(-1, name);
    defer vm.setTop(base);
    const value = vm.string(-1) orelse return failure;
    if (value.len == 0) return failure;
    return allocator.dupe(u8, value);
}

fn dupeOptionalField(allocator: std.mem.Allocator, vm: *lua_vm.Vm, base: c_int, comptime name: [:0]const u8, fallback: []const u8) Error![]u8 {
    vm.getField(-1, name);
    defer vm.setTop(base);
    if (vm.luaType(-1) == .nil) return allocator.dupe(u8, fallback);
    const value = vm.string(-1) orelse return error.InvalidSurface;
    if (value.len == 0) return error.InvalidSurface;
    return allocator.dupe(u8, value);
}

fn optionalU32Field(vm: *lua_vm.Vm, base: c_int, comptime name: [:0]const u8) Error!u32 {
    vm.getField(-1, name);
    defer vm.setTop(base);
    if (vm.luaType(-1) == .nil) return 0;
    const value = vm.integer(-1) orelse return error.InvalidSurface;
    if (value < 0 or value > std.math.maxInt(u32)) return error.InvalidSurface;
    return @intCast(value);
}

test "registrations are keyed: a later one replaces an earlier one, nil removes it" {
    const allocator = std.testing.allocator;
    var config = try loadSource(allocator,
        \\local wp = require("whirlpool")
        \\wp.layout("lib.tiles", { gap = 4 })
        \\wp.bind({ "super" }, "Return", wp.spawn("foot"))
        \\wp.bind({ "super" }, "d", wp.spawn("fuzzel"))
        \\wp.bind({ "super" }, "Return", wp.spawn("alacritty"))
        \\wp.bind({ "super" }, "d", nil)
        \\wp.surface("bar", { provider = "river", role = "shell", placement = "all-outputs",
        \\  content = "lib.bar", options = { compact = true } })
        \\wp.surface("old", { provider = "layer-shell", role = "shell", placement = "default-output",
        \\  content = "lib.old" })
        \\wp.surface("old", nil)
    , try modules.Set.standard(allocator));
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.bindings.len);
    try std.testing.expectEqualStrings("alacritty", config.bindings[0].action.spawn[0]);
    try std.testing.expectEqual(@as(usize, 1), config.surfaces.len);
    try std.testing.expectEqualStrings("bar", config.surfaces[0].name);
    try std.testing.expect(std.mem.indexOf(u8, config.surfaces[0].content, "require(\"lib.bar\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.surfaces[0].content, "[\"compact\"]=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.layout_source, "provider.new({[\"gap\"]=4})") != null);
}

test "options must be plain data" {
    var set = try modules.Set.standard(std.testing.allocator);
    defer set.deinit();
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try modules.install(&vm, set.modules);
    try std.testing.expectEqual(@as(i64, 1), try vm.evalInteger(
        \\local wp = require("whirlpool")
        \\local ok = pcall(wp.serialize, { callback = print })
        \\local data = wp.serialize({ 1, "two", { three = true } })
        \\return (not ok and data == '{[1]=1,[2]="two",[3]={["three"]=true}}') and 1 or 0
    , "=test"));
}

test "the example configuration loads" {
    var config = try load(std.testing.allocator, std.testing.io, "config/whirlpool.lua");
    defer config.deinit();
    try std.testing.expect(config.bindings.len > 50);
    try std.testing.expect(config.surface("river", "shell") != null);
    try std.testing.expect(config.surface("river", "decoration") != null);
}
