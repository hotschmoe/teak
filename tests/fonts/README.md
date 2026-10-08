# Test fonts (text-engine PR1)

Tiny subsets, regenerated with `pyftsubset --no-hinting`, used only by `zig build test`.

| File | Source | Contents | License |
|------|--------|----------|---------|
| `IBMPlexMonoSub-Regular.ttf` | IBM Plex Mono Regular (`examples/fonts/assets`) | U+0020-007E | SIL OFL 1.1, `OFL-IBMPlexMono.txt` (Reserved Font Name "Plex"; test-only, not redistributed as a font) |
| `QuicksandSub-Regular.ttf` | Quicksand Regular 2011 (Debian `fonts-quicksand`) | U+0020-007E, U+FB01, U+FB02, GPOS `kern` | SIL OFL 1.1, `OFL-Quicksand.txt` |
| `QuicksandSub-NoLig.ttf` | same | U+0020-007E, GPOS `kern` (no fi/fl glyphs) | same |
| `IBMPlexMonoMarks.ttf` | IBM Plex Mono Regular | U+0020-007E, U+00E9, U+0301 | SIL OFL 1.1, `OFL-IBMPlexMono.txt` |
