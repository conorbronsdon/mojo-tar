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
