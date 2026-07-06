"""Pure-Mojo tar archive reading and writing, mirroring Python's
`tarfile` module API.

Reading (`open_tar` / `TarReader`) understands the ustar format plus the
common extensions: GNU long names (typeflag `L`), pax extended headers
(typeflag `x`/`g` — the `path`, `size`, and `linkpath` keyword records
are honored, others are skipped), the ustar `prefix` field, and both
octal and base-256 numeric fields. 512-byte block padding and the
end-of-archive zero block are handled. Parsing is liberal where safe: a
member whose stored checksum does not match is skipped with a recorded
warning rather than aborting the archive, but a garbage first block or a
truncated member data run raises cleanly.

Writing (`TarWriter`) emits ustar archives from `(name, bytes, mode,
mtime)` entries. A name longer than 100 bytes is written with a leading
pax extended header carrying a `path` record, so the full name survives
the round trip and is readable by system `tar`.

No compression is in scope. For `.tar.gz` / `.tar.bz2`, pair this with a
separate zlib/gzip library and feed the decompressed bytes to
`open_tar` (or compress `TarWriter.finalize()`'s output).

Sparse files are not in scope either: a GNU sparse member (typeflag `S`,
or a member carrying `GNU.sparse.*` pax records) stores a hole map plus
only the non-hole bytes, so its archived length differs from its logical
size. Rather than mis-read the sparse-encoded bytes as file content and
desync the rest of the parse, `open_tar` raises on any sparse member.
"""

from std.memory import memcpy

from tar.model import (
    TarInfo,
    TarEntry,
    REGTYPE,
    AREGTYPE,
    LNKTYPE,
    SYMTYPE,
    DIRTYPE,
    GNU_LONGNAME,
    GNU_LONGLINK,
    XHDTYPE,
    XGLTYPE,
    GNU_SPARSE,
)

comptime BLOCKSIZE = 512
comptime _NUL = UInt8(0)
comptime _SPACE = UInt8(0x20)
comptime _EQ = UInt8(ord("="))
comptime _NL = UInt8(0x0A)
comptime _SLASH = UInt8(ord("/"))

comptime USTAR_MAGIC = "ustar"


# --- Low-level field decoding -----------------------------------------


def _padded(size: Int) -> Int:
    """Round a byte count up to a whole number of 512-byte blocks."""
    return ((size + BLOCKSIZE - 1) // BLOCKSIZE) * BLOCKSIZE


def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(ord("0")) and b <= UInt8(ord("9"))


def _get_str(block: Span[UInt8, _], offset: Int, length: Int) -> String:
    """Read a NUL-terminated (or field-filling) string field."""
    var end = offset
    var limit = offset + length
    while end < limit and block[end] != _NUL:
        end += 1
    return String(StringSlice(unsafe_from_utf8=block[offset:end]))


def _get_octal(block: Span[UInt8, _], offset: Int, length: Int) -> Int:
    """Parse an octal numeric field, skipping leading/trailing padding."""
    var v = 0
    var i = offset
    var end = offset + length
    while i < end and (block[i] == _SPACE or block[i] == _NUL):
        i += 1
    while (
        i < end and block[i] >= UInt8(ord("0")) and block[i] <= UInt8(ord("7"))
    ):
        v = v * 8 + Int(block[i]) - ord("0")
        i += 1
    return v


def _get_num(block: Span[UInt8, _], offset: Int, length: Int) raises -> Int:
    """Parse a numeric field: base-256 if the high bit is set, else octal."""
    var first = block[offset]
    if (first & 0x80) != 0:
        # Base-256. A ustar numeric field is up to 12 bytes wide, i.e. 95
        # usable bits after the 0x80 flag, but the result must fit a signed
        # 64-bit Int. Guard every shift: if the running value already
        # occupies the high 8 bits, the next `<< 8` would overflow and
        # silently wrap a huge (95-bit) size down into a small — or
        # negative — one. Reject rather than wrap.
        var v = Int(first & 0x7F)
        for i in range(offset + 1, offset + length):
            if v > (Int.MAX >> 8):
                raise Error("mojo-tar: base-256 numeric field exceeds 64 bits")
            v = (v << 8) | Int(block[i])
        return v
    return _get_octal(block, offset, length)


def _is_zero_block(block: Span[UInt8, _]) -> Bool:
    for i in range(BLOCKSIZE):
        if block[i] != _NUL:
            return False
    return True


def _compute_checksum(block: Span[UInt8, _]) -> Int:
    """Unsigned header checksum: the checksum field counts as 8 spaces."""
    var s = 0
    for i in range(BLOCKSIZE):
        if i >= 148 and i < 156:
            s += 0x20
        else:
            s += Int(block[i])
    return s


def _parse_dec(block: Span[UInt8, _], start: Int, end: Int) -> Int:
    var v = 0
    for i in range(start, end):
        if not _is_digit(block[i]):
            break
        v = v * 10 + Int(block[i]) - ord("0")
    return v


# --- Header parsing ----------------------------------------------------


def _parse_header(block: Span[UInt8, _]) raises -> TarInfo:
    """Decode a 512-byte ustar header into a `TarInfo`.

    Applies the ustar `prefix` field (long-path split) when present.
    """
    var name = _get_str(block, 0, 100)
    var mode = _get_octal(block, 100, 8)
    var uid = _get_octal(block, 108, 8)
    var gid = _get_octal(block, 116, 8)
    var size = _get_num(block, 124, 12)
    var mtime = _get_num(block, 136, 12)
    var typeflag = block[156]
    var linkname = _get_str(block, 157, 100)
    var magic = _get_str(block, 257, 6)
    var uname = _get_str(block, 265, 32)
    var gname = _get_str(block, 297, 32)
    if magic.startswith(USTAR_MAGIC):
        var prefix = _get_str(block, 345, 155)
        if prefix.byte_length() > 0:
            name = prefix + "/" + name
    return TarInfo(
        name=name^,
        size=size,
        mtime=mtime,
        mode=mode,
        typeflag=typeflag,
        uid=uid,
        gid=gid,
        uname=uname^,
        gname=gname^,
        linkname=linkname^,
    )


def _has_gnu_sparse(fields: Dict[String, String]) -> Bool:
    """True if pax fields describe a GNU sparse member (any format version).

    GNU sparse encodes a file's data as a hole map plus only the non-hole
    bytes, so the archived data length differs from the logical `size`.
    Honoring it correctly requires materializing the holes; treating the
    sparse-encoded bytes as file content — or advancing `pos` by the logical
    size — desyncs the parse. We detect and reject rather than mis-read.
    """
    return (
        "GNU.sparse.major" in fields
        or "GNU.sparse.minor" in fields
        or "GNU.sparse.name" in fields
        or "GNU.sparse.realsize" in fields
        or "GNU.sparse.size" in fields
        or "GNU.sparse.map" in fields
        or "GNU.sparse.numblocks" in fields
        or "GNU.sparse.offset" in fields
        or "GNU.sparse.numbytes" in fields
    )


def _parse_pax(records: Span[UInt8, _], mut fields: Dict[String, String]):
    """Parse pax `len key=value\\n` records into `fields`.

    Malformed records stop parsing; whatever was decoded so far is kept.
    """
    var i = 0
    var n = len(records)
    while i < n:
        var j = i
        while j < n and _is_digit(records[j]):
            j += 1
        if j >= n or records[j] != _SPACE or j == i:
            break
        var length = _parse_dec(records, i, j)
        if length <= 0:
            break
        var rec_end = i + length
        if rec_end > n or records[rec_end - 1] != _NL:
            break
        var kv = j + 1
        var eq = kv
        while eq < rec_end and records[eq] != _EQ:
            eq += 1
        if eq < rec_end:
            var key = String(StringSlice(unsafe_from_utf8=records[kv:eq]))
            var val = String(
                StringSlice(unsafe_from_utf8=records[eq + 1 : rec_end - 1])
            )
            fields[key^] = val^
        i = rec_end


# --- Reading -----------------------------------------------------------


def _parse_archive(
    data: Span[UInt8, _],
    mut entries: List[TarEntry],
    mut warnings: List[String],
) raises:
    """Core parse loop shared by `open_tar` and `TarReader`."""
    var n = len(data)
    var pos = 0
    # Pending overrides supplied by an extension header that precedes
    # the member it modifies.
    var long_name = String()
    var have_long_name = False
    var long_link = String()
    var have_long_link = False
    var pax = Dict[String, String]()

    while pos + BLOCKSIZE <= n:
        var start_pos = pos
        var block = data[pos : pos + BLOCKSIZE]
        if _is_zero_block(block):
            # First zero block ends the archive (a valid archive uses
            # two, but one is sufficient to stop).
            break

        var stored = _get_octal(block, 148, 8)
        if _compute_checksum(block) != stored:
            if (
                len(entries) == 0
                and not have_long_name
                and not (have_long_link)
                and len(pax) == 0
            ):
                raise Error(
                    "mojo-tar: bad checksum in first block (not a tar archive?)"
                )
            # A bad checksum on a non-first block is unrecoverable, and we
            # must NOT resync using the header's size field: on a corrupt
            # block that field is attacker-controlled. A crafted size of 0
            # (or any value that lands the skip a single block ahead) would
            # degrade the skip to just this header block and reinterpret the
            # member's data as the next headers -- the exact content-smuggling
            # / scanner-evasion vector this guard exists to close. There is no
            # trustworthy way to learn where the member's data ends, so mirror
            # CPython `tarfile`'s ReadError and abort rather than guess.
            raise Error(
                "mojo-tar: bad checksum at offset "
                + String(pos)
                + " (header untrusted; cannot safely resync, aborting)"
            )

        var info = _parse_header(block)
        pos += BLOCKSIZE
        var declared = info.size
        # A size that is negative (base-256 shifted into the sign bit) or
        # larger than the whole archive is hostile: it can make _padded()
        # negative and rewind `pos`, re-parsing the same header forever.
        if declared < 0 or declared > n:
            raise Error("mojo-tar: implausible entry size " + String(declared))
        var data_end = pos + _padded(declared)
        # Monotonic-progress guard: the next position must advance past the
        # block we started this iteration on, or we would loop forever.
        if data_end <= start_pos:
            raise Error(
                "mojo-tar: non-monotonic parse progress (entry size "
                + String(declared)
                + ")"
            )
        if data_end > n:
            raise Error(
                "mojo-tar: truncated archive (member '"
                + info.name
                + "' data runs past end)"
            )
        var payload = data[pos:data_end]

        if info.typeflag == GNU_LONGNAME:
            long_name = _cstr(payload, declared)
            have_long_name = True
            pos = data_end
            continue
        if info.typeflag == GNU_LONGLINK:
            long_link = _cstr(payload, declared)
            have_long_link = True
            pos = data_end
            continue
        if info.typeflag == XHDTYPE or info.typeflag == XGLTYPE:
            _parse_pax(data[pos : pos + declared], pax)
            pos = data_end
            continue
        if info.typeflag == GNU_SPARSE:
            raise Error(
                "mojo-tar: GNU sparse members (typeflag 'S') are not"
                " supported (would desync the parse)"
            )

        # A real member: apply any pending overrides.
        if _has_gnu_sparse(pax):
            raise Error(
                "mojo-tar: GNU sparse members (GNU.sparse.* pax records) are"
                " not supported (would desync the parse)"
            )
        if have_long_name:
            info.name = long_name.copy()
            have_long_name = False
        if have_long_link:
            info.linkname = long_link.copy()
            have_long_link = False
        if "path" in pax:
            info.name = pax["path"].copy()
        if "linkpath" in pax:
            info.linkname = pax["linkpath"].copy()
        if "size" in pax:
            var override_size = _atoi(pax["size"])
            # A pax size override is just as hostile as a header size: reject
            # negative or implausibly large values before they can rewind pos.
            if override_size < 0 or override_size > n:
                raise Error(
                    "mojo-tar: implausible entry size " + String(override_size)
                )
            # The pax size governs the true content length; re-read the
            # payload if it differs from the header's declared size.
            if override_size != declared:
                var real_end = pos + _padded(override_size)
                if real_end <= start_pos:
                    raise Error(
                        "mojo-tar: non-monotonic parse progress (pax size "
                        + String(override_size)
                        + ")"
                    )
                if real_end > n:
                    raise Error(
                        "mojo-tar: truncated archive (pax size for '"
                        + info.name
                        + "' runs past end)"
                    )
                info.size = override_size
                entries.append(
                    TarEntry(
                        info^, _copy_bytes(data[pos:real_end], override_size)
                    )
                )
                pos = real_end
                pax.clear()
                continue

        pax.clear()

        var content = List[UInt8]()
        if info.isfile():
            content = _copy_bytes(payload, declared)
        entries.append(TarEntry(info^, content^))
        pos = data_end

    # Any leftover partial block that is not zero padding is corruption.
    if pos < n:
        for i in range(pos, n):
            if data[i] != _NUL:
                raise Error(
                    "mojo-tar: truncated archive (trailing partial block)"
                )


def open_tar(data: Span[UInt8, _]) raises -> List[TarEntry]:
    """Parse a tar archive into its member entries.

    Returns one `TarEntry` per real member (extension headers for GNU
    long names and pax metadata are consumed and applied, never
    returned). Raises on a garbage leading block or a member whose data
    is truncated; skips members with a bad checksum. Use `TarReader` if
    you want the recorded checksum warnings.
    """
    var entries = List[TarEntry]()
    var warnings = List[String]()
    _parse_archive(data, entries, warnings)
    return entries^


struct TarReader(Movable):
    """Reads a tar archive held in a byte span.

    Construction parses eagerly. `entries` holds the members; `warnings`
    holds one message per member skipped for a bad checksum.
    """

    var entries: List[TarEntry]
    var warnings: List[String]

    def __init__(out self, data: Span[UInt8, _]) raises:
        self.entries = List[TarEntry]()
        self.warnings = List[String]()
        _parse_archive(data, self.entries, self.warnings)

    def names(self) -> List[String]:
        var out = List[String]()
        for entry in self.entries:
            out.append(entry.info.name.copy())
        return out^


def _cstr(payload: Span[UInt8, _], size: Int) -> String:
    """Decode a length-bounded, NUL-trimmed string (GNU long-name data)."""
    var end = size
    if end > len(payload):
        end = len(payload)
    while end > 0 and payload[end - 1] == _NUL:
        end -= 1
    return String(StringSlice(unsafe_from_utf8=payload[0:end]))


def _copy_bytes(payload: Span[UInt8, _], size: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var limit = size
    if limit > len(payload):
        limit = len(payload)
    for i in range(limit):
        out.append(payload[i])
    return out^


def _atoi(s: String) raises -> Int:
    var v = 0
    var count = 0
    for b in s.as_bytes():
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            break
        # Cap the digit count: 18 decimal digits max out below 10^18, which
        # fits a signed 64-bit Int with room to spare. A 19th digit could
        # overflow and wrap into a negative or small positive value, so a
        # pax size with 19+ digits is rejected rather than silently wrapped.
        count += 1
        if count > 18:
            raise Error("mojo-tar: pax numeric field too large: " + s)
        v = v * 10 + Int(b) - ord("0")
    return v


def read_tar_file(path: String) raises -> List[TarEntry]:
    """Read and parse a tar archive from a filesystem path."""
    var raw = open(path, "r").read_bytes()
    return open_tar(Span(raw))


# --- Writing -----------------------------------------------------------


def _octal_str(value: Int, width: Int) -> String:
    """Zero-padded octal of exactly `width` digits (low bits if oversized)."""
    var digits = List[UInt8]()
    var v = value
    for _ in range(width):
        digits.append(UInt8(ord("0") + (v & 7)))
        v = v >> 3
    var out = String()
    for i in range(width):
        out += String(
            StringSlice(unsafe_from_utf8=digits[width - 1 - i : width - i])
        )
    return out^


def _set_str(mut buf: List[UInt8], offset: Int, s: String, maxlen: Int) raises:
    var bytes = s.as_bytes()
    var count = len(bytes)
    # Silently truncating a name/linkname/uname/gname that overflows its
    # fixed-width header field corrupts the value on read-back. Callers that
    # can carry an over-length value (name, linkname) must emit a pax record
    # and pass a pre-truncated field; anything still over-length here is a
    # bug or an unrepresentable uname/gname, so raise rather than truncate.
    if count > maxlen:
        raise Error(
            "mojo-tar: value of length "
            + String(count)
            + " exceeds "
            + String(maxlen)
            + "-byte header field: "
            + s
        )
    for i in range(count):
        # An embedded NUL would truncate the field on read-back (NUL is the
        # field terminator), silently corrupting the name/linkname.
        if bytes[i] == _NUL:
            raise Error("mojo-tar: embedded NUL byte in field: " + s)
        buf[offset + i] = bytes[i]


def _set_octal(
    mut buf: List[UInt8], offset: Int, width: Int, value: Int
) raises:
    # ustar numeric fields: (width - 1) octal digits followed by a NUL, so
    # the field holds values in [0, 8**(width-1)). A value outside that range
    # would be silently truncated to its low bits (or mangled if negative);
    # raise instead of writing a corrupt field. For the 12-byte size field
    # this caps at 8 GiB - 1, matching the README's stated scope.
    if value < 0:
        raise Error(
            "mojo-tar: negative value for numeric field: " + String(value)
        )
    var limit = 1 << (3 * (width - 1))
    if value >= limit:
        raise Error(
            "mojo-tar: value "
            + String(value)
            + " does not fit numeric field (max "
            + String(limit - 1)
            + ")"
        )
    var s = _octal_str(value, width - 1)
    var bytes = s.as_bytes()
    for i in range(width - 1):
        buf[offset + i] = bytes[i]
    buf[offset + width - 1] = _NUL


def _finalize_checksum(mut buf: List[UInt8]):
    for i in range(148, 156):
        buf[i] = _SPACE
    var s = 0
    for i in range(BLOCKSIZE):
        s += Int(buf[i])
    var oct = _octal_str(s, 6)
    var bytes = oct.as_bytes()
    for i in range(6):
        buf[148 + i] = bytes[i]
    buf[154] = _NUL
    buf[155] = _SPACE


def _build_header(
    name: String,
    size: Int,
    mode: Int,
    mtime: Int,
    typeflag: UInt8,
    uid: Int,
    gid: Int,
    uname: String,
    gname: String,
    linkname: String,
) raises -> List[UInt8]:
    var buf = List[UInt8]()
    for _ in range(BLOCKSIZE):
        buf.append(_NUL)
    _set_str(buf, 0, name, 100)
    _set_octal(buf, 100, 8, mode)
    _set_octal(buf, 108, 8, uid)
    _set_octal(buf, 116, 8, gid)
    _set_octal(buf, 124, 12, size)
    _set_octal(buf, 136, 12, mtime)
    buf[156] = typeflag
    _set_str(buf, 157, linkname, 100)
    # magic "ustar\0" + version "00"
    _set_str(buf, 257, USTAR_MAGIC, 5)
    buf[262] = _NUL
    buf[263] = UInt8(ord("0"))
    buf[264] = UInt8(ord("0"))
    _set_str(buf, 265, uname, 32)
    _set_str(buf, 297, gname, 32)
    _finalize_checksum(buf)
    return buf^


def _pax_record(key: String, value: String) -> String:
    """Build one `len key=value\\n` pax record with a self-consistent len."""
    var base = key.byte_length() + value.byte_length() + 3  # space, '=', '\n'
    var length = base + 1
    var prev = -1
    while length != prev:
        prev = length
        length = base + String(length).byte_length()
    return String(length) + " " + key + "=" + value + "\n"


def _reject_nul(s: String) raises:
    """Raise if `s` contains a NUL byte (would truncate a header field)."""
    for b in s.as_bytes():
        if b == _NUL:
            raise Error("mojo-tar: embedded NUL byte in field: " + s)


def _truncate_bytes(s: String, maxlen: Int) -> String:
    var bytes = s.as_bytes()
    var count = len(bytes)
    if count > maxlen:
        count = maxlen
    return String(StringSlice(unsafe_from_utf8=bytes[0:count]))


struct TarWriter(Movable):
    """Builds a ustar archive incrementally.

    Add members with `add` (regular file), `add_dir`, or `add_symlink`,
    then call `finalize` to get the complete archive bytes (including the
    end-of-archive zero blocks). Names longer than 100 bytes are written
    with a leading pax `path` extended header.
    """

    var _blocks: List[UInt8]

    def __init__(out self):
        self._blocks = List[UInt8]()

    def _extend(mut self, block: List[UInt8]):
        for b in block:
            self._blocks.append(b)

    def _append_padded_data(mut self, data: Span[UInt8, _]):
        for b in data:
            self._blocks.append(b)
        var pad = _padded(len(data)) - len(data)
        for _ in range(pad):
            self._blocks.append(_NUL)

    def _emit_pax_header(mut self, records: String) raises:
        var rec_bytes = records.as_bytes()
        var hdr = _build_header(
            name="PaxHeader",
            size=len(rec_bytes),
            mode=0o644,
            mtime=0,
            typeflag=XHDTYPE,
            uid=0,
            gid=0,
            uname=String(),
            gname=String(),
            linkname=String(),
        )
        self._extend(hdr)
        self._append_padded_data(rec_bytes)

    def _emit_pax_path(mut self, name: String) raises:
        # The full name goes verbatim into the pax record data, bypassing
        # _set_str's per-field NUL guard, so validate the whole thing here.
        _reject_nul(name)
        self._emit_pax_header(_pax_record("path", name))

    def add(
        mut self,
        name: String,
        data: Span[UInt8, _],
        mode: Int = 0o644,
        mtime: Int = 0,
        uid: Int = 0,
        gid: Int = 0,
        uname: String = String(),
        gname: String = String(),
    ) raises:
        """Append a regular-file member with the given content bytes."""
        var stored_name = name
        if name.byte_length() > 100:
            self._emit_pax_path(name)
            stored_name = _truncate_bytes(name, 100)
        var hdr = _build_header(
            name=stored_name,
            size=len(data),
            mode=mode,
            mtime=mtime,
            typeflag=REGTYPE,
            uid=uid,
            gid=gid,
            uname=uname,
            gname=gname,
            linkname=String(),
        )
        self._extend(hdr)
        self._append_padded_data(data)

    def add_dir(
        mut self, name: String, mode: Int = 0o755, mtime: Int = 0
    ) raises:
        """Append a directory member (name is given a trailing `/`)."""
        var dirname = name
        if not dirname.endswith("/"):
            dirname = dirname + "/"
        var stored_name = dirname
        if dirname.byte_length() > 100:
            self._emit_pax_path(dirname)
            stored_name = _truncate_bytes(dirname, 100)
        var hdr = _build_header(
            name=stored_name,
            size=0,
            mode=mode,
            mtime=mtime,
            typeflag=DIRTYPE,
            uid=0,
            gid=0,
            uname=String(),
            gname=String(),
            linkname=String(),
        )
        self._extend(hdr)

    def add_symlink(
        mut self,
        name: String,
        target: String,
        mode: Int = 0o777,
        mtime: Int = 0,
    ) raises:
        """Append a symbolic-link member pointing at `target`.

        A name or target longer than 100 bytes is written with a leading
        pax extended header (`path` / `linkpath` records) so the full
        values survive the round trip, mirroring `add`. Without this the
        over-length field would be silently truncated in the ustar header.
        """
        var stored_name = name
        var stored_target = target
        var records = String()
        if name.byte_length() > 100:
            _reject_nul(name)
            records += _pax_record("path", name)
            stored_name = _truncate_bytes(name, 100)
        if target.byte_length() > 100:
            _reject_nul(target)
            records += _pax_record("linkpath", target)
            stored_target = _truncate_bytes(target, 100)
        if records.byte_length() > 0:
            self._emit_pax_header(records)
        var hdr = _build_header(
            name=stored_name,
            size=0,
            mode=mode,
            mtime=mtime,
            typeflag=SYMTYPE,
            uid=0,
            gid=0,
            uname=String(),
            gname=String(),
            linkname=stored_target,
        )
        self._extend(hdr)

    def finalize(mut self) -> List[UInt8]:
        """Return the complete archive, terminated by two zero blocks."""
        var out = self._blocks.copy()
        for _ in range(BLOCKSIZE * 2):
            out.append(_NUL)
        return out^
