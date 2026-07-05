"""Fuzz target: parse the tar file at argv[1]; raising is fine,
crashing/hanging is not.

Feed it corrupted, truncated, or random inputs — a clean raise counts as
a pass. Mirrors the shape of mojo-captions' fuzz_runner.
"""

from std.sys import argv

from tar import open_tar


def main():
    try:
        var raw = open(String(argv()[1]), "r").read_bytes()
        var entries = open_tar(Span(raw))
        print("entries:", len(entries))
        for e in entries:
            print("  ", e.info.name, e.info.size)
    except e:
        print("raised:", e)
