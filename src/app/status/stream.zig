//! A program that reports by printing lines as things happen (`pactl
//! subscribe`, `nvidia-smi -lms`), read on a source's own task: the task blocks
//! on the pipe, so nothing polls and nothing waits on any other thread.

const std = @import("std");

pub const Error = error{ ReadFailed, StreamTooLong } || std.process.SpawnError || std.Io.Cancelable;

/// Run `argv` and call `context.line(text)` for each line it prints, until it
/// exits (returns normally) or the task is canceled (the program is killed).
/// `line` may return an error to stop early; the program is then killed too.
pub fn lines(io: std.Io, argv: []const []const u8, context: anytype) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            // The pipe read itself says why it failed; cancelation must
            // propagate as such so the task ends.
            error.ReadFailed => return if (reader.err) |cause| switch (cause) {
                error.Canceled => error.Canceled,
                else => error.ReadFailed,
            } else error.ReadFailed,
            error.StreamTooLong => {
                // A line longer than the buffer is no report we understand.
                _ = reader.interface.discardDelimiterInclusive('\n') catch return error.ReadFailed;
                continue;
            },
        } orelse return;
        try context.line(std.mem.trim(u8, line, " \t\r"));
    }
}
