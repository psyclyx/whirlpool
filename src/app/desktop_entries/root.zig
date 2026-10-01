//! Asynchronous application-id to desktop entry resolution: an application's
//! human name and icon file, as its desktop entry gives them.
//!
//! Requests only touch bounded in-memory state. A single `std.Io` producer
//! reads desktop entries and probes icon themes away from Wayland and Lua
//! callbacks, then publishes what it found for retained surfaces.
//!
//! Lookups search the session's XDG data directories and, given the
//! window's process, that process's own: the Nix store path its executable
//! is in, and the XDG_DATA_DIRS it was started with. So an application run
//! from a nix-shell or with `nix run` is still found.

const std = @import("std");

pub const Wake = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque) void,
};

/// What is known about an application; empty strings where nothing was found.
pub const AppInfo = struct {
    /// The desktop entry's Name ("Ghostty" for com.mitchellh.ghostty).
    name: []const u8 = "",
    /// An icon file path.
    icon: []const u8 = "",
};

const Entry = struct {
    info: AppInfo = .{},
    ready: bool = false,
    /// The process whose own data directories the last lookup also searched.
    pid: ?i32 = null,

    fn free(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.info.name.len != 0) allocator.free(self.info.name);
        if (self.info.icon.len != 0) allocator.free(self.info.icon);
        self.info = .{};
    }
};

const Request = struct { app_id: []const u8, pid: ?i32 };

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    queue: std.ArrayList(Request) = .empty,
    wake: ?Wake = null,
    /// How many lookups have finished; changes as each does.
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
            item.value_ptr.free(self.allocator);
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

    /// What is known about `app_id` so far, copied into `arena`; unknown parts
    /// are empty while a non-blocking lookup is queued. `pid`, the window's
    /// process when known, lets the lookup also search that process's own data
    /// directories (an app started from a nix-shell, say). A lookup that found
    /// no icon is tried again for a window of another process.
    pub fn lookup(self: *Service, arena: std.mem.Allocator, app_id: []const u8, pid: ?i32) !AppInfo {
        if (app_id.len == 0) return .{};
        self.lock();
        defer self.unlock();
        if (self.entries.getEntry(app_id)) |found| {
            const entry = found.value_ptr;
            if (!entry.ready) return .{};
            if (entry.info.icon.len == 0 and pid != null and !std.meta.eql(pid, entry.pid)) {
                entry.ready = false;
                entry.pid = pid;
                try self.queue.append(self.allocator, .{ .app_id = found.key_ptr.*, .pid = pid });
                self.changed.signal(self.io);
            }
            return .{ .name = try arena.dupe(u8, entry.info.name), .icon = try arena.dupe(u8, entry.info.icon) };
        }

        const key = try self.allocator.dupe(u8, app_id);
        errdefer self.allocator.free(key);
        try self.entries.put(self.allocator, key, .{ .pid = pid });
        errdefer _ = self.entries.remove(key);
        try self.queue.append(self.allocator, .{ .app_id = key, .pid = pid });
        self.changed.signal(self.io);
        return .{};
    }

    fn workerLoop(self: *Service) std.Io.Cancelable!void {
        while (true) {
            self.lock();
            while (self.queue.items.len == 0)
                self.changed.wait(self.io, &self.mutex) catch |err| {
                    self.unlock();
                    return err;
                };
            const request = self.queue.orderedRemove(0);
            const app_id = request.app_id;
            self.unlock();

            var info = resolve(self.allocator, self.io, app_id, request.pid) catch |err| blk: {
                if (err == error.Canceled) return error.Canceled;
                break :blk AppInfo{};
            };

            self.lock();
            const entry = self.entries.getPtr(app_id) orelse {
                self.unlock();
                var orphan = Entry{ .info = info };
                orphan.free(self.allocator);
                continue;
            };
            // Callers copied what they read under the lock, so replacing it is safe.
            entry.free(self.allocator);
            entry.info = info;
            info = .{};
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

/// Where to look: data directories in XDG order, and icon themes to search in
/// order (the user's GTK theme, what it inherits, then hicolor).
const Search = struct {
    roots: []const []const u8,
    themes: []const []const u8,
};

fn resolve(allocator: std.mem.Allocator, io: std.Io, app_id: []const u8, pid: ?i32) !AppInfo {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var roots = std.ArrayList([]const u8).empty;
    try roots.appendSlice(arena, try dataRoots(arena));
    if (pid) |process| try appendProcessRoots(arena, io, process, &roots);
    const search = Search{ .roots = roots.items, .themes = try themeChain(arena, io, roots.items) };
    return resolveIn(allocator, io, app_id, search);
}

/// An application id to its name and icon: through its desktop entry (named
/// after the id, or claiming it as StartupWMClass) when there is one, else an
/// icon named after the id itself. The result is owned by `allocator`.
fn resolveIn(allocator: std.mem.Allocator, io: std.Io, app_id: []const u8, search: Search) !AppInfo {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var icon: []const u8 = app_id;
    var name: []const u8 = "";
    if (try findDesktopEntry(arena, io, app_id, search.roots)) |contents| {
        if (desktopKey(contents, "Icon")) |named| icon = named;
        if (desktopKey(contents, "Name")) |named| name = named;
    }
    const found = try findIconFile(arena, io, icon, search) orelse "";
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    return .{ .name = owned_name, .icon = try allocator.dupe(u8, found) };
}

/// The contents of the desktop entry for `app_id`: `<id>.desktop` (or its
/// lowercase form), else whichever entry names it as its StartupWMClass.
fn findDesktopEntry(arena: std.mem.Allocator, io: std.Io, app_id: []const u8, roots: []const []const u8) !?[]u8 {
    const names = [_][]const u8{
        try std.mem.concat(arena, u8, &.{ app_id, ".desktop" }),
        try std.mem.concat(arena, u8, &.{ try std.ascii.allocLowerString(arena, app_id), ".desktop" }),
    };
    for (names) |name| for (roots) |root| {
        const path = try std.fs.path.join(arena, &.{ root, "applications", name });
        if (readSmall(arena, io, path)) |contents| return contents;
    };
    for (roots) |root| {
        const directory = try std.fs.path.join(arena, &.{ root, "applications" });
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var entries = dir.iterate();
        while (entries.next(io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;
            const contents = readSmall(arena, io, try std.fs.path.join(arena, &.{ directory, entry.name })) orelse continue;
            const class = desktopKey(contents, "StartupWMClass") orelse continue;
            if (std.ascii.eqlIgnoreCase(class, app_id)) return contents;
        }
    }
    return null;
}

fn readSmall(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch null;
}

const image_extensions = [_][]const u8{ ".svg", ".png", ".xpm" };
/// Sizes to try, best for a ~20-40px bar icon first.
const icon_sizes = [_][]const u8{ "scalable", "32x32", "48x48", "64x64", "24x24", "128x128", "256x256", "22x22", "16x16", "512x512", "1024x1024" };

/// An icon by name (or path): in each theme in order, at each size, in
/// either directory layout (`<size>/apps` or `apps/<size>`), then pixmaps.
/// Names are often reverse-DNS (`com.example.App`): only a real image
/// extension counts as one.
fn findIconFile(arena: std.mem.Allocator, io: std.Io, icon: []const u8, search: Search) !?[]const u8 {
    if (std.fs.path.isAbsolute(icon)) return if (exists(io, icon)) icon else null;
    const given = for (image_extensions) |extension| {
        if (std.ascii.endsWithIgnoreCase(icon, extension)) break true;
    } else false;
    const extensions: []const []const u8 = if (given) &.{""} else &image_extensions;
    for (search.themes) |theme| for (icon_sizes) |size| for (extensions) |extension| {
        const file = try std.mem.concat(arena, u8, &.{ icon, extension });
        for (search.roots) |root| {
            for ([_][2][]const u8{ .{ size, "apps" }, .{ "apps", size } }) |layout| {
                const path = try std.fs.path.join(arena, &.{ root, "icons", theme, layout[0], layout[1], file });
                if (exists(io, path)) return path;
            }
        }
    };
    for (extensions) |extension| {
        const file = try std.mem.concat(arena, u8, &.{ icon, extension });
        for (search.roots) |root| {
            const path = try std.fs.path.join(arena, &.{ root, "pixmaps", file });
            if (exists(io, path)) return path;
        }
    }
    return null;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A process's own data directories, after `roots` (skipping repeats): the
/// `XDG_DATA_DIRS` it was started with, and the `share` directory of the Nix
/// store path its executable is in. That is how an application run from a
/// nix-shell or `nix run` finds its desktop entry and icons.
fn appendProcessRoots(arena: std.mem.Allocator, io: std.Io, pid: i32, roots: *std.ArrayList([]const u8)) !void {
    var candidates = std.ArrayList([]const u8).empty;
    const environ_path = try std.fmt.allocPrint(arena, "/proc/{d}/environ", .{pid});
    if (readStream(arena, io, environ_path)) |environ| {
        var dirs = std.mem.tokenizeScalar(u8, environValue(environ, "XDG_DATA_DIRS") orelse "", ':');
        while (dirs.next()) |dir| try candidates.append(arena, dir);
    } else |_| {}
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fmt.allocPrint(arena, "/proc/{d}/exe", .{pid});
    if (std.Io.Dir.cwd().readLink(io, exe_path, &link_buffer)) |length| {
        if (storePath(link_buffer[0..length])) |store| try candidates.append(arena, try std.fs.path.join(arena, &.{ store, "share" }));
    } else |_| {}
    for (candidates.items) |candidate| {
        for (roots.items) |root| {
            if (std.mem.eql(u8, root, candidate)) break;
        } else try roots.append(arena, try arena.dupe(u8, candidate));
    }
}

/// A variable's value in a `/proc/<pid>/environ` block (NUL-separated).
fn environValue(environ: []const u8, name: []const u8) ?[]const u8 {
    var variables = std.mem.splitScalar(u8, environ, 0);
    while (variables.next()) |variable| {
        if (variable.len > name.len and std.mem.startsWith(u8, variable, name) and variable[name.len] == '=')
            return variable[name.len + 1 ..];
    }
    return null;
}

/// A whole file read until its end: `/proc` files report a size of zero, so
/// reads that trust the size see nothing.
fn readStream(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(1024 * 1024));
}

/// `/nix/store/<hash>-<name>` for a path inside the Nix store.
fn storePath(path: []const u8) ?[]const u8 {
    const prefix = "/nix/store/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const end = std.mem.indexOfScalarPos(u8, path, prefix.len, '/') orelse path.len;
    return path[0..end];
}

/// XDG data directories, most specific first.
fn dataRoots(arena: std.mem.Allocator) ![]const []const u8 {
    var roots = std.ArrayList([]const u8).empty;
    if (environment("XDG_DATA_HOME")) |root| {
        try roots.append(arena, root);
    } else if (environment("HOME")) |home| {
        try roots.append(arena, try std.fs.path.join(arena, &.{ home, ".local", "share" }));
    }
    var dirs = std.mem.tokenizeScalar(u8, environment("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", ':');
    while (dirs.next()) |root| try roots.append(arena, root);
    return roots.items;
}

/// The user's GTK icon theme, the themes it inherits (by its index.theme),
/// and hicolor, the fallback every theme ends in.
fn themeChain(arena: std.mem.Allocator, io: std.Io, roots: []const []const u8) ![]const []const u8 {
    var chain = std.ArrayList([]const u8).empty;
    var pending = std.ArrayList([]const u8).empty;
    if (try gtkIconTheme(arena, io)) |theme| try pending.append(arena, theme);
    while (pending.items.len > 0 and chain.items.len < 8) {
        const theme = pending.orderedRemove(0);
        for (chain.items) |seen| {
            if (std.mem.eql(u8, seen, theme)) break;
        } else {
            try chain.append(arena, theme);
            for (roots) |root| {
                const index = readSmall(arena, io, try std.fs.path.join(arena, &.{ root, "icons", theme, "index.theme" })) orelse continue;
                var parents = std.mem.tokenizeScalar(u8, iniValue(index, "Icon Theme", "Inherits") orelse "", ',');
                while (parents.next()) |parent| try pending.append(arena, std.mem.trim(u8, parent, " "));
                break;
            }
        }
    }
    for (chain.items) |theme| {
        if (std.mem.eql(u8, theme, "hicolor")) break;
    } else try chain.append(arena, "hicolor");
    return chain.items;
}

/// `gtk-icon-theme-name` from GTK's settings.ini, as GTK applications use.
fn gtkIconTheme(arena: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const config_home = environment("XDG_CONFIG_HOME") orelse blk: {
        const home = environment("HOME") orelse return null;
        break :blk try std.fs.path.join(arena, &.{ home, ".config" });
    };
    for ([_][]const u8{ "gtk-4.0", "gtk-3.0" }) |version| {
        const settings = readSmall(arena, io, try std.fs.path.join(arena, &.{ config_home, version, "settings.ini" })) orelse continue;
        if (iniValue(settings, "Settings", "gtk-icon-theme-name")) |name| return name;
    }
    return null;
}

/// `key`'s value in `[section]` of an ini-style file (desktop entries,
/// index.theme, settings.ini).
fn iniValue(contents: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_section = line.len >= 2 and std.mem.eql(u8, line[1 .. line.len - 1], section);
            continue;
        }
        if (!in_section) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equals], " \t"), key)) continue;
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t\"");
        return if (value.len == 0) null else value;
    }
    return null;
}

fn desktopKey(contents: []const u8, key: []const u8) ?[]const u8 {
    return iniValue(contents, "Desktop Entry", key);
}

fn environment(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "desktop icon parser only accepts the main desktop entry" {
    const source =
        "[Desktop Action New]\nIcon=wrong\n" ++
        "[Desktop Entry]\nName=Example\nIcon=org.example.App\n";
    try std.testing.expectEqualStrings("org.example.App", desktopKey(source, "Icon").?);
}

/// A scratch XDG data directory with the given files (contents are names).
const Fixture = struct {
    dir: std.testing.TmpDir,
    root: [:0]u8,

    fn init(files: []const []const u8) !Fixture {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        for (files) |file| {
            const separator = std.mem.indexOfScalar(u8, file, '=');
            const path = if (separator) |index| file[0..index] else file;
            if (std.fs.path.dirname(path)) |parent| try dir.dir.createDirPath(std.testing.io, parent);
            try dir.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = if (separator) |index| file[index + 1 ..] else "x" });
        }
        const root = try dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .dir = dir, .root = root };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.root);
        self.dir.cleanup();
    }

    fn resolve(self: *const Fixture, app_id: []const u8, themes: []const []const u8) !AppInfo {
        return resolveIn(std.testing.allocator, std.testing.io, app_id, .{ .roots = &.{self.root}, .themes = themes });
    }

    fn free(info: AppInfo) void {
        var entry = Entry{ .info = info };
        entry.free(std.testing.allocator);
    }
};

test "reverse-DNS icon names are names, not files with an extension" {
    var fixture = try Fixture.init(&.{
        "applications/com.mitchellh.ghostty.desktop=[Desktop Entry]\nName=Ghostty\nIcon=com.mitchellh.ghostty\n[Desktop Action new-window]\nName=New Window\n",
        "icons/hicolor/32x32/apps/com.mitchellh.ghostty.png",
    });
    defer fixture.deinit();
    const info = try fixture.resolve("com.mitchellh.ghostty", &.{"hicolor"});
    defer Fixture.free(info);
    try std.testing.expect(std.mem.endsWith(u8, info.icon, "icons/hicolor/32x32/apps/com.mitchellh.ghostty.png"));
    // The application's name, not an action's.
    try std.testing.expectEqualStrings("Ghostty", info.name);
}

test "an entry claiming the app id as its window class supplies the icon" {
    var fixture = try Fixture.init(&.{
        "applications/signal.desktop=[Desktop Entry]\nStartupWMClass=Signal\nIcon=signal-desktop\n",
        "icons/hicolor/48x48/apps/signal-desktop.png",
    });
    defer fixture.deinit();
    const info = try fixture.resolve("signal", &.{"hicolor"});
    defer Fixture.free(info);
    try std.testing.expect(std.mem.endsWith(u8, info.icon, "signal-desktop.png"));
}

test "without an entry, an icon named after the app id is used, themes first" {
    var fixture = try Fixture.init(&.{
        "icons/Papirus/64x64/apps/foot.svg",
        "icons/hicolor/scalable/apps/foot.svg",
    });
    defer fixture.deinit();
    const info = try fixture.resolve("foot", &.{ "Papirus", "hicolor" });
    defer Fixture.free(info);
    try std.testing.expect(std.mem.endsWith(u8, info.icon, "icons/Papirus/64x64/apps/foot.svg"));
}

test "ini values are read from their own section" {
    const index = "[Icon Theme]\nName=Papirus\nInherits=breeze,hicolor\n[16x16/apps]\nInherits=nope\n";
    try std.testing.expectEqualStrings("breeze,hicolor", iniValue(index, "Icon Theme", "Inherits").?);
}

test "a store path is the package an executable belongs to" {
    try std.testing.expectEqualStrings("/nix/store/abc-ghostty-1.3.1", storePath("/nix/store/abc-ghostty-1.3.1/bin/.ghostty-wrapped").?);
    try std.testing.expect(storePath("/usr/bin/foot") == null);
}

test "a process's XDG_DATA_DIRS is read from its environment block" {
    const environ = "HOME=/home/a\x00XDG_DATA_DIRS_X=no\x00XDG_DATA_DIRS=/nix/store/abc-mpv/share:/usr/share\x00";
    try std.testing.expectEqualStrings("/nix/store/abc-mpv/share:/usr/share", environValue(environ, "XDG_DATA_DIRS").?);
    try std.testing.expect(environValue(environ, "PATH") == null);
}
