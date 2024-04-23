const std = @import("std");
const files = @import("file.zig");
const ops = @import("operations.zig");

const WholeFile = files.WholeFile;
const FileFragment = files.FileFragment;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next();

    const mode: []const u8 = args.next() orelse {
        std.log.err("Missing mode\n", .{});
        return;
    };

    const filename: []const u8 = args.next() orelse {
        std.log.err("Missing filename\n", .{});
        return;
    };
    const password: []const u8 = args.next() orelse {
        std.log.err("Missing password\n", .{});
        return;
    };

    if (std.mem.eql(u8, mode, "spread")) {
        const n_frags: usize = def: {
            const value = args.next() orelse break :def null;
            break :def std.fmt.parseInt(usize, value, 10) catch {
                std.log.err("Invalid number of splits '{s}'", .{value});
                return;
            };
        } orelse 3;

        try ops.split(allocator, &.{
            .input_path = filename,
            .output_path = "output",
            .n_frags = n_frags,
            .password = password,
        });
    } else if (std.mem.eql(u8, mode, "join")) {
        var frags = std.ArrayList([]const u8).init(allocator);
        defer frags.deinit();

        while (args.next()) |frag| {
            try frags.append(frag);
        }

        try ops.join(allocator, &.{
            .output_path = filename,
            .password = password,
            .fragment_paths = frags.items,
        });
    } else {
        std.log.err("Invalid command\n", .{});
        return;
    }
}
