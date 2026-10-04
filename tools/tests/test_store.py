import json
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import store  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / "tests" / "fixtures"


def make_repo(tmp_dir: Path, fixture_name: str, plugin_id: str | None = None) -> Path:
    """A throwaway repo root: real policy/schema + one fixture under plugins/<id>."""
    root = tmp_dir / "repo"
    (root / "plugins").mkdir(parents=True)
    shutil.copytree(REPO_ROOT / "policy", root / "policy")
    shutil.copytree(REPO_ROOT / "schema", root / "schema")
    plugin_id = plugin_id or fixture_name
    shutil.copytree(FIXTURES / fixture_name, root / "plugins" / plugin_id)
    return root


class ValidateGoodPlugin(unittest.TestCase):
    def test_sample_plugin_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin")
            errors = store.Validator(root).validate_plugin("sample-plugin")
            self.assertEqual(errors, [])


class ValidateMissingLicence(unittest.TestCase):
    def test_missing_licence_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "bad-missing-licence")
            errors = store.Validator(root).validate_plugin("bad-missing-licence")
            self.assertTrue(any("LICENSE is missing" in e for e in errors), errors)


class ValidateSpiceVersion(unittest.TestCase):
    def test_missing_spice_version_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin")
            spice_path = root / "plugins" / "sample-plugin" / "mod" / "spice.json"
            spice = json.loads(spice_path.read_text(encoding="utf-8"))
            del spice["spiceVersion"]
            spice_path.write_text(json.dumps(spice), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-plugin")
            self.assertTrue(any("spiceVersion" in e for e in errors), errors)

    def test_wrong_spice_version_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin")
            spice_path = root / "plugins" / "sample-plugin" / "mod" / "spice.json"
            spice = json.loads(spice_path.read_text(encoding="utf-8"))
            spice["spiceVersion"] = 2
            spice_path.write_text(json.dumps(spice), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-plugin")
            self.assertTrue(any("spiceVersion" in e for e in errors), errors)


class ValidateOversize(unittest.TestCase):
    def test_oversize_file_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin")
            with mock.patch.object(store, "MAX_FILE_BYTES", 4):
                errors = store.Validator(root).validate_plugin("sample-plugin")
            self.assertTrue(any("larger than 4 bytes" in e for e in errors), errors)

    def test_oversize_total_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin")
            with mock.patch.object(store, "MAX_SOURCE_BYTES", 4):
                errors = store.Validator(root).validate_plugin("sample-plugin")
            self.assertTrue(any("larger than 4 bytes in total" in e for e in errors), errors)


class FileTypeRules(unittest.TestCase):
    def test_ini_file_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin")
            (root / "plugins" / "sample-plugin" / "mod" / "effect.ini").write_text("[effect]\n", encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-plugin")
            self.assertEqual(errors, [])

    def test_unknown_extension_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin")
            (root / "plugins" / "sample-plugin" / "mod" / "notes.xyz").write_text("hi", encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-plugin")
            self.assertTrue(any("file type" in e and ".xyz" in e for e in errors), errors)


class LayoutRules(unittest.TestCase):
    def test_good_layout_passes(self):
        errors = store.check_layout("sample-plugin", [
            "sample-plugin/spice.json",
            "sample-plugin/client/init.lua",
            "sample-plugin/LICENSE",
        ])
        self.assertEqual(errors, [])

    def test_traversal_path_fails(self):
        errors = store.check_layout("sample-plugin", [
            "sample-plugin/spice.json",
            "sample-plugin/../../evil.txt",
        ])
        self.assertTrue(any("'..' segment" in e for e in errors), errors)

    def test_absolute_path_fails(self):
        errors = store.check_layout("sample-plugin", ["/etc/passwd"])
        self.assertTrue(errors)

    def test_backslash_path_fails(self):
        errors = store.check_layout("sample-plugin", ["sample-plugin\\evil.exe"])
        self.assertTrue(any("backslash" in e for e in errors), errors)

    def test_wrong_top_folder_fails(self):
        errors = store.check_layout("sample-plugin", ["other-id/spice.json"])
        self.assertTrue(any("not under top folder" in e for e in errors), errors)

    def test_two_top_folders_fails(self):
        errors = store.check_layout("sample-plugin", [
            "sample-plugin/spice.json",
            "extra/evil.txt",
        ])
        self.assertTrue(any("more than one top-level folder" in e for e in errors)
                         or any("not under top folder" in e for e in errors), errors)

    def test_reserved_user_path_fails(self):
        errors = store.check_layout("sample-plugin", ["sample-plugin/user/save.dat"])
        self.assertTrue(any("reserved path" in e for e in errors), errors)

    def test_case_insensitive_duplicate_fails(self):
        errors = store.check_layout("sample-plugin", [
            "sample-plugin/Init.lua",
            "sample-plugin/init.lua",
        ])
        self.assertTrue(any("duplicates" in e for e in errors), errors)

    def test_device_name_fails(self):
        errors = store.check_layout("sample-plugin", ["sample-plugin/CON.txt"])
        self.assertTrue(any("device name" in e for e in errors), errors)


class PackAndVerify(unittest.TestCase):
    def test_pack_then_verify_release_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            root = make_repo(tmp, "sample-plugin")
            out_dir = tmp / "dist"
            facts = store.pack_plugin(root, "sample-plugin", out_dir)
            zip_path = out_dir / "sample-plugin-1.0.0.zip"
            self.assertTrue(zip_path.exists())
            self.assertEqual(facts["id"], "sample-plugin")
            errors = store.verify_release(
                zip_path, "sample-plugin", "1.0.0", facts["sha256"], facts["size"]
            )
            self.assertEqual(errors, [])

    def test_bad_hash_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            root = make_repo(tmp, "sample-plugin")
            out_dir = tmp / "dist"
            facts = store.pack_plugin(root, "sample-plugin", out_dir)
            zip_path = out_dir / "sample-plugin-1.0.0.zip"
            wrong_hash = "0" * 64
            errors = store.verify_release(
                zip_path, "sample-plugin", "1.0.0", wrong_hash, facts["size"]
            )
            self.assertTrue(any("sha256 mismatch" in e for e in errors), errors)

    def test_bad_size_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            root = make_repo(tmp, "sample-plugin")
            out_dir = tmp / "dist"
            facts = store.pack_plugin(root, "sample-plugin", out_dir)
            zip_path = out_dir / "sample-plugin-1.0.0.zip"
            errors = store.verify_release(
                zip_path, "sample-plugin", "1.0.0", facts["sha256"], facts["size"] + 1
            )
            self.assertTrue(any("size mismatch" in e for e in errors), errors)

    def test_pack_sets_regular_file_unix_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            root = make_repo(tmp, "sample-plugin")
            out_dir = tmp / "dist"
            store.pack_plugin(root, "sample-plugin", out_dir)
            zip_path = out_dir / "sample-plugin-1.0.0.zip"
            with zipfile.ZipFile(zip_path) as zf:
                self.assertTrue(zf.infolist())
                for info in zf.infolist():
                    mode = info.external_attr >> 16
                    self.assertTrue(stat.S_ISREG(mode), (info.filename, oct(mode)))
                    self.assertEqual(mode & 0o777, 0o644)


class IndexGeneration(unittest.TestCase):
    def test_index_omits_plugin_with_no_versions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin")
            index = store.build_index(root)
            self.assertEqual(index["plugins"], [])

    def test_index_includes_released_version_and_is_deterministic(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            root = make_repo(tmp, "sample-plugin")
            store_json_path = root / "plugins" / "sample-plugin" / "store.json"
            store_json = json.loads(store_json_path.read_text(encoding="utf-8"))
            store_json["versions"] = [{
                "version": "1.0.0",
                "released": "2026-10-20",
                "melange": ">=0.9.0 <0.10.0",
                "kind": "client-only",
                "permissions": {"unsafe": False, "filesystem": "none"},
                "dependencies": [],
                "conflicts": [],
                "url": (
                    "https://github.com/JaminB/melange-plugins/releases/download/"
                    "sample-plugin-v1.0.0/sample-plugin-1.0.0.zip"
                ),
                "sha256": "a" * 64,
                "size": 100,
                "unpackedSize": 200,
                "files": 2,
                "changelog": "First release.",
            }]
            store_json_path.write_text(json.dumps(store_json), encoding="utf-8")

            index1 = store.build_index(root)
            index2 = store.build_index(root)
            self.assertEqual(index1["plugins"], index2["plugins"])
            self.assertEqual(len(index1["plugins"]), 1)
            self.assertEqual(index1["plugins"][0]["id"], "sample-plugin")

    def test_index_check_detects_staleness(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            root = make_repo(tmp, "sample-plugin")
            (root / "index.json").write_text('{"indexVersion": 1, "serial": 0, "plugins": []}\n', encoding="utf-8")
            rendered = store.render_index(store.build_index(root) | {"serial": 1})
            self.assertNotEqual((root / "index.json").read_text(encoding="utf-8"), rendered)


class ReservedAndNaming(unittest.TestCase):
    def test_reserved_id_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-plugin", plugin_id="store")
            spice_path = root / "plugins" / "store" / "mod" / "spice.json"
            spice = json.loads(spice_path.read_text(encoding="utf-8"))
            spice["id"] = "store"
            spice_path.write_text(json.dumps(spice), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("store")
            self.assertTrue(any("reserved" in e for e in errors), errors)

    def test_dash_underscore_twin_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            root = make_repo(tmp, "sample-plugin", plugin_id="hd-water")
            spice_path = root / "plugins" / "hd-water" / "mod" / "spice.json"
            spice = json.loads(spice_path.read_text(encoding="utf-8"))
            spice["id"] = "hd-water"
            spice_path.write_text(json.dumps(spice), encoding="utf-8")

            twin_dir = root / "plugins" / "hd_water"
            shutil.copytree(root / "plugins" / "hd-water", twin_dir)
            twin_spice_path = twin_dir / "mod" / "spice.json"
            twin_spice = json.loads(twin_spice_path.read_text(encoding="utf-8"))
            twin_spice["id"] = "hd_water"
            twin_spice_path.write_text(json.dumps(twin_spice), encoding="utf-8")

            errors = store.Validator(root).validate_plugin("hd-water")
            self.assertTrue(any("collides with" in e for e in errors), errors)


class ImporterRecipe(unittest.TestCase):
    def _load_recipe(self, tmp):
        root = make_repo(Path(tmp), "sample-importer")
        recipe_path = root / "plugins" / "sample-importer" / "mod" / "import.json"
        recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
        return root, recipe_path, recipe

    def test_valid_recipe_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-importer")
            errors = store.Validator(root).validate_plugin("sample-importer")
            self.assertEqual(errors, [])

    def test_http_url_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, recipe_path, recipe = self._load_recipe(tmp)
            recipe["sources"][0]["urls"] = ["http://mod.worms.pro/resources/sample.zip"]
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-importer")
            self.assertTrue(any("must be https://" in e for e in errors), errors)

    def test_unknown_host_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, recipe_path, recipe = self._load_recipe(tmp)
            recipe["sources"][0]["urls"] = ["https://evil.example/sample.zip"]
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-importer")
            self.assertTrue(any("is not in policy/import-hosts.json" in e for e in errors), errors)

    def test_bad_sha_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, recipe_path, recipe = self._load_recipe(tmp)
            recipe["sources"][0]["sha256"] = "not-hex"
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-importer")
            self.assertTrue(any("sha256 must be 64 lowercase hex" in e for e in errors), errors)

    def test_unknown_key_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, recipe_path, recipe = self._load_recipe(tmp)
            recipe["bogus"] = True
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-importer")
            self.assertTrue(any("unexpected key 'bogus'" in e for e in errors), errors)

    def test_prefix_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, recipe_path, recipe = self._load_recipe(tmp)
            recipe["output"]["packPrefix"] = "other"
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-importer")
            self.assertTrue(
                any("packPrefix" in e and "must equal the plugin id" in e for e in errors), errors
            )

    def test_generated_key_in_spice_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-importer")
            spice_path = root / "plugins" / "sample-importer" / "mod" / "spice.json"
            spice = json.loads(spice_path.read_text(encoding="utf-8"))
            spice["generated"] = {"by": "sample-importer", "recipe": "x", "format": 1}
            spice_path.write_text(json.dumps(spice), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-importer")
            self.assertTrue(any("must not declare 'generated'" in e for e in errors), errors)

    def test_reserved_generated_pack_id_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_repo(Path(tmp), "sample-importer", plugin_id="caravan-1")
            spice_path = root / "plugins" / "caravan-1" / "mod" / "spice.json"
            spice = json.loads(spice_path.read_text(encoding="utf-8"))
            spice["id"] = "caravan-1"
            spice_path.write_text(json.dumps(spice), encoding="utf-8")
            recipe_path = root / "plugins" / "caravan-1" / "mod" / "import.json"
            recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
            recipe["output"]["packPrefix"] = "caravan-1"
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("caravan-1")
            self.assertTrue(any("reserved" in e for e in errors), errors)

    def test_expect_maps_over_cap_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, recipe_path, recipe = self._load_recipe(tmp)
            recipe["select"]["expect"]["maps"] = 257
            recipe_path.write_text(json.dumps(recipe), encoding="utf-8")
            errors = store.Validator(root).validate_plugin("sample-importer")
            self.assertTrue(any("exceeds the engine cap of 256" in e for e in errors), errors)

    def test_caravan_plugin_recipe_is_valid(self):
        """The real Caravan recipe, validated against the repo's own policy/schema."""
        root = Path(__file__).resolve().parents[2]
        errors = store.Validator(root).validate_plugin("caravan")
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
