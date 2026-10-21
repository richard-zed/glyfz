# Cedar

A TrueType rasteriser in Zig.

Cedar reads `glyf`-based fonts and turns outlines into antialiased coverage
masks. It is not a shaper: no kerning, no glyph substitution, no fallback chain.

## Status

Slice 1 -- the table layer and glyph metrics. No rasterising yet.

| | state |
|---|---|
| sfnt directory, `head`, `maxp`, `hhea`, `hmtx` | done |
| `cmap` formats 4 and 12 | done |
| `glyf` / `loca` outline decoding | next |
| coverage accumulation, antialiasing | after that |

## Scope, and what it is measured against

The reference implementation is stb_truetype, and it is vendored in `oracle/`
purely so the test suite can compare the two glyph by glyph. **stb is the
reference, not the authority** -- where they disagree the OpenType spec decides,
and a disagreement gets documented. There is one already, in `cmapFormat4`.

Deliberately out of scope for v1:

- hinting -- stb skips it too, so unhinted is the bar; FreeType is not the target
- CFF/CFF2 outlines, variable axes, colour fonts
- shaping and kerning
- Unicode line breaking

## Build

```sh
zig build                    # compile
zig build test               # unit tests, no font file needed
zig build oracle -Dfont=/path/to/font.ttf   # differential against stb_truetype
```

The oracle needs a font because none is vendored: `-Dfont=`, or set
`CEDAR_TEST_FONT`.

## Licence

MIT. See `LICENSE`. The vendored stb_truetype in `oracle/` is public domain or
MIT at your option.
