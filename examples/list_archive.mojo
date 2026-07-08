"""List a tar archive's members, `tar -tvf`-style — the "what's in this
archive" workflow.

Usage:
    mojo run -I src examples/list_archive.mojo <archive.tar>
"""

from std.sys import argv

from tar import read_tar_file, TarInfo


def _type_char(info: TarInfo) -> String:
    if info.isdir():
        return String("d")
    if info.issym():
        return String("l")
    if info.islnk():
        return String("h")
    return String("-")


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: list_archive <archive.tar>")
        return

    var entries = read_tar_file(String(args[1]))
    print(len(entries), "member(s) in", args[1])
    print()

    for e in entries:
        var line = (
            _type_char(e.info) + " " + String(e.info.size) + "\t" + e.info.name
        )
        if e.info.linkname.byte_length() > 0:
            line += " -> " + e.info.linkname
        print(line)
