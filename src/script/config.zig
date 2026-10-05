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
const wm = @import("whirlpool-wm");
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
pub const MaxSources: usize = 32;

pub const SurfaceSpec = struct {
    name: []u8,
    provider: []u8,
    role: []u8,
    placement: []u8,
    /// With placement "mark": the name of the layout marks it is drawn on.
    /// Empty otherwise.
    mark: []u8,
    /// Lua source that mounts the surface: requires its content module and
    /// calls it with its options.
    content: []u8,
    edge: []u8,
    height: u32 = 0,
    /// For an all-outputs shell: its width, centred on the output (0: the
    /// output's width), and its distance from `edge`. With height 0 it is
    /// as tall as the output.
    width: u32 = 0,
    margin: u32 = 0,
    /// Whether the pointer interacts with it (false: it passes through).
    input: bool = true,
    exclusive_zone: u32 = 0,
    /// Where `content` finds modules (a `package.path`); borrowed from the
    /// owning `Config`.
    module_path: []const u8 = "",

    pub fn deinit(self: *SurfaceSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.edge);
        allocator.free(self.mark);
        allocator.free(self.placement);
        allocator.free(self.role);
        allocator.free(self.provider);
        allocator.free(self.name);
        self.* = undefined;
    }
};

/// A periodically sampled measurement; see `whirlpool.source`.
pub const SourceSpec = struct {
    name: []u8,
    kind: []u8,
    every_ms: u32,
    keep_ms: u32,
    argv: [][]u8,

    pub fn deinit(self: *SourceSpec, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.kind);
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
    sources: []SourceSpec,
    /// Lua source producing the layout controller.
    layout_source: []u8,
    /// Where every Lua state finds modules (a `package.path`).
    module_path: []u8,

    pub fn deinit(self: *Config) void {
        for (self.bindings) |*binding| binding.deinit(self.allocator);
        self.allocator.free(self.bindings);
        for (self.surfaces) |*descriptor| descriptor.deinit(self.allocator);
        self.allocator.free(self.surfaces);
        for (self.sources) |*source| source.deinit(self.allocator);
        self.allocator.free(self.sources);
        self.allocator.free(self.layout_source);
        self.allocator.free(self.module_path);
        self.* = undefined;
    }

    /// The surface for `provider` and `role`, other than one drawn on marks.
    /// The `provider` shell surfaces placed on every output, in the order
    /// they were registered (later ones stack above earlier ones), at most
    /// `out.len`.
    pub fn outputShells(self: *const Config, provider: []const u8, out: []*const SurfaceSpec) []*const SurfaceSpec {
        var count: usize = 0;
        for (self.surfaces) |*candidate| {
            if (count == out.len) break;
            if (!std.mem.eql(u8, candidate.provider, provider) or !std.mem.eql(u8, candidate.role, "shell")) continue;
            if (!std.mem.eql(u8, candidate.placement, "all-outputs")) continue;
            out[count] = candidate;
            count += 1;
        }
        return out[0..count];
    }

    pub fn surface(self: *const Config, provider: []const u8, role: []const u8) ?*const SurfaceSpec {
        for (self.surfaces) |*candidate| {
            if (candidate.mark.len != 0) continue;
            if (std.mem.eql(u8, candidate.provider, provider) and std.mem.eql(u8, candidate.role, role))
                return candidate;
        }
        return null;
    }

    /// The `provider` surface drawn on layout marks named `mark`.
    pub fn markSurface(self: *const Config, provider: []const u8, mark: []const u8) ?*const SurfaceSpec {
        for (self.surfaces) |*candidate| {
            if (std.mem.eql(u8, candidate.provider, provider) and std.mem.eql(u8, candidate.mark, mark))
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
    InvalidSources,
    MissingStandardLibrary,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error!Config {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MaxConfigBytes)) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConfigLoadFailed,
        };
    };
    defer allocator.free(source);
    const module_path = try modules.defaultSearchPath(allocator, io, path);
    errdefer allocator.free(module_path);
    return loadSource(allocator, source, module_path);
}

/// Run a configuration's source, finding modules on `module_path`. Takes
/// ownership of `module_path` (allocated with `allocator`) on success.
pub fn loadSource(allocator: std.mem.Allocator, source: []const u8, module_path: []u8) Error!Config {
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try modules.install(&vm, module_path);
    // A configuration is usually itself `whirlpool.lua`; if the standard
    // library were missing, `require("whirlpool")` would find it instead.
    vm.run(
        \\local found = package.searchpath("whirlpool", package.path)
        \\assert(found and found:match("whirlpool[/\\]init%.lua$"),
        \\  "the whirlpool standard library is not on the module path: " .. package.path)
    , "=whirlpool.stdlib") catch return error.MissingStandardLibrary;
    try vm.runReporting(source, "=whirlpool.config");
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
    for (surfaces) |*surface| surface.module_path = module_path;
    vm.setTop(1);

    vm.getField(-1, "sources");
    const sources = try parseSources(allocator, &vm);
    errdefer {
        for (sources) |*item| item.deinit(allocator);
        allocator.free(sources);
    }
    vm.setTop(1);

    vm.getField(-1, "bindings");
    const bindings = try binding_config.parse(allocator, &vm);
    vm.setTop(0);
    return .{
        .allocator = allocator,
        .bindings = bindings,
        .surfaces = surfaces,
        .sources = sources,
        .layout_source = layout_source,
        .module_path = module_path,
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
pub fn surfaceEntry(allocator: std.mem.Allocator, module: []const u8, options: []const u8) Error![]u8 {
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

fn parseSources(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error![]SourceSpec {
    if (vm.luaType(-1) != .table) return error.InvalidSources;
    const count = vm.rawLength(-1);
    if (count > MaxSources) return error.InvalidSources;
    const sources = try allocator.alloc(SourceSpec, count);
    var initialized: usize = 0;
    errdefer {
        for (sources[0..initialized]) |*source| source.deinit(allocator);
        allocator.free(sources);
    }
    while (initialized < count) : (initialized += 1) {
        vm.rawGetInteger(-1, @intCast(initialized + 1));
        if (vm.luaType(-1) != .table) return error.InvalidSources;
        const base: c_int = @intCast(vm.stackDepth());
        const name = try dupeField(allocator, vm, base, "name", error.InvalidSources);
        errdefer allocator.free(name);
        const kind = try dupeField(allocator, vm, base, "kind", error.InvalidSources);
        errdefer allocator.free(kind);
        const every_ms = optionalU32Field(vm, base, "every") catch return error.InvalidSources;
        const keep_ms = optionalU32Field(vm, base, "keep") catch return error.InvalidSources;
        vm.getField(-1, "command");
        const argv = try stringList(allocator, vm);
        vm.setTop(base);
        sources[initialized] = .{ .name = name, .kind = kind, .every_ms = every_ms, .keep_ms = keep_ms, .argv = argv };
        vm.setTop(2);
    }
    return sources;
}

/// A list of strings at the top of the stack (nil is empty).
fn stringList(allocator: std.mem.Allocator, vm: *lua_vm.Vm) Error![][]u8 {
    if (vm.luaType(-1) == .nil) return allocator.alloc([]u8, 0);
    if (vm.luaType(-1) != .table) return error.InvalidSources;
    const count = vm.rawLength(-1);
    if (count > MaxArguments) return error.InvalidSources;
    const list = try allocator.alloc([]u8, count);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |item| allocator.free(item);
        allocator.free(list);
    }
    while (filled < count) : (filled += 1) {
        vm.rawGetInteger(-1, @intCast(filled + 1));
        const item = vm.string(-1) orelse return error.InvalidSources;
        list[filled] = try allocator.dupe(u8, item);
        vm.setTop(-2);
    }
    return list;
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
        // One surface per provider and role, except that every output can
        // have several shells (a bar, a popup): those are told apart by name.
        const current = &surfaces[initialized];
        const several = std.mem.eql(u8, current.role, "shell") and std.mem.eql(u8, current.placement, "all-outputs");
        for (surfaces[0..initialized]) |previous| {
            if (std.mem.eql(u8, previous.provider, current.provider) and
                std.mem.eql(u8, previous.role, current.role) and
                std.mem.eql(u8, previous.mark, current.mark) and
                (!several or !std.mem.eql(u8, previous.placement, current.placement)))
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
    const mark = try dupeOptionalField(allocator, vm, base, "mark", "");
    errdefer allocator.free(mark);
    // A mark names where the surface goes, so only a mark surface has one.
    if ((mark.len != 0) != std.mem.eql(u8, placement, "mark")) return error.InvalidSurface;
    if (mark.len > wm.layout.Mark.Name.max_len) return error.InvalidSurface;
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
    const width = try optionalU32Field(vm, base, "width");
    const margin = try optionalU32Field(vm, base, "margin");
    const exclusive_zone = try optionalU32Field(vm, base, "exclusive_zone");
    vm.getField(-1, "input");
    const input = if (vm.luaType(-1) == .nil) true else vm.boolean(-1) orelse {
        vm.setTop(base);
        return error.InvalidSurface;
    };
    vm.setTop(base);
    if (!std.mem.eql(u8, edge, "top") and !std.mem.eql(u8, edge, "bottom")) return error.InvalidSurface;
    return .{
        .name = name,
        .provider = provider,
        .role = role,
        .placement = placement,
        .mark = mark,
        .content = content,
        .edge = edge,
        .height = height,
        .width = width,
        .margin = margin,
        .input = input,
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
    , try allocator.dupe(u8, modules.source_tree_path));
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
    var vm = try lua_vm.Vm.init(true);
    defer vm.deinit();
    try modules.install(&vm, modules.source_tree_path);
    try std.testing.expectEqual(@as(i64, 1), try vm.evalInteger(
        \\local wp = require("whirlpool")
        \\local ok = pcall(wp.serialize, { callback = print })
        \\local data = wp.serialize({ 1, "two", { three = true } })
        \\return (not ok and data == '{[1]=1,[2]="two",[3]={["three"]=true}}') and 1 or 0
    , "=test"));
}

test "the example configuration loads" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "config/whirlpool.lua", std.testing.allocator, .limited(MaxConfigBytes));
    defer std.testing.allocator.free(source);
    var config = try loadSource(std.testing.allocator, source, try std.testing.allocator.dupe(u8, modules.source_tree_path));
    defer config.deinit();
    try std.testing.expect(config.bindings.len > 50);
    try std.testing.expectEqualStrings("all-outputs", config.surface("river", "shell").?.placement);
    try std.testing.expect(config.surface("river", "decoration") != null);
    try std.testing.expect(config.markSurface("river", "drop") != null);
}

test "a surface drawn on marks sits beside the shell, and a mark means placement \"mark\"" {
    const allocator = std.testing.allocator;
    var config = try loadSource(allocator,
        \\local wp = require("whirlpool")
        \\wp.layout("lib.tiles")
        \\wp.surface("bar", { provider = "river", role = "shell", placement = "all-outputs", content = "lib.bar" })
        \\wp.surface("drop", { provider = "river", role = "shell", placement = "mark", mark = "drop", content = "lib.drop" })
    , try allocator.dupe(u8, modules.source_tree_path));
    defer config.deinit();
    try std.testing.expectEqualStrings("bar", config.surface("river", "shell").?.name);
    try std.testing.expectEqualStrings("drop", config.markSurface("river", "drop").?.name);
    try std.testing.expectEqual(@as(?*const SurfaceSpec, null), config.markSurface("river", "other"));

    try expectRefused(
        \\local wp = require("whirlpool")
        \\wp.layout("lib.tiles")
        \\wp.surface("drop", { provider = "river", role = "shell", placement = "all-outputs", mark = "drop", content = "lib.drop" })
    );
    try expectRefused(
        \\local wp = require("whirlpool")
        \\wp.layout("lib.tiles")
        \\wp.surface("drop", { provider = "river", role = "shell", placement = "mark", content = "lib.drop" })
    );
}

fn expectRefused(source: []const u8) !void {
    const allocator = std.testing.allocator;
    // `loadSource` owns the module path only once it succeeds.
    const module_path = try allocator.dupe(u8, modules.source_tree_path);
    if (loadSource(allocator, source, module_path)) |loaded| {
        var config = loaded;
        config.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        allocator.free(module_path);
        try std.testing.expectEqual(error.InvalidSurface, err);
    }
}
