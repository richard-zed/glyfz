//! Malformed input: mangle the face and require that every outcome is either a
//! clean rejection or a face that still behaves.
//!
//! A font parser reads lengths and offsets that arrive from outside the
//! program, and each one is a chance to read somewhere it shouldn't. The
//! validation tests break one field at a time on a hand-built face; this sweeps
//! a real one, badly, everywhere.
//!
//! Point GLYFZ_TEST_FONT at a TTF (or run `zig build fuzz -Dfont=...`). No font
//! is vendored, so the run is reproducible for anyone with a font rather than
//! pinned to one file.
//!
//! What counts as failure: a panic, an out-of-bounds read, a hang, or a face
//! that loads and then claims to be incoherent (no glyphs, a zero em). What
//! does not: any LoadError or GlyphError, which is the library doing its job.

const std = @import("std");
const glyfz = @import("glyfz");

fn readFont(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(32 * 1024 * 1024));
}

fn fontPath() ![]const u8 {
    // 0.16 dropped std.posix.getenv; this test links libc for it.
    const p = std.c.getenv("GLYFZ_TEST_FONT") orelse return error.SkipZigTest;
    return std.mem.span(p);
}

var state: u64 = 0x243F6A8885A308D3;
fn rnd() u64 {
    state = state *% 6364136223846793005 +% 1442695040888963407;
    return state >> 17;
}

fn use(b: []const u8, cmem: []align(8) u8, deep: bool) !void {
    const font = glyfz.Font.init(b) catch return;
    // Loading is a promise that the face is coherent.
    try std.testing.expect(font.units_per_em > 0);
    try std.testing.expect(font.num_glyphs > 0);

    var cache = glyfz.Cache.init(cmem, .{}) catch return;
    const last: u16 = if (deep) 40 else 3;
    var gid: u16 = 0;
    while (gid <= last) : (gid += 1) {
        _ = font.hMetrics(gid) catch {};
        _ = font.bitmapBox(gid, 0.0117, 0) catch {};
        _ = font.bitmapBox(gid, 0.0117, 0.5) catch {};
        _ = cache.mask(&font, gid, 14, .zero) catch {};
    }
    _ = font.kern(2, 3);
    _ = font.kern(6, 7);
    _ = font.kerning();
}

test "truncations and bit flips reject or behave, never fault" {
    const gpa = std.testing.allocator;
    const data = try readFont(gpa, try fontPath());
    defer gpa.free(data);

    const scratch = try gpa.alloc(u8, data.len);
    defer gpa.free(scratch);
    const cmem = try gpa.alignedAlloc(u8, .fromByteUnits(8), 1024 * 1024);
    defer gpa.free(cmem);

    // Every truncation, strided so a huge face stays quick: a cut at any point
    // is the classic way to make a parser walk off the end.
    const stride = 1 + data.len / 4000;
    var trunc: usize = 0;
    while (trunc <= data.len) : (trunc += stride) try use(data[0..trunc], cmem, false);

    // Random single-bit flips, which reach states no truncation does.
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        @memcpy(scratch, data);
        const at: usize = @intCast(rnd() % data.len);
        scratch[at] ^= @as(u8, 1) << @as(u3, @intCast(rnd() % 8));
        try use(scratch, cmem, i % 50 == 0);
    }
}
