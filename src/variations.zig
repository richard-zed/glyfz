//! OpenType font variations: fvar (axes), avar (axis mapping) and gvar (glyf
//! outline deltas), applied with the standard interpolation of untouched
//! points.
//!
//! No allocator, like the rest of the library: every scratch buffer a decode
//! needs is handed in by the caller. The decoders are bounds-checked and
//! return `error.Malformed` rather than reading past a table's end, because a
//! variation table is exactly the sort of thing a subsetter or a web tool
//! truncates.
//!
//! What this does NOT do, deliberately: `HVAR` advances, `cvar`, `MVAR`, and
//! composite-glyph component-offset deltas. A varied composite still picks up
//! its components' variation (they are varied when the component itself is
//! decoded), but the offsets between components stay at their default values.

const std = @import("std");

pub const max_axes = 8;
/// Points one glyph's delta decode may touch. Beyond this the glyf is left at
/// its default outline rather than half-varied.
pub const max_points = 1024;

pub const Error = error{Malformed};

pub const Axis = struct {
    tag: u32,
    min: f32,
    default: f32,
    max: f32,
};

fn u16At(d: []const u8, o: usize) Error!u16 {
    if (o + 2 > d.len) return error.Malformed;
    return (@as(u16, d[o]) << 8) | d[o + 1];
}

fn i16At(d: []const u8, o: usize) Error!i16 {
    return @bitCast(try u16At(d, o));
}

fn u32At(d: []const u8, o: usize) Error!u32 {
    if (o + 4 > d.len) return error.Malformed;
    return (@as(u32, d[o]) << 24) | (@as(u32, d[o + 1]) << 16) |
        (@as(u32, d[o + 2]) << 8) | d[o + 3];
}

/// 16.16 signed fixed point.
fn fixed(v: u32) f32 {
    return @as(f32, @floatFromInt(@as(i32, @bitCast(v)))) / 65536.0;
}

/// 2.14 signed fixed point, the unit every variation coordinate uses.
fn f2d(v: i16) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

pub fn axisCount(d: []const u8) Error!u16 {
    if (d.len < 16) return error.Malformed;
    return u16At(d, 8);
}

pub fn axis(d: []const u8, i: usize) Error!Axis {
    const count = try axisCount(d);
    const data_at: usize = try u16At(d, 4);
    const size: usize = try u16At(d, 10);
    if (size < 20) return error.Malformed;
    if (i >= count) return error.Malformed;
    const o = data_at + i * size;
    return .{
        .tag = try u32At(d, o),
        .min = fixed(try u32At(d, o + 4)),
        .default = fixed(try u32At(d, o + 8)),
        .max = fixed(try u32At(d, o + 12)),
    };
}

/// Map one user-space value onto the normalised [-1, 1] axis, then through the
/// `avar` segment map if the face has one. A flat axis (min == default == max)
/// normalises to 0 -- that is a legal axis, not a broken one.
pub fn normalizeAxis(a: Axis, v: f32, avar: []const u8, axis_index: usize) f32 {
    var n: f32 = 0;
    if (v > a.default) {
        const span = a.max - a.default;
        n = if (span <= 0) 0 else (v - a.default) / span;
    } else if (v < a.default) {
        const span = a.default - a.min;
        n = if (span <= 0) 0 else (v - a.default) / span;
    }
    n = std.math.clamp(n, -1, 1);
    // Normalised coordinates are F2Dot14 everywhere else in the format: avar's
    // mapping points, gvar's tuple regions, all of it. Snapping the instance
    // coordinate to that same grid before any tuple is evaluated is what a
    // static instancer does, and it matters: a scalar product that lands within
    // a unit of a .5 boundary otherwise rounds the other way from every other
    // implementation (Inter at wght 700 wants 8847/16384, not 0.5400049).
    return quantizeF2Dot14(avarMap(avar, axis_index, n));
}

fn quantizeF2Dot14(v: f32) f32 {
    const scaled = @round(v * 16384.0);
    return std.math.clamp(scaled / 16384.0, -1, 1);
}

/// Piecewise-linear `avar` remap. Segments are stored per axis, in axis order,
/// after a header; a value outside the stored segments keeps its normalised
/// value, which is what the spec's implicit end points do.
fn avarMap(avar: []const u8, axis_index: usize, n: f32) f32 {
    if (avar.len < 8) return n;
    const count = u16At(avar, 6) catch return n;
    if (axis_index >= count) return n;
    var o: usize = 8;
    var i: usize = 0;
    while (i < axis_index) : (i += 1) {
        const segs = u16At(avar, o) catch return n;
        o += 2 + @as(usize, segs) * 4;
    }
    const segs = u16At(avar, o) catch return n;
    o += 2;
    if (segs < 2) return n;
    var prev_from: f32 = undefined;
    var prev_to: f32 = undefined;
    var k: usize = 0;
    while (k < segs) : (k += 1) {
        const from = f2d(i16At(avar, o + k * 4) catch return n);
        const to = f2d(i16At(avar, o + k * 4 + 2) catch return n);
        if (k != 0 and n >= prev_from and n <= from) {
            if (from == prev_from) return to;
            const t = (n - prev_from) / (from - prev_from);
            return prev_to + t * (to - prev_to);
        }
        prev_from = from;
        prev_to = to;
    }
    return n;
}

/// The scalar for one tuple: 1 when the tuple does not move this axis, 0 when
/// the coordinate is outside the tuple's region, and a linear ramp in between.
fn tupleScalar(
    peak: []const f32,
    start: ?[]const f32,
    end: ?[]const f32,
    coords: []const f32,
) f32 {
    var f: f32 = 1;
    for (peak, 0..) |p, i| {
        if (p == 0) continue;
        const c = if (i < coords.len) coords[i] else 0;
        if (start) |s| {
            const e = end.?;
            if (c == p) continue;
            if (c <= s[i] or c >= e[i]) return 0;
            if (c < p) {
                const den = p - s[i];
                f *= if (den == 0) 1 else (c - s[i]) / den;
            } else {
                const den = e[i] - p;
                f *= if (den == 0) 1 else (e[i] - c) / den;
            }
        } else {
            if (c == 0) return 0;
            if ((c < 0) != (p < 0)) return 0;
            const r = @abs(c) / @abs(p);
            if (r < 1) f *= r;
        }
    }
    return f;
}

/// Read a packed point-number list (the deltas-from-previous encoding), writing
/// the indices to `out`. Returns how many were written and advances `at`.
fn readPoints(src: []const u8, at: *usize, out: []u16) Error!usize {
    if (at.* >= src.len) return error.Malformed;
    const b = src[at.*];
    at.* += 1;
    var count: usize = b;
    if (b & 0x80 != 0) {
        if (at.* >= src.len) return error.Malformed;
        count = (@as(usize, b & 0x7F) << 8) | src[at.*];
        at.* += 1;
    }
    var i: usize = 0;
    var last: u32 = 0;
    while (i < count) {
        if (at.* >= src.len) return error.Malformed;
        const ctl = src[at.*];
        at.* += 1;
        const run: usize = @as(usize, ctl & 0x7F) + 1;
        var k: usize = 0;
        while (k < run and i < count) : (k += 1) {
            if (ctl & 0x80 != 0) {
                last += try u16At(src, at.*);
                at.* += 2;
            } else {
                if (at.* >= src.len) return error.Malformed;
                last += src[at.*];
                at.* += 1;
            }
            if (i >= out.len or last >= 0xFFFF) return error.Malformed;
            out[i] = @intCast(last);
            i += 1;
        }
    }
    return i;
}

/// Read a packed delta run, scattering each value to its point as it goes.
///
/// The delta list is positional and the point list is not, so the two cannot
/// share a buffer: an empty `mapping` means "in order, all points", which is
/// what a tuple with no point list has. Values for indices past `n_points` are
/// the phantom points, which only carry advances, so they are dropped.
fn readDeltasMapped(
    src: []const u8,
    at: *usize,
    count: usize,
    mapping: []const u16,
    n_points: usize,
    out: []f32,
) Error!void {
    var i: usize = 0;
    while (i < count) {
        if (at.* >= src.len) return error.Malformed;
        const ctl = src[at.*];
        at.* += 1;
        var run: usize = @as(usize, ctl & 0x3F) + 1;
        const is_zero = ctl & 0x80 != 0;
        const is_word = ctl & 0x40 != 0;
        while (run > 0 and i < count) : ({
            run -= 1;
            i += 1;
        }) {
            var v: f32 = 0;
            if (is_zero) {
                v = 0;
            } else if (is_word) {
                v = @floatFromInt(try i16At(src, at.*));
                at.* += 2;
            } else {
                if (at.* >= src.len) return error.Malformed;
                v = @floatFromInt(@as(i8, @bitCast(src[at.*])));
                at.* += 1;
            }
            const dest: usize = if (mapping.len == 0)
                i
            else if (i < mapping.len) mapping[i] else 0xFFFF;
            if (dest < n_points) out[dest] = v;
        }
    }
}

/// Interpolate the untouched points of one contour. Untouched points take the
/// value of whichever side they sit on, which is what makes a delta on one
/// point move a whole stem.
fn iupContour(
    xs: []const f32,
    ys: []const f32,
    dx: []f32,
    dy: []f32,
    touched: []bool,
    first: usize,
    count: usize,
) void {
    if (count == 0) return;
    var n_touched: usize = 0;
    var first_touched: usize = 0;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        if (touched[first + k]) {
            if (n_touched == 0) first_touched = k;
            n_touched += 1;
        }
    }
    if (n_touched == 0) {
        k = 0;
        while (k < count) : (k += 1) {
            dx[first + k] = 0;
            dy[first + k] = 0;
        }
        return;
    }
    if (n_touched == count) return;

    var pos: usize = 0;
    while (pos < count) {
        const a = first + (first_touched + pos) % count;
        var step: usize = 1;
        while (step < count and !touched[first + (first_touched + pos + step) % count]) : (step += 1) {}
        const b = first + (first_touched + pos + step) % count;
        var t: usize = 1;
        while (t < step) : (t += 1) {
            const m = first + (first_touched + pos + t) % count;
            inline for (.{ true, false }) |is_x| {
                const src: []const f32 = if (is_x) xs else ys;
                const dst: []f32 = if (is_x) dx else dy;
                // A point outside its two references' coordinates takes the
                // NEARER reference's delta. Extrapolating instead reaches
                // values neither reference has, which is not what a hinted
                // outline going through the same positions does.
                //
                // Two references sharing a coordinate on this axis say nothing
                // about where the point sits between them, so there is no
                // basis for a weighted answer: the axis gets NO movement
                // unless both references agree on one. Carrying the lower
                // reference's delta is the tempting shortcut and it is wrong
                // -- on a vertical stem it slides the point sideways.
                dst[m] = if (src[b] == src[a])
                    (if (dst[b] == dst[a]) dst[a] else 0)
                else blk: {
                    const frac = (src[m] - src[a]) / (src[b] - src[a]);
                    if (frac <= 0) break :blk dst[a];
                    if (frac >= 1) break :blk dst[b];
                    break :blk dst[a] + frac * (dst[b] - dst[a]);
                };
            }
        }
        pos += step;
    }
}

/// Apply one glyph's variations to `dx`/`dy`, which come back holding the total
/// offset per point in font units.
///
/// Returns false when the glyph has no variation data, which is the ordinary
/// case: a face varies the glyphs that move, not every glyph.
///
/// Nothing here touches `xs`/`ys` -- they are the DEFAULT coordinates, and
/// interpolation is defined against them, so the deltas accumulate separately
/// and the caller adds them at the end.
pub fn applyGlyph(
    d: []const u8, // the gvar table
    coords: []const f32,
    gid: u16,
    n_points: usize,
    ends: []const u16,
    xs: []const f32,
    ys: []const f32,
    dx: []f32,
    dy: []f32,
    touched: []bool,
    pt_idx: []u16,
    tmp_x: []f32,
    tmp_y: []f32,
) Error!bool {
    if (d.len < 20 or n_points == 0 or n_points > dx.len) return false;
    const axis_count = try u16At(d, 4);
    if (axis_count > max_axes) return false;
    const glyph_count = try u16At(d, 12);
    if (gid >= glyph_count) return false;
    const flags = try u16At(d, 14);
    const data_at: usize = try u32At(d, 16);
    if (data_at >= d.len) return false;

    // Offset array format: long = uint32 entries, short = uint16 entries at
    // HALF the stride, so the short path indexes with gid * 2, not gid * 4.
    // Inter ships long offsets and hid this; a short-offset face shifted every
    // glyph onto another glyph's deltas (glyph 18 read glyph 36's entries).
    const long = (flags & 1) != 0;
    const o0: usize = if (long) try u32At(d, 20 + @as(usize, gid) * 4) else @as(usize, try u16At(d, 20 + @as(usize, gid) * 2)) * 2;
    const o1: usize = if (long) try u32At(d, 20 + (@as(usize, gid) + 1) * 4) else @as(usize, try u16At(d, 20 + (@as(usize, gid) + 1) * 2)) * 2;
    if (o1 <= o0) return false;
    if (data_at + o1 > d.len) return error.Malformed;
    const gd = d[data_at + o0 ..][0 .. o1 - o0];

    const tv_count = try u16At(gd, 0);
    const n_tuples = tv_count & 0x0FFF;
    const shared_points = (tv_count & 0x8000) != 0;
    if (n_tuples == 0) return false;
    const data_cursor: usize = try u16At(gd, 2);
    if (data_cursor > gd.len) return error.Malformed;

    // The shared point numbers are the first thing in the serialized data
    // region, and dataOffset points at THEM, not at the first tuple's deltas.
    // Reading tuple data from dataOffset therefore starts two bytes early when
    // a face shares a point list, which silently shifts every delta.
    const shared_at = data_cursor;
    var tuple_at: usize = data_cursor;
    var shared_n: usize = 0;
    if (shared_points) shared_n = try readPoints(gd, &tuple_at, pt_idx);

    @memset(dx[0..n_points], 0);
    @memset(dy[0..n_points], 0);
    var any = false;

    var header: usize = 4;
    var h: usize = 0;
    while (h < n_tuples) : (h += 1) {
        const size: usize = try u16At(gd, header);
        const idx = try u16At(gd, header + 2);
        header += 4;

        var peak: [max_axes]f32 = @splat(0);
        var lo: [max_axes]f32 = @splat(0);
        var hi: [max_axes]f32 = @splat(0);
        const has_peak = (idx & 0x8000) != 0;
        const has_mid = (idx & 0x4000) != 0;
        const private_points = (idx & 0x2000) != 0;
        const shared_index: usize = idx & 0x0FFF;

        if (has_peak) {
            var a: usize = 0;
            while (a < axis_count) : (a += 1) peak[a] = f2d(try i16At(gd, header + a * 2));
            header += @as(usize, axis_count) * 2;
        } else {
            const shared_count = try u16At(d, 6);
            if (shared_index >= shared_count) return error.Malformed;
            const sto = try u32At(d, 8);
            var a: usize = 0;
            while (a < axis_count) : (a += 1) {
                const o = sto + shared_index * @as(usize, axis_count) * 2 + a * 2;
                peak[a] = f2d(try i16At(d, o));
            }
        }
        if (has_mid) {
            var a: usize = 0;
            while (a < axis_count) : (a += 1) lo[a] = f2d(try i16At(gd, header + a * 2));
            header += @as(usize, axis_count) * 2;
            a = 0;
            while (a < axis_count) : (a += 1) hi[a] = f2d(try i16At(gd, header + a * 2));
            header += @as(usize, axis_count) * 2;
        }

        if (tuple_at + size > gd.len) return error.Malformed;
        const tuple_data = gd[tuple_at..][0..size];
        tuple_at += size;

        const scalar = tupleScalar(
            peak[0..axis_count],
            if (has_mid) lo[0..axis_count] else null,
            if (has_mid) hi[0..axis_count] else null,
            coords,
        );
        // A tuple outside its region costs nothing, but its block still has to
        // be stepped over or every tuple after it decodes the wrong bytes.
        if (scalar == 0) continue;

        var at: usize = 0;
        var n_pts: usize = 0;
        if (private_points) {
            // This tuple's own point list, first in its data block.
            n_pts = try readPoints(tuple_data, &at, pt_idx);
        } else if (shared_n != 0) {
            // Re-read rather than trust pt_idx: an earlier tuple may have
            // overwritten it with a private list of its own.
            var sa = shared_at;
            _ = try readPoints(gd, &sa, pt_idx);
            n_pts = shared_n;
        }
        const n_deltas = if (n_pts != 0) n_pts else n_points + 4;

        var i: usize = 0;
        while (i < n_points) : (i += 1) {
            tmp_x[i] = 0;
            tmp_y[i] = 0;
            touched[i] = false;
        }
        if (n_pts != 0) {
            try readDeltasMapped(tuple_data, &at, n_deltas, pt_idx[0..n_pts], n_points, tmp_x);
            try readDeltasMapped(tuple_data, &at, n_deltas, pt_idx[0..n_pts], n_points, tmp_y);
            i = 0;
            while (i < n_pts) : (i += 1) {
                const p = pt_idx[i];
                if (p < n_points) touched[p] = true;
            }
        } else {
            try readDeltasMapped(tuple_data, &at, n_deltas, &.{}, n_points, tmp_x);
            try readDeltasMapped(tuple_data, &at, n_deltas, &.{}, n_points, tmp_y);
            i = 0;
            while (i < n_points) : (i += 1) touched[i] = true;
        }

        var c: usize = 0;
        var start: usize = 0;
        while (c < ends.len) : (c += 1) {
            const last = @as(usize, ends[c]);
            if (last >= n_points) break;
            iupContour(xs, ys, tmp_x, tmp_y, touched, start, last - start + 1);
            start = last + 1;
        }

        i = 0;
        while (i < n_points) : (i += 1) {
            dx[i] += scalar * tmp_x[i];
            dy[i] += scalar * tmp_y[i];
        }
        any = true;
    }
    return any;
}

test "a normalised axis lands on the F2Dot14 grid" {
    const a = Axis{ .tag = 0, .min = 100, .default = 400, .max = 900 };
    // (700 - 400) / (900 - 400) = 0.6, which 16.14 cannot represent: the grid
    // step is 1/16384, so the nearest value is 9830/16384 = 0.599976. Getting
    // this wrong moves a scalar product across a rounding boundary and a whole
    // glyph lands one unit off, which is exactly what the oracles caught.
    try std.testing.expectEqual(@as(f32, 9830.0 / 16384.0), normalizeAxis(a, 700, &.{}, 0));
    // The default sits exactly on zero rather than one step away from it.
    try std.testing.expectEqual(@as(f32, 0), normalizeAxis(a, 400, &.{}, 0));
    // And the ends are exact, so a peak of 1 gets a scalar of exactly 1.
    try std.testing.expectEqual(@as(f32, 1), normalizeAxis(a, 700, &.{}, 0) * 0 + normalizeAxis(a, 900, &.{}, 0));
}

test "IUP yields no delta when both references share a coordinate" {
    // Contour (0,0) (100,0) (50,0) (100,0) with point 2 untouched. Its two
    // references, points 1 and 3, both sit at x=100 but carry different deltas,
    // so there is no ramp to read: the rule is zero, not the first reference's
    // value. This one case was 695 wrong glyphs' worth of trouble.
    const xs = [_]f32{ 0, 100, 50, 100 };
    const ys = [_]f32{ 0, 0, 0, 0 };
    var dx = [_]f32{ 7, 30, 0, 12 };
    var dy = [_]f32{ 0, 0, 0, 0 };
    var touched = [_]bool{ true, true, false, true };
    iupContour(&xs, &ys, &dx, &dy, &touched, 0, 4);
    try std.testing.expectEqual(@as(f32, 0), dx[2]);

    // A point strictly between two references still interpolates linearly, so
    // the equal-coordinate rule cannot have swallowed the ordinary path. The
    // references here are points 0 and 3 (both ends of the walk), so x=50 lands
    // halfway and takes half of the 90 unit delta.
    const xs2 = [_]f32{ 0, 20, 50, 100 };
    var dx2 = [_]f32{ 0, 0, 0, 90 };
    var dy2 = [_]f32{ 0, 0, 0, 0 };
    var touched2 = [_]bool{ true, false, false, true };
    iupContour(&xs2, &ys, &dx2, &dy2, &touched2, 0, 4);
    try std.testing.expectEqual(@as(f32, 45), dx2[2]);
    try std.testing.expectEqual(@as(f32, 18), dx2[1]);
}
