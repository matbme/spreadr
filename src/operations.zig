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
    var input_file = try FileHandler(.read).init(params.input_path);
    defer input_file.close();

    std.debug.print("Creating {d} fragments.\n", .{params.n_frags});
    var frags = try FileHandler(.write).initN(params.output_path, params.n_frags, allocator);
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

    var draw_buffer: [1000]u8 = undefined;
    const progress = std.Progress.start(.{
        .draw_buffer = &draw_buffer,
        .estimated_total_items = input_file.size() catch 0,
        .root_name = "Spreading file",
    });
    defer progress.end();

    var bits_read: usize = undefined;
    var total_read: usize = 0;
    while (true) {
        const sample_size = rand.uintLessThan(usize, 7) + 1;
        const target = rand.uintLessThan(usize, params.n_frags);

        const sample = try input_file.readBits(u8, sample_size, &bits_read);
        if (bits_read == 0) {
            break;
        }

        total_read += bits_read;
        progress.setCompletedItems(total_read);
        try frags[target].writeBits(sample, bits_read);
    }

    for (frags) |*frag| {
        try frag.flushBits();
    }

    std.debug.print("Spread of {d} bytes complete.\n", .{total_read / 8});
}

pub fn join(allocator: Allocator, params: *const JoinParams) !void {
    std.debug.print("Creating output file.\n", .{});
    var output_file = try FileHandler(.write).init(params.output_path);
    defer output_file.close();

    const n_frags = params.fragment_paths.len;

    std.debug.print("Opening {d} fragments.\n", .{n_frags});
    var frags = try allocator.alloc(FileHandler(.read), n_frags);
    defer {
        FileHandler(.read).closeAll(frags);
        allocator.free(frags);
    }

    for (0.., params.fragment_paths) |i, frag_path| {
        frags[i] = try FileHandler(.read).init(frag_path);
    }

    var bits_read: usize = undefined;

    std.debug.print("Extracting salt.\n", .{});
    var salt: [salt_len]u8 = undefined;
    for (0..salt_len) |i| {
        salt[i] = try frags[i % n_frags].readBits(u8, 8, &bits_read);
        std.debug.assert(bits_read == 8);
    }

    std.debug.print("Deriving key from password.\n", .{});
    const key = try sec.deriveKey(allocator, params.password, &salt, 32);

    var csprng = std.rand.DefaultCsprng.init(key);
    const rand = csprng.random();

    std.debug.print("Joining file.\n", .{});
    var total_read: usize = 0;
    while (true) {
        const sample_size = rand.uintLessThan(usize, 7) + 1;
        const target = rand.uintLessThan(usize, n_frags);

        const sample = try frags[target].readBits(u8, sample_size, &bits_read);
        // Ideally, the first time we read 0 bits from any source means we are
        // done. If a fragment is corrupted, then this will stop early.
        // TODO: Figure out a way to check whether we're actually done.
        if (bits_read == 0) {
            break;
        }

        total_read += bits_read;
        try output_file.writeBits(sample, bits_read);
    }

    std.debug.print("Join of {d} bytes complete.\n", .{total_read / 8});
}
