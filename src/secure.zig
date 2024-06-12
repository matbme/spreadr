const std = @import("std");

const Allocator = std.mem.Allocator;
const sensitive_2id = std.crypto.pwhash.argon2.Params.sensitive_2id;

const expectEqualSlices = std.testing.expectEqualSlices;

/// Uses the default csprng to generate a salt with specified `size`.
pub fn randomSalt(comptime size: usize) [size]u8 {
    var output: [size]u8 = undefined;
    std.crypto.random.bytes(&output);
    return output;
}

/// Derives a key from `password` and `salt` that is `tag_size` bytes long.
pub fn deriveKey(
    allocator: Allocator,
    password: []const u8,
    salt: []const u8,
    comptime tag_size: usize,
) ![tag_size]u8 {
    var derived_key: [tag_size]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(
        allocator,
        &derived_key,
        password,
        salt,
        sensitive_2id,
        .argon2id,
    );

    return derived_key;
}

test "generate hash from password" {
    const password = "VerySecurePassword";
    const salt = "saltsalt";
    const out = try deriveKey(std.testing.allocator, password, salt[0..], 32);

    try expectEqualSlices(u8, &out, &[_]u8{
        0xdd,
        0x9d,
        0xc4,
        0x15,
        0xf4,
        0xa4,
        0x68,
        0xef,
        0x7f,
        0xec,
        0xc1,
        0x58,
        0x7a,
        0xe9,
        0xec,
        0xc,
        0x27,
        0x88,
        0xc2,
        0xd3,
        0xa8,
        0x66,
        0xbf,
        0x5a,
        0xeb,
        0x6c,
        0xf,
        0x5e,
        0xc0,
        0xef,
        0xde,
        0x87,
    });
}
