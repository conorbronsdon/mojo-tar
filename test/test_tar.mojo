"""Test suite for mojo-tar: header parsing, fixture enumeration, GNU/pax
extensions, writer round-trips, and error handling.

Fixture archives under `test/data/` were produced by the system `tar`
binary (`--format=ustar|gnu|pax`); the writer round-trip and interop
checks were also verified against system `tar -tf`/`-xf` at build time.
"""

from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from tar import (
    open_tar,
    read_tar_file,
    TarReader,
    TarWriter,
    TarInfo,
    TarEntry,
    BLOCKSIZE,
)


# --- helpers -----------------------------------------------------------


def _content(entry: TarEntry) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(entry.data)))


def _find(entries: List[TarEntry], name: String) raises -> TarInfo:
    for e in entries:
        if e.info.name == name:
            return e.info.copy()
    raise Error("member not found: " + name)


def _find_entry(entries: List[TarEntry], name: String) raises -> TarEntry:
    for e in entries:
        if e.info.name == name:
            return e.copy()
    raise Error("member not found: " + name)


def _octal6(value: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var v = value
    var digits = List[UInt8]()
    for _ in range(6):
        digits.append(UInt8(ord("0") + (v & 7)))
        v = v >> 3
    for i in range(6):
        out.append(digits[5 - i])
    return out^


def _fix_checksum(mut blocks: List[UInt8], off: Int):
    """Recompute the ustar header checksum for the block at `off`."""
    for i in range(148, 156):
        blocks[off + i] = UInt8(0x20)
    var s = 0
    for i in range(BLOCKSIZE):
        s += Int(blocks[off + i])
    var oct = _octal6(s)
    for i in range(6):
        blocks[off + 148 + i] = oct[i]
    blocks[off + 154] = UInt8(0)
    blocks[off + 155] = UInt8(0x20)


# --- writer round-trip -------------------------------------------------


def test_writer_roundtrip_single() raises:
    var w = TarWriter()
    w.add("hello.txt", String("hello world\n").as_bytes())
    var archive = w.finalize()
    var entries = open_tar(Span(archive))
    assert_equal(len(entries), 1)
    assert_equal(entries[0].info.name, "hello.txt")
    assert_equal(entries[0].info.size, 12)
    assert_equal(_content(entries[0]), "hello world\n")


def test_writer_roundtrip_multiple() raises:
    var w = TarWriter()
    w.add("a.txt", String("alpha").as_bytes())
    w.add("b.txt", String("beta!!").as_bytes())
    w.add("c.txt", String("").as_bytes())
    var archive = w.finalize()
    var entries = open_tar(Span(archive))
    assert_equal(len(entries), 3)
    assert_equal(_content(_find_entry(entries, "a.txt")), "alpha")
    assert_equal(_content(_find_entry(entries, "b.txt")), "beta!!")
    assert_equal(_find(entries, "c.txt").size, 0)


def test_writer_end_of_archive_blocks() raises:
    var w = TarWriter()
    w.add("x", String("y").as_bytes())
    var archive = w.finalize()
    # Two trailing zero blocks after one 512 header + 512 data block.
    assert_equal(len(archive), BLOCKSIZE * 4)


def test_writer_mode_and_mtime_preserved() raises:
    var w = TarWriter()
    w.add("f.txt", String("data").as_bytes(), mode=0o640, mtime=1700000000)
    var archive = w.finalize()
    var info = open_tar(Span(archive))[0].info.copy()
    assert_equal(info.mode, 0o640)
    assert_equal(info.mtime, 1700000000)


def test_writer_binary_roundtrip() raises:
    var payload = List[UInt8]()
    for i in range(600):
        payload.append(UInt8((i * 37 + 11) & 0xFF))
    var w = TarWriter()
    w.add("blob.bin", Span(payload))
    var archive = w.finalize()
    var entries = open_tar(Span(archive))
    assert_equal(entries[0].info.size, 600)
    assert_equal(len(entries[0].data), 600)
    for i in range(600):
        assert_equal(entries[0].data[i], UInt8((i * 37 + 11) & 0xFF))


def test_writer_long_name_pax() raises:
    var longname = String(
        "some/nested/directory/"
        "an_intentionally_very_long_file_name_exceeding_one_hundred_bytes_"
        "to_force_a_pax_header_abcdef.txt"
    )
    assert_true(longname.byte_length() > 100)
    var w = TarWriter()
    w.add(longname, String("payload\n").as_bytes())
    var archive = w.finalize()
    var entries = open_tar(Span(archive))
    # The pax extended header is consumed, not surfaced as a member.
    assert_equal(len(entries), 1)
    assert_equal(entries[0].info.name, longname)
    assert_equal(_content(entries[0]), "payload\n")


def test_writer_dir_entry() raises:
    var w = TarWriter()
    w.add_dir("mydir")
    var archive = w.finalize()
    var info = open_tar(Span(archive))[0].info.copy()
    assert_equal(info.name, "mydir/")
    assert_true(info.isdir())
    assert_false(info.isfile())


def test_writer_symlink_entry() raises:
    var w = TarWriter()
    w.add_symlink("shortcut", "target.txt")
    var archive = w.finalize()
    var info = open_tar(Span(archive))[0].info.copy()
    assert_true(info.issym())
    assert_equal(info.linkname, "target.txt")


def test_writer_reparse_via_reader_names() raises:
    var w = TarWriter()
    w.add("one", String("1").as_bytes())
    w.add("two", String("2").as_bytes())
    var archive = w.finalize()
    var reader = TarReader(Span(archive))
    var names = reader.names()
    assert_equal(len(names), 2)
    assert_equal(names[0], "one")
    assert_equal(names[1], "two")


# --- fixture archives (produced by system tar) -------------------------


def test_ustar_fixture_enumerate() raises:
    var entries = read_tar_file("test/data/ustar.tar")
    assert_equal(len(entries), 5)
    assert_equal(_find(entries, "hello.txt").size, 12)
    assert_equal(_find(entries, "fox.txt").size, 45)
    assert_equal(_find(entries, "empty.txt").size, 0)
    assert_equal(_find(entries, "blob.bin").size, 300)
    assert_equal(_find(entries, "subdir/nested.txt").size, 20)


def test_ustar_fixture_contents() raises:
    var entries = read_tar_file("test/data/ustar.tar")
    assert_equal(_content(_find_entry(entries, "hello.txt")), "hello world\n")
    assert_equal(
        _content(_find_entry(entries, "fox.txt")),
        "The quick brown fox jumps over the lazy dog.\n",
    )
    assert_equal(
        _content(_find_entry(entries, "subdir/nested.txt")),
        "nested content here\n",
    )


def test_ustar_fixture_binary_size() raises:
    var entries = read_tar_file("test/data/ustar.tar")
    var blob = _find_entry(entries, "blob.bin")
    assert_equal(len(blob.data), 300)


def test_gnu_long_name() raises:
    var entries = read_tar_file("test/data/gnu.tar")
    var longname = String(
        "this_is_a_very_long_file_name_that_definitely_exceeds_the_one_"
        "hundred_byte_ustar_limit_for_names_abcdefghij.txt"
    )
    assert_true(longname.byte_length() > 100)
    var info = _find(entries, longname)
    assert_equal(info.size, 18)


def test_gnu_symlink() raises:
    var entries = read_tar_file("test/data/gnu.tar")
    var info = _find(entries, "link_to_hello.txt")
    assert_true(info.issym())
    assert_equal(info.linkname, "hello.txt")


def test_pax_path_override() raises:
    var entries = read_tar_file("test/data/pax.tar")
    assert_equal(len(entries), 4)
    var longname = String(
        "this_is_a_very_long_file_name_that_definitely_exceeds_the_one_"
        "hundred_byte_ustar_limit_for_names_abcdefghij.txt"
    )
    var info = _find(entries, longname)
    assert_equal(info.size, 18)
    assert_equal(
        _content(_find_entry(entries, "hello.txt")), "hello world\n"
    )


def test_dirs_fixture_directory_typeflag() raises:
    var entries = read_tar_file("test/data/dirs.tar")
    var d = _find(entries, "subdir/")
    assert_true(d.isdir())
    assert_equal(d.size, 0)
    var f = _find(entries, "subdir/nested.txt")
    assert_true(f.isfile())


def test_empty_archive() raises:
    var entries = read_tar_file("test/data/empty_archive.tar")
    assert_equal(len(entries), 0)


# --- numeric field decoding (hand-crafted headers) ---------------------


def test_base256_size_field() raises:
    # Write a normal 12-byte file, then re-encode its size field in
    # base-256 and confirm the reader decodes it identically.
    var w = TarWriter()
    w.add("num.bin", String("0123456789ab").as_bytes())  # 12 bytes
    var archive = w.finalize()
    # size field is at header offset 124, width 12.
    archive[124] = UInt8(0x80)  # high bit => base-256
    for i in range(125, 135):
        archive[i] = UInt8(0)
    archive[135] = UInt8(12)  # big-endian value 12
    _fix_checksum(archive, 0)
    var entries = open_tar(Span(archive))
    assert_equal(entries[0].info.size, 12)
    assert_equal(_content(entries[0]), "0123456789ab")


def test_ustar_prefix_split() raises:
    # Move part of the path into the ustar prefix field (offset 345) and
    # confirm the reader rejoins prefix + "/" + name.
    var w = TarWriter()
    w.add("leaf.txt", String("hi").as_bytes())
    var archive = w.finalize()
    var prefix = String("deep/sub/tree")
    var pb = prefix.as_bytes()
    for i in range(len(pb)):
        archive[345 + i] = pb[i]
    _fix_checksum(archive, 0)
    var entries = open_tar(Span(archive))
    assert_equal(entries[0].info.name, "deep/sub/tree/leaf.txt")


# --- lenient parsing and error handling --------------------------------


def test_bad_checksum_member_skipped() raises:
    # A middle member (a directory, so it has no data blocks) with a
    # corrupted header is skipped, not fatal; the others survive.
    var w = TarWriter()
    w.add("first.txt", String("AAAA").as_bytes())  # header + 1 data block
    w.add_dir("baddir")  # single header block at offset 1024
    w.add("last.txt", String("BBBB").as_bytes())
    var archive = w.finalize()
    # Corrupt the directory header's name byte (offset 1024) without
    # fixing its checksum -> checksum mismatch on that block only.
    archive[1024] = UInt8(ord("Z"))
    var reader = TarReader(Span(archive))
    var names = reader.names()
    assert_equal(len(names), 2)
    assert_equal(names[0], "first.txt")
    assert_equal(names[1], "last.txt")
    assert_true(len(reader.warnings) >= 1)


def test_garbage_input_raises() raises:
    var junk = List[UInt8]()
    for i in range(BLOCKSIZE):
        junk.append(UInt8((i * 7 + 3) & 0xFF))
    with assert_raises():
        _ = open_tar(Span(junk))


def test_truncated_archive_raises() raises:
    # A valid header claims 4096 bytes of data, but only a partial data
    # run follows -> clean raise.
    var w = TarWriter()
    var big = List[UInt8]()
    for _ in range(4096):
        big.append(UInt8(ord("x")))
    w.add("big.bin", Span(big))
    var archive = w.finalize()
    # Truncate mid-file: keep header + 1 data block only.
    var truncated = List[UInt8]()
    for i in range(BLOCKSIZE * 2):
        truncated.append(archive[i])
    with assert_raises():
        _ = open_tar(Span(truncated))


def test_short_partial_block_raises() raises:
    # Non-zero bytes that do not form a full 512-byte block are corruption.
    var w = TarWriter()
    w.add("f", String("f").as_bytes())
    var archive = w.finalize()
    var truncated = List[UInt8]()
    for i in range(BLOCKSIZE * 2 + 10):  # 10 stray non-zero bytes
        var b = archive[i]
        if i >= BLOCKSIZE * 2:
            b = UInt8(ord("!"))
        truncated.append(b)
    with assert_raises():
        _ = open_tar(Span(truncated))


def test_type_helpers_are_exclusive() raises:
    var w = TarWriter()
    w.add("reg", String("r").as_bytes())
    w.add_dir("dir")
    w.add_symlink("sym", "reg")
    var entries = open_tar(Span(w.finalize()))
    var reg = _find(entries, "reg")
    assert_true(reg.isfile())
    assert_false(reg.isdir())
    assert_false(reg.issym())
    var d = _find(entries, "dir/")
    assert_true(d.isdir())
    assert_false(d.isfile())
    var s = _find(entries, "sym")
    assert_true(s.issym())
    assert_false(s.isfile())


# --- hostile-input regression tests (adversarial review) ---------------


def _put_str(mut b: List[UInt8], off: Int, s: String):
    var by = s.as_bytes()
    for i in range(len(by)):
        b[off + i] = by[i]


def _put_octal(mut b: List[UInt8], off: Int, width: Int, value: Int):
    # (width - 1) octal digits, then a NUL terminator.
    var v = value
    for i in range(width - 1):
        b[off + width - 2 - i] = UInt8(ord("0") + (v & 7))
        v = v >> 3
    b[off + width - 1] = UInt8(0)


def _make_header(name: String, size: Int, typeflag: UInt8) raises -> List[UInt8]:
    """Build a single forged-valid ustar header block for hostile fixtures."""
    var b = List[UInt8]()
    for _ in range(BLOCKSIZE):
        b.append(UInt8(0))
    _put_str(b, 0, name)
    _put_octal(b, 100, 8, 0o644)  # mode
    _put_octal(b, 108, 8, 0)  # uid
    _put_octal(b, 116, 8, 0)  # gid
    _put_octal(b, 124, 12, size)  # size
    _put_octal(b, 136, 12, 0)  # mtime
    b[156] = typeflag
    _put_str(b, 257, "ustar")
    b[262] = UInt8(0)
    b[263] = UInt8(ord("0"))
    b[264] = UInt8(ord("0"))
    _fix_checksum(b, 0)
    return b^


def test_base256_negative_size_raises() raises:
    # T1(a): a forged-valid ustar header whose base-256 size field encodes a
    # negative value must raise (not rewind `pos` and re-parse forever).
    var w = TarWriter()
    w.add("x", String("x").as_bytes())
    var archive = w.finalize()
    var block = List[UInt8]()
    for i in range(BLOCKSIZE):  # keep only the header block
        block.append(archive[i])
    block[124] = UInt8(0x80)  # high bit => base-256 decoding
    for i in range(125, 136):
        block[i] = UInt8(0)
    block[128] = UInt8(0x80)  # shifts onto bit 63 => negative Int
    _fix_checksum(block, 0)
    with assert_raises():
        _ = open_tar(Span(block))  # raises fast, does not hang


def test_pax_oversized_size_raises() raises:
    # T1(b): a pax `size` record with a 20-digit number overflows Int; the
    # _atoi digit cap must reject it rather than wrap to a bogus value.
    var record = String("29 size=12345678901234567890\n")
    assert_equal(record.byte_length(), 29)
    var archive = List[UInt8]()
    var paxhdr = _make_header(
        "PaxHeader", record.byte_length(), UInt8(ord("x"))
    )
    for b in paxhdr:
        archive.append(b)
    var rb = record.as_bytes()
    for i in range(len(rb)):
        archive.append(rb[i])
    for _ in range(BLOCKSIZE - len(rb)):  # pad pax data to a full block
        archive.append(UInt8(0))
    var memhdr = _make_header("f.txt", 0, UInt8(ord("0")))
    for b in memhdr:
        archive.append(b)
    for _ in range(BLOCKSIZE * 2):  # end-of-archive
        archive.append(UInt8(0))
    with assert_raises():
        _ = open_tar(Span(archive))  # raises fast, does not hang


def test_writer_oversized_mode_raises() raises:
    # T2: a mode that does not fit the 8-byte octal field (max 0o7777777)
    # must raise rather than silently write its low bits.
    var w = TarWriter()
    with assert_raises():
        w.add("f", String("d").as_bytes(), mode=0o10000000)


def test_writer_negative_uid_raises() raises:
    # T2: a negative numeric field must raise, not corrupt the header.
    var w = TarWriter()
    with assert_raises():
        w.add("f", String("d").as_bytes(), uid=-1)


def test_writer_embedded_nul_name_raises() raises:
    # T4: a name containing a NUL byte would truncate on read-back.
    var nb = List[UInt8]()
    nb.append(UInt8(ord("a")))
    nb.append(UInt8(0))
    nb.append(UInt8(ord("b")))
    var name = String(StringSlice(unsafe_from_utf8=Span(nb)))
    var w = TarWriter()
    with assert_raises():
        w.add(name, String("d").as_bytes())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
