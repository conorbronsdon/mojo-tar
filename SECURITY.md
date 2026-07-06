# Security Policy

mojo-tar is a pure-Mojo tar archive reader and writer with no network
access, no authentication, and no secrets handling: it reads or writes
archive bytes and returns structured data. The main risk surface is
malformed or adversarial archive input causing a crash, hang, or
unbounded memory growth (e.g. a header claiming an enormous size, or a
truncated block), which the fuzz suite (`test/fuzz_runner.mojo`)
specifically targets.

If you find an archive that crashes, hangs, or otherwise misbehaves in a
way that looks security-relevant (out-of-bounds access, unbounded memory
growth, path traversal via `..` or absolute names in extracted entries),
please report it via a
[GitHub issue](https://github.com/conorbronsdon/mojo-tar/issues),
including the offending archive or a minimal reproduction.

A member whose header fails its checksum aborts the parse with an error
(mirroring CPython `tarfile`'s `ReadError`); the archive is rejected rather
than resynced. A corrupt header cannot be trusted to say where its member's
data ends: its size field is attacker-controlled, and a crafted size (for
example 0) would make a "skip the member" resync advance only a single block,
reinterpreting the member's data as the next headers. That is a
content-smuggling / scanner-evasion differential — a file whose contents are
themselves a valid tar could surface its inner members as top-level entries —
so mojo-tar refuses to guess and raises instead. GNU sparse members
(typeflag `S`, or `GNU.sparse.*` pax records) are likewise rejected rather
than mis-read, because their archived length differs from their logical
size and would desync the parse.

Note that mojo-tar, like `tarfile`, does not sanitize member names or link
targets on read: they are returned verbatim. Callers writing entries to disk
are responsible for validating `TarInfo.name` and `TarInfo.linkname` — rejecting
absolute paths, `..` components, and unsafe symlink targets — before joining
them to a destination path. This is the path-traversal class tracked as
[CVE-2007-4559](https://nvd.nist.gov/vuln/detail/CVE-2007-4559) against Python's
`tarfile`; mojo-tar leaves that policy to the caller by design. See the
"Security" section of the README for details.

This is a personal open-source project maintained on a best-effort
basis. There's no formal SLA for response time, but reports are welcome
and taken seriously.
