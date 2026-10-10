"""Compare generated files with the files on disk for the generators' --check.

PNG files are compared by what they decode to (IHDR, any other chunk, and the inflated pixel rows), not by their bytes:
the compressed IDAT stream depends on the zlib build (zlib 1.3.1 and zlib-ng give different deflate bytes for the same
pixels), so a byte comparison would report every PNG as different on a contributor's Python although the images are
identical. Everything else (TGA, WAV, glTF, bin) is compared byte for byte.
"""
import struct
import zlib


def _decode(data):
    """-> (other chunks as (tag, body) in order, inflated image data), or None when `data` is not a well-formed PNG."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, chunks, idat = 8, [], bytearray()
    while pos + 8 <= len(data):
        n, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if len(body) != n:
            return None
        if tag == b"IDAT":
            idat += body
        else:
            chunks.append((tag, body))
        pos += 12 + n
    try:
        return chunks, zlib.decompress(bytes(idat))
    except zlib.error:
        return None


def same(disk, fresh, name=""):
    """True when the two byte strings are the same file. A PNG pair is the same when its decoded content is."""
    if disk == fresh:
        return True
    if name.lower().endswith(".png"):
        a, b = _decode(disk), _decode(fresh)
        return a is not None and a == b
    return False
