const std = @import("std");
const builtin = @import("builtin");

pub fn success(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub const System = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    failure: ?[]const u8 = null,

    pub fn fail(self: *System, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, Failed } {
        self.failure = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        return error.Failed;
    }

    pub fn capture(self: *System, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(512 << 20),
            .stderr_limit = .limited(4 << 20),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(120) } },
        }) catch |err| return self.fail("{s}: {s}", .{ argv[0], @errorName(err) });
    }

    pub fn output(self: *System, argv: []const []const u8) ![]const u8 {
        const result = try self.capture(argv);
        if (!success(result.term)) return self.fail("{s}: {s}{s}", .{ argv[0], result.stdout, result.stderr });
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }

    pub fn run(self: *System, argv: []const []const u8) ![]const u8 {
        const result = try self.capture(argv);
        if (!success(result.term)) return self.fail("{s}: {s}{s}", .{ argv[0], result.stdout, result.stderr });
        return std.mem.trim(u8, try std.mem.concat(self.allocator, u8, &.{ result.stdout, result.stderr }), " \t\r\n");
    }

    pub fn optional(self: *System, argv: []const []const u8) []const u8 {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(4 << 20),
            .stderr_limit = .limited(1 << 20),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
        }) catch return "";
        if (!success(result.term)) return "";
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }

    pub fn inherit(self: *System, argv: []const []const u8) !void {
        var child = try std.process.spawn(self.io, .{ .argv = argv, .create_no_window = true });
        defer child.kill(self.io);
        if (!success(try child.wait(self.io))) return self.fail("{s} failed", .{argv[0]});
    }

    pub fn commandExists(self: *System, name: []const u8) bool {
        if (std.mem.indexOfScalar(u8, name, '/')) |_| return self.pathExists(name);
        return self.optional(&.{ "sh", "-c", "command -v \"$1\"", "clearme", name }).len > 0;
    }

    pub fn firstCommand(self: *System, names: []const []const u8) []const u8 {
        for (names) |name| if (self.commandExists(name)) return name;
        return "";
    }

    pub fn isRoot(self: *System) bool {
        return std.mem.eql(u8, self.optional(&.{ "id", "-u" }), "0");
    }

    pub fn read(self: *System, path: []const u8, limit: usize) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(limit));
    }

    pub fn readOptional(self: *System, path: []const u8) []const u8 {
        return self.read(path, 4 << 20) catch "";
    }

    pub fn pathExists(self: *System, path: []const u8) bool {
        _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }

    pub fn write(self: *System, path: []const u8, data: []const u8, mode: u16) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = data,
            .flags = .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(mode) },
        });
    }

    pub fn mkdir(self: *System, path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, path);
    }

    pub fn remove(self: *System, path: []const u8) void {
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
    }
};

test "command capture preserves failure output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sys: System = .{ .io = std.testing.io, .allocator = arena.allocator() };
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/c", "echo failure & exit /b 7" }
    else
        &.{ "sh", "-c", "printf failure; exit 7" };
    try std.testing.expectError(error.Failed, sys.output(argv));
    try std.testing.expect(std.mem.indexOf(u8, sys.failure.?, "failure") != null);
}
