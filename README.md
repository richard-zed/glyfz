# GlyfZ

A TrueType font parser and rasteriser for Zig 0.17. No allocator, glyph caching.

## Disclaimer

Basically everything here, outside of this disclaimer, and a bit more, was written by AI. 

I'm using this for a UI library, didn't want to use the C dependency, kinda ported stb over to Zig. Removed the allocations in the library itself, added caching, and some other optimizations or attempts. And here we are. This has been used in that library already. Performance has improved with caching implemented. The benchmarks we're using showed roughly a 25-40% improvement in render times. I don't want to make any promises, nor do I want to make this about performance or comparisons to stb. We've deviated. Hope you find this useful.

## Usage

GlyfZ reads `glyf`-based fonts, turns outlines into antialiased coverage masks,
and keeps those masks between draws. It is not a shaper: no glyph substitution,
no fallback chain, no line breaking.

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
| CFF1 outlines: INDEX, DICT, charstring interpreter, cubic to quadratic flatten | done |
| composite metrics (`USE_MY_METRICS`) and scaled component offsets | done |
| coverage: exact-area sweep, caller-owned buffers | done |
| load-time validation, scoped errors | done |
| `name`, decoded to UTF-8, with an encoding preference | done |
| `kern` format 0 | done |
| GPOS pair kerning: PairPos formats 1 and 2, `kern` feature | done |
| `Kern`: pair kerning with the feature's lookups resolved once, GPOS preferred over the legacy table | done |
| `hasCodepoint`, for asking a fallback chain's question | done |
| glyph cache, keyed on glyph + scale + phase | done |
| codepoint lookup cache, carrying the resolved advance | done |
| malformed input: truncation and bit-flip sweeps | done |
| `post`: italic angle, underline, fixed pitch | done |
| variable axes: `fvar`, `avar`, `gvar`, on glyphs and on composites | done |
| colour: COLRv0 layers with CPAL palettes | done |
| Arabic and Thai shaping, over GSUB features | done |
| hinting, COLRv1, kern formats 2/3 | out of scope |
| CFF2 outlines -- see [Roadmap](#roadmap) | roadmap |
| GSUB beyond Arabic and Thai, and GSUB 1.1 FeatureVariations -- see [Roadmap](#roadmap) | roadmap |
| GPOS beyond pair adjustment: contextual positioning, GDEF mark filtering, Device tables | out of scope |

Two kerning surfaces, and they answer different questions. `kern()` reads the
legacy `kern` table, format 0 only, which is what stb reads; a zero from it means
that table has nothing to say, not that the designer wanted no adjustment. Apple's
version 1 layout is still not read.

`pairAdjust()` reads GPOS -- where modern fonts actually keep their kerning --
and returns the pair's adjustment, or null if there is none. PairPos format 1 and
format 2 are both implemented, because faces split their pairs across the two:
Liberation ships only format 1, DejaVu only format 2, Lato splits one face's
pairs across both. Extension wrappers are unwrapped.

`kern()` is the RAW legacy read and stays that way; it answers what that table
says, nothing more. `Kern` is the entry point that decides: GPOS first, the
legacy table only when the face has no `kern` feature in GPOS. A face carrying
both is saying the same thing twice, so summing them would double every pair --
DejaVu is such a face.

`shape()` kerns. Its advances come back with pair adjustment already folded in,
because a shaper that returns glyph ids and leaves every caller to re-derive
kerning is how two owners end up applying it twice. Pairing is adjacent, marks
included: lookup flags (IgnoreMarks, USE_MARK_FILTERING_SET) are not modelled,
and Inter's `kern` feature carries both kinds at once, so skipping marks here
would be answering for a flag never read.

What GPOS does not yet get: contextual positioning, GDEF mark filtering, and
Device tables (hint-time, and there is no hinting here). Script selection has no text to work from, so it tries `latn`,
then DFLT, then file order -- which matters, because DejaVu keeps one class-based
lookup under DFLT and its two real ones under `latn`.

Verified differentially against fontTools' decode of the same tables: 95,236
glyph pairs over five faces, 18,918 of them non-zero, no disagreements.

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

`post()` is the same kind of table and gets the same treatment: the 32-byte
header every version shares, and null when the table is absent or too short.
`shear()` turns `italic_angle` into the tangent a synthetic oblique needs, and
`underline(upem)` returns a position and thickness with the table's own zeros
replaced by the usual proportions -- a zero thickness draws nothing, so handing
it back would only make every caller reimplement the substitution. The angle
does not select an italic face. `fsSelection` does that, and it is already read.

## Scope

`glyf` and CFF outlines. An OTTO face is read through its `CFF ` table, and one
that carries neither outline table -- only `CFF2`, say -- is refused rather than
half-loaded. The reference implementation
during development was stb_truetype; **it is not vendored here**, so neither the
differential nor the per-glyph comparison can be re-run from this repository.
What they found is recorded below.

Where the two disagreed, the OpenType spec decided, and the disagreement is
documented rather than papered over. Three exist, and all three are places the
differential could not have voted on, because it was grading against stb:

- `cmap` format 4 applies `idDelta` to a value fetched through a non-zero
  `idRangeOffset`; stb returns that value unchanged.
- Composite transforms are applied as given; stb multiplies by each column's
  norm, which squares a uniform scale.
- `SCALED_COMPONENT_OFFSET` is honoured; stb ignores the flag, so a transformed
  component lands at its unscaled offset there and its scaled offset here.

The first two agree on translate-only composites, and so does the third.

## What was checked

Two checks still in this repo:

- **`zig build test`** -- the unit suite, 49 tests, no font file needed. The
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

The cache-hit column came from the harness that no longer ships; `bench` prints
its own cached figure, and the two have disagreed by several times over while the
raster column matched. Treat that column as a magnitude, not a measurement.

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

- CFF charstrings are cubic, and this library's outline type is quadratic, so
  `outline` hands back CFF curves **already flattened to line points**. The
  tolerance is one font unit, far below one device pixel at any normal size,
  but the curve data itself is not preserved.
- CFF2 (the variable-font flavour) is still refused.

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
- **No real face exercises the composite flags.** `USE_MY_METRICS` and the
  scaled offset rule have their own tests, on a synthetic font, because DejaVu
  Sans sets the metrics flag on 840 composites and not one advance changes. The
  code follows the spec; no font here proves a rendering depends on it.
  `ROUND_XY_TO_GRID` and `OVERLAP_COMPOUND` are grid-fitting hints, and an
  unhinted rasteriser cannot honour either.
- **The Arabic comparison against HarfBuzz is not in the tree.** 924 mark
  sequences were shaped here and by `hb-shape` and compared, which is where the
  `liga` decision came from; that harness lived outside the repository and is
  not a test. The two entry points were graded by inspection until the GSUB
  fixtures landed, and a font-scale regression in Arabic shaping would still
  not be caught by the suite.
- **The one consumer pins a commit.** A Zig GUI toolkit links this at a specific
  revision rather than by version range, so an API change here reaches it only
  when that pin is moved on purpose. Nothing else consumes GlyfZ.

## Roadmap

Two entries. Both are refused correctly today -- a face that needs either gets a
scoped error, not a misread -- and both are things this library should eventually
read rather than refuse.

### CFF2

CFF2 is the variable flavour of CFF, the outline format OpenType ships for
variable PostScript faces. It is refused twice over, on purpose: `Font.init`
matches only the `CFF ` tag, so a `CFF2` table is never even located (an OTTO
face carrying only CFF2 ends in `error.MissingTable`), and `cff.Font.init`
rejects any header byte but `1` -- CFF2 starts `0x02` -- returning
`error.NotCff`. A test pins the second refusal on those exact bytes.

What it needs, in the order it would be built:

- A second reader beside CFF1. CFF2 has no NAME INDEX, so the header and the
  Top DICT INDEX are at different offsets; sharing CFF1's parser is not an
  option, which is exactly why it is refused rather than attempted.
- An `ItemVariationStore` parser. `variations.zig` handles `gvar`, whose deltas
  are per-glyph packed; a variation store is an indexed, shared region and
  nothing in the tree reads one today.
- The CFF2 charstring dialect: no `endchar`, and `vsindex`/`blend` operators for
  interpolating between regions.

Reusable as-is: the charstring interpreter, `charstringBox` and `flatten`.
CFF1 is otherwise complete, so this is an addition, not a rewrite.

### GSUB

Shaping here means the `ccmp`, `init`/`medi`/`fina`, `rlig`, `calt` and `locl`
features under two scripts, `arab` and `thai`. Single, multiple, ligature and
chaining-contextual substitution all run; type 6 supports format 3 only, and
GSUB 1.1's FeatureVariations are not read. There is no script-agnostic entry
point -- `shapeArabic` and `shapeThai` are the two doors, each with its feature
list baked in.

What it needs:

- A script-agnostic `shape` that takes a script tag and a feature list, so a
  third writing system does not mean a third function.
- GSUB type 6 formats 1 and 2 (glyph- and class-based rule sets). Real fonts use
  them; nothing here reads them yet.
- FeatureVariations, which is what a variable font switches on when an axis
  crosses a threshold.
- More scripts, which is a data problem before it is a code problem: joining and
  combining classes per script, the way `arabic.zig` carries Arabic's.

Test scaffolding now exists for this work. `buildGsubTestFont` emits a
well-formed GSUB with empty lists, and `buildSubstTestFont` emits a `ccmp`
lookup that turns one glyph into two -- the only lookup type that makes a run
longer, which is what the placement guards have to follow.

## Licence

MIT. See `LICENSE`.
