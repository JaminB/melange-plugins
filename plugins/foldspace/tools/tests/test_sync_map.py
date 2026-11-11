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

    def test_bank_rename_one_mesh(self):
        doc = json.dumps({"a": "caldera.Boulder", "b": ["caldera.Boulder_group_0"], "c": "caldera.BoulderDark2x"})
        with self.assertRaises(SystemExit):  # another caldera.* name left in the bank
            sync_map.rename_bank_json(doc, "caldera", "caldera", "caldera.Boulder")
        doc = json.dumps({"a": "caldera.Boulder", "b": ["caldera.Boulder_group_0"], "c": "Rock"})
        out = json.loads(sync_map.rename_bank_json(doc, "caldera", "caldera", "caldera.Boulder"))
        self.assertEqual(out, {"a": "foldspace.caldera_Boulder", "b": ["foldspace.caldera_Boulder_group_0"], "c": "Rock"})

    def test_bank_rename_many_meshes(self):
        doc = json.dumps({"a": "caldera.Boulder", "b": "caldera.BoulderDark", "c": ["caldera.BoulderDark_group_0",
                          "caldera.Boulder_group_0"], "d": "Rock"})
        out = json.loads(sync_map.rename_bank_json(doc, "caldera", "caldera", ["caldera.Boulder", "caldera.BoulderDark"]))
        self.assertEqual(out, {"a": "foldspace.caldera_Boulder", "b": "foldspace.caldera_BoulderDark",
                               "c": ["foldspace.caldera_BoulderDark_group_0", "foldspace.caldera_Boulder_group_0"], "d": "Rock"})
        with self.assertRaises(SystemExit):  # a caldera.* mesh the bank does not declare
            sync_map.rename_bank_json(doc, "caldera", "caldera", ["caldera.Boulder"])

    def test_bank_mesh_names_come_from_the_descriptors(self):
        bank = {"objects": [{"type": "XInteriorNode", "fields": {"Name": "caldera.Decoy"}},
                            {"type": "XMeshDescriptor", "fields": {"ResourceId": "caldera.A"}},
                            {"type": "XMeshDescriptor", "fields": {"ResourceId": "caldera.B"}}]}
        self.assertEqual(sync_map.bank_mesh_names(bank), ["caldera.A", "caldera.B"])
        with self.assertRaises(SystemExit):
            sync_map.bank_mesh_names({"objects": []})

    def test_bank_file_name(self):
        f = sync_map.bank_file_name
        # one bank holding many meshes
        self.assertEqual(f("caldera", "caldera", "caldera.Rocks", ["caldera.A", "caldera.B"], 1), "foldspace.caldera")
        # old layout: one mesh per bank, named after it
        self.assertEqual(f("caldera", "caldera", "caldera.Boulder", ["caldera.Boulder"], 8), "foldspace.caldera_Boulder")
        self.assertEqual(f("caldera", "caldera", "caldera.Boulder", ["caldera.Boulder"], 1), "foldspace.caldera_Boulder")
        # two many-mesh banks stay apart
        self.assertEqual(f("caldera", "caldera", "caldera.Rocks", ["caldera.A", "caldera.B"], 2), "foldspace.caldera_Rocks")

    def test_spice_with_keeps_other_maps(self):
        spice = {"id": "foldspace", "melange": {"range": ">=0.14.0"},
                 "levels": [{"slug": "isle", "source": "maps/isle/isle.ergpatch.json"},
                            {"slug": "caldera", "source": "old"}],
                 "meshes": [{"file": "assets/meshes/isle/foldspace.isle_A.xom"},
                            {"file": "assets/meshes/caldera/foldspace.caldera_Gone.xom"}]}
        files = {"maps/caldera/caldera.ergpatch.json": b"", "assets/meshes/caldera/foldspace.caldera_B.xom": b""}
        # (the same call with one bank per map: foldspace.caldera.xom replaces every caldera file)
        out = sync_map.spice_with(spice, "caldera", {"slug": "caldera", "source": "maps/caldera/caldera.ergpatch.json"}, files)
        self.assertEqual([lv["slug"] for lv in out["levels"]], ["caldera", "isle"])
        self.assertEqual([m["file"] for m in out["meshes"]],
                         ["assets/meshes/caldera/foldspace.caldera_B.xom", "assets/meshes/isle/foldspace.isle_A.xom"])
        self.assertEqual(out["melange"], {"range": ">=0.14.0"})

    def test_range_floor(self):
        self.assertEqual(sync_map.range_floor(">=0.14.0"), (0, 14, 0))
        with self.assertRaises(SystemExit):
            sync_map.range_floor(">=0.14.0 <0.15.0")


class VerifyBanks(unittest.TestCase):
    """verify() reads mesh names out of the committed banks' bytes; check that read for both layouts."""

    def names(self, data: bytes, slug="caldera"):
        import re
        return {m.decode() for m in re.findall(("foldspace." + slug + "_").encode() + rb"[A-Za-z0-9]+", data)}

    def test_one_bank_many_meshes(self):
        data = b"\0foldspace.caldera_Boulder_group_0\0foldspace.caldera_Boulder\0foldspace.caldera_Slab\0"
        self.assertEqual(self.names(data), {"foldspace.caldera_Boulder", "foldspace.caldera_Slab"})

    def test_one_mesh_bank(self):
        self.assertEqual(self.names(b"\0foldspace.caldera_Shard\0foldspace.caldera_Shard_group_0\0"),
                         {"foldspace.caldera_Shard"})


class Committed(unittest.TestCase):
    def test_committed_plugin_verifies(self):
        self.assertEqual(sync_map.verify(), [])


if __name__ == "__main__":
    unittest.main()
