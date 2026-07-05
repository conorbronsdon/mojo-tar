# Changelog

## 0.1.0 — 2026-07-05

Initial release. Pure-Mojo tar reader and writer mirroring Python's
`tarfile` API. Reads ustar (with the `prefix` field), GNU long names, and
pax extended headers (`path`/`size`/`linkpath`), with both octal and
base-256 numeric fields. A bad-checksum member is skipped and recorded in
`TarReader.warnings` rather than aborting the archive; garbage or
truncated input raises cleanly. `TarWriter` emits ustar archives with
automatic pax long-name headers for names over 100 bytes, plus
`add_dir`/`add_symlink`. 24 tests, with writer output verified
interoperable against system GNU `tar`.
