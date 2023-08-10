//! Implementation of Split block Bloom filters: https://arxiv.org/pdf/2101.01719v4.pdf

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const stdx = @import("../stdx.zig");

pub const Fingerprint = struct {
    /// Hash value used to map key to block.
    hash: u32,
    /// Mask of bits set in the block for the key.
    mask: @Vector(8, u32),

    pub fn create(hash: u64) Fingerprint {
        const hash_lower = @as(u32, @truncate(hash));
        const hash_upper = @as(u32, @intCast(hash >> 32));

        // TODO These constants are from the paper and we understand them to be arbitrary odd
        // integers. Experimentally compare the performance of these with other randomly chosen
        // odd integers to verify/improve our understanding.
        const odd_integers: @Vector(8, u32) = [8]u32{
            0x47b6137b,
            0x44974d91,
            0x8824ad5b,
            0xa2b7289d,
            0x705495c7,
            0x2df1424b,
            0x9efc4947,
            0x5c6bfb31,
        };

        // Multiply-shift hashing. This produces 8 values in the range 0 to 31 (2^5 - 1).
        const lower: @Vector(8, u32) = @splat(hash_lower);
        const bit_indexes = (odd_integers *% lower) >> @splat(32 - 5);

        return .{
            .hash = hash_upper,
            .mask = @as(@Vector(8, u32), @splat(1)) << @truncate(bit_indexes),
        };
    }
};

/// Add the key with the given fingerprint to the filter.
/// filter.len must be a multiple of 32.
pub fn add(fingerprint: Fingerprint, filter: []u8) void {
    comptime assert(@sizeOf(@Vector(8, u32)) == 32);

    assert(filter.len > 0);
    assert(filter.len % @sizeOf(@Vector(8, u32)) == 0);

    const blocks = mem.bytesAsSlice([8]u32, filter);
    const index = block_index(fingerprint.hash, filter.len);

    const current: @Vector(8, u32) = blocks[index];
    blocks[index] = current | fingerprint.mask;
}

/// Check if the key with the given fingerprint may have been added to the filter.
/// filter.len must be a multiple of 32.
pub fn may_contain(fingerprint: Fingerprint, filter: []const u8) bool {
    comptime assert(@sizeOf(@Vector(8, u32)) == 32);

    assert(filter.len > 0);
    assert(filter.len % @sizeOf(@Vector(8, u32)) == 0);

    const blocks = mem.bytesAsSlice([8]u32, filter);
    const index = block_index(fingerprint.hash, filter.len);

    const current: @Vector(8, u32) = blocks[index];
    return @reduce(.Or, ~current & fingerprint.mask) == 0;
}

inline fn block_index(hash: u32, size: usize) u32 {
    assert(size > 0);

    const block_count = @divExact(size, @sizeOf(@Vector(8, u32)));
    return @as(u32, @intCast((@as(u64, hash) * block_count) >> 32));
}

test "bloom filter: refAllDecls" {
    _ = std.testing.refAllDecls(@This());
}

const test_bloom_filter = struct {
    const fuzz = @import("../testing/fuzz.zig");
    const block_size = @import("../constants.zig").block_size;

    fn random_keys(random: std.rand.Random, iter: usize) !void {
        const keys_count = @min(
            @as(usize, 1E6),
            fuzz.random_int_exponential(random, usize, iter),
        );

        const keys = try std.testing.allocator.alloc(u32, keys_count);
        defer std.testing.allocator.free(keys);

        for (keys) |*key| key.* = random.int(u32);

        // `block_size` is currently the only size bloom_filter that we use.
        const filter = try std.testing.allocator.alloc(u8, block_size);
        @memset(filter, 0);
        defer std.testing.allocator.free(filter);

        for (keys) |key| {
            add(Fingerprint.create(stdx.hash_inline(key)), filter);
        }
        for (keys) |key| {
            try std.testing.expect(may_contain(Fingerprint.create(stdx.hash_inline(key)), filter));
        }

        // TODO Test the false positive rate:
        // * Calculate the expected false positive rate
        // * Test with a large number of random keys.
        // * Use Chernoff bound or similar to determine a reasonable test cutoff.
    }
};

test "bloom filter: random" {
    var rng = std.rand.DefaultPrng.init(42);
    const iterations_max: usize = (1 << 12);
    var iterations: usize = 0;
    while (iterations < iterations_max) : (iterations += 1) {
        try test_bloom_filter.random_keys(rng.random(), iterations);
    }
}
