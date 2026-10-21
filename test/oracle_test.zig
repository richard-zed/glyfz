//! Differential against stb_truetype: same face, same answers.
//!
//! Point CEDAR_TEST_FONT at a TTF (or run `zig build oracle -Dfont=...`).
//! No font is vendored, so the run is reproducible for anyone with a font
//! rather than pinned to one file -- and it can be aimed at an awkward face on
//! purpose.

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
    // 0.16 dropped std.posix.getenv; the oracle links libc anyway.
    const p = std.c.getenv("CEDAR_TEST_FONT") orelse return error.SkipZigTest;
    return std.mem.span(p);
}

const Fixture = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    font: cedar.Font,
    info: c.stbtt_fontinfo,

    fn open(gpa: std.mem.Allocator) !Fixture {
        const data = try readFont(gpa, try fontPath());
        errdefer gpa.free(data);
        const font = try cedar.Font.init(data);
        var info: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&info, data.ptr, 0) == 0) return error.BadFont;
        return .{ .gpa = gpa, .data = data, .font = font, .info = info };
    }

    fn close(self: Fixture) void {
        self.gpa.free(self.data);
    }
};

test "vertical and horizontal metrics match stb_truetype" {
    const gpa = std.testing.allocator;
    const fx = try Fixture.open(gpa);
    defer fx.close();

    try std.testing.expectEqual(@as(c_int, fx.font.num_glyphs), fx.info.numGlyphs);

    var sa: c_int = 0;
    var sd: c_int = 0;
    var sg: c_int = 0;
    c.stbtt_GetFontVMetrics(&fx.info, &sa, &sd, &sg);
    const v = fx.font.vMetrics();
    try std.testing.expectEqual(@as(i32, v.ascender), @as(i32, sa));
    try std.testing.expectEqual(@as(i32, v.descender), @as(i32, sd));
    try std.testing.expectEqual(@as(i32, v.line_gap), @as(i32, sg));

    var bad: usize = 0;
    var gid: u16 = 0;
    while (gid < fx.font.num_glyphs) : (gid += 1) {
        const ours = try fx.font.hMetrics(gid);
        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetGlyphHMetrics(&fx.info, gid, &adv, &lsb);
        if (ours.advance != @as(u16, @intCast(adv)) or ours.lsb != @as(i16, @intCast(lsb))) {
            if (bad < 5) std.debug.print(
                "hmtx gid {d}: cedar adv {d} lsb {d}, stb adv {d} lsb {d}\n",
                .{ gid, ours.advance, ours.lsb, adv, lsb },
            );
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "character map matches stb_truetype over the whole code space" {
    const gpa = std.testing.allocator;
    const fx = try Fixture.open(gpa);
    defer fx.close();

    var bad: usize = 0;
    // u21 saturates at 0x1FFFFF, so walk in u32 and narrow: Unicode ends at
    // 0x10FFFF.
    var cp: u32 = 0;
    while (cp < 0x11_0000) : (cp += 1) {
        const ours = try fx.font.glyphIndex(@intCast(cp));
        const theirs: c_int = c.stbtt_FindGlyphIndex(&fx.info, @intCast(cp));
        if (theirs < 0 or ours != @as(u16, @intCast(theirs))) {
            if (bad < 10) std.debug.print("cmap U+{X}: cedar {d}, stb {d}\n", .{ cp, ours, theirs });
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

const Compared = struct { checked: usize, skipped: usize, mismatched: usize };

/// Compare every glyph's decoded outline against stb's.
///
/// `perturb` shifts Cedar's box so the comparison itself can be proven to
/// notice a difference -- a differential that cannot go red is decoration.
fn compareOutlines(fx: Fixture, perturb: i32) !Compared {
    var pts: [8192]cedar.Point = undefined;
    var ends: [512]u16 = undefined;

    var out = Compared{ .checked = 0, .skipped = 0, .mismatched = 0 };
    var gid: u16 = 0;
    while (gid < fx.font.num_glyphs) : (gid += 1) {
        const o = fx.font.outline(gid, &pts, &ends) catch |e| switch (e) {
            error.BufferTooSmall, error.UnsupportedComposite => {
                out.skipped += 1;
                continue;
            },
            else => return e,
        };

        var verts: [*c]c.stbtt_vertex = null;
        const n = c.stbtt_GetGlyphShape(&fx.info, gid, &verts);
        defer if (n > 0) c.stbtt_FreeShape(&fx.info, verts);

        if (n <= 0) {
            if (o.points.len != 0) {
                std.debug.print("gid {d}: cedar {d} points, stb none\n", .{ gid, o.points.len });
                out.mismatched += 1;
            }
            continue;
        }

        var x0: i32 = verts[0].x;
        var y0: i32 = verts[0].y;
        var x1: i32 = verts[0].x;
        var y1: i32 = verts[0].y;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) {
            const v = verts[i];
            // cx/cy are dummy zeros on move and line vertices; only a curve
            // vertex carries a real control point.
            const curve = v.type == c.STBTT_vcurve;
            for ([_]i32{ v.x, if (curve) v.cx else v.x }) |vx| {
                x0 = @min(x0, vx);
                x1 = @max(x1, vx);
            }
            for ([_]i32{ v.y, if (curve) v.cy else v.y }) |vy| {
                y0 = @min(y0, vy);
                y1 = @max(y1, vy);
            }
        }

        var b = cedar.outlineBounds(o);
        if (perturb != 0) {
            b.x0 += perturb;
            b.y0 += perturb;
        }
        out.checked += 1;
        if (b.x0 != x0 or b.y0 != y0 or b.x1 != x1 or b.y1 != y1) {
            if (out.mismatched < 10) std.debug.print(
                "gid {d}: cedar box [{d},{d}..{d},{d}] stb [{d},{d}..{d},{d}]\n",
                .{ gid, b.x0, b.y0, b.x1, b.y1, x0, y0, x1, y1 },
            );
            out.mismatched += 1;
        }
    }
    return out;
}

test "outline matches stb_truetype's decoded shape, glyph by glyph" {
    const gpa = std.testing.allocator;
    const fx = try Fixture.open(gpa);
    defer fx.close();

    const r = try compareOutlines(fx, 0);
    std.debug.print("outline: {d} compared, {d} skipped, {d} mismatched\n", .{ r.checked, r.skipped, r.mismatched });
    // The differential only means something if it actually covered the face.
    try std.testing.expect(r.checked > 100);
    try std.testing.expectEqual(@as(usize, 0), r.mismatched);
}

test "the comparison itself notices a one-unit shift" {
    const gpa = std.testing.allocator;
    const fx = try Fixture.open(gpa);
    defer fx.close();

    const shifted = try compareOutlines(fx, 1);
    const exact = try compareOutlines(fx, 0);
    std.debug.print("control: {d} of {d} flagged under a 1-unit shift\n", .{ shifted.mismatched, shifted.checked });
    try std.testing.expect(shifted.mismatched == shifted.checked);
    try std.testing.expectEqual(@as(usize, 0), exact.mismatched);
}

test "pixel boxes match stb_truetype at several sizes and phases" {
    const gpa = std.testing.allocator;
    const fx = try Fixture.open(gpa);
    defer fx.close();

    // The scale Elm uses: pixels per font unit at a given pixel height. It is
    // NOT size/upem -- that difference is the trap.
    const span: f32 = @floatFromInt(fx.font.ascender - fx.font.descender);

    var bad: usize = 0;
    var checked: usize = 0;
    for ([_]f32{ 9, 11, 16, 34 }) |size| {
        for ([_]f32{ 0, 0.25, 0.5 }) |phase| {
            const scale = size / span;
            var gid: u16 = 0;
            while (gid < fx.font.num_glyphs) : (gid += 1) {
                const ours = try fx.font.bitmapBox(gid, scale, phase);
                var ix0: c_int = 0;
                var iy0: c_int = 0;
                var ix1: c_int = 0;
                var iy1: c_int = 0;
                c.stbtt_GetGlyphBitmapBoxSubpixel(&fx.info, gid, scale, scale, phase, 0, &ix0, &iy0, &ix1, &iy1);
                checked += 1;
                if (ours.x0 != ix0 or ours.y0 != iy0 or ours.x1 != ix1 or ours.y1 != iy1) {
                    if (bad < 10) std.debug.print(
                        "gid {d} size {d} phase {d}: cedar [{d},{d}..{d},{d}] stb [{d},{d}..{d},{d}]\n",
                        .{ gid, size, phase, ours.x0, ours.y0, ours.x1, ours.y1, ix0, iy0, ix1, iy1 },
                    );
                    bad += 1;
                }
            }
        }
    }
    std.debug.print("boxes: {d} compared, {d} mismatched\n", .{ checked, bad });
    try std.testing.expect(checked > 1000);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "coverage matches stb_truetype's rasteriser" {
    const gpa = std.testing.allocator;
    const fx = try Fixture.open(gpa);
    defer fx.close();

    const span: f32 = @floatFromInt(fx.font.ascender - fx.font.descender);

    var pts: [8192]cedar.Point = undefined;
    var ends: [512]u16 = undefined;
    var edges: [8192]cedar.Edge = undefined;
    var scratch: [1024]f32 = undefined;
    var ours_buf: [256 * 256]u8 = undefined;

    var glyphs: usize = 0;
    var pixels: usize = 0;
    var over2: usize = 0;
    var max_delta: u32 = 0;
    var box_mismatch: usize = 0;
    var skipped: usize = 0;

    for ([_]f32{ 11, 16, 34 }) |size| {
        for ([_]f32{ 0, 0.5 }) |phase| {
            const scale = size / span;
            var gid: u16 = 0;
            while (gid < fx.font.num_glyphs) : (gid += 1) {
                const r = fx.font.raster(
                    gid,
                    scale,
                    phase,
                    &pts,
                    &ends,
                    &edges,
                    &scratch,
                    &ours_buf,
                ) catch |e| switch (e) {
                    error.BufferTooSmall, error.UnsupportedComposite => {
                        skipped += 1;
                        continue;
                    },
                    else => return e,
                };

                var w: c_int = 0;
                var h: c_int = 0;
                var xoff: c_int = 0;
                var yoff: c_int = 0;
                const theirs = c.stbtt_GetGlyphBitmapSubpixel(&fx.info, scale, scale, phase, 0, gid, &w, &h, &xoff, &yoff);
                defer if (theirs != null) c.stbtt_FreeBitmap(theirs, null);

                if (w <= 0 or h <= 0) continue;
                if (r.w != @as(u32, @intCast(w)) or r.h != @as(u32, @intCast(h)) or
                    r.x0 != xoff or r.y0 != yoff)
                {
                    box_mismatch += 1;
                    continue;
                }

                glyphs += 1;
                var i: usize = 0;
                const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
                while (i < n) : (i += 1) {
                    const a: i32 = r.coverage[i];
                    const b: i32 = theirs[i];
                    const d: u32 = @intCast(if (a > b) a - b else b - a);
                    if (d > max_delta) max_delta = d;
                    if (d > 2) over2 += 1;
                }
                pixels += n;
            }
        }
    }

    std.debug.print(
        "coverage: {d} glyphs, {d} pixels, max delta {d}, over2 {d} ({d:.4}%), box mismatch {d}, skipped {d}\n",
        .{ glyphs, pixels, max_delta, over2, 100.0 * @as(f64, @floatFromInt(over2)) / @as(f64, @floatFromInt(pixels)), box_mismatch, skipped },
    );
    try std.testing.expectEqual(@as(usize, 0), box_mismatch);
    // Not vacuous: real coverage was compared.
    try std.testing.expect(glyphs > 1000);
    try std.testing.expect(pixels > 1_000_000);
    // The gate. Two independent implementations of the same spec, mirroring
    // each other's flattening tolerance, should agree this closely; anything
    // looser means a real disagreement hiding in the average.
    try std.testing.expect(max_delta <= 8);
    const frac = @as(f64, @floatFromInt(over2)) / @as(f64, @floatFromInt(pixels));
    try std.testing.expect(frac <= 0.001);
}

test "the coverage comparison notices a half-pixel shift" {
    const gpa = std.testing.allocator;
    const fx = try Fixture.open(gpa);
    defer fx.close();

    const span: f32 = @floatFromInt(fx.font.ascender - fx.font.descender);
    const scale = 16 / span;

    var pts: [8192]cedar.Point = undefined;
    var ends: [512]u16 = undefined;
    var edges: [8192]cedar.Edge = undefined;
    var scratch: [1024]f32 = undefined;
    var ours_buf: [256 * 256]u8 = undefined;

    var max_delta: u32 = 0;
    var glyphs: usize = 0;
    var gid: u16 = 0;
    while (gid < fx.font.num_glyphs and glyphs < 400) : (gid += 1) {
        // Rasterise half a pixel to the right of where stb is asked to.
        const r = fx.font.raster(gid, scale, 0.5, &pts, &ends, &edges, &scratch, &ours_buf) catch continue;

        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const theirs = c.stbtt_GetGlyphBitmapSubpixel(&fx.info, scale, scale, 0, 0, gid, &w, &h, &xoff, &yoff);
        defer if (theirs != null) c.stbtt_FreeBitmap(theirs, null);

        if (w <= 0 or h <= 0) continue;
        // A shifted glyph can be one pixel wider, so compare the overlap.
        const cw: usize = @min(@as(usize, r.w), @as(usize, @intCast(w)));
        const ch: usize = @min(@as(usize, r.h), @as(usize, @intCast(h)));
        if (cw == 0 or ch == 0) continue;

        var y: usize = 0;
        while (y < ch) : (y += 1) {
            var x: usize = 0;
            while (x < cw) : (x += 1) {
                const a: i32 = r.coverage[y * r.w + x];
                const b: i32 = theirs[y * @as(usize, @intCast(w)) + x];
                const d: u32 = @intCast(@abs(a - b));
                if (d > max_delta) max_delta = d;
            }
        }
        glyphs += 1;
    }

    std.debug.print("control: {d} glyphs, max delta {d} under a half-pixel shift\n", .{ glyphs, max_delta });
    try std.testing.expect(glyphs > 100);
    try std.testing.expect(max_delta > 20);
}
