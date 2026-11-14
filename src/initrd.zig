const std = @import("std");
const cpio = @import("cpio.zig");
const flate = std.compress.flate;

pub const Names = std.StringHashMap(void);

pub fn gunzip(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_buf: [16384]u8 = undefined;
    var history: [flate.max_window_len]u8 = undefined;
    var buffer: [4096]u8 = undefined;
    var source = file.reader(io, &file_buf);
    var gzip = GzipReader.init(&source.interface, &history, &buffer);
    return gzip.reader.allocRemaining(allocator, .limited(limit)) catch |err| return gzip.failure orelse err;
}

/// Exposes concatenated gzip members as one byte stream, as Go's gzip.Reader does.
const GzipReader = struct {
    source: *std.Io.Reader,
    history: []u8,
    decoder: ?flate.Decompress = null,
    members: usize = 0,
    failure: ?anyerror = null,
    reader: std.Io.Reader,

    fn init(source: *std.Io.Reader, history: []u8, buffer: []u8) GzipReader {
        return .{
            .source = source,
            .history = history,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *GzipReader = @fieldParentPtr("reader", reader);
        while (true) {
            if (self.decoder) |*decoder| {
                return decoder.reader.stream(writer, limit) catch |err| switch (err) {
                    error.EndOfStream => {
                        self.decoder = null;
                        continue;
                    },
                    error.ReadFailed => {
                        self.failure = decoder.err orelse error.ReadFailed;
                        return error.ReadFailed;
                    },
                    error.WriteFailed => return error.WriteFailed,
                };
            }
            _ = self.source.peek(1) catch |err| switch (err) {
                error.EndOfStream => {
                    if (self.members == 0) {
                        self.failure = error.InvalidGzip;
                        return error.ReadFailed;
                    }
                    return error.EndOfStream;
                },
                else => return error.ReadFailed,
            };
            self.decoder = .init(self.source, .gzip, self.history);
            self.members += 1;
        }
    }
};

pub fn appendCpio(io: std.Io, allocator: std.mem.Allocator, gzip_path: []const u8, out_path: []const u8, entries: []const cpio.Entry) !void {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ out_path, std.mem.readInt(u64, &nonce, .little) });
    defer allocator.free(tmp_path);
    const cwd = std.Io.Dir.cwd();
    errdefer cwd.deleteFile(io, tmp_path) catch {};
    {
        const input = try cwd.openFile(io, gzip_path, .{});
        defer input.close(io);
        const output = try cwd.createFile(io, tmp_path, .{ .exclusive = true });
        defer output.close(io);
        var input_buf: [16384]u8 = undefined;
        var output_buf: [16384]u8 = undefined;
        var read_history: [flate.max_window_len]u8 = undefined;
        var write_history: [flate.max_window_len]u8 = undefined;
        var gzip_buf: [4096]u8 = undefined;
        var file_reader = input.reader(io, &input_buf);
        var file_writer = output.writer(io, &output_buf);
        var gzip = GzipReader.init(&file_reader.interface, &read_history, &gzip_buf);
        var compressor = try flate.Compress.init(&file_writer.interface, &write_history, .gzip, .default);
        _ = gzip.reader.streamRemaining(&compressor.writer) catch |err| return gzip.failure orelse err;
        const archive = try cpio.write(allocator, entries);
        defer allocator.free(archive);
        try compressor.writer.writeAll(archive);
        try compressor.finish();
        try file_writer.flush();
        try output.sync(io);
    }
    try cwd.rename(tmp_path, cwd, out_path, io);
}

/// Keys and map storage belong to allocator; callers normally pass an arena.
pub fn names(io: std.Io, allocator: std.mem.Allocator, gzip_path: []const u8) !Names {
    const file = try std.Io.Dir.cwd().openFile(io, gzip_path, .{});
    defer file.close(io);
    var file_buf: [16384]u8 = undefined;
    var history: [flate.max_window_len]u8 = undefined;
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    var gzip = GzipReader.init(&file_reader.interface, &history, &buffer);
    return readNames(allocator, &gzip.reader) catch |err| return gzip.failure orelse err;
}

pub fn readNames(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Names {
    var result = Names.init(allocator);
    while (true) {
        const first = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return result,
            else => return err,
        };
        if (first == 0) continue;
        var header: [110]u8 = undefined;
        header[0] = first;
        reader.readSliceAll(header[1..]) catch |err| return if (err == error.EndOfStream) error.TruncatedCpio else err;
        if (!std.mem.eql(u8, header[0..6], "070701") and !std.mem.eql(u8, header[0..6], "070702")) return error.InvalidCpioMagic;
        const size = std.fmt.parseInt(u32, header[54..62], 16) catch return error.InvalidCpioField;
        const name_size = std.fmt.parseInt(u32, header[94..102], 16) catch return error.InvalidCpioField;
        if (name_size == 0 or name_size > 1 << 20) return error.InvalidCpioName;
        const raw = try allocator.alloc(u8, name_size);
        try reader.readSliceAll(raw);
        if (raw[raw.len - 1] != 0) return error.InvalidCpioName;
        try reader.discardAll(padding(110 + @as(usize, name_size)));
        try reader.discardAll64(@as(u64, size) + padding(size));
        const name = raw[0 .. raw.len - 1];
        if (std.mem.eql(u8, name, "TRAILER!!!")) continue;
        const trimmed = std.mem.trimEnd(u8, name, "/");
        const normalized = if (std.mem.startsWith(u8, trimmed, "./")) trimmed[2..] else trimmed;
        if (normalized.len != 0 and !std.mem.eql(u8, normalized, ".")) try result.put(normalized, {});
    }
}

fn padding(size: usize) usize {
    return (4 - size % 4) % 4;
}

test "cpio names parse concatenated archives and reject invalid data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try cpio.write(a, &.{cpio.file("usr/bin/sshd", 0o755, "sshd")});
    const second = try cpio.write(a, &.{cpio.symlink("usr/lib/libc.so.6", "libc.so.6.1")});
    const combined = try std.mem.concat(a, u8, &.{ first, "\x00\x00", second });
    var reader: std.Io.Reader = .fixed(combined);
    const result = try readNames(a, &reader);
    for ([_][]const u8{ "usr", "usr/bin", "usr/bin/sshd", "usr/lib/libc.so.6" }) |name| try std.testing.expect(result.contains(name));
    try std.testing.expect(!result.contains("TRAILER!!!"));
    var bad: std.Io.Reader = .fixed("not-a-cpio");
    try std.testing.expectError(error.TruncatedCpio, readNames(a, &bad));
}

fn writeGzip(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var file_buf: [4096]u8 = undefined;
    var history: [flate.max_window_len]u8 = undefined;
    var writer = file.writer(io, &file_buf);
    var compressor = try flate.Compress.init(&writer.interface, &history, .gzip, .default);
    try compressor.writer.writeAll(data);
    try compressor.finish();
    try writer.flush();
}

test "gzip initrd append works in place and preserves original members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const gzip_path = try std.fs.path.join(a, &.{ path, "initrd.gz" });
    const archive = try cpio.write(a, &.{cpio.file("original", 0o644, "preserved")});
    try writeGzip(io, gzip_path, archive);
    try appendCpio(io, a, gzip_path, gzip_path, &.{cpio.file("preseed.cfg", 0o644, "preseed")});
    const result = try names(io, a, gzip_path);
    try std.testing.expect(result.contains("original"));
    try std.testing.expect(result.contains("preseed.cfg"));
}

test "concatenated gzip members can split a cpio header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const one = try std.fs.path.join(a, &.{ path, "one.gz" });
    const two = try std.fs.path.join(a, &.{ path, "two.gz" });
    const archive = try cpio.write(a, &.{cpio.file("original", 0o644, "preserved")});
    try writeGzip(io, one, archive[0..45]);
    try writeGzip(io, two, archive[45..]);
    const data1 = try tmp.dir.readFileAlloc(io, "one.gz", a, .limited(8192));
    const data2 = try tmp.dir.readFileAlloc(io, "two.gz", a, .limited(8192));
    try tmp.dir.writeFile(io, .{ .sub_path = "one.gz", .data = try std.mem.concat(a, u8, &.{ data1, data2 }) });
    const before = try names(io, a, one);
    try std.testing.expect(before.contains("original"));
    try appendCpio(io, a, one, one, &.{cpio.file("added", 0o644, "new")});
    const after = try names(io, a, one);
    try std.testing.expect(after.contains("original") and after.contains("added"));
}
