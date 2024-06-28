const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Dir = std.fs.Dir;

const BitReader = std.io.BitReader;
const BitWriter = std.io.BitWriter;
const bitReader = std.io.bitReader;
const bitWriter = std.io.bitWriter;

const StreamSource = std.io.StreamSource;

const expect = std.testing.expect;

const sep = &[_]u8{@intCast(std.fs.path.sep)};
const bufferSize = 4096;

pub const FileMode = enum { read, write };

/// Either a `Reader` or `Writer`. Manages all read and write operations for Files.
pub fn FileHandler(comptime mode: FileMode) type {
    return struct {
        const Mode = mode;
        const Self = @This();

        // file: File,
        handler: switch (mode) {
            .read => BitReader(.little, StreamSource.Reader),
            .write => BitWriter(.little, StreamSource.Writer),
        } = undefined,

        buffer: [bufferSize]u8 = undefined,
        bfs: StreamSource,

        pub fn init(filepath: []const u8, out: *Self) !void {
            switch (Self.Mode) {
                .read => {
                    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
                    out.* = Self{
                        // .file = file,
                        .bfs = StreamSource{ .file = file },
                    };
                    out.handler = bitReader(.little, out.bfs.reader());
                },
                .write => {
                    const target_dir: Dir = def: {
                        const base_path = std.fs.path.dirname(filepath) orelse {
                            break :def std.fs.cwd();
                        };
                        std.fs.cwd().access(base_path, .{}) catch {
                            try std.fs.cwd().makeDir(base_path);
                        };
                        const dir = try std.fs.cwd().openDir(base_path, .{});
                        break :def dir;
                    };
                    const file = try target_dir.createFile(
                        std.fs.path.basename(filepath),
                        .{ .exclusive = true },
                    );

                    out.* = Self{
                        // .file = file,
                        .bfs = StreamSource{ .file = file },
                    };
                    out.handler = bitWriter(.little, out.bfs.writer());
                },
            }
        }

        pub fn initN(base_path: []const u8, n: usize, allocator: Allocator) ![]Self {
            std.fs.cwd().access(base_path, .{}) catch {
                try std.fs.cwd().makeDir(base_path);
            };

            var handlers: []Self = try allocator.alloc(Self, n);
            errdefer allocator.free(handlers);

            for (0..n) |i| {
                const path = try std.mem.concat(allocator, u8, &[_][]const u8{
                    base_path,
                    sep,
                    "fragment",
                    &[_]u8{@as(u8, @intCast(i)) + '0'},
                    ".spr",
                });
                defer allocator.free(path);
                try Self.init(path, &handlers[i]);
            }

            return handlers;
        }

        pub fn readBits(self: *Self, comptime U: type, bits: usize, out_bits: *usize) !U {
            switch (Self.Mode) {
                .read => return self.handler.readBits(U, bits, out_bits),
                else => @compileError("Cannot call readBits in " ++ @tagName(Self.Mode) ++ " mode."),
            }
        }

        pub fn writeBits(self: *Self, value: anytype, bits: usize) !void {
            switch (Self.Mode) {
                .write => return self.handler.writeBits(value, bits),
                else => @compileError("Cannot call writeBits in " ++ @tagName(Self.Mode) ++ " mode."),
            }
        }

        pub fn flushBits(self: *Self) !void {
            switch (Self.Mode) {
                .write => return self.handler.flushBits(),
                else => @compileError("Cannot call flushBits in " ++ @tagName(Self.Mode) ++ " mode."),
            }
        }

        /// Returns the total filesize
        pub fn size(self: *Self) !u64 {
            // const filestat = try self.file.stat();

            // TODO: handle union with switch
            const filestat = try self.bfs.file.stat();
            return filestat.size;
        }

        /// Closes the underlying file.
        pub fn close(self: *Self) void {
            // return self.file.close();

            // TODO: handle union with switch
            return self.bfs.file.close();
        }

        /// Closes all files.
        pub fn closeAll(handlers: []Self) void {
            for (handlers) |*h| h.close();
        }
    };
}

test "read bits from file" {
    var file = try FileHandler(.read).init("test/lorem.txt");
    defer file.close();

    const size = try file.size();
    try expect(size == 38094);

    var bits_read: usize = undefined;

    var lorem: [5]u8 = undefined;
    for (0..5) |i| {
        const letter = try file.readBits(u8, 8, &bits_read);
        try expect(bits_read == 8);
        lorem[i] = letter;
    }
    try expect(std.mem.eql(u8, &lorem, "Lorem"));
}

test "alternate writing to two fragments" {
    var input_file = try FileHandler(.read).init("test/lorem.txt");
    defer input_file.close();

    const dir = std.testing.tmpDir(.{});
    const dir_path = try dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var frags = try FileHandler(.write).initN(dir_path, 2, std.testing.allocator);
    defer std.testing.allocator.free(frags);

    var bits_read: usize = undefined;
    for (0..16) |i| {
        const bit = try input_file.readBits(u1, 1, &bits_read);
        try expect(bits_read == 1);
        try frags[i % 2].handler.writeBits(bit, 1);
    }

    try frags[0].flushBits();
    try frags[1].flushBits();

    FileHandler(.write).closeAll(frags);

    var read_frags: [2]FileHandler(.read) = undefined;
    for (0..2) |i| {
        const name = try std.mem.concat(std.testing.allocator, u8, &[_][]const u8{
            dir_path,
            sep,
            "fragment",
            &[_]u8{@as(u8, @intCast(i)) + '0'},
            ".spr",
        });
        read_frags[i] = try FileHandler(.read).init(name);
        std.testing.allocator.free(name);
    }
    defer FileHandler(.read).closeAll(&read_frags);

    // 'L' = 0b01001100
    // 'o' = 0b01101111
    // Fragment 0: 0b10111010 = 0d186
    // Fragment 1: 0b01110010 = 0d114
    const frag_1_contents = try read_frags[0].readBits(u8, 8, &bits_read);
    try expect(bits_read == 8);
    try expect(frag_1_contents == 186);

    const frag_2_contents = try read_frags[1].readBits(u8, 8, &bits_read);
    try expect(bits_read == 8);
    try expect(frag_2_contents == 114);
}
