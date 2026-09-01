//! User-facing Lua program configuration.
//!
//! This is intentionally a small, typed extraction boundary. Lua constructs
//! the program table; native providers receive copied policy and surface
//! descriptors, never compositor handles or borrowed Lua values.

const std = @import("std");
const lua_vm = @import("lua_vm.zig");
const binding_config = @import("config/bindings.zig");

pub const MaxConfigBytes: usize = 256 * 1024;
pub const MaxBindings = binding_config.MaxBindings;
pub const MaxArguments = binding_config.MaxArguments;
pub const default_mode = binding_config.default_mode;
pub const MaxSurfaces: usize = 64;
pub const MaxSurfaceSourceBytes: usize = 256 * 1024;
pub const MaxLayoutSourceBytes: usize = 256 * 1024;

pub const SurfaceSpec = struct {
    provider: []u8,
    role: []u8,
    placement: []u8,
    content: []u8,
    edge: []u8,
    height: u32 = 0,
    exclusive_zone: u32 = 0,

    pub fn deinit(self: *SurfaceSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.edge);
        allocator.free(self.placement);
        allocator.free(self.role);
        allocator.free(self.provider);
        self.* = undefined;
    }
};

pub const Action = binding_config.Action;
pub const Binding = binding_config.Binding;

pub const Config = struct {
    allocator: std.mem.Allocator,
    bindings: []Binding,
    surfaces: []SurfaceSpec,
    layout_source: []u8,

    pub fn deinit(self: *Config) void {
        for (self.bindings) |*binding| binding.deinit(self.allocator);
        self.allocator.free(self.bindings);
        for (self.surfaces) |*descriptor| descriptor.deinit(self.allocator);
        self.allocator.free(self.surfaces);
        self.allocator.free(self.layout_source);
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

pub const Error = std.mem.Allocator.Error || lua_vm.Error || binding_config.Error || error{
    ConfigTooLarge,
    ConfigLoadFailed,
    InvalidProgram,
    InvalidApiVersion,
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

    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try vm.evalValue(source, "=whirlpool.config");
    defer vm.setTop(0);
    if (vm.luaType(-1) != .table) return error.InvalidProgram;

    vm.getField(-1, "api_version");
    const api_version = vm.integer(-1) orelse return error.InvalidApiVersion;
    if (api_version != 1) return error.InvalidApiVersion;
    vm.setTop(1);

    vm.getField(-1, "layout");
    const layout_source = try loadLayoutSource(allocator, io, path, &vm);
    errdefer allocator.free(layout_source);
    vm.setTop(1);

    vm.getField(-1, "surfaces");
    const surfaces = try parseSurfaces(allocator, &vm);
    errdefer {
        for (surfaces) |*surface| surface.deinit(allocator);
        allocator.free(surfaces);
    }
    vm.setTop(1);

    vm.getField(-1, "bindings");
    const bindings = try binding_config.parse(allocator, &vm);
    vm.setTop(0);
    return .{ .allocator = allocator, .bindings = bindings, .surfaces = surfaces, .layout_source = layout_source };
}

fn loadLayoutSource(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8, vm: *lua_vm.Vm) Error![]u8 {
    const module = vm.string(-1) orelse return error.InvalidLayout;
    if (module.len == 0) return error.InvalidLayout;
    const path = if (std.fs.path.isAbsolute(module))
        try allocator.dupe(u8, module)
    else
        try std.fs.path.join(allocator, &.{ std.fs.path.dirname(config_path) orelse ".", module });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MaxLayoutSourceBytes)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidLayout,
    };
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
    const provider = try dupeField(allocator, vm, base, "provider", error.InvalidSurface);
    errdefer allocator.free(provider);
    const role = try dupeField(allocator, vm, base, "role", error.InvalidSurface);
    errdefer allocator.free(role);
    const placement = try dupeField(allocator, vm, base, "placement", error.InvalidSurface);
    errdefer allocator.free(placement);
    const content = try dupeField(allocator, vm, base, "content", error.InvalidContent);
    errdefer allocator.free(content);
    const edge = try dupeOptionalField(allocator, vm, base, "edge", "top");
    errdefer allocator.free(edge);
    if (content.len > MaxSurfaceSourceBytes) return error.InvalidContent;
    const height = try optionalU32Field(vm, base, "height");
    const exclusive_zone = try optionalU32Field(vm, base, "exclusive_zone");
    if (!std.mem.eql(u8, edge, "top") and !std.mem.eql(u8, edge, "bottom")) return error.InvalidSurface;
    return .{
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

test "loads the declarative binding shape" {
    const source =
        "return { api_version = 1, bindings = {" ++
        "{ key = 'h', modifiers = {'alt'}, action = { name = 'focus-left', args = {} } }" ++
        "} }";
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try vm.evalValue(source, "=config-test");
    try std.testing.expectEqual(lua_vm.Vm.LuaType.table, vm.luaType(-1));
}

test "generic surface descriptors own provider placement and content" {
    const source =
        \\return { surfaces = {{
        \\  provider = 'river', role = 'shell', placement = 'all-outputs',
        \\  content = 'return function(parent) return {} end',
        \\}} }
    ;
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try vm.evalValue(source, "=surface-config-test");
    vm.getField(-1, "surfaces");
    const surfaces = try parseSurfaces(std.testing.allocator, &vm);
    defer {
        for (surfaces) |*surface| surface.deinit(std.testing.allocator);
        std.testing.allocator.free(surfaces);
    }

    try std.testing.expectEqual(@as(usize, 1), surfaces.len);
    try std.testing.expectEqualStrings("river", surfaces[0].provider);
    try std.testing.expectEqualStrings("shell", surfaces[0].role);
    try std.testing.expectEqualStrings("all-outputs", surfaces[0].placement);
    try std.testing.expectEqualStrings("return function(parent) return {} end", surfaces[0].content);
    try std.testing.expectEqualStrings("top", surfaces[0].edge);
}
