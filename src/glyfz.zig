//! GlyfZ -- a TrueType font parser and rasteriser.
//!
//! Reads `glyf`-based fonts, turns outlines into antialiased coverage masks,
//! and keeps those masks between draws. It shapes Arabic and Thai through their
//! GSUB features; there is no fallback chain and no line breaking.
//!
//! Three rules shape the code:
//!
//! 1. **No allocator and no IO.** The font is bytes the caller owns, and every
//!    working buffer -- outlines, edges, coverage, and the glyph cache itself --
//!    is the caller's too. Nothing here reaches outside them.
//! 2. **The spec decides, not the reference.** GlyfZ was developed against
//!    stb_truetype as a differential oracle, which is no longer vendored here.
//!    Where the two disagreed the disagreement is a finding to write down, not
//!    a bug in GlyfZ by default. Three are documented: `cmapFormat4` applies
//!    `idDelta` to a value fetched through a non-zero `idRangeOffset` where stb
//!    does not, composite transforms are applied as given where stb multiplies by
//!    each column's norm, and `SCALED_COMPONENT_OFFSET` is honoured where stb
//!    ignores it entirely.
//! 3. **Failures are scoped.** `LoadError` means discard the face;
//!    `GlyphError` means this one glyph failed and the face is still good. GlyfZ
//!    propagates both and never substitutes a glyph silently -- deciding to keep
//!    a last-good face needs a fallback chain, which belongs to the caller.
//!
//! Outlines come from either `glyf` or `CFF`: a CFF charstring is cubic and
//! this library's outline is quadratic, so CFF curves reach the caller already
//! flattened to line points. See `cff.zig`.
//!
//! Variation comes from `gvar`, with `fvar` declaring the axes and `avar`
//! remapping the user's coordinates on the way into the normalised space that
//! the tuple regions are written in. A glyph is varied where it is DECODED, so
//! a composite's components move with it. See `variations.zig`.
//!
//! Out of scope, deliberately: hinting (stb skips it, so unhinted is the bar),
//! COLRv1 (COLRv0 and CPAL are read), GPOS beyond pair adjustment, kern formats
//! 2/3 and Apple's version 1 layout, vertical layout, and Unicode normalisation
//! or line breaking.
//!
//! Two of those are ROADMAP rather than refused, and the README says what each
//! needs: CFF2 (the variable flavour of CFF -- `glyf` variations are read, CFF2
//! is not) and GSUB beyond Arabic and Thai.

const std = @import("std");
const cff = @import("cff.zig");
const colr = @import("colr.zig");
const variations = @import("variations.zig");

pub const Layer = colr.Layer;
pub const Rgba = colr.Rgba;
const opentype = @import("opentype.zig");
const arabic = @import("arabic.zig");

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

/// The header of the `post` table: how the face says it should be set.
///
/// NOT what makes a face italic. `italic_angle` reports a slant the face
/// already has; it neither selects an italic face nor applies an oblique. A
/// renderer picks the face from `OS/2.fsSelection` (`Os2.italic`) and, if it
/// synthesises a slant, decides the angle itself. What lives here is the
/// underline geometry and a declaration of the angle, which is useful for
/// reporting and for a caller that wants to place a rule under text.
///
/// Only the 32-byte header every version shares is read. The version 2.0 glyph
/// name array is not: nothing here needs a glyph's PostScript name.
pub const Post = struct {
    /// Degrees counter-clockwise from upright, as a 16.16 fixed point value.
    /// 0 on an upright face, negative for a typical oblique.
    italic_angle: f32,
    /// Suggested underline offset in font units, y up from the baseline.
    /// Real fonts disagree about sign and sometimes leave this at zero, so
    /// treat it as a suggestion rather than a measurement.
    underline_position: i16,
    underline_thickness: i16,
    /// What the font believes about its own pitch. Unreliable enough that a
    /// caller wanting to know should compare advances instead; reported here
    /// because the table declares it and hiding it would be worse.
    is_fixed_pitch: bool,

    /// Horizontal offset per unit of height that a synthetic oblique needs:
    /// the tangent of the lean, positive for a glyph leaning right.
    ///
    /// Apply as `x' = x + shear * y` with y measured UP from the baseline. This
    /// is the only use the angle has: selecting an italic FACE is
    /// `OS/2.fsSelection` bit 0 or `head.macStyle` bit 1, both already parsed.
    /// A face with a non-zero angle is not thereby "the italic".
    pub fn shear(self: Post) f32 {
        return std.math.tan(-self.italic_angle * std.math.pi / 180.0);
    }

    /// Where to draw a rule under text, in font units, y up.
    ///
    /// The table's own numbers are frequently absent or nonsense: a thickness
    /// of 0 draws nothing, and a position at or above the baseline detaches the
    /// rule from the text it underlines. Both are substituted with the usual
    /// proportions -- 5% of the em for thickness, 10% below the baseline for
    /// position -- rather than returned as-is, because a caller left to
    /// reimplement the substitution gains nothing from having read the table.
    /// The raw fields are public for anyone who would rather decide themselves.
    pub fn underline(self: Post, upem: u16) Underline {
        const em: i32 = @intCast(upem);
        return .{
            .position = if (self.underline_position < 0)
                self.underline_position
            else
                @intCast(@divTrunc(-em, 10)),
            .thickness = if (self.underline_thickness > 0)
                self.underline_thickness
            else
                @intCast(@max(1, @divTrunc(em, 20))),
        };
    }
};

/// A rule under text, in font units, y up.
pub const Underline = struct {
    /// Baseline offset, negative when the rule hangs below the baseline.
    position: i16,
    thickness: i16,
};

pub const Point = struct { x: i32, y: i32, on: bool };

/// Components one composite may carry with variation deltas applied.
const comp_cap = 64;

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
/// Longest run `shapeArabic` will canonically reorder. Past this the text is
/// shaped in written order rather than silently reordered in part -- the same
/// bounded-buffer policy the lookup machinery uses.
pub const max_order = 128;

/// Composite component flag 0x0200: this component's metrics are the
/// composite's metrics. It is how a font builds e.g. "a with acute" so the
/// pair measures like the base letter instead of like its bounding box.
const use_my_metrics: u16 = 0x0200;

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
const tag_post = tag("post");
const tag_gpos = tag("GPOS");
const tag_gsub = tag("GSUB");
const tag_gdef = tag("GDEF");
const tag_cff = tag("CFF ");
const tag_colr = tag("COLR");
const tag_fvar = tag("fvar");
const tag_avar = tag("avar");
const tag_gvar = tag("gvar");
const tag_hvar = tag("HVAR");
const tag_cpal = tag("CPAL");

/// Map a CFF failure onto this library's glyph error set. A CFF construct that
/// is not implemented is reported as `UnsupportedComposite`, which already
/// means "this glyph needs something the reader does not do".
fn cffGlyphError(e: cff.Error) GlyphError {
    return switch (e) {
        error.Truncated => error.Truncated,
        error.MissingTable => error.MissingTable,
        error.BufferTooSmall => error.BufferTooSmall,
        error.SubrTooDeep => error.CompositeTooDeep,
        error.NotCff, error.Unsupported => error.UnsupportedComposite,
    };
}

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
    post_span: Span = .{},
    gpos_span: Span = .{},
    gsub_span: Span = .{},
    gdef_span: Span = .{},
    cff_span: Span = .{},
    colr_span: Span = .{},
    fvar_span: Span = .{},
    avar_span: Span = .{},
    gvar_span: Span = .{},
    hvar_span: Span = .{},
    /// Normalised axis coordinates, in axis order. Zero is the default
    /// instance, so a Font that was never varied costs nothing extra to decode.
    coords: [variations.max_axes]f32 = @splat(0),
    n_coords: u8 = 0,
    cpal_span: Span = .{},

    /// Set when the outlines come from a CFF table instead of `glyf`. The
    /// container is parsed at load; charstrings are interpreted per glyph.
    cff: ?cff.Font = null,
    is_cff: bool = false,

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
        var is_cff = false;
        const v = try u32At(bytes, 0);
        switch (v) {
            0x0001_0000, tag("true") => {},
            tag("ttcf") => {
                const count = try u32At(bytes, 8);
                if (index >= count) return error.UnknownFontIndex;
                base = try u32At(bytes, 12 + @as(usize, index) * 4);
            },
            // OTTO means CFF outlines. Loadable now; `CFF2` (a different,
            // variable-font format) is still refused below, by tag.
            tag("OTTO") => is_cff = true,
            else => return error.NotSfnt,
        }

        var self: Font = .{ .data = bytes };
        self.is_cff = is_cff;
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
            if (t == tag_post) self.post_span = span;
            if (t == tag_gpos) self.gpos_span = span;
            if (t == tag_gsub) self.gsub_span = span;
            if (t == tag_gdef) self.gdef_span = span;
            if (t == tag_cff) self.cff_span = span;
            if (t == tag_colr) self.colr_span = span;
            if (t == tag_fvar) self.fvar_span = span;
            if (t == tag_avar) self.avar_span = span;
            if (t == tag_gvar) self.gvar_span = span;
            if (t == tag_hvar) self.hvar_span = span;
            if (t == tag_cpal) self.cpal_span = span;
        }

        const head = try self.slice(self.head);
        const hhea = try self.slice(self.hhea);
        const maxp = try self.slice(self.maxp);
        const hmtx = try self.slice(self.hmtx);
        if (!self.is_cff) _ = try self.slice(self.glyf);

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

        // A CFF face has no glyf/loca at all, so those checks are skipped --
        // but the cmap selection below is NOT, because it is what maps a
        // codepoint to a glyph and it applies to both outline formats.
        if (self.is_cff) {
            self.cff = cff.Font.init(try self.slice(self.cff_span)) catch |e| return switch (e) {
                error.NotCff => error.CffNotSupported,
                error.Truncated => error.Truncated,
                error.MissingTable => error.MissingTable,
                else => error.BadValue,
            };
            if (self.cff.?.glyphCount() == 0) return error.MissingTable;
        }

        if (!self.is_cff) {
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

    /// True when the font carries a GPOS table with a header this version can
    /// read. Kerning lives there in most modern fonts, so `kern` can honestly
    /// report nothing while `pairAdjust` has an answer.
    pub fn hasGpos(self: Font) bool {
        _ = opentype.Layout.init(self.data, self.gpos_span.off, self.gpos_span.len) catch return false;
        return true;
    }

    /// GPOS pair adjustment for the `kern` feature, in FONT UNITS.
    ///
    /// Null when there is no GPOS, no `kern` feature, or nothing to say about
    /// this pair. That is NOT the same as an adjustment of zero, which is why
    /// this does not return a bare i16 -- a caller comparing against `kern`'s
    /// zero needs to know whether GPOS was consulted at all.
    ///
    /// Script selection has no text context to work from: `latn`, then DFLT,
    /// then each script in file order (see `featureLookupsDefault`). A caller that knows the script should use
    /// `opentype.Layout` directly. What is not applied: contextual lookups,
    /// GDEF mark filtering, and Device tables. See `opentype.zig`.
    ///
    /// The feature's lookup list is rebuilt per call rather than cached: a
    /// cache needs storage the caller owns, and a stale one would move text
    /// without saying so. Measured at ~30 bounds-checked reads.
    pub fn pairAdjust(self: Font, left: u16, right: u16) ?opentype.Adjust {
        if (self.gpos_span.len < 10) return null;
        const l = opentype.Layout.init(self.data, self.gpos_span.off, self.gpos_span.len) catch return null;
        var buf: [32]u16 = undefined;
        const lookups = l.featureLookupsDefault(opentype.tag("kern"), &buf) catch return null;
        if (lookups.len == 0) return null;
        const a = l.pairAdjust(lookups, left, right);
        if (a.isZero()) return null;
        return a;
    }

    /// The x advance of `pairAdjust`, for a caller that only wants a number
    /// shaped like `kern`'s.
    pub fn kernGpos(self: Font, left: u16, right: u16) i16 {
        const a = self.pairAdjust(left, right) orelse return 0;
        return a.x_advance;
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

    /// Pick a `cmap` subtable and return its format.
    ///
    /// The policy is deliberately the same one the previous backend used: walk
    /// the encoding records in file order and let the last one we understand
    /// win. Microsoft full-repertoire (3,10) beats Microsoft BMP (3,1) only
    /// because a well-formed font lists it later. The alternative -- scoring
    /// records -- would pick a different subtable on some fonts and move text
    /// on a swap, for no gain.
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
        return nameRecord(tbl, @backingInt(id), out);
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

    /// The `post` header, or null when the face has none -- or when it has one
    /// too short to hold the header at all.
    ///
    /// Same policy as `os2` and `name`: this is decoration, so a table GlyfZ
    /// cannot read costs the caller a fallback, never a face. A caller that
    /// needs to tell "absent" from "broken" has to parse the table itself.
    pub fn post(self: Font) ?Post {
        const tbl = self.slice(self.post_span) catch return null;
        // The header every version shares. A shorter table is a table GlyfZ
        // cannot read, which for decoration means falling back -- the reads
        // below are then in range by construction, not by luck.
        if (tbl.len < 32) return null;
        const angle: i32 = @bitCast(u32At(tbl, 4) catch return null);
        return .{
            .italic_angle = @as(f32, @floatFromInt(angle)) / 65536.0,
            .underline_position = i16At(tbl, 8) catch return null,
            .underline_thickness = i16At(tbl, 10) catch return null,
            .is_fixed_pitch = (u32At(tbl, 12) catch return null) != 0,
        };
    }

    /// Where to draw a rule under text, with the substitutions
    /// `Post.underline` applies. Null when the face has no readable `post`
    /// table at all, which is legal -- a caller then uses its own proportions.
    pub fn underline(self: Font) ?Underline {
        const p = self.post() orelse return null;
        return p.underline(self.units_per_em);
    }

    /// Decode a glyph's outline into the caller's buffers, in font units.
    ///
    /// No allocation anywhere: `points` and `ends` are scratch the caller
    /// owns and reuses. A blank glyph (or one with no contours) decodes to an
    /// empty outline rather than an error, because that is a legal glyph.
    pub fn outline(self: Font, gid: u16, points: []Point, ends: []u16) GlyphError!Outline {
        if (gid >= self.num_glyphs) return error.UnknownGlyph;
        if (self.cff) |cf| {
            // CFF charstrings are cubic; this library's outline is quadratic,
            // so the curves arrive already flattened to line points. The
            // tolerance is in font units and is far below one device pixel at
            // any realistic size (1 unit at 1000 upem is 0.048px at 48px).
            //
            // The buffer is 1024 because it has to be: flattened, the worst
            // glyph measured is 626 segments in Source Han Serif and 459 in
            // Noto Sans CJK JP. A 256 buffered clipped 27 real CJK glyphs.
            var segs: [1024]cff.Segment = undefined;
            const got = cff.charstring(cf, gid, &segs) catch |e| return cffGlyphError(e);
            const flat = cff.flatten(got, points, ends, 1.0) catch |e| return cffGlyphError(e);
            return .{ .points = flat.points, .ends = flat.ends };
        }
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
        if (self.cff) |cf| {
            // No per-glyph header exists in CFF, so the box is computed from
            // the control points. Still a declared-style integer box in font
            // units, so the bitmap sizing below is unchanged in shape.
            const b = (cff.charstringBox(cf, gid) catch |e| return cffGlyphError(e)) orelse return null;
            return Box{
                .x0 = @intFromFloat(@floor(b.x0)),
                .y0 = @intFromFloat(@floor(b.y0)),
                .x1 = @intFromFloat(@ceil(b.x1)),
                .y1 = @intFromFloat(@ceil(b.y1)),
            };
        }
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
        return self.bitmapBoxPhase(gid, scale, phase_x, 0);
    }

    /// `bitmapBox` with a vertical phase too. Type set on a fractional baseline
    /// needs both axes: an x-only phase leaves every glyph snapped to a whole
    /// pixel vertically, which is why rows looked uneven at 1.25x.
    pub fn bitmapBoxPhase(self: Font, gid: u16, scale: f32, phase_x: f32, phase_y: f32) GlyphError!PixelBox {
        const b = (try self.headerBox(gid)) orelse
            return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
        const f = struct {
            fn v(i: i32, s: f32, add: f32) f32 {
                return @as(f32, @floatFromInt(i)) * s + add;
            }
        };
        return .{
            .x0 = @intFromFloat(@floor(f.v(b.x0, scale, phase_x))),
            .y0 = @intFromFloat(@floor(f.v(-b.y1, scale, phase_y))),
            .x1 = @intFromFloat(@ceil(f.v(b.x1, scale, phase_x))),
            .y1 = @intFromFloat(@ceil(f.v(-b.y0, scale, phase_y))),
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
        return self.edgesIntoPhase(gid, scale, phase_x, 0, box, points, ends, edges);
    }

    /// `edgesInto` with a vertical phase.
    pub fn edgesIntoPhase(
        self: Font,
        gid: u16,
        scale: f32,
        phase_x: f32,
        phase_y: f32,
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
            .phase_y = phase_y,
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
        return self.rasterPhase(gid, scale, phase_x, 0, points, ends, edges, acc, coverage);
    }

    /// `raster` with a vertical phase.
    pub fn rasterPhase(
        self: Font,
        gid: u16,
        scale: f32,
        phase_x: f32,
        phase_y: f32,
        points: []Point,
        ends: []u16,
        edges: []Edge,
        acc: []f32,
        coverage: []u8,
    ) GlyphError!Raster {
        const box = try self.bitmapBoxPhase(gid, scale, phase_x, phase_y);
        const w: u32 = if (box.x1 > box.x0) @intCast(box.x1 - box.x0) else 0;
        const h: u32 = if (box.y1 > box.y0) @intCast(box.y1 - box.y0) else 0;

        const empty = Raster{ .w = w, .h = h, .x0 = box.x0, .y0 = box.y0, .coverage = &.{} };
        if (w == 0 or h == 0) return empty;

        const need = @as(usize, w) * h;
        if (coverage.len < need) return error.BufferTooSmall;
        if (acc.len < @as(usize, w) * 2 + 2) return error.BufferTooSmall;

        const n = try self.edgesIntoPhase(gid, scale, phase_x, phase_y, box, points, ends, edges);
        try sweep(edges[0..n], w, h, acc, coverage[0..need]);
        return .{ .w = w, .h = h, .x0 = box.x0, .y0 = box.y0, .coverage = coverage[0..need] };
    }

    /// Shape an Arabic run. Codepoints in, glyph ids out, in LOGICAL order --
    /// the caller reverses for display, because reversing is a property of the
    /// writing direction and not of the shaping.
    ///
    /// Each character takes one of four joining forms based on its two
    /// neighbours; the form names a GSUB feature that applies to that position
    /// and to nothing else. Then the ligature features run over the whole run.
    ///
    /// What this does NOT do: bidi (mixed-direction runs are the caller's),
    /// and contextual lookups -- `rlig` is applied but a font that puts its
    /// lam-alef behind a chaining lookup will keep the unligated pair until
    /// GSUB type 6 exists.
    pub fn shapeArabic(self: Font, cps: []const u21, out: []u16, place: ?[]opentype.Offset) GlyphError!usize {
        const n = @min(cps.len, out.len);
        // Canonical order first, on the CODEPOINTS, because it is a property of
        // the text and not of the font: two marks on one letter sort by
        // combining class before any lookup runs, which is what HarfBuzz does
        // during normalisation. Reorder the glyphs instead and the joining-form
        // loop would read a different character than the slot it applies to.
        var ordered: [max_order]u21 = undefined;
        var src: []const u21 = cps[0..n];
        if (n <= max_order) {
            @memcpy(ordered[0..n], cps[0..n]);
            arabic.canonicalOrder(ordered[0..n]);
            src = ordered[0..n];
        }
        for (src, out[0..n]) |cp, *g| g.* = self.glyphIndex(cp) catch 0;
        if (n == 0 or self.gsub_span.len == 0) return n;

        var l = opentype.Layout.init(self.data, self.gsub_span.off, self.gsub_span.len) catch return n;
        // Which ligature component each slot followed. Ligature substitution
        // fills this in and mark-to-ligature reads it back, because by then the
        // components themselves are one glyph and nothing else remembers them.
        var comps_of: [max_order]u8 = @splat(0xFF);
        l.lig = comps_of[0..];
        // Marks are transparent to matching when a lookup asks for it, which is
        // what lets lam-alef form across a fatha WITHOUT eating the fatha.
        if (self.gdef_span.len != 0) l.gdef = opentype.Gdef.init(self.data, self.gdef_span.off, self.gdef_span.len) catch null;
        const arab = opentype.tag("arab");
        var len = n;

        // Joining forms are decided from the CODEPOINTS, not the glyphs, so a
        // substitution earlier in the run cannot move a neighbour's form.
        var i: usize = 0;
        while (i < len and i < n) : (i += 1) {
            const feat = switch (arabic.formAt(src, i)) {
                .isolated => opentype.tag("isol"),
                .initial => opentype.tag("init"),
                .medial => opentype.tag("medi"),
                .final => opentype.tag("fina"),
                .none => continue,
            };
            len = l.applyFeatureAt(arab, 0, feat, out, len, i) catch len;
        }

        // ccmp runs AFTER the joining forms, not before, and that order is
        // load-bearing: ccmp merges two marks into one glyph (fatha + shadda
        // becomes uni0651.fatha), so it shortens the buffer. Deciding forms
        // afterwards indexed codepoints by glyph position and gave the last
        // letter of مُحَمَّد its isolated form.
        len = l.applyFeature(arab, 0, opentype.tag("ccmp"), out, len) catch len;
        len = l.applyFeature(arab, 0, opentype.tag("locl"), out, len) catch len;

        // `liga` is deliberately absent. DejaVu puts the Arabic PRESENTATION
        // FORMS under `liga` (uni0640 + uni064B -> uniFE71), and HarfBuzz's
        // arab shaper never enables that feature -- across 924 mark sequences
        // it forms no tatweel+mark ligature at all, though it does form the
        // mark-consuming ones in rlig (`0621 0651` -> 6017). Enabling liga
        // here fused 11 cases into glyphs nobody renders, while leaving the
        // rlig ligatures intact: they are a different feature, not a
        // different mark rule.
        for ([_]u32{ opentype.tag("rlig"), opentype.tag("calt") }) |feat| {
            len = l.applyFeature(arab, 0, feat, out, len) catch len;
        }

        // Marks are positioned after substitution, because the substitutions
        // are what turn a letter into the form the anchors are drawn for.
        if (place) |p| {
            // Substitution can SHORTEN the run, so `len` is known only here --
            // but it can also LENGTHEN it (GSUB type 2, a glyph expanding to a
            // sequence), bounded by `out.len` rather than by the codepoint
            // count. Checking against `len` at this point is therefore exact,
            // and checking earlier against `n` would not be.
            if (p.len < len) return error.BufferTooSmall;
            @memset(p[0..len], .{});
            if (self.gpos_span.len != 0) {
                if (opentype.Layout.init(self.data, self.gpos_span.off, self.gpos_span.len)) |gp_init| {
                    var gp = gp_init;
                    gp.lig = comps_of[0..];
                    _ = gp.markAttach(arab, 0, opentype.tag("mark"), out[0..len], len, p) catch 0;
                    _ = gp.markAttach(arab, 0, opentype.tag("mkmk"), out[0..len], len, p) catch 0;
                } else |_| {}
            }
        }
        return len;
    }

    /// Shape a Thai run. Thai needs no reordering: the consonants, vowels and
    /// tone marks keep their written order, which is why this is short. What it
    /// does need is the substitutions (`ccmp` composes the vowels that have
    /// precomposed forms, `liga` is the font's own preference) and the mark
    /// placement, because a tone mark left at the origin sits inside the
    /// consonant instead of above it.
    ///
    /// Canonical order runs first for the same reason as Arabic: a tone mark
    /// written before an upper vowel is stored after it, and the order decides
    /// which of them the font's anchors stack.
    ///
    /// What this does NOT do: `aalt` (an alternate, not something a run applies
    /// on its own), word breaking, or the SARA AM decomposition HarfBuzz does
    /// only for fonts that lack the precomposed glyph.
    pub fn shapeThai(self: Font, cps: []const u21, out: []u16, place: ?[]opentype.Offset) GlyphError!usize {
        const n = @min(cps.len, out.len);
        var ordered: [max_order]u21 = undefined;
        var src: []const u21 = cps[0..n];
        if (n <= max_order) {
            @memcpy(ordered[0..n], cps[0..n]);
            arabic.canonicalOrder(ordered[0..n]);
            src = ordered[0..n];
        }
        for (src, out[0..n]) |cp, *g| g.* = self.glyphIndex(cp) catch 0;
        if (n == 0) return n;
        var len = n;
        var comps_of: [max_order]u8 = @splat(0xFF);
        const thai = opentype.tag("thai");
        if (self.gsub_span.len != 0) {
            var l = opentype.Layout.init(self.data, self.gsub_span.off, self.gsub_span.len) catch return n;
            l.lig = comps_of[0..];
            if (self.gdef_span.len != 0) l.gdef = opentype.Gdef.init(self.data, self.gdef_span.off, self.gdef_span.len) catch null;
            len = l.applyFeature(thai, 0, opentype.tag("ccmp"), out, len) catch len;
            len = l.applyFeature(thai, 0, opentype.tag("liga"), out, len) catch len;
        }

        if (place) |p| {
            // Substitution can SHORTEN the run, so `len` is known only here --
            // but it can also LENGTHEN it (GSUB type 2, a glyph expanding to a
            // sequence), bounded by `out.len` rather than by the codepoint
            // count. Checking against `len` at this point is therefore exact,
            // and checking earlier against `n` would not be.
            if (p.len < len) return error.BufferTooSmall;
            @memset(p[0..len], .{});
            if (self.gpos_span.len != 0) {
                if (opentype.Layout.init(self.data, self.gpos_span.off, self.gpos_span.len)) |gp_init| {
                    var gp = gp_init;
                    gp.lig = comps_of[0..];
                    _ = gp.markAttach(thai, 0, opentype.tag("mark"), out[0..len], len, p) catch 0;
                    _ = gp.markAttach(thai, 0, opentype.tag("mkmk"), out[0..len], len, p) catch 0;
                } else |_| {}

                // Thai runs LEFT TO RIGHT, so a mark's pen sits after the base
                // it attaches to, while the anchors above are measured from the
                // base's own origin. A caller drawing at the pen would push
                // every mark right by the base's advance -- 600 units on
                // uni0E01, which is exactly the disagreement a hb comparison
                // reports as a constant offset. Convert once, here, rather than
                // making every caller subtract a distance it cannot see.
                //
                // Arabic deliberately does NOT get this: it runs right to left,
                // where the mark's pen already IS the base's origin, so the raw
                // anchor delta is already pen-relative. That asymmetry is a
                // property of the writing direction, not of the fonts.
                var advs: [max_order]i32 = @splat(0);
                for (out[0..len], 0..) |g, i| {
                    advs[i] = if (self.hMetricsResolved(g)) |m| m.advance else |_| 0;
                }
                penRelative(advs[0..len], p[0..len]);
            }
        }
        return len;
    }

    /// Which way a run runs. Positions come back pen-relative for `.ltr` and
    /// base-relative for `.rtl`, because that is what a caller drawing in each
    /// direction actually needs.
    pub const Direction = enum { ltr, rtl };

    pub const ShapeOptions = struct {
        direction: Direction = .ltr,
        /// OpenType script tag, e.g. `opentype.tag("latn")`. Zero asks GlyfZ to
        /// pick one, which means "the script that actually has these features
        /// under it" rather than a hardcoded DFLT -- DejaVu puts its real kern and
        /// liga lookups under `latn` and only a stub under DFLT.
        script: u32 = 0,
        lang: u32 = 0,
        /// Where the run's advances go, in FONT UNITS, with pair kerning
        /// already folded into the glyph it belongs to. Length `out.len`;
        /// only the first `len` entries are written.
        advances: ?[]i32 = null,
        /// Run the substitution features (`ccmp`, `locl`, `rlig`, `liga`,
        /// `clig`, `calt`). Off means glyph ids come straight from the cmap.
        ///
        /// Separate from `kern` because the two are separate promises: a
        /// caller that wants correct advances does not necessarily want `liga`
        /// rewriting "fi" into one glyph and changing the width of a button.
        /// Kerning is geometry; substitution is spelling.
        substitute: bool = true,
        /// A `Kern` resolved once and reused instead of rebuilt per call.
        ///
        /// Resolving means walking the feature list for `kern` and copying its
        /// lookup indices -- a handful of milliseconds' worth of small scans
        /// across a UI, but it happens once per string per FRAME, so it is
        /// pure repetition. `Kern.init(mem, font, .{})` builds one; storage is
        /// the caller's, as everywhere else here.
        ///
        /// A cache built from a DIFFERENT face is ignored, not trusted: its
        /// lookup indices would be applied to this face's tables, and wrong
        /// kerning is worse than slow kerning.
        kern_cache: ?*const Kern = null,
        /// Extra SUBSTITUTION features, applied after the default set and in
        /// this order: `fwid`, `hwid`, `vert`, `vrt2`, `smcp`, `onum` ...
        ///
        /// The default set is what a run needs to be SPELLED correctly. These
        /// are style choices -- half-width forms, vertical forms, small caps --
        /// so naming them is the caller's job, not a guess this function
        /// should make on their behalf. A tag with no lookups under the run's
        /// script is a no-op rather than an error: the same tag applied to a
        /// Latin face is simply not there.
        features: ?[]const u32 = null,

        /// Apply pair kerning: the `kern` feature in GPOS, falling back to the
        /// legacy `kern` table when the face has no such feature.
        ///
        /// ON by default, and that default is the point. A shaper that hands
        /// back glyph ids and leaves kerning to be re-derived by every caller
        /// is how two owners end up applying it twice, once when placing and
        /// once in the advance. Kerning is part of what shaping means.
        kern: bool = true,
    };

    pub const SubsetError = error{ BufferTooSmall, CffNotSupported, Truncated, BadValue };

    /// Write a valid single-table-directory font into `out` that carries only
    /// the outlines reachable from `gids`, and return how many bytes it took.
    ///
    /// GLYPH IDS ARE PRESERVED. A dropped glyph becomes a zero-length entry
    /// rather than being renumbered, which costs nothing in `glyf` (an empty
    /// glyph is no bytes) and means two things for free: any gid the caller
    /// already holds stays valid in the output, and composite glyphs need no
    /// rewriting, because their component indices still point at the same
    /// glyphs. Components are pulled in transitively, so a composite never
    /// references a glyph the subset dropped.
    ///
    /// Not supported: CFF faces (the charstring INDEX would have to be rebuilt)
    /// and any table other than the ones a rasteriser reads -- `cmap` is
    /// rebuilt from the kept codepoints, `glyf`/`loca` are rebuilt, and `name`,
    /// `OS/2` and `post` ride along verbatim. GPOS/GSUB and colour tables are
    /// DROPPED, so a subset is for rendering, not for shaping.
    pub fn subset(self: Font, gids: []const u16, out: []u8) SubsetError!usize {
        if (self.is_cff) return error.CffNotSupported;
        if (self.glyf.len == 0 or self.loca.len == 0 or self.num_glyphs == 0) return error.BadValue;
        const n: usize = self.num_glyphs;

        var keep_bits: [8192]u8 = @splat(0);
        const keep = keep_bits[0 .. (n + 7) / 8];
        const mark = struct {
            fn set(bits: []u8, i: usize) bool {
                const m = @as(u8, 1) << @intCast(i & 7);
                const was = bits[i >> 3] & m != 0;
                bits[i >> 3] |= m;
                return !was;
            }
            fn has(bits: []const u8, i: usize) bool {
                return bits[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) != 0;
            }
        };
        _ = mark.set(keep, 0); // .notdef always travels
        for (gids) |g| {
            if (g >= self.num_glyphs) return error.BadValue;
            _ = mark.set(keep, g);
        }

        // Pull in composite components until nothing new is reachable. A
        // composite cannot name a glyph the subset lacks, or the outline is
        // silently wrong rather than visibly broken.
        var changed = true;
        while (changed) {
            changed = false;
            var gid: usize = 0;
            while (gid < n) : (gid += 1) {
                if (!mark.has(keep, gid)) continue;
                var it = try self.componentIter(gid);
                while (try it.next()) |comp| {
                    if (comp < self.num_glyphs and mark.set(keep, comp)) changed = true;
                }
            }
        }

        // New glyf: kept outlines in place, everything else zero length.
        var glyf_len: usize = 0;
        {
            var gid: usize = 0;
            while (gid < n) : (gid += 1) {
                if (mark.has(keep, gid)) glyf_len += (try self.glyphBytes(gid)).len;
            }
        }

        // Two passes over the codepoint space: count the cmap segments, then
        // emit them. Nothing is buffered, because there is no allocator here.
        const seg_count = try self.countSegments(keep);
        const cmap_len = 12 + 14 + 8 * seg_count + 2;

        const HEAD = self.head.len;
        const HHEA = self.hhea.len;
        const MAXP = self.maxp.len;
        const HMTX = self.hmtx.len;
        const LOCA = (n + 1) * 4;
        const NAME = self.name_span.len;
        const OS2 = self.os2_span.len;
        const POST = self.post_span.len;
        const KERN = if (self.kern_ok) self.kern_span.len else 0;

        const n_tables: usize = 8 + @as(usize, if (OS2 != 0) 1 else 0) +
            @as(usize, if (POST != 0) 1 else 0) + @as(usize, if (KERN != 0) 1 else 0);
        var total: usize = 12 + 16 * n_tables;
        const off_head = total;
        total = pad4(total + HEAD);
        const off_hhea = total;
        total = pad4(total + HHEA);
        const off_maxp = total;
        total = pad4(total + MAXP);
        const off_hmtx = total;
        total = pad4(total + HMTX);
        const off_kern = total;
        total = pad4(total + KERN);
        const off_loca = total;
        total = pad4(total + LOCA);
        const off_glyf = total;
        total = pad4(total + glyf_len);
        const off_cmap = total;
        total = pad4(total + cmap_len);
        const off_name = total;
        total = pad4(total + NAME);
        const off_os2 = total;
        total = pad4(total + OS2);
        const off_post = total;
        total = pad4(total + POST);
        if (total > out.len) return error.BufferTooSmall;

        @memset(out[0..total], 0);
        var w = Out{ .b = out, .p = 0 };
        try w.u32v(0x0001_0000);
        try w.u16v(@intCast(n_tables));
        var pow: usize = 1;
        var log2: usize = 0;
        while (pow * 2 <= n_tables) : (pow *= 2) log2 += 1;
        try w.u16v(@intCast(pow * 16));
        try w.u16v(@intCast(log2));
        try w.u16v(@intCast(n_tables * 16 - pow * 16));
        const dir_at = w.p;
        w.p += 16 * n_tables;

        // head, with the loca format forced to long and the adjustment zeroed.
        @memcpy(out[off_head..][0..HEAD], self.data[self.head.off..][0..HEAD]);
        if (HEAD < 54) return error.BadValue;
        out[off_head + 8] = 0;
        out[off_head + 9] = 0;
        out[off_head + 10] = 0;
        out[off_head + 11] = 0;
        out[off_head + 50] = 0;
        out[off_head + 51] = 1; // indexToLocFormat = long
        @memcpy(out[off_hhea..][0..HHEA], self.data[self.hhea.off..][0..HHEA]);
        @memcpy(out[off_maxp..][0..MAXP], self.data[self.maxp.off..][0..MAXP]);
        @memcpy(out[off_hmtx..][0..HMTX], self.data[self.hmtx.off..][0..HMTX]);
        @memcpy(out[off_name..][0..NAME], self.data[self.name_span.off..][0..NAME]);
        if (KERN != 0) @memcpy(out[off_kern..][0..KERN], self.data[self.kern_span.off..][0..KERN]);
        if (OS2 != 0) @memcpy(out[off_os2..][0..OS2], self.data[self.os2_span.off..][0..OS2]);
        if (POST != 0) @memcpy(out[off_post..][0..POST], self.data[self.post_span.off..][0..POST]);

        // glyf + loca
        var at: u32 = 0;
        var gid: usize = 0;
        while (gid < n) : (gid += 1) {
            w.p = off_loca + gid * 4;
            try w.u32v(at);
            if (mark.has(keep, gid)) {
                const g = try self.glyphBytes(gid);
                @memcpy(out[off_glyf + at ..][0..g.len], g);
                at += @intCast(g.len);
            }
        }
        w.p = off_loca + n * 4;
        try w.u32v(at);

        // cmap: format 4, one segment per run of consecutive code -> glyph.
        w.p = off_cmap;
        try w.u16v(0);
        try w.u16v(1);
        try w.u16v(3);
        try w.u16v(1);
        try w.u32v(12);
        try w.u16v(4);
        try w.u16v(@intCast(cmap_len - 12));
        try w.u16v(0);
        try w.u16v(@intCast(seg_count * 2));
        var sr: usize = 1;
        var es: usize = 0;
        while (sr * 2 <= seg_count) : (sr *= 2) es += 1;
        try w.u16v(@intCast(sr * 2));
        try w.u16v(@intCast(es));
        try w.u16v(@intCast(seg_count * 2 - sr * 2));
        const end_at = w.p;
        w.p += seg_count * 2;
        const pad_at = w.p;
        w.p += 2;
        const start_at = w.p;
        w.p += seg_count * 2;
        const delta_at = w.p;
        w.p += seg_count * 2;
        w.p += seg_count * 2; // idRangeOffset, all zero: idDelta does the work
        try self.emitSegments(out, keep, end_at, start_at, delta_at, seg_count);
        out[pad_at] = 0;
        out[pad_at + 1] = 0;

        // Directory records must be in ascending tag order, and every table
        // physically written must have one: FreeType binary searches this
        // table, so an unsorted directory loses tables that are present.
        const DirRec = struct { tag: u32, off: usize, len: usize };
        var recs: [11]DirRec = undefined;
        var t: usize = 0;
        if (OS2 != 0) {
            recs[t] = .{ .tag = tag("OS/2"), .off = off_os2, .len = OS2 };
            t += 1;
        }
        recs[t] = .{ .tag = tag("cmap"), .off = off_cmap, .len = cmap_len };
        t += 1;
        recs[t] = .{ .tag = tag("glyf"), .off = off_glyf, .len = glyf_len };
        t += 1;
        recs[t] = .{ .tag = tag("head"), .off = off_head, .len = HEAD };
        t += 1;
        recs[t] = .{ .tag = tag("hhea"), .off = off_hhea, .len = HHEA };
        t += 1;
        recs[t] = .{ .tag = tag("hmtx"), .off = off_hmtx, .len = HMTX };
        t += 1;
        if (KERN != 0) {
            recs[t] = .{ .tag = tag("kern"), .off = off_kern, .len = KERN };
            t += 1;
        }
        recs[t] = .{ .tag = tag("loca"), .off = off_loca, .len = LOCA };
        t += 1;
        recs[t] = .{ .tag = tag("maxp"), .off = off_maxp, .len = MAXP };
        t += 1;
        recs[t] = .{ .tag = tag("name"), .off = off_name, .len = NAME };
        t += 1;
        if (POST != 0) {
            recs[t] = .{ .tag = tag("post"), .off = off_post, .len = POST };
            t += 1;
        }
        if (t != n_tables) return error.BadValue;
        var d: usize = 0;
        while (d < t) : (d += 1) {
            const rec = recs[d];
            const slot = dir_at + d * 16;
            writeU32(out, slot, rec.tag);
            writeU32(out, slot + 4, checksum(out[rec.off..][0..pad4(rec.len)]));
            writeU32(out, slot + 8, @intCast(rec.off));
            writeU32(out, slot + 12, @intCast(rec.len));
        }

        // head.checkSumAdjustment: 0xB1B0AFBA minus the whole-file sum.
        const sum = checksum(out[0..total]);
        const adj = 0xB1B0_AFBA -% sum;
        writeU32(out, off_head + 8, adj);

        return total;
    }

    const Out = struct {
        b: []u8,
        p: usize = 0,
        fn u16v(self: *Out, v: u32) SubsetError!void {
            if (self.p + 2 > self.b.len) return error.BufferTooSmall;
            writeU16(self.b, self.p, @intCast(v));
            self.p += 2;
        }
        fn u32v(self: *Out, v: u32) SubsetError!void {
            if (self.p + 4 > self.b.len) return error.BufferTooSmall;
            writeU32(self.b, self.p, v);
            self.p += 4;
        }
    };

    fn pad4(v: usize) usize {
        return (v + 3) & ~@as(usize, 3);
    }

    fn writeU16(b: []u8, at: usize, v: u16) void {
        b[at] = @intCast(v >> 8);
        b[at + 1] = @truncate(v);
    }

    fn writeU32(b: []u8, at: usize, v: u32) void {
        b[at] = @intCast(v >> 24);
        b[at + 1] = @truncate(v >> 16);
        b[at + 2] = @truncate(v >> 8);
        b[at + 3] = @truncate(v);
    }

    fn checksum(b: []const u8) u32 {
        var sum: u32 = 0;
        var i: usize = 0;
        while (i + 4 <= b.len) : (i += 4) {
            sum +%= (@as(u32, b[i]) << 24) | (@as(u32, b[i + 1]) << 16) |
                (@as(u32, b[i + 2]) << 8) | @as(u32, b[i + 3]);
        }
        if (i < b.len) {
            var last: u32 = 0;
            var k: usize = 0;
            while (i + k < b.len) : (k += 1) last |= @as(u32, b[i + k]) << @intCast(24 - 8 * k);
            sum +%= last;
        }
        return sum;
    }

    fn locaOff(self: Font, gid: usize) SubsetError!u32 {
        if (gid > self.num_glyphs) return error.BadValue;
        if (self.index_to_loc == 0) {
            return @as(u32, try u16At(self.data, self.loca.off + gid * 2)) * 2;
        }
        return try u32At(self.data, self.loca.off + gid * 4);
    }

    fn glyphBytes(self: Font, gid: usize) SubsetError![]const u8 {
        const a = try self.locaOff(gid);
        const b = try self.locaOff(gid + 1);
        if (b < a) return error.BadValue;
        const end = self.glyf.off + b;
        if (end > self.data.len) return error.Truncated;
        return self.data[self.glyf.off + a .. end];
    }

    /// Walk a composite's component glyph ids. A simple glyph yields nothing.
    fn componentIter(self: Font, gid: usize) SubsetError!CompIter {
        const g = try self.glyphBytes(gid);
        if (g.len < 10) return .{ .g = g, .p = g.len };
        const contours = try i16At(g, 0);
        if (contours >= 0) return .{ .g = g, .p = g.len };
        return .{ .g = g, .p = 10 };
    }

    const CompIter = struct {
        g: []const u8,
        p: usize,
        more: bool = true,
        fn next(self: *CompIter) SubsetError!?u16 {
            if (!self.more or self.p + 4 > self.g.len) return null;
            const flags = try u16At(self.g, self.p);
            const comp = try u16At(self.g, self.p + 2);
            var adv: usize = 4;
            adv += if (flags & 0x0001 != 0) 4 else 2; // ARG_1_AND_2_ARE_WORDS
            if (flags & 0x0008 != 0) adv += 2 // WE_HAVE_A_SCALE
            else if (flags & 0x0040 != 0) adv += 4 // X_AND_Y_SCALE
            else if (flags & 0x0080 != 0) adv += 8; // TWO_BY_TWO
            self.p += adv;
            self.more = flags & 0x0020 != 0; // MORE_COMPONENTS
            return comp;
        }
    };

    fn keptGid(self: Font, keep: []const u8, cp: u32) u16 {
        if (cp > 0xFFFF) return 0;
        const g = self.glyphIndex(@intCast(cp)) catch return 0;
        if (g == 0 or g >= self.num_glyphs) return 0;
        const i: usize = g;
        if (keep[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) == 0) return 0;
        return g;
    }

    fn countSegments(self: Font, keep: []const u8) SubsetError!usize {
        var segs: usize = 1; // the terminator
        var cp: u32 = 0;
        var prev_gid: u16 = 0;
        var run_open = false;
        while (cp <= 0xFFFF) : (cp += 1) {
            const g = self.keptGid(keep, cp);
            if (g == 0) {
                run_open = false;
                continue;
            }
            if (!run_open or runBroken(prev_gid, g)) segs += 1;
            run_open = true;
            prev_gid = g;
        }
        return segs;
    }

    fn runBroken(prev: u16, next: u16) bool {
        return @as(u32, prev) + 1 != @as(u32, next);
    }

    fn emitSegments(self: Font, out: []u8, keep: []const u8, end_at: usize, start_at: usize, delta_at: usize, expect: usize) SubsetError!void {
        var seg: usize = 0;
        var cp: u32 = 0;
        var prev_gid: u16 = 0;
        var run_open = false;
        var run_start: u32 = 0;
        var run_gid: u16 = 0;
        while (cp <= 0xFFFF) : (cp += 1) {
            const g = self.keptGid(keep, cp);
            if (g == 0) {
                if (run_open) {
                    writeU16(out, end_at + seg * 2, @intCast(cp - 1));
                    writeU16(out, start_at + seg * 2, @intCast(run_start));
                    writeU16(out, delta_at + seg * 2, @truncate(@as(u32, run_gid) -% run_start));
                    seg += 1;
                    run_open = false;
                }
                continue;
            }
            if (!run_open) {
                run_open = true;
                run_start = cp;
                run_gid = g;
            } else if (runBroken(prev_gid, g)) {
                writeU16(out, end_at + seg * 2, @intCast(cp - 1));
                writeU16(out, start_at + seg * 2, @intCast(run_start));
                writeU16(out, delta_at + seg * 2, @truncate(@as(u32, run_gid) -% run_start));
                seg += 1;
                run_start = cp;
                run_gid = g;
            }
            prev_gid = g;
        }
        if (run_open) {
            writeU16(out, end_at + seg * 2, 0xFFFF);
            writeU16(out, start_at + seg * 2, @intCast(run_start));
            writeU16(out, delta_at + seg * 2, @truncate(@as(u32, run_gid) -% run_start));
            seg += 1;
        }
        // Terminator segment: 0xFFFF maps to gid 0.
        writeU16(out, end_at + seg * 2, 0xFFFF);
        writeU16(out, start_at + seg * 2, 0xFFFF);
        writeU16(out, delta_at + seg * 2, 1);
        seg += 1;
        // The counting walk and the emitting walk are separate loops over the
        // same predicate. One segment's disagreement writes a cmap whose
        // segCountX2 is wrong -- corrupt and silent. Refuse instead.
        if (seg != expect) return error.BadValue;
    }

    /// Convert base-relative mark offsets into pen-relative ones.
    ///
    /// A mark's anchor offset is measured from the origin of the base it attaches
    /// to, but a caller draws at the pen, and in a left-to-right script the pen has
    /// already moved past that base by its advance. Subtracting that distance is
    /// what makes `draw(pen + place)` land the mark on its base -- without it every
    /// mark drifts right by the base's advance (600 units on Thai uni0E01).
    ///
    /// A glyph whose advance is zero is a mark; the last glyph with a real advance
    /// is the base it belongs to. A mark with no recorded offset is left alone,
    /// because a zero there means "no anchor", not "place at the base's origin".
    fn penRelative(advances: []const i32, place: []opentype.Offset) void {
        var pen: i32 = 0;
        var base_pen: i32 = 0;
        for (advances, 0..) |adv, i| {
            if (adv == 0) {
                if (place[i].x != 0 or place[i].y != 0) {
                    const corr: i32 = @as(i32, place[i].x) - (pen - base_pen);
                    const lo: i32 = std.math.minInt(i16);
                    const hi: i32 = std.math.maxInt(i16);
                    place[i].x = @intCast(std.math.clamp(corr, lo, hi));
                }
            } else {
                base_pen = pen;
            }
            pen += adv;
        }
    }

    /// Shape a run of codepoints into glyph ids with no assumption about the
    /// script beyond the default OpenType feature set: `ccmp`, `locl`, `rlig`,
    /// `liga`, `clig`, `calt`, then `mark`/`mkmk` positioning.
    ///
    /// This is the entry point for text that needs no script-specific machine.
    /// Arabic and Thai keep their own functions, because joining forms and
    /// positional features are not expressible as a list of features.
    ///
    /// Kerning IS applied, because it belongs to shaping: `ShapeOptions.kern`
    /// is on by default and the result lands in the advance of the glyph the
    /// pair starts with. Pass `ShapeOptions.advances` to receive them; the pen
    /// for glyph i is the running sum, so a caller that also adds its own
    /// kerning would be applying it twice.
    pub fn shape(
        self: Font,
        cps: []const u21,
        out: []u16,
        place: ?[]opentype.Offset,
        opts: ShapeOptions,
    ) GlyphError!usize {
        const n = @min(cps.len, out.len);
        var ordered: [max_order]u21 = undefined;
        var src: []const u21 = cps[0..n];
        if (n <= max_order) {
            @memcpy(ordered[0..n], cps[0..n]);
            arabic.canonicalOrder(ordered[0..n]);
            src = ordered[0..n];
        }
        for (src, out[0..n]) |cp, *g| g.* = self.glyphIndex(cp) catch 0;
        if (n == 0) return n;

        var len = n;
        var comps_of: [max_order]u8 = @splat(0xFF);
        const script = if (opts.script != 0) opts.script else self.scriptOf(src[0..n]);
        if (self.gsub_span.len != 0 and opts.substitute) {
            var l = opentype.Layout.init(self.data, self.gsub_span.off, self.gsub_span.len) catch return n;
            // Fixed-size scratch: a longer run loses component tracking rather
            // than indexing past the end. Substitution itself is unaffected.
            if (n <= max_order) l.lig = comps_of[0..];
            if (self.gdef_span.len != 0) l.gdef = opentype.Gdef.init(self.data, self.gdef_span.off, self.gdef_span.len) catch null;
            // Order is hb's default feature order, and it matters: ccmp
            // rewrites the buffer (and can shorten it), so everything after it
            // sees the glyphs it produced.
            for ([_]u32{
                opentype.tag("ccmp"), opentype.tag("locl"), opentype.tag("rlig"),
                opentype.tag("liga"), opentype.tag("clig"), opentype.tag("calt"),
            }) |feat| {
                len = l.applyFeature(script, opts.lang, feat, out, len) catch len;
            }
            // Caller-named features come after, so they see the run the
            // default set produced -- `vert` on a glyph `locl` just swapped in
            // is the case that matters for CJK.
            if (opts.features) |extra| for (extra) |feat| {
                len = l.applyFeature(script, opts.lang, feat, out, len) catch len;
            };
        }

        if (place) |p| {
            // Substitution can SHORTEN the run, so `len` is known only here --
            // but it can also LENGTHEN it (GSUB type 2, a glyph expanding to a
            // sequence), bounded by `out.len` rather than by the codepoint
            // count. Checking against `len` at this point is therefore exact,
            // and checking earlier against `n` would not be.
            if (p.len < len) return error.BufferTooSmall;
            @memset(p[0..len], .{});
            if (self.gpos_span.len != 0) {
                if (opentype.Layout.init(self.data, self.gpos_span.off, self.gpos_span.len)) |gp_init| {
                    var gp = gp_init;
                    gp.lig = comps_of[0..];
                    _ = gp.markAttach(script, opts.lang, opentype.tag("mark"), out[0..len], len, p) catch 0;
                    _ = gp.markAttach(script, opts.lang, opentype.tag("mkmk"), out[0..len], len, p) catch 0;
                } else |_| {}
            }
        }

        // One advance pass, kerning included. Windowed because both scratches
        // are fixed size: a mark attaches to a base nearby, so a window gives
        // the same answer as the whole run except at a seam.
        var kern_buf: [kern_lookups]u16 = undefined;
        var own_kern: Kern = .{ .font = self };
        var kp: *const Kern = &own_kern;
        if (opts.kern) {
            if (opts.kern_cache) |kc| {
                if (kc.font.data.ptr == self.data.ptr) kp = kc else own_kern = Kern.initSlice(self, kern_buf[0..]);
            } else {
                own_kern = Kern.initSlice(self, kern_buf[0..]);
            }
        }
        var advs: [max_order]i32 = @splat(0);
        var off: usize = 0;
        if (opts.advances) |a| {
            if (a.len < len) return error.BufferTooSmall;
        }
        while (off < len) {
            const cnt = @min(max_order, len - off);
            self.runAdvances(out[off..][0..cnt], advs[0..cnt], kp);
            if (opts.advances) |a| @memcpy(a[off..][0..cnt], advs[0..cnt]);
            if (place) |p| {
                if (opts.direction == .ltr) penRelative(advs[0..cnt], p[off..][0..cnt]);
            }
            off += cnt;
        }
        return len;
    }

    /// How many lookup indices `shape` will track for the `kern` feature.
    const kern_lookups = 32;

    /// Advances for one window of glyphs, with pair kerning folded in.
    ///
    /// Pairs are ADJACENT, marks included, because lookup flags are not
    /// modelled here and `pairAdjust` does not model them either -- a `kern`
    /// lookup may carry IgnoreMarks or USE_MARK_FILTERING_SET and Inter's
    /// feature carries both kinds at once, so skipping marks at this level
    /// would answer for a flag we never read and put `shape` out of step with
    /// the pair adjustment it is built on. What this does match is the font's
    /// pair tables, which is what a differential against fontTools can grade.
    fn runAdvances(self: Font, gids: []const u16, advs: []i32, kp: *const Kern) void {
        // `hMetricsResolved` walks `glyf` to honour USE_MY_METRICS, so a CFF
        // face has no answer there. The raw `hmtx` read still does, and a
        // plain advance is what a run needs; only composites care about the
        // flag, and they are not in a CFF face.
        for (gids, advs) |g, *a| {
            a.* = blk: {
                if (self.hMetricsResolved(g)) |m| break :blk @as(i32, m.advance) else |_| {}
                if (self.hMetrics(g)) |m| break :blk @as(i32, m.advance) else |_| {}
                break :blk 0;
            };
        }
        if (kp.status == .none) return;
        for (gids[0..gids.len -| 1], 0..) |g, i| {
            advs[i] += kp.adjust(g, gids[i + 1]).x_advance;
        }
    }

    /// The script of the TEXT, for choosing features.
    ///
    /// `pickScript` answers from the FONT -- does it carry `liga` or `ccmp
    /// under `latn`? -- which is why a face with both Latin and CJK always
    /// reported `latn` and nothing under `hani` or `kana` was ever reachable.
    /// Shaping needs the script of the characters. First character that has a
    /// script of its own wins, as in HarfBuzz: space, digits and punctuation
    /// are Common and decide nothing about what the text is.
    ///
    /// Choosing a script that the face does not carry costs nothing, because
    /// `lookupsFor` falls back to the default script when a lookup list comes
    /// back empty.
    fn scriptOf(self: Font, cps: []const u21) u32 {
        for (cps) |cp| {
            if (scriptOfCodepoint(cp)) |s| return s;
        }
        // Nothing but Common characters, or nothing at all: the font's own
        // answer is the honest one.
        return self.pickScript();
    }

    /// The script to use when the caller did not name one and the text decides
    /// nothing (nothing but Common characters, or an empty run): whichever of
    /// `latn` and `DFLT` actually carries the features this shaper applies.
    ///
    /// This answers from the FONT, not the text, so it is only the fallback --
    /// `scriptOf` asks it last. On a face carrying both Latin and CJK this
    /// always says `latn`, which is why it cannot be the primary answer.
    fn pickScript(self: Font) u32 {
        const latn = opentype.tag("latn");
        const dflt = opentype.tag("DFLT");
        inline for (.{ latn, dflt }) |cand| {
            if (self.hasGsubFeature(cand, 0, opentype.tag("liga")) or
                self.hasGsubFeature(cand, 0, opentype.tag("ccmp"))) return cand;
        }
        return dflt;
    }

    /// Script by Unicode block, for the ranges whose features a run keys off.
    ///
    /// `null` means Common or Inherited: that character says nothing about what
    /// the run is, so the next one is asked. Arabic and Thai are deliberately not
    /// here -- `shapeArabic` and `shapeThai` own those and carry their own feature
    /// lists, so this table only has to cover what `shape` itself decides.
    pub fn scriptOfCodepoint(cp: u21) ?u32 {
        return switch (cp) {
            // Han: radicals, extension A, the main block, compatibility ideographs
            // and the supplementary planes, which are the same script.
            0x2E80...0x2EFF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F => opentype.tag("hani"),
            // Kana: hiragana, katakana, the katakana phonetic extensions, and the
            // halfwidth forms.
            0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F => opentype.tag("kana"),
            // Hangul: jamo, compatibility jamo, and the precomposed syllables.
            0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF => opentype.tag("hang"),
            // Latin, which is what a letter run falls back to today.
            0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF => opentype.tag("latn"),
            else => null,
        };
    }

    test "a codepoint's script is decided by its block, and Common decides nothing" {
        // Each CJK script is its own, because their features differ.
        try std.testing.expectEqual(opentype.tag("hani"), Font.scriptOfCodepoint(0x4E2D).?);
        try std.testing.expectEqual(opentype.tag("kana"), Font.scriptOfCodepoint(0x3042).?);
        try std.testing.expectEqual(opentype.tag("hang"), Font.scriptOfCodepoint(0xAC00).?);
        try std.testing.expectEqual(opentype.tag("latn"), Font.scriptOfCodepoint('A').?);

        // Space, digits and punctuation are Common: they must not get a vote, or
        // a leading space would outvote the text it introduces.
        try std.testing.expectEqual(@as(?u32, null), Font.scriptOfCodepoint(' '));
        try std.testing.expectEqual(@as(?u32, null), Font.scriptOfCodepoint('7'));
        try std.testing.expectEqual(@as(?u32, null), Font.scriptOfCodepoint(','));

        // Supplementary-plane ideographs are Han, not an unknown block.
        try std.testing.expectEqual(opentype.tag("hani"), Font.scriptOfCodepoint(0x20000).?);

        // Arabic and Thai are absent on purpose: shapeArabic and shapeThai own
        // them, so shape() must not start claiming them here.
        try std.testing.expectEqual(@as(?u32, null), Font.scriptOfCodepoint(0x0645));
    }

    test "a run of Common characters falls back to the font, not to nothing" {
        var buf: [8192]u8 = undefined;
        const f = try Font.init(buildTestFont(&buf, false));

        // Hanzi decide the run even behind a space.
        try std.testing.expectEqual(
            opentype.tag("hani"),
            f.scriptOf(&[_]u21{ ' ', 0x4E2D }),
        );
        // Nothing but Common: whatever the face itself offers.
        try std.testing.expectEqual(f.pickScript(), f.scriptOf(&[_]u21{ ' ', '1' }));
        // Empty is the same case, and must not read past the slice.
        try std.testing.expectEqual(f.pickScript(), f.scriptOf(&[_]u21{}));
    }

    /// GPOS single adjustments over a shaped run: `palt` and `halt` live here.
    ///
    /// `gids` are the glyphs `shape` produced, NOT codepoints. GPOS runs after
    /// substitution and indexes coverage by glyph, so handing this codepoints
    /// would adjust the wrong glyphs on any face that substitutes.
    ///
    /// Features add rather than overwrite, so `&.{ palt, halt }` composes.
    /// A malformed GPOS adjusts nothing instead of failing, matching how
    /// `shape` treats a feature it cannot apply.
    ///
    /// The script defaults to latn, sufficient for a face whose features sit
    /// under DFLT because `lookupsFor` falls back there. A CJK face keeping `palt` under
    /// `hani` or `kana` needs `opts.script` named.
    pub fn adjustAdvances(self: Font, gids: []const u16, out: []opentype.Adjust, feats: []const u32, opts: ShapeOptions) usize {
        // Zeroed even when there is nothing to apply: a caller reusing the
        // buffer would otherwise apply the previous run's values.
        @memset(out[0..gids.len], .{});
        if (gids.len == 0 or self.gpos_span.len == 0) return 0;
        var l = opentype.Layout.init(self.data, self.gpos_span.off, self.gpos_span.len) catch return 0;
        const script = if (opts.script != 0) opts.script else opentype.tag("latn");
        var touched: usize = 0;
        for (feats) |f| touched += l.adjustSingles(script, opts.lang, f, gids, gids.len, out) catch 0;
        return touched;
    }

    /// Does the file carry this table at all? Answers about the DIRECTORY, so
    /// no parse of the table itself happens.
    /// How many variation axes the face declares. A static face has none.
    pub fn axisCount(self: Font) u16 {
        if (self.fvar_span.len == 0) return 0;
        return variations.axisCount(self.fvar_slice()) catch 0;
    }

    pub fn axisInfo(self: Font, i: usize) ?variations.Axis {
        if (self.fvar_span.len == 0) return null;
        return variations.axis(self.fvar_slice(), i) catch null;
    }

    /// Return a copy of this face pinned to a point in its design space.
    ///
    /// `user` is in axis order and in USER units (a `wght` of 700, not a
    /// normalised coordinate); it is normalised here, through `avar` when the
    /// face has one. Extra values are ignored and missing ones stay at the
    /// default, so varying one axis of a two-axis face is legal.
    pub fn withCoords(self: Font, user: []const f32) Font {
        var f = self;
        f.n_coords = 0;
        if (self.fvar_span.len == 0) return f;
        const count = variations.axisCount(self.fvar_slice()) catch return f;
        const avar: []const u8 = if (self.avar_span.len != 0)
            self.data[self.avar_span.off..][0..self.avar_span.len]
        else
            &.{};
        const n = @min(@min(user.len, variations.max_axes), @as(usize, count));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = variations.axis(self.fvar_slice(), i) catch break;
            f.coords[i] = variations.normalizeAxis(a, user[i], avar, i);
        }
        f.n_coords = @intCast(i);
        while (i < variations.max_axes) : (i += 1) f.coords[i] = 0;
        return f;
    }

    /// A small id for the current instance, for use in a cache key.
    ///
    /// Two Fonts over the same bytes at different coordinates produce
    /// different masks, so a cache that ignored this would serve the wrong
    /// glyph forever. It is a hash rather than an index because there is no
    /// registry to hand out indices.
    pub fn variationId(self: *const Font) u32 {
        var h: u32 = 0;
        for (self.coords[0..self.n_coords]) |c| {
            h = (h *% 0x9E3779B1) ^ @as(u32, @bitCast(c));
        }
        return h;
    }

    fn fvar_slice(self: Font) []const u8 {
        return self.data[self.fvar_span.off..][0..self.fvar_span.len];
    }

    /// Apply this instance's gvar deltas to a decoded outline, in place.
    ///
    /// Simple glyphs only. A composite's point numbers are its component
    /// records and its deltas move those offsets, which
    /// applies before the component's transform.
    /// `contour_ends` arrives as ABSOLUTE indices into the caller's flattened
    /// point buffer; `base` is where this glyph's points start. gvar's intervals
    /// are glyph-local, so rebase before handing them to the variation engine --
    /// without this a component varies against its parent's point numbering.
    fn varyOutline(self: Font, gid: u16, base: usize, pts: []Point, contour_ends: []const u16) void {
        if (self.n_coords == 0 or self.gvar_span.len == 0 or pts.len == 0) return;
        if (pts.len > variations.max_points) return;
        if (contour_ends.len > variations.max_points) return;

        var rel_ends: [variations.max_points]u16 = undefined;
        for (contour_ends, 0..) |e, i| {
            const abs: usize = e;
            if (abs < base) return;
            rel_ends[i] = @intCast(abs - base);
        }
        const ends = rel_ends[0..contour_ends.len];

        var xs: [variations.max_points]f32 = undefined;
        var ys: [variations.max_points]f32 = undefined;
        var dx: [variations.max_points]f32 = @splat(0);
        var dy: [variations.max_points]f32 = @splat(0);
        var tx: [variations.max_points]f32 = @splat(0);
        var ty: [variations.max_points]f32 = @splat(0);
        var touched: [variations.max_points]bool = @splat(false);
        var idx: [variations.max_points]u16 = undefined;
        for (pts, 0..) |p, i| {
            xs[i] = @floatFromInt(p.x);
            ys[i] = @floatFromInt(p.y);
        }
        const n = pts.len;
        const any = variations.applyGlyph(
            self.data[self.gvar_span.off..][0..self.gvar_span.len],
            self.coords[0..self.n_coords],
            gid,
            n,
            ends,
            xs[0..n],
            ys[0..n],
            dx[0..n],
            dy[0..n],
            touched[0..n],
            idx[0..n],
            tx[0..n],
            ty[0..n],
        ) catch return;
        if (!any) return;
        for (pts, 0..) |*p, i| {
            p.x += otRound(dx[i]);
            p.y += otRound(dy[i]);
        }
    }

    pub fn hasTable(self: Font, wanted: u32) bool {
        if (self.data.len < 12) return false;
        // A collection has no directory at offset 0: those bytes are 'ttcf' and
        // offset 4 is the face count, so numTables read from there answers about
        // nothing. Follow the first face's directory offset instead.
        var dir: usize = 0;
        if (self.data[0] == 't' and self.data[1] == 't' and self.data[2] == 'c' and self.data[3] == 'f') {
            if (self.data.len < 16) return false;
            dir = (@as(usize, self.data[12]) << 24) | (@as(usize, self.data[13]) << 16) |
                (@as(usize, self.data[14]) << 8) | self.data[15];
        }
        if (dir + 12 > self.data.len) return false;
        const n = (@as(usize, self.data[dir + 4]) << 8) | self.data[dir + 5];
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = dir + 12 + i * 16;
            if (rec + 16 > self.data.len) return false;
            const t = (@as(u32, self.data[rec]) << 24) | (@as(u32, self.data[rec + 1]) << 16) |
                (@as(u32, self.data[rec + 2]) << 8) | @as(u32, self.data[rec + 3]);
            if (t == wanted) return true;
        }
        return false;
    }

    /// Any kerning at all: a usable legacy `kern` table, or a `kern` feature in
    /// GPOS. The two are different tables and a caller cannot otherwise tell
    /// "this font does not kern" from "the kerning lives somewhere I did not
    /// look".
    pub fn hasKerning(self: Font) bool {
        if (self.kern_ok) return true;
        return self.hasGposFeature(0, 0, opentype.tag("kern"));
    }

    /// Is `feat` available for `script` (0 = pick one) in GPOS?
    pub fn hasGposFeature(self: Font, script: u32, lang: u32, feat: u32) bool {
        return self.hasFeatureIn(self.gpos_span, script, lang, feat);
    }

    /// Is `feat` available for `script` (0 = pick one) in GSUB?
    pub fn hasGsubFeature(self: Font, script: u32, lang: u32, feat: u32) bool {
        return self.hasFeatureIn(self.gsub_span, script, lang, feat);
    }

    fn hasFeatureIn(self: Font, span: Span, script: u32, lang: u32, feat: u32) bool {
        if (span.len == 0) return false;
        var l = opentype.Layout.init(self.data, span.off, span.len) catch return false;
        var ids: [32]u16 = undefined;
        if (script == 0) {
            const got = l.featureLookupsDefault(feat, &ids) catch return false;
            return got.len != 0;
        }
        const got = l.featureLookups(script, lang, feat, &ids) catch return false;
        return got.len != 0;
    }

    test "a left-to-right mark ends up pen-relative, not base-relative" {
        const advs = [_]i32{ 600, 0 };
        var place = [_]opentype.Offset{ .{}, .{ .x = 598 } };
        penRelative(&advs, &place);
        try std.testing.expectEqual(@as(i16, 0), place[0].x);
        try std.testing.expectEqual(@as(i16, -2), place[1].x);

        // two marks after one base both measure from that base, not from each other
        const advs2 = [_]i32{ 600, 0, 0 };
        var place2 = [_]opentype.Offset{ .{}, .{ .x = 598 }, .{ .x = 598 } };
        penRelative(&advs2, &place2);
        try std.testing.expectEqual(@as(i16, -2), place2[1].x);
        try std.testing.expectEqual(@as(i16, -2), place2[2].x);

        // a mark with no anchor recorded stays untouched
        const advs3 = [_]i32{ 500, 0 };
        var place3 = [_]opentype.Offset{ .{}, .{} };
        penRelative(&advs3, &place3);
        try std.testing.expectEqual(@as(i16, 0), place3[1].x);

        // and a shift larger than i16 saturates instead of wrapping
        const advs4 = [_]i32{ 70000, 0 };
        var place4 = [_]opentype.Offset{ .{}, .{ .x = 10 } };
        penRelative(&advs4, &place4);
        try std.testing.expectEqual(std.math.minInt(i16), place4[1].x);
    }

    /// The colour layers of a glyph, written into `out`.
    ///
    /// Null means "draw this as a normal glyph": the face has no colour table,
    /// or this glyph is not coloured. A caller must treat null as the ordinary
    /// path rather than as an error, because in every real emoji font most of
    /// the face is still monochrome.
    pub fn colorLayers(self: Font, gid: u16, out: []colr.Layer) ?[]colr.Layer {
        const tbl = self.slice(self.colr_span) catch return null;
        const c = colr.Colr.init(tbl) orelse return null;
        return c.layers(gid, out);
    }

    /// Whether the face carries colour glyphs at all, which is what a caller
    /// needs to know before deciding to ask per glyph.
    pub fn hasColor(self: Font) bool {
        const tbl = self.slice(self.colr_span) catch return false;
        const c = colr.Colr.init(tbl) orelse return false;
        return c.any();
    }

    /// One palette entry. Null when the face has no CPAL table, or when that
    /// palette or entry does not exist -- a layer naming an entry the palette
    /// does not have is a font bug, and the caller decides what to draw instead
    /// rather than this inventing a colour.
    pub fn paletteColor(self: Font, palette: u16, index: u16) ?colr.Rgba {
        const tbl = self.slice(self.cpal_span) catch return null;
        const p = colr.Cpal.init(tbl) orelse return null;
        return p.color(palette, index);
    }

    /// Horizontal metrics for a glyph, straight out of `hmtx`. Ids past
    /// `numberOfHMetrics` repeat the last advance and read their bearing from
    /// the trailing array -- that is the format, not a shortcut.
    ///
    /// This is the RAW read and it does not consult `USE_MY_METRICS`: answering
    /// that means reading the glyph's own `glyf` header and walking its
    /// component records, which is real per-call work on a path a draw loop
    /// enters once per glyph. Use `hMetricsResolved` where the flag matters, or
    /// `Lookup`, which resolves each codepoint once and caches the answer.
    pub fn hMetrics(self: Font, gid: u16) GlyphError!HMetrics {
        if (gid >= self.num_glyphs) return error.UnknownGlyph;
        return self.hMetricsFromTable(gid);
    }

    /// Horizontal metrics with `USE_MY_METRICS` honoured: a composite that
    /// flags one component reports that component's metrics, which is what the
    /// flag is for -- the accented letter measures like the letter. Chains
    /// through nested composites and stops at the same depth bound the outline
    /// decoder uses.
    pub fn hMetricsResolved(self: Font, gid: u16) GlyphError!HMetrics {
        return self.hMetricsDepth(gid, 0);
    }

    fn hMetricsDepth(self: Font, gid: u16, depth: u32) GlyphError!HMetrics {
        if (gid >= self.num_glyphs) return error.UnknownGlyph;
        // A component can point back at the composite, so the chain needs the
        // same depth bound the outline decoder has. Past the bound the walk
        // stops and the glyph answers from its own hmtx rather than erroring:
        // metrics are what layout needs, and refusing them would lose a whole
        // line of text to a font's bad component record. The outline decoder is
        // where a looping composite actually gets refused.
        if (depth < max_composite_depth) {
            if (try self.metricSource(gid)) |src| return self.hMetricsDepth(src, depth + 1);
        }
        return self.hMetricsFromTable(gid);
    }

    /// The `hmtx` read itself, with no flag resolution above it.
    fn hMetricsFromTable(self: Font, gid: u16) GlyphError!HMetrics {
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

    /// The component a composite takes its metrics from, if it flags one.
    ///
    /// This walks the component records only far enough to answer that, so the
    /// record layout is known in two places: here and in `decodeComposite`.
    /// That duplication is deliberate. The decoder is byte-exact against the
    /// reference rasteriser and is not worth restructuring for a flag lookup;
    /// the two would also have to agree on the transform keywords, which is
    /// where a subtle divergence would hide. What they MUST agree on is record
    /// length, and that is four flag bits adding 0, 2, 4 or 8 bytes.
    inline fn metricSource(self: Font, gid: u16) GlyphError!?u16 {
        // A CFF face has no composite records to resolve. Its `seac` form builds
        // an accented glyph out of the standard encoding, and the advance is
        // still the face's own `hmtx` entry, so there is no flag to honour.
        // Without this the `glyphRange` below fails on a face that has no
        // `glyf`/`loca` at all, which made `hMetricsResolved` unusable for
        // every OTF and pushed that knowledge onto callers.
        if (self.is_cff) return null;
        const data = try glyphRange(self, gid);
        // An empty range is a blank glyph; a positive contour count is simple.
        if (data.len == 0) return null;
        if (try i16At(data, 0) >= 0) return null;

        var p: usize = 10;
        var flags: u16 = 1 << 5; // enter the loop
        while (flags & (1 << 5) != 0) {
            flags = try u16At(data, p);
            p += 2;
            const comp = try u16At(data, p);
            p += 2;
            if (flags & use_my_metrics != 0) return comp;

            // Two arguments, whatever they mean: offsets or point numbers.
            p += if (flags & 0x0001 != 0) 4 else 2;

            if (flags & 0x0008 != 0) {
                p += 2;
            } else if (flags & 0x0040 != 0) {
                p += 4;
            } else if (flags & 0x0080 != 0) {
                p += 8;
            }
        }
        return null;
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

/// OpenType's float-to-integer rounding: floor(v + 0.5), i.e. half UP, not half
/// away from zero. The two only part company at an exact .5, and that is
/// exactly where a coordinate pinned to a half-unit scalar lands -- wght 250 on
/// Inter puts every tuple at a 0.5 ramp, so a negative product of -12.5 must
/// give -12, not -13. fontTools and FreeType both round this way.
fn otRound(v: f32) i32 {
    return @intFromFloat(@floor(v + 0.5));
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
        const first_n = cur.n;
        const first_nc = cur.nc;
        try decodeSimple(data, @intCast(n_contours), cur);
        // Vary here rather than at the top of `outline`, because a composite's
        // components are themselves glyphs with their own deltas and they are
        // decoded through this same function.
        self.varyOutline(gid, first_n, cur.points[first_n..cur.n], cur.ends[first_nc..cur.nc]);
    } else {
        const ncomp = componentCount(data) catch 0;
        var dxb: [comp_cap]f32 = @splat(0);
        var dyb: [comp_cap]f32 = @splat(0);
        var vdx: ?[]const f32 = null;
        var vdy: ?[]const f32 = null;
        if (ncomp > 0 and ncomp <= comp_cap) {
            if (varyComposite(self, gid, ncomp, dxb[0..ncomp], dyb[0..ncomp])) {
                vdx = dxb[0..ncomp];
                vdy = dyb[0..ncomp];
            }
        }
        try decodeComposite(self, data, cur, depth, vdx, vdy);
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
/// How many component records a composite carries. Sizing only: the offsets
/// themselves are read by `decodeComposite`.
fn componentCount(data: []const u8) GlyphError!usize {
    var p: usize = 10;
    var flags: u16 = 1 << 5;
    var n: usize = 0;
    while (flags & (1 << 5) != 0) : (n += 1) {
        flags = try u16At(data, p);
        p += 4; // flags + glyph index
        if (flags & 0x0002 != 0) {
            p += if (flags & 0x0001 != 0) 4 else 2;
        } else {
            p += 4; // point-matching arguments
        }
        if (flags & 0x0008 != 0) {
            p += 2;
        } else if (flags & 0x0040 != 0) {
            p += 4;
        } else if (flags & 0x0080 != 0) {
            p += 8;
        }
        if (p > data.len) return error.Truncated;
        if (n > 1024) return error.Truncated;
    }
    return n;
}

/// Deltas for a composite's component offsets, at the current instance.
fn varyComposite(self: Font, gid: u16, n: usize, dx: []f32, dy: []f32) bool {
    if (self.n_coords == 0 or self.gvar_span.len == 0 or n == 0) return false;
    var xs: [1024]f32 = @splat(0);
    var ys: [1024]f32 = @splat(0);
    var tx: [1024]f32 = @splat(0);
    var ty: [1024]f32 = @splat(0);
    var touched: [1024]bool = @splat(false);
    var idx: [1024]u16 = undefined;
    return variations.applyGlyph(
        self.data[self.gvar_span.off..][0..self.gvar_span.len],
        self.coords[0..self.n_coords],
        gid,
        n,
        &.{}, // no contours, so no interpolation: an unlisted component is unmoved
        xs[0..n],
        ys[0..n],
        dx,
        dy,
        touched[0..n],
        idx[0..n],
        tx[0..n],
        ty[0..n],
    ) catch false;
}

fn decodeComposite(self: Font, data: []const u8, cur: *Cursor, depth: u32, vdx: ?[]const f32, vdy: ?[]const f32) GlyphError!void {
    if (depth >= max_composite_depth) return error.CompositeTooDeep;

    var p: usize = 10;
    var flags: u16 = 1 << 5; // enter the loop
    var comp_i: usize = 0;
    while (flags & (1 << 5) != 0) : (comp_i += 1) {
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

        // A composite's deltas move its component offsets, one delta per
        // record, before the component's own transform is applied.
        if (vdx) |vx| {
            if (comp_i < vx.len) dx += vx[comp_i];
        }
        if (vdy) |vy| {
            if (comp_i < vy.len) dy += vy[comp_i];
        }

        // SCALED_COMPONENT_OFFSET: the offset is expressed in the component's
        // own space, so the matrix applies to it too. UNSCALED_COMPONENT_OFFSET
        // -- and the common case of neither flag, which is Microsoft's reading
        // and what most fonts were built against -- leave it alone.
        // ROUND_XY_TO_GRID (0x0004) and OVERLAP_COMPOUND (0x0400) are
        // grid-fitting hints: nothing here hints, and the points land on
        // integers below anyway, so neither can change this output.
        if (flags & 0x0800 != 0) {
            const ox = a * dx + c * dy;
            const oy = b * dx + d * dy;
            dx = ox;
            dy = oy;
        }

        const start = cur.n;
        try decodeInto(self, gid, cur, depth + 1);

        for (cur.points[start..cur.n]) |*pt| {
            const px: f32 = @floatFromInt(pt.x);
            const py: f32 = @floatFromInt(pt.y);
            pt.x = otRound(a * px + c * py + dx);
            pt.y = otRound(b * px + d * py + dy);
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
    phase_y: f32 = 0,
    ox: f32,
    oy: f32,
    flat_sq: f32,

    fn line(self: *Emitter, x0: f32, y0: f32, x1: f32, y1: f32) GlyphError!void {
        const px0 = x0 * self.scale + self.phase_x - self.ox;
        const px1 = x1 * self.scale + self.phase_x - self.ox;
        const py0 = -y0 * self.scale + self.phase_y - self.oy;
        const py1 = -y1 * self.scale + self.phase_y - self.oy;
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
    return @fromBackingInt(@intCast(@as(u2, @intCast(q & 3))));
}

pub fn phaseOffset(p: Phase) f32 {
    return @as(f32, @floatFromInt(@backingInt(p))) * 0.25;
}

/// A rasterised glyph, owned by the cache.
///
/// The pixels stay valid until its SIZE CLASS is evicted or the whole cache is
/// reset. A class eviction is not a flush: the slot table keeps every other
/// class's entries, and the evicted class's arena bytes are handed out again,
/// so a `Mask` held across it can come back pointing at some other glyph. Blit
/// it before asking for the next glyph.
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
/// The arena is partitioned into size classes, and each class is its own bump
/// region. When a class cannot fit the next mask, THAT CLASS is evicted -- its
/// slots are marked dead and its region starts over -- while the other classes
/// keep their pixels. Dropping all four would throw away three working sets to
/// make room in one. Reclaiming a dead mask from the middle of a bump region is
/// not possible without a compaction pass, and a compaction pass costs more
/// than re-rasterising a working set that did not fit in the first place. If
/// the flush count is high, the buffer is too small. Since a full class and a
/// full table both RECYCLE now, that signal is weaker than it reads: overflow
/// usually shows up as a lower hit rate rather than as a flush, so the flush
/// count catches only the case where no victim was big enough.
pub const Cache = struct {
    pub const Options = struct {
        /// Slots in the open-addressed key table.
        ///
        /// This must hold the whole working set, and it is the STRONGER of the
        /// two limits: 1000 distinct glyphs against 512 slots measured 0.0%
        /// hits even with an 8 MiB arena, because every insert had to recycle
        /// and every look-up missed. Aim for at least the number of distinct
        /// glyphs on screen; 2x that shortens probe chains, at the cost of the
        /// table's memory.
        slots: u16 = 512,
        max_points: u16 = 1024,
        max_ends: u16 = 256,
        max_edges: u16 = 1024,
        /// Widest box the sweep can accumulate, in pixels.
        max_width: u16 = 256,
        /// Pixel-arena bytes, used ONLY to size `needed()`.
        ///
        /// It is not a cap. The cache claims every byte of the buffer past its
        /// tables, so a caller that hands over a larger array silently gets a
        /// larger arena and this number is ignored. That is the friendly
        /// direction to fail, but it means a test that wants to observe
        /// eviction has to cut its buffer to exactly `needed()` -- otherwise
        /// it asserts about a capacity it never had.
        arena: u32 = 256 * 1024,
    };

    pub const Stats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        /// Every time pixels gave way: one size class giving up its share, or
        /// the whole table when the slots run out. A high count means the arena
        /// is sized below the working set -- visible rather than inferred from
        /// timings. It is not a miss count: what a class eviction costs depends
        /// on whether those masks are asked for again.
        flushes: u64 = 0,
    };

    const Slot = struct {
        gid: u16 = 0,
        scale_key: u32 = 0,
        var_key: u32 = 0,
        phase: Phase = .zero,
        phase_y: Phase = .zero,
        /// The size class the pixels came from, so an eviction knows whose
        /// slot to drop without consulting any other bookkeeping.
        cls: u8 = 0,
        off: u32 = 0,
        /// Bytes reserved in the class, which is what an eviction frees. It is
        /// the box the caller asked for, NOT `w * h`: the raster may return a
        /// smaller coverage than the box it was given, and an extent that
        /// under-reports itself would refuse to host a mask that fits.
        len: u32 = 0,
        /// Last touch, oldest-wins. A hit refreshes it, so the glyphs a frame
        /// actually asks for survive an eviction instead of the ones that
        /// merely happened to be inserted late.
        used: u64 = 0,
        w: u32 = 0,
        h: u32 = 0,
        x0: i32 = 0,
        y0: i32 = 0,
        state: State = .empty,
    };

    /// An open-addressed table cannot simply drop an entry: a hole in the
    /// middle of a probe chain hides every key behind it, because a lookup
    /// stops at the first empty slot it meets. `dead` keeps the chain walkable
    /// while marking those pixels as gone.
    const State = enum(u2) { empty = 0, live = 1, dead = 2 };

    /// Byte-size classes, largest `len` each will hold. A mask goes in the
    /// first class that fits, and every class owns its own slice of the arena.
    ///
    /// The point is that filling up is not a single event: without this, one
    /// page of display-size glyphs exhausts the arena and evicts the small text
    /// masks that get asked for on every row of every frame, so the cheap,
    /// hot, numerous masks are thrown away to make room for the rare, cold,
    /// expensive ones. Separate budgets mean each population only competes with
    /// itself.
    const class_count = 4;
    const class_max = [class_count]usize{ 256, 1024, 4096, std.math.maxInt(usize) };
    /// Below this there is no room to divide usefully, and the cache behaves as
    /// one pool exactly as it used to -- which keeps a deliberately tiny arena
    /// in a test meaning what it says.
    const partition_min: usize = 8 * 1024;

    mem: []align(8) u8,
    slots: []Slot,
    points: []Point,
    ends: []u16,
    edges: []Edge,
    scratch: []f32,
    arena_at: usize,
    arena_len: usize,
    class_at: [class_count]usize = @splat(0),
    class_cap: [class_count]usize = @splat(0),
    class_used: [class_count]usize = @splat(0),
    partitioned: bool,
    /// Recency clock. A plain counter rather than a timestamp: recency is the
    /// only thing asked of it, and a clock would make eviction depend on how
    /// fast a frame ran.
    tick: u64 = 0,
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

    /// Arena bytes to hold roughly `glyphs` distinct masks at `ppem`.
    ///
    /// `needed()` answers "how big a buffer does this configuration take".
    /// That is a different question from "how much arena does my screen need",
    /// and nothing used to answer the second. A caller could size its buffer
    /// correctly by the library's own measure and still cache almost nothing,
    /// because the default arena holds only about four hundred CJK glyphs at
    /// 16px. The failure was silent: no error, no band, just a hit rate that
    /// reads as a slow rasteriser.
    ///
    /// A mask costs about four bytes per em squared, so 24px is roughly twice
    /// the size of 16px rather than 1.5 times -- area, not length. Measured on
    /// NotoSansCJKsc: 2000 glyphs at 16px needed 2 MiB, 4000 needed 4 MiB, 1000
    /// at 24px needed 2 MiB, each reaching 100%. This rounds up from those.
    ///
    /// The measurement already accounts for the four-way class split: one size
    /// class only ever receives a quarter of the arena, and those numbers were
    /// taken through that path rather than corrected for it afterwards.
    ///
    /// A heuristic, not a guarantee -- one face, one phase. Under-sizing is
    /// survivable: the cache still works, it evicts sooner.
    pub fn arenaFor(glyphs: usize, ppem: u16) u32 {
        const e: u64 = ppem;
        const total = @as(u64, glyphs) * 4 * e * e;
        return @intCast(@min(total, std.math.maxInt(u32)));
    }

    pub fn init(mem: []align(8) u8, opts: Options) error{BufferTooSmall}!Cache {
        // A zero-slot table has no probe chain to walk and `probeStart` would
        // take it modulo zero. `Lookup` refuses the same input for the same
        // reason; a configuration error is not a crash.
        if (opts.slots == 0 or mem.len < needed(opts)) return error.BufferTooSmall;
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
            .partitioned = mem.len - arena_at >= partition_min,
        };
        if (c.partitioned) {
            const each = c.arena_len / class_count;
            var k: usize = 0;
            while (k < class_count) : (k += 1) {
                c.class_at[k] = k * each;
                c.class_cap[k] = each;
            }
            // The division is not exact; the last class takes the remainder
            // rather than leaving bytes unreachable.
            c.class_cap[class_count - 1] = c.arena_len - (class_count - 1) * each;
        } else {
            c.class_cap[class_count - 1] = c.arena_len;
        }
        c.reset();
        return c;
    }

    /// Which budget a mask of `len` bytes is drawn from.
    fn classOf(self: Cache, len: usize) usize {
        if (!self.partitioned) return class_count - 1;
        var k: usize = 0;
        while (k < class_count - 1) : (k += 1) {
            if (len <= class_max[k]) return k;
        }
        return class_count - 1;
    }

    /// The mask for this glyph at this pixel size and phase, rasterising it if
    /// it is not already held.
    /// A mask at a pixel size, for callers who think in ppem.
    pub fn mask(self: *Cache, font: *const Font, gid: u16, ppem: u16, phase: Phase) GlyphError!Mask {
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
    pub fn maskAt(self: *Cache, font: *const Font, gid: u16, scale: f32, phase: Phase) GlyphError!Mask {
        return self.maskAtXY(font, gid, scale, phase, .zero);
    }

    /// `maskAt` with a vertical phase as well.
    ///
    /// The y phase belongs in the KEY, not just the call: two masks of one glyph
    /// that differ only vertically are different pictures, so sharing a slot
    /// between them would serve the wrong one forever.
    pub fn maskAtXY(self: *Cache, font: *const Font, gid: u16, scale: f32, phase: Phase, phase_y: Phase) GlyphError!Mask {
        const scale_key: u32 = @bitCast(scale);
        const vk = font.variationId();
        if (self.find(gid, scale_key, phase, phase_y, vk)) |s| {
            self.stats.hits += 1;
            s.used = self.bumpTick();
            const at = self.arena_at + self.class_at[s.cls] + s.off;
            return .{ .w = s.w, .h = s.h, .x0 = s.x0, .y0 = s.y0, .pixels = self.mem[at..][0 .. @as(usize, s.w) * s.h] };
        }

        self.stats.misses += 1;
        if (!(scale > 0) or font.units_per_em == 0) return .{};
        const ph = phaseOffset(phase);
        const phy = phaseOffset(phase_y);
        // Size the arena from the box the raster will ACTUALLY use. Measuring
        // with the x phase alone under-reserves by a row whenever a y phase
        // pushes a ceil over, and the failure surfaces as BufferTooSmall on a
        // glyph that fits at every whole-pixel offset.
        const box = try font.bitmapBoxPhase(gid, scale, ph, phy);
        const w: u32 = if (box.x1 > box.x0) @intCast(box.x1 - box.x0) else 0;
        const h: u32 = if (box.y1 > box.y0) @intCast(box.y1 - box.y0) else 0;
        if (w == 0 or h == 0) return .{ .x0 = box.x0, .y0 = box.y0 };
        const len = @as(usize, w) * h;

        const cls = self.classOf(len);
        if (len > self.class_cap[cls]) return error.BufferTooSmall;
        // Only this class gives way. Masks of other sizes keep their pixels.
        //
        // A full class first tries to RECYCLE one victim's extent in place,
        // which is the whole point: the old path wiped the class and turned a
        // one-glyph overflow into a total loss -- measured at 99.8% -> 9.1%
        // hits between 400 and 405 distinct CJK glyphs. Wiping stays as the
        // fallback for when no victim is big enough, because with nothing
        // contiguous left it is the only honest answer.
        // Table space first, and a table eviction doubles as an arena one:
        // recycling a mask hands back its slot AND its extent, so the two
        // limits cannot drift apart. Wiping the table stays as the fallback
        // for when no victim is big enough.
        //
        // It has to be a victim of THIS class. `off` is relative to the
        // class's own region, so borrowing an extent from another class and
        // recording the new mask under this one would address the wrong bytes.
        var recycled: ?usize = null;
        var slot = self.freeSlot(gid, scale_key, phase, phase_y, vk);
        if (slot == null) {
            if (self.evictOne(cls, len)) |off| {
                recycled = off;
                slot = self.freeSlot(gid, scale_key, phase, phase_y, vk);
            } else {
                self.flush();
                slot = self.freeSlot(gid, scale_key, phase, phase_y, vk);
            }
        }
        const s = slot orelse return error.BufferTooSmall;

        const at_off: usize = recycled orelse blk: {
            if (self.class_used[cls] + len <= self.class_cap[cls]) {
                const o = self.class_used[cls];
                self.class_used[cls] += len;
                break :blk o;
            }
            // A reclaimed extent is already inside the class's accounted
            // bytes, so `class_used` is deliberately left alone: it is a
            // high-water mark here, not a live total. Decrementing it would
            // hand the bump pointer a region live masks still occupy.
            if (self.evictOne(cls, len)) |off| break :blk off;
            self.evictClass(cls);
            self.class_used[cls] = len;
            break :blk 0;
        };

        const at = self.arena_at + self.class_at[cls] + at_off;
        const r = try font.rasterPhase(gid, scale, ph, phy, self.points, self.ends, self.edges, self.scratch, self.mem[at..][0..len]);

        s.* = .{
            .gid = gid,
            .scale_key = scale_key,
            .var_key = vk,
            .phase = phase,
            .phase_y = phase_y,
            .cls = @intCast(cls),
            .off = @intCast(at_off),
            .len = @intCast(len),
            .used = self.bumpTick(),
            .w = r.w,
            .h = r.h,
            .x0 = r.x0,
            .y0 = r.y0,
            .state = .live,
        };
        return .{ .w = r.w, .h = r.h, .x0 = r.x0, .y0 = r.y0, .pixels = r.coverage };
    }

    fn probeStart(self: *Cache, gid: u16, scale_key: u32, phase: Phase, phase_y: Phase, var_key: u32) usize {
        // The instance id is part of the key: the same glyph at the same size
        // in two weights is two different masks.
        // The scale enters the key by its raw bits. Quantising it onto a size
        // lattice would let two neighbouring sizes share a mask, which is the
        // wrong glyph by design; a caller that animates size loses hit rate
        // instead, and that is the honest failure.
        var key: u64 = (@as(u64, gid) << 40) ^ (@as(u64, scale_key) << 4) ^ (@as(u64, @backingInt(phase)) << 2) ^ @as(u64, @backingInt(phase_y)) ^ (@as(u64, var_key) << 48);
        key *%= 0x9E3779B97F4A7C15;
        key ^= key >> 29;
        return @as(usize, key >> 16) % self.slots.len;
    }

    fn find(self: *Cache, gid: u16, scale_key: u32, phase: Phase, phase_y: Phase, var_key: u32) ?*Slot {
        const start = self.probeStart(gid, scale_key, phase, phase_y, var_key);
        var i: usize = 0;
        while (i < self.slots.len) : (i += 1) {
            const s = &self.slots[(start + i) % self.slots.len];
            if (s.state == .empty) return null; // an empty slot ends the probe run
            if (s.state == .live and s.gid == gid and s.scale_key == scale_key and s.phase == phase and s.phase_y == phase_y and s.var_key == var_key) return s;
        }
        return null;
    }

    fn freeSlot(self: *Cache, gid: u16, scale_key: u32, phase: Phase, phase_y: Phase, var_key: u32) ?*Slot {
        const start = self.probeStart(gid, scale_key, phase, phase_y, var_key);
        var i: usize = 0;
        while (i < self.slots.len) : (i += 1) {
            const s = &self.slots[(start + i) % self.slots.len];
            if (s.state != .live) return s; // a dead slot is free, and keeps its chain
        }
        return null;
    }

    /// Back to cold: every slot empty and every class's region abandoned, so
    /// the arena starts allocating from zero again. `stats` is NOT touched --
    /// the counters are a running total across resets, which is what makes a
    /// high flush count visible at all. Storage is untouched, so this is cheap
    /// and repeatable.
    ///
    /// It exists because a cache's STARTING STATE is otherwise not something a
    /// caller can name. A test that wants to observe misses has to know it
    /// began cold -- and Elm's process-global test face is shared across a
    /// whole test binary, so that assumption held only while no earlier test
    /// happened to raster the same glyphs.
    pub fn reset(self: *Cache) void {
        for (self.slots) |*s| s.state = .empty;
        self.class_used = @splat(0);
    }

    fn bumpTick(self: *Cache) u64 {
        self.tick += 1;
        return self.tick;
    }

    /// Reclaim the OLDEST slot of `cls` whose extent can host `len` bytes, and
    /// return its offset for immediate reuse.
    ///
    /// One victim, not a class wipe. The pixels of every other mask stay where
    /// they are, which matters beyond hit rate: a `Mask` already handed to a
    /// caller points into the arena, so compacting or moving live pixels would
    /// pull the floor out from under it mid-frame.
    ///
    /// Null means no victim is big enough, and the caller falls back to wiping.
    fn evictOne(self: *Cache, cls: usize, len: usize) ?usize {
        var victim: ?*Slot = null;
        for (self.slots) |*s| {
            if (s.state != .live or s.cls != cls) continue;
            if (s.len < len) continue;
            if (victim == null or s.used < victim.?.used) victim = s;
        }
        const v = victim orelse return null;
        v.state = .dead;
        return v.off;
    }

    /// One size class gives way; the other three keep their pixels.
    fn evictClass(self: *Cache, cls: usize) void {
        for (self.slots) |*s| {
            if (s.state == .live and s.cls == cls) s.state = .dead;
        }
        self.class_used[cls] = 0;
        self.stats.flushes += 1;
    }

    /// Everything goes. Counted, because a high flush count means the caller
    /// sized the arena below the working set and that is worth being able to
    /// see rather than infer from timings.
    fn flush(self: *Cache) void {
        self.reset();
        self.stats.flushes += 1;
    }
};

// ---------------------------------------------------------------------------
// codepoint -> glyph lookup table
// ---------------------------------------------------------------------------

/// A codepoint-to-glyph table, so a repeated character does not walk the cmap
/// again.
///
/// Measured on DejaVu Sans: a `glyphIndex` call costs about 450 ns and a cache
/// hit on the raster costs about 85 ns, so in a real draw roughly four fifths
/// of a glyph's cost is the map search, and the mask cache cannot touch any of
/// it. The search is already a binary search, so the fix is not a better
/// algorithm -- a dozen scattered `u16` reads across a multi-KB segment array
/// is simply more memory traffic than a 8 KB table that stays resident.
///
/// Pair kerning with the feature's lookups resolved once, instead of rebuilt
/// per query the way `Font.pairAdjust` has to.
///
/// Storage is the caller's, like `Lookup`: no allocator, and a `Kern` that
/// outlives its buffer is a dangling slice the type system will not catch, so
/// the buffer must live at least as long as the value.
///
/// PRECEDENCE, and it matters: GPOS wins, and the legacy `kern` table is
/// consulted only when the face has no `kern` feature in GPOS. A face that
/// carries both is expressing the same kerning twice, so summing them would
/// double every pair; DejaVu is such a face.
pub const Kern = struct {
    pub const Options = struct {
        /// Lookup indices tracked for the `kern` feature, in 2-byte entries.
        lookups: u16 = 32,
    };

    pub const Status = enum {
        /// Pair adjustment from GPOS, where modern faces keep kerning.
        gpos,
        /// No `kern` feature in GPOS, so the older table is the answer.
        legacy,
        /// Neither: this face does not kern.
        none,
    };

    font: Font,
    layout: ?opentype.Layout = null,
    lookups: []u16 = &.{},
    status: Status = .none,

    /// How much memory `init` wants for this configuration.
    pub fn needed(opts: Options) usize {
        return @as(usize, opts.lookups) * @sizeOf(u16);
    }

    pub fn init(mem: []align(8) u8, font: Font, opts: Options) Kern {
        const n = @min(@as(usize, opts.lookups), mem.len / @sizeOf(u16));
        const buf: []u16 = @alignCast(std.mem.bytesAsSlice(u16, mem[0 .. n * @sizeOf(u16)]));
        return initSlice(font, buf);
    }

    /// The same thing over storage the caller already has as `u16`, which is
    /// what `shape` needs for its stack scratch.
    pub fn initSlice(font: Font, buf: []u16) Kern {
        var k = Kern{ .font = font };
        if (font.gpos_span.len >= 10) {
            if (opentype.Layout.init(font.data, font.gpos_span.off, font.gpos_span.len)) |l| {
                if (l.featureLookupsDefault(opentype.tag("kern"), buf)) |got| {
                    if (got.len != 0) {
                        k.layout = l;
                        k.lookups = got;
                        k.status = .gpos;
                        return k;
                    }
                } else |_| {}
            } else |_| {}
        }
        k.status = if (font.kern_ok) .legacy else .none;
        return k;
    }

    /// The adjustment for a pair, in FONT UNITS.
    pub fn adjust(self: Kern, left: u16, right: u16) opentype.Adjust {
        return switch (self.status) {
            .gpos => if (self.layout) |l| l.pairAdjust(self.lookups, left, right) else .{},
            .legacy => .{ .x_advance = self.font.kern(left, right) },
            .none => .{},
        };
    }

    /// The x advance of `adjust`, for a caller that only wants a number.
    pub fn xAdvance(self: Kern, left: u16, right: u16) i16 {
        return self.adjust(left, right).x_advance;
    }
};

/// Same contract as `Cache`: the caller owns the memory, there is no
/// allocator, and `init` carves one buffer.
pub const Lookup = struct {
    pub const Options = struct {
        /// A power of two divides evenly; anything else costs a modulo per
        /// probe. 1024 slots is 8 KB, which fits in L1 with room to spare.
        slots: u16 = 1024,
    };

    pub const Stats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
    };

    /// What a draw asks for, in font units.
    pub const Entry = struct {
        gid: u16,
        advance: u16,
    };

    /// No codepoint is 0xFFFFFFFF, so it marks a free slot.
    const empty: u32 = 0xFFFF_FFFF;

    const Slot = struct {
        cp: u32 = empty,
        gid: u16 = 0,
        advance: u16 = 0,
    };

    slots: []Slot,
    stats: Stats = .{},

    /// How much memory `init` wants for this configuration.
    pub fn needed(opts: Options) usize {
        return @as(usize, opts.slots) * @sizeOf(Slot);
    }

    pub fn init(mem: []align(8) u8, opts: Options) error{BufferTooSmall}!Lookup {
        if (opts.slots == 0 or mem.len < needed(opts)) return error.BufferTooSmall;
        var off: usize = 0;
        const slots = takeSlice(Slot, mem, &off, opts.slots);
        var l = Lookup{ .slots = slots };
        l.reset();
        return l;
    }

    /// Glyph and advance for a codepoint, resolving it if this is the first
    /// time. A failed resolution is not cached: it is rare, the caller has to
    /// handle the error anyway, and caching it would need a second kind of slot
    /// for no gain.
    pub fn resolve(self: *Lookup, font: *const Font, cp: u21) GlyphError!Entry {
        const key: u32 = @intCast(cp);
        const start = self.probeStart(key);
        var i: usize = 0;
        var free_at: ?usize = null;
        while (i < self.slots.len) : (i += 1) {
            const idx = (start + i) % self.slots.len;
            const s = &self.slots[idx];
            if (s.cp == key) {
                self.stats.hits += 1;
                return .{ .gid = s.gid, .advance = s.advance };
            }
            if (s.cp == empty) {
                free_at = idx;
                break;
            }
        }

        self.stats.misses += 1;
        const gid = try font.glyphIndex(cp);
        // Resolved, not raw: this runs once per new codepoint, which is the
        // one place the USE_MY_METRICS lookup is free.
        const advance = (try font.hMetricsResolved(gid)).advance;
        // First free slot on the run, or the home slot when the table is full.
        // Overwriting the home slot is the cheapest eviction there is, and a
        // caller cannot feel it: the next resolve simply recomputes.
        self.slots[free_at orelse start] = .{ .cp = key, .gid = gid, .advance = advance };
        return .{ .gid = gid, .advance = advance };
    }

    /// Every slot goes. Counters too -- unlike the raster cache's arena, which
    /// flushes under memory pressure and counts it, this one only clears when
    /// the caller asks, so a reset is a fresh measurement.
    pub fn reset(self: *Lookup) void {
        for (self.slots) |*s| s.cp = empty;
        self.stats = .{};
    }

    fn probeStart(self: *Lookup, cp: u32) usize {
        var key: u64 = cp;
        key *%= 0x9E3779B97F4A7C15;
        key ^= key >> 32;
        return @as(usize, @truncate(key)) % self.slots.len;
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

fn at32(b: []const u8, off: usize) u32 {
    return (@as(u32, b[off]) << 24) | (@as(u32, b[off + 1]) << 16) | (@as(u32, b[off + 2]) << 8) | b[off + 3];
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
    return buildTestFontImpl(buf, with_fmt12, false, .none);
}

/// The same 8-glyph face plus `fvar`, `avar` and `gvar`: one weight axis
/// 400..700, an avar that maps 0.5 onto 0.6 (so the map is not the identity and
/// the F2Dot14 snap is exercised), and deltas on gid 6 only. The gvar uses
/// SHORT offsets on purpose -- every real font big enough to matter ships long
/// ones, and that hid a wrong index stride here for the whole of Inter.
fn buildVarTestFont(buf: []u8) []const u8 {
    return buildTestFontImpl(buf, false, true, .none);
}

/// The same 8-glyph face plus a well-formed but EMPTY `GSUB`: no scripts, no
/// features, no lookups, so nothing substitutes. It exists because an empty
/// `gsub_span` makes `shapeArabic` and `shapeThai` return before their placement
/// path, which left that code with no way to be tested at all.
/// What the fixture's `GSUB` contains.
const GsubKind = enum {
    /// No GSUB table at all.
    none,
    /// A header with three empty lists: loads, substitutes nothing.
    empty,
    /// One `ccmp` lookup that turns gid 0 into gid 1 followed by gid 2, so a
    /// substitution really does LENGTHEN the run.
    subst,
    /// One `locl` lookup under a NAMED language system (`JAN `) and no default
    /// language system at all, so `locl` is reachable only when the caller names
    /// a language. This is the shape real CJK faces use: the default LangSys
    /// carries no `locl`, and every regional LangSys carries one.
    langsys,
};

/// The same face with a `ccmp` lookup under `arab` and `thai` that expands one
/// glyph into two. `shapeArabic` and `shapeThai` apply `ccmp` unconditionally,
/// so both reach it.
fn buildSubstTestFont(buf: []u8) []const u8 {
    return buildTestFontImpl(buf, false, false, .subst);
}

fn buildGsubTestFont(buf: []u8) []const u8 {
    return buildTestFontImpl(buf, false, false, .empty);
}

fn buildLangsysTestFont(buf: []u8) []const u8 {
    return buildTestFontImpl(buf, false, false, .langsys);
}

fn buildTestFontImpl(buf: []u8, with_fmt12: bool, comptime with_var: bool, comptime gsub: GsubKind) []const u8 {
    const ntables: usize = 8 + (if (with_var) 3 else 0) + (if (gsub != .none) 1 else 0);
    var w = W{ .buf = buf };

    w.u32v(0x0001_0000); // sfnt version
    w.u16v(@intCast(ntables)); // numTables
    w.u16v(0);
    w.u16v(0);
    w.u16v(0);
    const rec_base = w.at;
    w.zeros(ntables * 16);

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

    // --- post 2.0: the 32-byte header every version shares ---
    const post_start = w.at;
    w.u32v(0x0002_0000);
    w.u32v(0xFFF3_8000); // italicAngle -12.5, 16.16 fixed point
    w.i16v(-100); // underlinePosition
    w.i16v(50); // underlineThickness
    w.u32v(0); // isFixedPitch
    w.zeros(16); // the four memory-usage fields
    const r_post = Rec{ .at = post_start, .len = w.at - post_start };

    var tags: [ntables]u32 = undefined;
    var recs: [ntables]Rec = undefined;
    var nrec: usize = 0;
    const base_tags = [_]u32{ tag_cmap, tag_glyf, tag_loca, tag_head, tag_hhea, tag_hmtx, tag_maxp, tag_post };
    const base_recs = [_]Rec{ r_cmap, r_glyf, r_loca, r_head, r_hhea, r_hmtx, r_maxp, r_post };
    for (base_tags, base_recs) |t, r| {
        tags[nrec] = t;
        recs[nrec] = r;
        nrec += 1;
    }

    if (with_var) {
        // --- fvar: one weight axis, 400 default, 700 max ---
        const fvar_start = w.at;
        w.u32v(0x0001_0000);
        w.u16v(16); // axesArrayOffset
        w.u16v(2); // reserved
        w.u16v(1); // axisCount
        w.u16v(20); // axisSize
        w.u16v(0); // instanceCount
        w.u16v(0); // instanceSize
        w.u32v(tag("wght"));
        w.u32v(400 << 16); // min, 16.16 fixed
        w.u32v(400 << 16); // default
        w.u32v(700 << 16); // max
        w.u16v(0); // flags
        w.u16v(256); // axisNameID
        tags[nrec] = tag_fvar;
        recs[nrec] = .{ .at = fvar_start, .len = w.at - fvar_start };
        nrec += 1;

        // --- avar: 0.5 maps to 0.6, so the remap is visibly not the identity ---
        const avar_start = w.at;
        w.u32v(0x0001_0000);
        w.u16v(0); // reserved
        w.u16v(1); // axisCount
        w.u16v(4); // segmentCount
        w.i16v(-16384);
        w.i16v(-16384);
        w.i16v(0);
        w.i16v(0);
        w.i16v(8192); // 0.5
        w.i16v(9830); // -> 0.6, snapped to the 16.14 grid
        w.i16v(16384);
        w.i16v(16384);
        tags[nrec] = tag_avar;
        recs[nrec] = .{ .at = avar_start, .len = w.at - avar_start };
        nrec += 1;

        // --- gvar: deltas on gid 6 only; gids 0..5 and 7 carry nothing ---
        const gvar_start = w.at;
        const data_at: usize = 38; // 20 byte header + 9 short offsets
        w.u32v(0x0001_0000); // version 1.0
        w.u16v(1); // axisCount
        w.u16v(0); // sharedTupleCount
        w.u32v(data_at); // sharedTuplesOffset (no shared tuples)
        w.u16v(8); // glyphCount
        w.u16v(0); // flags: SHORT offsets
        w.u32v(data_at); // glyphVariationDataArrayOffset
        var g: usize = 0;
        while (g < 6) : (g += 1) w.u16v(0); // gids 0..5: no data
        w.u16v(0); // gid 6 starts at byte 0
        w.u16v(12); // gid 7 starts at byte 24
        w.u16v(12); // end of data
        // gid 6: one tuple, embedded peak 1.0, all points touched.
        w.u16v(1); // tupleVariationCount
        w.u16v(10); // dataOffset: 4 byte header + 6 byte tuple header
        w.u16v(13); // variationDataSize
        w.u16v(0x8000); // EMBEDDED_PEAK_TUPLE, tuple index 0
        w.i16v(16384); // peak 1.0
        // x deltas 40, -20, 10 then four zero phantoms
        w.u8v(0x00);
        w.u8v(40);
        w.u8v(0x00);
        w.u8v(236); // -20
        w.u8v(0x00);
        w.u8v(10);
        w.u8v(0x83); // four zeros
        // y deltas 0, 30, -10 then four zero phantoms
        w.u8v(0x80); // one zero
        w.u8v(0x00);
        w.u8v(30);
        w.u8v(0x00);
        w.u8v(246); // -10
        w.u8v(0x83); // four zeros
        w.zeros(1); // pad: short offsets count in two byte units
        tags[nrec] = tag_gvar;
        recs[nrec] = .{ .at = gvar_start, .len = w.at - gvar_start };
        nrec += 1;
    }

    if (gsub == .empty) {
        // --- GSUB: header and three empty lists ---
        //
        // `Layout.init` resolves each list offset through `inside`, which wants
        // four readable bytes at the offset, so the smallest table that loads is
        // 20 bytes: 10 header, 2+2+2 of counts, 4 of pad.
        const gsub_start = w.at;
        w.u32v(0x0001_0000); // version 1.0
        w.u16v(10); // scriptListOffset
        w.u16v(12); // featureListOffset
        w.u16v(14); // lookupListOffset
        w.u16v(0); // ScriptList: scriptCount
        w.u16v(0); // FeatureList: featureCount
        w.u16v(0); // LookupList: lookupCount
        w.zeros(4); // pad for `inside`
        tags[nrec] = tag_gsub;
        recs[nrec] = .{ .at = gsub_start, .len = w.at - gsub_start };
        nrec += 1;
    }

    if (gsub == .subst) {
        // --- GSUB: arab + thai, one ccmp feature, one type 2 lookup ---
        //
        // Type 2 (multiple substitution) is the one lookup type that makes the
        // run LONGER, which is what the placement guard's `len` has to follow.
        // Offsets are all relative to the start of the structure they belong
        // to, so each one is patched once the target is written.
        const g = w.at;
        w.u32v(0x0001_0000); // version 1.0
        const sl_at = w.at;
        w.u16v(0); // scriptListOffset, patched
        const fl_at = w.at;
        w.u16v(0); // featureListOffset, patched
        const ll_at = w.at;
        w.u16v(0); // lookupListOffset, patched

        // ScriptList: two scripts, both pointing at the same LangSys shape.
        const sl = w.at;
        w16(buf[0..], sl_at, @intCast(sl - g));
        w.u16v(2); // scriptCount
        const rec_arab = w.at;
        w.u32v(tag("arab"));
        w.u16v(0); // scriptOffset, patched
        const rec_thai = w.at;
        w.u32v(tag("thai"));
        w.u16v(0); // scriptOffset, patched
        const script_arab = w.at;
        w16(buf[0..], rec_arab + 4, @intCast(script_arab - sl));
        w.u16v(4); // defaultLangSysOffset: the LangSys follows the two counts
        w.u16v(0); // langSysCount
        // LangSys
        w.u16v(0); // lookupOrder
        w.u16v(0xFFFF); // requiredFeatureIndex: none
        w.u16v(1); // featureIndexCount
        w.u16v(0); // featureIndices[0]
        // The Thai script reuses the arab one by offset: same feature set.
        w16(buf[0..], rec_thai + 4, @intCast(script_arab - sl));

        // FeatureList: ccmp -> lookup 0.
        const fl = w.at;
        w16(buf[0..], fl_at, @intCast(fl - g));
        w.u16v(1); // featureCount
        w.u32v(tag("ccmp"));
        const feat_off_at = w.at;
        w.u16v(0); // featureOffset, patched
        const feat = w.at;
        w16(buf[0..], feat_off_at, @intCast(feat - fl));
        w.u16v(0); // featureParams
        w.u16v(1); // lookupIndexCount
        w.u16v(0); // lookupListIndices[0]

        // LookupList: one type 2 lookup.
        const ll = w.at;
        w16(buf[0..], ll_at, @intCast(ll - g));
        w.u16v(1); // lookupCount
        const look_off_at = w.at;
        w.u16v(0); // lookupOffset, patched
        const look = w.at;
        w16(buf[0..], look_off_at, @intCast(look - ll));
        w.u16v(2); // lookupType: multiple substitution
        w.u16v(0); // lookupFlag
        w.u16v(1); // subTableCount
        const sub_off_at = w.at;
        w.u16v(0); // subtableOffset, patched
        const sub = w.at;
        w16(buf[0..], sub_off_at, @intCast(sub - look));
        w.u16v(1); // substFormat 1
        const cov_off_at = w.at;
        w.u16v(0); // coverageOffset, patched
        w.u16v(1); // sequenceCount
        const seq_off_at = w.at;
        w.u16v(0); // sequenceOffset[0], patched
        const cov = w.at;
        w16(buf[0..], cov_off_at, @intCast(cov - sub));
        w.u16v(1); // coverageFormat 1
        w.u16v(1); // glyphCount
        w.u16v(0); // the glyph Arabic text maps to in this face: gid 0
        const seq = w.at;
        w16(buf[0..], seq_off_at, @intCast(seq - sub));
        w.u16v(2); // glyphCount: one glyph becomes two
        w.u16v(1);
        w.u16v(2);

        tags[nrec] = tag_gsub;
        recs[nrec] = .{ .at = g, .len = w.at - g };
        nrec += 1;
    }

    if (gsub == .langsys) {
        // --- GSUB: one `locl` under a NAMED language system only ---
        //
        // There is deliberately NO default LangSys, so with `lang = 0` the
        // feature is unreachable and the run comes back untouched. Naming
        // `JAN ` is the only way in, which is the property being tested.
        const g = w.at;
        w.u32v(0x0001_0000); // version 1.0
        const sl_at = w.at;
        w.u16v(0); // scriptListOffset, patched
        const fl_at = w.at;
        w.u16v(0); // featureListOffset, patched
        const ll_at = w.at;
        w.u16v(0); // lookupListOffset, patched

        // ScriptList: one script, no default LangSys.
        const sl = w.at;
        w16(buf[0..], sl_at, @intCast(sl - g));
        w.u16v(1); // scriptCount
        w.u32v(tag("DFLT"));
        const rec_dflt = w.at;
        w.u16v(0); // scriptOffset, patched
        const script_rec = w.at;
        w16(buf[0..], rec_dflt, @intCast(script_rec - sl));
        w.u16v(0); // defaultLangSysOffset: none, so lang 0 reaches nothing
        w.u16v(1); // langSysCount
        w.u32v(tag("JAN "));
        const rec_jan = w.at;
        w.u16v(0); // langSysOffset, patched
        // LangSys
        const langs = w.at;
        w16(buf[0..], rec_jan, @intCast(langs - script_rec));
        w.u16v(0); // lookupOrder
        w.u16v(0xFFFF); // requiredFeatureIndex
        w.u16v(2); // featureIndexCount
        w.u16v(0); // featureIndices[0] -> locl
        w.u16v(1); // featureIndices[1] -> fwid

        // FeatureList: locl -> lookup 0, fwid -> lookup 1. `locl` is in the
        // default set and `fwid` is not, which is what lets a test tell
        // "applied by default" from "applied because the caller named it".
        const fl = w.at;
        w16(buf[0..], fl_at, @intCast(fl - g));
        w.u16v(2); // featureCount
        w.u32v(tag("locl"));
        const feat_off_at = w.at;
        w.u16v(0); // featureOffset, patched
        w.u32v(tag("fwid"));
        const feat2_off_at = w.at;
        w.u16v(0); // featureOffset, patched
        const feat = w.at;
        w16(buf[0..], feat_off_at, @intCast(feat - fl));
        w.u16v(0); // featureParams
        w.u16v(1); // lookupIndexCount
        w.u16v(0); // lookupListIndices[0]
        const feat2 = w.at;
        w16(buf[0..], feat2_off_at, @intCast(feat2 - fl));
        w.u16v(0); // featureParams
        w.u16v(1); // lookupIndexCount
        w.u16v(1); // lookupListIndices[0]

        // LookupList: two type 1 lookups. Lookup 0 turns 'A' (gid 6) into gid 2.
        // Lookup 1 covers ONLY gid 2 -- the glyph lookup 0 produces -- so it
        // bites only if the default set ran first. If extras ran before the
        // defaults, lookup 1 would see gid 6, miss, and the result would stay 2.
        // That difference is what makes the ORDER observable instead of luck.
        const ll = w.at;
        w16(buf[0..], ll_at, @intCast(ll - g));
        w.u16v(2); // lookupCount
        const look_off_at = w.at;
        w.u16v(0); // lookupOffset[0], patched
        const look2_off_at = w.at;
        w.u16v(0); // lookupOffset[1], patched
        const look = w.at;
        w16(buf[0..], look_off_at, @intCast(look - ll));
        w.u16v(1); // lookupType: single substitution
        w.u16v(0); // lookupFlag
        w.u16v(1); // subTableCount
        const sub_off_at = w.at;
        w.u16v(0); // subtableOffset, patched
        const sub = w.at;
        w16(buf[0..], sub_off_at, @intCast(sub - look));
        w.u16v(2); // substFormat 2
        const cov_off_at = w.at;
        w.u16v(0); // coverageOffset, patched
        w.u16v(1); // glyphCount
        w.u16v(2); // substituteGlyphIDs[0]: gid 6 becomes gid 2
        const cov = w.at;
        w16(buf[0..], cov_off_at, @intCast(cov - sub));
        w.u16v(1); // coverageFormat 1
        w.u16v(1); // glyphCount
        w.u16v(6); // coverage glyph: gid 6, which is 'A' in this face

        const look2 = w.at;
        w16(buf[0..], look2_off_at, @intCast(look2 - ll));
        w.u16v(1); // lookupType: single substitution
        w.u16v(0); // lookupFlag
        w.u16v(1); // subTableCount
        const sub2_off_at = w.at;
        w.u16v(0); // subtableOffset, patched
        const sub2 = w.at;
        w16(buf[0..], sub2_off_at, @intCast(sub2 - look2));
        w.u16v(2); // substFormat 2
        const cov2_off_at = w.at;
        w.u16v(0); // coverageOffset, patched
        w.u16v(1); // glyphCount
        w.u16v(3); // gid 2 -> 3
        const cov2 = w.at;
        w16(buf[0..], cov2_off_at, @intCast(cov2 - sub2));
        w.u16v(1); // coverageFormat 1
        w.u16v(1); // glyphCount
        w.u16v(2); // only gid 2, which is what lookup 0 PRODUCES

        tags[nrec] = tag_gsub;
        recs[nrec] = .{ .at = g, .len = w.at - g };
        nrec += 1;
    }

    for (tags[0..nrec], recs[0..nrec], 0..) |t, r, i| patchRec(buf, rec_base + i * 16, t, r.at, r.len);

    return buf[0..w.at];
}

test {
    // Tests in an imported file only join this binary when the file is
    // referenced from here. Without it arabic.zig's joining tests silently
    // do not run, which is how a suite stays green while testing nothing.
    std.testing.refAllDecls(arabic);
    std.testing.refAllDecls(colr);
    std.testing.refAllDecls(variations);
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
    // OTTO is CFF outlines, which load now; without a CFF table the face has no
    // outlines at all, which is what this pins. A CFF2 table is still refused,
    // and `cff.zig` covers that directly.
    try std.testing.expectError(error.MissingTable, Font.init("OTTO\x00\x00\x00\x00"));
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
const rec_post = 7;

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

    const first = try cache.mask(&font, 6, ppem, .zero);
    try std.testing.expectEqual(@as(u64, 0), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
    try std.testing.expectEqual(direct.w, first.w);
    try std.testing.expectEqual(direct.h, first.h);
    try std.testing.expectEqualSlices(u8, direct.coverage, first.pixels);

    const second = try cache.mask(&font, 6, ppem, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
    try std.testing.expectEqualSlices(u8, first.pixels, second.pixels);
}

test "the cache key covers size and phase, not just the glyph" {
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));
    var cbuf: [64 * 1024]u8 align(8) = undefined;
    var cache = try Cache.init(&cbuf, .{ .slots = 16, .max_points = 256, .max_edges = 256, .max_width = 64, .arena = 48 * 1024 });

    _ = try cache.mask(&font, 6, 16, .zero);
    _ = try cache.mask(&font, 6, 16, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);

    // A different size is a different mask, and so is a different phase.
    _ = try cache.mask(&font, 6, 17, .zero);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.misses);
    _ = try cache.mask(&font, 6, 16, .half);
    try std.testing.expectEqual(@as(u64, 3), cache.stats.misses);

    _ = try cache.mask(&font, 6, 16, .zero);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.hits);
}

test "the instance is part of the cache key, so a varied face still hits" {
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildVarTestFont(&fb));
    const user = [_]f32{700};
    const varied = font.withCoords(&user);
    try std.testing.expect(varied.variationId() != font.variationId());

    var cbuf: [64 * 1024]u8 align(8) = undefined;
    var cache = try Cache.init(&cbuf, .{ .slots = 16, .max_points = 256, .max_edges = 256, .max_width = 64, .arena = 48 * 1024 });

    // The instance id already chose the probe position; storing it is what
    // makes the entry findable again. Without it every ask on a varied face was
    // a miss, and 512 duplicates of one key then flushed the whole table.
    _ = try cache.mask(&varied, 6, 16, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
    _ = try cache.mask(&varied, 6, 16, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);

    // The default instance is a DIFFERENT key, not a shared hit. A stored id
    // that was always zero would pass the two checks above and fail here.
    _ = try cache.mask(&font, 6, 16, .zero);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.misses);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
}

test "a zero-slot cache is refused rather than dividing by zero" {
    // `probeStart` takes the hash modulo the slot count, so an empty table is
    // not an empty cache, it is a crash on the first ask. A configuration error
    // is not a crash: `Lookup` refuses the same input for the same reason.
    var cbuf: [Cache.needed(.{ .slots = 0 })]u8 align(8) = undefined;
    try std.testing.expectError(error.BufferTooSmall, Cache.init(&cbuf, .{ .slots = 0 }));
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
        last = try cache.mask(&font, 6, ppem, .zero);
    }
    try std.testing.expect(cache.stats.flushes > 0);

    // Whatever survived the flush has to be a correct rasterisation of THIS
    // key, which is the failure a stale offset would produce.
    const scale = @as(f32, @floatFromInt(@as(u16, 39))) / @as(f32, @floatFromInt(font.units_per_em));
    const direct = try font.raster(6, scale, 0, &pts, &ends, &edges, &scratch, &cov);
    try std.testing.expectEqualSlices(u8, direct.coverage, last.pixels);
}

test "filling one size class does not evict the small masks" {
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));

    var storage: [64 * 1024]u8 align(8) = undefined;
    var cache = try Cache.init(&storage, .{
        .slots = 64,
        .max_points = 256,
        .max_edges = 256,
        .max_width = 64,
        .arena = 16 * 1024,
    });

    // One small mask: the kind a row of text asks for on every frame.
    const small = try cache.mask(&font, 6, 8, .zero);
    try std.testing.expect(small.pixels.len > 0);
    var snapshot: [4096]u8 = undefined;
    @memcpy(snapshot[0..small.pixels.len], small.pixels);

    // Now drag a stream of display-size masks through the arena. These are the
    // cold, rare, expensive ones; they must not be able to throw out the cheap
    // hot ones to make room for themselves.
    var ppem: u16 = 300;
    while (ppem < 600) : (ppem += 1) {
        _ = try cache.mask(&font, 6, ppem, .zero);
        _ = try cache.mask(&font, 7, ppem, .zero);
    }
    try std.testing.expect(cache.stats.flushes > 0); // it really did give way

    const mid = cache.stats;
    const again = try cache.mask(&font, 6, 8, .zero);
    try std.testing.expectEqual(mid.misses, cache.stats.misses);
    try std.testing.expectEqual(mid.hits + 1, cache.stats.hits);
    try std.testing.expectEqualSlices(u8, snapshot[0..again.pixels.len], again.pixels);
}

test "evicting a class leaves the keys behind its holes findable" {
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));

    var storage: [64 * 1024]u8 align(8) = undefined;
    var cache = try Cache.init(&storage, .{
        .slots = 64,
        .max_points = 256,
        .max_edges = 256,
        .max_width = 64,
        .arena = 16 * 1024,
    });

    // Small keys and big ones requested in turn, so their slots interleave and
    // share probe chains -- which is exactly where a hole costs more than a
    // miss: a lookup that stops at the hole reports a glyph it does not have,
    // and the caller gets the WRONG mask rather than a slow one.
    var ppem: u16 = 8;
    while (ppem < 14) : (ppem += 1) {
        _ = try cache.mask(&font, 6, ppem, .zero);
        _ = try cache.mask(&font, 7, ppem * 40, .zero);
    }
    const smalls = [_]u16{ 8, 9, 10, 11, 12, 13 };
    const before = cache.stats;

    var storm: u16 = 300;
    while (storm < 500) : (storm += 1) _ = try cache.mask(&font, 6, storm, .zero);
    try std.testing.expect(cache.stats.flushes > 0);

    const mid = cache.stats;
    for (smalls) |p| _ = try cache.mask(&font, 6, p, .zero);
    // Every small key is still there: no new rasterisations, all hits.
    try std.testing.expectEqual(mid.misses, cache.stats.misses);
    try std.testing.expectEqual(mid.hits + smalls.len, cache.stats.hits);
    _ = before;
}

test "a dead slot keeps its probe chain walkable, an empty one ends it" {
    var storage: [64 * 1024]u8 align(8) = undefined;
    var cache = try Cache.init(&storage, .{ .slots = 16, .max_points = 256, .max_edges = 256, .max_width = 64, .arena = 16 * 1024 });

    const gid: u16 = 42;
    const sk: u32 = @bitCast(@as(f32, 0.25));
    const n = cache.slots.len;
    const start = cache.probeStart(gid, sk, .zero, .zero, 0);
    const near = start % n;
    const under_test = (start + 1) % n;
    const far = (start + 2) % n;

    // A live neighbour first, so the only thing standing between the lookup
    // and the key is the slot under test.
    cache.slots[near] = .{ .gid = 1, .state = .live };
    cache.slots[far] = .{ .gid = gid, .scale_key = sk, .phase = .zero, .state = .live };

    // Evicted pixels: the chain has to walk over it.
    cache.slots[under_test] = .{ .state = .dead };
    try std.testing.expect(cache.find(gid, sk, .zero, .zero, 0) != null);

    // A slot that was never used ends the run: nothing is ever stored past one,
    // so a lookup must stop rather than scan the rest of the table.
    cache.slots[under_test] = .{ .state = .empty };
    try std.testing.expect(cache.find(gid, sk, .zero, .zero, 0) == null);
}

test "a vertical phase moves the mask, and is part of the cache key" {
    var mem: [Cache.needed(.{})]u8 align(8) = undefined;
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    var cache = try Cache.init(&mem, .{});

    const flat = try cache.maskAtXY(&font, 6, 0.2, .zero, .zero);
    const before = cache.stats;

    // Same glyph, same scale, offset half a pixel DOWN: a different picture.
    const half = try cache.maskAtXY(&font, 6, 0.2, .zero, .half);
    try std.testing.expect(cache.stats.misses == before.misses + 1);
    try std.testing.expect(half.y0 != flat.y0 or !std.mem.eql(u8, half.pixels, flat.pixels));

    // And each y phase is cached on its own, so asking again is free.
    const again = try cache.maskAtXY(&font, 6, 0.2, .zero, .zero);
    try std.testing.expect(cache.stats.hits == 1);
    try std.testing.expectEqualSlices(u8, flat.pixels, again.pixels);
}

test "two vertical phases never share a cache slot" {
    // White-box on purpose. The hash already separates two different y phases,
    // so a black-box test passes whether or not the lookup COMPARES the phase
    // -- it proves the hash, not the guard. With a one-slot table every probe
    // starts at the same index, which is the only way to make the comparison
    // the deciding factor.
    var mem: [Cache.needed(.{ .slots = 1 })]u8 align(8) = undefined;
    var cache = try Cache.init(&mem, .{ .slots = 1 });
    const sk: u32 = @bitCast(@as(f32, 0.25));
    cache.slots[0] = .{ .gid = 6, .scale_key = sk, .phase = .zero, .phase_y = .zero, .state = .live };

    try std.testing.expect(cache.find(6, sk, .zero, .zero, 0) != null);
    try std.testing.expect(cache.find(6, sk, .zero, .half, 0) == null);
    try std.testing.expect(cache.find(6, sk, .half, .zero, 0) == null);
    try std.testing.expect(cache.find(6, sk, .zero, .three_quarters, 0) == null);
}

test "a subset pulls in components it was not asked for, and keeps ids" {
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    var out: [16384]u8 = undefined;

    // gid 7 is a composite whose component is gid 6. Ask for 7 alone.
    const n = try font.subset(&[_]u16{7}, &out);
    const small = try Font.init(out[0..n]);
    try std.testing.expectEqual(font.num_glyphs, small.num_glyphs);
    try std.testing.expectEqual(try font.glyphIndex('A'), try small.glyphIndex('A'));

    var pts: [256]Point = undefined;
    var ends: [32]u16 = undefined;
    var edges: [256]Edge = undefined;
    var acc: [256]f32 = undefined;
    var c1: [4096]u8 = undefined;
    var c2: [4096]u8 = undefined;
    const a = try font.raster(7, 0.02, 0, &pts, &ends, &edges, &acc, &c1);
    const b = try small.raster(7, 0.02, 0, &pts, &ends, &edges, &acc, &c2);
    try std.testing.expect(a.w > 0 and a.h > 0);
    try std.testing.expectEqual(a.w, b.w);
    try std.testing.expectEqualSlices(u8, a.coverage, b.coverage);
}

test "a subset writes a conformant container: sorted directory, correct header" {
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    var out: [16384]u8 = undefined;
    const n = try font.subset(&[_]u16{ 6, 7 }, &out);

    const nt = (@as(usize, out[4]) << 8) | out[5];
    try std.testing.expect(nt >= 8);
    // header fields are required, not decorative: a reader that trusts
    // searchRange searches the wrong span of the directory.
    var pow: usize = 1;
    var log2: usize = 0;
    while (pow * 2 <= nt) : (pow *= 2) log2 += 1;
    try std.testing.expectEqual(@as(u16, @intCast(pow * 16)), at16(&out, 6));
    try std.testing.expectEqual(@as(u16, @intCast(log2)), at16(&out, 8));
    try std.testing.expectEqual(@as(u16, @intCast(nt * 16 - pow * 16)), at16(&out, 10));

    var prev: u32 = 0;
    var i: usize = 0;
    var saw_glyf = false;
    while (i < nt) : (i += 1) {
        const rec = 12 + i * 16;
        const tg = at32(&out, rec);
        // ascending tag order, which binary-searching readers depend on
        if (i != 0) try std.testing.expect(tg > prev);
        prev = tg;
        const off = at32(&out, rec + 8);
        const len = at32(&out, rec + 12);
        try std.testing.expect(off + len <= n);
        if (tg == tag("glyf")) saw_glyf = true;
    }
    try std.testing.expect(saw_glyf);
}

test "a run longer than the scratch arrays is shaped instead of overrunning them" {
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    var cps: [600]u21 = @splat(0x41);
    var out: [600]u16 = @splat(0);
    var place: [600]opentype.Offset = @splat(.{});
    // No layout tables in the test face, so this exercises the length guards
    // rather than a lookup; the point is that it must not index past the fixed
    // component/advance scratch arrays.
    const n = try font.shape(&cps, &out, &place, .{});
    try std.testing.expectEqual(@as(usize, 600), n);
    try std.testing.expect(out[599] != 0);
}

test "a placement or advance buffer shorter than the run is refused, not written past" {
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    const cps = [_]u21{ 0x41, 0x42, 0x43, 0x44 };
    var out: [4]u16 = @splat(0);

    // Both slices are indexed by the SHAPED length, which is not known until
    // substitution has run. A buffer sized to the codepoint count is safe only
    // while nothing grows the run, and GSUB type 2 does grow it -- bounded by
    // `out.len`, not by the codepoint count -- so the check belongs after.
    var short_place: [1]opentype.Offset = undefined;
    try std.testing.expectError(error.BufferTooSmall, font.shape(&cps, &out, &short_place, .{}));

    var short_adv: [1]i32 = undefined;
    try std.testing.expectError(error.BufferTooSmall, font.shape(&cps, &out, null, .{ .advances = &short_adv }));

    // A buffer the size of the run is accepted: the guard rejects what would
    // overflow, not what happens to be smaller than the input.
    var place: [4]opentype.Offset = undefined;
    var adv: [4]i32 = undefined;
    const n = try font.shape(&cps, &out, &place, .{ .advances = &adv });
    try std.testing.expect(n > 0 and n <= 4);
}

test "the Arabic and Thai placement paths check their buffer too" {
    var fbuf: [2048]u8 = undefined;
    const font = try Font.init(buildGsubTestFont(&fbuf));

    // Non-vacuity: both functions return EARLY when there is no GSUB, so
    // without this the test would pass while never reaching the code it names.
    try std.testing.expect(font.gsub_span.len != 0);

    const cps = [_]u21{ 0x0645, 0x062D, 0x0645, 0x062F };
    var out: [4]u16 = @splat(0);

    var short: [1]opentype.Offset = undefined;
    try std.testing.expectError(error.BufferTooSmall, font.shapeArabic(&cps, &out, &short));
    try std.testing.expectError(error.BufferTooSmall, font.shapeThai(&cps, &out, &short));

    // A buffer the size of the run is accepted: the empty GSUB substitutes
    // nothing, so the shaped length is the input length.
    var full: [4]opentype.Offset = @splat(.{});
    try std.testing.expectEqual(@as(usize, 4), try font.shapeArabic(&cps, &out, &full));
    try std.testing.expectEqual(@as(usize, 4), try font.shapeThai(&cps, &out, &full));
}

test "a substitution that lengthens the run is what the placement check follows" {
    var fbuf: [2048]u8 = undefined;
    const font = try Font.init(buildSubstTestFont(&fbuf));
    try std.testing.expect(font.gsub_span.len != 0);

    // One codepoint, and its glyph is covered by a type 2 lookup that turns it
    // into two glyphs. A buffer with ONE slot therefore still has to be refused:
    // checking `place.len` against the codepoint count, or against `out.len`,
    // would both let this through and write a second slot past the end.
    const cps = [_]u21{0x0645};
    var out: [4]u16 = @splat(0);

    var one: [1]opentype.Offset = undefined;
    try std.testing.expectError(error.BufferTooSmall, font.shapeArabic(&cps, &out, &one));
    try std.testing.expectError(error.BufferTooSmall, font.shapeThai(&cps, &out, &one));

    // Two slots take it, and the sequence is the one the lookup named.
    var two: [2]opentype.Offset = @splat(.{});
    try std.testing.expectEqual(@as(usize, 2), try font.shapeArabic(&cps, &out, &two));
    try std.testing.expectEqual(@as(u16, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 2), out[1]);

    out = @splat(0);
    try std.testing.expectEqual(@as(usize, 2), try font.shapeThai(&cps, &out, &two));
    try std.testing.expectEqual(@as(u16, 1), out[0]);
    try std.testing.expectEqual(@as(u16, 2), out[1]);
}

test "a subset drops the outlines it was not given" {
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    var out: [16384]u8 = undefined;

    // Keep the triangle only; the composite that used it goes away, because
    // nothing asked for it and dropping a glyph must not be silently undone.
    const n = try font.subset(&[_]u16{6}, &out);
    const small = try Font.init(out[0..n]);

    var pts: [256]Point = undefined;
    var ends: [32]u16 = undefined;
    var edges: [256]Edge = undefined;
    var acc: [256]f32 = undefined;
    var c1: [4096]u8 = undefined;
    var c2: [4096]u8 = undefined;
    const kept = try small.raster(6, 0.02, 0, &pts, &ends, &edges, &acc, &c1);
    const gone = try small.raster(7, 0.02, 0, &pts, &ends, &edges, &acc, &c2);
    try std.testing.expect(kept.w > 0);
    try std.testing.expectEqual(@as(u32, 0), gone.w);
}

test "a subset that does not fit says so instead of writing a broken font" {
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    var tiny: [64]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, font.subset(&[_]u16{6}, &tiny));
}

test "capability queries answer from the directory, not from a guess" {
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    try std.testing.expect(font.hasTable(tag("glyf")));
    try std.testing.expect(font.hasTable(tag("cmap")));
    try std.testing.expect(!font.hasTable(tag("zzzz")));
    // The test face carries no layout tables at all, so every feature query is
    // a clean no rather than an error.
    try std.testing.expect(!font.hasGsubFeature(0, 0, tag("liga")));
    try std.testing.expect(!font.hasGposFeature(0, 0, tag("kern")));
    try std.testing.expect(!font.hasKerning());
}

test "the generic shaper is identity on a face with no layout tables" {
    var fbuf: [4096]u8 = undefined;
    const font = try Font.init(buildTestFont(&fbuf, false));
    const cps = [_]u21{ 0x41, 0x42 }; // 'A' 'B', both mapped
    var out: [4]u16 = @splat(0);
    var place: [4]opentype.Offset = @splat(.{});
    const n = try font.shape(&cps, &out, &place, .{});
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(try font.glyphIndex(0x41), out[0]);
    try std.testing.expectEqual(try font.glyphIndex(0x42), out[1]);
    try std.testing.expectEqual(@as(i16, 0), place[0].x);

    // An unknown script is not an error either: nothing applies, the glyphs stay.
    const n2 = try font.shape(&cps, &out, &place, .{ .script = tag("zzzz") });
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqual(try font.glyphIndex(0x41), out[0]);
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
    const m = try cache.mask(&font, gid, 16, .zero); // a hash lookup once warm

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
        _ = cache.mask(&font, gid, 13, .zero) catch {};
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
        .id = @backingInt(NameId.family),
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

test "lookup: a cached resolve agrees with the cmap and hmtx" {
    var buf: [1024]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));

    var mem: [Lookup.needed(.{})]u8 align(8) = undefined;
    var l = try Lookup.init(&mem, .{});

    for ([_]u21{ 'A', 'B', 'C', 0x1F600, 'A', 'z', 0x20 }) |cp| {
        const got = try l.resolve(&f, cp);
        try std.testing.expectEqual(try f.glyphIndex(cp), got.gid);
        try std.testing.expectEqual((try f.hMetrics(got.gid)).advance, got.advance);
    }
}

test "lookup: the second resolve is a hit, the first is not" {
    var buf: [1024]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));

    var mem: [Lookup.needed(.{})]u8 align(8) = undefined;
    var l = try Lookup.init(&mem, .{});

    _ = try l.resolve(&f, 'A');
    try std.testing.expectEqual(@as(u64, 1), l.stats.misses);
    try std.testing.expectEqual(@as(u64, 0), l.stats.hits);

    _ = try l.resolve(&f, 'A');
    _ = try l.resolve(&f, 'A');
    try std.testing.expectEqual(@as(u64, 1), l.stats.misses);
    try std.testing.expectEqual(@as(u64, 2), l.stats.hits);

    // resolve must not mutate the font or the entry it hands back.
    try std.testing.expectEqual(@as(u16, 6), (try l.resolve(&f, 'A')).gid);
}

test "lookup: eviction never returns another codepoint's glyph" {
    // Two slots and three codepoints force a collision and an eviction; every
    // resolve must still be right. This is the failure the table can actually
    // have -- a stale slot answering for a different character.
    var buf: [1024]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));

    var mem: [Lookup.needed(.{ .slots = 2 })]u8 align(8) = undefined;
    var l = try Lookup.init(&mem, .{ .slots = 2 });

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        for ([_]u21{ 'A', 'B', 'z' }) |cp| {
            const got = try l.resolve(&f, cp);
            try std.testing.expectEqual(try f.glyphIndex(cp), got.gid);
        }
    }
}

test "lookup: a buffer the size asked for is enough, anything less is refused" {
    const need = comptime Lookup.needed(.{ .slots = 16 });
    var mem: [need]u8 align(8) = undefined;
    try std.testing.expectEqual(@as(usize, 16 * @sizeOf(Lookup.Slot)), need);
    _ = try Lookup.init(&mem, .{ .slots = 16 });

    var small: [need - 1]u8 align(8) = undefined;
    try std.testing.expectError(error.BufferTooSmall, Lookup.init(&small, .{ .slots = 16 }));
    try std.testing.expectError(error.BufferTooSmall, Lookup.init(&mem, .{ .slots = 0 }));
}

test "post reads the italic angle and underline the face declares" {
    var buf: [2048]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));
    const p = f.post() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, -12.5), p.italic_angle);
    try std.testing.expectEqual(@as(i16, -100), p.underline_position);
    try std.testing.expectEqual(@as(i16, 50), p.underline_thickness);
    try std.testing.expect(!p.is_fixed_pitch);
}

test "post is decoration: absent or short reads as null, never as a bad face" {
    var buf: [2048]u8 = undefined;

    // Absent: the record is there but declares nothing.
    const font = buildTestFont(&buf, false);
    w32(buf[0..], recSpan(&buf, rec_post).len_at, 0);
    const absent = try Font.init(buf[0..font.len]);
    try std.testing.expect(absent.post() == null);

    // Present, but shorter than the header every version shares.
    const font2 = buildTestFont(&buf, false);
    w32(buf[0..], recSpan(&buf, rec_post).len_at, 16);
    const short = try Font.init(buf[0..font2.len]);
    try std.testing.expect(short.post() == null);
}

test "a composite flagging USE_MY_METRICS measures as its component" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    const glyf = recSpan(&buf, 1).off;
    // The composite is gid 7; its single component record starts after the
    // 10-byte glyph header.
    const comp_rec = glyf + 24 + 10;
    const comp_gid = comp_rec + 2;

    // gid 7's own metrics. Every glyph past numberOfHMetrics shares the last
    // advance, so a bearing alone would not be proof -- the component below is
    // pointed at gid 1, which differs in BOTH fields.
    {
        const f = try Font.init(buf[0..font.len]);
        try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 80 }, try f.hMetricsResolved(7));
    }

    // Same component placement, no flag: the composite keeps its own metrics.
    w16(buf[0..], comp_gid, 1);
    {
        const f = try Font.init(buf[0..font.len]);
        try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 80 }, try f.hMetricsResolved(7));
    }

    // Set the flag and the composite takes gid 1's metrics wholesale.
    w16(buf[0..], comp_rec, 0x0003 | 0x0200);
    {
        const f = try Font.init(buf[0..font.len]);
        try std.testing.expectEqual(HMetrics{ .advance = 600, .lsb = 20 }, try f.hMetricsResolved(7));
        try std.testing.expectEqual(HMetrics{ .advance = 600, .lsb = 20 }, try f.hMetricsResolved(1));

        // The raw read is not the resolved one, and that separation is the
        // point: a draw loop that never asks about the flag never pays for it.
        try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 80 }, try f.hMetrics(7));
    }

    // A component that flags the composite itself still terminates, and lands
    // on the composite's own metrics once the depth bound is reached.
    w16(buf[0..], comp_gid, 7);
    {
        const f = try Font.init(buf[0..font.len]);
        try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 80 }, try f.hMetricsResolved(7));
    }
}

test "the flag is per component, and only composites can carry it" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    const glyf = recSpan(&buf, 1).off;
    const comp_rec = glyf + 24 + 10;

    // A simple glyph has no component records to walk, so it always reports its
    // own metrics -- the walk must not read glyph data as if it were a record.
    {
        const f = try Font.init(buf[0..font.len]);
        try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 70 }, try f.hMetricsResolved(6));
    }

    // The flag on a component naming the composite's OWN metrics changes
    // nothing, which is the one case where "flag set" and "flag clear" have to
    // agree: gid 7 pointing at nothing it would inherit.
    w16(buf[0..], comp_rec, 0x0003 | 0x0200);
    {
        const f = try Font.init(buf[0..font.len]);
        // Component is gid 6, whose bearing differs from gid 7's.
        try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 70 }, try f.hMetricsResolved(7));
    }
}

test "post turns its numbers into a lean and a rule a renderer can use" {
    var buf: [2048]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));
    const p = f.post() orelse return error.TestUnexpectedResult;

    // -12.5 degrees leans right, so the shear is tan(+12.5).
    try std.testing.expectApproxEqAbs(@as(f32, 0.22169466), p.shear(), 1e-5);

    // The table's own numbers are usable here, so they are returned untouched.
    const u = f.underline() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i16, -100), u.position);
    try std.testing.expectEqual(@as(i16, 50), u.thickness);
}

test "post substitutes a rule for the nonsense fonts actually ship" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    // A zero thickness draws nothing and a position on the baseline detaches
    // the rule from the text. Both are common, and neither is worth honouring.
    const post_at = recSpan(&buf, rec_post).off;
    w32(buf[0..], post_at + 8, 0); // underlinePosition and underlineThickness
    const f = try Font.init(font);
    const u = f.underline() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i16, -102), u.position); // -1024 / 10
    try std.testing.expectEqual(@as(i16, 51), u.thickness); // 1024 / 20

    // An upright face has no lean to synthesise.
    w32(buf[0..], post_at + 4, 0);
    const upright = try Font.init(font);
    try std.testing.expectEqual(@as(f32, 0), (upright.post() orelse return error.TestUnexpectedResult).shear());
}

test "a scaled component offset is scaled, and the default is not" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    const glyf = recSpan(&buf, 1).off;
    // The same 18-byte component record, re-laid out: byte args plus one scale
    // instead of word args, so no other glyph moves and the record still ends
    // exactly where it did.
    const at = glyf + 24 + 10;
    w16(buf[0..], at, 0x0002 | 0x0008); // XY values, WE_HAVE_A_SCALE
    buf[at + 4] = 4; // dx
    buf[at + 5] = 6; // dy
    w16(buf[0..], at + 6, 0x2000); // scale 0.5

    var pts: [16]Point = undefined;
    var ends: [4]u16 = undefined;

    // Neither offset flag: the matrix scales the OUTLINE but not the offset, so
    // the triangle lands at 0.5 * p + (4, 6).
    {
        const f = try Font.init(font);
        const o = try f.outline(7, &pts, &ends);
        try std.testing.expectEqual(@as(usize, 3), o.points.len);
        try std.testing.expectEqual(Point{ .x = 4, .y = 6, .on = true }, o.points[0]);
        try std.testing.expectEqual(Point{ .x = 54, .y = 6, .on = true }, o.points[1]);
        try std.testing.expectEqual(Point{ .x = 29, .y = 56, .on = true }, o.points[2]);
    }

    // SCALED_COMPONENT_OFFSET: the offset rides through the matrix too, so it
    // becomes (0.5 * 4, 0.5 * 6) and the whole component moves.
    w16(buf[0..], at, 0x0002 | 0x0008 | 0x0800);
    {
        const f = try Font.init(font);
        const o = try f.outline(7, &pts, &ends);
        try std.testing.expectEqual(Point{ .x = 2, .y = 3, .on = true }, o.points[0]);
        try std.testing.expectEqual(Point{ .x = 52, .y = 3, .on = true }, o.points[1]);
        try std.testing.expectEqual(Point{ .x = 27, .y = 53, .on = true }, o.points[2]);
    }
}

test "Lookup stores the RESOLVED advance, so a hit cannot report a stale one" {
    var buf: [2048]u8 = undefined;
    const font = buildTestFont(&buf, false);
    const glyf = recSpan(&buf, 1).off;
    const comp_rec = glyf + 24 + 10;
    const comp_gid = comp_rec + 2;

    // The composite takes gid 1's metrics, which differ from its own in both
    // fields, and 'B' is repointed at the composite so it is reachable from a
    // codepoint the way a real accented letter would be.
    w16(buf[0..], comp_gid, 1);
    w16(buf[0..], comp_rec, 0x0003 | 0x0200);
    w16(buf[0..], recSpan(&buf, 0).off + 42, 0xFFC5); // idDelta[1]: 'B' -> gid 7

    const f = try Font.init(font);
    try std.testing.expectEqual(@as(u16, 7), try f.glyphIndex(0x42));

    // The two reads disagree, which is what makes the assertion below bite.
    try std.testing.expectEqual(HMetrics{ .advance = 700, .lsb = 80 }, try f.hMetrics(7));
    try std.testing.expectEqual(HMetrics{ .advance = 600, .lsb = 20 }, try f.hMetricsResolved(7));

    var mem: [Lookup.needed(.{ .slots = 16 })]u8 align(8) = undefined;
    var l = try Lookup.init(&mem, .{ .slots = 16 });

    const first = try l.resolve(&f, 0x42);
    try std.testing.expectEqual(@as(u16, 7), first.gid);
    try std.testing.expectEqual(@as(u16, 600), first.advance);
    try std.testing.expectEqual(@as(u32, 1), l.stats.misses);

    // Served from the slot, and still the resolved number.
    const again = try l.resolve(&f, 0x42);
    try std.testing.expectEqual(@as(u16, 600), again.advance);
    try std.testing.expectEqual(@as(u32, 1), l.stats.hits);
}

test {
    // A sibling file's tests only join the module's test binary if something
    // references its declarations -- the same reason elmz keeps this line.
    std.testing.refAllDecls(@import("opentype.zig"));
}

test "a variable face moves a glyph's points where it is decoded" {
    var buf: [4096]u8 = undefined;
    const f = try Font.init(buildVarTestFont(&buf));
    var pa: [64]Point = undefined;
    var ea: [16]u16 = undefined;

    // The default instance leaves the gvar deltas parked.
    const flat = try f.outline(6, &pa, &ea);
    try std.testing.expectEqual(@as(usize, 3), flat.points.len);
    try std.testing.expectEqual(@as(i32, 0), flat.points[0].x);
    try std.testing.expectEqual(@as(i32, 100), flat.points[1].x);
    try std.testing.expectEqual(@as(i32, 100), flat.points[2].y);

    // wght 700 is the axis peak, so the scalar is exactly 1: point deltas are
    // (40,0) (-20,30) (10,-10) on a triangle of (0,0) (100,0) (50,100).
    const user = [_]f32{700};
    const vf = f.withCoords(&user);
    const o = try vf.outline(6, &pa, &ea);
    try std.testing.expectEqual(@as(i32, 40), o.points[0].x);
    try std.testing.expectEqual(@as(i32, 0), o.points[0].y);
    try std.testing.expectEqual(@as(i32, 80), o.points[1].x);
    try std.testing.expectEqual(@as(i32, 30), o.points[1].y);
    try std.testing.expectEqual(@as(i32, 60), o.points[2].x);
    try std.testing.expectEqual(@as(i32, 90), o.points[2].y);
}

test "a composite follows its varied component through a short offset table" {
    var buf: [4096]u8 = undefined;
    const f = try Font.init(buildVarTestFont(&buf));
    const user = [_]f32{700};
    const vf = f.withCoords(&user);
    var pa: [64]Point = undefined;
    var ea: [16]u16 = undefined;

    // gid 7 is gid 6 shifted by (200,0) with no deltas of its own, so every
    // point must land 200 past the varied child's. This is also the regression
    // for the short-offset stride: indexed with the wrong stride the child's
    // tuples are found at the wrong byte and nothing moves at all.
    const c = try vf.outline(7, &pa, &ea);
    try std.testing.expectEqual(@as(usize, 3), c.points.len);
    try std.testing.expectEqual(@as(i32, 240), c.points[0].x);
    try std.testing.expectEqual(@as(i32, 280), c.points[1].x);
    try std.testing.expectEqual(@as(i32, 30), c.points[1].y);
    try std.testing.expectEqual(@as(i32, 260), c.points[2].x);
    try std.testing.expectEqual(@as(i32, 90), c.points[2].y);
}

test "a halfway instance rounds a delta half up, not away from zero" {
    var buf: [4096]u8 = undefined;
    const f = try Font.init(buildVarTestFont(&buf));
    // 550 normalises to 0.5, avar maps that to 0.6, and the F2Dot14 grid makes
    // it 9830/16384 = 0.599976. So -20 scales to -11.9995, which must give -12:
    // floor(v + 0.5). Rounding away from zero would have said -13.
    const user = [_]f32{550};
    const vf = f.withCoords(&user);
    var pa: [64]Point = undefined;
    var ea: [16]u16 = undefined;
    const o = try vf.outline(6, &pa, &ea);
    try std.testing.expectEqual(@as(i32, 24), o.points[0].x);
    try std.testing.expectEqual(@as(i32, 88), o.points[1].x);
    try std.testing.expectEqual(@as(i32, 18), o.points[1].y);
    try std.testing.expectEqual(@as(i32, 56), o.points[2].x);
    try std.testing.expectEqual(@as(i32, 94), o.points[2].y);
}

test "a cached kern gives the same advances and refuses a foreign face" {
    var buf: [65536]u8 = undefined;
    const f = try Font.init(buildTestFont(&buf, false));

    const text = "AVTo";
    var cps: [8]u21 = undefined;
    for (text, 0..) |ch, i| cps[i] = ch;

    var a: [8]u16 = undefined;
    var adv_a: [8]i32 = undefined;
    _ = try f.shape(cps[0..text.len], a[0..], null, .{ .advances = adv_a[0..] });

    var mem: [Kern.needed(.{})]u8 align(8) = undefined;
    const cached = Kern.init(&mem, f, .{});
    var b: [8]u16 = undefined;
    var adv_b: [8]i32 = undefined;
    _ = try f.shape(cps[0..text.len], b[0..], null, .{ .advances = adv_b[0..], .kern_cache = &cached });

    try std.testing.expectEqualSlices(u16, a[0..text.len], b[0..text.len]);
    try std.testing.expectEqualSlices(i32, adv_a[0..text.len], adv_b[0..text.len]);

    // A cache built from a DIFFERENT face must be ignored rather than applied:
    // its lookup indices address another font's tables.
    var buf2: [65536]u8 = undefined;
    const f2 = try Font.init(buildTestFont(&buf2, true));
    var mem2: [Kern.needed(.{})]u8 align(8) = undefined;
    const foreign = Kern.init(&mem2, f2, .{});
    var c2: [8]u16 = undefined;
    var adv_c: [8]i32 = undefined;
    _ = try f.shape(cps[0..text.len], c2[0..], null, .{ .advances = adv_c[0..], .kern_cache = &foreign });
    try std.testing.expectEqualSlices(i32, adv_a[0..text.len], adv_c[0..text.len]);
}

// ---------------------------------------------------------------------------
// a CFF face, for the paths that must not assume `glyf`
// ---------------------------------------------------------------------------

/// A minimal OTTO face: `CFF ` outlines and no `glyf`/`loca` at all. Four
/// glyphs, of which the first two carry a full `hmtx` record and the rest share
/// the last advance plus a bearing, so both branches of the metric read are
/// reachable.
fn buildCffTestFont(buf: []u8) []const u8 {
    const ntables: usize = 6;
    var w = W{ .buf = buf };

    w.u32v(tag("OTTO")); // sfnt version
    w.u16v(@intCast(ntables)); // numTables
    w.u16v(0);
    w.u16v(0);
    w.u16v(0);
    w.zeros(ntables * 16); // table records, patched at the end

    // --- cmap: format 4, A -> gid 1 and B -> gid 2 ---
    const cmap_start = w.at;
    w.u16v(0); // version
    w.u16v(1); // numTables
    const rec0 = w.at;
    w.u16v(3); // platform
    w.u16v(1); // encoding
    w.u32v(0); // offset, patched
    const f4 = w.at;
    w.u16v(4); // format
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
    w.i16v(0); // idDelta[0] -- the glyphIdArray entry already names the glyph
    w.i16v(@bitCast(@as(u16, 0xFFC0))); // idDelta[1]
    w.i16v(1); // idDelta[2]
    w.u16v(6); // idRangeOffset[0]
    w.u16v(0);
    w.u16v(0);
    w.u16v(1); // glyphIdArray[0]
    w16(buf, len4_at, @intCast(w.at - f4));
    w32(buf, rec0 + 4, @intCast(f4 - cmap_start));
    const r_cmap = Rec{ .at = cmap_start, .len = w.at - cmap_start };

    // --- CFF: header, Name INDEX, Top DICT INDEX, empty String and Global Subr
    // INDEXes, then the CharStrings INDEX with its offset patched back in ---
    const cff_start = w.at;
    w.u8v(1); // major
    w.u8v(0); // minor
    w.u8v(4); // hdrSize
    w.u8v(1); // offSize
    w.u16v(1); // Name INDEX: one entry
    w.u8v(1); // offSize
    w.u8v(1);
    w.u8v(5);
    for ("Test") |c| w.u8v(c);
    w.u16v(1); // Top DICT INDEX: one entry
    w.u8v(1); // offSize
    w.u8v(1);
    w.u8v(7); // 1 + 6 bytes of DICT
    w.u8v(29); // 32-bit operand follows
    const cs_off_at = w.at;
    w.u32v(0); // CharStrings offset, patched
    w.u8v(17); // op char_strings
    w.u16v(0); // String INDEX: empty
    w.u16v(0); // Global Subr INDEX: empty
    const cs_at = w.at;
    w.u16v(4); // CharStrings INDEX: four glyphs
    w.u8v(1); // offSize
    w.u8v(1);
    w.u8v(4); // 1 + "abc"
    w.u8v(6); // 4 + "de"
    w.u8v(6); // then two empty
    w.u8v(6);
    for ("abc") |c| w.u8v(c);
    for ("de") |c| w.u8v(c);
    w32(buf, cs_off_at, @intCast(cs_at - cff_start));
    const r_cff = Rec{ .at = cff_start, .len = w.at - cff_start };

    // --- head (54 bytes) ---
    const head_start = w.at;
    w.u32v(0x0001_0000);
    w.u32v(0x0001_0000);
    w.u32v(0);
    w.u32v(0x5F0F_3CF5);
    w.u16v(0);
    w.u16v(1000); // unitsPerEm
    w.zeros(16); // created, modified
    w.zeros(8); // bbox
    w.u16v(0); // macStyle
    w.u16v(8); // lowestRecPPEM
    w.i16v(2); // fontDirectionHint
    w.i16v(0); // indexToLocFormat
    w.i16v(0); // glyphDataFormat
    const r_head = Rec{ .at = head_start, .len = w.at - head_start };

    // --- hhea (36 bytes) ---
    const hhea_start = w.at;
    w.u32v(0x0001_0000);
    w.i16v(880); // ascender
    w.i16v(-120); // descender
    w.i16v(0); // lineGap
    w.u16v(600); // advanceWidthMax
    w.zeros(6);
    w.zeros(6);
    w.zeros(8);
    w.i16v(0); // metricDataFormat
    w.u16v(2); // numberOfHMetrics
    const r_hhea = Rec{ .at = hhea_start, .len = w.at - hhea_start };

    // --- hmtx: two full records, then bearings for glyphs 2 and 3 ---
    const hmtx_start = w.at;
    w.u16v(600);
    w.i16v(10);
    w.u16v(500);
    w.i16v(20);
    w.i16v(30);
    w.i16v(40);
    const r_hmtx = Rec{ .at = hmtx_start, .len = w.at - hmtx_start };

    // --- maxp 0.5 (6 bytes) ---
    const maxp_start = w.at;
    w.u32v(0x0000_5000);
    w.u16v(4); // numGlyphs
    const r_maxp = Rec{ .at = maxp_start, .len = w.at - maxp_start };

    const tags: [ntables]u32 = .{ tag_cmap, tag_cff, tag_head, tag_hhea, tag_hmtx, tag_maxp };
    const recs: [ntables]Rec = .{ r_cmap, r_cff, r_head, r_hhea, r_hmtx, r_maxp };
    for (tags, recs, 0..) |t, r, i| patchRec(buf, 12 + i * 16, t, r.at, r.len);

    return buf[0..w.at];
}

test "a CFF face resolves advances without glyf composite records" {
    var buf: [4096]u8 = undefined;
    const f = try Font.init(buildCffTestFont(&buf));
    try std.testing.expect(f.is_cff);
    try std.testing.expectEqual(@as(u16, 4), f.num_glyphs);

    // Glyphs inside `numberOfHMetrics` carry their own advance ...
    try std.testing.expectEqual(@as(u16, 600), (try f.hMetricsResolved(0)).advance);
    try std.testing.expectEqual(@as(u16, 500), (try f.hMetricsResolved(1)).advance);
    // ... and the rest inherit the last one.
    try std.testing.expectEqual(@as(u16, 500), (try f.hMetricsResolved(3)).advance);

    // The codepoint path is what a caller actually uses.
    try std.testing.expectEqual(@as(u16, 1), try f.glyphIndex(0x41));
}

test "a full slot table recycles a mask instead of flushing every class" {
    // The table had its own cliff, one level up from the arena's: when no slot
    // was free, `flush` emptied ALL FOUR classes. Measured on NotoSansCJKsc
    // with an 8 MiB arena -- pixels nowhere near full -- 1000 distinct glyphs
    // against 512 slots scored 0.0% hits and 2000 against 1024 scored 0.0%.
    // The arena was never the constraint there; the table was.
    //
    // Recycling keeps the two limits in step: an evicted mask returns both its
    // slot and its extent.
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));
    const upem: f32 = @floatFromInt(font.units_per_em);

    // Six distinct entries from one inked glyph: the key covers scale. Sorted
    // LARGEST FIRST so that every incoming mask has an older mask big enough
    // to recycle -- otherwise the test would exercise the fallback wipe and
    // prove the opposite of what it claims.
    const Sizes = struct { ppem: u16, len: usize };
    var sizes = [_]Sizes{ .{ .ppem = 24, .len = 0 }, .{ .ppem = 22, .len = 0 }, .{ .ppem = 20, .len = 0 }, .{ .ppem = 18, .len = 0 }, .{ .ppem = 16, .len = 0 }, .{ .ppem = 14, .len = 0 } };
    for (&sizes) |*e| {
        const b = try font.bitmapBox(6, @as(f32, @floatFromInt(e.ppem)) / upem, 0);
        e.len = @intCast((b.x1 - b.x0) * (b.y1 - b.y0));
    }
    std.mem.sort(Sizes, &sizes, {}, struct {
        fn gt(_: void, x: Sizes, y: Sizes) bool {
            return x.len > y.len or (x.len == y.len and x.ppem > y.ppem);
        }
    }.gt);

    const opts = Cache.Options{ .slots = 4, .max_points = 256, .max_edges = 256, .max_width = 64, .arena = 4096 };
    var cbuf: [64 * 1024]u8 align(8) = undefined;
    const mem: []align(8) u8 = @alignCast(cbuf[0..Cache.needed(opts)]);
    var cache = try Cache.init(mem, opts);
    try std.testing.expect(!cache.partitioned);

    for (sizes) |e| _ = try cache.mask(&font, 6, e.ppem, .zero);
    try std.testing.expectEqual(@as(u64, 6), cache.stats.misses);
    // The whole point: six masks through four slots without a single wipe.
    try std.testing.expectEqual(@as(u64, 0), cache.stats.flushes);

    // Capacity 4, six inserted, so the two oldest gave way and the four most
    // recent are live. Under a flush only the newest would survive.
    _ = try cache.mask(&font, 6, sizes[2].ppem, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);

    // And the oldest really did go, so the hit above is not vacuous.
    _ = try cache.mask(&font, 6, sizes[0].ppem, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 7), cache.stats.misses);
}

test "arenaFor sizes from a working set, quadratically in point size" {
    // Pins the calibration, not the cache. The fixture has two glyphs with ink,
    // so a run of thousands is not available here; what is worth pinning is the
    // constant, because a wrong one is silent -- a caller would size a buffer
    // that looks right and caches a fraction of the screen.
    //
    // 2000 CJK glyphs at 16px needed 2 MiB when measured.
    try std.testing.expectEqual(@as(u32, 2000 * 4 * 16 * 16), Cache.arenaFor(2000, 16));
    try std.testing.expectEqual(@as(u32, 2_048_000), Cache.arenaFor(2000, 16));

    // Area, not length: 24px is about twice 16px, not 1.5 times.
    const per16 = Cache.arenaFor(1000, 16);
    const per24 = Cache.arenaFor(1000, 24);
    try std.testing.expect(per24 > per16 * 2);

    // Linear in glyph count, and zero is zero rather than a minimum.
    try std.testing.expectEqual(Cache.arenaFor(1000, 16) * 2, Cache.arenaFor(2000, 16));
    try std.testing.expectEqual(@as(u32, 0), Cache.arenaFor(0, 16));

    // Absurd inputs clamp instead of wrapping into a tiny arena.
    try std.testing.expectEqual(std.math.maxInt(u32), Cache.arenaFor(1 << 30, 65535));

    // The default arena is far too small for a CJK screen, which is the whole
    // reason this function exists.
    try std.testing.expect(Cache.arenaFor(2000, 16) > (Cache.Options{}).arena * 4);
}

test "adjustAdvances zeroes its output even when the face has no GPOS" {
    // The zeroing is the real assertion. A caller reuses one buffer across
    // runs, so leaving stale numbers in place would apply the previous run's
    // adjustments to the next line of text -- silently, and only visibly on
    // the second draw.
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));

    var out = [_]opentype.Adjust{ .{ .x_advance = 99 }, .{ .x_advance = 99 } };
    const gids = [_]u16{ 6, 7 };
    const n = font.adjustAdvances(&gids, &out, &.{opentype.tag("palt")}, .{});
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expectEqual(@as(i16, 0), out[0].x_advance);
    try std.testing.expectEqual(@as(i16, 0), out[1].x_advance);

    // An empty run is not an error either.
    try std.testing.expectEqual(@as(usize, 0), font.adjustAdvances(&.{}, &out, &.{opentype.tag("palt")}, .{}));
}

test "a language system is reachable only when the caller names one" {
    var fbuf: [2048]u8 = undefined;
    const font = try Font.init(buildLangsysTestFont(&fbuf));
    try std.testing.expect(font.gsub_span.len != 0);

    const dflt = opentype.tag("DFLT");
    const jan = opentype.tag("JAN ");

    // The fixture's `locl` lookup turns the glyph for 'A' into gid 2. Pin the
    // cmap coupling explicitly, so a change to the fixture's cmap fails HERE
    // with the reason, rather than as a mysterious "expected 1, found 6".
    const a = try font.glyphIndex(0x41);
    try std.testing.expectEqual(@as(u16, 6), a);

    const cps = [_]u21{0x41};
    var out: [4]u16 = @splat(0);

    // The fixture has NO default LangSys, so naming no language cannot reach
    // the feature and the glyph has to come back untouched. This is the whole
    // reason `locl` needs a language at all: a real CJK face puts it ONLY under
    // the regional LangSys records.
    var n = try font.shape(&cps, &out, null, .{ .script = dflt });
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(a, out[0]);

    // Naming the language system opens it.
    out = @splat(0);
    n = try font.shape(&cps, &out, null, .{ .script = dflt, .lang = jan });
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, 2), out[0]);

    // A language the face does not carry behaves like naming none. Without this
    // a lookup that ignored `lang` entirely would still pass the two cases
    // above, because the fixture would substitute on both.
    out = @splat(0);
    _ = try font.shape(&cps, &out, null, .{ .script = dflt, .lang = opentype.tag("ZHS ") });
    try std.testing.expectEqual(a, out[0]);
}

test "caller-named features run after the default set, not instead of it" {
    var fbuf: [2048]u8 = undefined;
    const font = try Font.init(buildLangsysTestFont(&fbuf));

    const dflt = opentype.tag("DFLT");
    const jan = opentype.tag("JAN ");
    const cps = [_]u21{0x41};
    var out: [4]u16 = @splat(0);
    const a = try font.glyphIndex(0x41);

    // `locl` is in the default set, so a language alone reaches it: 6 -> 2.
    _ = try font.shape(&cps, &out, null, .{ .script = dflt, .lang = jan });
    try std.testing.expectEqual(@as(u16, 2), out[0]);

    // Naming a feature does NOT replace that set. `fwid` is not in the default
    // list, so it runs only because it was named -- and it lands on gid 2,
    // which exists only because `locl` already ran. Result 3 therefore proves
    // defaults-then-extras; extras-first would have left gid 6 for `locl` to
    // turn into 2.
    out = @splat(0);
    const only_fwid = [_]u32{opentype.tag("fwid")};
    _ = try font.shape(&cps, &out, null, .{ .script = dflt, .lang = jan, .features = &only_fwid });
    try std.testing.expectEqual(@as(u16, 3), out[0]);

    // A tag the face does not carry is a no-op rather than an error, and it
    // must not disturb the default set either.
    out = @splat(0);
    const only_liga = [_]u32{opentype.tag("liga")};
    _ = try font.shape(&cps, &out, null, .{ .script = dflt, .lang = jan, .features = &only_liga });
    try std.testing.expectEqual(@as(u16, 2), out[0]);

    // Sanity: without the language, none of it is reachable, extras included.
    out = @splat(0);
    _ = try font.shape(&cps, &out, null, .{ .script = dflt, .features = &only_fwid });
    try std.testing.expectEqual(a, out[0]);
}

test "a full class recycles one victim instead of wiping every mask" {
    // The cliff this guards: `evictClass` marked every live mask of the class
    // dead, so one mask past the budget threw away the whole working set.
    // Measured on NotoSansCJKsc at 16px that was 99.8% -> 9.1% hits between
    // 400 and 405 distinct glyphs -- five glyphs of overflow costing ninety
    // points. A cache that re-rasterises everything after each overflow is not
    // a slow cache, it is a cache that has stopped being one.
    //
    // The fixture has only two glyphs with ink, so the three entries come from
    // one glyph at three sizes: the key covers scale, which is exactly what
    // makes them distinct masks.
    //
    // NOTE the arena is sized by the BUFFER, not by `Options.arena`: the cache
    // claims every byte past its tables, and `arena` only tells `needed()` how
    // much to ask for. Handing it a larger array silently grants a larger
    // arena, which is how a first version of this test ended up never evicting
    // anything. Every buffer here is cut to exactly `needed()`.
    var fb: [2048]u8 = undefined;
    const font = try Font.init(buildTestFont(&fb, false));

    const upem: f32 = @floatFromInt(font.units_per_em);
    const b24 = try font.bitmapBox(6, 24 / upem, 0);
    const b20 = try font.bitmapBox(6, 20 / upem, 0);
    const b16 = try font.bitmapBox(6, 16 / upem, 0);
    const l24: usize = @intCast((b24.x1 - b24.x0) * (b24.y1 - b24.y0));
    const l20: usize = @intCast((b20.x1 - b20.x0) * (b20.y1 - b20.y0));
    const l16: usize = @intCast((b16.x1 - b16.x0) * (b16.y1 - b16.y0));
    // Capacity for exactly the first two. The third cannot be admitted without
    // giving something up, and the FIRST mask is the one that must go.
    try std.testing.expect(l24 >= l16 and l20 >= l16);

    const opts = Cache.Options{ .slots = 16, .max_points = 256, .max_edges = 256, .max_width = 64, .arena = @intCast(l24 + l20) };
    var cbuf: [64 * 1024]u8 align(8) = undefined;
    const mem: []align(8) u8 = @alignCast(cbuf[0..Cache.needed(opts)]);
    var cache = try Cache.init(mem, opts);
    // Under `partition_min` the cache is one pool, so the capacity above is the
    // whole budget and the arithmetic in this test is the real arithmetic.
    try std.testing.expect(!cache.partitioned);

    _ = try cache.mask(&font, 6, 24, .zero);
    const mid = try cache.mask(&font, 6, 20, .zero);
    var mid_pixels: [2048]u8 = undefined;
    @memcpy(mid_pixels[0..mid.pixels.len], mid.pixels);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.misses);

    _ = try cache.mask(&font, 6, 16, .zero);
    try std.testing.expectEqual(@as(u64, 3), cache.stats.misses);

    // The 20px mask is the second-oldest of three, so an LRU eviction spares
    // it. Under a class wipe it is gone and this is a miss.
    const again = try cache.mask(&font, 6, 20, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 3), cache.stats.misses);
    // Recycling an extent must not disturb a live neighbour's pixels.
    try std.testing.expectEqualSlices(u8, mid_pixels[0..again.pixels.len], again.pixels);

    // The oldest mask DID give way -- otherwise the hit above would be
    // explained by nothing having been evicted at all.
    _ = try cache.mask(&font, 6, 24, .zero);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 4), cache.stats.misses);
}
