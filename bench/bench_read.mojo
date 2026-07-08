"""Throughput benchmark for the core read path: tar header parsing plus
member iteration, via the public `open_tar` API.

Reads only the repo's own trusted fixtures in `test/data/` — no new parsing
logic lives here (tar size fields are attacker-controlled in the general
case, so the bench deliberately never touches untrusted input). The fixtures
are tiny (10 KiB each), so each archive is parsed many times per measurement
for stable numbers. Bytes are read from disk once; only parsing is timed.

Run compiled for meaningful numbers:
`mojo build -I src bench/bench_read.mojo -o .bench_read && ./.bench_read`
(or `pixi run bench`).
"""
from std.time import perf_counter_ns

from tar import open_tar


def bench(path: String, iterations: Int) raises:
    var raw = open(path, "r").read_bytes()
    var size_mb = Float64(len(raw)) / (1024.0 * 1024.0)
    # Warmup + correctness anchor: member count must stay stable.
    var warm = open_tar(Span(raw))
    var n = len(warm)
    var start = perf_counter_ns()
    for _ in range(iterations):
        var entries = open_tar(Span(raw))
        if len(entries) != n:
            raise Error("inconsistent parse")
    var elapsed_ns = perf_counter_ns() - start
    var per_parse_us = Float64(elapsed_ns) / Float64(iterations) / 1e3
    var mb_per_s = size_mb / (per_parse_us / 1e6)
    print(path)
    print(t"  {len(raw)} bytes, {n} member(s):")
    print(t"  {per_parse_us} us/parse, {mb_per_s} MB/s")


def main() raises:
    bench("test/data/ustar.tar", 5000)
    bench("test/data/gnu.tar", 5000)
    bench("test/data/pax.tar", 5000)
    bench("test/data/dirs.tar", 5000)
