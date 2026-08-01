# ADR-0003: .shredfix fixtures are directories, not zips

**Status:** accepted · **Deviates from:** 08 §2 ("zip of chunks")

Foundation on Linux has no zip API and the zero-dependency rule (04 §1) excludes a zip
library. A `<name>.shredfix/` directory with `meta.json`, `truth.json`, and per-stream
chunk subdirectories is diff-able in review, streams the same bytes, and needs no archive
code. Wire format of the chunks themselves is unchanged (05 §4).
