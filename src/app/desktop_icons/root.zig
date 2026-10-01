//! Asynchronous application-id to desktop icon resolution.
//!
//! Requests only touch bounded in-memory state. A single `std.Io` producer
//! reads desktop entries and probes the hicolor theme away from Wayland and
//! Lua callbacks, then publishes stable icon paths for retained surfaces.

const std = @import("std");

pub const Wake = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque) void,
};

const Entry = struct {
    path: []u8 = &.{},
    ready: bool = false,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    queue: std.ArrayList([]const u8) = .empty,
    wake: ?Wake = null,
    /// How many icons have been looked up so far; changes as lookups finish.
    resolved: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io };
        errdefer self.group.cancel(io);
        try self.group.concurrent(io, workerLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Service) void {
        self.group.cancel(self.io);
        var iterator = self.entries.iterator();
        while (iterator.next()) |item| {
            self.allocator.free(item.key_ptr.*);
            if (item.value_ptr.path.len != 0) self.allocator.free(item.value_ptr.path);
        }
        self.entries.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn setWake(self: *Service, wake: Wake) void {
        self.lock();
        self.wake = wake;
        self.unlock();
    }

    pub fn clearWake(self: *Service) void {
        self.lock();
        self.wake = null;
        self.unlock();
    }

    /// Return a stable resolved path or queue one non-blocking lookup.
    pub fn pathFor(self: *Service, app_id: []const u8) ![]const u8 {
        if (app_id.len == 0) return &.{};
        self.lock();
        defer self.unlock();
        if (self.entries.get(app_id)) |entry| return if (entry.ready) entry.path else &.{};

        const key = try self.allocator.dupe(u8, app_id);
        errdefer self.allocator.free(key);
        try self.entries.put(self.allocator, key, .{});
        errdefer _ = self.entries.remove(key);
        try self.queue.append(self.allocator, key);
        self.changed.signal(self.io);
        return &.{};
    }

    fn workerLoop(self: *Service) std.Io.Cancelable!void {
        while (true) {
            self.lock();
            while (self.queue.items.len == 0)
                self.changed.wait(self.io, &self.mutex) catch |err| {
                    self.unlock();
                    return err;
                };
            const app_id = self.queue.orderedRemove(0);
            self.unlock();

            const path = resolve(self.allocator, self.io, app_id) catch |err| blk: {
                if (err == error.Canceled) return error.Canceled;
                break :blk @as([]u8, &.{});
            };

            self.lock();
            const entry = self.entries.getPtr(app_id) orelse {
                self.unlock();
                if (path.len != 0) self.allocator.free(path);
                continue;
            };
            entry.path = path;
            entry.ready = true;
            self.resolved +%= 1;
            const wake = self.wake;
            self.unlock();
            if (wake) |callback| callback.run(callback.context);
        }
    }

    pub fn resolvedCount(self: *Service) u64 {
        self.lock();
        defer self.unlock();
        return self.resolved;
    }

    fn lock(self: *Service) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Service) void {
        self.mutex.unlock(self.io);
    }
};

fn resolve(allocator: std.mem.Allocator, io: std.Io, app_id: []const u8) ![]u8 {
    const desktop = try findDesktopFile(allocator, io, app_id) orelse return &.{};
    defer allocator.free(desktop);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, desktop, allocator, .limited(1024 * 1024));
    defer allocator.free(contents);
    const icon = desktopIcon(contents) orelse return &.{};
    return try findIconFile(allocator, io, icon) orelse &.{};
}

fn findDesktopFile(allocator: std.mem.Allocator, io: std.Io, app_id: []const u8) !?[]u8 {
    const filename = if (std.mem.endsWith(u8, app_id, ".desktop"))
        try allocator.dupe(u8, app_id)
    else
        try std.mem.concat(allocator, u8, &.{ app_id, ".desktop" });
    defer allocator.free(filename);
    if (try findDataFile(allocator, io, &.{ "applications", filename })) |path| return path;

    const lowercase = try std.ascii.allocLowerString(allocator, filename);
    defer allocator.free(lowercase);
    if (!std.mem.eql(u8, lowercase, filename))
        return try findDataFile(allocator, io, &.{ "applications", lowercase });
    return null;
}

fn findIconFile(allocator: std.mem.Allocator, io: std.Io, icon: []const u8) !?[]u8 {
    if (std.fs.path.isAbsolute(icon)) return if (try existingOwned(allocator, io, icon)) |path| path else null;

    const sizes = [_][]const u8{ "24x24", "22x22", "32x32", "16x16", "48x48", "64x64", "128x128", "scalable" };
    const extensions = if (std.fs.path.extension(icon).len == 0)
        [_][]const u8{ ".png", ".svg", ".xpm" }
    else
        [_][]const u8{ "", "", "" };
    for (sizes) |size| for (extensions) |extension| {
        if (extension.len == 0 and std.fs.path.extension(icon).len == 0) continue;
        const filename = try std.mem.concat(allocator, u8, &.{ icon, extension });
        defer allocator.free(filename);
        if (try findDataFile(allocator, io, &.{ "icons", "hicolor", size, "apps", filename })) |path| return path;
    };
    if (try findDataFile(allocator, io, &.{ "pixmaps", icon })) |path| return path;
    if (std.fs.path.extension(icon).len == 0) for (extensions) |extension| {
        const filename = try std.mem.concat(allocator, u8, &.{ icon, extension });
        defer allocator.free(filename);
        if (try findDataFile(allocator, io, &.{ "pixmaps", filename })) |path| return path;
    };
    return null;
}

fn findDataFile(allocator: std.mem.Allocator, io: std.Io, suffix: []const []const u8) !?[]u8 {
    if (environment("XDG_DATA_HOME")) |root| {
        if (try existingJoined(allocator, io, root, suffix)) |path| return path;
    } else if (environment("HOME")) |home| {
        const root = try std.fs.path.join(allocator, &.{ home, ".local", "share" });
        defer allocator.free(root);
        if (try existingJoined(allocator, io, root, suffix)) |path| return path;
    }

    const roots = environment("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var iterator = std.mem.splitScalar(u8, roots, ':');
    while (iterator.next()) |root| {
        if (root.len == 0) continue;
        if (try existingJoined(allocator, io, root, suffix)) |path| return path;
    }
    return null;
}

fn existingJoined(allocator: std.mem.Allocator, io: std.Io, root: []const u8, suffix: []const []const u8) !?[]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, root);
    try parts.appendSlice(allocator, suffix);
    const path = try std.fs.path.join(allocator, parts.items);
    return existingPath(allocator, io, path);
}

fn existingOwned(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return existingPath(allocator, io, try allocator.dupe(u8, path));
}

fn existingPath(allocator: std.mem.Allocator, io: std.Io, path: []u8) !?[]u8 {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(path);
            return null;
        },
        else => {
            allocator.free(path);
            return err;
        },
    };
    return path;
}

fn environment(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn desktopIcon(contents: []const u8) ?[]const u8 {
    var in_desktop_entry = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_desktop_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (in_desktop_entry and std.mem.startsWith(u8, line, "Icon=")) {
            const value = std.mem.trim(u8, line[5..], " \t");
            return if (value.len == 0) null else value;
        }
    }
    return null;
}

test "desktop icon parser only accepts the main desktop entry" {
    const source =
        "[Desktop Action New]\nIcon=wrong\n" ++
        "[Desktop Entry]\nName=Example\nIcon=org.example.App\n";
    try std.testing.expectEqualStrings("org.example.App", desktopIcon(source).?);
}
