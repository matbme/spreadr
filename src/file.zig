const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Dir = std.fs.Dir;

const BitReader = std.io.BitReader;
const BitWriter = std.io.BitWriter;
const bitReader = std.io.bitReader;
const bitWriter = std.io.bitWriter;

const expect = std.testing.expect;

const sep = &[_]u8{@intCast(std.fs.path.sep)};

pub const FileMode = enum { read, write };
const FileHandler = union(FileMode) {
    read: BitReader(.little, File.Reader),
    write: BitWriter(.little, File.Writer),

    pub fn readBits(self: *FileHandler, comptime U: type, bits: usize, out_bits: *usize) !U {
        return switch (self.*) {
            .read => |*reader| reader.readBits(U, bits, out_bits),
            else => FileOpError.IncorrectMode,
        };
    }

    pub fn writeBits(self: *FileHandler, value: anytype, bits: usize) !void {
        return switch (self.*) {
            .write => |*writer| writer.writeBits(value, bits),
            else => FileOpError.IncorrectMode,
        };
    }

    pub fn flushBits(self: *FileHandler) !void {
        return switch (self.*) {
            .write => |*writer| writer.flushBits(),
            else => FileOpError.IncorrectMode,
        };
    }
};

pub const FileOpError = error{
    IncorrectMode,
};

pub const WholeFile = struct {
    file: File,
    handler: FileHandler,

    const Self = @This();

    pub fn open(path: []const u8, mode: FileMode) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = switch (mode) {
            .read => .read_only,
            .write => .read_write,
        } });

        const handler = switch (mode) {
            .read => FileHandler{ .read = bitReader(.little, file.reader()) },
            .write => FileHandler{ .write = bitWriter(.little, file.writer()) },
        };
        return Self{ .file = file, .handler = handler };
    }

    pub fn close(self: Self) void {
        return self.file.close();
    }
};

pub const FileFragment = struct {
    file: File,
    frag_n: usize,
    handler: FileHandler,

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

        const file = try target_dir.createFile(
            std.fs.path.basename(path),
            .{ .exclusive = true },
        );
        const handler = FileHandler{ .write = bitWriter(.little, file.writer()) };
        return Self{ .file = file, .frag_n = frag_n, .handler = handler };
    }

    pub fn createN(n: usize, base_path: []const u8, allocator: Allocator) ![]Self {
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

    pub fn open(path: []const u8, frag_n: usize) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        const handler = FileHandler{ .read = bitReader(.little, file.reader()) };
        return Self{ .file = file, .frag_n = frag_n, .handler = handler };
    }

    pub fn close(self: Self) void {
        return self.file.close();
    }

    pub fn closeAll(frags: []Self) void {
        for (frags) |f| f.close();
    }
};

test "read bits from file" {
    var file = try WholeFile.open("test/lorem.txt", .read);
    defer file.close();

    var bits_read: usize = undefined;

    var lorem: [5]u8 = undefined;
    for (0..5) |i| {
        const letter = try file.handler.readBits(u8, 8, &bits_read);
        try expect(bits_read == 8);
        lorem[i] = letter;
    }
    try expect(std.mem.eql(u8, &lorem, "Lorem"));
}

test "alternate writing to two fragments" {
    var input_file = try WholeFile.open("test/lorem.txt", .read);
    defer input_file.close();

    const dir = std.testing.tmpDir(.{});
    const dir_path = try dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var frags = try FileFragment.createN(2, dir_path, std.testing.allocator);
    defer std.testing.allocator.free(frags);

    var bits_read: usize = undefined;
    for (0..16) |i| {
        const bit = try input_file.handler.readBits(u1, 1, &bits_read);
        try expect(bits_read == 1);
        try frags[i % 2].handler.writeBits(bit, 1);
    }

    try frags[0].handler.flushBits();
    try frags[1].handler.flushBits();

    FileFragment.closeAll(frags);

    var read_frags: [2]FileFragment = undefined;
    for (0..2) |i| {
        const name = try std.mem.concat(std.testing.allocator, u8, &[_][]const u8{
            dir_path,
            sep,
            "fragment",
            &[_]u8{@as(u8, @intCast(i)) + '0'},
            ".spr",
        });
        read_frags[i] = try FileFragment.open(name, i);
        std.testing.allocator.free(name);
    }
    defer FileFragment.closeAll(read_frags[0..]);

    // 'L' = 0b01001100
    // 'o' = 0b01101111
    // Fragment 0: 0b10111010 = 0d186
    // Fragment 1: 0b01110010 = 0d114
    const frag_1_contents = try read_frags[0].handler.readBits(u8, 8, &bits_read);
    try expect(bits_read == 8);
    try expect(frag_1_contents == 186);

    const frag_2_contents = try read_frags[1].handler.readBits(u8, 8, &bits_read);
    try expect(bits_read == 8);
    try expect(frag_2_contents == 114);
}
