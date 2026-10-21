//! GlyfZ -- a TrueType font parser and rasteriser.
//!
//! Reads `glyf`-based fonts, turns outlines into antialiased coverage masks,
//! and keeps those masks between draws. It is not a shaper: no glyph
//! substitution, no fallback chain, no line breaking.
//!
//! Three rules shape the code:
//!
//! 1. **No allocator and no IO.** The font is bytes the caller owns, and every
//!    working buffer -- outlines, edges, coverage, and the glyph cache itself --
//!    is the caller's too. Nothing here reaches outside them.
//! 2. **The spec decides, not the reference.** GlyfZ was developed against
//!    stb_truetype as a differential oracle, which is no longer vendored here.
//!    Where the two disagreed the disagreement is a finding to write down, not
//!    a bug in GlyfZ by default. Two are documented at `cmapFormat4` and in the
//!    composite decoder.
//! 3. **Failures are scoped.** `LoadError` means discard the face;
//!    `GlyphError` means this one glyph failed and the face is still good. GlyfZ
//!    propagates both and never substitutes a glyph silently -- deciding to keep
//!    a last-good face needs a fallback chain, which belongs to the caller.
//!
//! Out of scope, deliberately: hinting (stb skips it, so unhinted is the bar),
//! CFF/CFF2 outlines, variable axes, colour fonts, shaping and GPOS, kern
//! formats 2/3 and Apple's version 1 layout, vertical layout, and Unicode
//! normalisation or line breaking.

const std = @import("std");

/// The only failure a bounds-checked reader can produce.
const ReadError = error{Truncated};
/// A table span that is absent or out of range: the only thing `slice` checks.
const SpanError = error{ Truncated, MissingTable };

/// Failures that mean the bytes will never work. GlyfZ has no second face to
/// fall back to, so choosing another font is the caller's policy, not ours.
pub const LoadError = error{
    /// A read ran past the end of the font, or a table is shorter than the
    /// fields the format defines for it.
    Truncated,
    /// Not an sfnt at all.
    NotSfnt,
    /// An OpenType/CFF font: outlines are PostScript, not `glyf`.
    CffNotSupported,
    /// A table the font needs is absent, or empty.
    MissingTable,
    /// No `cmap` subtable we can read (v1: formats 4 and 12).
    UnsupportedCmap,
    /// A collection was asked for a face past its end.
    UnknownFontIndex,
    /// A field holds a value the format does not allow.
    BadValue,
};

/// Failures confined to one glyph of an otherwise usable font: a caller can
/// skip this glyph and keep drawing. A glyph is never silently substituted --
/// a failure is visible, because an invisible missing character is worse.
pub const GlyphError = error{
    Truncated,
    MissingTable,
    /// A glyph id at or past `num_glyphs`.
    UnknownGlyph,
    /// A composite glyph whose components are placed by matching points
    /// rather than by an offset. Rare; v1 does not decode it.
    UnsupportedComposite,
    /// The caller's point, contour, edge or coverage buffer is too small.
    BufferTooSmall,
    /// Composite glyphs nested deeper than `max_composite_depth`, which is
    /// what stops a font that references itself from eating the stack.
    CompositeTooDeep,
};

/// Everything either kind of call can return. Functions are declared with the
/// narrower set so the compiler keeps them apart.
pub const Error = LoadError || GlyphError;

/// Worst-case decode sizes the font declares, so a caller can size scratch
/// once instead of guessing. Zero for a `maxp` 0.5 font, which does not carry
/// them -- and they are SIMPLE glyph maxima, so composites can exceed them.
pub const Limits = struct { max_points: u16, max_contours: u16 };

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
/// The `name` table ids worth naming. The enum is documentation, not a
/// restriction: `name` takes any id.
pub const NameId = enum(u16) {
    copyright = 0,
    family = 1,
    subfamily = 2,
    unique_id = 3,
    full = 4,
    version = 5,
    /// No space in a PostScript name, by the spec -- hence the underscore.
    postscript = 6,
    trademark = 7,
    manufacturer = 8,
    designer = 9,
    description = 10,
    vendor_url = 11,
    designer_url = 12,
    license = 13,
    license_url = 14,
    typographic_family = 16,
    typographic_subfamily = 17,
};

/// The parts of `OS/2` a layout needs and `hhea` does not carry.
///
/// `hhea` gives one set of vertical metrics for every use; `OS/2` keeps the
/// typographic set apart from the Windows set, which is why a line placed on
/// one and clipped against the other is off by a few units. Cap height and
/// x-height are what a box centres on; the ascent convention Elm uses
/// (size/(ascender-descender)) is only one of four this table offers.
pub const Os2 = struct {
    version: u16,
    /// usWeightClass: 400 regular, 700 bold.
    weight: u16,
    /// fsSelection: bit 0 italic, bit 5 bold, bit 6 regular.
    selection: u16,
    typo_ascender: i16,
    typo_descender: i16,
    typo_line_gap: i16,
    win_ascent: u16,
    win_descent: u16,
    /// Version 2 and later. Null on an older table rather than zero, because
    /// zero is a legal cap height and a guess would be indistinguishable.
    cap_height: ?i16,
    x_height: ?i16,

    pub fn bold(self: Os2) bool {
        return self.selection & 0x20 != 0;
    }

    pub fn italic(self: Os2) bool {
        return self.selection & 0x01 != 0;
    }
};

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

/// A box in DEVICE PIXELS with y pointing down, which is the bitmap the
/// rasteriser will produce: `x0`/`y0` are where its top-left pixel sits
/// relative to the glyph origin, `y0` measured downward from the baseline.
/// This is the convention the existing backend hands the caller, so a swap
/// does not move text.
pub const PixelBox = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// One flattened outline segment in BITMAP pixel space, y down, with
/// `y0 <= y1`. `dir` is +1 if the contour runs downward along this edge and -1
/// if it runs up; the rasteriser only uses it to sign the winding.
pub const Edge = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    dir: i8,
};

/// A rasterised glyph: `coverage[y*w + x]` is 0..255, and `x0`/`y0` say where
/// the bitmap's top-left sits relative to the glyph origin, y down from the
/// baseline -- the same numbers the previous backend returned.
pub const Raster = struct {
    w: u32,
    h: u32,
    x0: i32,
    y0: i32,
    coverage: []u8,
};

/// stb_truetype's curve flattening tolerance, in pixels. GlyfZ uses the same
/// number so the two rasterisers are comparing the same polygons; an exact
/// quadratic path would remove the tolerance altogether and is a later win.
pub const flatten_tolerance: f32 = 0.35;

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
const tag_kern = tag("kern");
const tag_head = tag("head");
const tag_hhea = tag("hhea");
const tag_hmtx = tag("hmtx");
const tag_maxp = tag("maxp");
const tag_glyf = tag("glyf");
const tag_loca = tag("loca");
const tag_name = tag("name");
const tag_os2 = tag("OS/2");

/// One loaded face. Borrows the bytes; they must outlive it.
pub const Font = struct {
    data: []const u8 = &.{},
    kern_span: Span = .{},
    kern_ok: bool = false,
    kern_tables: u16 = 0,
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
    name_span: Span = .{},
    os2_span: Span = .{},

    /// Parse the table directory and the metrics a caller needs up front.
    /// Fails loudly: a font GlyfZ cannot read should not silently measure zero.
    pub fn init(bytes: []const u8) LoadError!Font {
        return initIndex(bytes, 0);
    }

    /// Same, for the Nth face of a font collection (`.ttc`). The existing
    /// backend asks stb for index 0 of every file, so a collection is a file
    /// users can already point at and GlyfZ refused.
    pub fn initIndex(bytes: []const u8, index: u32) LoadError!Font {
        var base: usize = 0;
        const v = try u32At(bytes, 0);
        switch (v) {
            0x0001_0000, tag("true") => {},
            tag("ttcf") => {
                const count = try u32At(bytes, 8);
                if (index >= count) return error.UnknownFontIndex;
                base = try u32At(bytes, 12 + @as(usize, index) * 4);
            },
            tag("OTTO") => return error.CffNotSupported,
            else => return error.NotSfnt,
        }

        var self: Font = .{ .data = bytes };
        const n = try u16At(bytes, base + 4);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = base + 12 + i * 16;
            const t = try u32At(bytes, rec);
            const span = Span{ .off = try u32At(bytes, rec + 8), .len = try u32At(bytes, rec + 12) };
            if (t == tag_cmap) self.cmap = span;
            if (t == tag_kern) self.kern_span = span;
            if (t == tag_head) self.head = span;
            if (t == tag_hhea) self.hhea = span;
            if (t == tag_hmtx) self.hmtx = span;
            if (t == tag_maxp) self.maxp = span;
            if (t == tag_glyf) self.glyf = span;
            if (t == tag_loca) self.loca = span;
            if (t == tag_name) self.name_span = span;
            if (t == tag_os2) self.os2_span = span;
        }

        const head = try self.slice(self.head);
        const hhea = try self.slice(self.hhea);
        const maxp = try self.slice(self.maxp);
        const hmtx = try self.slice(self.hmtx);
        _ = try self.slice(self.glyf);

        // Every field below is read at a fixed offset, so a table that is
        // merely short would read into whatever follows it instead of failing.
        // Lengths are checked against the format, not against "does the read
        // stay inside the file".
        if (head.len < 54) return error.Truncated;
        if (hhea.len < 36) return error.Truncated;
        if (maxp.len < 6) return error.Truncated;

        self.units_per_em = try u16At(head, 18);
        self.index_to_loc = try i16At(head, 50);
        self.ascender = try i16At(hhea, 4);
        self.descender = try i16At(hhea, 6);
        self.line_gap = try i16At(hhea, 8);
        self.num_hmetrics = try u16At(hhea, 34);
        self.num_glyphs = try u16At(maxp, 4);

        if (self.units_per_em == 0) return error.MissingTable;
        if (self.num_hmetrics == 0) return error.MissingTable;
        if (self.num_glyphs == 0) return error.BadValue;
        // 0 is short `loca` (offsets in half-words), 1 is long. Anything else
        // would make every glyph lookup read nonsense.
        if (self.index_to_loc != 0 and self.index_to_loc != 1) return error.BadValue;
        if (self.num_hmetrics > self.num_glyphs) return error.BadValue;

        // Full advances for the first num_hmetrics glyphs, then one bearing each.
        const hmtx_need = @as(usize, self.num_hmetrics) * 4 +
            (@as(usize, self.num_glyphs) - self.num_hmetrics) * 2;
        if (hmtx.len < hmtx_need) return error.Truncated;

        // `loca` is indexed up to num_glyphs inclusive. A table that is short
        // would let glyph lookups read into the next table, so check once here.
        const loca = try self.slice(self.loca);
        const entry: usize = if (self.index_to_loc == 0) 2 else 4;
        if (loca.len < (@as(usize, self.num_glyphs) + 1) * entry) return error.Truncated;

        // Offsets must not go backwards: one that does makes a glyph's byte
        // range invert, and every lookup after it is a guess.
        var prev: u32 = 0;
        var gi: usize = 0;
        while (gi <= self.num_glyphs) : (gi += 1) {
            const at: u32 = if (self.index_to_loc == 0)
                @as(u32, try u16At(loca, gi * 2)) * 2
            else
                try u32At(loca, gi * 4);
            if (at < prev) return error.Truncated;
            if (@as(usize, at) > (try self.slice(self.glyf)).len) return error.Truncated;
            prev = at;
        }

        // Choose the character map once, so a font we cannot map fails at load
        // rather than per glyph.
        self.cmap_format = try self.selectCmap();
        if (self.cmap_format != 4 and self.cmap_format != 12) return error.UnsupportedCmap;
        try self.validateCmap();
        self.kern_ok = self.validateKern();

        return self;
    }

    fn slice(self: Font, span: Span) SpanError![]const u8 {
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
    /// True when the font carries a `kern` table GlyfZ could read. An absent
    /// or malformed one is not an error -- kerning is decoration, and refusing
    /// an otherwise good font over it would be worse -- but it is REPORTABLE,
    /// so a caller can say so instead of wondering why text looks loose.
    pub fn kerning(self: Font) bool {
        return self.kern_ok;
    }

    /// Kerning adjustment between two glyphs, in FONT UNITS. Zero when the
    /// font has no kern table, when this pair has no entry, or when the table
    /// could not be validated.
    ///
    /// Format 0 only, which is what stb_truetype reads: modern fonts put most
    /// kerning in GPOS instead, so a zero here does not mean the designer
    /// intended no adjustment -- it means there is nothing this table can say.
    pub fn kern(self: Font, left: u16, right: u16) i16 {
        if (!self.kern_ok) return 0;
        const kv: u32 = (@as(u32, left) << 16) | right;
        var i: usize = 0;
        while (i < self.kern_tables) : (i += 1) {
            const at = self.kern_subtable(i) orelse return 0;
            const pairs = at + 14;
            const n = u16At(self.data, at + 6) catch return 0;

            var lo: u32 = 0;
            var hi: u32 = n;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const rec = pairs + @as(usize, mid) * 6;
                const l = u16At(self.data, rec) catch return 0;
                const r = u16At(self.data, rec + 2) catch return 0;
                const key: u32 = (@as(u32, l) << 16) | r;
                if (key < kv) {
                    lo = mid + 1;
                } else if (key > kv) {
                    hi = mid;
                } else {
                    return i16At(self.data, rec + 4) catch 0;
                }
            }
        }
        return 0;
    }

    /// Offset of the nth `kern` subtable body, skipping any we do not read.
    fn kern_subtable(self: Font, n: usize) ?usize {
        var at: usize = self.kern_span.off + 4;
        var seen: usize = 0;
        var i: usize = 0;
        while (i < self.kern_tables) : (i += 1) {
            const len = u16At(self.data, at + 2) catch return null;
            if (len < 6) return null;
            if (seen == n) return at;
            seen += 1;
            at += len;
        }
        return null;
    }

    /// Walks the `kern` table once at load so a per-glyph lookup cannot read
    /// outside it. Returns whether anything here is trustworthy.
    fn validateKern(self: *Font) bool {
        if (self.kern_span.len == 0) return false;
        const version = u16At(self.data, self.kern_span.off) catch return false;
        // Apple's version 1 layout is different and is not read here.
        if (version != 0) return false;
        const n = u16At(self.data, self.kern_span.off + 2) catch return false;
        if (n == 0) return false;
        self.kern_tables = n;

        const end = @as(usize, self.kern_span.off) + self.kern_span.len;
        var at: usize = self.kern_span.off + 4;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const len = u16At(self.data, at + 2) catch return false;
            if (len < 6 or at + len > end) return false;
            const coverage = u16At(self.data, at + 4) catch return false;
            const format = coverage >> 8;
            // Horizontal kerning only; format 0 is the only layout we read.
            if (format == 0 and (coverage & 0x1) != 0) {
                const pairs = u16At(self.data, at + 6) catch return false;
                if (at + 14 + @as(usize, pairs) * 6 > at + len) return false;
            }
            at += len;
        }
        return true;
    }

    /// Check the chosen subtable's own arrays fit before any lookup can walk
    /// them, so a font we cannot map fails at load rather than per glyph.
    fn validateCmap(self: Font) LoadError!void {
        const cm = try self.slice(self.cmap);
        if (cm.len < 2) return error.Truncated;
        switch (self.cmap_format) {
            4 => {
                if (cm.len < 16) return error.Truncated;
                const seg_x2 = try u16At(cm, 6);
                if (seg_x2 == 0 or seg_x2 % 2 != 0) return error.BadValue;
                // endCode, reservedPad, startCode, idDelta, idRangeOffset.
                const need = 16 + @as(usize, seg_x2) * 4;
                if (cm.len < need) return error.Truncated;
            },
            12 => {
                if (cm.len < 16) return error.Truncated;
                const n = try u32At(cm, 12);
                const need = 16 + @as(usize, n) * 12;
                if (cm.len < need) return error.Truncated;
            },
            else => return error.UnsupportedCmap,
        }
    }

    fn selectCmap(self: *Font) LoadError!u16 {
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
    pub fn glyphIndex(self: Font, cp: u21) GlyphError!u16 {
        const cm = try self.slice(self.cmap);
        const gid = switch (self.cmap_format) {
            4 => try cmapFormat4(cm, 0, cp),
            12 => try cmapFormat12(cm, 0, cp),
            // init refuses anything else, so this cannot be reached.
            else => unreachable,
        };
        // A cmap is free to name a glyph the face does not contain -- a
        // truncated or hand-edited font does it, and the format's terminal
        // 0xFFFF segment maps whatever follows it arithmetically. Handing that
        // number out would let `hasCodepoint` say yes to a glyph that cannot be
        // drawn, and every later call would fail with a number in hand.
        if (gid >= self.num_glyphs) return error.UnknownGlyph;
        return gid;
    }

    /// True when the face maps this codepoint to a real glyph.
    ///
    /// Glyph 0 is `.notdef` by the format, so a codepoint that resolves to it
    /// is ABSENT, not present-and-blank. A fallback chain asks this question,
    /// and answering "yes" for a codepoint the face would draw as a box is the
    /// bug the chain exists to prevent.
    pub fn hasCodepoint(self: Font, cp: u21) bool {
        const gid = self.glyphIndex(cp) catch return false;
        return gid != 0;
    }

    /// A `name`-table string, decoded to UTF-8 into `out`.
    ///
    /// Null when the face carries no such record. Names are decoration like
    /// kerning: no face fails to load for want of one, and a result shorter
    /// than the name means a caller's buffer was too small.
    pub fn name(self: Font, id: NameId, out: []u8) ?[]const u8 {
        const tbl = self.slice(self.name_span) catch return null;
        return nameRecord(tbl, @intFromEnum(id), out);
    }

    /// Family name, e.g. "DejaVu Sans". This is the string a theme file's font
    /// name gets matched against, so it is the one that has to be exact.
    pub fn family(self: Font, out: []u8) ?[]const u8 {
        return self.name(.family, out);
    }

    /// Style within the family, e.g. "Bold Oblique".
    pub fn style(self: Font, out: []u8) ?[]const u8 {
        return self.name(.subfamily, out);
    }

    /// The `OS/2` numbers, or null when the face has no such table.
    pub fn os2(self: Font) ?Os2 {
        const tbl = self.slice(self.os2_span) catch return null;
        return os2Table(tbl);
    }

    /// Decode a glyph's outline into the caller's buffers, in font units.
    ///
    /// No allocation anywhere: `points` and `ends` are scratch the caller
    /// owns and reuses. A blank glyph (or one with no contours) decodes to an
    /// empty outline rather than an error, because that is a legal glyph.
    pub fn outline(self: Font, gid: u16, points: []Point, ends: []u16) GlyphError!Outline {
        if (gid >= self.num_glyphs) return error.UnknownGlyph;
        var cur = Cursor{ .points = points, .ends = ends };
        try decodeInto(self, gid, &cur, 0);
        return .{ .points = points[0..cur.n], .ends = ends[0..cur.nc] };
    }

    /// What `maxp` says about the biggest glyph, for sizing caller scratch.
    pub fn limits(self: Font) LoadError!Limits {
        const data = try self.slice(self.maxp);
        const version = try u32At(data, 0);
        if (version < 0x0001_0000) return .{ .max_points = 0, .max_contours = 0 };
        return .{ .max_points = try u16At(data, 6), .max_contours = try u16At(data, 8) };
    }

    /// The ink box the FONT DECLARES in the glyph header, or null for a blank
    /// glyph. Deliberately the declared box rather than a computed one: it is
    /// what the previous backend sized its bitmaps from, so bitmaps stay the
    /// same size across the swap. `outlineBounds` is the computed alternative.
    pub fn headerBox(self: Font, gid: u16) GlyphError!?Box {
        if (gid >= self.num_glyphs) return error.UnknownGlyph;
        const data = try glyphRange(self, gid);
        if (data.len == 0) return null;
        return Box{
            .x0 = try i16At(data, 2),
            .y0 = try i16At(data, 4),
            .x1 = try i16At(data, 6),
            .y1 = try i16At(data, 8),
        };
    }

    /// Map `headerBox` to whole device pixels at `scale` (font units to
    /// pixels), with an optional horizontal subpixel phase in pixels.
    ///
    /// Font y points up and bitmap y points down, hence the negations: the
    /// top of the bitmap comes from the glyph's yMax.
    pub fn bitmapBox(self: Font, gid: u16, scale: f32, phase_x: f32) GlyphError!PixelBox {
        const b = (try self.headerBox(gid)) orelse
            return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
        const f = struct {
            fn v(i: i32, s: f32, add: f32) f32 {
                return @as(f32, @floatFromInt(i)) * s + add;
            }
        };
        return .{
            .x0 = @intFromFloat(@floor(f.v(b.x0, scale, phase_x))),
            .y0 = @intFromFloat(@floor(f.v(-b.y1, scale, 0))),
            .x1 = @intFromFloat(@ceil(f.v(b.x1, scale, phase_x))),
            .y1 = @intFromFloat(@ceil(f.v(-b.y0, scale, 0))),
        };
    }

    /// Flatten the glyph into bitmap-space edges, written into `edges`, and
    /// return how many. `box` is where the bitmap origin lands, so the edges
    /// come out already relative to it.
    pub fn edgesInto(
        self: Font,
        gid: u16,
        scale: f32,
        phase_x: f32,
        box: PixelBox,
        points: []Point,
        ends: []u16,
        edges: []Edge,
    ) GlyphError!usize {
        const o = try self.outline(gid, points, ends);
        var em = Emitter{
            .edges = edges,
            .scale = scale,
            .phase_x = phase_x,
            .ox = @floatFromInt(box.x0),
            .oy = @floatFromInt(box.y0),
            // Flatness is expressed in pixels, so in font units it scales.
            .flat_sq = sq(flatten_tolerance / scale),
        };
        try em.contours(o);
        return em.n;
    }

    /// Rasterise a glyph: flatten into `edges`, sweep into `coverage`.
    ///
    /// Nothing is allocated. `edges`, `acc` (one f32 per pixel column) and
    /// `coverage` are the caller's, reused frame after frame -- which is the
    /// whole point of this existing, since the previous backend malloc'd and
    /// freed twice per glyph per draw.
    ///
    /// `edges` is SORTED IN PLACE (by top, so the sweep can stop early). Its
    /// contents after the call are the same edges in a different order.
    pub fn raster(
        self: Font,
        gid: u16,
        scale: f32,
        phase_x: f32,
        points: []Point,
        ends: []u16,
        edges: []Edge,
        acc: []f32,
        coverage: []u8,
    ) GlyphError!Raster {
        const box = try self.bitmapBox(gid, scale, phase_x);
        const w: u32 = if (box.x1 > box.x0) @intCast(box.x1 - box.x0) else 0;
        const h: u32 = if (box.y1 > box.y0) @intCast(box.y1 - box.y0) else 0;

        const empty = Raster{ .w = w, .h = h, .x0 = box.x0, .y0 = box.y0, .coverage = &.{} };
        if (w == 0 or h == 0) return empty;

        const need = @as(usize, w) * h;
        if (coverage.len < need) return error.BufferTooSmall;
        if (acc.len < @as(usize, w) * 2 + 2) return error.BufferTooSmall;

        const n = try self.edgesInto(gid, scale, phase_x, box, points, ends, edges);
        try sweep(edges[0..n], w, h, acc, coverage[0..need]);
        return .{ .w = w, .h = h, .x0 = box.x0, .y0 = box.y0, .coverage = coverage[0..need] };
    }

    /// Horizontal metrics for a glyph. Ids past `numberOfHMetrics` repeat the
    /// last advance and read their bearing from the trailing array -- that is
    /// the format, not a shortcut.
    pub fn hMetrics(self: Font, gid: u16) GlyphError!HMetrics {
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
/// KNOWN DIVERGENCE FROM stb_truetype, in GlyfZ's favour. The spec applies
/// `idDelta` to the value fetched through `idRangeOffset`; stb returns the
/// fetched value unchanged. On a font that combines a non-zero delta with a
/// non-zero range offset the two disagree, and GlyfZ is the one following the
/// spec. A differential run reports that as a mismatch only if a font in test
/// uses the combination; the synthetic test below pins our behaviour either way.
fn cmapFormat4(cm: []const u8, base: usize, cp: u21) GlyphError!u16 {
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
fn cmapFormat12(cm: []const u8, base: usize, cp: u21) GlyphError!u16 {
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

    fn room(self: Cursor, count: usize) GlyphError!void {
        if (self.n + count > self.points.len) return error.BufferTooSmall;
    }

    fn roomContour(self: Cursor) GlyphError!void {
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

    fn next(self: *FlagWalk, data: []const u8) ReadError!u8 {
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
fn glyphRange(self: Font, gid: u16) GlyphError![]const u8 {
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

fn decodeInto(self: Font, gid: u16, cur: *Cursor, depth: u32) GlyphError!void {
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

fn decodeSimple(data: []const u8, n_contours: usize, cur: *Cursor) GlyphError!void {
    const ends_at = 10;
    var ci: usize = 1;
    while (ci < n_contours) : (ci += 1) {
        if (try u16At(data, ends_at + ci * 2) <= try u16At(data, ends_at + (ci - 1) * 2)) {
            return error.Truncated;
        }
    }
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
/// (`m = sqrt(a*a + b*b)`), which squares a uniform scale. GlyfZ follows the
/// spec. The two agree on the common case -- accents placed by translation
/// with no matrix -- and disagree on scaled composites, which is exactly the
/// kind of thing the differential is there to point at.
fn decodeComposite(self: Font, data: []const u8, cur: *Cursor, depth: u32) GlyphError!void {
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
// flattening and coverage
// ---------------------------------------------------------------------------

fn sq(v: f32) f32 {
    return v * v;
}

/// Turns contours into bitmap-space edges. Curves are subdivided in FONT space
/// against a flatness bound, which is how stb_truetype does it -- mirroring the
/// criterion keeps both rasterisers comparing the same polygons instead of two
/// slightly different ones.
const Emitter = struct {
    edges: []Edge,
    n: usize = 0,
    scale: f32,
    phase_x: f32,
    ox: f32,
    oy: f32,
    flat_sq: f32,

    fn line(self: *Emitter, x0: f32, y0: f32, x1: f32, y1: f32) GlyphError!void {
        const px0 = x0 * self.scale + self.phase_x - self.ox;
        const px1 = x1 * self.scale + self.phase_x - self.ox;
        const py0 = -y0 * self.scale - self.oy;
        const py1 = -y1 * self.scale - self.oy;
        // A horizontal edge contributes no area to a row.
        if (py0 == py1) return;
        if (self.n == self.edges.len) return error.BufferTooSmall;

        var e = Edge{ .x0 = px0, .y0 = py0, .x1 = px1, .y1 = py1, .dir = 1 };
        if (py0 > py1) {
            e = .{ .x0 = px1, .y0 = py1, .x1 = px0, .y1 = py0, .dir = -1 };
        }
        self.edges[self.n] = e;
        self.n += 1;
    }

    /// Midpoint subdivision, stopping when the midpoint deviates from the chord
    /// by less than the flatness bound.
    fn quad(self: *Emitter, fx: f32, fy: f32, cx: f32, cy: f32, tx: f32, ty: f32, depth: u8) GlyphError!void {
        const mx = (fx + 2 * cx + tx) / 4;
        const my = (fy + 2 * cy + ty) / 4;
        const dx = (fx + tx) / 2 - mx;
        const dy = (fy + ty) / 2 - my;
        if (depth < 16 and dx * dx + dy * dy > self.flat_sq) {
            try self.quad(fx, fy, (fx + cx) / 2, (fy + cy) / 2, mx, my, depth + 1);
            try self.quad(mx, my, (cx + tx) / 2, (cy + ty) / 2, tx, ty, depth + 1);
        } else {
            try self.line(fx, fy, tx, ty);
        }
    }

    fn contours(self: *Emitter, o: Outline) GlyphError!void {
        var start: usize = 0;
        for (o.ends) |end| {
            const last: usize = end;
            if (last < start or last >= o.points.len) return error.Truncated;
            try self.contour(o.points, start, last - start + 1);
            start = last + 1;
        }
    }

    /// One closed contour. The start point has to be on-curve; if the contour
    /// begins with a control point (legal, and common) we either move to the
    /// next on-curve point or, when every point is off-curve, start from the
    /// midpoint between the last and first, which is a point on the curve.
    fn contour(self: *Emitter, pts: []const Point, start: usize, n: usize) GlyphError!void {
        if (n == 0) return;

        var on_rel: ?usize = null;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (pts[start + k].on) {
                on_rel = k;
                break;
            }
        }

        var cur: Point = undefined;
        var first_step: usize = undefined;
        if (on_rel) |r| {
            cur = pts[start + r];
            first_step = 1;
        } else {
            const a = pts[start + n - 1];
            const b = pts[start];
            cur = .{ .x = @divTrunc(a.x + b.x, 2), .y = @divTrunc(a.y + b.y, 2), .on = true };
            first_step = 0;
        }
        const begin = cur;
        const r = on_rel orelse 0;

        var ctrl: ?Point = null;
        var i = first_step;
        while (i <= n) : (i += 1) {
            // Walk the contour cyclically FROM the start point, wrapping back
            // into this contour's own points -- not past its end.
            const p = pts[start + (r + i) % n];
            if (p.on) {
                if (ctrl) |c| {
                    try self.quad(@floatFromInt(cur.x), @floatFromInt(cur.y), @floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(p.x), @floatFromInt(p.y), 0);
                    ctrl = null;
                } else {
                    try self.line(@floatFromInt(cur.x), @floatFromInt(cur.y), @floatFromInt(p.x), @floatFromInt(p.y));
                }
                cur = p;
            } else {
                if (ctrl) |c| {
                    const m = Point{ .x = @divTrunc(c.x + p.x, 2), .y = @divTrunc(c.y + p.y, 2), .on = true };
                    try self.quad(@floatFromInt(cur.x), @floatFromInt(cur.y), @floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(m.x), @floatFromInt(m.y), 0);
                    cur = m;
                }
                ctrl = p;
            }
        }

        if (ctrl) |c| {
            try self.quad(@floatFromInt(cur.x), @floatFromInt(cur.y), @floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(begin.x), @floatFromInt(begin.y), 0);
        } else {
            try self.line(@floatFromInt(cur.x), @floatFromInt(cur.y), @floatFromInt(begin.x), @floatFromInt(begin.y));
        }
    }
};

fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

/// The exact area of column `c` inside one row that lies to the RIGHT of the
/// edge piece running (xa,ya)-(xb,yb).
///
/// Summed over the pieces of a closed contour and sign-flipped, these cancel to
/// the covered area of every column: each piece adds full height for the
/// columns past it and the far pieces cancel, which is why no sort is needed
/// and why holes (opposite `dir`) fall out for free.
/// Integral of clamp(c + 1 - x(y), 0, 1) over [ya, yb] for a straight edge.
///
/// Substituting u = c + 1 - x turns the integrand into clamp(u, 0, 1), and
/// substituting v = u turns the integral into an area under a clamped ramp --
/// whose antiderivative needs no division and does not care how many times u
/// crosses 0 or 1. That is what the piecewise-with-breakpoints version was
/// buying with three divisions and a sort per column.
///
/// `inv_k` is dy/dx for the whole line, which is constant, so it is hoisted
/// out of the column loop by the caller rather than recomputed here.
inline fn colArea(xa: f32, ya: f32, xb: f32, yb: f32, c: f32, inv_k: f32) f32 {
    const dy = yb - ya;
    if (dy <= 0) return 0;
    const ua = c + 1 - xa;
    const ub = c + 1 - xb;
    if (ub == ua) return clamp01(ua) * dy; // horizontal within this column
    return -inv_k * (rampArea(ub) - rampArea(ua));
}

/// Antiderivative of clamp(v, 0, 1) dv, from 0 to v.
inline fn rampArea(v: f32) f32 {
    if (v <= 0) return 0;
    if (v >= 1) return v - 0.5;
    return 0.5 * v * v;
}

fn sweep(edges: []Edge, w: u32, h: u32, scratch: []f32, coverage: []u8) GlyphError!void {
    // Two accumulators per row: the partial areas where an edge cuts a column,
    // and the tail an edge contributes to every column to its right.
    const need = @as(usize, w) * 2 + 2;
    if (scratch.len < need) return error.BufferTooSmall;
    const acc = scratch[0..w];
    const fill = scratch[w .. @as(usize, w) * 2 + 1];
    if (coverage.len < @as(usize, w) * h) return error.BufferTooSmall;

    const wf: f32 = @floatFromInt(w);
    @memset(coverage, 0);
    if (edges.len == 0) return;

    // Sort by top edge (y is DOWN, so y0 is the top) so a row can stop as soon
    // as it meets an edge that begins below it. Insertion sort: a glyph has
    // tens of edges, they arrive nearly ordered, and this is once per glyph
    // rather than once per row.
    {
        var i: usize = 1;
        while (i < edges.len) : (i += 1) {
            const e = edges[i];
            var j = i;
            while (j > 0 and edges[j - 1].y0 > e.y0) : (j -= 1) edges[j] = edges[j - 1];
            edges[j] = e;
        }
    }

    // Rows above and below every edge are already zero; walking them would
    // clear the accumulators and scan the whole edge list to find nothing.
    var bot = edges[0].y1;
    for (edges) |e| bot = @max(bot, e.y1);
    const row_lo: u32 = if (edges[0].y0 <= 0) 0 else @min(@as(u32, @intFromFloat(@floor(edges[0].y0))), h);
    const row_hi: u32 = if (bot <= 0) 0 else @min(@as(u32, @intFromFloat(@ceil(bot))), h);

    var start: usize = 0;
    var row: u32 = row_lo;
    while (row < row_hi) : (row += 1) {
        const y0: f32 = @floatFromInt(row);
        const y1 = y0 + 1;
        @memset(acc, 0);
        @memset(fill, 0);

        // An edge that ended above this row is done for every later row too.
        while (start < edges.len and edges[start].y1 <= y0) : (start += 1) {}

        var ei = start;
        while (ei < edges.len) : (ei += 1) {
            const e = edges[ei];
            if (e.y0 >= y1) break; // sorted: nothing past here reaches this row
            if (e.y1 <= y0) continue;

            const ya = @max(e.y0, y0);
            const yb = @min(e.y1, y1);
            if (ya >= yb) continue;

            const k = (e.x1 - e.x0) / (e.y1 - e.y0);
            const inv_k = if (k != 0) 1 / k else 0;
            const xa = e.x0 + (ya - e.y0) * k;
            const xb = e.x0 + (yb - e.y0) * k;
            const s: f32 = if (e.dir > 0) 1 else -1;
            const xmax = @max(xa, xb);

            // Columns the edge may only partly cover.
            const lo_f = @floor(@min(xa, xb)) - 1;
            const hi_f = @min(@ceil(xmax), wf);
            var c: usize = if (lo_f <= 0) 0 else @intFromFloat(lo_f);
            const hi: usize = if (hi_f <= 0) 0 else @intFromFloat(hi_f);
            while (c < hi) : (c += 1) {
                acc[c] += s * colArea(xa, ya, xb, yb, @floatFromInt(c), inv_k);
            }

            // Everything right of ceil(xmax) is covered for the edge's whole
            // height in this row, which is what makes a closed contour cancel.
            const t = @ceil(xmax);
            const tail: usize = if (t <= 0) 0 else if (t >= wf) w else @intFromFloat(t);
            fill[tail] += s * (yb - ya);
        }

        var run: f32 = 0;
        const at = @as(usize, row) * w;
        var c: usize = 0;
        while (c < w) : (c += 1) {
            run += fill[c];
            const v = clamp01(@abs(acc[c] + run));
            coverage[at + c] = @intFromFloat(@round(v * 255.0));
        }
    }
}

// ---------------------------------------------------------------------------
// glyph cache
// ---------------------------------------------------------------------------

/// Sub-pixel phase classes a cached mask can take. A mask is rasterised at one
/// of these and then placed on a pixel boundary, so the residual offset inside
/// the phase is dropped. Four classes hold that error under 1/8 px, which is
/// finer than hinting moves a stem anyway -- and the alternative, keying on the
/// exact float, turns the cache into a leak with extra steps.
pub const Phase = enum(u2) { zero = 0, quarter = 1, half = 2, three_quarters = 3 };

pub fn phaseOf(x: f32) Phase {
    const frac = x - @floor(x);
    const q: u32 = @intFromFloat(@floor(frac * 4.0 + 0.5));
    return @enumFromInt(@as(u2, @intCast(q & 3)));
}

pub fn phaseOffset(p: Phase) f32 {
    return @as(f32, @floatFromInt(@intFromEnum(p))) * 0.25;
}

/// A rasterised glyph, owned by the cache. Valid until the cache fills up and
/// flushes; blit it before asking for the next glyph.
pub const Mask = struct {
    w: u32 = 0,
    h: u32 = 0,
    x0: i32 = 0,
    y0: i32 = 0,
    pixels: []const u8 = &.{},
};

/// Glyph masks kept between draws, so a repeated glyph costs a lookup instead
/// of a rasterisation.
///
/// All of its memory is one caller-owned buffer. GlyfZ still does not allocate:
/// the caller decides the size once, from `needed()`, and this carves that into
/// the slot table, the outline scratch and the pixel arena.
///
/// The arena is a bump allocator and the policy when it fills is to drop
/// everything. Reclaiming a dead mask from the middle of a bump region is not
/// possible without a compaction pass, and a compaction pass costs more than
/// re-rasterising a working set that did not fit in the first place. If the
/// flush count is high, the buffer is too small -- that is the signal to look
/// at, and it is reported rather than hidden.
pub const Cache = struct {
    pub const Options = struct {
        slots: u16 = 512,
        max_points: u16 = 1024,
        max_ends: u16 = 256,
        max_edges: u16 = 1024,
        /// Widest box the sweep can accumulate, in pixels.
        max_width: u16 = 256,
        /// Pixel-arena bytes.
        arena: u32 = 256 * 1024,
    };

    pub const Stats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        flushes: u64 = 0,
    };

    const Slot = struct {
        gid: u16 = 0,
        scale_key: u32 = 0,
        phase: Phase = .zero,
        off: u32 = 0,
        w: u32 = 0,
        h: u32 = 0,
        x0: i32 = 0,
        y0: i32 = 0,
        valid: bool = false,
    };

    mem: []align(8) u8,
    slots: []Slot,
    points: []Point,
    ends: []u16,
    edges: []Edge,
    scratch: []f32,
    arena_at: usize,
    arena_len: usize,
    used: usize,
    stats: Stats = .{},

    /// How much memory `init` wants for this configuration.
    pub fn needed(opts: Options) usize {
        var total: usize = 0;
        total += @as(usize, opts.slots) * @sizeOf(Slot);
        total = std.mem.alignForward(usize, total, @alignOf(Point)) + @as(usize, opts.max_points) * @sizeOf(Point);
        total = std.mem.alignForward(usize, total, @alignOf(u16)) + @as(usize, opts.max_ends) * @sizeOf(u16);
        total = std.mem.alignForward(usize, total, @alignOf(Edge)) + @as(usize, opts.max_edges) * @sizeOf(Edge);
        total = std.mem.alignForward(usize, total, @alignOf(f32)) + (@as(usize, opts.max_width) * 2 + 2) * @sizeOf(f32);
        total = std.mem.alignForward(usize, total, 8) + @as(usize, opts.arena);
        return total;
    }

    pub fn init(mem: []align(8) u8, opts: Options) error{BufferTooSmall}!Cache {
        if (mem.len < needed(opts)) return error.BufferTooSmall;
        var off: usize = 0;
        const slots = takeSlice(Slot, mem, &off, opts.slots);
        const points = takeSlice(Point, mem, &off, opts.max_points);
        const ends = takeSlice(u16, mem, &off, opts.max_ends);
        const edges = takeSlice(Edge, mem, &off, opts.max_edges);
        const scratch = takeSlice(f32, mem, &off, @as(usize, opts.max_width) * 2 + 2);
        const arena_at = std.mem.alignForward(usize, off, 8);

        var c = Cache{
            .mem = mem,
            .slots = slots,
            .points = points,
            .ends = ends,
            .edges = edges,
            .scratch = scratch,
            .arena_at = arena_at,
            .arena_len = mem.len - arena_at,
            .used = 0,
        };
        c.reset();
        return c;
    }

    /// The mask for this glyph at this pixel size and phase, rasterising it if
    /// it is not already held.
    /// A mask at a pixel size, for callers who think in ppem.
    pub fn mask(self: *Cache, font: Font, gid: u16, ppem: u16, phase: Phase) GlyphError!Mask {
        if (ppem == 0 or font.units_per_em == 0) return .{};
        const scale = @as(f32, @floatFromInt(ppem)) / @as(f32, @floatFromInt(font.units_per_em));
        return self.maskAt(font, gid, scale, phase);
    }

    /// A mask at whatever scale the caller actually uses.
    ///
    /// ppem is only one convention for turning a point size into a scale, and
    /// it is not the one a UI toolkit necessarily has: Elm derives its scale
    /// from `size / (ascender - descender)`, which has nothing to do with
    /// unitsPerEm. Handing the cache a ppem would therefore silently rasterise
    /// at a different size than the caller lays out with. The scale is the
    /// primitive; ppem is the convenience wrapper above.
    pub fn maskAt(self: *Cache, font: Font, gid: u16, scale: f32, phase: Phase) GlyphError!Mask {
        const scale_key: u32 = @bitCast(scale);
        if (self.find(gid, scale_key, phase)) |s| {
            self.stats.hits += 1;
            const at = self.arena_at + s.off;
            return .{ .w = s.w, .h = s.h, .x0 = s.x0, .y0 = s.y0, .pixels = self.mem[at..][0 .. @as(usize, s.w) * s.h] };
        }

        self.stats.misses += 1;
        if (!(scale > 0) or font.units_per_em == 0) return .{};
        const ph = phaseOffset(phase);
        const box = try font.bitmapBox(gid, scale, ph);
        const w: u32 = if (box.x1 > box.x0) @intCast(box.x1 - box.x0) else 0;
        const h: u32 = if (box.y1 > box.y0) @intCast(box.y1 - box.y0) else 0;
        if (w == 0 or h == 0) return .{ .x0 = box.x0, .y0 = box.y0 };
        const len = @as(usize, w) * h;

        var slot = self.freeSlot(gid, scale_key, phase);
        if (slot == null or self.used + len > self.arena_len) {
            self.flush();
            if (len > self.arena_len) return error.BufferTooSmall;
            slot = self.freeSlot(gid, scale_key, phase);
        }
        const s = slot orelse return error.BufferTooSmall;
        const at = self.arena_at + self.used;
        const r = try font.raster(gid, scale, ph, self.points, self.ends, self.edges, self.scratch, self.mem[at..][0..len]);

        s.* = .{
            .gid = gid,
            .scale_key = scale_key,
            .phase = phase,
            .off = @intCast(self.used),
            .w = r.w,
            .h = r.h,
            .x0 = r.x0,
            .y0 = r.y0,
            .valid = true,
        };
        self.used += len;
        return .{ .w = r.w, .h = r.h, .x0 = r.x0, .y0 = r.y0, .pixels = r.coverage };
    }

    fn probeStart(self: *Cache, gid: u16, scale_key: u32, phase: Phase) usize {
        // The scale enters the key by its raw bits. Quantising it onto a size
        // lattice would let two neighbouring sizes share a mask, which is the
        // wrong glyph by design; a caller that animates size loses hit rate
        // instead, and that is the honest failure.
        var key: u64 = (@as(u64, gid) << 40) ^ (@as(u64, scale_key) << 2) ^ @intFromEnum(phase);
        key *%= 0x9E3779B97F4A7C15;
        key ^= key >> 29;
        return @as(usize, key >> 16) % self.slots.len;
    }

    fn find(self: *Cache, gid: u16, scale_key: u32, phase: Phase) ?*Slot {
        const start = self.probeStart(gid, scale_key, phase);
        var i: usize = 0;
        while (i < self.slots.len) : (i += 1) {
            const s = &self.slots[(start + i) % self.slots.len];
            if (!s.valid) return null; // an empty slot ends the probe run
            if (s.gid == gid and s.scale_key == scale_key and s.phase == phase) return s;
        }
        return null;
    }

    fn freeSlot(self: *Cache, gid: u16, scale_key: u32, phase: Phase) ?*Slot {
        const start = self.probeStart(gid, scale_key, phase);
        var i: usize = 0;
        while (i < self.slots.len) : (i += 1) {
            const s = &self.slots[(start + i) % self.slots.len];
            if (!s.valid) return s;
        }
        return null;
    }

    fn reset(self: *Cache) void {
        for (self.slots) |*s| s.valid = false;
        self.used = 0;
    }

    /// Everything goes. Counted, because a high flush count means the caller
    /// sized the arena below the working set and that is worth being able to
    /// see rather than infer from timings.
    fn flush(self: *Cache) void {
        self.reset();
        self.stats.flushes += 1;
    }
};

fn takeSlice(comptime T: type, mem: []align(8) u8, off: *usize, n: usize) []T {
    const start = std.mem.alignForward(usize, off.*, @alignOf(T));
    off.* = start + n * @sizeOf(T);
    const p: [*]T = @ptrCast(@alignCast(mem.ptr + start));
    return p[0..n];
}

// ---------------------------------------------------------------------------
// bounds-checked big-endian reads
// ---------------------------------------------------------------------------

fn u8At(b: []const u8, off: usize) ReadError!u8 {
    if (off >= b.len) return error.Truncated;
    return b[off];
}

fn u16At(b: []const u8, off: usize) ReadError!u16 {
    if (off + 2 > b.len) return error.Truncated;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn i16At(b: []const u8, off: usize) ReadError!i16 {
    return @bitCast(try u16At(b, off));
}

fn u32At(b: []const u8, off: usize) ReadError!u32 {
    if (off + 4 > b.len) return error.Truncated;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

// ---------------------------------------------------------------------------
// tests: a synthetic font, so the suite needs no font file
// ---------------------------------------------------------------------------

/// Reads that answer null instead of erroring. Optional tables use these:
/// a short `name` or `OS/2` record must not charge the caller an error union
/// it cannot act on, and absence is already legal for both.
fn at16(b: []const u8, off: usize) ?u16 {
    if (off + 2 > b.len) return null;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

/// Parse an `OS/2` body. Version 0 ends at offset 78; later versions append,
/// so a table long enough for the version it claims is accepted.
fn os2Table(t: []const u8) ?Os2 {
    const version = at16(t, 0) orelse return null;
    const weight = at16(t, 4) orelse return null;
    const selection = at16(t, 62) orelse return null;
    const typo_asc = at16(t, 68) orelse return null;
    const typo_desc = at16(t, 70) orelse return null;
    const typo_gap = at16(t, 72) orelse return null;
    const win_asc = at16(t, 74) orelse return null;
    const win_desc = at16(t, 76) orelse return null;

    // xHeight sits at 86 and sCapHeight at 88, and only from version 2. On a
    // version 0 table those bytes are the reserved gap, so reading them would
    // invent two numbers that look authoritative.
    var x_height: ?i16 = null;
    var cap_height: ?i16 = null;
    if (version >= 2) {
        x_height = @bitCast(at16(t, 86) orelse return null);
        cap_height = @bitCast(at16(t, 88) orelse return null);
    }

    return .{
        .version = version,
        .weight = weight,
        .selection = selection,
        .typo_ascender = @bitCast(typo_asc),
        .typo_descender = @bitCast(typo_desc),
        .typo_line_gap = @bitCast(typo_gap),
        .win_ascent = win_asc,
        .win_descent = win_desc,
        .cap_height = cap_height,
        .x_height = x_height,
    };
}

/// Pick the best `name` record for `id` and decode it into `out`.
///
/// Microsoft Unicode (3,1)/(3,10) wins over Apple Mac Roman (1,0), because the
/// Windows record is UTF-16 and carries every script while the Mac record is a
/// single-byte codepage. A Mac record is used only while it is pure ASCII:
/// reproducing it exactly needs a 128-entry table, and guessing would put the
/// wrong character in a string whose whole job is to be exact.
/// Pick one `name` record and decode it.
///
/// The same id is usually stored several times, once per encoding, so a
/// preference order is unavoidable. Windows Unicode (platform 3, encoding 1 or
/// 10) wins, then the Unicode platform, then Mac Roman -- which is accepted
/// ONLY while the bytes are pure ASCII. Decoding Mac Roman properly means
/// implementing Mac OS Roman, and half-doing it would turn a name into
/// mojibake; refusing to guess is better than a plausible wrong answer.
///
/// The first record of the winning rank wins, so the pick does not depend on
/// how many duplicates a face ships. A record pointing outside the table is
/// skipped rather than trusted.
fn nameRecord(tbl: []const u8, id: u16, out: []u8) ?[]const u8 {
    const count = at16(tbl, 2) orelse return null;
    const storage = at16(tbl, 4) orelse return null;

    var best_rank: u8 = 0;
    var best_off: usize = 0;
    var best_len: usize = 0;
    var best_wide = false;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r = 6 + i * 12;
        const plat = at16(tbl, r) orelse break;
        const enc = at16(tbl, r + 2) orelse break;
        const nid = at16(tbl, r + 6) orelse break;
        const len = at16(tbl, r + 8) orelse break;
        const off = at16(tbl, r + 10) orelse break;
        if (nid != id) continue;

        var rank: u8 = 0;
        var wide = false;
        if (plat == 3 and (enc == 1 or enc == 10)) {
            rank = 2;
            wide = true;
        } else if (plat == 0) {
            rank = 1;
            wide = true;
        } else if (plat == 1 and enc == 0) {
            rank = 1;
        }
        if (rank == 0) continue;

        const start = @as(usize, storage) + @as(usize, off);
        const end = start + @as(usize, len);
        // A record that points outside the table is not a name we can read.
        if (end > tbl.len) continue;

        if (!wide) {
            var ascii = true;
            for (tbl[start..end]) |ch| {
                if (ch >= 0x80) {
                    ascii = false;
                    break;
                }
            }
            if (!ascii) continue;
        }

        // Strictly better only: the first record of the best rank wins, so the
        // pick does not depend on how many duplicates a font ships.
        if (rank > best_rank) {
            best_rank = rank;
            best_off = start;
            best_len = end - start;
            best_wide = wide;
        }
    }

    if (best_rank == 0) return null;
    const body = tbl[best_off..][0..best_len];
    if (best_wide) return utf16beToUtf8(body, out);
    const n = @min(body.len, out.len);
    @memcpy(out[0..n], body[0..n]);
    return out[0..n];
}

/// UTF-16 big-endian to UTF-8, truncated at a codepoint boundary when `out` is
/// too small for the whole string.
fn utf16beToUtf8(s: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 2 <= s.len) {
        const u = std.mem.readInt(u16, s[i..][0..2], .big);
        i += 2;
        var cp: u21 = @intCast(u);
        if (u >= 0xD800 and u <= 0xDBFF) {
            // High half of a surrogate pair. A lone one is not text, so it
            // becomes a placeholder rather than disappearing silently.
            if (i + 2 <= s.len) {
                const lo = std.mem.readInt(u16, s[i..][0..2], .big);
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    i += 2;
                    cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
                } else cp = '?';
            } else cp = '?';
        } else if (u >= 0xDC00 and u <= 0xDFFF) {
            cp = '?';
        }
        var enc: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &enc) catch continue;
        if (n + len > out.len) break;
        @memcpy(out[n..][0..len], enc[0..len]);
        n += len;
    }
    return out[0..n];
}

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
    w16(buf[0..], len4_at, @intCast(w.at - f4));
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

// ---------------------------------------------------------------------------
// raster tests: hand-computed shapes first, supersampling as a referee
// ---------------------------------------------------------------------------

fn covAt(cov: []const u8, w: usize, x: usize, row: usize) u8 {
    return cov[row * w + x];
}

test "sweep: a rectangle lands on half, full, half" {
    var cov: [6 * 3]u8 = undefined;
    var acc: [6 * 2 + 2]f32 = undefined;

    // Closed clockwise: down the right side at x=3.5, up the left at x=1.5.
    // Horizontals are omitted, as they contribute no area.
    var edges = [_]Edge{
        .{ .x0 = 3.5, .y0 = 0, .x1 = 3.5, .y1 = 3, .dir = 1 },
        .{ .x0 = 1.5, .y0 = 0, .x1 = 1.5, .y1 = 3, .dir = -1 },
    };
    try sweep(&edges, 6, 3, &acc, &cov);

    var row: usize = 0;
    while (row < 3) : (row += 1) {
        try std.testing.expectEqual(@as(u8, 0), covAt(&cov, 6, 0, row));
        try std.testing.expectEqual(@as(u8, 128), covAt(&cov, 6, 1, row));
        try std.testing.expectEqual(@as(u8, 255), covAt(&cov, 6, 2, row));
        try std.testing.expectEqual(@as(u8, 128), covAt(&cov, 6, 3, row));
        try std.testing.expectEqual(@as(u8, 0), covAt(&cov, 6, 4, row));
    }
}

test "sweep: a hole wound the other way cancels" {
    var cov: [5 * 2]u8 = undefined;
    var acc: [5 * 2 + 2]f32 = undefined;

    var edges = [_]Edge{
        .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 2, .dir = -1 }, // outer left
        .{ .x0 = 4, .y0 = 0, .x1 = 4, .y1 = 2, .dir = 1 }, // outer right
        .{ .x0 = 1, .y0 = 0, .x1 = 1, .y1 = 2, .dir = 1 }, // hole left
        .{ .x0 = 2, .y0 = 0, .x1 = 2, .y1 = 2, .dir = -1 }, // hole right
    };
    try sweep(&edges, 5, 2, &acc, &cov);

    try std.testing.expectEqual(@as(u8, 255), covAt(&cov, 5, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), covAt(&cov, 5, 1, 0));
    try std.testing.expectEqual(@as(u8, 255), covAt(&cov, 5, 2, 0));
    try std.testing.expectEqual(@as(u8, 255), covAt(&cov, 5, 3, 0));
    try std.testing.expectEqual(@as(u8, 0), covAt(&cov, 5, 4, 0));
}

/// Coverage by brute force: the referee the exact accumulator is checked
/// against, so the accumulator is not graded by its own algebra.
fn supersample(edges: []const Edge, w: usize, h: usize, n: usize, out: []u8) void {
    @memset(out, 0);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        var c: usize = 0;
        while (c < w) : (c += 1) {
            var hits: usize = 0;
            var sy: usize = 0;
            while (sy < n) : (sy += 1) {
                const py = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(n));
                var sx: usize = 0;
                while (sx < n) : (sx += 1) {
                    const px = @as(f32, @floatFromInt(c)) + (@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, @floatFromInt(n));
                    // nonzero winding: sum the direction of edges crossing the
                    // upward ray from the sample point.
                    var wind: i32 = 0;
                    for (edges) |e| {
                        if (py < e.y0 or py >= e.y1) continue;
                        const k = (e.x1 - e.x0) / (e.y1 - e.y0);
                        const x = e.x0 + (py - e.y0) * k;
                        if (x > px) wind += e.dir;
                    }
                    if (wind != 0) hits += 1;
                }
            }
            const frac = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(n * n));
            out[row * w + c] = @intFromFloat(@round(frac * 255.0));
        }
    }
}

test "exact area agrees with brute-force supersampling on a triangle" {
    // Right triangle (1,1)-(12,1)-(1,12): the top edge is horizontal so it
    // drops out, leaving a slanted hypotenuse and one vertical side.
    var edges = [_]Edge{
        .{ .x0 = 12, .y0 = 1, .x1 = 1, .y1 = 12, .dir = 1 }, // hypotenuse
        .{ .x0 = 1, .y0 = 1, .x1 = 1, .y1 = 12, .dir = -1 }, // vertical side
    };
    const w = 14;
    const h = 14;

    var exact: [w * h]u8 = undefined;
    var brute: [w * h]u8 = undefined;
    var acc: [w * 2 + 2]f32 = undefined;
    try sweep(&edges, w, h, &acc, &exact);
    supersample(&edges, w, h, 24, &brute);

    var worst: i32 = 0;
    for (exact, brute) |a, b| {
        const d = @as(i32, a) - @as(i32, b);
        worst = @max(worst, if (d < 0) -d else d);
    }
    std.debug.print("triangle: worst delta {d}\n", .{worst});
    // 24x24 samples leave a little noise; a wrong integral would be far worse.
    try std.testing.expect(worst <= 6);
}

test "a font collection resolves its first face" {
    // Wrap the synthetic font in a minimal ttcf header and check that the face
    // inside is found at the recorded offset.
    var inner: [2048]u8 = undefined;
    const face = buildTestFont(&inner, false);

    var buf: [4096]u8 = undefined;
    @memset(&buf, 0);
    w32(buf[0..], 0, tag("ttcf"));
    w32(buf[0..], 4, 0x0001_0000); // version
    w32(buf[0..], 8, 1); // numFonts
    w32(buf[0..], 12, 16); // offset of face 0
    @memcpy(buf[16 .. 16 + face.len], face);

    // Table offsets inside a collection are file-relative, so shift each of the
    // 7 records by the face's new position.
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const at = 16 + 12 + i * 16 + 8;
        w32(buf[0..], at, std.mem.readInt(u32, buf[at..][0..4], .big) + 16);
    }

    const f = try Font.init(buf[0 .. 16 + face.len]);
    try std.testing.expectEqual(@as(u16, 1024), f.units_per_em);
    try std.testing.expectError(error.UnknownFontIndex, Font.initIndex(buf[0 .. 16 + face.len], 1));
}

test "limits come from a maxp 1.0 table and are zero otherwise" {
    var buf: [2048]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));
    // The synthetic font declares maxp 0.5, which has no such fields.
    try std.testing.expectEqual(Limits{ .max_points = 0, .max_contours = 0 }, try f.limits());
}

// ---------------------------------------------------------------------------
// malformed fonts: every check below has to be able to fail
// ---------------------------------------------------------------------------

/// The nth table record in the synthetic font: where its body starts and where
/// its length field lives, so a test can break exactly one thing.
fn recSpan(buf: []const u8, n: usize) struct { off: usize, len_at: usize } {
    const at = 12 + n * 16;
    return .{
        .off = @intCast(std.mem.readInt(u32, buf[at + 8 ..][0..4], .big)),
        .len_at = at + 12,
    };
}

const rec_head = 3;
const rec_hhea = 4;
const rec_hmtx = 5;

test "a table shorter than its fields is refused, not read past" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    // head carries fields out to offset 52; 20 bytes must not be accepted just
    // because the next table happens to follow it.
    w32(buf[0..], recSpan(&buf, rec_head).len_at, 20);
    try std.testing.expectError(error.Truncated, Font.init(buf[0..font.len]));
}

test "hmtx too short for its metrics is refused" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    w32(buf[0..], recSpan(&buf, rec_hmtx).len_at, 5);
    try std.testing.expectError(error.Truncated, Font.init(buf[0..font.len]));
}

test "more hmetrics than glyphs is refused" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    const hhea = recSpan(&buf, rec_hhea).off;
    w16(buf[0..], hhea + 34, 9); // numberOfHMetrics, numGlyphs is 8
    try std.testing.expectError(error.BadValue, Font.init(buf[0..font.len]));
}

test "loca that goes backwards is refused" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    const loca = recSpan(&buf, 2).off;
    // Entries are 0,0,0,0,0,0,0,12,21; pushing entry 7 past entry 8 inverts the
    // last glyph's byte range.
    w16(buf[0..], loca + 7 * 2, 30);
    try std.testing.expectError(error.Truncated, Font.init(buf[0..font.len]));
}

test "a cmap segment array larger than the subtable is refused" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    const f4 = recSpan(&buf, 0).off + 12; // format-4 subtable
    w16(buf[0..], f4 + 6, 4000); // segCountX2
    try std.testing.expectError(error.Truncated, Font.init(buf[0..font.len]));
}

test "a composite that refers to itself stops at the depth limit" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    const glyf = recSpan(&buf, 1).off;
    // The triangle is 24 bytes; the composite starts after it. Its component
    // glyph id is 2 bytes into the record, after the 10-byte header and flags.
    w16(buf[0..], glyf + 24 + 12, 7); // point gid 7 at itself

    const f = try Font.init(buf[0..font.len]);
    var pts: [64]Point = undefined;
    var ends: [8]u16 = undefined;
    try std.testing.expectError(error.CompositeTooDeep, f.outline(7, &pts, &ends));
}

test "a cached mask matches a direct rasterisation, and repeats are hits" {
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));

    var pts: [256]Point = undefined;
    var ends: [16]u16 = undefined;
    var edges: [256]Edge = undefined;
    var scratch: [2 * 64 + 2]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;

    var cbuf: [64 * 1024]u8 align(8) = undefined;
    var cache = try Cache.init(&cbuf, .{ .slots = 16, .max_points = 256, .max_edges = 256, .max_width = 64, .arena = 48 * 1024 });

    const ppem: u16 = 16;
    const scale = @as(f32, @floatFromInt(ppem)) / @as(f32, @floatFromInt(font.units_per_em));
    const direct = try font.raster(6, scale, 0, &pts, &ends, &edges, &scratch, &cov);

    const first = try cache.mask(font, 6, ppem, .zero);
    try std.testing.expectEqual(@as(u64, 0), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
    try std.testing.expectEqual(direct.w, first.w);
    try std.testing.expectEqual(direct.h, first.h);
    try std.testing.expectEqualSlices(u8, direct.coverage, first.pixels);

    const second = try cache.mask(font, 6, ppem, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
    try std.testing.expectEqualSlices(u8, first.pixels, second.pixels);
}

test "the cache key covers size and phase, not just the glyph" {
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));
    var cbuf: [64 * 1024]u8 align(8) = undefined;
    var cache = try Cache.init(&cbuf, .{ .slots = 16, .max_points = 256, .max_edges = 256, .max_width = 64, .arena = 48 * 1024 });

    _ = try cache.mask(font, 6, 16, .zero);
    _ = try cache.mask(font, 6, 16, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);

    // A different size is a different mask, and so is a different phase.
    _ = try cache.mask(font, 6, 17, .zero);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.misses);
    _ = try cache.mask(font, 6, 16, .half);
    try std.testing.expectEqual(@as(u64, 3), cache.stats.misses);

    _ = try cache.mask(font, 6, 16, .zero);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.hits);
}

test "a full arena flushes instead of handing back stale pixels" {
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));

    var pts: [256]Point = undefined;
    var ends: [16]u16 = undefined;
    var edges: [256]Edge = undefined;
    var scratch: [2 * 64 + 2]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;

    // Room for a couple of masks, so a spread of sizes must evict.
    var cbuf: [64 * 1024]u8 align(8) = undefined;
    var cache = try Cache.init(&cbuf, .{ .slots = 16, .max_points = 256, .max_edges = 256, .max_width = 64, .arena = 512 });

    var ppem: u16 = 6;
    var last: Mask = .{};
    while (ppem < 40) : (ppem += 1) {
        last = try cache.mask(font, 6, ppem, .zero);
    }
    try std.testing.expect(cache.stats.flushes > 0);

    // Whatever survived the flush has to be a correct rasterisation of THIS
    // key, which is the failure a stale offset would produce.
    const scale = @as(f32, @floatFromInt(@as(u16, 39))) / @as(f32, @floatFromInt(font.units_per_em));
    const direct = try font.raster(6, scale, 0, &pts, &ends, &edges, &scratch, &cov);
    try std.testing.expectEqualSlices(u8, direct.coverage, last.pixels);
}

test "phase classes quantise to the nearest quarter pixel" {
    try std.testing.expectEqual(Phase.zero, phaseOf(0.0));
    try std.testing.expectEqual(Phase.zero, phaseOf(0.1));
    try std.testing.expectEqual(Phase.quarter, phaseOf(0.2));
    try std.testing.expectEqual(Phase.half, phaseOf(0.5));
    try std.testing.expectEqual(Phase.three_quarters, phaseOf(0.8));
    try std.testing.expectEqual(Phase.zero, phaseOf(1.0));
    try std.testing.expectEqual(Phase.half, phaseOf(3.5));
    try std.testing.expectEqual(@as(f32, 0.5), phaseOffset(.half));
}

test "the usage shown in the README compiles and runs" {
    var fb: [2048]u8 = undefined;
    const bytes = buildTestFont(&fb, false);
    var storage: [64 * 1024]u8 align(8) = undefined;

    var font = try Font.init(bytes); // bytes are yours
    var cache = try Cache.init(&storage, .{
        .slots = 16,
        .max_points = 256,
        .max_edges = 256,
        .max_width = 64,
        .arena = 16 * 1024,
    }); // storage is yours
    const gid = try font.glyphIndex('A');
    const m = try cache.mask(font, gid, 16, .zero); // a hash lookup once warm

    try std.testing.expect(m.w > 0 and m.h > 0);
    try std.testing.expectEqual(m.pixels.len, @as(usize, m.w) * m.h);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
}

// --- malformed input -------------------------------------------------------
//
// A font parser reads lengths and offsets that arrive from outside the
// program, and every one of them is a chance to read somewhere it shouldn't.
// The validation tests each break one field on purpose; this sweep breaks
// everything, everywhere, including combinations no test author would think
// of. A panic or an out-of-bounds read here fails the suite, which is the
// point: the library is meant to reject garbage, never to fault on it.
//
// Truncations and single-bit flips are the two cheapest ways to reach a lot of
// states quickly. Anything that loads has to behave, so a successful init is
// followed through the glyph path rather than merely counted.

fn sweepUse(bytes: []const u8, cmem: []align(8) u8, deep: bool) void {
    const font = Font.init(bytes) catch return;
    // A face that loaded has to be coherent, not just non-faulting.
    std.debug.assert(font.units_per_em > 0);
    std.debug.assert(font.num_glyphs > 0);

    var cache = Cache.init(cmem, .{}) catch return;
    var gid: u16 = 0;
    const last: u16 = if (deep) 7 else 6;
    while (gid <= last) : (gid += 1) {
        _ = font.hMetrics(gid) catch {};
        _ = font.bitmapBox(gid, 0.0175, 0) catch {};
        _ = font.bitmapBox(gid, 0.0175, 0.5) catch {};
        _ = cache.mask(font, gid, 13, .zero) catch {};
    }
    _ = font.kern(2, 3);
    _ = font.kern(6, 7);
    _ = font.kerning();
}

test "every truncation either loads cleanly or is rejected" {
    var buf: [4096]u8 = undefined;
    const base = buildTestFont(&buf, true);
    var cmem: [192 * 1024]u8 align(8) = undefined;
    var n: usize = 0;
    while (n <= base.len) : (n += 1) sweepUse(base[0..n], &cmem, false);
}

test "every single-bit flip either loads cleanly or is rejected" {
    var buf: [4096]u8 = undefined;
    const base = buildTestFont(&buf, true);
    var scratch: [4096]u8 = undefined;
    var cmem: [192 * 1024]u8 align(8) = undefined;
    var i: usize = 0;
    while (i < base.len) : (i += 1) {
        var bit: u3 = 0;
        while (true) : (bit += 1) {
            @memcpy(scratch[0..base.len], base);
            scratch[i] ^= @as(u8, 1) << bit;
            sweepUse(scratch[0..base.len], &cmem, false);
            if (bit == 7) break;
        }
    }
}

// ---------------------------------------------------------------------------
// name, OS/2, and codepoint coverage
// ---------------------------------------------------------------------------

const NameSrc = struct { plat: u16, enc: u16, id: u16, body: []const u8 };

/// Lay out a `name` table body: header, one record per source, then the
/// strings. Strings go in the order given, so a record's offset is test data
/// rather than something the builder hides.
fn buildName(buf: []u8, srcs: []const NameSrc) []const u8 {
    const base: usize = 6 + srcs.len * 12;
    w16(buf, 0, 0); // format 0
    w16(buf, 2, @intCast(srcs.len));
    w16(buf, 4, @intCast(base));
    var off: usize = 0;
    for (srcs, 0..) |src, i| {
        const r = 6 + i * 12;
        w16(buf, r, src.plat);
        w16(buf, r + 2, src.enc);
        w16(buf, r + 4, 0x409); // language: en-US, which the lookup ignores
        w16(buf, r + 6, src.id);
        w16(buf, r + 8, @intCast(src.body.len));
        w16(buf, r + 10, @intCast(off));
        @memcpy(buf[base + off ..][0..src.body.len], src.body);
        off += src.body.len;
    }
    return buf[0 .. base + off];
}

/// ASCII to the UTF-16BE the Windows records use.
fn utf16be(dst: []u8, src: []const u8) []const u8 {
    for (src, 0..) |ch, i| {
        dst[i * 2] = 0;
        dst[i * 2 + 1] = ch;
    }
    return dst[0 .. src.len * 2];
}

test "a name record decodes from UTF-16 big endian" {
    var tbuf: [256]u8 = undefined;
    var sbuf: [64]u8 = undefined;
    const tbl = buildName(&tbuf, &.{.{
        .plat = 3,
        .enc = 1,
        .id = @intFromEnum(NameId.family),
        .body = utf16be(&sbuf, "GlyfZ Sans"),
    }});
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("GlyfZ Sans", nameRecord(tbl, 1, &out).?);
}

test "Microsoft Unicode beats Mac Roman for the same name id" {
    var tbuf: [256]u8 = undefined;
    var sbuf: [64]u8 = undefined;
    // The Mac record is listed FIRST, so a lookup that just took the first
    // match would return "Mac Name" and this test would fail.
    const tbl = buildName(&tbuf, &.{
        .{ .plat = 1, .enc = 0, .id = 1, .body = "Mac Name" },
        .{ .plat = 3, .enc = 1, .id = 1, .body = utf16be(&sbuf, "Win Name") },
    });
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Win Name", nameRecord(tbl, 1, &out).?);
}

test "a Mac Roman record with a high byte is skipped, not guessed" {
    var tbuf: [256]u8 = undefined;
    // 0xE9 is e-acute in Mac Roman and something else in every other codepage.
    const tbl = buildName(&tbuf, &.{.{
        .plat = 1,
        .enc = 0,
        .id = 1,
        .body = "Caf\xe9",
    }});
    var out: [64]u8 = undefined;
    try std.testing.expect(nameRecord(tbl, 1, &out) == null);
}

test "a name record pointing outside its table is not read" {
    var tbuf: [256]u8 = undefined;
    var sbuf: [64]u8 = undefined;
    const body = utf16be(&sbuf, "Out There");
    // The slice aliases tbuf, so breaking the offset after building is
    // breaking the very table being read.
    const tbl = buildName(&tbuf, &.{.{ .plat = 3, .enc = 1, .id = 1, .body = body }});
    w16(tbuf[0..], 6 + 10, 4000); // string now points far past the table
    var out: [64]u8 = undefined;
    try std.testing.expect(nameRecord(tbl, 1, &out) == null);
}

test "a name truncated by a small buffer stops at a codepoint boundary" {
    var tbuf: [256]u8 = undefined;
    var sbuf: [64]u8 = undefined;
    const tbl = buildName(&tbuf, &.{.{
        .plat = 3,
        .enc = 1,
        .id = 1,
        .body = utf16be(&sbuf, "GlyfZ"),
    }});
    var small: [3]u8 = undefined;
    try std.testing.expectEqualStrings("Gly", nameRecord(tbl, 1, &small).?);
    var empty: [0]u8 = undefined;
    try std.testing.expectEqualStrings("", nameRecord(tbl, 1, &empty).?);
}

test "a surrogate pair decodes to one codepoint" {
    var tbuf: [256]u8 = undefined;
    var body: [4]u8 = undefined;
    // U+1F600, as the two halves UTF-16 actually uses.
    std.mem.writeInt(u16, body[0..2], 0xD83D, .big);
    std.mem.writeInt(u16, body[2..4], 0xDE00, .big);
    const tbl = buildName(&tbuf, &.{.{ .plat = 3, .enc = 10, .id = 1, .body = &body }});
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\u{1F600}", nameRecord(tbl, 1, &out).?);
}

/// A table long enough for the version it claims, with the fields a test
/// needs set and everything else left zero.
fn buildOs2(buf: []u8, version: u16, len: usize) []const u8 {
    @memset(buf[0..len], 0);
    w16(buf, 0, version);
    w16(buf, 4, 700); // usWeightClass: bold
    w16(buf, 62, 0x20); // fsSelection: bold bit
    w16(buf, 68, @bitCast(@as(i16, 1556))); // sTypoAscender
    w16(buf, 70, @bitCast(@as(i16, -492))); // sTypoDescender
    w16(buf, 74, 1901); // usWinAscent
    w16(buf, 76, 483); // usWinDescent
    if (len >= 90) {
        w16(buf, 86, 1118); // sxHeight
        w16(buf, 88, 1493); // sCapHeight
    }
    return buf[0..len];
}

test "OS/2 keeps the typographic metrics apart from the Windows ones" {
    var buf: [96]u8 = undefined;
    const o = os2Table(buildOs2(&buf, 4, 96)).?;
    try std.testing.expectEqual(@as(u16, 1556), @as(u16, @bitCast(o.typo_ascender)));
    try std.testing.expectEqual(@as(i16, -492), o.typo_descender);
    try std.testing.expectEqual(@as(u16, 1901), o.win_ascent);
    try std.testing.expectEqual(@as(i16, 1493), o.cap_height.?);
    try std.testing.expectEqual(@as(i16, 1118), o.x_height.?);
    try std.testing.expect(o.bold());
    try std.testing.expect(!o.italic());
}

test "OS/2 below version 2 reports no cap height rather than zero" {
    var buf: [96]u8 = undefined;
    const o = os2Table(buildOs2(&buf, 0, 78)).?;
    // 1493 and 1118 are still in the buffer; a version 0 table must not read
    // them out of the reserved gap.
    try std.testing.expect(o.cap_height == null);
    try std.testing.expect(o.x_height == null);
    try std.testing.expectEqual(@as(u16, 0), o.version);
}

test "a table too short for OS/2 fields is refused" {
    var buf: [96]u8 = undefined;
    try std.testing.expect(os2Table(buildOs2(&buf, 0, 40)) == null);
}

test "a face without name or OS/2 answers null instead of failing" {
    var buf: [2048]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));
    var out: [32]u8 = undefined;
    try std.testing.expect(f.family(&out) == null);
    try std.testing.expect(f.style(&out) == null);
    try std.testing.expect(f.os2() == null);
}

test "hasCodepoint separates .notdef from a real glyph" {
    var buf: [2048]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));
    // The synthetic face maps 'A' to the triangle and 'B' to glyph 2, so both
    // are present even though only one is drawn by the tests.
    try std.testing.expect(f.hasCodepoint('A'));
    try std.testing.expect(f.hasCodepoint('B'));
    // 'C' falls in the format's terminal segment, which maps it arithmetically
    // to a glyph this face does not have. That is absent, not present.
    try std.testing.expect(!f.hasCodepoint('C'));
    // Beyond the subtable's reach entirely, and still just "absent".
    try std.testing.expect(!f.hasCodepoint(0x10FFFF));
}
