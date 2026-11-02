"""Run the real Nu builder; check both diagnostics and preserved sentinel bytes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

BUILDER = Path(sys.argv.pop(1)).resolve()
FIXTURES = Path(sys.argv.pop(1))


def file(text="replacement", dest=None):
    return {"text": text, "mode": "0644", "dest": dest}


def link(path, target, kind="explicit"):
    return {"path": path, "target": str(target), "kind": kind}


class BuilderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.out = self.root / "out"
        self.attrs = {
            "outputs": {"out": str(self.out)},
            "PATH": os.environ["PATH"],
            "epoch": 0,
            "closure": [{"path": str(FIXTURES)}],
            "version": "20261102.1",
            "links": [],
            "files": {},
            "units": {},
            "sysusers": [],
            "tmpfiles": [],
            "osRelease": "ID=test\n",
            "packageList": [],
            "sbomPath": None,
            "allowedDirs": ["bin", "lib", "share", "nix"],
        }
        self.source = FIXTURES / "a/lib/systemd/system/demo.service"

    def run_builder(self):
        for path, value in self.attrs["files"].items():
            if value["dest"] is None:
                value["dest"] = path.removeprefix("/usr/")
        attrs_file = self.root / "attrs.json"
        attrs_file.write_text(json.dumps(self.attrs))
        return subprocess.run(
            [shutil.which("nu"), "--no-config-file", "--include-path", str(BUILDER),
             "-c", "use main.nu; main build"],
            env={**os.environ, "NIX_ATTRS_JSON_FILE": str(attrs_file)},
            text=True, capture_output=True,
        )

    def succeeds(self):
        result = self.run_builder()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("verification passed", result.stderr)

    def rejects(self, path):
        result = self.run_builder()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("destination conflict", result.stderr)
        self.assertIn(path, result.stderr)
        self.assertEqual(self.source.read_bytes(), b"sentinel")

    def farm(self, path="/usr/lib/systemd", source="a/lib/systemd"):
        self.attrs["links"].append(link(path, FIXTURES / source, "farm"))

    def test_fixed_sbin_alias_cannot_overwrite_bin(self):
        self.attrs["files"] = {"/usr/bin/x": file("sentinel"), "/usr/sbin/x": file()}
        self.rejects("/usr/sbin")
        self.assertEqual((self.out / "bin/x").read_bytes(), b"sentinel")
        self.assertTrue((self.out / "sbin").is_symlink())

    def test_file_cannot_be_a_parent(self):
        self.attrs["files"] = {"/usr/lib/x": file("sentinel"), "/usr/lib/x/y": file()}
        self.rejects("/usr/lib/x")
        self.assertEqual((self.out / "lib/x").read_bytes(), b"sentinel")

    def test_directory_cannot_be_a_file(self):
        self.attrs["files"] = {"/usr/lib": file()}
        self.rejects("/usr/lib")
        self.assertTrue((self.out / "lib").is_dir())

    def test_file_cannot_follow_directory_link(self):
        self.attrs["links"] = [link("/usr/lib/alias", "/usr/lib/real")]
        self.attrs["files"] = {"/usr/lib/alias/x": file()}
        self.out.mkdir()
        (self.out / "lib/real").mkdir(parents=True)
        (self.out / "lib/real/x").write_text("sentinel")
        self.rejects("/usr/lib/alias")
        self.assertEqual((self.out / "lib/real/x").read_bytes(), b"sentinel")

    def test_dangling_link_cannot_be_a_file(self):
        self.attrs["links"] = [link("/usr/lib/x", "missing")]
        self.attrs["files"] = {"/usr/lib/x": file()}
        self.rejects("/usr/lib/x")
        self.assertEqual(os.readlink(self.out / "lib/x"), "missing")
        self.assertFalse((self.out / "lib/missing").exists())

    def test_link_cannot_replace_link(self):
        self.attrs["links"] = [link("/usr/bin/x", "first"), link("/usr/bin/x", "second")]
        self.rejects("/usr/bin/x")
        self.assertEqual(os.readlink(self.out / "bin/x"), "first")

    def test_link_cannot_follow_parent(self):
        self.attrs["links"] = [link("/usr/lib/x", "/usr/bin"), link("/usr/lib/x/y", "missing")]
        self.rejects("/usr/lib/x")
        self.assertFalse((self.out / "bin/y").is_symlink())

    def test_file_cannot_replace_farm_file(self):
        self.farm()
        self.attrs["files"] = {"/usr/lib/systemd/system/demo.service": file()}
        self.rejects("/usr/lib/systemd/system/demo.service")
        self.assertTrue((self.out / "lib/systemd/system/demo.service").is_symlink())

    def test_unit_cannot_replace_farm_file(self):
        self.farm()
        self.attrs["units"] = {"demo.service": "[Unit]\n"}
        self.rejects("/usr/lib/systemd/system/demo.service")
        self.assertTrue((self.out / "lib/systemd/system/demo.service").is_symlink())

    def test_different_farm_sources_collide(self):
        self.farm()
        self.farm("/usr/lib/systemd/system", "b/lib/systemd/system")
        self.rejects("/usr/lib/systemd/system/demo.service")
        self.assertIn("/a/", os.readlink(self.out / "lib/systemd/system/demo.service"))

    def test_farm_cannot_follow_parent_link(self):
        self.attrs["links"] = [link("/usr/lib/alias", "/usr/lib/real")]
        self.farm("/usr/lib/alias/system", "a/lib/systemd/system")
        self.rejects("/usr/lib/alias")
        self.assertFalse((self.out / "lib/real").exists())

    def test_farm_cannot_use_link_as_its_directory(self):
        self.attrs["links"] = [link("/usr/lib/systemd", "/usr/lib/real")]
        self.farm()
        self.rejects("/usr/lib/systemd")
        self.assertFalse((self.out / "lib/real").exists())

    def test_farm_cannot_reuse_an_ordinary_link(self):
        self.attrs["links"] = [link("/usr/lib/systemd/system/demo.service", self.source)]
        self.farm()
        self.rejects("/usr/lib/systemd/system/demo.service")

    def test_generated_metadata_cannot_replace_farm_files(self):
        for name in ["os-release", "golconda/packages.json", "golconda/sbom.json",
                     "sysusers.d/golconda.conf", "tmpfiles.d/golconda.conf"]:
            with self.subTest(name=name):
                self.out = self.root / ("out-" + name.replace("/", "-"))
                self.attrs["outputs"]["out"] = str(self.out)
                self.attrs["sysusers"] = ["u test -"]
                self.attrs["tmpfiles"] = ["d /test 0755 root root -"]
                self.attrs["sbomPath"] = str(self.source)
                self.attrs["links"] = [
                    link("/usr/lib", FIXTURES / "metadata" / name / "lib", "farm")
                ]
                self.rejects(f"/usr/lib/{name}")
                self.assertTrue((self.out / "lib" / name).is_symlink())
                self.assertEqual((FIXTURES / "metadata" / name / "lib" / name).read_bytes(), b"sentinel")

    def test_identical_overlapping_farms_succeed(self):
        self.farm()
        self.farm("/usr/lib/systemd/system", "a/lib/systemd/system")
        self.succeeds()
        self.assertEqual((self.out / "lib/systemd/system/demo.service").read_bytes(), b"sentinel")
        wants = self.out / "lib/systemd/system/multi-user.target.wants/demo.service"
        self.assertEqual(wants.read_bytes(), b"sentinel")

    def test_shared_directories_and_normal_links_succeed(self):
        self.attrs["files"] = {"/usr/lib/shared/a": file("a"), "/usr/lib/shared/b": file("b")}
        self.attrs["links"] = [
            link("/usr/bin/tool", FIXTURES / "a/bin/tool", "package"),
            link("/usr/lib/systemd/system/multi-user.target.wants/demo.service", "../demo.service"),
            link("/usr/lib/systemd/system/dbus.service", "demo.service"),
            link("/usr/share/zoneinfo", FIXTURES / "a/share/zoneinfo"),
            link("/usr/lib/security/pam", FIXTURES / "a/lib/security"),
        ]
        self.attrs["units"] = {"demo.service": "[Unit]\n"}
        self.succeeds()
        self.assertEqual((self.out / "lib/shared/a").read_text(), "a")
        self.assertEqual((self.out / "lib/shared/b").read_text(), "b")
        for path in ["bin/tool", "share/zoneinfo", "lib/security/pam",
                     "lib/systemd/system/dbus.service"]:
            self.assertTrue((self.out / path).is_symlink(), path)
        wants = self.out / "lib/systemd/system/multi-user.target.wants/demo.service"
        self.assertEqual(os.readlink(wants), "../demo.service")
        self.assertEqual((self.out / "bin/tool").read_bytes(), b"tool")
        self.assertEqual((self.out / "share/zoneinfo/UTC").read_bytes(), b"utc")
        self.assertEqual((self.out / "lib/security/pam/pam.so").read_bytes(), b"pam")
        self.assertEqual((self.out / "lib/systemd/system/dbus.service").read_text(), "[Unit]\n")

    def test_initrd_without_system_metadata_or_sbom_succeeds(self):
        self.succeeds()
        self.assertTrue((self.out / "sbin").is_symlink())
        self.assertEqual(os.readlink(self.out / "sbin"), "bin")
        for name in ["config", "schema", "sbom"]:
            self.assertFalse((self.out / f"lib/golconda/{name}.json").exists())

    def test_metadata_owners_emit_once(self):
        self.attrs["files"] = {
            f"/usr/lib/golconda/{name}.json": file("{}")
            for name in ["config", "schema", "attribution"]
        }
        self.attrs["sbomPath"] = str(self.source)
        self.attrs["sysusers"] = ["u test -"]
        self.attrs["tmpfiles"] = ["d /test 0755 root root -"]
        self.succeeds()
        self.assertEqual((self.out / "lib/golconda/sbom.json").read_bytes(), b"sentinel")


if __name__ == "__main__":
    unittest.main()
