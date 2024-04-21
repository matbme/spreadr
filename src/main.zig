const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Dir = std.fs.Dir;

const sep = &[_]u8{@intCast(std.fs.path.sep)};

pub const WholeFile = struct {
    file: File,

    const Self = @This();

    pub fn init(path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        return Self{ .file = file };
    }

    pub fn close(self: Self) void {
        return self.file.close();
    }
};

pub const FileFragment = struct {
    file: File,
    frag_n: usize,

    const Self = @This();

    pub fn create(path: []const u8, frag_n: usize) !Self {
        const target_dir: Dir = def: {
            const base_path = std.fs.path.dirname(path) orelse {
                break :def std.fs.cwd();
            };
            std.fs.cwd().access(base_path, .{}) catch {
                try std.fs.cwd().makeDir(base_path);
            };
            const dir = try std.fs.cwd().openDir(base_path, .{});
            break :def dir;
        };

        const file = try target_dir.createFile(std.fs.path.basename(path), .{ .exclusive = true });
        return Self{ .file = file, .frag_n = frag_n };
    }

    pub fn create_n(n: usize, base_path: []const u8, allocator: Allocator) ![]Self {
        std.fs.cwd().access(base_path, .{}) catch {
            try std.fs.cwd().makeDir(base_path);
        };

        var fragments: []Self = try allocator.alloc(Self, n);
        errdefer allocator.free(fragments);

        for (0..n) |i| {
            const path = try std.mem.concat(allocator, u8, &[_][]const u8{
                base_path,
                sep,
                "fragment",
                &[_]u8{@as(u8, @intCast(i)) + '0'},
                ".spr",
            });
            defer allocator.free(path);
            fragments[i] = try Self.create(path, i);
        }

        return fragments;
    }
};

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

    const f = WholeFile.init(filename) catch |err| {
        std.log.err("Could not open {s}: {}", .{ filename, err });
        return;
    };
    defer f.close();

    const frags = FileFragment.create_n(splits, "fragments", allocator) catch |err| {
        std.log.err("Could not create fragments: {}", .{err});
        return;
    };
    defer allocator.free(frags);
}
