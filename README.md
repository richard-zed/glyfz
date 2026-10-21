# Cedar

A TrueType rasteriser in Zig.

Cedar reads `glyf`-based fonts, turns outlines into antialiased coverage masks,
and keeps those masks between draws. It is not a shaper: no glyph substitution,
no fallback chain, no line breaking.

```zig
var font = try cedar.Font.init(bytes);           // bytes are yours
var cache = try cedar.Cache.init(&storage, .{}); // so is the cache's memory
const gid = try font.glyphIndex('A');
const m = try cache.mask(font, gid, 16, .zero);  // a hash lookup once warm
```

That sample is a unit test, so it cannot rot quietly.

Two properties are the whole point:

- **No allocator, no IO, no libc.** The font is bytes you own. Every working
  buffer -- outlines, edges, coverage, and the glyph cache -- is yours too.
- **Glyph masks are cached.** `stbtt_GetCodepointBitmap` allocates, rasterises
  and frees on every draw, per glyph. A Cedar cache hit is a hash lookup and a
  slice.

## Status

| layer | state |
|---|---|
| sfnt directory, including `ttcf` collections | done |
| `head`, `maxp`, `hhea`, `hmtx` metrics | done |
| `cmap` formats 4 and 12 | done |
| `glyf` / `loca` outlines, simple and composite | done |
| coverage: exact-area sweep, caller-owned buffers | done |
| load-time validation, scoped errors | done |
| `kern` format 0 | done |
| glyph cache, keyed on glyph + ppem + phase | done |
| `name`, `OS/2`, `post` | not started |
| fuzzing | not started |
| hinting, CFF/CFF2, variable axes, colour fonts, GPOS, kern 2/3 | out of scope |

`kern` is format 0 only, which is what stb reads. Apple's version 1 layout is
not read, and neither is GPOS -- where modern fonts actually keep their kerning.
So a zero advance from `kern()` means the table has nothing to say, not that the
designer wanted no adjustment.

## Scope, and what it is measured against

The reference implementation is stb_truetype, vendored in `oracle/` purely so
the suite can compare the two glyph by glyph. **stb is the reference, not the
authority** -- where they disagree the OpenType spec decides, and the
disagreement gets documented. Two exist: `cmap` format 4 applies `idDelta` to a
value fetched through a non-zero `idRangeOffset` (stb returns it unchanged), and
composite transforms are applied as given (stb multiplies by each column's norm,
which squares a uniform scale). They agree on translate-only composites.

## Verification

`zig build oracle -Dfont=<ttf>` compares against stb over a real face. On DejaVu
Sans:

| check | result |
|---|---|
| glyph metrics | 0 mismatched |
| `cmap` over 0..0x10FFFF | 0 mismatched |
| outlines, 6190 glyphs | 0 mismatched, 0 skipped |
| pixel boxes | 75,036 comparisons, all exact |
| coverage, 37,140 rasterisations, 6.74M pixels | max delta 4/255, 0.01% of pixels differ by more than 2 |
| kerning, 90,000 pairs (1,955 non-zero) | 0 mismatched |

The comparisons are shown to be capable of failing, not assumed to pass: a
one-unit box shift flags 6190/6190, a half-pixel phase shift drives coverage
delta to 169, dropping the sweep's accumulator tail drives it to 255.

Agreement with stb proves Cedar is not *different*. It does not prove Cedar is
*right* -- which is why the spec, not the oracle, settles arguments.

## Measured cost

Per glyph, ReleaseFast, 94 printable-ASCII glyphs, best of 40, three runs of the
same binary (the spread is the honest precision):

| size | stb | cedar raster | ratio | cache hit | vs stb |
|---|---|---|---|---|---|
| 11 | 2100-2118 | 2048-2064 | 1.02-1.03x | 115-116 ns | 18x |
| 16 | 1942-2134 | 1983-2212 | 0.96-1.03x | 86-94 ns | 22-25x |
| 24 | 2188-2195 | 2380-2399 | 0.91-0.92x | 72 ns | 30x |
| 34 | 2889-2905 | 3250-3267 | 0.89x | 181-183 ns | 16x |
| 48 | 3868-3890 | 4562-4572 | 0.85x | 187-193 ns | 20x |

Read that honestly: the rasteriser is at parity at UI sizes and behind at
display sizes. It is not faster than stb. The cache is where the win is, and it
is a win stb cannot match at the call site, because stb has no cache at all.

## Build

```sh
zig build                                     # compile
zig build test                                # unit tests, no font needed
zig build oracle -Dfont=/path/to/font.ttf     # differential against stb
zig build bench  -Doptimize=ReleaseFast -Dfont=/path/to/font.ttf
zig build fuzz   -Dfont=/path/to/font.ttf     # malformed input: rejected, never faulted
```

No font is vendored, so the oracle and the bench both need `-Dfont=` (or
`CEDAR_TEST_FONT` / `CEDAR_BENCH_FONT`). Aim them at an awkward face on purpose.

## Not ready yet

- **Nothing outside this repo has ever linked it.** The API has been exercised
  by its own tests and bench, and by no consumer.
- **No fuzzing.** A truncated or bit-flipped font is the classic input for this
  kind of parser, and the validation has one test per field rather than a sweep.
- **No font selection.** Without `name` and `OS/2` a caller cannot resolve a
  font by name or ask for cap height.
- **The cache flush policy is unmeasured under a real working set.** The arena is
  a bump allocator, so filling it drops everything. One alphabet at one size is
  not a UI.

## Licence

MIT. See `LICENSE`. The vendored stb_truetype in `oracle/` is public domain or
MIT at your option.
