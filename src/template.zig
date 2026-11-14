//! The small, strict text/template subset used by the embedded installer assets.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    list: []const Value,
    object: std.StringHashMap(Value),

    fn truth(self: Value) bool {
        return switch (self) {
            .string => |s| s.len > 0,
            .boolean => |b| b,
            .integer => |n| n != 0,
            .list => |items| items.len > 0,
            .object => true,
        };
    }
};

const Token = struct { action: bool, text: []const u8 };
const Node = union(enum) {
    text: []const u8,
    output: []const u8,
    conditional: struct { expression: []const u8, yes: []const Node, no: []const Node },
    range: struct { expression: []const u8, body: []const Node },
};
const Block = struct { nodes: []const Node, stop: ?[]const u8 = null };

/// All parser storage and rendered output belong to the supplied arena.
pub fn render(arena: Allocator, source: []const u8, data: anytype) ![]const u8 {
    const tokens = try tokenize(arena, source);
    var index: usize = 0;
    const block = try parseBlock(arena, tokens, &index);
    if (block.stop != null) return error.UnexpectedTemplateEnd;
    const value = try reflect(arena, data);
    var output: std.ArrayList(u8) = .empty;
    try emit(arena, &output, block.nodes, value);
    return output.toOwnedSlice(arena);
}

fn tokenize(arena: Allocator, source: []const u8) ![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "{{")) |start| {
        const end = std.mem.indexOfPos(u8, source, start + 2, "}}") orelse return error.UnclosedTemplateAction;
        var action = source[start + 2 .. end];
        var text = source[cursor..start];
        if (std.mem.startsWith(u8, action, "- ")) {
            action = action[2..];
            text = std.mem.trimEnd(u8, text, " \t\r\n");
        }
        var trim_right = false;
        if (std.mem.endsWith(u8, action, " -")) {
            action = action[0 .. action.len - 2];
            trim_right = true;
        }
        try tokens.append(arena, .{ .action = false, .text = text });
        try tokens.append(arena, .{ .action = true, .text = std.mem.trim(u8, action, " \t\r\n") });
        cursor = end + 2;
        if (trim_right) while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {};
    }
    try tokens.append(arena, .{ .action = false, .text = source[cursor..] });
    return tokens.toOwnedSlice(arena);
}

fn parseBlock(arena: Allocator, tokens: []const Token, index: *usize) anyerror!Block {
    var nodes: std.ArrayList(Node) = .empty;
    while (index.* < tokens.len) {
        const token = tokens[index.*];
        index.* += 1;
        if (!token.action) {
            try nodes.append(arena, .{ .text = token.text });
        } else if (std.mem.eql(u8, token.text, "end") or std.mem.startsWith(u8, token.text, "else")) {
            return .{ .nodes = try nodes.toOwnedSlice(arena), .stop = token.text };
        } else if (std.mem.startsWith(u8, token.text, "if ")) {
            try nodes.append(arena, try parseIf(arena, tokens, index, token.text[3..]));
        } else if (std.mem.startsWith(u8, token.text, "range ")) {
            const body = try parseBlock(arena, tokens, index);
            if (!std.mem.eql(u8, body.stop orelse "", "end")) return error.UnclosedTemplateRange;
            try nodes.append(arena, .{ .range = .{ .expression = token.text[6..], .body = body.nodes } });
        } else {
            try nodes.append(arena, .{ .output = token.text });
        }
    }
    return .{ .nodes = try nodes.toOwnedSlice(arena) };
}

fn parseIf(arena: Allocator, tokens: []const Token, index: *usize, expression: []const u8) anyerror!Node {
    const yes = try parseBlock(arena, tokens, index);
    const stop = yes.stop orelse return error.UnclosedTemplateIf;
    var no: []const Node = &.{};
    if (std.mem.eql(u8, stop, "else")) {
        const otherwise = try parseBlock(arena, tokens, index);
        if (!std.mem.eql(u8, otherwise.stop orelse "", "end")) return error.UnclosedTemplateIf;
        no = otherwise.nodes;
    } else if (std.mem.startsWith(u8, stop, "else if ")) {
        const nested = try arena.alloc(Node, 1);
        nested[0] = try parseIf(arena, tokens, index, stop[8..]);
        no = nested;
    } else if (!std.mem.eql(u8, stop, "end")) return error.InvalidTemplateElse;
    return .{ .conditional = .{ .expression = expression, .yes = yes.nodes, .no = no } };
}

fn reflect(arena: Allocator, data: anytype) anyerror!Value {
    const T = @TypeOf(data);
    return switch (@typeInfo(T)) {
        .bool => .{ .boolean = data },
        .int, .comptime_int => .{ .integer = @intCast(data) },
        .pointer => |pointer| blk: {
            if (pointer.size != .slice) return error.UnsupportedTemplateValue;
            if (pointer.child == u8) break :blk .{ .string = data };
            const values = try arena.alloc(Value, data.len);
            for (data, 0..) |item, i| values[i] = try reflect(arena, item);
            break :blk .{ .list = values };
        },
        .@"struct" => blk: {
            var object = std.StringHashMap(Value).init(arena);
            inline for (@typeInfo(T).@"struct".field_names) |field| try object.put(field, try reflect(arena, @field(data, field)));
            break :blk .{ .object = object };
        },
        else => error.UnsupportedTemplateValue,
    };
}

fn eval(context: Value, raw: []const u8) anyerror!Value {
    const expression = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, expression, "not ")) return .{ .boolean = !(try eval(context, expression[4..])).truth() };
    if (std.mem.startsWith(u8, expression, "eq ") or std.mem.startsWith(u8, expression, "ne ")) {
        const args = std.mem.trimStart(u8, expression[3..], " \t");
        const split = std.mem.indexOfAny(u8, args, " \t") orelse return error.InvalidTemplateExpression;
        const lhs = try eval(context, args[0..split]);
        const rhs = try eval(context, args[split + 1 ..]);
        if (lhs != .string or rhs != .string) return error.UnsupportedTemplateComparison;
        const equal = std.mem.eql(u8, lhs.string, rhs.string);
        return .{ .boolean = if (expression[0] == 'e') equal else !equal };
    }
    if (expression.len >= 2 and expression[0] == '"' and expression[expression.len - 1] == '"') return .{ .string = expression[1 .. expression.len - 1] };
    if (std.mem.eql(u8, expression, ".")) return context;
    if (std.mem.startsWith(u8, expression, ".") and context == .object) return context.object.get(expression[1..]) orelse error.UnknownTemplateField;
    return error.InvalidTemplateExpression;
}

fn emit(arena: Allocator, output: *std.ArrayList(u8), nodes: []const Node, context: Value) anyerror!void {
    for (nodes) |node| switch (node) {
        .text => |text| try output.appendSlice(arena, text),
        .output => |expression| switch (try eval(context, expression)) {
            .string => |s| try output.appendSlice(arena, s),
            .boolean => |b| try output.appendSlice(arena, if (b) "true" else "false"),
            .integer => |n| try output.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{n})),
            else => return error.UnsupportedTemplateOutput,
        },
        .conditional => |conditional| try emit(arena, output, if ((try eval(context, conditional.expression)).truth()) conditional.yes else conditional.no, context),
        .range => |range| {
            const items = try eval(context, range.expression);
            if (items != .list) return error.UnsupportedTemplateRange;
            for (items.list) |item| try emit(arena, output, range.body, item);
        },
    };
}

test "template trimming, nesting, else-if, and range match installer syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = .{ .Flag = false, .Name = @as([]const u8, "gpt"), .Items = @as([]const []const u8, &.{ "a", "b" }) };
    const result = try render(arena.allocator(), "start\n{{- if .Flag}}bad{{else if eq .Name \"gpt\"}}ok{{else}}bad{{end}}:{{range .Items}}[{{.}}]{{end}}", data);
    try std.testing.expectEqualStrings("startok:[a][b]", result);
}
