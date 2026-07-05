"""The archive-member data model shared by the tar reader and writer.

`TarInfo` mirrors Python's `tarfile.TarInfo`: it describes a single
member (its name, size, permissions, ownership, and link target) but
does not itself hold the file's bytes. The reader pairs each `TarInfo`
with the member's content in a `TarEntry`.
"""

# --- Type flags (mirror `tarfile` module constants) --------------------
# Stored in `TarInfo.typeflag` as the raw ustar type byte.
comptime REGTYPE = UInt8(ord("0"))  # regular file
comptime AREGTYPE = UInt8(0)  # regular file (legacy NUL form)
comptime LNKTYPE = UInt8(ord("1"))  # hard link
comptime SYMTYPE = UInt8(ord("2"))  # symbolic link
comptime CHRTYPE = UInt8(ord("3"))  # character device
comptime BLKTYPE = UInt8(ord("4"))  # block device
comptime DIRTYPE = UInt8(ord("5"))  # directory
comptime FIFOTYPE = UInt8(ord("6"))  # FIFO
comptime CONTTYPE = UInt8(ord("7"))  # contiguous file

# Extension type flags (consumed by the reader, never surfaced as members).
comptime GNU_LONGNAME = UInt8(ord("L"))  # GNU long name for the next header
comptime GNU_LONGLINK = UInt8(ord("K"))  # GNU long linkname for the next header
comptime XHDTYPE = UInt8(ord("x"))  # pax per-file extended header
comptime XGLTYPE = UInt8(ord("g"))  # pax global extended header


@fieldwise_init
struct TarInfo(Copyable, Movable, Writable):
    """Metadata for one archive member (mirrors `tarfile.TarInfo`).

    `typeflag` holds the raw ustar type byte; use `isfile`/`isdir`/
    `issym`/`islnk` rather than comparing it directly. `linkname` is
    the target for symbolic and hard links, empty otherwise. `size` is
    the member's content length in bytes (0 for directories and links).
    """

    var name: String
    var size: Int
    var mtime: Int
    var mode: Int
    var typeflag: UInt8
    var uid: Int
    var gid: Int
    var uname: String
    var gname: String
    var linkname: String

    def isfile(self) -> Bool:
        """A regular file (both the modern `0` and legacy NUL forms)."""
        return self.typeflag == REGTYPE or self.typeflag == AREGTYPE

    def isreg(self) -> Bool:
        """Alias for `isfile`, matching `tarfile.TarInfo.isreg`."""
        return self.isfile()

    def isdir(self) -> Bool:
        return self.typeflag == DIRTYPE

    def issym(self) -> Bool:
        return self.typeflag == SYMTYPE

    def islnk(self) -> Bool:
        return self.typeflag == LNKTYPE

    def write_to(self, mut writer: Some[Writer]):
        writer.write("TarInfo(", self.name, ", ", self.size, " bytes")
        if self.linkname.byte_length() > 0:
            writer.write(" -> ", self.linkname)
        writer.write(")")


@fieldwise_init
struct TarEntry(Copyable, Movable, Writable):
    """A member's metadata paired with its extracted content bytes.

    `data` is empty for members that carry no content (directories,
    symbolic and hard links). For regular files it is exactly `info.size`
    bytes long.
    """

    var info: TarInfo
    var data: List[UInt8]

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.info)
