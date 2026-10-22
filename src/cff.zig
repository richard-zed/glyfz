//! CFF container reading: the outline format CJK fonts actually ship.
//!
//! This is the layer under the charstrings, not the interpreter. It resolves
//! what a Type 2 charstring needs in order to be run at all: the CharStrings
//! INDEX, the global subroutines, and -- for the CID-keyed faces that are the
//! norm for Chinese, Japanese and Korean -- the FDArray and FDSelect, because
//! a CID face carries one Private DICT and one local subroutine set PER
//! element, not per font.
//!
//! Offsets are relative to the start of the CFF data, which is the start of
//! the table as it appears in the font file. Nothing here allocates; every
//! reader walks the bytes the caller already owns and returns a slice into
//! them, or an error.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

pub const Error = error{
    /// The data ended before the structure did.
    Truncated,
    /// Not a CFF table at all.
    NotCff,
    /// A well-formed CFF that uses something this reader does not implement
    /// yet. Distinct from Truncated on purpose: one means the font is broken,
    /// the other means the reader is.
    Unsupported,
    /// A required structure is absent.
    MissingTable,
    /// The caller's segment or point buffer was too small for this glyph.
    BufferTooSmall,
    /// Subroutines nested deeper than the spec allows.
    SubrTooDeep,
};

/// DICT operator numbers used here, with 1200 added to two-byte operators so
/// they cannot collide with one-byte ones.
pub const op = struct {
    pub const char_strings: u16 = 17;
    pub const private: u16 = 18;
    pub const subrs: u16 = 19;
    pub const default_width_x: u16 = 20;
    pub const nominal_width_x: u16 = 21;
    pub const charstring_type: u16 = 1206;
    pub const ros: u16 = 1230;
    pub const fd_array: u16 = 1236;
    pub const fd_select: u16 = 1237;
};

fn u8At(d: []const u8, p: usize) Error!u8 {
    if (p >= d.len) return error.Truncated;
    return d[p];
}

fn u16At(d: []const u8, p: usize) Error!u16 {
    if (p + 2 > d.len) return error.Truncated;
    return @as(u16, d[p]) << 8 | d[p + 1];
}

fn u32At(d: []const u8, p: usize) Error!u32 {
    if (p + 4 > d.len) return error.Truncated;
    return @as(u32, d[p]) << 24 | @as(u32, d[p + 1]) << 16 |
        @as(u32, d[p + 2]) << 8 | d[p + 3];
}

/// A CFF INDEX: a count, a table of big-endian offsets, then the data. The
/// offsets are one-based, so offset 1 means the first byte of the data.
pub const Index = struct {
    /// Position of the first offset; the count sits just before it.
    offsets_at: usize,
    /// Bytes per offset, 1 to 4.
    off_size: u8,
    count: u16,
    /// First byte of the data region.
    data_at: usize,
    /// One past the last byte of the data region.
    end_at: usize,

    fn rawOffset(self: Index, d: []const u8, i: usize) Error!usize {
        var v: usize = 0;
        var k: usize = 0;
        const at = self.offsets_at + i * self.off_size;
        while (k < self.off_size) : (k += 1) {
            v = v << 8 | try u8At(d, at + k);
        }
        return v;
    }

    /// The i-th item, as a slice of the font's own bytes.
    pub fn get(self: Index, d: []const u8, i: usize) Error![]const u8 {
        if (i >= self.count) return error.MissingTable;
        const a = try self.rawOffset(d, i);
        const b = try self.rawOffset(d, i + 1);
        if (a < 1 or b < a) return error.Truncated;
        const s = self.data_at + a - 1;
        const e = self.data_at + b - 1;
        if (e > self.end_at or s > e) return error.Truncated;
        return d[s..e];
    }

    /// First byte after this INDEX, so the next one can be read.
    pub fn end(self: Index) usize {
        return self.end_at;
    }
};

/// Read an INDEX at `at`. An empty INDEX is two bytes and nothing else.
pub fn indexAt(d: []const u8, at: usize) Error!Index {
    const count = try u16At(d, at);
    if (count == 0) {
        return .{ .offsets_at = at + 2, .off_size = 0, .count = 0, .data_at = at + 2, .end_at = at + 2 };
    }
    const off_size = try u8At(d, at + 2);
    if (off_size == 0 or off_size > 4) return error.Unsupported;
    const offsets_at = at + 3;
    const data_at = offsets_at + (@as(usize, count) + 1) * off_size;
    var probe = Index{ .offsets_at = offsets_at, .off_size = off_size, .count = count, .data_at = data_at, .end_at = data_at };
    const last = try probe.rawOffset(d, count);
    if (last < 1) return error.Truncated;
    probe.end_at = data_at + last - 1;
    if (probe.end_at > d.len) return error.Truncated;
    return probe;
}

/// The operand bytes of the last occurrence of `want` in a DICT, or null.
///
/// Last wins because that is how a DICT overrides itself; a reader that took
/// the first would honour a stale value in a font that redefines one.
pub fn dictFind(dict: []const u8, want: u16) Error!?[]const u8 {
    var i: usize = 0;
    var found: ?[]const u8 = null;
    while (i < dict.len) {
        const start = i;
        while (i < dict.len) {
            const b = dict[i];
            if (b <= 21) break;
            if (b == 28) {
                i += 3;
            } else if (b == 29) {
                i += 5;
            } else if (b == 30) {
                // Real: nibbles until one of them is 0xf.
                i += 1;
                while (i < dict.len) {
                    const nb = dict[i];
                    i += 1;
                    if ((nb & 0x0f) == 0x0f or (nb >> 4) == 0x0f) break;
                }
            } else if (b <= 246) {
                i += 1;
            } else if (b <= 254) {
                i += 2;
            } else {
                return error.Unsupported;
            }
        }
        if (i >= dict.len) return error.Truncated;
        const operands = dict[start..i];
        var key: u16 = dict[i];
        i += 1;
        if (key == 12) {
            const second = try u8At(dict, i);
            i += 1;
            key = 1200 + @as(u16, second);
        }
        if (key == want) found = operands;
    }
    return found;
}

/// Decode the integer operands of a DICT entry, in order.
///
/// Reals are refused rather than approximated: every operator read here takes
/// integers by spec, so a real in one of them means the font is doing
/// something unexpected and a rounded number would hide it.
pub fn dictNumbers(operands: []const u8, out: []i32) Error!usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < operands.len) {
        if (n >= out.len) return error.Unsupported;
        const b = operands[i];
        if (b >= 32 and b <= 246) {
            out[n] = @as(i32, b) - 139;
            i += 1;
        } else if (b >= 247 and b <= 250) {
            out[n] = (@as(i32, b) - 247) * 256 + @as(i32, try u8At(operands, i + 1)) + 108;
            i += 2;
        } else if (b >= 251 and b <= 254) {
            out[n] = -(@as(i32, b) - 251) * 256 - @as(i32, try u8At(operands, i + 1)) - 108;
            i += 2;
        } else if (b == 28) {
            const hi = try u8At(operands, i + 1);
            const lo = try u8At(operands, i + 2);
            out[n] = @as(i16, @bitCast(@as(u16, hi) << 8 | lo));
            i += 3;
        } else if (b == 29) {
            out[n] = @bitCast(try u32At(operands, i + 1));
            i += 5;
        } else {
            return error.Unsupported;
        }
        n += 1;
    }
    return n;
}

fn dictOne(operands: []const u8) Error!i32 {
    var buf: [4]i32 = undefined;
    const n = try dictNumbers(operands, &buf);
    if (n == 0) return error.Truncated;
    return buf[n - 1];
}

/// One Private DICT: where it lives, its local subroutines, and the widths the
/// charstring interpreter needs to turn a relative width into an advance.
pub const Private = struct {
    size: usize,
    offset: usize,
    default_width_x: i32 = 0,
    nominal_width_x: i32 = 0,
    /// Null when the DICT declares no Subrs operator, which is legal.
    local_subrs: ?Index = null,

    fn read(d: []const u8, size: usize, offset: usize) Error!Private {
        if (offset > d.len or size > d.len - offset) return error.Truncated;
        const dict = d[offset .. offset + size];
        var p = Private{ .size = size, .offset = offset };
        if (try dictFind(dict, op.default_width_x)) |v| p.default_width_x = try dictOne(v);
        if (try dictFind(dict, op.nominal_width_x)) |v| p.nominal_width_x = try dictOne(v);
        if (try dictFind(dict, op.subrs)) |v| {
            const rel = try dictOne(v);
            if (rel < 0) return error.Truncated;
            p.local_subrs = try indexAt(d, offset + @as(usize, @intCast(rel)));
        }
        return p;
    }
};

/// A CFF face as far as the container goes.
pub const Font = struct {
    data: []const u8,
    top_dict: []const u8,
    char_strings: Index,
    global_subrs: Index,
    /// For a non-CID face this is the font's one Private DICT.
    private: ?Private = null,
    /// CID-keyed: one font dict per element, each with its own Private.
    is_cid: bool = false,
    fd_array: ?Index = null,
    fd_select_at: ?usize = null,
    charstring_type: u16 = 2,

    pub fn init(data: []const u8) Error!Font {
        if (data.len < 4) return error.Truncated;
        if (data[0] != 1) {
            // CFF2 has no NAME INDEX and a different header. Refusing it here
            // keeps the error honest instead of misreading its bytes.
            return error.NotCff;
        }
        const hdr_size = data[2];
        if (hdr_size < 4 or hdr_size > data.len) return error.Truncated;

        const names = try indexAt(data, hdr_size);
        if (names.count == 0) return error.MissingTable;
        const tops = try indexAt(data, names.end());
        if (tops.count == 0) return error.MissingTable;
        const strings = try indexAt(data, tops.end());
        const gsubrs = try indexAt(data, strings.end());

        const top_dict = try tops.get(data, 0);
        var f = Font{ .data = data, .top_dict = top_dict, .char_strings = undefined, .global_subrs = gsubrs };

        const cs = (try dictFind(top_dict, op.char_strings)) orelse return error.MissingTable;
        const cs_rel = try dictOne(cs);
        if (cs_rel < 0) return error.Truncated;
        f.char_strings = try indexAt(data, @intCast(cs_rel));

        if (try dictFind(top_dict, op.charstring_type)) |v| {
            const t = try dictOne(v);
            if (t < 0 or t > 2) return error.Unsupported;
            f.charstring_type = @intCast(t);
        }

        if (try dictFind(top_dict, op.private)) |v| {
            var nums: [4]i32 = undefined;
            const n = try dictNumbers(v, &nums);
            if (n != 2) return error.Unsupported;
            if (nums[0] < 0 or nums[1] < 0) return error.Truncated;
            f.private = try Private.read(data, @intCast(nums[0]), @intCast(nums[1]));
        }

        f.is_cid = (try dictFind(top_dict, op.ros)) != null;
        if (try dictFind(top_dict, op.fd_array)) |v| {
            const rel = try dictOne(v);
            if (rel < 0) return error.Truncated;
            f.fd_array = try indexAt(data, @intCast(rel));
        }
        if (try dictFind(top_dict, op.fd_select)) |v| {
            const rel = try dictOne(v);
            if (rel < 0) return error.Truncated;
            f.fd_select_at = @intCast(rel);
        }

        // A CID face with no FDArray cannot resolve a Private DICT or a local
        // subroutine, so its charstrings could not be interpreted correctly.
        if (f.is_cid and f.fd_array == null) return error.MissingTable;
        return f;
    }

    pub fn glyphCount(self: Font) usize {
        return self.char_strings.count;
    }

    /// The charstring for a glyph, as stored: not yet interpreted.
    pub fn charString(self: Font, gid: usize) Error![]const u8 {
        return self.char_strings.get(self.data, gid);
    }

    /// Which font dict a CID-keyed glyph belongs to.
    ///
    /// FDSelect format 3 is ranges and format 0 is one byte per glyph; both
    /// appear in real CJK faces, so neither can be left out.
    pub fn fdIndex(self: Font, gid: usize) Error!usize {
        const at = self.fd_select_at orelse return 0;
        const fmt = try u8At(self.data, at);
        switch (fmt) {
            0 => return try u8At(self.data, at + 1 + gid),
            3 => {
                const n_ranges = try u16At(self.data, at + 1);
                var i: usize = 0;
                while (i < n_ranges) : (i += 1) {
                    const rec = at + 3 + i * 3;
                    const first = try u16At(self.data, rec);
                    const fd = try u8At(self.data, rec + 2);
                    const next_at = rec + 3;
                    const next_first = if (i + 1 < n_ranges) try u16At(self.data, next_at) else blk: {
                        break :blk try u16At(self.data, at + 3 + n_ranges * 3);
                    };
                    if (gid >= first and gid < next_first) return fd;
                }
                return error.MissingTable;
            },
            else => return error.Unsupported,
        }
    }

    /// The Private DICT governing a glyph: the font's own, or the CID
    /// element's.
    pub fn privateFor(self: Font, gid: usize) Error!?Private {
        if (!self.is_cid) return self.private;
        const fds = self.fd_array orelse return error.MissingTable;
        const fd = try self.fdIndex(gid);
        if (fd >= fds.count) return error.MissingTable;
        const font_dict = try fds.get(self.data, fd);
        const v = (try dictFind(font_dict, op.private)) orelse return null;
        var nums: [4]i32 = undefined;
        const n = try dictNumbers(v, &nums);
        if (n != 2) return error.Unsupported;
        if (nums[0] < 0 or nums[1] < 0) return error.Truncated;
        return try Private.read(self.data, @intCast(nums[0]), @intCast(nums[1]));
    }
};

// -- tests -------------------------------------------------------------

const B = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn put(self: *B, src: []const u8) usize {
        const at = self.len;
        @memcpy(self.buf[at .. at + src.len], src);
        self.len += src.len;
        return at;
    }
    fn u8_(self: *B, v: u8) usize {
        const at = self.len;
        self.buf[at] = v;
        self.len += 1;
        return at;
    }
    fn u16_(self: *B, v: u16) usize {
        const at = self.len;
        self.buf[at] = @truncate(v >> 8);
        self.buf[at + 1] = @truncate(v);
        self.len += 2;
        return at;
    }
    fn i32_(self: *B, v: i32) usize {
        const at = self.len;
        const u: u32 = @bitCast(v);
        self.buf[at] = @truncate(u >> 24);
        self.buf[at + 1] = @truncate(u >> 16);
        self.buf[at + 2] = @truncate(u >> 8);
        self.buf[at + 3] = @truncate(u);
        self.len += 4;
        return at;
    }
    fn patch32(self: *B, at: usize, v: i32) void {
        const u: u32 = @bitCast(v);
        self.buf[at] = @truncate(u >> 24);
        self.buf[at + 1] = @truncate(u >> 16);
        self.buf[at + 2] = @truncate(u >> 8);
        self.buf[at + 3] = @truncate(u);
    }
    fn index(self: *B, items: []const []const u8) void {
        if (items.len == 0) {
            _ = self.u16_(0);
            return;
        }
        _ = self.u16_(@intCast(items.len));
        _ = self.u8_(1); // offSize
        var off: u8 = 1;
        _ = self.u8_(1);
        for (items) |it| {
            off += @intCast(it.len);
            _ = self.u8_(off);
        }
        for (items) |it| _ = self.put(it);
    }
    fn bytes(self: *B) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Write a single-entry Top DICT INDEX around pre-assembled DICT bytes and
/// return where those bytes landed, so fields can be patched afterwards.
fn topIndex(b: *B, data: []const u8) usize {
    _ = b.u16_(1);
    _ = b.u8_(1); // offSize
    _ = b.u8_(1);
    _ = b.u8_(@intCast(1 + data.len));
    return b.put(data);
}

/// header, Name INDEX, a Top DICT carrying only CharStrings, empty String and
/// global-subr INDEXes, then the CharStrings INDEX and a patch of the offset.
fn minimal(b: *B, charstrings: []const []const u8) void {
    _ = b.put(&.{ 1, 0, 4, 1 }); // major, minor, hdrSize, offSize
    b.index(&.{"Test"});

    var dict = [_]u8{0} ** 6;
    dict[0] = 29; // 32-bit operand
    dict[5] = op.char_strings;
    const dict_at = topIndex(b, &dict);

    b.index(&.{}); // String INDEX
    b.index(&.{}); // Global Subr INDEX

    const cs_at = b.len;
    b.index(charstrings);
    b.patch32(dict_at + 1, @intCast(cs_at));
}

test "a minimal face resolves its charstrings" {
    var b = B{};
    minimal(&b, &.{ "abc", "de", "" });
    const f = try Font.init(b.bytes());
    try expectEqual(@as(usize, 3), f.glyphCount());
    try std.testing.expectEqualSlices(u8, "abc", try f.charString(0));
    try std.testing.expectEqualSlices(u8, "de", try f.charString(1));
    try expectEqual(@as(usize, 0), (try f.charString(2)).len);
    try expect(!f.is_cid);
    try expect(f.private == null);
}

test "the container never reads past a truncated table" {
    var b = B{};
    minimal(&b, &.{ "abc", "de" });
    const full = b.bytes();
    // Every prefix either parses or errors; a panic, or an "empty but valid"
    // face, is the failure this catches.
    var len: usize = 0;
    var parsed: usize = 0;
    while (len <= full.len) : (len += 1) {
        if (Font.init(full[0..len])) |f| {
            parsed += 1;
            try expect(f.glyphCount() > 0);
        } else |_| {}
    }
    try expect(parsed > 0);
    try expect(parsed < full.len);
}

test "a face that is not CFF is refused, not misread" {
    // CFF2 starts 0x02 and has no NAME INDEX; reading it as CFF1 would take
    // the Top DICT INDEX from the wrong place.
    const fake = [_]u8{ 2, 0, 5, 2, 0, 0, 0, 0 };
    try expectError(error.NotCff, Font.init(&fake));
    try expectError(error.Truncated, Font.init(&[_]u8{ 1, 0 }));
}

test "a private dict yields its widths and local subroutines" {
    var b = B{};
    _ = b.put(&.{ 1, 0, 4, 1 });
    b.index(&.{"Test"});

    // CharStrings, then Private (size, offset): 17 bytes, patched below.
    var dict = [_]u8{0} ** 17;
    dict[0] = 29;
    dict[5] = op.char_strings;
    dict[6] = 29;
    dict[11] = 29;
    dict[16] = op.private;
    const dict_at = topIndex(&b, &dict);

    b.index(&.{}); // String INDEX
    b.index(&.{}); // Global Subr INDEX

    const cs_at = b.len;
    b.index(&.{"a"});

    // Private DICT: defaultWidthX 500, nominalWidthX 400, then Subrs at a
    // relative offset patched once the subr INDEX has been written.
    const priv_at = b.len;
    _ = b.u8_(29); // 32-bit operand prefix
    _ = b.i32_(500);
    _ = b.u8_(op.default_width_x);
    _ = b.u8_(29);
    _ = b.i32_(400);
    _ = b.u8_(op.nominal_width_x);
    _ = b.u8_(29);
    const subrs_slot = b.len;
    _ = b.i32_(0); // patched to the local subr INDEX, relative to priv_at
    _ = b.u8_(op.subrs);
    const priv_len = b.len - priv_at;
    const subrs_at = b.len;
    b.index(&.{"xyz"});
    b.patch32(subrs_slot, @intCast(subrs_at - priv_at));

    b.patch32(dict_at + 1, @intCast(cs_at));
    b.patch32(dict_at + 7, @intCast(priv_len));
    b.patch32(dict_at + 12, @intCast(priv_at));

    const f = try Font.init(b.bytes());
    const p = f.private.?;
    try expectEqual(@as(i32, 500), p.default_width_x);
    try expectEqual(@as(i32, 400), p.nominal_width_x);
    const subrs = p.local_subrs.?;
    try expectEqual(@as(u16, 1), subrs.count);
    try std.testing.expectEqualSlices(u8, "xyz", try subrs.get(f.data, 0));
}

test "dict operators keep the last value and skip reals" {
    var b = B{};
    // 100, then 60, then CharStrings.
    _ = b.u8_(100 + 139);
    _ = b.u8_(60 + 139);
    _ = b.u8_(op.char_strings);
    var nums: [4]i32 = undefined;
    const n = try dictNumbers((try dictFind(b.bytes(), op.char_strings)).?, &nums);
    try expectEqual(@as(usize, 2), n);
    try expectEqual(@as(i32, 60), nums[1]);

    // A real number is refused rather than rounded.
    var c = B{};
    _ = c.put(&.{ 30, 0x1a, 0x5f }); // 1.5, then terminator nibble
    _ = c.u8_(op.char_strings);
    try expectError(error.Unsupported, dictNumbers((try dictFind(c.bytes(), op.char_strings)).?, &nums));
}

// -- Type 2 charstrings -------------------------------------------------

/// One step of a Type 2 charstring, in absolute font units, y up.
///
/// Curves stay cubic here. Turning them into the quadratic points a glyf-based
/// rasteriser wants is a decision that needs a target size, so it belongs to
/// the caller, not to the interpreter.
pub const Segment = union(enum) {
    move: [2]f32,
    line: [2]f32,
    /// c1x, c1y, c2x, c2y, x, y
    cubic: [6]f32,
    close: void,
};

/// Accumulates segments into the caller's buffer and tracks the current point.
pub const Pen = struct {
    /// Null means count only: the outline is measured, not stored. That is how
    /// a caller gets a glyph's bounds without owning a segment buffer.
    out: ?[]Segment,
    n: usize = 0,
    x: f32 = 0,
    y: f32 = 0,
    open: bool = false,
    any: bool = false,
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,

    fn note(self: *Pen, x: f32, y: f32) void {
        if (!self.any) {
            self.min_x = x;
            self.max_x = x;
            self.min_y = y;
            self.max_y = y;
            self.any = true;
            return;
        }
        self.min_x = @min(self.min_x, x);
        self.max_x = @max(self.max_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_y = @max(self.max_y, y);
    }

    fn push(self: *Pen, s: Segment) Error!void {
        if (self.out) |o| {
            if (self.n >= o.len) return error.BufferTooSmall;
            o[self.n] = s;
        }
        self.n += 1;
    }

    fn moveTo(self: *Pen, dx: f32, dy: f32) Error!void {
        // A moveto without an intervening endchar closes the previous contour,
        // or the rasteriser sees two contours joined by a straight line.
        if (self.open) try self.push(.close);
        self.x += dx;
        self.y += dy;
        self.note(self.x, self.y);
        try self.push(.{ .move = .{ self.x, self.y } });
        self.open = true;
    }

    fn lineTo(self: *Pen, dx: f32, dy: f32) Error!void {
        self.x += dx;
        self.y += dy;
        self.note(self.x, self.y);
        try self.push(.{ .line = .{ self.x, self.y } });
    }

    fn curveTo(self: *Pen, args: []const f32) Error!void {
        const c1x = self.x + args[0];
        const c1y = self.y + args[1];
        const c2x = c1x + args[2];
        const c2y = c1y + args[3];
        self.x = c2x + args[4];
        self.y = c2y + args[5];
        // Control points count toward the bounds: the curve cannot leave their
        // convex hull, so this box is a superset of the ink and never clips.
        self.note(c1x, c1y);
        self.note(c2x, c2y);
        self.note(self.x, self.y);
        try self.push(.{ .cubic = .{ c1x, c1y, c2x, c2y, self.x, self.y } });
    }
};

/// The spec allows 48 operands on the stack.
const stack_max = 48;
/// The spec allows 10 nested subroutine calls.
const call_max = 10;
/// Transient storage used by put/get.
const transient_max = 32;

const Run = struct {
    data: []const u8,
    pen: Pen,
    st: [stack_max]f32 = undefined,
    sp: usize = 0,
    hints: usize = 0,
    width_seen: bool = false,
    local: ?Index,
    global_subrs: Index,
    transient: [transient_max]f32 = @splat(0),

    fn push(self: *Run, v: f32) Error!void {
        if (self.sp >= stack_max) return error.Unsupported;
        self.st[self.sp] = v;
        self.sp += 1;
    }

    fn argsAt(self: *Run) []const f32 {
        return self.st[0..self.sp];
    }

    /// Consume a leading width if this is the first stack-clearing operator.
    /// `odd_means_width` covers every operator that takes an even number of
    /// arguments; hmoveto and vmoveto take one, so they pass false and land
    /// here with two.
    fn widthShift(self: *Run, odd_means_width: bool) usize {
        if (self.width_seen) return 0;
        self.width_seen = true;
        const n = self.sp;
        const odd = (n % 2) == 1;
        if (odd_means_width) return if (odd) 1 else 0;
        return if (n > 1) 1 else 0;
    }
};

fn charAt(code: []const u8, at: usize) Error!u8 {
    if (at >= code.len) return error.Truncated;
    return code[at];
}

fn subrBias(count: usize) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

/// Run a charstring, emitting segments. Returns how many were written.
pub fn charstring(f: Font, gid: usize, out: []Segment) Error![]Segment {
    const code = try f.charString(gid);
    const priv = try f.privateFor(gid);
    var run = Run{
        .data = f.data,
        .pen = .{ .out = out },
        .local = if (priv) |p| p.local_subrs else null,
        .global_subrs = f.global_subrs,
    };
    _ = try exec(&run, code, 0);
    if (run.pen.open) try run.pen.push(.close);
    return out[0..run.pen.n];
}

/// The glyph's bounds in font units, control points included, without needing
/// a segment buffer. Null for a glyph with no path at all.
pub fn charstringBox(f: Font, gid: usize) Error!?Bounds {
    const code = try f.charString(gid);
    const priv = try f.privateFor(gid);
    var run = Run{
        .data = f.data,
        .pen = .{ .out = null },
        .local = if (priv) |p| p.local_subrs else null,
        .global_subrs = f.global_subrs,
    };
    _ = try exec(&run, code, 0);
    if (!run.pen.any) return null;
    return .{ .x0 = run.pen.min_x, .y0 = run.pen.min_y, .x1 = run.pen.max_x, .y1 = run.pen.max_y };
}

pub const Bounds = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

fn exec(run: *Run, code: []const u8, depth: u8) Error!bool {
    if (depth > call_max) return error.SubrTooDeep;
    var pc: usize = 0;
    while (pc < code.len) {
        const b = code[pc];
        if (b >= 32 or b == 28 or b == 255) {
            var v: f32 = 0;
            if (b == 28) {
                const hi = try charAt(code, pc + 1);
                const lo = try charAt(code, pc + 2);
                v = @floatFromInt(@as(i16, @bitCast(@as(u16, hi) << 8 | lo)));
                pc += 3;
            } else if (b == 255) {
                const u: u32 = @as(u32, try charAt(code, pc + 1)) << 24 |
                    @as(u32, try charAt(code, pc + 2)) << 16 |
                    @as(u32, try charAt(code, pc + 3)) << 8 |
                    @as(u32, try charAt(code, pc + 4));
                v = @as(f32, @floatFromInt(@as(i32, @bitCast(u)))) / 65536.0;
                pc += 5;
            } else if (b <= 246) {
                v = @floatFromInt(@as(i32, b) - 139);
                pc += 1;
            } else if (b <= 250) {
                v = @floatFromInt((@as(i32, b) - 247) * 256 + @as(i32, try charAt(code, pc + 1)) + 108);
                pc += 2;
            } else {
                v = -@as(f32, @floatFromInt((@as(i32, b) - 251) * 256 + @as(i32, try charAt(code, pc + 1)) + 108));
                pc += 2;
            }
            try run.push(v);
            continue;
        }
        pc += 1;

        switch (b) {
            // Stems. The hints themselves are never applied: a rasteriser
            // without hinting has no use for them. They are COUNTED, because
            // hintmask sizes its mask from that count.
            1, 3, 18, 23 => {
                const shift = run.widthShift(true);
                const n = run.sp - shift;
                run.hints += n / 2;
                run.sp = 0;
            },
            19, 20 => {
                // When a mask operator carries operands they are the missing
                // vstem hints, so they count too.
                const shift = run.widthShift(true);
                const n = run.sp - shift;
                run.hints += n / 2;
                run.sp = 0;
                const mask_bytes = (run.hints + 7) / 8;
                pc += mask_bytes;
                if (pc > code.len) return error.Truncated;
            },
            21 => { // rmoveto
                const shift = run.widthShift(true);
                const a = run.argsAt()[shift..];
                if (a.len < 2) return error.Truncated;
                try run.pen.moveTo(a[0], a[1]);
                run.sp = 0;
            },
            22 => { // hmoveto
                const shift = run.widthShift(false);
                const a = run.argsAt()[shift..];
                if (a.len < 1) return error.Truncated;
                try run.pen.moveTo(a[0], 0);
                run.sp = 0;
            },
            4 => { // vmoveto
                const shift = run.widthShift(false);
                const a = run.argsAt()[shift..];
                if (a.len < 1) return error.Truncated;
                try run.pen.moveTo(0, a[0]);
                run.sp = 0;
            },
            5 => { // rlineto
                const a = run.argsAt();
                var i: usize = 0;
                while (i + 1 < a.len) : (i += 2) try run.pen.lineTo(a[i], a[i + 1]);
                run.sp = 0;
            },
            6, 7 => { // hlineto / vlineto, alternating
                const a = run.argsAt();
                var horizontal = b == 6;
                for (a) |v| {
                    if (horizontal) try run.pen.lineTo(v, 0) else try run.pen.lineTo(0, v);
                    horizontal = !horizontal;
                }
                run.sp = 0;
            },
            8 => { // rrcurveto
                const a = run.argsAt();
                if (a.len % 6 != 0) return error.Truncated;
                var i: usize = 0;
                while (i + 5 < a.len) : (i += 6) try run.pen.curveTo(a[i..][0..6]);
                run.sp = 0;
            },
            24 => { // rcurveline: curves, then one line
                const a = run.argsAt();
                if (a.len < 2) return error.Truncated;
                const line_at = a.len - 2;
                var i: usize = 0;
                while (i + 6 <= line_at) : (i += 6) try run.pen.curveTo(a[i..][0..6]);
                try run.pen.lineTo(a[line_at], a[line_at + 1]);
                run.sp = 0;
            },
            25 => { // rlinecurve: lines, then one curve
                const a = run.argsAt();
                if (a.len < 6) return error.Truncated;
                const curve_at = a.len - 6;
                var i: usize = 0;
                while (i + 2 <= curve_at) : (i += 2) try run.pen.lineTo(a[i], a[i + 1]);
                try run.pen.curveTo(a[curve_at..][0..6]);
                run.sp = 0;
            },
            26 => { // vvcurveto: optional dx1, then (dy1 dx2 dy2 dy3)*
                const a = run.argsAt();
                var i: usize = 0;
                var dx1: f32 = 0;
                if (a.len % 4 == 1) {
                    dx1 = a[0];
                    i = 1;
                }
                while (i + 3 < a.len) : (i += 4) {
                    try run.pen.curveTo(&.{ dx1, a[i], a[i + 1], a[i + 2], 0, a[i + 3] });
                    dx1 = 0;
                }
                run.sp = 0;
            },
            27 => { // hhcurveto: optional dy1, then (dx1 dx2 dy2 dx3)*
                const a = run.argsAt();
                var i: usize = 0;
                var dy1: f32 = 0;
                if (a.len % 4 == 1) {
                    dy1 = a[0];
                    i = 1;
                }
                while (i + 3 < a.len) : (i += 4) {
                    try run.pen.curveTo(&.{ a[i], dy1, a[i + 1], a[i + 2], a[i + 3], 0 });
                    dy1 = 0;
                }
                run.sp = 0;
            },
            30, 31 => { // vhcurveto / hvcurveto
                // These alternate between an h-group and a v-group, each
                // taking four arguments, and only the very last group may
                // carry a fifth: the component on the axis that group does
                // not end on. Getting the 5th argument's axis or its placement
                // wrong shifts every following point.
                const a = run.argsAt();
                var i: usize = 0;
                var horizontal = b == 31; // hv starts horizontal, vh vertical
                while (i < a.len) {
                    const rem = a.len - i;
                    if (rem < 4) return error.Truncated;
                    const extra: f32 = if (rem == 5) a[i + 4] else 0;
                    if (horizontal) {
                        // (dxa, 0) (dxb, dyb) (dxc, dyc)
                        try run.pen.curveTo(&.{ a[i], 0, a[i + 1], a[i + 2], extra, a[i + 3] });
                    } else {
                        // (0, dya) (dxb, dyb) (dxc, dyc)
                        try run.pen.curveTo(&.{ 0, a[i], a[i + 1], a[i + 2], a[i + 3], extra });
                    }
                    i += if (rem == 5) 5 else 4;
                    horizontal = !horizontal;
                }
                run.sp = 0;
            },
            10, 29 => { // callsubr / callgsubr
                const a = run.argsAt();
                if (a.len < 1) return error.Truncated;
                const raw = a[a.len - 1];
                run.sp -= 1;
                const subs = if (b == 10) run.local else run.global_subrs;
                const idx = subs orelse return error.MissingTable;
                const bias = subrBias(idx.count);
                const target = @as(i32, @intFromFloat(raw)) + bias;
                if (target < 0 or @as(usize, @intCast(target)) >= idx.count) return error.MissingTable;
                const sub = try idx.get(run.data, @intCast(target));
                if (try exec(run, sub, depth + 1)) return true;
            },
            11 => return false, // return
            14 => { // endchar; a 4-argument endchar is the seac composite
                const shift = run.widthShift(true);
                const n = run.sp - shift;
                if (n >= 4) return error.Unsupported;
                run.sp = 0;
                return true;
            },
            12 => {
                const second = try charAt(code, pc);
                pc += 1;
                switch (second) {
                    9 => { // abs
                        if (run.sp < 1) return error.Truncated;
                        run.st[run.sp - 1] = @abs(run.st[run.sp - 1]);
                    },
                    10 => { // add
                        if (run.sp < 2) return error.Truncated;
                        run.st[run.sp - 2] += run.st[run.sp - 1];
                        run.sp -= 1;
                    },
                    11 => { // sub
                        if (run.sp < 2) return error.Truncated;
                        run.st[run.sp - 2] -= run.st[run.sp - 1];
                        run.sp -= 1;
                    },
                    12 => { // div
                        if (run.sp < 2 or run.st[run.sp - 1] == 0) return error.Unsupported;
                        run.st[run.sp - 2] /= run.st[run.sp - 1];
                        run.sp -= 1;
                    },
                    14 => { // neg
                        if (run.sp < 1) return error.Truncated;
                        run.st[run.sp - 1] = -run.st[run.sp - 1];
                    },
                    18 => { // drop
                        if (run.sp < 1) return error.Truncated;
                        run.sp -= 1;
                    },
                    20 => { // put
                        if (run.sp < 2) return error.Truncated;
                        const idx: i32 = @intFromFloat(run.st[run.sp - 1]);
                        if (idx >= 0 and @as(usize, @intCast(idx)) < transient_max) {
                            run.transient[@intCast(idx)] = run.st[run.sp - 2];
                        }
                        run.sp -= 2;
                    },
                    21 => { // get
                        if (run.sp < 1) return error.Truncated;
                        const idx: i32 = @intFromFloat(run.st[run.sp - 1]);
                        if (idx < 0 or @as(usize, @intCast(idx)) >= transient_max) return error.Unsupported;
                        run.st[run.sp - 1] = run.transient[@intCast(idx)];
                    },
                    22 => { // ifelse
                        if (run.sp < 4) return error.Truncated;
                        const v2 = run.st[run.sp - 1];
                        const v1 = run.st[run.sp - 2];
                        const s2 = run.st[run.sp - 3];
                        const s1 = run.st[run.sp - 4];
                        run.sp -= 4;
                        try run.push(if (v1 <= v2) s1 else s2);
                    },
                    24 => { // mul
                        if (run.sp < 2) return error.Truncated;
                        run.st[run.sp - 2] *= run.st[run.sp - 1];
                        run.sp -= 1;
                    },
                    26 => { // sqrt
                        if (run.sp < 1 or run.st[run.sp - 1] < 0) return error.Unsupported;
                        run.st[run.sp - 1] = @sqrt(run.st[run.sp - 1]);
                    },
                    27 => { // dup
                        if (run.sp < 1) return error.Truncated;
                        try run.push(run.st[run.sp - 1]);
                    },
                    28 => { // exch
                        if (run.sp < 2) return error.Truncated;
                        const t = run.st[run.sp - 1];
                        run.st[run.sp - 1] = run.st[run.sp - 2];
                        run.st[run.sp - 2] = t;
                    },
                    // flex, random, index, roll, and the boolean operators are
                    // not implemented. A font using them is refused rather than
                    // drawn wrong.
                    else => return error.Unsupported,
                }
            },
            else => return error.Unsupported,
        }
    }
    return false;
}

/// Adaptive flattening of one cubic into line segments, by repeated halving
/// until the control points sit within `tolerance` of the chord.
fn flattenCubic(out: []Segment, n: *usize, p0: [2]f32, c1: [2]f32, c2: [2]f32, p1: [2]f32, tolerance: f32, depth: u8) Error!void {
    if (depth >= 8) {
        if (n.* >= out.len) return error.BufferTooSmall;
        out[n.*] = .{ .line = p1 };
        n.* += 1;
        return;
    }
    // Distance of each control point from the chord, compared against the
    // tolerance scaled by four: the standard cheap flatness test.
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const d1 = @abs((c1[0] - p1[0]) * dy - (c1[1] - p1[1]) * dx);
    const d2 = @abs((c2[0] - p1[0]) * dy - (c2[1] - p1[1]) * dx);
    const sum = d1 + d2;
    if (sum * sum <= tolerance * tolerance * (dx * dx + dy * dy) * 16.0) {
        if (n.* >= out.len) return error.BufferTooSmall;
        out[n.*] = .{ .line = p1 };
        n.* += 1;
        return;
    }
    const a01 = lerp(p0, c1);
    const a12 = lerp(c1, c2);
    const a23 = lerp(c2, p1);
    const b01 = lerp(a01, a12);
    const b12 = lerp(a12, a23);
    const mid = lerp(b01, b12);
    try flattenCubic(out, n, p0, a01, b01, mid, tolerance, depth + 1);
    try flattenCubic(out, n, mid, b12, a23, p1, tolerance, depth + 1);
}

fn lerp(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

/// Flatten segmented output into points-plus-contour-ends: the shape a
/// glyf-based rasteriser consumes. All emitted points are on-curve.
/// The element type behind a slice, an array, or a pointer to an array, so
/// `flatten` can accept a caller's fixed buffer without copying.
fn Elem(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (@typeInfo(p.child)) {
            .array => |a| a.child,
            else => p.child,
        },
        .array => |a| a.child,
        else => @compileError("flatten wants a slice or an array"),
    };
}

pub fn flatten(segs: []const Segment, points: anytype, ends: anytype, tolerance: f32) Error!struct { points: []Elem(@TypeOf(points)), ends: []Elem(@TypeOf(ends)) } {
    var np: usize = 0;
    var ne: usize = 0;
    var start: [2]f32 = .{ 0, 0 };
    var cur: [2]f32 = .{ 0, 0 };
    var open = false;

    for (segs) |s| {
        switch (s) {
            .move => |p| {
                if (open) {
                    if (ne >= ends.len) return error.BufferTooSmall;
                    ends[ne] = @intCast(np);
                    ne += 1;
                    open = false;
                }
                if (np >= points.len) return error.BufferTooSmall;
                points[np] = .{ .x = @intFromFloat(@round(p[0])), .y = @intFromFloat(@round(p[1])), .on = true };
                np += 1;
                start = p;
                cur = p;
                open = true;
            },
            .line => |p| {
                if (np >= points.len) return error.BufferTooSmall;
                points[np] = .{ .x = @intFromFloat(@round(p[0])), .y = @intFromFloat(@round(p[1])), .on = true };
                np += 1;
                cur = p;
            },
            .cubic => |c| {
                var buf: [64]Segment = undefined;
                var wn: usize = 0;
                try flattenCubic(&buf, &wn, cur, .{ c[0], c[1] }, .{ c[2], c[3] }, .{ c[4], c[5] }, tolerance, 0);
                for (buf[0..wn]) |f| {
                    if (np >= points.len) return error.BufferTooSmall;
                    points[np] = .{ .x = @intFromFloat(@round(f.line[0])), .y = @intFromFloat(@round(f.line[1])), .on = true };
                    np += 1;
                }
                cur = .{ c[4], c[5] };
            },
            .close => {
                if (open) {
                    if (ne >= ends.len) return error.BufferTooSmall;
                    ends[ne] = @intCast(np);
                    ne += 1;
                    open = false;
                }
            },
        }
    }
    if (open) {
        if (ne >= ends.len) return error.BufferTooSmall;
        ends[ne] = @intCast(np);
        ne += 1;
    }
    return .{ .points = points[0..np], .ends = ends[0..ne] };
}

/// The point type the outline conversion produces. Mirrors glyfz.Point so the
/// two can be handed to the same rasteriser.
pub const Point = struct { x: i32, y: i32, on: bool };

/// A face whose Top DICT carries CharStrings and a Private DICT with local
/// subroutines, which is the minimum a charstring of any interest needs.
fn cffFace(b: *B, charstrings: []const []const u8, subrs: []const []const u8) void {
    _ = b.put(&.{ 1, 0, 4, 1 });
    b.index(&.{"Test"});

    var dict = [_]u8{0} ** 17;
    dict[0] = 29;
    dict[5] = op.char_strings;
    dict[6] = 29;
    dict[11] = 29;
    dict[16] = op.private;
    const dict_at = topIndex(b, &dict);

    b.index(&.{}); // String INDEX
    b.index(&.{}); // Global Subr INDEX

    const cs_at = b.len;
    b.index(charstrings);

    const priv_at = b.len;
    _ = b.u8_(29);
    const subrs_slot = b.len;
    _ = b.i32_(0);
    _ = b.u8_(op.subrs);
    const priv_len = b.len - priv_at;
    const subrs_at = b.len;
    b.index(subrs);
    b.patch32(subrs_slot, @intCast(subrs_at - priv_at));

    b.patch32(dict_at + 1, @intCast(cs_at));
    b.patch32(dict_at + 7, @intCast(priv_len));
    b.patch32(dict_at + 12, @intCast(priv_at));
}

fn expectPoint(got: [2]f32, x: f32, y: f32) !void {
    try expect(@abs(got[0] - x) < 0.01);
    try expect(@abs(got[1] - y) < 0.01);
}

test "a leading width is consumed, not drawn as a coordinate" {
    var b = B{};
    // width 500, rmoveto 100 0, rlineto 50 0, endchar
    cffFace(&b, &.{&.{ 28, 0x01, 0xF4, 239, 139, 21, 189, 139, 5, 14 }}, &.{});
    const f = try Font.init(b.bytes());
    var segs: [8]Segment = undefined;
    const got = try charstring(f, 0, &segs);
    try expectEqual(@as(usize, 3), got.len);
    try expectPoint(got[0].move, 100, 0);
    try expectPoint(got[1].line, 150, 0);
    try expect(got[2] == .close);
}

test "hint masks skip exactly the bytes the stem count implies" {
    var b = B{};
    // hstemhm with two stems, hintmask with one mask byte, then a move/line.
    // If the mask were skipped short the 0xff byte would be read as a number
    // and every following byte would land in the wrong place.
    cffFace(&b, &.{&.{ 139, 159, 139, 159, 18, 19, 0xFF, 149, 159, 21, 169, 139, 5, 14 }}, &.{});
    const f = try Font.init(b.bytes());
    var segs: [8]Segment = undefined;
    const got = try charstring(f, 0, &segs);
    try expectEqual(@as(usize, 3), got.len);
    try expectPoint(got[0].move, 10, 20);
    try expectPoint(got[1].line, 40, 20);
}

test "a local subroutine is called through its bias" {
    var b = B{};
    // The subr draws a line of 30 and returns; the caller biases index 0 by
    // -107 because the subr count is under 1240.
    cffFace(&b, &.{&.{ 149, 139, 21, 28, 0xFF, 0x95, 10, 14 }}, &.{&.{ 169, 139, 5, 11 }});
    const f = try Font.init(b.bytes());
    var segs: [8]Segment = undefined;
    const got = try charstring(f, 0, &segs);
    try expectEqual(@as(usize, 3), got.len);
    try expectPoint(got[0].move, 10, 0);
    try expectPoint(got[1].line, 40, 0);
}

test "a cubic keeps its control points in absolute coordinates" {
    var b = B{};
    // rmoveto 0 0, rrcurveto 10 0 10 10 0 10, endchar
    cffFace(&b, &.{&.{ 139, 139, 21, 149, 139, 149, 149, 139, 149, 8, 14 }}, &.{});
    const f = try Font.init(b.bytes());
    var segs: [8]Segment = undefined;
    const got = try charstring(f, 0, &segs);
    try expectEqual(@as(usize, 3), got.len);
    const c = got[1].cubic;
    try expectPoint(.{ c[0], c[1] }, 10, 0);
    try expectPoint(.{ c[2], c[3] }, 20, 10);
    try expectPoint(.{ c[4], c[5] }, 20, 20);
}

test "a short segment buffer is reported, not overrun" {
    var b = B{};
    cffFace(&b, &.{&.{ 139, 139, 21, 189, 139, 5, 14 }}, &.{});
    const f = try Font.init(b.bytes());
    var one: [1]Segment = undefined;
    try expectError(error.BufferTooSmall, charstring(f, 0, &one));
}

test "flattening turns a contour into points and one end index" {
    var segs = [_]Segment{
        .{ .move = .{ 0, 0 } },
        .{ .line = .{ 100, 0 } },
        .{ .line = .{ 100, 100 } },
        .close,
    };
    var pts: [16]Point = undefined;
    var ends: [4]u16 = undefined;
    const got = try flatten(&segs, pts[0..], ends[0..], 0.5);
    try expectEqual(@as(usize, 3), got.points.len);
    try expectEqual(@as(usize, 1), got.ends.len);
    try expectEqual(@as(u16, 3), got.ends[0]);
    try expectEqual(@as(i32, 100), got.points[2].x);
    try expect(got.points[0].on);
}

test "a curve flattens to more than one line and stays inside its hull" {
    var segs = [_]Segment{
        .{ .move = .{ 0, 0 } },
        .{ .cubic = .{ 0, 100, 100, 100, 100, 0 } },
        .close,
    };
    var pts: [64]Point = undefined;
    var ends: [4]u16 = undefined;
    const got = try flatten(&segs, pts[0..], ends[0..], 1.0);
    try expect(got.points.len > 3);
    for (got.points) |p| {
        try expect(p.x >= 0 and p.x <= 100);
        try expect(p.y >= 0 and p.y <= 100);
    }
    // The flattener must not collapse the curve onto its chord: something in
    // the middle has to sit well above y = 0.
    var max_y: i32 = 0;
    for (got.points) |p| max_y = @max(max_y, p.y);
    try expect(max_y > 60);
}
