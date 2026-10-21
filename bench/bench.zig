//! Cedar vs stb_truetype, per glyph, as the call site actually pays for it.
//!
//! The claim this project rests on is that rasterising into a caller's buffer
//! beats the malloc/free pair stb does per glyph per draw. That claim was
//! unmeasured until this file existed, so this measures the real call shapes:
//! stbtt_GetGlyphBitmapSubpixel + stbtt_FreeBitmap on one side, one `raster`
//! into reused buffers on the other.
//!
//! ReleaseFast only. Debug numbers are ~10x worse and mean nothing here.

const std = @import("std");
const cedar = @import("cedar");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

fn readFont(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(32 * 1024 * 1024));
}

fn fontPath() ![]const u8 {
    const p = std.c.getenv("CEDAR_BENCH_FONT") orelse return error.NoFont;
    return std.mem.span(p);
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();

    const gpa = std.heap.page_allocator;

    const path = fontPath() catch {
        std.debug.print("set CEDAR_BENCH_FONT to a TTF\n", .{});
        return error.NoFont;
    };
    const data = try readFont(gpa, path);
    defer gpa.free(data);

    const font = try cedar.Font.init(data);
    var info: c.stbtt_fontinfo = undefined;
    if (c.stbtt_InitFont(&info, data.ptr, 0) == 0) return error.BadFont;

    // The glyphs a text run actually touches: printable ASCII through the font's
    // own cmap, so this is the mix a UI draws rather than a hand-picked best case.
    var glyphs: [128]u16 = undefined;
    var n: usize = 0;
    var cp: u21 = 33;
    while (cp < 127) : (cp += 1) {
        const gid = font.glyphIndex(cp) catch continue;
        if (gid == 0) continue;
        glyphs[n] = gid;
        n += 1;
    }

    var pts: [8192]cedar.Point = undefined;
    var ends: [512]u16 = undefined;
    var edges: [8192]cedar.Edge = undefined;
    var scratch: [1024]f32 = undefined;
    var cov: [256 * 256]u8 = undefined;

    const span: f32 = @floatFromInt(font.vMetrics().ascender - font.vMetrics().descender);

    // The cache never allocates: one caller-owned buffer, carved internally.
    var cbuf: [1 << 21]u8 align(8) = undefined;
    var cache = try cedar.Cache.init(&cbuf, .{ .arena = 1 << 20 });

    std.debug.print("{d} glyphs from printable ASCII\n\n", .{n});
    std.debug.print("{s:>6} {s:>11} {s:>11} {s:>11} {s:>8} {s:>11} {s:>9}\n", .{ "size", "stb ns", "cedar ns", "decode ns", "ratio", "cached ns", "vs stb" });

    for ([_]u32{ 11, 16, 24, 34, 48 }) |size| {
        const scale = @as(f32, @floatFromInt(size)) / span;
        const reps: u32 = 40;

        var best_stb: i128 = std.math.maxInt(i128);
        var best_cedar: i128 = std.math.maxInt(i128);
        var best_decode: i128 = std.math.maxInt(i128);

        // Warm both paths first: the first call loads caches and, for stb, the
        // allocator's arenas.
        for (glyphs[0..n]) |gid| {
            var w: c_int = 0;
            var h: c_int = 0;
            var xo: c_int = 0;
            var yo: c_int = 0;
            const bmp = c.stbtt_GetGlyphBitmapSubpixel(&info, scale, scale, 0, 0, gid, &w, &h, &xo, &yo);
            if (bmp != null) c.stbtt_FreeBitmap(bmp, null);
            _ = font.raster(gid, scale, 0, &pts, &ends, &edges, &scratch, &cov) catch continue;
        }

        var r: u32 = 0;
        while (r < reps) : (r += 1) {
            var t0 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            for (glyphs[0..n]) |gid| {
                var w: c_int = 0;
                var h: c_int = 0;
                var xo: c_int = 0;
                var yo: c_int = 0;
                const bmp = c.stbtt_GetGlyphBitmapSubpixel(&info, scale, scale, 0, 0, gid, &w, &h, &xo, &yo);
                if (bmp != null) c.stbtt_FreeBitmap(bmp, null);
            }
            var t1 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            best_stb = @min(best_stb, t1 - t0);

            t0 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            for (glyphs[0..n]) |gid| {
                _ = font.raster(gid, scale, 0, &pts, &ends, &edges, &scratch, &cov) catch continue;
            }
            t1 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            best_cedar = @min(best_cedar, t1 - t0);

            // Everything up to and including the flattened edges. The gap to
            // `cedar ns` is the coverage sweep, which tells us which half to
            // fix instead of guessing.
            t0 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            for (glyphs[0..n]) |gid| {
                const box = font.bitmapBox(gid, scale, 0) catch continue;
                _ = font.edgesInto(gid, scale, 0, box, &pts, &ends, &edges) catch continue;
            }
            t1 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            best_decode = @min(best_decode, t1 - t0);
        }

        const per_stb = @as(f64, @floatFromInt(best_stb)) / @as(f64, @floatFromInt(n));
        const per_cedar = @as(f64, @floatFromInt(best_cedar)) / @as(f64, @floatFromInt(n));
        // Cached: warm the whole set (every one a miss), then time pure hits.
        const ppem: u16 = @intFromFloat(@round(scale * @as(f32, @floatFromInt(font.units_per_em))));
        for (glyphs[0..n]) |gid| _ = cache.mask(font, gid, ppem, .zero) catch continue;

        var best_cached: i128 = std.math.maxInt(i128);
        r = 0;
        while (r < reps) : (r += 1) {
            const t0 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            for (glyphs[0..n]) |gid| _ = cache.mask(font, gid, ppem, .zero) catch continue;
            const t1 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            best_cached = @min(best_cached, t1 - t0);
        }
        const per_cached = @as(f64, @floatFromInt(best_cached)) / @as(f64, @floatFromInt(n));

        const per_decode = @as(f64, @floatFromInt(best_decode)) / @as(f64, @floatFromInt(n));
        std.debug.print("{d:>6} {d:>11.1} {d:>11.1} {d:>11.1} {d:>7.2}x {d:>11.1} {d:>8.1}x\n", .{ size, per_stb, per_cedar, per_decode, per_stb / per_cedar, per_cached, per_stb / per_cached });
    }
}
