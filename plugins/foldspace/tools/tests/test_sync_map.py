#!/usr/bin/env python3
"""Tests for sync_map.py's renames and its offline check of the committed plugin. Stdlib only.

  python plugins/foldspace/tools/tests/test_sync_map.py -v
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import sync_map  # noqa: E402


class Renames(unittest.TestCase):
    def test_mesh_name(self):
        self.assertEqual(sync_map.mesh_name("caldera", "caldera", "caldera.BoulderDark"), "foldspace.caldera_BoulderDark")
        self.assertEqual(sync_map.mesh_name("isle", "erg1", "erg1.Rock"), "foldspace.isle_Rock")
        with self.assertRaises(SystemExit):
            sync_map.mesh_name("caldera", "caldera", "other.Boulder")

    def test_patch_rewrite_whole_strings_only(self):
        patch = json.dumps({
            "format": "erg-patch/2", "stem": "caldera_caldera", "title": "Caldera",
            "ops": [{"op": "add", "detail": {"resource": "caldera.Boulder"}},
                    {"op": "add", "detail": {"resource": "caldera.BoulderDark"}},
                    {"op": "add", "detail": {"name": "caldera.Boulder is here", "resource": "Rock01"}}],
        })
        out = json.loads(sync_map.rewrite_patch(patch, "caldera", "caldera", ["caldera.Boulder", "caldera.BoulderDark"]))
        self.assertEqual(out["stem"], "foldspace_caldera")
        self.assertEqual([o["detail"].get("resource") for o in out["ops"]],
                         ["foldspace.caldera_Boulder", "foldspace.caldera_BoulderDark", "Rock01"])
        self.assertEqual(out["ops"][2]["detail"]["name"], "caldera.Boulder is here")

    def test_patch_naming_an_unshipped_mesh_is_refused(self):
        patch = json.dumps({"stem": "caldera_caldera", "ops": [{"detail": {"resource": "caldera.Ledge"}}]})
        with self.assertRaises(SystemExit):
            sync_map.rewrite_patch(patch, "caldera", "caldera", ["caldera.Boulder"])

    def test_patch_with_another_stem_is_refused(self):
        with self.assertRaises(SystemExit):
            sync_map.rewrite_patch(json.dumps({"stem": "caldera_other"}), "caldera", "caldera", [])

    def test_bank_rename(self):
        doc = json.dumps({"a": "caldera.Boulder", "b": ["caldera.Boulder_group_0"], "c": "caldera.BoulderDark2x"})
        with self.assertRaises(SystemExit):  # another caldera.* name left in the bank
            sync_map.rename_bank_json(doc, "caldera", "caldera", "caldera.Boulder")
        doc = json.dumps({"a": "caldera.Boulder", "b": ["caldera.Boulder_group_0"], "c": "Rock"})
        out = json.loads(sync_map.rename_bank_json(doc, "caldera", "caldera", "caldera.Boulder"))
        self.assertEqual(out, {"a": "foldspace.caldera_Boulder", "b": ["foldspace.caldera_Boulder_group_0"], "c": "Rock"})

    def test_spice_with_keeps_other_maps(self):
        spice = {"id": "foldspace", "melange": {"range": ">=0.14.0"},
                 "levels": [{"slug": "isle", "source": "maps/isle/isle.ergpatch.json"},
                            {"slug": "caldera", "source": "old"}],
                 "meshes": [{"file": "assets/meshes/isle/foldspace.isle_A.xom"},
                            {"file": "assets/meshes/caldera/foldspace.caldera_Gone.xom"}]}
        files = {"maps/caldera/caldera.ergpatch.json": b"", "assets/meshes/caldera/foldspace.caldera_B.xom": b""}
        out = sync_map.spice_with(spice, "caldera", {"slug": "caldera", "source": "maps/caldera/caldera.ergpatch.json"}, files)
        self.assertEqual([lv["slug"] for lv in out["levels"]], ["caldera", "isle"])
        self.assertEqual([m["file"] for m in out["meshes"]],
                         ["assets/meshes/caldera/foldspace.caldera_B.xom", "assets/meshes/isle/foldspace.isle_A.xom"])
        self.assertEqual(out["melange"], {"range": ">=0.14.0"})

    def test_range_floor(self):
        self.assertEqual(sync_map.range_floor(">=0.14.0"), (0, 14, 0))
        with self.assertRaises(SystemExit):
            sync_map.range_floor(">=0.14.0 <0.15.0")


class Committed(unittest.TestCase):
    def test_committed_plugin_verifies(self):
        self.assertEqual(sync_map.verify(), [])


if __name__ == "__main__":
    unittest.main()
