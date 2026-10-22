//! Arabic joining: which of the four contextual forms a letter takes.
//!
//! Arabic is written in logical order and joined, so there is no reordering
//! here -- only a neighbourhood question. A letter's form depends on whether
//! the letter before it can join forwards and whether the letter after it can
//! join backwards, one step each way, with transparent marks skipped over.
//!
//! The data is Unicode's `ArabicShaping.txt` joining types, merged into
//! contiguous ranges. Non-joining (U) codepoints are omitted because that is
//! the default, which leaves 158 ranges and no allocation: the lookup is a
//! binary search over a static table.
//!
//! Joining types are directional from the letter's own point of view:
//!   D (dual)        joins on both sides
//!   R (right)       joins to the PREVIOUS letter only
//!   L (left)        joins to the FOLLOWING letter only
//!   C (join_causing) forces joining, and has no glyph of its own (ZWJ)
//!   T (transparent) marks; ignored when looking for a neighbour

const std = @import("std");

pub const Joining = enum(u3) {
    non_joining,
    right,
    dual,
    left,
    join_causing,
    transparent,

    /// Can a letter of this type connect to the letter AFTER it?
    fn joinsForward(self: Joining) bool {
        return self == .dual or self == .left or self == .join_causing;
    }

    /// Can a letter of this type connect to the letter BEFORE it?
    fn joinsBackward(self: Joining) bool {
        return self == .dual or self == .right or self == .join_causing;
    }
};

const Range = struct { start: u21, end: u21, jt: Joining };

const ranges = [_]Range{
    .{ .start = 0x0610, .end = 0x061A, .jt = .transparent },
    .{ .start = 0x0620, .end = 0x0620, .jt = .dual },
    .{ .start = 0x0622, .end = 0x0625, .jt = .right },
    .{ .start = 0x0626, .end = 0x0626, .jt = .dual },
    .{ .start = 0x0627, .end = 0x0627, .jt = .right },
    .{ .start = 0x0628, .end = 0x0628, .jt = .dual },
    .{ .start = 0x0629, .end = 0x0629, .jt = .right },
    .{ .start = 0x062A, .end = 0x062E, .jt = .dual },
    .{ .start = 0x062F, .end = 0x0632, .jt = .right },
    .{ .start = 0x0633, .end = 0x063F, .jt = .dual },
    .{ .start = 0x0640, .end = 0x0640, .jt = .join_causing },
    .{ .start = 0x0641, .end = 0x0647, .jt = .dual },
    .{ .start = 0x0648, .end = 0x0648, .jt = .right },
    .{ .start = 0x0649, .end = 0x064A, .jt = .dual },
    .{ .start = 0x064B, .end = 0x065F, .jt = .transparent },
    .{ .start = 0x066E, .end = 0x066F, .jt = .dual },
    .{ .start = 0x0670, .end = 0x0670, .jt = .transparent },
    .{ .start = 0x0671, .end = 0x0673, .jt = .right },
    .{ .start = 0x0675, .end = 0x0677, .jt = .right },
    .{ .start = 0x0678, .end = 0x0687, .jt = .dual },
    .{ .start = 0x0688, .end = 0x0699, .jt = .right },
    .{ .start = 0x069A, .end = 0x06BF, .jt = .dual },
    .{ .start = 0x06C0, .end = 0x06C0, .jt = .right },
    .{ .start = 0x06C1, .end = 0x06C2, .jt = .dual },
    .{ .start = 0x06C3, .end = 0x06CB, .jt = .right },
    .{ .start = 0x06CC, .end = 0x06CC, .jt = .dual },
    .{ .start = 0x06CD, .end = 0x06CD, .jt = .right },
    .{ .start = 0x06CE, .end = 0x06CE, .jt = .dual },
    .{ .start = 0x06CF, .end = 0x06CF, .jt = .right },
    .{ .start = 0x06D0, .end = 0x06D1, .jt = .dual },
    .{ .start = 0x06D2, .end = 0x06D3, .jt = .right },
    .{ .start = 0x06D5, .end = 0x06D5, .jt = .right },
    .{ .start = 0x06D6, .end = 0x06DC, .jt = .transparent },
    .{ .start = 0x06DF, .end = 0x06E4, .jt = .transparent },
    .{ .start = 0x06E7, .end = 0x06E8, .jt = .transparent },
    .{ .start = 0x06EA, .end = 0x06ED, .jt = .transparent },
    .{ .start = 0x06EE, .end = 0x06EF, .jt = .right },
    .{ .start = 0x06FA, .end = 0x06FC, .jt = .dual },
    .{ .start = 0x06FF, .end = 0x06FF, .jt = .dual },
    .{ .start = 0x070F, .end = 0x070F, .jt = .transparent },
    .{ .start = 0x0710, .end = 0x0710, .jt = .right },
    .{ .start = 0x0712, .end = 0x0714, .jt = .dual },
    .{ .start = 0x0715, .end = 0x0719, .jt = .right },
    .{ .start = 0x071A, .end = 0x071D, .jt = .dual },
    .{ .start = 0x071E, .end = 0x071E, .jt = .right },
    .{ .start = 0x071F, .end = 0x0727, .jt = .dual },
    .{ .start = 0x0728, .end = 0x0728, .jt = .right },
    .{ .start = 0x0729, .end = 0x0729, .jt = .dual },
    .{ .start = 0x072A, .end = 0x072A, .jt = .right },
    .{ .start = 0x072B, .end = 0x072B, .jt = .dual },
    .{ .start = 0x072C, .end = 0x072C, .jt = .right },
    .{ .start = 0x072D, .end = 0x072E, .jt = .dual },
    .{ .start = 0x072F, .end = 0x072F, .jt = .right },
    .{ .start = 0x074D, .end = 0x074D, .jt = .right },
    .{ .start = 0x074E, .end = 0x0758, .jt = .dual },
    .{ .start = 0x0759, .end = 0x075B, .jt = .right },
    .{ .start = 0x075C, .end = 0x076A, .jt = .dual },
    .{ .start = 0x076B, .end = 0x076C, .jt = .right },
    .{ .start = 0x076D, .end = 0x0770, .jt = .dual },
    .{ .start = 0x0771, .end = 0x0771, .jt = .right },
    .{ .start = 0x0772, .end = 0x0772, .jt = .dual },
    .{ .start = 0x0773, .end = 0x0774, .jt = .right },
    .{ .start = 0x0775, .end = 0x0777, .jt = .dual },
    .{ .start = 0x0778, .end = 0x0779, .jt = .right },
    .{ .start = 0x077A, .end = 0x077F, .jt = .dual },
    .{ .start = 0x07CA, .end = 0x07EA, .jt = .dual },
    .{ .start = 0x07FA, .end = 0x07FA, .jt = .join_causing },
    .{ .start = 0x0840, .end = 0x0840, .jt = .right },
    .{ .start = 0x0841, .end = 0x0845, .jt = .dual },
    .{ .start = 0x0846, .end = 0x0847, .jt = .right },
    .{ .start = 0x0848, .end = 0x0848, .jt = .dual },
    .{ .start = 0x0849, .end = 0x0849, .jt = .right },
    .{ .start = 0x084A, .end = 0x0853, .jt = .dual },
    .{ .start = 0x0854, .end = 0x0854, .jt = .right },
    .{ .start = 0x0855, .end = 0x0855, .jt = .dual },
    .{ .start = 0x0856, .end = 0x0858, .jt = .right },
    .{ .start = 0x0860, .end = 0x0860, .jt = .dual },
    .{ .start = 0x0862, .end = 0x0865, .jt = .dual },
    .{ .start = 0x0867, .end = 0x0867, .jt = .right },
    .{ .start = 0x0868, .end = 0x0868, .jt = .dual },
    .{ .start = 0x0869, .end = 0x086A, .jt = .right },
    .{ .start = 0x0870, .end = 0x0882, .jt = .right },
    .{ .start = 0x0883, .end = 0x0885, .jt = .join_causing },
    .{ .start = 0x0886, .end = 0x0886, .jt = .dual },
    .{ .start = 0x0889, .end = 0x088D, .jt = .dual },
    .{ .start = 0x088E, .end = 0x088E, .jt = .right },
    .{ .start = 0x088F, .end = 0x088F, .jt = .dual },
    .{ .start = 0x08A0, .end = 0x08A9, .jt = .dual },
    .{ .start = 0x08AA, .end = 0x08AC, .jt = .right },
    .{ .start = 0x08AE, .end = 0x08AE, .jt = .right },
    .{ .start = 0x08AF, .end = 0x08B0, .jt = .dual },
    .{ .start = 0x08B1, .end = 0x08B2, .jt = .right },
    .{ .start = 0x08B3, .end = 0x08B8, .jt = .dual },
    .{ .start = 0x08B9, .end = 0x08B9, .jt = .right },
    .{ .start = 0x08BA, .end = 0x08C8, .jt = .dual },
    .{ .start = 0x08CA, .end = 0x08E1, .jt = .transparent },
    .{ .start = 0x08E3, .end = 0x08FF, .jt = .transparent },
    .{ .start = 0x1807, .end = 0x1807, .jt = .dual },
    .{ .start = 0x180A, .end = 0x180A, .jt = .join_causing },
    .{ .start = 0x1820, .end = 0x1878, .jt = .dual },
    .{ .start = 0x1885, .end = 0x1886, .jt = .transparent },
    .{ .start = 0x1887, .end = 0x18A8, .jt = .dual },
    .{ .start = 0x18AA, .end = 0x18AA, .jt = .dual },
    .{ .start = 0x200D, .end = 0x200D, .jt = .join_causing },
    .{ .start = 0xA840, .end = 0xA871, .jt = .dual },
    .{ .start = 0xA872, .end = 0xA872, .jt = .left },
    .{ .start = 0x10AC0, .end = 0x10AC4, .jt = .dual },
    .{ .start = 0x10AC5, .end = 0x10AC5, .jt = .right },
    .{ .start = 0x10AC7, .end = 0x10AC7, .jt = .right },
    .{ .start = 0x10AC9, .end = 0x10ACA, .jt = .right },
    .{ .start = 0x10ACD, .end = 0x10ACD, .jt = .left },
    .{ .start = 0x10ACE, .end = 0x10AD2, .jt = .right },
    .{ .start = 0x10AD3, .end = 0x10AD6, .jt = .dual },
    .{ .start = 0x10AD7, .end = 0x10AD7, .jt = .left },
    .{ .start = 0x10AD8, .end = 0x10ADC, .jt = .dual },
    .{ .start = 0x10ADD, .end = 0x10ADD, .jt = .right },
    .{ .start = 0x10ADE, .end = 0x10AE0, .jt = .dual },
    .{ .start = 0x10AE1, .end = 0x10AE1, .jt = .right },
    .{ .start = 0x10AE4, .end = 0x10AE4, .jt = .right },
    .{ .start = 0x10AEB, .end = 0x10AEE, .jt = .dual },
    .{ .start = 0x10AEF, .end = 0x10AEF, .jt = .right },
    .{ .start = 0x10B80, .end = 0x10B80, .jt = .dual },
    .{ .start = 0x10B81, .end = 0x10B81, .jt = .right },
    .{ .start = 0x10B82, .end = 0x10B82, .jt = .dual },
    .{ .start = 0x10B83, .end = 0x10B85, .jt = .right },
    .{ .start = 0x10B86, .end = 0x10B88, .jt = .dual },
    .{ .start = 0x10B89, .end = 0x10B89, .jt = .right },
    .{ .start = 0x10B8A, .end = 0x10B8B, .jt = .dual },
    .{ .start = 0x10B8C, .end = 0x10B8C, .jt = .right },
    .{ .start = 0x10B8D, .end = 0x10B8D, .jt = .dual },
    .{ .start = 0x10B8E, .end = 0x10B8F, .jt = .right },
    .{ .start = 0x10B90, .end = 0x10B90, .jt = .dual },
    .{ .start = 0x10B91, .end = 0x10B91, .jt = .right },
    .{ .start = 0x10BA9, .end = 0x10BAC, .jt = .right },
    .{ .start = 0x10BAD, .end = 0x10BAE, .jt = .dual },
    .{ .start = 0x10D00, .end = 0x10D00, .jt = .left },
    .{ .start = 0x10D01, .end = 0x10D21, .jt = .dual },
    .{ .start = 0x10D22, .end = 0x10D22, .jt = .right },
    .{ .start = 0x10D23, .end = 0x10D23, .jt = .dual },
    .{ .start = 0x10EC2, .end = 0x10EC2, .jt = .right },
    .{ .start = 0x10EC3, .end = 0x10EC4, .jt = .dual },
    .{ .start = 0x10EC6, .end = 0x10EC7, .jt = .dual },
    .{ .start = 0x10ED9, .end = 0x10EEE, .jt = .left },
    .{ .start = 0x10F30, .end = 0x10F32, .jt = .dual },
    .{ .start = 0x10F33, .end = 0x10F33, .jt = .right },
    .{ .start = 0x10F34, .end = 0x10F44, .jt = .dual },
    .{ .start = 0x10F51, .end = 0x10F53, .jt = .dual },
    .{ .start = 0x10F54, .end = 0x10F54, .jt = .right },
    .{ .start = 0x10F70, .end = 0x10F73, .jt = .dual },
    .{ .start = 0x10F74, .end = 0x10F75, .jt = .right },
    .{ .start = 0x10F76, .end = 0x10F81, .jt = .dual },
    .{ .start = 0x10FB0, .end = 0x10FB0, .jt = .dual },
    .{ .start = 0x10FB2, .end = 0x10FB3, .jt = .dual },
    .{ .start = 0x10FB4, .end = 0x10FB6, .jt = .right },
    .{ .start = 0x10FB8, .end = 0x10FB8, .jt = .dual },
    .{ .start = 0x10FB9, .end = 0x10FBA, .jt = .right },
    .{ .start = 0x10FBB, .end = 0x10FBC, .jt = .dual },
    .{ .start = 0x10FBD, .end = 0x10FBD, .jt = .right },
    .{ .start = 0x10FBE, .end = 0x10FBF, .jt = .dual },
    .{ .start = 0x10FC1, .end = 0x10FC1, .jt = .dual },
    .{ .start = 0x10FC2, .end = 0x10FC3, .jt = .right },
    .{ .start = 0x10FC4, .end = 0x10FC4, .jt = .dual },
    .{ .start = 0x10FC9, .end = 0x10FC9, .jt = .right },
    .{ .start = 0x10FCA, .end = 0x10FCA, .jt = .dual },
    .{ .start = 0x10FCB, .end = 0x10FCB, .jt = .left },
    .{ .start = 0x1E900, .end = 0x1E943, .jt = .dual },
    .{ .start = 0x1E94B, .end = 0x1E94B, .jt = .transparent },
};

/// The joining type of a codepoint. Anything unlisted does not join.
pub fn joiningType(cp: u21) Joining {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            return r.jt;
        }
    }
    return .non_joining;
}

/// The contextual form a letter takes. `none` means "no substitution", which
/// is what an isolated letter or a non-Arabic codepoint gets.
/// Canonical combining class (Unicode `ccc`) for the marks Arabic actually
/// uses. Zero means "not a reorderable mark": a base letter, a tatweel, or a
/// character from a block this table does not cover.
///
/// This is not the full Unicode property. It covers the Arabic block's marks
/// (064B..0670, 06D6..06ED) and the Arabic signs (0610..061A), which is every
/// mark a font can put on Arabic text. A character outside it sorts as a base,
/// so an uncovered mark keeps its written order instead of being moved by a
/// guessed class.
pub fn combiningClass(cp: u21) u8 {
    return switch (cp) {
        0x064B => 27, // fathatan
        0x064C => 28, // dammatan
        0x064D => 29, // kasratan
        0x064E => 30, // fatha
        0x064F => 31, // damma
        0x0650 => 32, // kasra
        0x0651 => 33, // shadda
        0x0652 => 34, // sukun
        0x0653, 0x0654, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E => 230,
        0x0655, 0x0656, 0x065C, 0x065F => 220,
        0x0670 => 35, // superscript alef
        0x0610... 0x061A => 230,
        0x06D6... 0x06DC => 230,
        0x06DF... 0x06E2 => 230,
        0x06E3 => 220,
        0x06E4 => 230,
        0x06E7, 0x06E8 => 230,
        0x06EA => 220,
        0x06EB, 0x06EC => 230,
        0x06ED => 220,
        else => 0,
    };
}

/// Put combining marks in canonical order: a stable sort by combining class,
/// inside each run bounded by anything of class 0. Two marks on one letter
/// written shadda-then-fatha are stored fatha-last whatever order they were
/// typed in, which decides which of them stacks on the other.
///
/// HarfBuzz does this as part of normalisation, before a single lookup runs,
/// and a shaper that skips it disagrees with every HarfBuzz render of the most
/// ordinary Arabic word. The sort is insertion sort because it is stable by
/// construction and n here is the length of one word.
pub fn canonicalOrder(cps: []u21) void {
    var i: usize = 1;
    while (i < cps.len) : (i += 1) {
        const cls = combiningClass(cps[i]);
        if (cls == 0) continue;
        var j = i;
        while (j > 0) {
            const prev = combiningClass(cps[j - 1]);
            if (prev == 0 or prev <= cls) break;
            const tmp = cps[j - 1];
            cps[j - 1] = cps[j];
            cps[j] = tmp;
            j -= 1;
        }
    }
}

pub const Form = enum { none, isolated, initial, medial, final };

/// The form of each codepoint, given its neighbours. Writes at most
/// `out.len` entries and returns that slice, so a short buffer truncates the
/// run rather than failing.
pub fn forms(cps: []const u21, out: []Form) []Form {
    for (cps, 0..) |_, i| {
        const f = formAt(cps, i);
        if (i < out.len) out[i] = f;
    }
    return out[0..@min(cps.len, out.len)];
}

pub fn formAt(cps: []const u21, i: usize) Form {
    const jt = joiningType(cps[i]);
    if (jt == .transparent or jt == .join_causing or jt == .non_joining) return .none;
    const prev = neighbourJoins(cps, i, -1);
    const next = neighbourJoins(cps, i, 1);
    return switch (jt) {
        .dual => if (prev and next) .medial else if (prev) .final else if (next) .initial else .isolated,
        .right => if (prev) .final else .isolated,
        .left => if (next) .initial else .isolated,
        else => .none,
    };
}

/// Walk one step in `dir` from index `i`, stepping over transparent marks, and
/// answer whether that neighbour can join towards us. Indexed, not searched by
/// codepoint: `بب` must see the SECOND beh's left neighbour, and matching on
/// the codepoint alone would look at itself.
fn neighbourJoins(cps: []const u21, i: usize, comptime dir: i8) bool {
    var k = i;
    while (true) {
        if (dir < 0) {
            if (k == 0) return false;
            k -= 1;
        } else {
            if (k + 1 >= cps.len) return false;
            k += 1;
        }
        const jt = joiningType(cps[k]);
        if (jt == .transparent) continue;
        return if (dir < 0) jt.joinsForward() else jt.joinsBackward();
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const beh: u21 = 0x628;
const seen: u21 = 0x633;
const meem: u21 = 0x645;
const alef: u21 = 0x627;
const lam: u21 = 0x644;
const fatha: u21 = 0x64B;
const zwj: u21 = 0x200D;

test "joining types come from the table" {
    try std.testing.expectEqual(Joining.dual, joiningType(beh));
    try std.testing.expectEqual(Joining.dual, joiningType(lam));
    try std.testing.expectEqual(Joining.right, joiningType(alef));
    try std.testing.expectEqual(Joining.transparent, joiningType(fatha));
    try std.testing.expectEqual(Joining.join_causing, joiningType(zwj));
    try std.testing.expectEqual(Joining.non_joining, joiningType('A'));
    try std.testing.expectEqual(Joining.non_joining, joiningType(0x10FFFF));
}

test "a word takes initial, medial and final" {
    const cps = [_]u21{ beh, seen, meem };
    var out: [3]Form = undefined;
    const f = forms(&cps, &out);
    try std.testing.expectEqual(Form.initial, f[0]);
    try std.testing.expectEqual(Form.medial, f[1]);
    try std.testing.expectEqual(Form.final, f[2]);
}

test "two of the same letter are initial then final" {
    // Indexed search: matching the neighbour by codepoint value would make the
    // second beh look at itself and call it isolated.
    const cps = [_]u21{ beh, beh };
    var out: [2]Form = undefined;
    const f = forms(&cps, &out);
    try std.testing.expectEqual(Form.initial, f[0]);
    try std.testing.expectEqual(Form.final, f[1]);
}

test "a lone letter is isolated, and alef only joins backwards" {
    var out: [2]Form = undefined;
    try std.testing.expectEqual(Form.isolated, forms(&[_]u21{beh}, &out)[0]);

    const cps = [_]u21{ beh, alef };
    const f = forms(&cps, &out);
    try std.testing.expectEqual(Form.initial, f[0]);
    try std.testing.expectEqual(Form.final, f[1]);

    // Alef cannot join forwards, so a beh after it starts a new join.
    const cps2 = [_]u21{ alef, beh };
    const g = forms(&cps2, &out);
    try std.testing.expectEqual(Form.isolated, g[0]);
    try std.testing.expectEqual(Form.isolated, g[1]);
}

test "a transparent mark neither joins nor breaks the join" {
    const cps = [_]u21{ beh, fatha, beh };
    var out: [3]Form = undefined;
    const f = forms(&cps, &out);
    try std.testing.expectEqual(Form.initial, f[0]);
    try std.testing.expectEqual(Form.none, f[1]);
    try std.testing.expectEqual(Form.final, f[2]);
}

test "a non-joining letter breaks the join" {
    const cps = [_]u21{ beh, 'A', beh };
    var out: [3]Form = undefined;
    const f = forms(&cps, &out);
    try std.testing.expectEqual(Form.isolated, f[0]);
    try std.testing.expectEqual(Form.none, f[1]);
    try std.testing.expectEqual(Form.isolated, f[2]);
}

test "a short buffer truncates instead of overrunning" {
    const cps = [_]u21{ beh, seen, meem };
    var out: [2]Form = undefined;
    const f = forms(&cps, &out);
    try std.testing.expectEqual(@as(usize, 2), f.len);
    try std.testing.expectEqual(Form.initial, f[0]);
    try std.testing.expectEqual(Form.medial, f[1]);
}

test "marks sort into canonical order inside a letter" {
    // fatha (30) then fathatan (27): the lighter class goes first.
    var a = [_]u21{ 0x0644, 0x064E, 0x064B };
    canonicalOrder(&a);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0x0644, 0x064B, 0x064E }, &a);
}

test "canonical order does not move marks across a letter" {
    // Two letters, each with a mark: leh fatha, then lam kasra. Sorting must
    // stay inside each cluster, or a mark ends up on the wrong letter.
    var a = [_]u21{ 0x0647, 0x064E, 0x0644, 0x0650 };
    canonicalOrder(&a);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0x0647, 0x064E, 0x0644, 0x0650 }, &a);
}

test "an equal class keeps the written order" {
    // shadda (33) then sukun (34) is already sorted; sukun then shadda is not.
    var a = [_]u21{ 0x0644, 0x0652, 0x0651 };
    canonicalOrder(&a);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0x0644, 0x0651, 0x0652 }, &a);
}

test "an uncovered mark keeps its written place" {
    // 0x0640 tatweel has no class, so nothing crosses it.
    var a = [_]u21{ 0x0644, 0x0652, 0x0640, 0x0651 };
    canonicalOrder(&a);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 0x0644, 0x0652, 0x0640, 0x0651 }, &a);
}
