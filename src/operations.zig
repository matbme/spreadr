const std = @import("std");
const files = @import("file.zig");
const sec = @import("secure.zig");

const Allocator = std.mem.Allocator;
const WholeFile = files.WholeFile;
const FileFragment = files.FileFragment;

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
    std.log.info("Opening input file.", .{});
    var input_file = try WholeFile.open(params.input_path);
    defer input_file.close();

    std.log.info("Creating {d} fragments.", .{params.n_frags});
    var frags = try FileFragment.createN(params.n_frags, params.output_path, allocator);
    defer {
        FileFragment.closeAll(frags);
        allocator.free(frags);
    }

    std.log.info("Generating salt.", .{});
    const salt = sec.randomSalt(salt_len);
    std.log.info("Deriving key from password.", .{});
    const key = try sec.deriveKey(allocator, params.password, &salt, 32);

    // Distribute salt in fragments
    std.log.info("Distributing salt over fragments.", .{});
    for (0..salt_len) |i| {
        try frags[i % params.n_frags].handler.writeBits(salt[i], 8);
    }

    var csprng = std.rand.DefaultCsprng.init(key);
    const rand = csprng.random();

    std.log.info("Spreading file.", .{});
    var bits_read: usize = undefined;
    while (true) {
        const sample_size = rand.uintLessThan(usize, 7) + 1;
        const target = rand.uintLessThan(usize, params.n_frags);

        const sample = try input_file.handler.readBits(u8, sample_size, &bits_read);
        if (bits_read < sample_size) {
            break;
        }

        try frags[target].handler.writeBits(sample, bits_read);
    }

    for (frags) |*frag| {
        try frag.handler.flushBits();
    }

    std.log.info("Spread complete.", .{});
}

pub fn join(allocator: Allocator, params: *const JoinParams) !void {
    std.log.info("Creating output file", .{});
    var output_file = try WholeFile.create(params.output_path);
    defer output_file.close();

    const n_frags = params.fragment_paths.len;

    std.log.info("Opening {d} fragments", .{n_frags});
    var frags = try allocator.alloc(FileFragment, n_frags);
    defer {
        FileFragment.closeAll(frags);
        allocator.free(frags);
    }

    for (0.., params.fragment_paths) |i, frag_path| {
        frags[i] = try FileFragment.open(frag_path, i);
    }

    var bits_read: usize = undefined;

    std.log.info("Extracting salt", .{});
    var salt: [salt_len]u8 = undefined;
    for (0..salt_len) |i| {
        salt[i] = try frags[i % n_frags].handler.readBits(u8, 8, &bits_read);
        std.debug.assert(bits_read == 8);
    }

    std.log.info("Deriving key from password.", .{});
    const key = try sec.deriveKey(allocator, params.password, &salt, 32);

    var csprng = std.rand.DefaultCsprng.init(key);
    const rand = csprng.random();

    std.log.info("Joining file.", .{});
    while (true) {
        const sample_size = rand.uintLessThan(usize, 7) + 1;
        const target = rand.uintLessThan(usize, n_frags);

        const sample = try frags[target].handler.readBits(u8, sample_size, &bits_read);

        // Ideally, the first time we read 0 bits from any source means we are
        // done. If a fragment is corrupted, then this will stop early.
        // TODO: Figure out a way to check whether we're actually done.
        if (bits_read == 0) {
            break;
        }

        // FIXME: Outputting 0x0 at the end of the file for some reason.
        try output_file.handler.writeBits(sample, bits_read);
    }

    try output_file.handler.flushBits();

    std.log.info("Join complete.", .{});
}
