"""The texture digest that keys Sunstone's tag table (mod/texture_tags.json).

PLACEHOLDER. Melange's texture tags (mg_texTag) look a texture up by a digest of its base level that Melange itself
computes at upload. Melange defines the reference scheme; until it lands this module uses the texture inventory's own
key, and make_tag_table.py calls only the two functions below. Replace both bodies (and SCHEME) with Melange's reference
implementation; nothing else has to change.

Only one-way digests ever reach the table: no texel of a game texture is written anywhere.
"""
import hashlib

# Written into the table so Melange (and a reader) can tell which digest the keys are.
SCHEME = "placeholder-inventory-sha1-16"

# XImage format codes as the engine stores them.
FORMATS = {"RGB": 0, "RGBA": 1}


def digest(w, h, fmt, pixels):
    """The digest of a texture's base level: w, h in texels, fmt an XImage format code (0 RGB, 1 RGBA) or name,
    pixels the base level's bytes as the engine uploads them (rows in upload order, no padding).

    PLACEHOLDER: the inventory's key, sha1(pixels + b"w,h,fmt")[:16].
    """
    code = FORMATS.get(fmt, fmt)
    return hashlib.sha1(bytes(pixels) + b"%d,%d,%d" % (w, h, code)).hexdigest()[:16]


def digest_entry(entry):
    """The digest of an inventory entry (inventory.json row).

    PLACEHOLDER: the inventory's id, which is digest() of the XImage's base level as extracted. With Melange's scheme
    this needs the base level's bytes: decode the cache PNG (cache/<id>.png is stored top row first and always RGBA, so
    flip it back to upload order and drop alpha for RGB) and call digest(w, h, fmt, pixels).
    """
    return entry["id"]
