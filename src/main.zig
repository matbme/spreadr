const std = @import("std");
const files = @import("file.zig");

const WholeFile = files.WholeFile;
const FileFragment = files.FileFragment;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next();

    const filename: []const u8 = args.next() orelse {
        std.log.err("Missing filename\n", .{});
        return;
    };
    const splits: usize = def: {
        const value = args.next() orelse break :def null;
        break :def std.fmt.parseInt(usize, value, 10) catch {
            std.log.err("Invalid number of splits '{s}'", .{value});
            return;
        };
    } orelse 3;

    const f = WholeFile.open(filename, .read) catch |err| {
        std.log.err("Could not open {s}: {}", .{ filename, err });
        return;
    };
    defer f.close();

    const frags = FileFragment.createN(splits, "fragments", allocator) catch |err| {
        std.log.err("Could not create fragments: {}", .{err});
        return;
    };
    defer allocator.free(frags);
}
