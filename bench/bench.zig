//! GlyfZ per glyph, as a call site actually pays for it.
//!
//! Three numbers per size over the same glyph set: a rasterisation into
//! caller-owned buffers, the decode-and-flatten half of it (so the gap is the
//! coverage sweep), and a cache hit. The hit is the number the library is built
//! around -- a hash lookup and a slice, against a full rasterise otherwise.
//!
//! ReleaseFast only. Debug numbers are ~10x worse and mean nothing here.

const std = @import("std");
const glyfz = @import("glyfz");

fn readFont(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(32 * 1024 * 1024));
}

fn fontPath() ![]const u8 {
    const p = std.c.getenv("GLYFZ_BENCH_FONT") orelse return error.NoFont;
    return std.mem.span(p);
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();

    const gpa = std.heap.page_allocator;

    const path = fontPath() catch {
        std.debug.print("set GLYFZ_BENCH_FONT to a TTF\n", .{});
        return error.NoFont;
    };
    const data = try readFont(gpa, path);
    defer gpa.free(data);

    const font = try glyfz.Font.init(data);

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

    var pts: [8192]glyfz.Point = undefined;
    var ends: [512]u16 = undefined;
    var edges: [8192]glyfz.Edge = undefined;
    var scratch: [1024]f32 = undefined;
    var cov: [256 * 256]u8 = undefined;

    const span: f32 = @floatFromInt(font.vMetrics().ascender - font.vMetrics().descender);

    // The cache never allocates: one caller-owned buffer, carved internally.
    var cbuf: [1 << 21]u8 align(8) = undefined;
    var cache = try glyfz.Cache.init(&cbuf, .{ .arena = 1 << 20 });

    std.debug.print("{d} glyphs from printable ASCII, {d} units per em\n\n", .{ n, font.units_per_em });
    std.debug.print("{s:>6} {s:>11} {s:>11} {s:>11} {s:>9}\n", .{ "size", "raster ns", "decode ns", "cached ns", "raster/hit" });

    for ([_]u32{ 11, 16, 24, 34, 48 }) |size| {
        const scale = @as(f32, @floatFromInt(size)) / span;
        const reps: u32 = 40;

        var best_raster: i128 = std.math.maxInt(i128);
        var best_decode: i128 = std.math.maxInt(i128);

        // Warm first: the first call touches nothing reusable but pays for
        // branch prediction and page faults on the buffers.
        for (glyphs[0..n]) |gid| {
            _ = font.raster(gid, scale, 0, &pts, &ends, &edges, &scratch, &cov) catch continue;
        }

        var r: u32 = 0;
        while (r < reps) : (r += 1) {
            var t0 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            for (glyphs[0..n]) |gid| {
                _ = font.raster(gid, scale, 0, &pts, &ends, &edges, &scratch, &cov) catch continue;
            }
            var t1 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            best_raster = @min(best_raster, t1 - t0);

            // Everything up to and including the flattened edges. The gap to
            // `raster ns` is the coverage sweep, which says which half to fix
            // instead of guessing.
            t0 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            for (glyphs[0..n]) |gid| {
                const box = font.bitmapBox(gid, scale, 0) catch continue;
                _ = font.edgesInto(gid, scale, 0, box, &pts, &ends, &edges) catch continue;
            }
            t1 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
            best_decode = @min(best_decode, t1 - t0);
        }

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

        const denom: f64 = @floatFromInt(n);
        const per_raster = @as(f64, @floatFromInt(best_raster)) / denom;
        const per_decode = @as(f64, @floatFromInt(best_decode)) / denom;
        const per_cached = @as(f64, @floatFromInt(best_cached)) / denom;
        std.debug.print("{d:>6} {d:>11.1} {d:>11.1} {d:>11.1} {d:>8.1}x\n", .{ size, per_raster, per_decode, per_cached, per_raster / per_cached });
    }

    const s = cache.stats;
    std.debug.print("\ncache: {d} hits, {d} misses, {d} flushes\n", .{ s.hits, s.misses, s.flushes });
}
