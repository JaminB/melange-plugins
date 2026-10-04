#!/usr/bin/env python3
"""melange-plugins store tooling. Python 3.10+, standard library only.

Commands:
  validate <id>... | --all   run every store check on the given plugins
  pack <id> --out DIR        build the release zip for the newest CHANGELOG version
  index [--check]            (re)generate index.json, or check it is up to date
  verify-release ZIP --id ID --version V --sha256 HASH --size N
                             verify a built/downloaded zip against the recorded facts
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
import urllib.parse
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ID_RE = re.compile(r"^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$")
SEGMENT_CHARS_RE = re.compile(r"^[A-Za-z0-9._ -]+$")
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+)?$"
)
DEVICE_NAMES = {
    "con", "prn", "aux", "nul",
    *{f"com{i}" for i in range(1, 10)},
    *{f"lpt{i}" for i in range(1, 10)},
}

LICENCE_ALLOWLIST = {
    "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib",
    "MPL-2.0", "LGPL-3.0-or-later", "GPL-3.0-or-later", "CC0-1.0",
    "CC-BY-4.0", "CC-BY-SA-4.0", "Unlicense",
}
CATEGORIES = {
    "graphics", "gameplay", "maps", "weapons", "audio",
    "interface", "tools", "libraries",
}
GAME_BUILDS = {"1077"}

EXECUTABLE_EXTENSIONS = {
    ".exe", ".dll", ".asi", ".sys", ".scr", ".com", ".bat", ".cmd", ".ps1",
    ".psm1", ".vbs", ".wsf", ".hta", ".msi", ".jar", ".lnk", ".reg",
}
EXECUTABLE_MAGICS = (b"MZ", b"\x7fELF")

FILE_TYPE_EXTENSIONS = {
    ".lua", ".json", ".txt", ".md", ".ini", ".glsl", ".vert", ".frag", ".fx", ".cg",
    ".png", ".tga", ".dds", ".jpg", ".jpeg", ".xom", ".lub", ".ergpatch",
    ".wav", ".ogg", ".html", ".css", ".js", ".svg", ".ttf", ".otf",
}

RESERVED_MOD_PATHS = {"user", "thumper-state.json", "storage.json", "melange.ini"}

MAX_LICENSE_BYTES = 64 * 1024
MAX_SOURCE_BYTES = 48 * 1024 * 1024
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_FILE_COUNT = 2000
MAX_PACKED_BYTES = 64 * 1024 * 1024
MAX_PATH_SEGMENTS = 8
MAX_PATH_BYTES = 180
MAX_SCREENSHOT_BYTES = 1024 * 1024
MAX_SCREENSHOTS = 6
MAX_CHANGELOG_CHARS = 2000
MAX_DESCRIPTION_CHARS = 400
MAX_NAME_CHARS = 80
MAX_HOMEPAGE_CHARS = 200

INDEX_MAX_BYTES = 1024 * 1024
INDEX_MAX_PLUGINS = 500
INDEX_MAX_VERSIONS = 50

# --------------------------------------------------------------------------
# import-1 recipe rules (docs/importers.md in the Melange repo; schema/import-1.schema.json)

IMPORT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9.-]{0,47}$")
IMPORT_FORMATS = {1}
IMPORT_FILENAME_RE = re.compile(r"^[A-Za-z0-9._ -]{1,64}\.zip$")
IMPORT_SEGMENT_RE = re.compile(r"^[A-Za-z0-9._*-]+$")
IMPORT_SIZE_MAX = 512 * 1024 * 1024          # 512 MiB
IMPORT_MAX_TOTAL = 256                       # manifest::kMaxTotal
IMPORT_MAX_PER_PACK = 32                     # manifest::kMaxPerMod
IMPORT_READER_MAX_SEGMENTS = 8
IMPORT_TEXTURES_FORMAT1 = {"vanilla"}
IMPORT_SCRIPTS_FORMAT1 = {"drop"}
IMPORT_DESCRIPTOR_FORMAT1 = {"rebuild"}
IMPORT_CREDENTIAL_QUERY_WORDS = ("user", "pass", "token", "secret", "key", "auth", "credential")

IMPORT_TOP_KEYS = {
    "importVersion", "format", "id", "name", "content", "sources",
    "reader", "select", "categories", "modes", "groups", "transform", "output",
}
IMPORT_TOP_REQUIRED = {
    "importVersion", "format", "id", "name", "content", "sources",
    "reader", "select", "categories", "transform", "output",
}
IMPORT_CONTENT_KEYS = {"title", "publisher", "termsUrl", "credit"}
IMPORT_SOURCE_KEYS = {"id", "name", "urls", "fileName", "size", "sha256"}
IMPORT_READER_KEYS = {"type", "root", "registry", "titles", "descriptors", "maps", "previews"}
IMPORT_READER_REQUIRED = {"type", "root", "registry", "descriptors", "maps"}
IMPORT_SELECT_KEYS = {"levelType", "skipKeySuffix", "require", "exclude", "vanilla", "expect"}
IMPORT_SELECT_REQUIRED = {"levelType", "expect"}
IMPORT_CATEGORY_KEYS = {"id", "label", "scriptsEqual", "scriptsWithin", "default", "hidden"}
IMPORT_CATEGORY_REQUIRED = {"id", "label"}
IMPORT_GROUP_KEYS = {"id", "label", "match", "vanilla", "default"}
IMPORT_GROUP_REQUIRED = {"id", "label"}
IMPORT_TRANSFORM_KEYS = {
    "stem", "descriptor", "timeOfDay", "title", "author", "textures", "scripts", "survivor", "previews",
}
IMPORT_OUTPUT_KEYS = {
    "packPrefix", "version", "perPack", "order", "newPackBefore", "packName", "packDescription",
}
IMPORT_OUTPUT_REQUIRED = {"packPrefix", "version", "perPack", "order"}


# --------------------------------------------------------------------------
# small helpers


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def load_lines(path: Path) -> set[str]:
    if not path.exists():
        return set()
    out = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.add(line)
    return out


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def all_ids(root: Path) -> list[str]:
    plugins_dir = root / "plugins"
    if not plugins_dir.is_dir():
        return []
    return sorted(p.name for p in plugins_dir.iterdir() if p.is_dir())


def load_import_hosts(root: Path) -> set[str]:
    path = root / "policy" / "import-hosts.json"
    if not path.exists():
        return set()
    data = load_json(path)
    return set(data) if isinstance(data, list) else set()


# --------------------------------------------------------------------------
# pure layout / name rules (section 2.2 and 5.1), independently testable


def check_entry_name(name: str) -> str | None:
    """One entry name from a zip (or a would-be zip). Returns an error, or None."""
    if name == "":
        return "empty entry name"
    if ":" in name or name.startswith("/") or (len(name) > 1 and name[1] == ":"):
        return f"{name!r}: absolute path or drive letter"
    if "\\" in name:
        return f"{name!r}: backslash in path"
    segments = name.split("/")
    if len(segments) > MAX_PATH_SEGMENTS:
        return f"{name!r}: more than {MAX_PATH_SEGMENTS} path segments"
    if len(name.encode("utf-8")) > MAX_PATH_BYTES:
        return f"{name!r}: path longer than {MAX_PATH_BYTES} bytes"
    for seg in segments:
        if seg in ("", ".", ".."):
            return f"{name!r}: empty, '.' or '..' segment"
        if seg != seg.rstrip(" ."):
            return f"{name!r}: segment with a trailing dot or space"
        if any(ord(c) < 0x20 for c in seg):
            return f"{name!r}: control character in segment"
        if not SEGMENT_CHARS_RE.match(seg):
            return f"{name!r}: segment has characters outside [A-Za-z0-9._ -]"
        base = seg.split(".")[0].lower()
        if base in DEVICE_NAMES:
            return f"{name!r}: Windows device name {seg!r}"
    return None


def check_layout(plugin_id: str, entries: list[str]) -> list[str]:
    """Entries of a would-be (or real) zip for `plugin_id`. Mirrors rule 2.2/5.1."""
    errors: list[str] = []
    seen_lower: dict[str, str] = {}
    top_folders: set[str] = set()
    for name in entries:
        err = check_entry_name(name)
        if err:
            errors.append(err)
            continue
        top = name.split("/", 1)[0]
        top_folders.add(top)
        if top != plugin_id:
            errors.append(f"{name!r}: not under top folder {plugin_id!r}")
            continue
        rest = name.split("/", 1)[1] if "/" in name else ""
        rest_segments = rest.split("/") if rest else []
        if rest_segments and rest_segments[0] in RESERVED_MOD_PATHS:
            errors.append(f"{name!r}: reserved path {rest_segments[0]!r}")
        if any(seg.startswith(".") for seg in rest_segments):
            errors.append(f"{name!r}: hidden (dot) path segment")
        lower = name.lower()
        if lower in seen_lower and seen_lower[lower] != name:
            errors.append(f"{name!r}: duplicates {seen_lower[lower]!r} case-insensitively")
        seen_lower[lower] = name
    if len(top_folders) > 1:
        errors.append(f"more than one top-level folder: {sorted(top_folders)}")
    elif len(top_folders) == 1 and next(iter(top_folders)) != plugin_id:
        errors.append(f"top-level folder {next(iter(top_folders))!r} != id {plugin_id!r}")
    return errors


def is_executable_name(name: str) -> bool:
    return Path(name).suffix.lower() in EXECUTABLE_EXTENSIONS


def is_executable_magic(head: bytes) -> bool:
    return any(head.startswith(m) for m in EXECUTABLE_MAGICS)


# --------------------------------------------------------------------------
# import-1 recipe validation (mirrors the engine's own parse/validate; no JSON Schema
# library dependency, see schema/import-1.schema.json for the documented shape)


def check_import_recipe_path(path) -> str | None:
    """spice.json's importer.recipe: relative, inside the mod folder, ending in .json."""
    if not isinstance(path, str) or not path:
        return "must be a non-empty string"
    if len(path) > 64:
        return "longer than 64 characters"
    if not path.endswith(".json"):
        return "must end in .json"
    if path.startswith("/") or ":" in path or "\\" in path:
        return "must be a relative path with forward slashes only"
    segments = path.split("/")
    if any(seg in ("", ".", "..") for seg in segments):
        return "must not contain '..' or empty segments"
    return None


def check_import_glob_path(path, *, max_segments: int = IMPORT_READER_MAX_SEGMENTS) -> str | None:
    """A reader.* path or glob: relative, '/'-separated, no '..', globs only '*' within a segment."""
    if not isinstance(path, str) or not path:
        return "must be a non-empty string"
    if path.startswith("/") or ":" in path or "\\" in path:
        return "must be a relative path with forward slashes only"
    segments = path.split("/")
    if len(segments) > max_segments:
        return f"more than {max_segments} path segments"
    for seg in segments:
        if seg in ("", ".", ".."):
            return "must not contain '..' or empty segments"
        if "**" in seg:
            return "globs may use '*' only within a segment, not across segments"
        if not IMPORT_SEGMENT_RE.match(seg):
            return "segment has characters outside [A-Za-z0-9._*-]"
    return None


def validate_import_url(url, hosts: set[str]) -> str | None:
    if not isinstance(url, str):
        return "must be a string"
    try:
        parsed = urllib.parse.urlsplit(url)
    except ValueError:
        return "is not a valid URL"
    if parsed.scheme != "https":
        return "must be https://"
    if "@" in parsed.netloc:
        return "must not contain userinfo"
    host = parsed.hostname or ""
    if host not in hosts:
        return f"host {host!r} is not in policy/import-hosts.json"
    try:
        port = parsed.port
    except ValueError:
        return "has an invalid port"
    if port not in (None, 443):
        return "must not specify a port other than 443"
    if parsed.query and any(w in parsed.query.lower() for w in IMPORT_CREDENTIAL_QUERY_WORDS):
        return "query string must not contain credentials"
    return None


def _unknown_keys(obj, allowed: set[str], where: str) -> list[str]:
    if not isinstance(obj, dict):
        return [f"{where} must be an object"]
    return [f"{where}: unexpected key {k!r}" for k in sorted(set(obj.keys()) - allowed)]


def _missing_keys(obj, required: set[str], where: str) -> list[str]:
    if not isinstance(obj, dict):
        return []
    return [f"{where}: missing required key {k!r}" for k in sorted(required - set(obj.keys()))]


def validate_import_recipe(recipe, plugin_id: str, hosts: set[str], recipe_rel: str = "import.json") -> list[str]:
    """Section 3.2 field rules for an importVersion-1 recipe. Errors are prefixed with mod/<recipe_rel>."""
    if not isinstance(recipe, dict):
        return [f"mod/{recipe_rel} must be a JSON object"]

    raw: list[str] = []

    def add(msgs):
        raw.extend(msgs)

    add(_unknown_keys(recipe, IMPORT_TOP_KEYS, "top level"))
    add(_missing_keys(recipe, IMPORT_TOP_REQUIRED, "top level"))

    if recipe.get("importVersion") != 1:
        add([f"importVersion must be 1, got {recipe.get('importVersion')!r}"])
    if recipe.get("format") not in IMPORT_FORMATS:
        add([f"format {recipe.get('format')!r} is not supported (supports {sorted(IMPORT_FORMATS)})"])

    rid = recipe.get("id")
    if not isinstance(rid, str) or not IMPORT_ID_RE.match(rid):
        add([f"id {rid!r} does not match ^[a-z0-9][a-z0-9.-]{{0,47}}$"])

    name = recipe.get("name")
    if not isinstance(name, str) or not (1 <= len(name) <= 80):
        add(["name must be 1-80 characters"])

    content = recipe.get("content")
    if isinstance(content, dict):
        add(_unknown_keys(content, IMPORT_CONTENT_KEYS, "content"))
        add(_missing_keys(content, IMPORT_CONTENT_KEYS, "content"))
        terms = content.get("termsUrl")
        if terms is not None:
            err = validate_import_url(terms, hosts)
            if err:
                add([f"content.termsUrl {err}"])
        for key in ("title", "publisher", "credit"):
            val = content.get(key)
            if not isinstance(val, str) or not (1 <= len(val) <= 400):
                add([f"content.{key} must be 1-400 characters"])
    else:
        add(["content must be an object"])

    sources = recipe.get("sources")
    if isinstance(sources, list) and 1 <= len(sources) <= 4:
        for i, src in enumerate(sources):
            where = f"sources[{i}]"
            if not isinstance(src, dict):
                add([f"{where} must be an object"])
                continue
            add(_unknown_keys(src, IMPORT_SOURCE_KEYS, where))
            add(_missing_keys(src, IMPORT_SOURCE_KEYS, where))
            urls = src.get("urls")
            if isinstance(urls, list) and 1 <= len(urls) <= 4:
                for j, url in enumerate(urls):
                    err = validate_import_url(url, hosts)
                    if err:
                        add([f"{where}.urls[{j}] {err}"])
            else:
                add([f"{where}.urls must have 1-4 entries"])
            file_name = src.get("fileName")
            if not isinstance(file_name, str) or not IMPORT_FILENAME_RE.match(file_name):
                add([f"{where}.fileName must match ^[A-Za-z0-9._ -]{{1,64}}\\.zip$"])
            size = src.get("size")
            if not isinstance(size, int) or isinstance(size, bool) or not (1 <= size <= IMPORT_SIZE_MAX):
                add([f"{where}.size must be an integer from 1 to {IMPORT_SIZE_MAX}"])
            sha = src.get("sha256")
            if not isinstance(sha, str) or not re.match(r"^[0-9a-f]{64}$", sha):
                add([f"{where}.sha256 must be 64 lowercase hex characters"])
    else:
        add(["sources must have 1-4 entries"])

    reader = recipe.get("reader")
    if isinstance(reader, dict):
        add(_unknown_keys(reader, IMPORT_READER_KEYS, "reader"))
        add(_missing_keys(reader, IMPORT_READER_REQUIRED, "reader"))
        if reader.get("type") != "w4-registry":
            add([f"reader.type must be 'w4-registry', got {reader.get('type')!r}"])
        for key in ("root", "registry", "descriptors", "previews"):
            val = reader.get(key)
            if val is not None:
                err = check_import_glob_path(val)
                if err:
                    add([f"reader.{key}: {err}"])
        for key in ("titles", "maps"):
            val = reader.get(key)
            if val is None:
                continue
            if not isinstance(val, list):
                add([f"reader.{key} must be a list"])
                continue
            for i, v in enumerate(val):
                err = check_import_glob_path(v)
                if err:
                    add([f"reader.{key}[{i}]: {err}"])
    else:
        add(["reader must be an object"])

    select = recipe.get("select")
    if isinstance(select, dict):
        add(_unknown_keys(select, IMPORT_SELECT_KEYS, "select"))
        add(_missing_keys(select, IMPORT_SELECT_REQUIRED, "select"))
        lt = select.get("levelType")
        def _lt_ok(v):
            return isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 64
        if not (_lt_ok(lt) or (isinstance(lt, list) and 1 <= len(lt) <= 8 and all(_lt_ok(v) for v in lt))):
            add(["select.levelType must be an integer 0-64 or a list of 1-8 such integers"])
        if select.get("skipKeySuffix") is not None and not isinstance(select["skipKeySuffix"], str):
            add(["select.skipKeySuffix must be a string"])
        require = select.get("require", [])
        if not isinstance(require, list) or not all(isinstance(r, str) for r in require):
            add(["select.require must be a list of strings"])
        exclude = select.get("exclude", [])
        if not isinstance(exclude, list) or len(exclude) > 64 or not all(isinstance(e, str) for e in exclude):
            add(["select.exclude must be a list of at most 64 names"])
        vanilla = select.get("vanilla", [])
        if not isinstance(vanilla, list) or len(vanilla) > 32:
            add(["select.vanilla must be a list of at most 32 entries"])
        elif isinstance(vanilla, list):
            for i, v in enumerate(vanilla):
                where = f"select.vanilla[{i}]"
                if not isinstance(v, dict) or set(v.keys()) != {"file", "sha256"}:
                    add([f"{where} must be an object with exactly 'file' and 'sha256'"])
                    continue
                file_stem = v.get("file")
                if not isinstance(file_stem, str) or not file_stem:
                    add([f"{where}.file must be a non-empty string"])
                    file_stem = None
                hashes = v.get("sha256")
                if not isinstance(hashes, dict) or not hashes:
                    add([f"{where}.sha256 must be a non-empty object"])
                else:
                    for file_path, h in hashes.items():
                        if not isinstance(h, str) or not re.match(r"^[0-9a-f]{64}$", h):
                            add([f"{where}.sha256[{file_path!r}] must be 64 lowercase hex characters"])
                        if file_stem and Path(file_path).stem.lower() != file_stem.lower():
                            add([f"{where}.sha256[{file_path!r}] does not match file stem {file_stem!r}"])
        expect = select.get("expect")
        if not isinstance(expect, dict) or not all(
            isinstance(expect.get(k), int) and not isinstance(expect.get(k), bool)
            for k in ("maps", "fromArchive", "fromGame")
        ):
            add(["select.expect must have integer maps, fromArchive, fromGame"])
        elif expect["maps"] > IMPORT_MAX_TOTAL:
            add([f"select.expect.maps ({expect['maps']}) exceeds the engine cap of {IMPORT_MAX_TOTAL}"])
    else:
        add(["select must be an object"])

    categories = recipe.get("categories")
    if isinstance(categories, list) and 1 <= len(categories) <= 8:
        defaults = 0
        for i, cat in enumerate(categories):
            where = f"categories[{i}]"
            if not isinstance(cat, dict):
                add([f"{where} must be an object"])
                continue
            add(_unknown_keys(cat, IMPORT_CATEGORY_KEYS, where))
            add(_missing_keys(cat, IMPORT_CATEGORY_REQUIRED, where))
            if cat.get("default") is True:
                defaults += 1
        if defaults != 1:
            add([f"categories must have exactly one 'default: true' (found {defaults})"])
    else:
        add(["categories must have 1-8 entries"])

    groups = recipe.get("groups")
    if groups is not None:
        if isinstance(groups, list):
            for i, g in enumerate(groups):
                where = f"groups[{i}]"
                if not isinstance(g, dict):
                    add([f"{where} must be an object"])
                    continue
                add(_unknown_keys(g, IMPORT_GROUP_KEYS, where))
                add(_missing_keys(g, IMPORT_GROUP_REQUIRED, where))
        else:
            add(["groups must be a list"])

    modes = recipe.get("modes")
    if modes is not None and not isinstance(modes, dict):
        add(["modes must be an object"])

    transform = recipe.get("transform")
    if isinstance(transform, dict):
        add(_unknown_keys(transform, IMPORT_TRANSFORM_KEYS, "transform"))
        if transform.get("textures") not in IMPORT_TEXTURES_FORMAT1:
            add([f"transform.textures must be one of {sorted(IMPORT_TEXTURES_FORMAT1)} in format 1"])
        if transform.get("scripts") not in IMPORT_SCRIPTS_FORMAT1:
            add([f"transform.scripts must be one of {sorted(IMPORT_SCRIPTS_FORMAT1)} in format 1"])
        if transform.get("descriptor") not in IMPORT_DESCRIPTOR_FORMAT1:
            add([f"transform.descriptor must be one of {sorted(IMPORT_DESCRIPTOR_FORMAT1)} in format 1"])
    else:
        add(["transform must be an object"])

    output = recipe.get("output")
    if isinstance(output, dict):
        add(_unknown_keys(output, IMPORT_OUTPUT_KEYS, "output"))
        add(_missing_keys(output, IMPORT_OUTPUT_REQUIRED, "output"))
        prefix = output.get("packPrefix")
        if prefix != plugin_id:
            add([f"output.packPrefix {prefix!r} must equal the plugin id {plugin_id!r}"])
        per_pack = output.get("perPack")
        if not isinstance(per_pack, int) or isinstance(per_pack, bool) or not (1 <= per_pack <= IMPORT_MAX_PER_PACK):
            add([f"output.perPack must be an integer from 1 to {IMPORT_MAX_PER_PACK}"])
        version = output.get("version")
        if not isinstance(version, str) or not SEMVER_RE.match(version):
            add(["output.version must be valid semver"])
        order = output.get("order")
        if not isinstance(order, list) or not order:
            add(["output.order must be a non-empty list"])
    else:
        add(["output must be an object"])

    return [f"mod/{recipe_rel}: {m}" for m in raw]


# --------------------------------------------------------------------------
# validate


class Validator:
    def __init__(self, root: Path):
        self.root = root
        self.reserved_ids = load_lines(root / "policy" / "reserved-ids.txt")
        self.exec_allowlist = {
            (e["id"], e["path"], e["sha256"])
            for e in self._load_policy_list("executables.json")
        }
        self.extra_types = {
            (e["id"], e["path"]) for e in self._load_policy_list("extra-types.json")
        }
        self.stock_names = {
            n.lower() for n in load_lines(root / "policy" / "stock-names.txt")
        }
        self.import_hosts = load_import_hosts(root)

    def _load_policy_list(self, name: str) -> list[dict]:
        path = self.root / "policy" / name
        if not path.exists():
            return []
        data = load_json(path)
        return data if isinstance(data, list) else []

    def validate_plugin(self, plugin_id: str) -> list[str]:
        errors: list[str] = []
        plugin_dir = self.root / "plugins" / plugin_id

        if not ID_RE.match(plugin_id):
            errors.append(f"id {plugin_id!r} does not match the spice id pattern")
        if plugin_id in self.reserved_ids:
            errors.append(f"id {plugin_id!r} is reserved")
        else:
            normalized = plugin_id.replace("_", "-")
            for other in all_ids(self.root):
                if other != plugin_id and other.replace("_", "-") == normalized:
                    errors.append(f"id {plugin_id!r} collides with {other!r} (only - / _ differ)")

        store_path = plugin_dir / "store.json"
        spice_path = plugin_dir / "mod" / "spice.json"
        license_path = plugin_dir / "LICENSE"

        if not store_path.exists():
            errors.append("plugins/<id>/store.json is missing")
            return errors
        if not spice_path.exists():
            errors.append("plugins/<id>/mod/spice.json is missing")
            return errors

        try:
            store = load_json(store_path)
        except (OSError, json.JSONDecodeError) as e:
            errors.append(f"store.json: invalid JSON ({e})")
            return errors
        try:
            spice = load_json(spice_path)
        except (OSError, json.JSONDecodeError) as e:
            errors.append(f"mod/spice.json: invalid JSON ({e})")
            return errors

        errors += self._check_store_schema(store)
        errors += self._check_spice(spice, plugin_id)
        errors += self._check_licence(store, license_path)
        errors += self._check_layout_and_sizes(plugin_dir, plugin_id)
        errors += self._check_versions(store.get("versions", []), plugin_id)
        errors += self._check_importer(spice, plugin_dir, plugin_id)

        name = spice.get("name")
        if isinstance(name, str):
            for other_id in all_ids(self.root):
                if other_id == plugin_id:
                    continue
                other_spice = self.root / "plugins" / other_id / "mod" / "spice.json"
                if not other_spice.exists():
                    continue
                try:
                    other_name = load_json(other_spice).get("name")
                except (OSError, json.JSONDecodeError):
                    continue
                if isinstance(other_name, str) and other_name.lower() == name.lower():
                    errors.append(f"name {name!r} duplicates plugin {other_id!r}")

        return errors

    def _check_store_schema(self, store: dict) -> list[str]:
        errors = []
        if store.get("storeVersion") != 1:
            errors.append("store.json: storeVersion must be 1")

        licence = store.get("licence")
        if licence not in LICENCE_ALLOWLIST:
            errors.append(f"store.json: licence {licence!r} is not in the allow-list")

        homepage = store.get("homepage")
        if homepage is not None:
            if not isinstance(homepage, str) or not homepage.startswith("https://"):
                errors.append("store.json: homepage must be an https:// URL")
            elif len(homepage) > MAX_HOMEPAGE_CHARS:
                errors.append("store.json: homepage longer than 200 characters")

        categories = store.get("categories")
        if not isinstance(categories, list) or not (1 <= len(categories) <= 3):
            errors.append("store.json: categories must have 1-3 entries")
        elif not set(categories) <= CATEGORIES:
            errors.append(f"store.json: unknown categories {set(categories) - CATEGORIES}")

        game_builds = store.get("gameBuilds")
        if not isinstance(game_builds, list) or not game_builds:
            errors.append("store.json: gameBuilds must be a non-empty list")
        elif not set(game_builds) <= GAME_BUILDS:
            errors.append(f"store.json: unknown gameBuilds {set(game_builds) - GAME_BUILDS}")

        shots = store.get("screenshots", [])
        if len(shots) > MAX_SCREENSHOTS:
            errors.append("store.json: more than 6 screenshots")
        for shot in shots:
            if not isinstance(shot, dict) or "file" not in shot:
                errors.append(f"store.json: bad screenshot entry {shot!r}")
                continue
            if Path(shot["file"]).suffix.lower() not in (".png", ".jpg", ".jpeg"):
                errors.append(f"store.json: screenshot {shot['file']!r} must be .png/.jpg/.jpeg")
            if len(shot.get("caption", "")) > 120:
                errors.append(f"store.json: screenshot caption for {shot['file']!r} > 120 chars")

        imports = store.get("imports")
        if imports is not None:
            if not isinstance(imports, list) or not (1 <= len(imports) <= 4):
                errors.append("store.json: imports must have 1-4 entries")
            else:
                for i, entry in enumerate(imports):
                    where = f"store.json: imports[{i}]"
                    if not isinstance(entry, dict) or set(entry.keys()) != {
                        "title", "publisher", "host", "size"
                    }:
                        errors.append(f"{where} must be an object with exactly title, publisher, host, size")
                        continue
                    for key in ("title", "publisher"):
                        if not isinstance(entry.get(key), str) or not (1 <= len(entry[key]) <= 400):
                            errors.append(f"{where}.{key} must be 1-400 characters")
                    host = entry.get("host")
                    if not isinstance(host, str) or host not in self.import_hosts:
                        errors.append(f"{where}.host {host!r} is not in policy/import-hosts.json")
                    size = entry.get("size")
                    if not isinstance(size, int) or isinstance(size, bool) or not (1 <= size <= IMPORT_SIZE_MAX):
                        errors.append(f"{where}.size must be an integer from 1 to {IMPORT_SIZE_MAX}")

        extra = set(store.keys()) - {
            "storeVersion", "licence", "homepage", "categories",
            "gameBuilds", "screenshots", "versions", "imports",
        }
        if extra:
            errors.append(f"store.json: unexpected fields {sorted(extra)} (belongs in spice.json)")
        return errors

    def _check_spice(self, spice: dict, plugin_id: str) -> list[str]:
        errors = []
        if spice.get("spiceVersion") != 1:
            errors.append(f"mod/spice.json spiceVersion {spice.get('spiceVersion')!r} must be 1")
        spice_id = spice.get("id")
        if spice_id != plugin_id:
            errors.append(f"mod/spice.json id {spice_id!r} != folder name {plugin_id!r}")
        version = spice.get("version")
        if not isinstance(version, str) or not SEMVER_RE.match(version):
            errors.append(f"mod/spice.json version {version!r} is not valid semver")
        name = spice.get("name")
        if not isinstance(name, str) or not (1 <= len(name) <= MAX_NAME_CHARS):
            errors.append("mod/spice.json name must be 1-80 characters")
        authors = spice.get("authors")
        if not isinstance(authors, list) or not authors:
            errors.append("mod/spice.json authors: the store requires at least one")
        description = spice.get("description", "")
        if not isinstance(description, str) or not (1 <= len(description) <= MAX_DESCRIPTION_CHARS):
            errors.append("mod/spice.json description must be 1-400 characters (store requirement)")
        kind = spice.get("kind")
        if kind not in ("client-only", "content"):
            errors.append(f"mod/spice.json kind {kind!r} must be client-only or content")
        if spice.get("defaultEnabled") not in (None, True):
            errors.append("mod/spice.json defaultEnabled must be absent or true")
        permissions = spice.get("permissions", {})
        if permissions.get("network"):
            errors.append("mod/spice.json permissions.network must be absent or false")
        melange_range = spice.get("melange", {}).get("range")
        if not isinstance(melange_range, str) or not melange_range.strip():
            errors.append("mod/spice.json melange.range is required")
        for setting in spice.get("settings", []) or []:
            if isinstance(setting, dict) and not setting.get("label"):
                errors.append(f"mod/spice.json setting {setting.get('key')!r} is missing a label")
        if "generated" in spice:
            errors.append("mod/spice.json must not declare 'generated' (reserved for importer-generated packs)")
        importer = spice.get("importer")
        if importer is not None and (not isinstance(importer, dict) or set(importer.keys()) != {"recipe"}):
            errors.append("mod/spice.json importer must be an object with exactly one key 'recipe'")
        return errors

    def _check_importer(self, spice: dict, plugin_dir: Path, plugin_id: str) -> list[str]:
        importer = spice.get("importer")
        if not isinstance(importer, dict) or set(importer.keys()) != {"recipe"}:
            return []  # malformed shape is already reported by _check_spice
        recipe_rel = importer.get("recipe")
        path_err = check_import_recipe_path(recipe_rel)
        if path_err:
            return [f"mod/spice.json importer.recipe: {path_err}"]
        recipe_path = plugin_dir / "mod" / recipe_rel
        if not recipe_path.exists():
            return [f"mod/spice.json importer.recipe points to a missing file ({recipe_rel})"]
        try:
            recipe = load_json(recipe_path)
        except (OSError, json.JSONDecodeError) as e:
            return [f"mod/{recipe_rel}: invalid JSON ({e})"]
        return validate_import_recipe(recipe, plugin_id, self.import_hosts, recipe_rel)

    def _check_licence(self, store: dict, license_path: Path) -> list[str]:
        errors = []
        if not license_path.exists():
            errors.append("plugins/<id>/LICENSE is missing")
            return errors
        size = license_path.stat().st_size
        if size == 0:
            errors.append("LICENSE is empty")
        if size > MAX_LICENSE_BYTES:
            errors.append(f"LICENSE is larger than {MAX_LICENSE_BYTES} bytes")
        return errors

    def _check_layout_and_sizes(self, plugin_dir: Path, plugin_id: str) -> list[str]:
        errors = []
        mod_dir = plugin_dir / "mod"
        if not mod_dir.is_dir():
            errors.append("plugins/<id>/mod/ is missing")
            return errors

        entries: list[str] = []
        total_size = 0
        file_count = 0
        for path in sorted(mod_dir.rglob("*")):
            if path.is_dir():
                continue
            if path.is_symlink() or stat.S_ISLNK(path.lstat().st_mode):
                errors.append(f"{path.relative_to(plugin_dir)}: symlinks are not allowed")
                continue
            rel = path.relative_to(mod_dir).as_posix()
            entries.append(f"{plugin_id}/{rel}")
            size = path.stat().st_size
            total_size += size
            file_count += 1
            if size > MAX_FILE_BYTES:
                errors.append(f"{rel}: larger than {MAX_FILE_BYTES} bytes")
            errors += self._check_executable_and_type(plugin_id, rel, path)

        entries.append(f"{plugin_id}/LICENSE")
        errors += check_layout(plugin_id, entries)

        if total_size > MAX_SOURCE_BYTES:
            errors.append(f"mod/ is larger than {MAX_SOURCE_BYTES} bytes in total")
        if file_count > MAX_FILE_COUNT:
            errors.append(f"mod/ has more than {MAX_FILE_COUNT} files")
        return errors

    def _check_executable_and_type(self, plugin_id: str, rel: str, path: Path) -> list[str]:
        errors = []
        ext = path.suffix.lower()
        with path.open("rb") as f:
            head = f.read(4)
        is_exec = is_executable_name(rel) or is_executable_magic(head)
        if is_exec:
            file_hash = sha256_file(path)
            if (plugin_id, rel, file_hash) not in self.exec_allowlist:
                errors.append(f"{rel}: looks like an executable and is not in policy/executables.json")
        elif ext not in FILE_TYPE_EXTENSIONS and path.name != "LICENSE":
            if (plugin_id, rel) not in self.extra_types:
                errors.append(f"{rel}: file type {ext or '(none)'!r} is not allowed")
        if path.name.lower() in self.stock_names:
            errors.append(f"{rel}: name matches a stock game file (policy/stock-names.txt)")
        return errors

    def _check_versions(self, versions: list, plugin_id: str) -> list[str]:
        errors = []
        if not isinstance(versions, list):
            return [f"{plugin_id}: versions must be a list"]
        if len(versions) > INDEX_MAX_VERSIONS:
            errors.append(f"{plugin_id}: more than {INDEX_MAX_VERSIONS} versions")
        prev = None
        for v in versions:
            url = v.get("url", "")
            expected_prefix = (
                f"https://github.com/JaminB/melange-plugins/releases/download/"
                f"{plugin_id}-v{v.get('version')}/{plugin_id}-{v.get('version')}.zip"
            )
            if url != expected_prefix:
                errors.append(f"{plugin_id} {v.get('version')}: url does not match the fixed form")
            sha = v.get("sha256", "")
            if not re.match(r"^[0-9a-f]{64}$", sha or ""):
                errors.append(f"{plugin_id} {v.get('version')}: sha256 must be 64 lower-case hex chars")
            for field in ("size", "unpackedSize", "files"):
                if not isinstance(v.get(field), int) or v.get(field) <= 0:
                    errors.append(f"{plugin_id} {v.get('version')}: {field} must be a positive integer")
            if len(v.get("changelog", "")) > MAX_CHANGELOG_CHARS:
                errors.append(f"{plugin_id} {v.get('version')}: changelog longer than 2000 characters")
            ver = v.get("version")
            if prev is not None and ver is not None and not _semver_lt(ver, prev):
                errors.append(f"{plugin_id}: versions[] must be strictly descending ({prev} then {ver})")
            prev = ver if ver is not None else prev
        return errors


def _semver_key(v: str) -> tuple:
    m = SEMVER_RE.match(v)
    if not m:
        return (0, 0, 0)
    return tuple(int(x) for x in m.groups()[:3])


def _semver_lt(a: str, b: str) -> bool:
    return _semver_key(a) < _semver_key(b)


def cmd_validate(args) -> int:
    root = Path(args.root).resolve()
    v = Validator(root)
    if not args.all and not args.ids:
        print("pass plugin ids, or --all", file=sys.stderr)
        return 2
    ids = all_ids(root) if args.all else args.ids
    if not ids:
        print("no plugins to validate")
        return 0
    ok = True
    for plugin_id in ids:
        errors = v.validate_plugin(plugin_id)
        if errors:
            ok = False
            print(f"FAIL {plugin_id}")
            for e in errors:
                print(f"  - {e}")
        else:
            print(f"ok   {plugin_id}")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# pack


def newest_changelog_version(changelog_path: Path) -> str | None:
    if not changelog_path.exists():
        return None
    for line in changelog_path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^##\s+(\S+)", line.strip())
        if m:
            return m.group(1)
    return None


def pack_plugin(root: Path, plugin_id: str, out_dir: Path) -> dict:
    plugin_dir = root / "plugins" / plugin_id
    mod_dir = plugin_dir / "mod"
    spice = load_json(mod_dir / "spice.json")
    version = spice["version"]

    files: list[tuple[str, Path]] = []
    for path in sorted(mod_dir.rglob("*")):
        if path.is_file():
            rel = path.relative_to(mod_dir).as_posix()
            files.append((f"{plugin_id}/{rel}", path))
    files.append((f"{plugin_id}/LICENSE", plugin_dir / "LICENSE"))
    files.sort(key=lambda t: t[0])

    errors = check_layout(plugin_id, [name for name, _ in files])
    if errors:
        raise SystemExit("pack: layout errors:\n" + "\n".join(f"  - {e}" for e in errors))

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{plugin_id}-{version}.zip"
    unpacked_size = 0
    with zipfile.ZipFile(out_path, "w") as zf:
        for name, src in files:
            data = src.read_bytes()
            unpacked_size += len(data)
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (0o100644 << 16)
            info.flag_bits |= 0x800
            zf.writestr(info, data, compresslevel=9)

    size = out_path.stat().st_size
    sha256 = sha256_file(out_path)
    facts = {
        "id": plugin_id,
        "version": version,
        "url": (
            f"https://github.com/JaminB/melange-plugins/releases/download/"
            f"{plugin_id}-v{version}/{plugin_id}-{version}.zip"
        ),
        "sha256": sha256,
        "size": size,
        "unpackedSize": unpacked_size,
        "files": len(files),
    }
    return facts


def cmd_pack(args) -> int:
    root = Path(args.root).resolve()
    facts = pack_plugin(root, args.id, Path(args.out))
    print(json.dumps(facts, indent=2))
    if facts["size"] > MAX_PACKED_BYTES:
        print(f"error: packed zip is larger than {MAX_PACKED_BYTES} bytes", file=sys.stderr)
        return 1
    return 0


# --------------------------------------------------------------------------
# index


def build_index(root: Path) -> dict:
    plugins_out = []
    for plugin_id in all_ids(root):
        plugin_dir = root / "plugins" / plugin_id
        store_path = plugin_dir / "store.json"
        spice_path = plugin_dir / "mod" / "spice.json"
        if not store_path.exists() or not spice_path.exists():
            continue
        store = load_json(store_path)
        versions = store.get("versions") or []
        if not versions:
            continue
        spice = load_json(spice_path)

        shots_out = []
        for shot in store.get("screenshots", []):
            shot_path = plugin_dir / "screenshots" / shot["file"]
            if not shot_path.exists():
                continue
            entry = {
                "path": f"plugins/{plugin_id}/screenshots/{shot['file']}",
                "sha256": sha256_file(shot_path),
                "size": shot_path.stat().st_size,
            }
            if shot.get("caption"):
                entry["caption"] = shot["caption"]
            shots_out.append(entry)

        plugins_out.append({
            "id": plugin_id,
            "name": spice.get("name"),
            "authors": spice.get("authors", []),
            "description": spice.get("description", ""),
            **({"homepage": store["homepage"]} if store.get("homepage") else (
                {"homepage": spice["website"]} if spice.get("website") else {}
            )),
            "licence": store.get("licence"),
            "categories": store.get("categories", []),
            "gameBuilds": store.get("gameBuilds", []),
            "screenshots": shots_out,
            "versions": versions,
            **({"imports": store["imports"]} if store.get("imports") else {}),
        })

    plugins_out.sort(key=lambda p: p["id"])
    return {"indexVersion": 1, "serial": 0, "plugins": plugins_out}


def _index_without_serial(index: dict) -> dict:
    return {k: v for k, v in index.items() if k != "serial"}


def render_index(index: dict) -> str:
    return json.dumps(index, indent=2, ensure_ascii=False) + "\n"


def cmd_index(args) -> int:
    root = Path(args.root).resolve()
    new_index = build_index(root)
    index_path = root / "index.json"

    previous_serial = 0
    previous_body = None
    if index_path.exists():
        try:
            previous = load_json(index_path)
            previous_serial = previous.get("serial", 0)
            previous_body = _index_without_serial(previous)
        except (OSError, json.JSONDecodeError):
            pass

    new_index["serial"] = (
        previous_serial
        if previous_body == _index_without_serial(new_index) and index_path.exists()
        else previous_serial + 1
    )
    rendered = render_index(new_index)

    if len(new_index["plugins"]) > INDEX_MAX_PLUGINS:
        print(f"error: {len(new_index['plugins'])} plugins exceeds cap {INDEX_MAX_PLUGINS}", file=sys.stderr)
        return 1
    if len(rendered.encode("utf-8")) > INDEX_MAX_BYTES:
        print(f"error: index.json exceeds {INDEX_MAX_BYTES} bytes", file=sys.stderr)
        return 1
    for p in new_index["plugins"]:
        if len(p["versions"]) > INDEX_MAX_VERSIONS:
            print(f"error: {p['id']} has more than {INDEX_MAX_VERSIONS} versions", file=sys.stderr)
            return 1

    if args.check:
        if not index_path.exists():
            print("error: index.json does not exist", file=sys.stderr)
            return 1
        current = index_path.read_text(encoding="utf-8")
        if current != rendered:
            print("error: index.json is stale; run `store.py index` and commit the result", file=sys.stderr)
            return 1
        print("index.json is up to date")
        return 0

    with index_path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(rendered)
    print(f"wrote {index_path} (serial {new_index['serial']}, {len(new_index['plugins'])} plugins)")
    return 0


# --------------------------------------------------------------------------
# verify-release


def verify_release(zip_path: Path, plugin_id: str, version: str, sha256: str, size: int) -> list[str]:
    errors = []
    actual_size = zip_path.stat().st_size
    if actual_size != size:
        errors.append(f"size mismatch: expected {size}, got {actual_size}")
    actual_sha = sha256_file(zip_path)
    if actual_sha != sha256:
        errors.append(f"sha256 mismatch: expected {sha256}, got {actual_sha}")
    if errors:
        return errors
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        errors += check_layout(plugin_id, names)
        for info in zf.infolist():
            if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                errors.append(f"{info.filename}: unsupported compression method {info.compress_type}")
            if info.flag_bits & 0x1:
                errors.append(f"{info.filename}: entry is encrypted")
        try:
            spice_bytes = zf.read(f"{plugin_id}/spice.json")
        except KeyError:
            errors.append("zip does not contain <id>/spice.json")
        else:
            spice = json.loads(spice_bytes)
            if spice.get("version") != version:
                errors.append(f"spice.json version {spice.get('version')!r} != release version {version!r}")
    return errors


def cmd_verify_release(args) -> int:
    if args.changed:
        return verify_changed_versions(Path(args.root).resolve(), args.base)
    if not (args.zip and args.id and args.version and args.sha256 and args.size):
        print("verify-release: pass ZIP --id --version --sha256 --size, or --changed", file=sys.stderr)
        return 2
    errors = verify_release(Path(args.zip), args.id, args.version, args.sha256, args.size)
    if errors:
        for e in errors:
            print(f"FAIL: {e}")
        return 1
    print("ok")
    return 0


def _base_versions(root: Path, base_ref: str, plugin_id: str) -> list[dict]:
    import subprocess
    try:
        out = subprocess.run(
            ["git", "show", f"{base_ref}:plugins/{plugin_id}/store.json"],
            cwd=root, capture_output=True, text=True, check=True,
        ).stdout
        return json.loads(out).get("versions", [])
    except Exception:
        return []


def verify_changed_versions(root: Path, base_ref: str) -> int:
    """CI: download and re-check every versions[] entry newly added versus `base_ref`."""
    import tempfile
    import urllib.request

    ok = True
    for plugin_id in all_ids(root):
        store_path = root / "plugins" / plugin_id / "store.json"
        if not store_path.exists():
            continue
        current = load_json(store_path).get("versions", [])
        base = {v["version"] for v in _base_versions(root, base_ref, plugin_id)}
        new_entries = [v for v in current if v.get("version") not in base]
        for entry in new_entries:
            print(f"verifying {plugin_id} {entry.get('version')} ...")
            with tempfile.TemporaryDirectory() as tmp:
                dest = Path(tmp) / "asset.zip"
                try:
                    with urllib.request.urlopen(entry["url"], timeout=120) as resp:
                        if resp.status != 200:
                            raise RuntimeError(f"HTTP {resp.status}")
                        data = resp.read(MAX_PACKED_BYTES + 1)
                        if len(data) > MAX_PACKED_BYTES:
                            raise RuntimeError(f"asset larger than {MAX_PACKED_BYTES} bytes")
                        dest.write_bytes(data)
                except Exception as e:
                    print(f"  FAIL: could not download {entry.get('url')}: {e}")
                    ok = False
                    continue
                errors = verify_release(
                    dest, plugin_id, entry["version"], entry["sha256"], entry["size"]
                )
                if errors:
                    ok = False
                    for e in errors:
                        print(f"  FAIL: {e}")
                else:
                    print("  ok")
    return 0 if ok else 1


# --------------------------------------------------------------------------


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(ROOT), help="repo root (default: this script's parent)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_validate = sub.add_parser("validate", help="run the store checks")
    p_validate.add_argument("ids", nargs="*", help="plugin ids, e.g. plugins/<id>")
    p_validate.add_argument("--all", action="store_true", help="validate every plugin in plugins/")
    p_validate.set_defaults(func=cmd_validate)

    p_pack = sub.add_parser("pack", help="build the release zip")
    p_pack.add_argument("id")
    p_pack.add_argument("--out", default="dist")
    p_pack.set_defaults(func=cmd_pack)

    p_index = sub.add_parser("index", help="(re)generate index.json")
    p_index.add_argument("--check", action="store_true")
    p_index.set_defaults(func=cmd_index)

    p_verify = sub.add_parser("verify-release", help="verify a built/downloaded zip")
    p_verify.add_argument("zip", nargs="?")
    p_verify.add_argument("--id")
    p_verify.add_argument("--version")
    p_verify.add_argument("--sha256")
    p_verify.add_argument("--size", type=int)
    p_verify.add_argument("--changed", action="store_true", help="CI mode: verify every newly-added versions[] entry")
    p_verify.add_argument("--base", default="origin/main", help="git ref to diff against with --changed")
    p_verify.set_defaults(func=cmd_verify_release)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
