const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Dir = std.fs.Dir;
const StreamSource = std.io.StreamSource;

const expect = std.testing.expect;

const sep = &[_]u8{@intCast(std.fs.path.sep)};
const bufferSize = if (builtin.is_test) 2 else 4096;

pub const FileMode = enum { read, write };

/// Either a `Reader` or `Writer`. Manages all read and write operations for Files.
pub fn FileHandler(comptime mode: FileMode) type {
    return struct {
        const Mode = mode;
        const Self = @This();

        file: File,
        file_handler: switch (mode) {
            .read => std.fs.File.Reader,
            .write => std.fs.File.Writer,
        },

        handler: switch (mode) {
            .read => std.io.BitReader(.little, StreamSource.Reader),
            .write => std.io.BitWriter(.little, StreamSource.Writer),
        } = undefined,

        buffer: [bufferSize]u8 = undefined,
        bfs: StreamSource = undefined,

        fn init(filepath: []const u8, out: *Self) !void {
            switch (Self.Mode) {
                .read => {
                    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
                    out.* = Self{ .file = file, .file_handler = file.reader() };
                    out.bfs = StreamSource{ .buffer = std.io.fixedBufferStream(&out.buffer) };
                    try out.bfs.seekTo(bufferSize); // Go to end of buffer so we immediately load from file
                    out.handler = std.io.bitReader(.little, out.bfs.reader());
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

                    out.* = Self{ .file = file, .file_handler = file.writer() };
                    out.bfs = StreamSource{ .buffer = std.io.fixedBufferStream(&out.buffer) };
                    out.handler = std.io.bitWriter(.little, out.bfs.writer());
                },
            }
        }

        pub fn create(allocator: Allocator, filepath: []const u8) !*Self {
            const out = try allocator.create(Self);
            try init(filepath, out);
            return out;
        }

        pub fn createN(allocator: Allocator, paths: [][]const u8) ![]Self {
            var handlers: []Self = try allocator.alloc(Self, paths.len);
            errdefer allocator.free(handlers);

            for (paths, 0..) |path, i| {
                try init(path, &handlers[i]);
            }

            return handlers;
        }

        pub fn createNWithFormat(allocator: Allocator, base_path: []const u8, comptime format: []const u8, n: usize) ![]Self {
            var handlers: []Self = try allocator.alloc(Self, n);
            errdefer allocator.free(handlers);

            for (0..n) |i| {
                const name = try std.fmt.allocPrint(allocator, format, .{i});
                defer allocator.free(name);

                const path = try std.mem.concat(allocator, u8, &[_][]const u8{ base_path, sep, name });
                defer allocator.free(path);

                try init(path, &handlers[i]);
            }

            return handlers;
        }

        inline fn loadBuffer(self: *Self) !void {
            const pos = try self.bfs.buffer.getPos();
            if (pos == bufferSize) {
                _ = try self.file_handler.read(&self.buffer);
                try self.bfs.seekTo(0);
            }
        }

        pub fn readBits(self: *Self, comptime U: type, bits: usize, out_bits: *usize) !U {
            switch (Self.Mode) {
                .read => {
                    try self.loadBuffer();
                    return self.handler.readBits(U, bits, out_bits);
                },
                else => @compileError("Cannot call readBits in " ++ @tagName(Self.Mode) ++ " mode."),
            }
        }

        inline fn flushBuffer(self: *Self, allow_partial: bool) !void {
            const pos = try self.bfs.buffer.getPos();
            if (allow_partial) {
                _ = try self.file_handler.write(self.buffer[0..pos]);
                try self.bfs.seekTo(0);
            } else if (pos == bufferSize) {
                _ = try self.file_handler.write(&self.buffer);
                try self.bfs.seekTo(0);
            }
        }

        pub fn writeBits(self: *Self, value: anytype, bits: usize) !void {
            switch (Self.Mode) {
                .write => {
                    try self.flushBuffer(false);
                    return self.handler.writeBits(value, bits);
                },
                else => @compileError("Cannot call writeBits in " ++ @tagName(Self.Mode) ++ " mode."),
            }
        }

        pub fn flushBits(self: *Self) !void {
            switch (Self.Mode) {
                .write => {
                    try self.handler.flushBits();
                    return self.flushBuffer(true);
                },
                else => @compileError("Cannot call flushBits in " ++ @tagName(Self.Mode) ++ " mode."),
            }
        }

        pub fn getBitOffset(self: *Self) u8 {
            return self.handler.bit_count;
        }

        pub fn tail(self: *Self) !u8 {
            const prev_pos = try self.file.getPos();
            try self.file.seekFromEnd(-1);
            const t = try self.file.reader().readByte();
            try self.file.seekTo(prev_pos);
            return t;
        }

        /// Returns the total filesize
        pub fn size(self: *Self) !u64 {
            const filestat = try self.file.stat();
            return filestat.size;
        }

        pub fn getPos(self: *Self) !u64 {
            return self.bfs.getPos();
        }

        /// Closes the underlying file.
        pub fn close(self: *Self) void {
            return self.file.close();
        }

        /// Closes all files.
        pub fn closeAll(handlers: []Self) void {
            for (handlers) |*h| h.close();
        }
    };
}

test "read bits from file" {
    var file = try FileHandler(.read).create(std.testing.allocator, "test/lorem.txt");
    defer {
        file.close();
        std.testing.allocator.destroy(file);
    }

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
    var input_file = try FileHandler(.read).create(std.testing.allocator, "test/lorem.txt");
    defer {
        input_file.close();
        std.testing.allocator.destroy(input_file);
    }

    const dir = std.testing.tmpDir(.{});
    const dir_path = try dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var frags = try FileHandler(.write).createNWithFormat(std.testing.allocator, dir_path, "fragment{d}.spr", 2);
    defer std.testing.allocator.free(frags);

    var bits_read: usize = undefined;
    for (0..24) |i| {
        const bit = try input_file.readBits(u1, 1, &bits_read);
        try expect(bits_read == 1);
        try frags[i % 2].writeBits(bit, 1);
    }

    try frags[0].flushBits();
    try frags[1].flushBits();

    FileHandler(.write).closeAll(frags);

    var read_frags = try FileHandler(.read).createNWithFormat(std.testing.allocator, dir_path, "fragment{d}.spr", 2);
    defer {
        FileHandler(.read).closeAll(read_frags);
        std.testing.allocator.free(read_frags);
    }

    var got_error = false;

    // 'L' = 0b01001100
    // 'o' = 0b01101111
    // 'r' = 0b01110010
    // Fragment 0: 0b110010111010 = 0d3258
    // Fragment 1: 0b010101110010 = 0d1394
    const frag_1_contents = try read_frags[0].readBits(u12, 12, &bits_read);
    try expect(try read_frags[0].size() == 2);
    try expect(try read_frags[1].size() == 2);

    expect(bits_read == 12) catch {
        std.debug.print("Expected to read 12 bits from fragment 1, but got {d}.\n", .{bits_read});
        got_error = true;
    };
    expect(frag_1_contents == 3258) catch {
        std.debug.print("Expected `{b:0>12}` in fragment 1, but got `{b:0>12}`.\n", .{ 3258, frag_1_contents });
        got_error = true;
    };

    const frag_2_contents = try read_frags[1].readBits(u12, 12, &bits_read);
    expect(bits_read == 12) catch {
        std.debug.print("Expected to read 12 bits from fragment 2, but got {d}.\n", .{bits_read});
        got_error = true;
    };
    expect(frag_2_contents == 1394) catch {
        std.debug.print("Expected `{b:0>12}` in fragment 2, but got `{b:0>12}`.\n", .{ 1394, frag_2_contents });
        got_error = true;
    };
}
