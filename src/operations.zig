const std = @import("std");
const files = @import("file.zig");
const sec = @import("secure.zig");

const Allocator = std.mem.Allocator;
const WholeFile = files.WholeFile;
const FileFragment = files.FileFragment;

pub const SplitParams = struct {
    input_path: []const u8,
    output_path: []const u8,
    n_frags: usize,
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
    const salt = sec.randomSalt(16);
    std.log.info("Deriving key from password.", .{});
    const key = try sec.deriveKey(allocator, params.password, &salt, 32);

    // Distribute salt in fragments
    std.log.info("Distributing salt over fragments.", .{});
    for (0..salt.len) |i| {
        try frags[i % params.n_frags].handler.writeBits(salt[i], 1);
    }

    var csprng = std.rand.DefaultCsprng.init(key);
    const rand = csprng.random();

    std.log.info("Spreading file.", .{});
    var bits_read: usize = undefined;
    while (true) {
        const sample_size = rand.uintLessThan(usize, 8);
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
