# GlyfZ

A TrueType font parser and rasteriser for Zig 0.16. No allocator, glyph caching.

GlyfZ reads `glyf`-based fonts, turns outlines into antialiased coverage masks,
and keeps those masks between draws. It is not a shaper: no glyph substitution,
no fallback chain, no line breaking.

<!-- Disclaimer goes here. Author-written. -->

```zig
var font = try glyfz.Font.init(bytes);           // bytes are yours
var cache = try glyfz.Cache.init(&storage, .{}); // so is the cache's memory
const gid = try font.glyphIndex('A');
const m = try cache.mask(font, gid, 16, .zero);  // a hash lookup once warm
```

That sample is a unit test, so it cannot rot quietly.

Two properties are the whole point:

- **No allocator, no IO, no libc.** There is no `std.mem.Allocator` parameter to
  pass and no file to open. The font is bytes you own; every working buffer --
  outlines, edges, coverage, and the glyph cache -- is yours too. The claim is
  about who owns memory, not about using none.
- **Glyph masks are cached.** `stbtt_GetCodepointBitmap` allocates, rasterises
  and frees on every draw, per glyph. A GlyfZ cache hit is a hash lookup and a
  slice into caller memory. What stays warm is the rasterised coverage, keyed on
  glyph, scale and subpixel phase -- not outlines, and not metrics.

## Status

| layer | state |
|---|---|
| sfnt directory, including `ttcf` collections | done |
| `head`, `maxp`, `hhea`, `hmtx` metrics | done |
| `OS/2` weight, selection, typographic and Windows metrics, cap and x-height | done |
| `cmap` formats 4 and 12 | done |
| `glyf` / `loca` outlines, simple and composite | done |
| coverage: exact-area sweep, caller-owned buffers | done |
| load-time validation, scoped errors | done |
| `name`, decoded to UTF-8, with an encoding preference | done |
| `kern` format 0 | done |
| `hasCodepoint`, for asking a fallback chain's question | done |
| glyph cache, keyed on glyph + scale + phase | done |
| malformed input: truncation and bit-flip sweeps | done |
| `post`: italic angle, underline | not started |
| hinting, CFF/CFF2, variable axes, colour fonts, GPOS, kern 2/3 | out of scope |

`kern` is format 0 only, which is what stb reads. Apple's version 1 layout is
not read, and neither is GPOS -- where modern fonts actually keep their kerning.
So a zero advance from `kern()` means the table has nothing to say, not that the
designer wanted no adjustment. Kerning here is parity with stb, not an
improvement on it.

## Names, and the numbers a box centres on

A theme that says `.font = "DejaVu Sans"` needs something to match that string
against, and `name` is the table that answers. `family` and `style` return the
usual pair; `name` takes any id for the rest.

Names are decoration, like kerning: a face without a `name` table still loads,
and the accessor returns null instead of failing. The same id is normally stored
once per encoding, so there is a preference order -- Windows Unicode, then the
Unicode platform, then Mac Roman, and Mac Roman only while the bytes are pure
ASCII, because decoding a codepage that is not implemented would produce a
plausible wrong answer.

`os2()` returns `cap_height` and `x_height`, both null below table version 2.
Null rather than zero, because zero is a legal cap height and a guess would be
indistinguishable from one. DejaVu Sans ships version 1, so this is the ordinary
case rather than an edge.

They matter because `hhea` gives one set of vertical metrics for every purpose
while `OS/2` carries three, and on real faces they disagree: DejaVu Sans is
1556/-492 typographic against 1901/-483 in `hhea`. Anything sizing a line by
ascender-descender gets a different height depending on which pair it reads.

## Scope

`glyf`-based fonts only. The reference implementation
during development was stb_truetype; **it is not vendored here**, so neither the
differential nor the per-glyph comparison can be re-run from this repository.
What they found is recorded below.

Where the two disagreed, the OpenType spec decided, and the disagreement is
documented rather than papered over. Two exist: `cmap` format 4 applies
`idDelta` to a value fetched through a non-zero `idRangeOffset` (stb returns it
unchanged), and composite transforms are applied as given (stb multiplies by
each column's norm, which squares a uniform scale). They agree on translate-only
composites.

## What was checked

Two checks still in this repo:

- **`zig build test`** -- the unit suite, 37 tests, no font file needed. The
  coverage sweep is graded against brute-force supersampling and hand-computed
  shapes, so it is never marked by its own algebra.
- **`zig build fuzz -Dfont=<ttf>`** -- a truncated face at every 4000th byte,
  plus 20,000 single-bit flips, deterministic. Every outcome has to be a scoped
  error or a face that still behaves; a panic, an out-of-bounds read, a hang, or
  a face that loads with no glyphs is a failure. Proven able to fail in both
  directions: an impossible assertion turns it red, and running with no font
  configured reports *skipped*, not passed.

The third check was a glyph-by-glyph differential against stb_truetype on DejaVu
Sans, run while stb was still vendored here:

| check | result |
|---|---|
| glyph metrics | 0 mismatched |
| `cmap` over 0..0x10FFFF | 0 mismatched |
| outlines, 6190 glyphs | 0 mismatched, 0 skipped |
| pixel boxes | 75,036 comparisons, all exact |
| coverage, 37,140 rasterisations, 6.74M pixels | max delta 4/255, 0.01% of pixels differ by more than 2 |
| kerning, 90,000 pairs (1,955 non-zero) | 0 mismatched |

Those comparisons were shown to be capable of failing rather than assumed to
pass: a one-unit box shift flagged 6190/6190, a half-pixel phase shift drove
coverage delta to 169, and dropping the sweep's accumulator tail drove it to
255. Agreement with stb proves GlyfZ is not *different*; it does not prove it is
*right*, which is why the spec settles arguments.

## Measured cost

Per glyph, ReleaseFast, 94 printable-ASCII glyphs, best of 40, three runs of the
same binary (the spread is the honest precision). The stb column is from the
same period as the differential above:

| size | stb | glyfz raster | ratio | cache hit | vs stb |
|---|---|---|---|---|---|
| 11 | 2100-2118 | 2048-2064 | 1.02-1.03x | 115-116 ns | 18x |
| 16 | 1942-2134 | 1983-2212 | 0.96-1.03x | 86-94 ns | 22-25x |
| 24 | 2188-2195 | 2380-2399 | 0.91-0.92x | 72 ns | 30x |
| 34 | 2889-2905 | 3250-3267 | 0.89x | 181-183 ns | 16x |
| 48 | 3868-3890 | 4562-4572 | 0.85x | 187-193 ns | 20x |

Read that honestly: the rasteriser is at parity at UI sizes and behind at
display sizes. It is not faster than stb. The cache is where the win is, and it
is a win stb cannot match at the call site, because stb has no cache at all.

`zig build bench -Doptimize=ReleaseFast -Dfont=<ttf>` reproduces the raster,
decode and cache columns, and nothing else, since there is no second
implementation here to compare against.

## Build

```sh
zig build                                     # compile
zig build test                                # unit tests, no font needed
zig build bench -Doptimize=ReleaseFast -Dfont=/path/to/font.ttf
zig build fuzz  -Dfont=/path/to/font.ttf      # malformed input: rejected, never faulted
```

No font is vendored, so `bench` and `fuzz` both need `-Dfont=` (or
`GLYFZ_BENCH_FONT` / `GLYFZ_TEST_FONT`). Aim them at an awkward face on purpose.

## Known gaps

- **The external check is not reproducible here.** The differential and the
  comparison numbers came from a harness against stb_truetype that no longer
  ships in this repo. The unit suite and the fuzz sweeps are what a cloner can
  run.
- **No font selection.** `name` gives you the family string; finding a *file*
  with that family, and chaining to the next one when this face lacks a
  codepoint, is the caller's job. `hasCodepoint` answers the question a chain
  asks, and nothing here walks a list of files.
- **The cache flush policy is unmeasured under a real working set.** The arena
  is a bump allocator, so filling it drops everything and `stats.flushes` says
  so. One alphabet at one size is not a UI.
- **Composite flags are not audited.** `USE_MY_METRICS`, `ROUND_XY_TO_GRID` and
  the scaled/unscaled component offset rules are shared with stb, so a
  differential could not have seen them even when one was here. They need their
  own tests.
- **One consumer, reached by absolute path.** A Zig GUI toolkit links this from
  a machine-local path, which is not how anyone else would consume it. There is
  no published package.

## Licence

MIT. See `LICENSE`.
