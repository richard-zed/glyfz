//! COLR v0 layers and CPAL palettes.
//!
//! A colour glyph is not a new kind of outline: it is a list of ordinary glyph
//! ids, each filled from a palette entry. Everything here is therefore a table
//! read, and the rasteriser and the mask cache are untouched -- a layer is
//! drawn by the same path as any other glyph, in a colour the caller picks.
//!
//! v1 is deliberately not read. A v1 font keeps the v0 layer list for fallback,
//! so a v1 face reports its v0 layers here rather than nothing, and the paint
//! graph (which is a whole interpreter: transforms, gradients, compositing) is
//! somebody else's problem. Bitmap-only formats (CBDT/sbix) are out of scope for
//! the same reason as WOFF2: they need an inflate implementation, and that needs
//! an allocator.

const std = @import("std");

/// One layer of a colour glyph: an ordinary glyph, filled from a palette entry.
pub const Layer = struct {
    glyph: u16,
    palette_index: u16,
};

pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

fn u16At(d: []const u8, at: usize) error{Truncated}!u16 {
    if (at + 2 > d.len) return error.Truncated;
    return @as(u16, d[at]) << 8 | d[at + 1];
}

fn u32At(d: []const u8, at: usize) error{Truncated}!u32 {
    if (at + 4 > d.len) return error.Truncated;
    return @as(u32, d[at]) << 24 | @as(u32, d[at + 1]) << 16 | @as(u32, d[at + 2]) << 8 | d[at + 3];
}

pub const Colr = struct {
    data: []const u8,
    num_base: u16,
    base_off: usize,
    layer_off: usize,
    num_layer: u16,

    const header_len = 14;
    const base_len = 6;
    const layer_len = 4;

    pub fn init(data: []const u8) ?Colr {
        if (data.len < header_len) return null;
        const version = u16At(data, 0) catch return null;
        // v1 carries the v0 header prefix unchanged, so the layer list below it
        // is still the fallback list a v0 reader wants.
        if (version > 1) return null;
        const num_base = u16At(data, 2) catch return null;
        const base_off = u32At(data, 4) catch return null;
        const layer_off = u32At(data, 8) catch return null;
        const num_layer = u16At(data, 12) catch return null;
        if (num_base != 0) {
            if (@as(usize, base_off) + @as(usize, num_base) * base_len > data.len) return null;
        }
        if (num_layer != 0) {
            if (@as(usize, layer_off) + @as(usize, num_layer) * layer_len > data.len) return null;
        }
        return .{
            .data = data,
            .num_base = num_base,
            .base_off = base_off,
            .layer_off = layer_off,
            .num_layer = num_layer,
        };
    }

    /// The layers of one base glyph, written into `out`. Null when the glyph has
    /// no colour record, or when `out` is too small for it -- a partial list
    /// would draw half an emoji, which is worse than drawing none.
    ///
    /// Base records are sorted by glyph id, so this is a binary search: a face
    /// with thousands of emoji should not be walked one record at a time.
    pub fn layers(self: Colr, gid: u16, out: []Layer) ?[]Layer {
        var lo: usize = 0;
        var hi: usize = self.num_base;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = self.base_off + mid * base_len;
            const rec = u16At(self.data, at) catch return null;
            if (rec < gid) {
                lo = mid + 1;
            } else if (rec > gid) {
                hi = mid;
            } else {
                const first = u16At(self.data, at + 2) catch return null;
                const count = u16At(self.data, at + 4) catch return null;
                if (count == 0) return null;
                if (out.len < count) return null;
                if (@as(usize, first) + count > self.num_layer) return null;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const lat = self.layer_off + (@as(usize, first) + i) * layer_len;
                    out[i] = .{
                        .glyph = u16At(self.data, lat) catch return null,
                        .palette_index = u16At(self.data, lat + 2) catch return null,
                    };
                }
                return out[0..count];
            }
        }
        return null;
    }

    /// Whether this face has any colour glyphs at all.
    pub fn any(self: Colr) bool {
        return self.num_base != 0;
    }
};

pub const Cpal = struct {
    data: []const u8,
    num_entries: u16,
    num_palettes: u16,
    num_colors: u16,
    color_off: usize,

    const header_len = 12;

    pub fn init(data: []const u8) ?Cpal {
        if (data.len < header_len) return null;
        const version = u16At(data, 0) catch return null;
        if (version > 1) return null;
        const num_entries = u16At(data, 2) catch return null;
        const num_palettes = u16At(data, 4) catch return null;
        const num_colors = u16At(data, 6) catch return null;
        const color_off = u32At(data, 8) catch return null;
        if (num_palettes != 0) {
            // the palette index table sits between the header and the records
            if (header_len + @as(usize, num_palettes) * 2 > data.len) return null;
        }
        if (num_colors != 0) {
            if (@as(usize, color_off) + @as(usize, num_colors) * 4 > data.len) return null;
        }
        return .{
            .data = data,
            .num_entries = num_entries,
            .num_palettes = num_palettes,
            .num_colors = num_colors,
            .color_off = color_off,
        };
    }

    /// One colour, or null when the palette or the entry does not exist. Colour
    /// records are stored BGRA, so the byte order is reversed from what a
    /// renderer wants and that reversal is the whole job here.
    pub fn color(self: Cpal, palette: u16, index: u16) ?Rgba {
        if (palette >= self.num_palettes) return null;
        if (index >= self.num_entries) return null;
        const base = u16At(self.data, header_len + @as(usize, palette) * 2) catch return null;
        const rec = @as(u32, base) + index;
        if (rec >= self.num_colors) return null;
        const at = self.color_off + @as(usize, rec) * 4;
        if (at + 4 > self.data.len) return null;
        return .{
            .b = self.data[at],
            .g = self.data[at + 1],
            .r = self.data[at + 2],
            .a = self.data[at + 3],
        };
    }
};

test "a colour glyph reports its layers in order" {
    // header 14, one base record (6), two layer records (8)
    const blob = [_]u8{
        0x00, 0x00, // version 0
        0x00, 0x01, // one base glyph
        0x00, 0x00, 0x00, 0x0E, // base records at 14
        0x00, 0x00, 0x00, 0x14, // layer records at 20
        0x00, 0x02, // two layers
        0x00, 0x32, 0x00, 0x00, 0x00, 0x02, // gid 50, first layer 0, count 2
        0x00, 0x0A, 0x00, 0x00, // layer: gid 10, palette 0
        0x00, 0x0B, 0x00, 0x01, // layer: gid 11, palette 1
    };
    const c = Colr.init(&blob) orelse return error.TestUnexpectedResult;
    try std.testing.expect(c.any());
    var buf: [8]Layer = undefined;
    const ls = c.layers(50, &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), ls.len);
    try std.testing.expectEqual(@as(u16, 10), ls[0].glyph);
    try std.testing.expectEqual(@as(u16, 0), ls[0].palette_index);
    try std.testing.expectEqual(@as(u16, 11), ls[1].glyph);
    try std.testing.expectEqual(@as(u16, 1), ls[1].palette_index);

    // a glyph with no record, and a buffer too small for one that has
    try std.testing.expect(c.layers(51, &buf) == null);
    var small: [1]Layer = undefined;
    try std.testing.expect(c.layers(50, &small) == null);
}

test "a broken COLR table is refused rather than read past" {
    const short = [_]u8{ 0x00, 0x00, 0x00, 0x01 };
    try std.testing.expect(Colr.init(&short) == null);
    // claims two base records but carries room for one
    const lying = [_]u8{
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x0E,
        0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x32,
        0x00, 0x00, 0x00, 0x01,
    };
    try std.testing.expect(Colr.init(&lying) == null);
}

test "palette colours come back in RGB order, not BGRA" {
    const blob = [_]u8{
        0x00, 0x00, // version 0
        0x00, 0x02, // two entries per palette
        0x00, 0x01, // one palette
        0x00, 0x02, // two colour records
        0x00, 0x00, 0x00, 0x0E, // records at 14
        0x00, 0x00, // palette 0 starts at record 0
        // stored B, G, R, A
        0x33, 0x22,
        0x11, 0xFF,
        0xFF, 0x00,
        0x00, 0x80,
    };
    const p = Cpal.init(&blob) orelse return error.TestUnexpectedResult;
    const first = p.color(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0x11), first.r);
    try std.testing.expectEqual(@as(u8, 0x22), first.g);
    try std.testing.expectEqual(@as(u8, 0x33), first.b);
    try std.testing.expectEqual(@as(u8, 0xFF), first.a);
    const second = p.color(0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0x00), second.r);
    try std.testing.expectEqual(@as(u8, 0x80), second.a);
    // palette 1 does not exist, entry 2 does not exist
    try std.testing.expect(p.color(1, 0) == null);
    try std.testing.expect(p.color(0, 2) == null);
}
