const std = @import("std");
const files = @import("file.zig");
const sec = @import("secure.zig");

const Allocator = std.mem.Allocator;
const FileHandler = files.FileHandler;

const salt_len: usize = 16;

pub const SplitParams = struct {
    input_path: []const u8,
    output_path: []const u8,
    n_frags: usize,
    password: []const u8,
};

pub const JoinParams = struct {
    output_path: []const u8,
    fragment_paths: [][]const u8,
    password: []const u8,
};

pub fn split(allocator: Allocator, params: *const SplitParams) !void {
    std.debug.print("Opening input file.\n", .{});
    var input_file = try FileHandler(.read).create(allocator, params.input_path);
    defer {
        input_file.close();
        allocator.destroy(input_file);
    }

    std.debug.print("Creating {d} fragments.\n", .{params.n_frags});
    var frags = try FileHandler(.write).createNWithFormat(allocator, params.output_path, "fragment{d}.spr", params.n_frags);
    defer {
        FileHandler(.write).closeAll(frags);
        allocator.free(frags);
    }

    std.debug.print("Generating salt.\n", .{});
    const salt = sec.randomSalt(salt_len);
    std.debug.print("Deriving key from password. This might take a while.\n", .{});
    const key = try sec.deriveKey(allocator, params.password, &salt, 32);

    // Distribute salt in fragments
    std.debug.print("Distributing salt over fragments.\n", .{});
    for (0..salt_len) |i| {
        try frags[i % params.n_frags].writeBits(salt[i], 8);
    }

    var csprng = std.rand.DefaultCsprng.init(key);
    const rand = csprng.random();

    const file_size = try input_file.size();

    var draw_buffer: [1000]u8 = undefined;
    const progress = std.Progress.start(.{
        .draw_buffer = &draw_buffer,
        .estimated_total_items = file_size,
        .root_name = "Spreading file",
    });
    defer progress.end();

    var bits_read: usize = undefined;
    var bits_left = file_size * 8;
    while (bits_left > 0) {
        const sample_size = @min(bits_left, rand.uintLessThan(usize, 7) + 1);
        const target = rand.uintLessThan(usize, params.n_frags);

        const sample = try input_file.readBits(u8, sample_size, &bits_read);

        bits_left -= bits_read;
        progress.setCompletedItems(file_size * 8 - bits_left);
        try frags[target].writeBits(sample, bits_read);
    }

    for (frags) |*frag| {
        const offset = frag.getBitOffset();
        try frag.flushBits();

        // Add EOF offset indicator byte so we can know how many bits from the
        // second to last byte are actually part of the file
        try frag.writeBits(offset, 8);
        try frag.flushBits();
    }

    std.debug.print("Spread of {d} bytes complete.\n", .{file_size});
}

fn calculateFilesize(frags: []FileHandler(.read)) usize {
    var total_size: usize = 0;
    for (frags) |*frag| {
        total_size += frag.size() catch unreachable;
    }

    var offset: usize = frags.len * 8;
    for (frags) |*frag| {
        offset -= frag.tail() catch unreachable;
    }
    const byte_offset = @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(offset)) / 8.0)));

    return total_size - salt_len - frags.len - byte_offset;
}

pub fn join(allocator: Allocator, params: *const JoinParams) !void {
    std.debug.print("Creating output file.\n", .{});
    var output_file = try FileHandler(.write).create(allocator, params.output_path);
    defer {
        output_file.close();
        allocator.destroy(output_file);
    }

    const n_frags = params.fragment_paths.len;

    std.debug.print("Opening {d} fragments.\n", .{n_frags});
    var frags = try FileHandler(.read).createN(allocator, params.fragment_paths);
    defer {
        FileHandler(.read).closeAll(frags);
        allocator.free(frags);
    }

    var bits_read: usize = undefined;
    const file_size = calculateFilesize(frags);

    std.debug.print("Extracting salt.\n", .{});
    var salt: [salt_len]u8 = undefined;
    for (0..salt_len) |i| {
        salt[i] = try frags[i % n_frags].readBits(u8, 8, &bits_read);
        std.debug.assert(bits_read == 8);
    }

    std.debug.print("Deriving key from password. This might take a while.\n", .{});
    const key = try sec.deriveKey(allocator, params.password, &salt, 32);

    var csprng = std.rand.DefaultCsprng.init(key);
    const rand = csprng.random();

    var draw_buffer: [1000]u8 = undefined;
    const progress = std.Progress.start(.{
        .draw_buffer = &draw_buffer,
        .estimated_total_items = file_size,
        .root_name = "Joining file",
    });
    defer progress.end();

    var bits_left = file_size * 8;
    while (bits_left > 0) {
        const sample_size = @min(bits_left, rand.uintLessThan(usize, 7) + 1);
        const target = rand.uintLessThan(usize, n_frags);

        const sample = try frags[target].readBits(u8, sample_size, &bits_read);
        bits_left -= bits_read;
        progress.setCompletedItems(file_size * 8 - bits_left);
        try output_file.writeBits(sample, bits_read);
    }

    try output_file.flushBits();

    std.debug.print("Join of {d} bytes complete.\n", .{file_size});
}
