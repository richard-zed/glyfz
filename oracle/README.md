# oracle/

A vendored copy of `stb_truetype.h` (public domain / MIT dual licence) and its
implementation translation unit.

It is **not part of the library**. It exists so the differential test in
`test/oracle_test.zig` can compare Cedar against an independent implementation
of the same spec: same face, same sizes, glyph by glyph.

stb is the *reference*, not the *authority*. Where the two disagree the OpenType
spec decides, and the disagreement gets written down rather than papered over.

Run it with a font of your choosing:

    zig build oracle -Dfont=/path/to/font.ttf
