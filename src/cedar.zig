//! Cedar -- a TrueType rasteriser.
//!
//! Slice 1 is the table layer and glyph metrics: enough to answer "which glyph
//! is this codepoint, how wide is it, and where is the baseline" without
//! rasterising anything. Coverage follows, and it is the part that has to be
//! right rather than merely plausible.
//!
//! What this is NOT: no hinting (the reference implementation, stb_truetype,
//! skips it too, so unhinted is the bar), no CFF outlines, no variable axes, no
//! colour fonts, no shaping or kerning. Cedar v1 reads `glyf`-based fonts.
//!
//! Two rules that shape the code:
//!
//! 1. **No allocator and no IO.** The font is bytes the caller owns; nothing
//!    here reaches outside them.
//! 2. **The spec decides, not the reference.** `oracle/` carries stb_truetype
//!    as a differential oracle. Where the two disagree, the disagreement is a
//!    finding to write down, not a bug in Cedar by default. One such case is
//!    already documented at `cmapFormat4`.

const std = @import("std");

pub const Error = error{
    /// A read ran past the end of the font.
    Truncated,
    /// Not an sfnt at all.
    NotSfnt,
    /// An OpenType/CFF font: outlines are PostScript, not `glyf`.
    CffNotSupported,
    /// A table the font needs is absent, or empty.
    MissingTable,
    /// No `cmap` subtable we can read (v1: formats 4 and 12).
    UnsupportedCmap,
    /// A glyph id at or past `num_glyphs`.
    UnknownGlyph,
    /// A composite glyph whose components are placed by matching points
    /// rather than by an offset. Rare; v1 does not decode it.
    UnsupportedComposite,
    /// The caller's point or contour buffer is too small for this glyph.
    BufferTooSmall,
    /// Composite glyphs nested deeper than `max_composite_depth`.
    CompositeTooDeep,
};

/// Vertical metrics in FONT UNITS. Scaling to pixels is the caller's job,
/// because the divisor is a policy choice (see `unitsPerEm`).
pub const VMetrics = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
};

/// Horizontal metrics in FONT UNITS.
pub const HMetrics = struct {
    advance: u16,
    /// Left side bearing: distance from the origin to the left edge of the ink.
    lsb: i16,
};

/// One decoded outline point, in FONT UNITS. `on` is the on-curve flag: an
/// off-curve point is a quadratic control point between its neighbours.
pub const Point = struct { x: i32, y: i32, on: bool };

/// A glyph outline: all points, and the index of the LAST point of each
/// contour. Contours wrap, so the point after `ends[i]` starts contour i+1.
pub const Outline = struct {
    points: []Point,
    ends: []u16,
};

/// Ink bounds in FONT UNITS, control points included -- the same box the
/// rasteriser is about to map to pixels.
pub const Box = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

pub fn outlineBounds(o: Outline) Box {
    if (o.points.len == 0) return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    var b = Box{
        .x0 = o.points[0].x,
        .y0 = o.points[0].y,
        .x1 = o.points[0].x,
        .y1 = o.points[0].y,
    };
    for (o.points[1..]) |pt| {
        b.x0 = @min(b.x0, pt.x);
        b.y0 = @min(b.y0, pt.y);
        b.x1 = @max(b.x1, pt.x);
        b.y1 = @max(b.y1, pt.y);
    }
    return b;
}

/// Composite glyphs are inlined; eight is more nesting than any real font
/// uses and stops a malformed one from recursing forever.
pub const max_composite_depth = 8;

const Span = struct { off: u32 = 0, len: u32 = 0 };

fn tag(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

const tag_cmap = tag("cmap");
const tag_head = tag("head");
const tag_hhea = tag("hhea");
const tag_hmtx = tag("hmtx");
const tag_maxp = tag("maxp");
const tag_glyf = tag("glyf");
const tag_loca = tag("loca");

/// One loaded face. Borrows the bytes; they must outlive it.
pub const Font = struct {
    data: []const u8 = &.{},
    units_per_em: u16 = 0,
    num_glyphs: u16 = 0,
    ascender: i16 = 0,
    descender: i16 = 0,
    line_gap: i16 = 0,
    num_hmetrics: u16 = 0,
    index_to_loc: i16 = 0,

    cmap: Span = .{},
    cmap_format: u16 = 0,
    head: Span = .{},
    hhea: Span = .{},
    hmtx: Span = .{},
    maxp: Span = .{},
    glyf: Span = .{},
    loca: Span = .{},

    /// Parse the table directory and the metrics a caller needs up front.
    /// Fails loudly: a font Cedar cannot read should not silently measure zero.
    pub fn init(bytes: []const u8) Error!Font {
        const sfnt = try u32At(bytes, 0);
        switch (sfnt) {
            0x0001_0000, tag("true") => {},
            tag("OTTO") => return error.CffNotSupported,
            else => return error.NotSfnt,
        }

        var self: Font = .{ .data = bytes };
        const n = try u16At(bytes, 4);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = 12 + i * 16;
            const t = try u32At(bytes, rec);
            const span = Span{ .off = try u32At(bytes, rec + 8), .len = try u32At(bytes, rec + 12) };
            if (t == tag_cmap) self.cmap = span;
            if (t == tag_head) self.head = span;
            if (t == tag_hhea) self.hhea = span;
            if (t == tag_hmtx) self.hmtx = span;
            if (t == tag_maxp) self.maxp = span;
            if (t == tag_glyf) self.glyf = span;
            if (t == tag_loca) self.loca = span;
        }

        const head = try self.slice(self.head);
        const hhea = try self.slice(self.hhea);
        const maxp = try self.slice(self.maxp);
        _ = try self.slice(self.hmtx);
        _ = try self.slice(self.glyf);

        self.units_per_em = try u16At(head, 18);
        self.index_to_loc = try i16At(head, 50);
        self.ascender = try i16At(hhea, 4);
        self.descender = try i16At(hhea, 6);
        self.line_gap = try i16At(hhea, 8);
        self.num_hmetrics = try u16At(hhea, 34);
        self.num_glyphs = try u16At(maxp, 4);

        if (self.units_per_em == 0) return error.MissingTable;
        if (self.num_hmetrics == 0) return error.MissingTable;

        // `loca` is indexed up to num_glyphs inclusive. A table that is short
        // would let glyph lookups read into the next table, so check once here.
        const loca_len = (try self.slice(self.loca)).len;
        const entry: usize = if (self.index_to_loc == 0) 2 else 4;
        if (loca_len < (@as(usize, self.num_glyphs) + 1) * entry) return error.Truncated;

        // Choose the character map once, so a font we cannot map fails at load
        // rather than per glyph.
        self.cmap_format = try self.selectCmap();
        if (self.cmap_format != 4 and self.cmap_format != 12) return error.UnsupportedCmap;

        return self;
    }

    fn slice(self: Font, span: Span) Error![]const u8 {
        if (span.len == 0) return error.MissingTable;
        const off: usize = span.off;
        const end = off + @as(usize, span.len);
        if (end > self.data.len) return error.Truncated;
        return self.data[off..end];
    }

    /// Pick a `cmap` subtable and return its format.
    ///
    /// The policy is deliberately the same one the previous backend used: walk
    /// the encoding records in file order and let the last one we understand
    /// win. Microsoft full-repertoire (3,10) beats Microsoft BMP (3,1) only
    /// because a well-formed font lists it later. The alternative -- scoring
    /// records -- would pick a different subtable on some fonts and move text
    /// on a swap, for no gain.
    fn selectCmap(self: *Font) Error!u16 {
        const cm = try self.slice(self.cmap);
        const n = try u16At(cm, 2);
        var chosen: ?u32 = null;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = 4 + i * 8;
            const plat = try u16At(cm, rec);
            const enc = try u16At(cm, rec + 2);
            const off = try u32At(cm, rec + 4);
            const ok = switch (plat) {
                3 => enc == 1 or enc == 10,
                0 => true,
                else => false,
            };
            if (ok) chosen = off;
        }

        const off = chosen orelse return error.UnsupportedCmap;
        if (@as(usize, off) + 2 > cm.len) return error.Truncated;
        self.cmap = .{ .off = self.cmap.off + off, .len = @intCast(cm.len - @as(usize, off)) };
        return u16At(cm, off);
    }

    pub fn vMetrics(self: Font) VMetrics {
        return .{ .ascender = self.ascender, .descender = self.descender, .line_gap = self.line_gap };
    }

    /// Glyph id for a codepoint. 0 means `.notdef`, per the format.
    pub fn glyphIndex(self: Font, cp: u21) Error!u16 {
        const cm = try self.slice(self.cmap);
        return switch (self.cmap_format) {
            4 => cmapFormat4(cm, 0, cp),
            12 => cmapFormat12(cm, 0, cp),
            else => error.UnsupportedCmap,
        };
    }

    /// Decode a glyph's outline into the caller's buffers, in font units.
    ///
    /// No allocation anywhere: `points` and `ends` are scratch the caller
    /// owns and reuses. A blank glyph (or one with no contours) decodes to an
    /// empty outline rather than an error, because that is a legal glyph.
    pub fn outline(self: Font, gid: u16, points: []Point, ends: []u16) Error!Outline {
        if (gid >= self.num_glyphs) return error.UnknownGlyph;
        var cur = Cursor{ .points = points, .ends = ends };
        try decodeInto(self, gid, &cur, 0);
        return .{ .points = points[0..cur.n], .ends = ends[0..cur.nc] };
    }

    /// Horizontal metrics for a glyph. Ids past `numberOfHMetrics` repeat the
    /// last advance and read their bearing from the trailing array -- that is
    /// the format, not a shortcut.
    pub fn hMetrics(self: Font, gid: u16) Error!HMetrics {
        if (gid >= self.num_glyphs) return error.UnknownGlyph;
        const hm = try self.slice(self.hmtx);

        if (gid < self.num_hmetrics) {
            const at = @as(usize, gid) * 4;
            return .{ .advance = try u16At(hm, at), .lsb = try i16At(hm, at + 2) };
        }

        const last = self.num_hmetrics - 1;
        const advance = try u16At(hm, @as(usize, last) * 4);
        const lsb_at = @as(usize, self.num_hmetrics) * 4 + @as(usize, gid - self.num_hmetrics) * 2;
        return .{ .advance = advance, .lsb = try i16At(hm, lsb_at) };
    }
};

// ---------------------------------------------------------------------------
// character maps
// ---------------------------------------------------------------------------

/// Format 4: segment mapping to delta values.
///
/// KNOWN DIVERGENCE FROM stb_truetype, in Cedar's favour. The spec applies
/// `idDelta` to the value fetched through `idRangeOffset`; stb returns the
/// fetched value unchanged. On a font that combines a non-zero delta with a
/// non-zero range offset the two disagree, and Cedar is the one following the
/// spec. The oracle run reports that as a mismatch only if a font in test uses
/// the combination; the synthetic test below pins our behaviour either way.
fn cmapFormat4(cm: []const u8, base: usize, cp: u21) Error!u16 {
    if (cp > 0xFFFF) return 0;
    const c: u16 = @intCast(cp);

    const seg_x2 = try u16At(cm, base + 6);
    const seg: usize = seg_x2 / 2;
    if (seg == 0) return 0;

    const ends = base + 14;
    const starts = ends + seg_x2 + 2;
    const deltas = starts + seg_x2;
    const ranges = deltas + seg_x2;

    // Binary search for the first segment whose endCode >= c. We search on
    // endCode arrays rather than trusting the header's searchRange /
    // entrySelector fields, which a malformed font can get wrong.
    var lo: usize = 0;
    var hi: usize = seg;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = try u16At(cm, ends + mid * 2);
        if (e < c) lo = mid + 1 else hi = mid;
    }
    if (lo >= seg) return 0;

    const start = try u16At(cm, starts + lo * 2);
    const end = try u16At(cm, ends + lo * 2);
    if (c < start or c > end) return 0;

    const delta = try u16At(cm, deltas + lo * 2);
    const range_at = ranges + lo * 2;
    const range = try u16At(cm, range_at);
    if (range == 0) return c +% delta;

    // The offset is relative to its own slot, not to the table.
    const gid_at = range_at + @as(usize, range) + 2 * @as(usize, c - start);
    const gid = try u16At(cm, gid_at);
    if (gid == 0) return 0;
    return gid +% delta;
}

/// Format 12: segmented coverage, the one that reaches past the BMP.
fn cmapFormat12(cm: []const u8, base: usize, cp: u21) Error!u16 {
    const n = try u32At(cm, base + 12);
    const groups = base + 16;

    var lo: u32 = 0;
    var hi: u32 = n;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const g = groups + @as(usize, mid) * 12;
        const start = try u32At(cm, g);
        const end = try u32At(cm, g + 4);
        if (@as(u32, cp) < start) {
            hi = mid;
        } else if (@as(u32, cp) > end) {
            lo = mid + 1;
        } else {
            const start_gid = try u32At(cm, g + 8);
            const gid = start_gid + (@as(u32, cp) - start);
            return if (gid > 0xFFFF) 0 else @intCast(gid);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// outlines
// ---------------------------------------------------------------------------

const Cursor = struct {
    points: []Point,
    n: usize = 0,
    ends: []u16,
    nc: usize = 0,

    fn room(self: Cursor, count: usize) Error!void {
        if (self.n + count > self.points.len) return error.BufferTooSmall;
    }

    fn roomContour(self: Cursor) Error!void {
        if (self.nc + 1 > self.ends.len) return error.BufferTooSmall;
    }
};

/// Walks the run-length-encoded flag stream. Three passes read it (on-curve,
/// x, y) instead of storing a flag per point, so the decoder stays
/// allocation-free without capping point counts.
const FlagWalk = struct {
    at: usize,
    left: u32 = 0,
    cur: u8 = 0,

    fn next(self: *FlagWalk, data: []const u8) Error!u8 {
        if (self.left == 0) {
            self.cur = try u8At(data, self.at);
            self.at += 1;
            if (self.cur & 8 != 0) {
                self.left = try u8At(data, self.at);
                self.at += 1;
            }
        } else {
            self.left -= 1;
        }
        return self.cur;
    }
};

fn f2dot14(raw: i16) f32 {
    return @as(f32, @floatFromInt(raw)) / 16384.0;
}

/// The glyph's byte range in `glyf`, via `loca`.
fn glyphRange(self: Font, gid: u16) Error![]const u8 {
    const loca = try self.slice(self.loca);
    const glyf = try self.slice(self.glyf);
    const i: usize = gid;
    const a: u32 = if (self.index_to_loc == 0)
        @as(u32, try u16At(loca, i * 2)) * 2
    else
        try u32At(loca, i * 4);
    const b: u32 = if (self.index_to_loc == 0)
        @as(u32, try u16At(loca, (i + 1) * 2)) * 2
    else
        try u32At(loca, (i + 1) * 4);

    if (a > b) return error.Truncated;
    if (@as(usize, b) > glyf.len) return error.Truncated;
    return glyf[a..b];
}

fn decodeInto(self: Font, gid: u16, cur: *Cursor, depth: u32) Error!void {
    const data = try glyphRange(self, gid);
    // A blank glyph: loca gives it an empty range.
    if (data.len == 0) return;

    const n_contours = try i16At(data, 0);
    if (n_contours == 0) return;
    if (n_contours > 0) {
        try decodeSimple(data, @intCast(n_contours), cur);
    } else {
        try decodeComposite(self, data, cur, depth);
    }
}

fn decodeSimple(data: []const u8, n_contours: usize, cur: *Cursor) Error!void {
    const ends_at = 10;
    const last_end = try u16At(data, ends_at + (n_contours - 1) * 2);
    const n: usize = @as(usize, last_end) + 1;
    try cur.room(n);

    const instr_at = ends_at + n_contours * 2;
    const instr_len = try u16At(data, instr_at);
    const flags_at = instr_at + 2 + @as(usize, instr_len);

    // Pass 1: find where the coordinate data starts, and record on-curve.
    const base = cur.n;
    {
        var fw = FlagWalk{ .at = flags_at };
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const fl = try fw.next(data);
            cur.points[base + k] = .{ .x = 0, .y = 0, .on = fl & 1 != 0 };
        }
        // Pass 2: x, starting where the flag stream ended.
        var x: i32 = 0;
        var at = fw.at;
        fw = FlagWalk{ .at = flags_at };
        k = 0;
        while (k < n) : (k += 1) {
            const fl = try fw.next(data);
            if (fl & 2 != 0) {
                const dx = try u8At(data, at);
                at += 1;
                x += if (fl & 16 != 0) @as(i32, dx) else -@as(i32, dx);
            } else if (fl & 16 == 0) {
                x += try i16At(data, at);
                at += 2;
            }
            cur.points[base + k].x = x;
        }

        // Pass 3: y, continuing from where x left off.
        var y: i32 = 0;
        fw = FlagWalk{ .at = flags_at };
        k = 0;
        while (k < n) : (k += 1) {
            const fl = try fw.next(data);
            if (fl & 4 != 0) {
                const dy = try u8At(data, at);
                at += 1;
                y += if (fl & 32 != 0) @as(i32, dy) else -@as(i32, dy);
            } else if (fl & 32 == 0) {
                y += try i16At(data, at);
                at += 2;
            }
            cur.points[base + k].y = y;
        }
    }

    var j: usize = 0;
    while (j < n_contours) : (j += 1) {
        const end = try u16At(data, ends_at + j * 2);
        try cur.roomContour();
        cur.ends[cur.nc] = @intCast(base + @as(usize, end));
        cur.nc += 1;
    }
    cur.n = base + n;
}

/// Composite glyphs.
///
/// SECOND KNOWN DIVERGENCE FROM stb_truetype. The spec applies the 2x2 matrix
/// as given; stb additionally multiplies by the sqrt of each column's norm
/// (`m = sqrt(a*a + b*b)`), which squares a uniform scale. Cedar follows the
/// spec. The two agree on the common case -- accents placed by translation
/// with no matrix -- and disagree on scaled composites, which is exactly the
/// kind of thing the differential is there to point at.
fn decodeComposite(self: Font, data: []const u8, cur: *Cursor, depth: u32) Error!void {
    if (depth >= max_composite_depth) return error.CompositeTooDeep;

    var p: usize = 10;
    var flags: u16 = 1 << 5; // enter the loop
    while (flags & (1 << 5) != 0) {
        flags = try u16At(data, p);
        p += 2;
        const gid = try u16At(data, p);
        p += 2;

        var a: f32 = 1;
        var b: f32 = 0;
        var c: f32 = 0;
        var d: f32 = 1;
        var dx: f32 = 0;
        var dy: f32 = 0;

        if (flags & 0x0002 != 0) {
            if (flags & 0x0001 != 0) {
                dx = @floatFromInt(try i16At(data, p));
                p += 2;
                dy = @floatFromInt(try i16At(data, p));
                p += 2;
            } else {
                dx = @floatFromInt(@as(i8, @bitCast(try u8At(data, p))));
                p += 1;
                dy = @floatFromInt(@as(i8, @bitCast(try u8At(data, p))));
                p += 1;
            }
        } else {
            // Component placement by matching points.
            return error.UnsupportedComposite;
        }

        if (flags & 0x0008 != 0) {
            const s = f2dot14(try i16At(data, p));
            p += 2;
            a = s;
            d = s;
        } else if (flags & 0x0040 != 0) {
            a = f2dot14(try i16At(data, p));
            p += 2;
            d = f2dot14(try i16At(data, p));
            p += 2;
        } else if (flags & 0x0080 != 0) {
            a = f2dot14(try i16At(data, p));
            p += 2;
            b = f2dot14(try i16At(data, p));
            p += 2;
            c = f2dot14(try i16At(data, p));
            p += 2;
            d = f2dot14(try i16At(data, p));
            p += 2;
        }

        const start = cur.n;
        try decodeInto(self, gid, cur, depth + 1);

        for (cur.points[start..cur.n]) |*pt| {
            const px: f32 = @floatFromInt(pt.x);
            const py: f32 = @floatFromInt(pt.y);
            pt.x = @intFromFloat(@round(a * px + c * py + dx));
            pt.y = @intFromFloat(@round(b * px + d * py + dy));
        }
    }

    if (flags & 0x0100 != 0) {
        // WE_HAVE_INSTRUCTIONS follows the last component; nothing to decode.
        const len = try u16At(data, p);
        p += 2 + @as(usize, len);
    }
}

// ---------------------------------------------------------------------------
// bounds-checked big-endian reads
// ---------------------------------------------------------------------------

fn u8At(b: []const u8, off: usize) Error!u8 {
    if (off >= b.len) return error.Truncated;
    return b[off];
}

fn u16At(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.Truncated;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn i16At(b: []const u8, off: usize) Error!i16 {
    return @bitCast(try u16At(b, off));
}

fn u32At(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.Truncated;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

// ---------------------------------------------------------------------------
// tests: a synthetic font, so the suite needs no font file
// ---------------------------------------------------------------------------

fn w16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .big);
}

fn w32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .big);
}

const W = struct {
    buf: []u8,
    at: usize = 0,

    fn u8v(self: *W, v: u8) void {
        self.buf[self.at] = v;
        self.at += 1;
    }
    fn u16v(self: *W, v: u16) void {
        w16(self.buf, self.at, v);
        self.at += 2;
    }
    fn i16v(self: *W, v: i16) void {
        w16(self.buf, self.at, @bitCast(v));
        self.at += 2;
    }
    fn u32v(self: *W, v: u32) void {
        w32(self.buf, self.at, v);
        self.at += 4;
    }
    fn zeros(self: *W, n: usize) void {
        @memset(self.buf[self.at..][0..n], 0);
        self.at += n;
    }
};

const Rec = struct { at: usize, len: usize };

fn patchRec(buf: []u8, rec: usize, t: u32, off: usize, len: usize) void {
    w32(buf, rec, t);
    w32(buf, rec + 8, @intCast(off));
    w32(buf, rec + 12, @intCast(len));
}

/// A minimal 8-glyph face, unitsPerEm 1024, three horizontal metrics, one
/// format-4 character map (plus a format-12 one when asked).
///
/// Format-4 layout on purpose:
///   'A' -> non-zero idRangeOffset, glyphIdArray holds 1, idDelta 5  => gid 6
///   'B' -> delta only, idDelta -0x40                                => gid 2
///   'C' -> unmapped                                                 => gid 0
/// and the format-12 map, when present, remaps 'A'..'B' to gid 1..2 and puts
/// U+1F600 at gid 7 so a codepoint above the BMP is covered.
fn buildTestFont(buf: []u8, with_fmt12: bool) []const u8 {
    var w = W{ .buf = buf };

    w.u32v(0x0001_0000); // sfnt version
    w.u16v(7); // numTables
    w.u16v(0);
    w.u16v(0);
    w.u16v(0);
    const rec_base = w.at;
    w.zeros(7 * 16);

    // --- cmap ---
    const cmap_start = w.at;
    w.u16v(0); // version
    w.u16v(if (with_fmt12) 2 else 1);
    const rec0 = w.at;
    w.u16v(3);
    w.u16v(1);
    w.u32v(0);
    var rec1: usize = 0;
    if (with_fmt12) {
        rec1 = w.at;
        w.u16v(3);
        w.u16v(10);
        w.u32v(0);
    }

    const f4 = w.at;
    w.u16v(4);
    const len4_at = w.at;
    w.u16v(0); // length, patched
    w.u16v(0); // language
    w.u16v(6); // segCountX2
    w.u16v(4); // searchRange
    w.u16v(1); // entrySelector
    w.u16v(2); // rangeShift
    w.u16v(0x41); // endCode
    w.u16v(0x42);
    w.u16v(0xFFFF);
    w.u16v(0); // reservedPad
    w.u16v(0x41); // startCode
    w.u16v(0x42);
    w.u16v(0xFFFF);
    w.i16v(5); // idDelta
    w.i16v(@bitCast(@as(u16, 0xFFC0)));
    w.i16v(1);
    w.u16v(6); // idRangeOffset[0] -> glyphIdArray[0]
    w.u16v(0);
    w.u16v(0);
    w.u16v(1); // glyphIdArray[0]
    w16(buf, len4_at, @intCast(w.at - f4));
    w32(buf, rec0 + 4, @intCast(f4 - cmap_start));

    if (with_fmt12) {
        const f12 = w.at;
        w.u16v(12);
        w.u16v(0);
        const len12_at = w.at;
        w.u32v(0); // length, patched
        w.u32v(0); // language
        w.u32v(2); // nGroups
        w.u32v(0x41);
        w.u32v(0x42);
        w.u32v(1);
        w.u32v(0x1F600);
        w.u32v(0x1F600);
        w.u32v(7);
        w32(buf, len12_at, @intCast(w.at - f12));
        w32(buf, rec1 + 4, @intCast(f12 - cmap_start));
    }
    const r_cmap = Rec{ .at = cmap_start, .len = w.at - cmap_start };

    // --- glyf: gid 6 is a triangle, gid 7 is gid 6 shifted right 200 ---
    const glyf_start = w.at;
    w.i16v(1); // numberOfContours
    w.i16v(0);
    w.i16v(0);
    w.i16v(100);
    w.i16v(100); // bbox
    w.u16v(2); // endPtsOfContours[0]
    w.u16v(0); // instructionLength
    w.u8v(0x37); // on | x-short | y-short | x-same | y-same
    w.u8v(0x37);
    w.u8v(0x27); // dx negative, dy positive
    w.u8v(0); // x deltas: 0, +100, -50
    w.u8v(100);
    w.u8v(50);
    w.u8v(0); // y deltas: 0, 0, +100
    w.u8v(0);
    w.u8v(100);
    w.zeros(1); // pad to even
    const tri_len = w.at - glyf_start;

    w.i16v(-1); // composite
    w.i16v(200);
    w.i16v(0);
    w.i16v(300);
    w.i16v(100); // bbox
    w.u16v(0x0003); // ARGS_ARE_XY_VALUES | ARG_1_AND_2_ARE_WORDS
    w.u16v(6); // component glyph
    w.i16v(200); // dx
    w.i16v(0); // dy
    const comp_len = w.at - glyf_start;
    const r_glyf = Rec{ .at = glyf_start, .len = w.at - glyf_start };

    // --- loca: short format; six blank glyphs, then the triangle and composite ---
    const loca_start = w.at;
    var k: usize = 0;
    while (k < 7) : (k += 1) w.u16v(0); // glyphs 0..6 all start at 0
    w.u16v(@intCast(tri_len / 2));
    w.u16v(@intCast(comp_len / 2));
    const r_loca = Rec{ .at = loca_start, .len = w.at - loca_start };

    // --- head (54 bytes) ---
    const head_start = w.at;
    w.u32v(0x0001_0000);
    w.u32v(0x0001_0000);
    w.u32v(0);
    w.u32v(0x5F0F_3CF5);
    w.u16v(0);
    w.u16v(1024); // unitsPerEm
    w.zeros(16); // created, modified
    w.zeros(8); // bbox
    w.u16v(0); // macStyle
    w.u16v(8); // lowestRecPPEM
    w.i16v(2); // fontDirectionHint
    w.i16v(0); // indexToLocFormat: short
    w.i16v(0); // glyphDataFormat
    const r_head = Rec{ .at = head_start, .len = w.at - head_start };

    // --- hhea (36 bytes) ---
    const hhea_start = w.at;
    w.u32v(0x0001_0000);
    w.i16v(800); // ascender
    w.i16v(-200); // descender
    w.i16v(0); // lineGap
    w.u16v(700); // advanceWidthMax
    w.zeros(6); // minLSB, minRSB, xMaxExtent
    w.zeros(6); // caret rise/run/offset
    w.zeros(8); // reserved
    w.i16v(0); // metricDataFormat
    w.u16v(3); // numberOfHMetrics
    const r_hhea = Rec{ .at = hhea_start, .len = w.at - hhea_start };

    // --- hmtx: 3 full records, then bearings for glyphs 3..7 ---
    const hmtx_start = w.at;
    w.u16v(500);
    w.i16v(10);
    w.u16v(600);
    w.i16v(20);
    w.u16v(700);
    w.i16v(30);
    for ([_]i16{ 40, 50, 60, 70, 80 }) |lsb| w.i16v(lsb);
    const r_hmtx = Rec{ .at = hmtx_start, .len = w.at - hmtx_start };

    // --- maxp 0.5 (6 bytes) ---
    const maxp_start = w.at;
    w.u32v(0x0000_5000);
    w.u16v(8); // numGlyphs
    const r_maxp = Rec{ .at = maxp_start, .len = w.at - maxp_start };

    const tags = [_]u32{ tag_cmap, tag_glyf, tag_loca, tag_head, tag_hhea, tag_hmtx, tag_maxp };
    const recs = [_]Rec{ r_cmap, r_glyf, r_loca, r_head, r_hhea, r_hmtx, r_maxp };
    for (tags, recs, 0..) |t, r, i| patchRec(buf, rec_base + i * 16, t, r.at, r.len);

    return buf[0..w.at];
}

test "init reads the table directory and metrics" {
    var buf: [1024]u8 = undefined;
    const bytes = buildTestFont(&buf, false);
    const f = try Font.init(bytes);

    try std.testing.expectEqual(@as(u16, 1024), f.units_per_em);
    try std.testing.expectEqual(@as(u16, 8), f.num_glyphs);
    try std.testing.expectEqual(@as(u16, 3), f.num_hmetrics);
    try std.testing.expectEqual(@as(u16, 4), f.cmap_format);
    try std.testing.expectEqual(VMetrics{ .ascender = 800, .descender = -200, .line_gap = 0 }, f.vMetrics());
}

test "format 4: the delta path, the glyph-array path, and a miss" {
    var buf: [1024]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));

    // 'A' goes through glyphIdArray (1) and must also take idDelta (5).
    // stb_truetype omits that second step; the spec does not.
    try std.testing.expectEqual(@as(u16, 6), try f.glyphIndex('A'));
    // 'B' is delta-only: 0x42 + 0xFFC0 -> 2
    try std.testing.expectEqual(@as(u16, 2), try f.glyphIndex('B'));
    // unmapped, and the segment past the BMP
    try std.testing.expectEqual(@as(u16, 0), try f.glyphIndex('C'));
    try std.testing.expectEqual(@as(u16, 0), try f.glyphIndex(0x1F600));
}

test "format 12 is chosen when the font lists it, and reaches past the BMP" {
    var buf: [1024]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, true));

    try std.testing.expectEqual(@as(u16, 12), f.cmap_format);
    try std.testing.expectEqual(@as(u16, 1), try f.glyphIndex('A'));
    try std.testing.expectEqual(@as(u16, 2), try f.glyphIndex('B'));
    try std.testing.expectEqual(@as(u16, 7), try f.glyphIndex(0x1F600));
    try std.testing.expectEqual(@as(u16, 0), try f.glyphIndex(0x1F601));
}

test "hmtx: short arrays repeat the last advance" {
    var buf: [1024]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));

    try std.testing.expectEqual(HMetrics{ .advance = 500, .lsb = 10 }, try f.hMetrics(0));
    try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 30 }, try f.hMetrics(2));
    try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 60 }, try f.hMetrics(5));
    try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 80 }, try f.hMetrics(7));
    try std.testing.expectError(error.UnknownGlyph, f.hMetrics(8));
}

test "outline decodes a simple glyph, coordinates and all" {
    var buf: [2048]u8 = undefined;
    var pts: [16]Point = undefined;
    var ends: [4]u16 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));

    const o = try f.outline(6, &pts, &ends);
    try std.testing.expectEqual(@as(usize, 3), o.points.len);
    try std.testing.expectEqual(@as(usize, 1), o.ends.len);
    try std.testing.expectEqual(@as(u16, 2), o.ends[0]);

    try std.testing.expectEqual(Point{ .x = 0, .y = 0, .on = true }, o.points[0]);
    try std.testing.expectEqual(Point{ .x = 100, .y = 0, .on = true }, o.points[1]);
    try std.testing.expectEqual(Point{ .x = 50, .y = 100, .on = true }, o.points[2]);

    try std.testing.expectEqual(Box{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 }, outlineBounds(o));
}

test "outline inlines composites, and a blank glyph decodes to nothing" {
    var buf: [2048]u8 = undefined;
    var pts: [16]Point = undefined;
    var ends: [4]u16 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));

    const o = try f.outline(7, &pts, &ends);
    try std.testing.expectEqual(@as(usize, 3), o.points.len);
    try std.testing.expectEqual(@as(u16, 2), o.ends[0]);
    try std.testing.expectEqual(@as(i32, 200), o.points[0].x);
    try std.testing.expectEqual(@as(i32, 300), o.points[1].x);
    try std.testing.expectEqual(Box{ .x0 = 200, .y0 = 0, .x1 = 300, .y1 = 100 }, outlineBounds(o));

    // gid 0 has an empty loca range: a legal blank glyph.
    const blank = try f.outline(0, &pts, &ends);
    try std.testing.expectEqual(@as(usize, 0), blank.points.len);
    try std.testing.expectEqual(@as(usize, 0), blank.ends.len);
}

test "outline says so when the caller's buffer is too small" {
    var buf: [2048]u8 = undefined;
    var pts: [2]Point = undefined;
    var ends: [4]u16 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));
    try std.testing.expectError(error.BufferTooSmall, f.outline(6, &pts, &ends));
}

test "rejects what it cannot read" {
    try std.testing.expectError(error.Truncated, Font.init(""));
    try std.testing.expectError(error.Truncated, Font.init("\x00\x01\x00"));
    try std.testing.expectError(error.CffNotSupported, Font.init("OTTO\x00\x00\x00\x00"));
    try std.testing.expectError(error.NotSfnt, Font.init("junkjunkjunk"));

    var buf: [1024]u8 = undefined;
    const bytes = buildTestFont(&buf, false);

    // A table record pointing past the end of the font.
    const copy = buf[0..bytes.len];
    const head_rec = 12 + 1 * 16;
    std.mem.writeInt(u32, copy[head_rec + 8 ..][0..4], 999_999, .big);
    try std.testing.expectError(error.Truncated, Font.init(copy));
}
