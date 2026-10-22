//! OpenType layout: the substrate GPOS and GSUB are both made of.
//!
//! Coverage, ClassDef, the script -> langsys -> feature -> lookup indirection
//! and ValueRecords live here once. Two copies would be two sets of bugs.
//!
//! Everything is bounds-checked and allocator-free. A malformed table makes a
//! lookup return nothing; `init` refuses a header whose lists do not fit.
//!
//! Deliberately absent for now, each because it needs machinery this layer
//! does not have yet: contextual lookups (GPOS 7/8, GSUB 5/6), GDEF mark
//! filtering, Device tables (hint-time only, and we do not hint), and
//! FeatureVariations (variable fonts).

const std = @import("std");

pub const Error = error{ Truncated, MissingTable, BufferTooSmall };

/// Big-endian four-character tag, the same encoding `glyfz.tag` produces.
pub fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// What a ValueRecord can say. Device offsets are read past, not applied.
/// Where a mark sits relative to the glyph it attaches to, in font units.
pub const Offset = struct { x: i16 = 0, y: i16 = 0 };

/// GDEF, only as much of it as matching needs: which glyphs are marks, so a
/// lookup flagged IgnoreMarks can step over them instead of being blocked.
pub const Gdef = struct {
    data: []const u8,
    class_def: usize = 0, // absolute offset, 0 when the table has none

    pub fn init(data: []const u8, off: u32, len: u32) Error!Gdef {
        if (data.len < off + len or len < 12) return error.Truncated;
        var g: Gdef = .{ .data = data };
        const rel = try u16At(data, off + 4);
        if (rel != 0) g.class_def = off + rel;
        return g;
    }

    pub fn classOf(self: Gdef, gid: u16) Error!u16 {
        if (self.class_def == 0) return 0;
        const at = self.class_def;
        switch (try u16At(self.data, at)) {
            1 => {
                const start = try u16At(self.data, at + 2);
                const count = try u16At(self.data, at + 4);
                if (gid < start or gid >= start + count) return 0;
                return try u16At(self.data, at + 6 + @as(usize, gid - start) * 2);
            },
            2 => {
                const count = try u16At(self.data, at + 2);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const rec = at + 4 + i * 6;
                    const lo = try u16At(self.data, rec);
                    const hi = try u16At(self.data, rec + 2);
                    if (gid >= lo and gid <= hi) return try u16At(self.data, rec + 4);
                }
                return 0;
            },
            else => return 0,
        }
    }

    /// Class 3 is "mark" in GDEF's GlyphClassDef.
    pub fn isMark(self: Gdef, gid: u16) Error!bool {
        return (try self.classOf(gid)) == 3;
    }
};

pub const Adjust = struct {
    x_placement: i16 = 0,
    y_placement: i16 = 0,
    x_advance: i16 = 0,
    y_advance: i16 = 0,

    pub fn isZero(self: Adjust) bool {
        return self.x_placement == 0 and self.y_placement == 0 and
            self.x_advance == 0 and self.y_advance == 0;
    }

    /// Wrapping: a font with absurd values must not panic a caller.
    pub fn add(lhs: Adjust, rhs: Adjust) Adjust {
        return .{
            .x_placement = lhs.x_placement +% rhs.x_placement,
            .y_placement = lhs.y_placement +% rhs.y_placement,
            .x_advance = lhs.x_advance +% rhs.x_advance,
            .y_advance = lhs.y_advance +% rhs.y_advance,
        };
    }
};

/// Bytes a ValueRecord occupies, given the subtable's valueFormat.
pub fn valueSize(vf: u16) usize {
    return 2 * @as(usize, @popCount(vf & 0x00FF));
}

/// One GPOS or GSUB table, addressed over the caller's font bytes.
pub const Layout = struct {
    data: []const u8,
    gdef: ?Gdef = null,
    script_list: usize,
    feature_list: usize,
    lookup_list: usize,

    pub fn init(data: []const u8, off: u32, len: u32) Error!Layout {
        const base: usize = off;
        const end: usize = base + @as(usize, len);
        if (len < 10 or end > data.len) return error.Truncated;
        const major = try u16At(data, base);
        // 1.1 shares the header shape and only adds FeatureVariations, which
        // this layer does not read, so the version is not a gate at 1.x.
        if (major != 1) return error.MissingTable;
        const sl = try u16At(data, base + 4);
        const fl = try u16At(data, base + 6);
        const ll = try u16At(data, base + 8);
        return .{
            .data = data,
            .script_list = try inside(base, end, sl),
            .feature_list = try inside(base, end, fl),
            .lookup_list = try inside(base, end, ll),
        };
    }

    /// Lookup indices for `feat` under `script`/`lang`, sorted so the caller
    /// applies them in lookup-list order. An absent script, an absent langsys
    /// or a langsys without that feature all give an empty slice; they are not
    /// errors, because "this font does not kern this script" is a real answer.
    pub fn featureLookups(self: Layout, script: u32, lang: u32, feat: u32, out: []u16) Error![]u16 {
        var n: usize = 0;
        const langs = try self.langsys(script, lang) orelse return out[0..0];
        const count = try u16At(self.data, langs + 4);
        const idxs = langs + 6;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const fi = try u16At(self.data, idxs + i * 2);
            const rec = self.feature_list + 2 + @as(usize, fi) * 6;
            const ftag = try u32At(self.data, rec);
            if (ftag != feat) continue;
            const feature = self.feature_list + try u16At(self.data, rec + 4);
            const lookup_count = try u16At(self.data, feature + 2);
            var k: usize = 0;
            while (k < lookup_count) : (k += 1) {
                if (n == out.len) break;
                out[n] = try u16At(self.data, feature + 4 + k * 2);
                n += 1;
            }
        }
        return sortUnique(out[0..n]);
    }

    /// `featureLookups` for a script chosen when the caller has no text
    /// context: `latn`, then DFLT, then each script in file order.
    ///
    /// `latn` first is not a Latin bias for its own sake, it is what the fonts
    /// do: DejaVu Sans puts ONE class-based kern lookup under DFLT and the two
    /// real ones under `latn`, so a DFLT-first policy silently loses most of
    /// its kerning. A caller that knows the script -- which is what an Arabic
    /// or Indic app will -- calls `featureLookups` directly and this policy
    /// never runs.
    pub fn featureLookupsDefault(self: Layout, feat: u32, out: []u16) Error![]u16 {
        const latn = try self.featureLookups(tag("latn"), 0, feat, out);
        if (latn.len != 0) return latn;
        const dflt = try self.featureLookups(tag("DFLT"), 0, feat, out);
        if (dflt.len != 0) return dflt;
        const count = try u16At(self.data, self.script_list);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const st = try u32At(self.data, self.script_list + 2 + i * 6);
            const got = try self.featureLookups(st, 0, feat, out);
            if (got.len != 0) return got;
        }
        return out[0..0];
    }

    /// Absolute offset of the LangSys for `script`/`lang`, or the script's
    /// default when `lang` has no record.
    fn langsys(self: Layout, script: u32, lang: u32) Error!?usize {
        const count = try u16At(self.data, self.script_list);
        var i: usize = 0;
        var script_abs: ?usize = null;
        while (i < count) : (i += 1) {
            const rec = self.script_list + 2 + i * 6;
            if (try u32At(self.data, rec) != script) continue;
            script_abs = self.script_list + try u16At(self.data, rec + 4);
            break;
        }
        const s = script_abs orelse return null;

        if (lang != 0) {
            const lang_count = try u16At(self.data, s + 2);
            var j: usize = 0;
            while (j < lang_count) : (j += 1) {
                const rec = s + 4 + j * 6;
                if (try u32At(self.data, rec) != lang) continue;
                return s + try u16At(self.data, rec + 4);
            }
        }
        const def = try u16At(self.data, s);
        if (def == 0) return null;
        return s + def;
    }

    /// Sum of every PairPos adjustment the given lookups have for this pair.
    ///
    /// The LEFT glyph's records only: valueFormat2 adjusts the glyph that
    /// follows, and a pair lookup that wants to move the right glyph needs a
    /// positioned sequence, not a pair. Extension (type 9) wrappers are
    /// unwrapped, because large fonts cannot express themselves without them.
    pub fn pairAdjust(self: Layout, lookups: []const u16, left: u16, right: u16) Adjust {
        var total: Adjust = .{};
        for (lookups) |li| {
            total = total.add(self.pairAdjustLookup(li, left, right) catch Adjust{});
        }
        return total;
    }

    fn pairAdjustLookup(self: Layout, index: u16, left: u16, right: u16) Error!Adjust {
        const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, index) * 2);
        const kind = try u16At(self.data, lookup);
        const sub_count = try u16At(self.data, lookup + 4);
        var total: Adjust = .{};
        var i: usize = 0;
        while (i < sub_count) : (i += 1) {
            const sub = lookup + try u16At(self.data, lookup + 6 + i * 2);
            switch (kind) {
                2 => total = total.add(try self.pairAt(sub, left, right)),
                9 => {
                    // Long offsets live in their own subtable; unwrap and go on.
                    const inner_kind = try u16At(self.data, sub + 2);
                    const inner = sub + try u32At(self.data, sub + 4);
                    if (inner_kind == 2) total = total.add(try self.pairAt(inner, left, right));
                },
                else => {},
            }
        }
        return total;
    }

    /// One PairPos subtable (format 1 or 2), for a pair.
    fn pairAt(self: Layout, abs: usize, left: u16, right: u16) Error!Adjust {
        const fmt = try u16At(self.data, abs);
        const cov = abs + try u16At(self.data, abs + 2);
        const vf1 = try u16At(self.data, abs + 4);
        const vf2 = try u16At(self.data, abs + 6);
        const s1 = valueSize(vf1);
        const s2 = valueSize(vf2);

        switch (fmt) {
            1 => {
                const set_count = try u16At(self.data, abs + 8);
                const idx = (try self.coverageIndex(cov, left)) orelse return .{};
                if (idx >= set_count) return .{};
                const set = abs + try u16At(self.data, abs + 10 + @as(usize, idx) * 2);
                const n = try u16At(self.data, set);
                const rec = 2 + s1 + s2;
                // PairValueRecords are sorted by secondGlyph, by the spec.
                var lo: usize = 0;
                var hi: usize = n;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const at = set + 2 + mid * rec;
                    const g = try u16At(self.data, at);
                    if (g < right) {
                        lo = mid + 1;
                    } else if (g > right) {
                        hi = mid;
                    } else {
                        return self.readValue(at + 2, vf1);
                    }
                }
                return .{};
            },
            2 => {
                // Class 0 is a real matrix row -- glyphs outside the ClassDef
                // land there, and fonts put real values in it -- so unlike the
                // coverage index it is not a reason to bail.
                if (try self.coverageIndex(cov, left) == null) return .{};
                const cd1 = abs + try u16At(self.data, abs + 8);
                const cd2 = abs + try u16At(self.data, abs + 10);
                const n1 = try u16At(self.data, abs + 12);
                const n2 = try u16At(self.data, abs + 14);
                const c1 = try self.classOf(cd1, left);
                const c2 = try self.classOf(cd2, right);
                if (c1 >= n1 or c2 >= n2) return .{};
                const rec = s1 + s2;
                const at = abs + 16 + (@as(usize, c1) * n2 + c2) * rec;
                return self.readValue(at, vf1);
            },
            else => return .{},
        }
    }

    fn readValue(self: Layout, at: usize, vf: u16) Error!Adjust {
        var a: Adjust = .{};
        var p = at;
        if (vf & 0x0001 != 0) {
            a.x_placement = try i16At(self.data, p);
            p += 2;
        }
        if (vf & 0x0002 != 0) {
            a.y_placement = try i16At(self.data, p);
            p += 2;
        }
        if (vf & 0x0004 != 0) {
            a.x_advance = try i16At(self.data, p);
            p += 2;
        }
        if (vf & 0x0008 != 0) {
            a.y_advance = try i16At(self.data, p);
            p += 2;
        }
        // Device/VariationIndex offsets (0x10..0x80) are hint-time and are
        // skipped, not followed; valueSize accounts for their width.
        return a;
    }

    /// Coverage index of `gid`, or null when the glyph is not covered.
    pub fn coverageIndex(self: Layout, abs: usize, gid: u16) Error!?u16 {
        const fmt = try u16At(self.data, abs);
        const n = try u16At(self.data, abs + 2);
        var lo: usize = 0;
        var hi: usize = n;
        switch (fmt) {
            1 => {
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const g = try u16At(self.data, abs + 4 + mid * 2);
                    if (g < gid) {
                        lo = mid + 1;
                    } else if (g > gid) {
                        hi = mid;
                    } else {
                        return @intCast(mid);
                    }
                }
                return null;
            },
            2 => {
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const r = abs + 4 + mid * 6;
                    const start = try u16At(self.data, r);
                    const last = try u16At(self.data, r + 2);
                    if (gid < start) {
                        hi = mid;
                    } else if (gid > last) {
                        lo = mid + 1;
                    } else {
                        const first = try u16At(self.data, r + 4);
                        return first + (gid - start);
                    }
                }
                return null;
            },
            else => return error.MissingTable,
        }
    }

    /// ClassDef class of `gid`. Glyphs the ClassDef does not mention are class
    /// 0, which is what the spec says, not a failure.
    pub fn classOf(self: Layout, abs: usize, gid: u16) Error!u16 {
        const fmt = try u16At(self.data, abs);
        switch (fmt) {
            1 => {
                const start = try u16At(self.data, abs + 2);
                const n = try u16At(self.data, abs + 4);
                if (gid < start or gid >= start + n) return 0;
                return try u16At(self.data, abs + 6 + @as(usize, gid - start) * 2);
            },
            2 => {
                const n = try u16At(self.data, abs + 2);
                var lo: usize = 0;
                var hi: usize = n;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const r = abs + 4 + mid * 6;
                    const start = try u16At(self.data, r);
                    const last = try u16At(self.data, r + 2);
                    if (gid < start) {
                        hi = mid;
                    } else if (gid > last) {
                        lo = mid + 1;
                    } else {
                        return try u16At(self.data, r + 4);
                    }
                }
                return 0;
            },
            else => return error.MissingTable,
        }
    }

    /// One GSUB pass for `feat` over `in`, writing to `out`.
    ///
    /// Types 1 (single), 2 (multiple), 3 (alternate) and 4 (ligature). The
    /// pass is left to right, one lookup at a time, in lookup-list order --
    /// which is the order the spec applies them in, because a later lookup is
    /// written against the output of the earlier ones. Contextual lookups
    /// (types 5 and 6) are not applied, so a font that only replaces through
    /// context reads as unchanged rather than as wrong.
    ///
    /// `out` may alias `in`? No: it is written from the start, so pass distinct
    /// buffers. It must have room for the longest expansion the feature can
    /// produce, and too little room is `BufferTooSmall`, never a truncation.
    pub fn substitute(self: Layout, feat: u32, in: []const u16, out: []u16) Error!usize {
        if (out.len < in.len) return error.BufferTooSmall;
        @memcpy(out[0..in.len], in);
        var len = in.len;

        var lookups_buf: [32]u16 = undefined;
        const lookups = try self.featureLookupsDefault(feat, &lookups_buf);
        for (lookups) |li| {
            const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, li) * 2);
            const kind = try u16At(self.data, lookup);
            const flags = try u16At(self.data, lookup + 2);
            const sub_count = try u16At(self.data, lookup + 4);
            var i: usize = 0;
            while (i < sub_count) : (i += 1) {
                const sub = lookup + try u16At(self.data, lookup + 6 + i * 2);
                const step = try self.substPass(kind, sub, out, len, flags);
                len = step;
            }
        }
        return len;
    }

    /// The lookups of `feat` under `script`, falling back to the default
    /// script when that script does not carry it. Arabic lives under `arab`,
    /// and a font may not repeat ccmp there.
    fn lookupsFor(self: Layout, script: u32, feat: u32, out: []u16) []const u16 {
        if (self.featureLookups(script, 0, feat, out)) |l| {
            if (l.len > 0) return l;
        } else |_| {}
        return self.featureLookupsDefault(feat, out) catch return &.{};
    }

    /// Apply lookup `index` at one position, stopping at the first subtable
    /// that changes the buffer. `depth` bounds the nesting a contextual lookup
    /// can ask for, so a font that points a lookup at itself cannot loop.
    fn applyLookupAt(self: Layout, index: u16, buf: []u16, len: usize, pos: usize, depth: u4) Error!usize {
        if (depth > 8) return len;
        const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, index) * 2);
        const kind = try u16At(self.data, lookup);
        const flags = try u16At(self.data, lookup + 2);
        const sub_count = try u16At(self.data, lookup + 4);
        var cur = len;
        var i: usize = 0;
        while (i < sub_count) : (i += 1) {
            const sub = lookup + try u16At(self.data, lookup + 6 + i * 2);
            var real_kind = kind;
            var real = sub;
            if (kind == 7) {
                real_kind = try u16At(self.data, sub + 2);
                real = sub + try u32At(self.data, sub + 4);
            }
            const step = try self.substAt(real_kind, real, buf, cur, pos, depth, flags);
            // Only a HIT carries a length. Step.len defaults to 0 for a miss,
            // so assigning it unconditionally truncated the run to nothing at
            // the first lookup that did not match.
            if (step.hit) {
                cur = step.len;
                break;
            }
        }
        return cur;
    }

    /// GSUB type 6, chaining contextual. Format 3 only: every coverage set is
    /// an explicit list of positions, which is what real fonts use for this.
    /// Formats 1 and 2 (glyph and class based rule sets) are not implemented
    /// and match nothing, so a font using them keeps its unsubstituted glyphs
    /// rather than producing wrong ones.
    fn chainAt(self: Layout, sub: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16) Error!Step {
        if (try u16At(self.data, sub) != 3) return .{};
        var at = sub + 2;

        const back_n = try u16At(self.data, at);
        at += 2;
        const back_off = at;
        at += @as(usize, back_n) * 2;

        const in_n = try u16At(self.data, at);
        at += 2;
        const in_off = at;
        at += @as(usize, in_n) * 2;

        const ahead_n = try u16At(self.data, at);
        at += 2;
        const ahead_off = at;
        at += @as(usize, ahead_n) * 2;

        const rec_n = try u16At(self.data, at);
        at += 2;
        const rec_off = at;

        // Input coverage, left to right from pos.
        //
        // With lookupFlag IgnoreMarks (or UseMarkFilteringSet) a mark does not
        // break the match: it is stepped over and LEFT IN PLACE, which is how
        // HarfBuzz ligates لَا while keeping the fatha. `positions` maps each
        // matched input slot back to its buffer index so the records below
        // still name the right glyph.
        if (in_n == 0 or in_n > 16) return .{};
        const skip_marks = (flags & 0x0008 != 0) or (flags & 0x0010 != 0);
        var positions: [16]usize = undefined;
        var got: usize = 0;
        var p = pos;
        while (got < in_n) {
            if (p >= len) return .{};
            if (skip_marks) {
                if (self.gdef) |g| {
                    if (try g.isMark(buf[p])) {
                        p += 1;
                        continue;
                    }
                }
            }
            const cov = sub + try u16At(self.data, in_off + got * 2);
            if ((try self.coverageIndex(cov, buf[p])) == null) return .{};
            positions[got] = p;
            got += 1;
            p += 1;
        }
        const matched_end = p;
        // Backtrack reads backwards from pos, nearest first: coverage j matches
        // the glyph j positions to the left.
        if (pos < back_n) return .{};
        for (0..back_n) |j| {
            const cov = sub + try u16At(self.data, back_off + j * 2);
            if ((try self.coverageIndex(cov, buf[pos - 1 - j])) == null) return .{};
        }
        // Lookahead starts after the input.
        var ap = matched_end;
        var adone: usize = 0;
        while (adone < ahead_n) {
            if (ap >= len) return .{};
            if (skip_marks) {
                if (self.gdef) |g| {
                    if (try g.isMark(buf[ap])) {
                        ap += 1;
                        continue;
                    }
                }
            }
            const cov = sub + try u16At(self.data, ahead_off + adone * 2);
            if ((try self.coverageIndex(cov, buf[ap])) == null) return .{};
            adone += 1;
            ap += 1;
        }

        // Records name a position inside the input and a lookup to run there.
        // A nested lookup may change the buffer length, so later target
        // positions shift by however much the earlier ones moved.
        var cur = len;
        var shift: isize = 0;
        for (0..rec_n) |r| {
            const seq = try u16At(self.data, rec_off + r * 4);
            const li = try u16At(self.data, rec_off + r * 4 + 2);
            if (seq >= got) continue;
            const target = @as(isize, @intCast(positions[seq])) + shift;
            if (target < 0 or target >= @as(isize, @intCast(cur))) continue;
            const before = cur;
            cur = try self.applyLookupAt(li, buf, cur, @intCast(target), depth + 1);
            shift += @as(isize, @intCast(cur)) - @as(isize, @intCast(before));
        }
        return .{ .hit = true, .len = cur, .advance = matched_end - pos };
    }

    /// GPOS type 4, mark-to-base. Each mark glyph offsets itself by
    /// (base anchor - mark anchor) for its class, so a fatha lands where the
    /// font drew that letter's room for one rather than on the baseline.
    ///
    /// The base is the nearest preceding glyph that is not itself a mark, and
    /// the class is the one the mark's MarkRecord names. Anchors are integer
    /// font units: no device tables, no variation deltas.
    pub fn markAttach(self: Layout, script: u32, feat: u32, buf: []const u16, len: usize, out: []Offset) Error!usize {
        var lookups_buf: [32]u16 = undefined;
        var placed: usize = 0;
        for (self.lookupsFor(script, feat, &lookups_buf)) |li| {
            const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, li) * 2);
            var kind = try u16At(self.data, lookup);
            const sub_count = try u16At(self.data, lookup + 4);
            var si: usize = 0;
            while (si < sub_count) : (si += 1) {
                var sub = lookup + try u16At(self.data, lookup + 6 + si * 2);
                kind = try u16At(self.data, lookup);
                if (kind == 9) {
                    kind = try u16At(self.data, sub + 2);
                    sub = sub + try u32At(self.data, sub + 4);
                }
                if (kind == 4) {
                    placed += try self.markBaseSub(sub, buf, len, out);
                } else if (kind == 6) {
                    placed += try self.markMarkSub(sub, buf, len, out);
                }
            }
        }
        return placed;
    }

    /// GPOS type 6, mark-to-mark: the second of two marks stacked on one
    /// letter. The upper mark anchors to the lower one and INHERITS that mark's
    /// offset, so a fatha over a shadda sits on the shadda rather than sinking
    /// to wherever the shadda's own anchor put it.
    fn markMarkSub(self: Layout, sub: usize, buf: []const u16, len: usize, out: []Offset) Error!usize {
        if (try u16At(self.data, sub) != 1) return 0;
        const mark1_cov = sub + try u16At(self.data, sub + 2);
        const mark2_cov = sub + try u16At(self.data, sub + 4);
        const class_count = try u16At(self.data, sub + 6);
        const mark1_array = sub + try u16At(self.data, sub + 8);
        const mark2_array = sub + try u16At(self.data, sub + 10);

        var placed: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const mi = (try self.coverageIndex(mark1_cov, buf[i])) orelse continue;
            // The thing underneath is the nearest preceding glyph of the
            // mark2 set -- another mark, not the letter.
            var j = i;
            var under: ?u16 = null;
            while (j > 0) {
                j -= 1;
                if ((try self.coverageIndex(mark2_cov, buf[j])) != null) {
                    under = try self.coverageIndex(mark2_cov, buf[j]);
                    break;
                }
                // Stop at a letter. A mark two letters back is not under this
                // one, and walking past the base is how a lone kasra ended up
                // inheriting the offset of a sukun on the PREVIOUS letter.
                if ((try self.coverageIndex(mark1_cov, buf[j])) == null) break;
            }
            const mi2 = under orelse continue;

            const cls = try u16At(self.data, mark1_array + 2 + @as(usize, mi) * 4);
            if (cls >= class_count) continue;
            const mark1_anchor = mark1_array + try u16At(self.data, mark1_array + 2 + @as(usize, mi) * 4 + 2);
            const mark2_anchor = mark2_array + try u16At(self.data, mark2_array + 2 + (@as(usize, mi2) * class_count + cls) * 2);
            if (try u16At(self.data, mark2_anchor) == 0) continue;

            const ax = try i16At(self.data, mark2_anchor + 2);
            const ay = try i16At(self.data, mark2_anchor + 4);
            const bx = try i16At(self.data, mark1_anchor + 2);
            const by = try i16At(self.data, mark1_anchor + 4);
            out[i] = .{ .x = out[j].x + (ax - bx), .y = out[j].y + (ay - by) };
            placed += 1;
        }
        return placed;
    }

    fn markBaseSub(self: Layout, sub: usize, buf: []const u16, len: usize, out: []Offset) Error!usize {
        if (try u16At(self.data, sub) != 1) return 0;
        const mark_cov = sub + try u16At(self.data, sub + 2);
        const base_cov = sub + try u16At(self.data, sub + 4);
        const class_count = try u16At(self.data, sub + 6);
        const mark_array = sub + try u16At(self.data, sub + 8);
        const base_array = sub + try u16At(self.data, sub + 10);

        var placed: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const mi = (try self.coverageIndex(mark_cov, buf[i])) orelse continue;
            // Walk back to the base: any number of marks may stack on it.
            var j = i;
            var base_index: ?u16 = null;
            while (j > 0) {
                j -= 1;
                if ((try self.coverageIndex(mark_cov, buf[j])) != null) continue;
                base_index = try self.coverageIndex(base_cov, buf[j]);
                break;
            }
            const bi = base_index orelse continue;

            // MarkRecord: class, then the anchor offset within MarkArray.
            const cls = try u16At(self.data, mark_array + 2 + @as(usize, mi) * 4);
            if (cls >= class_count) continue;
            const mark_anchor = mark_array + try u16At(self.data, mark_array + 2 + @as(usize, mi) * 4 + 2);

            // BaseRecord: one anchor offset per class, within BaseArray.
            const base_anchor = base_array + try u16At(self.data, base_array + 2 + (@as(usize, bi) * class_count + cls) * 2);
            if (try u16At(self.data, base_anchor) == 0) continue;

            const bx = try i16At(self.data, base_anchor + 2);
            const by = try i16At(self.data, base_anchor + 4);
            const mx = try i16At(self.data, mark_anchor + 2);
            const my = try i16At(self.data, mark_anchor + 4);
            out[i] = .{ .x = bx - mx, .y = by - my };
            placed += 1;
        }
        return placed;
    }

    /// Apply one feature at ONE buffer position, which is what a joining form
    /// needs: `init` applies to the letters that take an initial form and to
    /// nothing else. Returns the (possibly changed) buffer length.
    pub fn applyFeatureAt(self: Layout, script: u32, feat: u32, buf: []u16, len: usize, pos: usize) Error!usize {
        if (pos >= len) return len;
        var lookups_buf: [32]u16 = undefined;
        var cur = len;
        for (self.lookupsFor(script, feat, &lookups_buf)) |li| {
            cur = try self.applyLookupAt(li, buf, cur, pos, 0);
        }
        return cur;
    }

    /// Apply one feature at every position, in order.
    pub fn applyFeature(self: Layout, script: u32, feat: u32, buf: []u16, len: usize) Error!usize {
        var lookups_buf: [32]u16 = undefined;
        var cur = len;
        for (self.lookupsFor(script, feat, &lookups_buf)) |li| {
            const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, li) * 2);
            const kind = try u16At(self.data, lookup);
            const flags = try u16At(self.data, lookup + 2);
            const sub_count = try u16At(self.data, lookup + 4);
            var i: usize = 0;
            while (i < sub_count) : (i += 1) {
                const sub = lookup + try u16At(self.data, lookup + 6 + i * 2);
                cur = try self.substPass(kind, sub, buf, cur, flags);
            }
        }
        return cur;
    }

    /// Walk `buf[0..len]` applying one subtable at every position.
    fn substPass(self: Layout, kind: u16, sub: usize, buf: []u16, len: usize, flags: u16) Error!usize {
        var real_kind = kind;
        var real = sub;
        if (kind == 7) {
            // GSUB Extension: the same unwrap GPOS uses, different type number.
            real_kind = try u16At(self.data, sub + 2);
            real = sub + try u32At(self.data, sub + 4);
        }
        var pos: usize = 0;
        var n = len;
        while (pos < n) {
            const step = try self.substAt(real_kind, real, buf, n, pos, 0, flags);
            if (step.hit) {
                n = step.len;
                pos += step.advance;
            } else {
                pos += 1;
            }
        }
        return n;
    }

    const Step = struct { hit: bool = false, len: usize = 0, advance: usize = 1 };

    fn substAt(self: Layout, kind: u16, sub: usize, buf: []u16, len: usize, pos: usize, depth: u4, flags: u16) Error!Step {
        // Contextual lookups gate other lookups rather than substituting a
        // glyph, so they do not have a coverage table at offset 2.
        if (kind == 6) return self.chainAt(sub, buf, len, pos, depth, flags);
        const gid = buf[pos];
        const cov = sub + try u16At(self.data, sub + 2);
        const idx = (try self.coverageIndex(cov, gid)) orelse return .{};
        switch (kind) {
            1 => {
                // Format 1 maps by delta (a signed add, wrapping 16-bit);
                // format 2 lists the substitutes.
                const fmt = try u16At(self.data, sub);
                const to: u16 = if (fmt == 1)
                    gid +% @as(u16, @bitCast(try i16At(self.data, sub + 4)))
                else blk: {
                    const count = try u16At(self.data, sub + 4);
                    if (idx >= count) return .{};
                    break :blk try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
                };
                if (to == gid) return .{};
                buf[pos] = to;
                return .{ .hit = true, .len = len, .advance = 1 };
            },
            2 => {
                const count = try u16At(self.data, sub + 4);
                if (idx >= count) return .{};
                const seq = sub + try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
                const n = try u16At(self.data, seq);
                if (n == 0) return .{};
                if (len - 1 + n > buf.len) return error.BufferTooSmall;
                if (n > 1) {
                    const tail = len - pos - 1;
                    std.mem.copyBackwards(u16, buf[pos + n .. pos + n + tail], buf[pos + 1 .. pos + 1 + tail]);
                }
                var k: usize = 0;
                while (k < n) : (k += 1) buf[pos + k] = try u16At(self.data, seq + 2 + k * 2);
                return .{ .hit = true, .len = len - 1 + n, .advance = n };
            },
            3 => {
                const count = try u16At(self.data, sub + 4);
                if (idx >= count) return .{};
                const set = sub + try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
                const n = try u16At(self.data, set);
                if (n == 0) return .{};
                // Alternate 0 is the designer's first choice.
                const to = try u16At(self.data, set + 2);
                if (to == gid) return .{};
                buf[pos] = to;
                return .{ .hit = true, .len = len, .advance = 1 };
            },
            4 => {
                const count = try u16At(self.data, sub + 4);
                if (idx >= count) return .{};
                const set = sub + try u16At(self.data, sub + 6 + @as(usize, idx) * 2);
                const lig_count = try u16At(self.data, set);
                const skip_marks = (flags & 0x0008 != 0) or (flags & 0x0010 != 0);
                var l: usize = 0;
                while (l < lig_count) : (l += 1) {
                    const lig = set + try u16At(self.data, set + 2 + l * 2);
                    const lig_glyph = try u16At(self.data, lig);
                    const comps = try u16At(self.data, lig + 2);
                    if (comps == 0 or comps > 16) continue;
                    // Where each component actually sits. With IgnoreMarks a
                    // mark between components is stepped over and LEFT IN
                    // PLACE, so the ligature can form without eating it --
                    // which is how الله keeps its shadda.
                    var positions: [16]usize = undefined;
                    positions[0] = pos;
                    var got: usize = 1;
                    var q = pos + 1;
                    while (got < comps) {
                        if (q >= len) break;
                        const want = try u16At(self.data, lig + 4 + (got - 1) * 2);
                        if (buf[q] == want) {
                            positions[got] = q;
                            got += 1;
                            q += 1;
                            continue;
                        }
                        const is_mark = if (self.gdef) |g| try g.isMark(buf[q]) else false;
                        if (skip_marks and is_mark) {
                            q += 1;
                            continue;
                        }
                        break;
                    }
                    if (got != comps) continue;
                    buf[pos] = lig_glyph;
                    // Keep everything that was not consumed as a component, so
                    // the stepped-over marks survive in order after the ligature.
                    var write = pos + 1;
                    var r = pos + 1;
                    while (r < len) : (r += 1) {
                        var consumed = false;
                        var c: usize = 1;
                        while (c < comps) : (c += 1) {
                            if (positions[c] == r) {
                                consumed = true;
                                break;
                            }
                        }
                        if (consumed) continue;
                        buf[write] = buf[r];
                        write += 1;
                    }
                    return .{ .hit = true, .len = write, .advance = 1 };
                }
                return .{};
            },
            else => return .{},
        }
    }

    /// Lookup type of a lookup index, with Extension wrappers resolved.
    pub fn lookupType(self: Layout, index: u16) Error!u16 {
        const lookup = self.lookup_list + try u16At(self.data, self.lookup_list + 2 + @as(usize, index) * 2);
        const kind = try u16At(self.data, lookup);
        if (kind != 9) return kind;
        const sub = lookup + try u16At(self.data, lookup + 6);
        return try u16At(self.data, sub + 2);
    }
};

/// Sort ascending and drop duplicates: feature records may name lookups in any
/// order, and the spec applies them in lookup-list order.
fn sortUnique(items: []u16) []u16 {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const v = items[i];
        var j = i;
        while (j > 0 and items[j - 1] > v) : (j -= 1) items[j] = items[j - 1];
        items[j] = v;
    }
    var n: usize = 0;
    for (items) |v| {
        if (n == 0 or items[n - 1] != v) {
            items[n] = v;
            n += 1;
        }
    }
    return items[0..n];
}

fn inside(base: usize, end: usize, rel: u16) Error!usize {
    const abs = base + rel;
    if (abs + 4 > end) return error.Truncated;
    return abs;
}

fn u16At(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.Truncated;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn i16At(b: []const u8, off: usize) Error!i16 {
    if (off + 2 > b.len) return error.Truncated;
    return std.mem.readInt(i16, b[off..][0..2], .big);
}

fn u32At(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.Truncated;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

// -- tests -------------------------------------------------------------
//
// Synthetic tables rather than a real face: a fixture states exactly one fact,
// so a failure names the field that broke instead of "Lato's kerning moved".
//
// Layout order matters. Every offset in an OpenType layout table points
// FORWARD, so the tables are emitted in dependency order: header, the three
// lists, the lookup, and only then the lookup's subtable.

const testing = std.testing;

const Builder = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn init() Builder {
        var b: Builder = .{};
        @memset(b.buf[0..], 0);
        return b;
    }
    fn bytes(b: *const Builder) []const u8 {
        return b.buf[0..b.len];
    }
    fn put16(b: *Builder, v: u16) usize {
        const at = b.len;
        std.mem.writeInt(u16, b.buf[at..][0..2], v, .big);
        b.len += 2;
        return at;
    }
    fn put32(b: *Builder, v: u32) usize {
        const at = b.len;
        std.mem.writeInt(u32, b.buf[at..][0..4], v, .big);
        b.len += 4;
        return at;
    }
    fn putTag(b: *Builder, t: *const [4]u8) usize {
        const at = b.len;
        @memcpy(b.buf[at..][0..4], t);
        b.len += 4;
        return at;
    }
    fn patch16(b: *Builder, at: usize, v: usize) void {
        std.mem.writeInt(u16, b.buf[at..][0..2], @intCast(v), .big);
    }
};

const Header = struct { scr: usize, fea: usize, loo: usize };

fn header(b: *Builder) Header {
    _ = b.put32(0x0001_0000);
    return .{ .scr = b.put16(0), .fea = b.put16(0), .loo = b.put16(0) };
}

/// A lookup whose subtable has not been written yet.
const Shell = struct { slot: usize, lookup: usize };

fn place(b: *Builder, sh: Shell, sub: usize) void {
    b.patch16(sh.slot, sub - sh.lookup);
}

/// One DFLT script, one langsys with no lang record, one `kern` feature, one
/// lookup. Everything the two tests that follow need, and nothing else.
fn shell(b: *Builder, h: Header, lookup_type: u16, fea_tag: *const [4]u8) Shell {
    const scr = b.len;
    b.patch16(h.scr, scr);
    _ = b.put16(1);
    _ = b.putTag("DFLT");
    const srec = b.put16(0);
    const script = b.len;
    b.patch16(srec, script - scr);
    const dls = b.put16(0);
    _ = b.put16(0); // langSysCount
    const langs = b.len;
    b.patch16(dls, langs - script);
    _ = b.put16(0); // lookupOrder: must be 0
    _ = b.put16(0xFFFF); // requiredFeatureIndex: none
    _ = b.put16(1); // featureIndexCount
    _ = b.put16(0); // feature 0, the kern feature below

    const fea = b.len;
    b.patch16(h.fea, fea);
    _ = b.put16(1);
    _ = b.putTag(fea_tag);
    const frec = b.put16(0);
    const feature = b.len;
    b.patch16(frec, feature - fea);
    _ = b.put16(0); // featureParams
    _ = b.put16(1); // lookupIndexCount
    _ = b.put16(0); // lookup 0

    const loo = b.len;
    b.patch16(h.loo, loo);
    _ = b.put16(1);
    const lrec = b.put16(0);
    const lookup = b.len;
    b.patch16(lrec, lookup - loo);
    _ = b.put16(lookup_type);
    _ = b.put16(0); // flag
    _ = b.put16(1); // subtableCount
    return .{ .slot = b.put16(0), .lookup = lookup };
}

/// PairPos format 1 over glyph 5: (5,7) = -80, (5,9) = +25.
fn pair1(b: *Builder) usize {
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(0x0004);
    _ = b.put16(0);
    _ = b.put16(1);
    const setrec = b.put16(0);
    const set = b.len;
    b.patch16(setrec, set - sub);
    _ = b.put16(2);
    _ = b.put16(7);
    _ = b.put16(@bitCast(@as(i16, -80)));
    _ = b.put16(9);
    _ = b.put16(@bitCast(@as(i16, 25)));
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    return sub;
}

/// PairPos format 2: left 5 is class 1, rights 7..9 are class 1 of ClassDef2,
/// and the class-0 row carries a real value the way fonts actually use it.
fn pair2(b: *Builder) usize {
    const sub = b.len;
    _ = b.put16(2);
    const cov = b.put16(0);
    _ = b.put16(0x0004);
    _ = b.put16(0);
    const cd1 = b.put16(0);
    const cd2 = b.put16(0);
    _ = b.put16(2);
    _ = b.put16(2);
    // 2x2 matrix: (0,0) = 0, (0,1) = -40, (1,0) = -12, (1,1) = -100
    _ = b.put16(0);
    _ = b.put16(@bitCast(@as(i16, -40)));
    _ = b.put16(@bitCast(@as(i16, -12)));
    _ = b.put16(@bitCast(@as(i16, -100)));

    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);

    const cd1abs = b.len;
    b.patch16(cd1, cd1abs - sub);
    _ = b.put16(1);
    _ = b.put16(5);
    _ = b.put16(1);
    _ = b.put16(1);

    const cd2abs = b.len;
    b.patch16(cd2, cd2abs - sub);
    _ = b.put16(2);
    _ = b.put16(1);
    _ = b.put16(7);
    _ = b.put16(9);
    _ = b.put16(1);
    return sub;
}

fn gposPair1(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 2, "kern");
    place(b, sh, pair1(b));
}

fn gposPair2(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 2, "kern");
    place(b, sh, pair2(b));
}

test "tag is big-endian, the same as glyfz's" {
    try testing.expectEqual(@as(u32, 0x6B65_726E), tag("kern"));
    try testing.expectEqual(@as(u32, 0x4446_4C54), tag("DFLT"));
}

test "valueSize counts only the record fields it must skip" {
    try testing.expectEqual(@as(usize, 0), valueSize(0));
    try testing.expectEqual(@as(usize, 2), valueSize(0x0004));
    try testing.expectEqual(@as(usize, 8), valueSize(0x000F));
    // Device offsets ride along in the record even though we never follow them.
    try testing.expectEqual(@as(usize, 16), valueSize(0x00FF));
}

test "pair-1 gives a signed adjustment and nothing for an absent pair" {
    var b = Builder.init();
    gposPair1(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var buf: [8]u16 = undefined;
    const lookups = try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf);
    try testing.expectEqual(@as(usize, 1), lookups.len);

    try testing.expectEqual(@as(i16, -80), l.pairAdjust(lookups, 5, 7).x_advance);
    try testing.expectEqual(@as(i16, 25), l.pairAdjust(lookups, 5, 9).x_advance);
    // Covered left glyph, absent right; then a right glyph with no left coverage.
    try testing.expectEqual(@as(i16, 0), l.pairAdjust(lookups, 5, 8).x_advance);
    try testing.expectEqual(@as(i16, 0), l.pairAdjust(lookups, 6, 7).x_advance);
    try testing.expect(!l.pairAdjust(lookups, 5, 7).isZero());
    try testing.expect(l.pairAdjust(lookups, 6, 7).isZero());
}

test "pair-2 reads class 0 as a row, not as a miss" {
    var b = Builder.init();
    gposPair2(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var buf: [8]u16 = undefined;
    const lookups = try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf);

    // left 5 -> class 1, right 7 -> class 1
    try testing.expectEqual(@as(i16, -100), l.pairAdjust(lookups, 5, 7).x_advance);
    // left 5 -> class 1, right 3 -> class 0 (the row fonts really kern against)
    try testing.expectEqual(@as(i16, -12), l.pairAdjust(lookups, 5, 3).x_advance);
    // left 8 is uncovered: a class-based subtable still requires coverage.
    try testing.expectEqual(@as(i16, 0), l.pairAdjust(lookups, 8, 7).x_advance);
}

test "an extension lookup is unwrapped, not skipped" {
    var b = Builder.init();
    const h = header(&b);
    const sh = shell(&b, h, 9, "kern");
    const ext = b.len;
    _ = b.put16(1); // extension posFormat
    _ = b.put16(2); // extensionLookupType: the real PairPos
    const inner = b.put32(0);
    const sub = pair1(&b);
    std.mem.writeInt(u32, b.buf[inner..][0..4], @intCast(sub - ext), .big);
    place(&b, sh, ext);

    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var buf: [8]u16 = undefined;
    const lookups = try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf);
    try testing.expectEqual(@as(u16, 2), try l.lookupType(lookups[0]));
    try testing.expectEqual(@as(i16, -80), l.pairAdjust(lookups, 5, 7).x_advance);
}

test "an offset past the end adjusts nothing instead of panicking" {
    var b = Builder.init();
    const h = header(&b);
    const sh = shell(&b, h, 2, "kern");
    const sub = pair1(&b);
    place(&b, sh, sub);
    // Break the subtable's coverage offset, leaving the header intact.
    std.mem.writeInt(u16, b.buf[sub + 2 ..][0..2], 0xFFF0, .big);

    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var buf: [8]u16 = undefined;
    const lookups = try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf);
    try testing.expectEqual(@as(usize, 1), lookups.len);
    try testing.expect(l.pairAdjust(lookups, 5, 7).isZero());
}

test "a header whose lists do not fit is refused at init" {
    var b = Builder.init();
    gposPair1(&b);
    try testing.expectError(error.Truncated, Layout.init(b.bytes(), 0, 8));
    var junk: [16]u8 = @splat(0);
    try testing.expectError(error.MissingTable, Layout.init(&junk, 0, 16));
}

test "an absent feature is an empty answer, not an error" {
    var b = Builder.init();
    gposPair1(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var buf: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 0), (try l.featureLookups(tag("DFLT"), 0, tag("liga"), &buf)).len);
    try testing.expectEqual(@as(usize, 0), (try l.featureLookups(tag("arab"), 0, tag("kern"), &buf)).len);
    // ...but the default policy finds the DFLT one.
    try testing.expectEqual(@as(usize, 1), (try l.featureLookupsDefault(tag("kern"), &buf)).len);
}

/// Two scripts, each with its own `kern` feature and lookup index. Only the
/// indirection is real here: this fixture is about which script is chosen.
fn twoScripts(b: *Builder) void {
    const h = header(b);

    const scr = b.len;
    b.patch16(h.scr, scr);
    _ = b.put16(2);
    _ = b.putTag("DFLT");
    const r0 = b.put16(0);
    _ = b.putTag("latn");
    const r1 = b.put16(0);

    const s0 = b.len;
    b.patch16(r0, s0 - scr);
    const d0 = b.put16(0);
    _ = b.put16(0);
    const ls0 = b.len;
    b.patch16(d0, ls0 - s0);
    _ = b.put16(0);
    _ = b.put16(0xFFFF);
    _ = b.put16(1);
    _ = b.put16(0);

    const s1 = b.len;
    b.patch16(r1, s1 - scr);
    const d1 = b.put16(0);
    _ = b.put16(0);
    const ls1 = b.len;
    b.patch16(d1, ls1 - s1);
    _ = b.put16(0);
    _ = b.put16(0xFFFF);
    _ = b.put16(1);
    _ = b.put16(1);

    const fea = b.len;
    b.patch16(h.fea, fea);
    _ = b.put16(2);
    _ = b.putTag("kern");
    const f0 = b.put16(0);
    _ = b.putTag("kern");
    const f1 = b.put16(0);
    const ft0 = b.len;
    b.patch16(f0, ft0 - fea);
    _ = b.put16(0);
    _ = b.put16(1);
    _ = b.put16(0);
    const ft1 = b.len;
    b.patch16(f1, ft1 - fea);
    _ = b.put16(0);
    _ = b.put16(1);
    _ = b.put16(1);

    const loo = b.len;
    b.patch16(h.loo, loo);
    _ = b.put16(2);
    const lr0 = b.put16(0);
    const lr1 = b.put16(0);
    const look = b.len;
    b.patch16(lr0, look - loo);
    b.patch16(lr1, look - loo);
    _ = b.put16(2);
    _ = b.put16(0);
    _ = b.put16(0);
}

test "the default script policy prefers latn, and DFLT still resolves" {
    var b = Builder.init();
    twoScripts(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));

    var buf: [8]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{1}, try l.featureLookups(tag("latn"), 0, tag("kern"), &buf));
    try testing.expectEqualSlices(u16, &.{0}, try l.featureLookups(tag("DFLT"), 0, tag("kern"), &buf));
    // latn wins when both exist -- DejaVu Sans carries its two real kern
    // lookups under latn and a single class lookup under DFLT.
    try testing.expectEqualSlices(u16, &.{1}, try l.featureLookupsDefault(tag("kern"), &buf));
}

// -- substitution fixtures ---------------------------------------------

/// Single substitution, format 1: glyph 5 becomes glyph 15.
fn gsubSingleDelta(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 1, "liga");
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(@bitCast(@as(i16, 10)));
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    place(b, sh, sub);
}

/// Single substitution, format 2: the substitute is listed, not derived.
fn gsubSingleList(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 1, "liga");
    const sub = b.len;
    _ = b.put16(2);
    const cov = b.put16(0);
    _ = b.put16(1); // glyphCount
    _ = b.put16(30); // substitute for the first covered glyph
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    place(b, sh, sub);
}

/// Multiple substitution: glyph 5 expands to 7 then 8.
fn gsubMultiple(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 2, "liga");
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(1);
    const seqrec = b.put16(0);
    const seq = b.len;
    b.patch16(seqrec, seq - sub);
    _ = b.put16(2);
    _ = b.put16(7);
    _ = b.put16(8);
    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    place(b, sh, sub);
}

/// Ligatures: 5+6+7 -> 20, and 5+6 -> 21. The longer record comes first, so a
/// three-glyph sequence must not match the two-glyph rule.
/// A GSUB with two lookups, which is the smallest shape a contextual rule
/// needs: lookup 0 is a single substitution reachable ONLY through the record,
/// lookup 1 is the chaining rule that decides when to call it. The feature
/// lists lookup 1 alone, so nothing substitutes unless the context matches.
fn gsubChain(b: *Builder) void {
    const h = header(b);

    // ScriptList: one DFLT script, one langsys naming feature 0.
    const scr = b.len;
    b.patch16(h.scr, scr);
    _ = b.put16(1);
    _ = b.putTag("DFLT");
    const srec = b.put16(0);
    const script = b.len;
    b.patch16(srec, script - scr);
    const dls = b.put16(0);
    _ = b.put16(0); // LangSysCount
    const langs = b.len;
    b.patch16(dls, langs - script);
    _ = b.put16(0); // LookupOrder
    _ = b.put16(0xFFFF); // ReqFeatureIndex
    _ = b.put16(1); // FeatureIndexCount
    _ = b.put16(0);

    // FeatureList: one 'liga' naming lookup 1 and NOT lookup 0.
    const fea = b.len;
    b.patch16(h.fea, fea);
    _ = b.put16(1);
    _ = b.putTag("liga");
    const frec = b.put16(0);
    const feature = b.len;
    b.patch16(frec, feature - fea);
    _ = b.put16(0); // FeatureParams
    _ = b.put16(1); // LookupIndexCount
    _ = b.put16(1); // lookup 1: the chaining rule

    // LookupList.
    const loo = b.len;
    b.patch16(h.loo, loo);
    _ = b.put16(2);
    const l0rec = b.put16(0);
    const l1rec = b.put16(0);

    // Lookup 0: single substitution, format 1, glyph 10 -> 15.
    const l0 = b.len;
    b.patch16(l0rec, l0 - loo);
    _ = b.put16(1); // lookupType
    _ = b.put16(0); // lookupFlag
    _ = b.put16(1); // subTableCount
    const l0sub = b.put16(0);
    const s0 = b.len;
    b.patch16(l0sub, s0 - l0);
    _ = b.put16(1); // substFormat
    const cov0 = b.put16(0);
    _ = b.put16(@bitCast(@as(i16, 5))); // delta +5
    const covabs0 = b.len;
    b.patch16(cov0, covabs0 - s0);
    _ = b.put16(1); // coverage format 1
    _ = b.put16(1); // glyphCount
    _ = b.put16(10);

    // Lookup 1: chaining contextual, format 3. Input [10], lookahead [20],
    // one record that runs lookup 0 at sequence index 0.
    const l1 = b.len;
    b.patch16(l1rec, l1 - loo);
    _ = b.put16(6);
    _ = b.put16(0);
    _ = b.put16(1);
    const l1sub = b.put16(0);
    const s1 = b.len;
    b.patch16(l1sub, s1 - l1);
    _ = b.put16(3); // substFormat
    _ = b.put16(0); // backtrackGlyphCount
    _ = b.put16(1); // inputGlyphCount
    const icov = b.put16(0);
    _ = b.put16(1); // lookaheadGlyphCount
    const acov = b.put16(0);
    _ = b.put16(1); // substCount
    _ = b.put16(0); // sequenceIndex
    _ = b.put16(0); // lookupListIndex -> lookup 0
    const icovabs = b.len;
    b.patch16(icov, icovabs - s1);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(10);
    const acovabs = b.len;
    b.patch16(acov, acovabs - s1);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(20);
}

fn gsubLigature(b: *Builder) void {
    const h = header(b);
    const sh = shell(b, h, 4, "liga");
    const sub = b.len;
    _ = b.put16(1);
    const cov = b.put16(0);
    _ = b.put16(1);
    const setrec = b.put16(0);
    const set = b.len;
    b.patch16(setrec, set - sub);
    _ = b.put16(2);
    const l0 = b.put16(0);
    const l1 = b.put16(0);

    const lig0 = b.len;
    b.patch16(l0, lig0 - set);
    _ = b.put16(20); // ligature glyph
    _ = b.put16(3); // componentCount, first included
    _ = b.put16(6);
    _ = b.put16(7);

    const lig1 = b.len;
    b.patch16(l1, lig1 - set);
    _ = b.put16(21);
    _ = b.put16(2);
    _ = b.put16(6);

    const covabs = b.len;
    b.patch16(cov, covabs - sub);
    _ = b.put16(1);
    _ = b.put16(1);
    _ = b.put16(5);
    place(b, sh, sub);
}

test "single substitution maps by delta and by list" {
    var b = Builder.init();
    gsubSingleDelta(&b);
    const d1 = b.bytes();
    const l1 = try Layout.init(d1, 0, @intCast(d1.len));
    var out: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 1), try l1.substitute(tag("liga"), &.{5}, &out));
    try testing.expectEqual(@as(u16, 15), out[0]);

    var c = Builder.init();
    gsubSingleList(&c);
    const d2 = c.bytes();
    const l2 = try Layout.init(d2, 0, @intCast(d2.len));
    try testing.expectEqual(@as(usize, 1), try l2.substitute(tag("liga"), &.{5}, &out));
    try testing.expectEqual(@as(u16, 30), out[0]);
    // A glyph outside the coverage is left exactly as it was.
    try testing.expectEqual(@as(usize, 1), try l2.substitute(tag("liga"), &.{9}, &out));
    try testing.expectEqual(@as(u16, 9), out[0]);
}

test "multiple substitution grows the sequence in place" {
    var b = Builder.init();
    gsubMultiple(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var out: [8]u16 = undefined;
    const n = try l.substitute(tag("liga"), &.{ 5, 9 }, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u16, &.{ 7, 8, 9 }, out[0..n]);

    // Too little room is an error, never a silent truncation.
    var small: [1]u16 = undefined;
    try testing.expectError(error.BufferTooSmall, l.substitute(tag("liga"), &.{5}, &small));
}

test "ligature substitution takes the longest matching rule first" {
    var b = Builder.init();
    gsubLigature(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var out: [8]u16 = undefined;

    var n = try l.substitute(tag("liga"), &.{ 5, 6, 7, 9 }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u16, &.{ 20, 9 }, out[0..n]);

    // Same first two glyphs, third differs: the two-component ligature applies.
    n = try l.substitute(tag("liga"), &.{ 5, 6, 9 }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u16, &.{ 21, 9 }, out[0..n]);

    // Nothing covered: unchanged, and no growth.
    n = try l.substitute(tag("liga"), &.{ 9, 9 }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u16, &.{ 9, 9 }, out[0..n]);
}

test "a ligature replaces its components with one glyph" {
    var b = Builder.init();
    gsubLigature(&b);
    const data = b.bytes();
    const l = try Layout.init(data, 0, @intCast(data.len));
    var out: [8]u16 = undefined;
    const n = try l.substitute(tag("liga"), &.{ 5, 6 }, &out);
    // Two components become one glyph: the length has to SHRINK, which is what
    // distinguishes a substitution from a positioning adjustment.
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u16, 21), out[0]);
}

test "a chaining lookup substitutes through the lookup it names" {
    var b = Builder.init();
    gsubChain(&b);
    const l = try Layout.init(b.bytes(), 0, @intCast(b.len));

    var buf = [_]u16{ 10, 20 };
    const n = try l.applyFeature(tag("DFLT"), tag("liga"), &buf, 2);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, 15), buf[0]); // 10 -> 15 via lookup 0
    try testing.expectEqual(@as(u16, 20), buf[1]); // untouched
}

test "a chaining lookup whose lookahead fails changes nothing" {
    var b = Builder.init();
    gsubChain(&b);
    const l = try Layout.init(b.bytes(), 0, @intCast(b.len));

    // Lookup 0 is not in the feature, so with the context broken there is
    // nothing left that could substitute the 10.
    var buf = [_]u16{ 10, 30 };
    const n = try l.applyFeature(tag("DFLT"), tag("liga"), &buf, 2);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, 10), buf[0]);
    try testing.expectEqual(@as(u16, 30), buf[1]);
}
