"""Installer regression: matching binary bytes do not imply launchable modes."""

import importlib.util
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "stage-dmg-app.py"
SPEC = importlib.util.spec_from_file_location("stage_dmg_app", SCRIPT)
STAGING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGING)


class InstallerStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "build/usAIge.app"
        self.destination = self.root / "installer/usAIge.app"
        self.executable = self.source / "Contents/MacOS/usAIge"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        self.executable.chmod(0o755)
        with (self.source / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "usAIge"}, stream)
        self.resource = self.source / "Contents/Resources/readme.txt"
        self.resource.parent.mkdir()
        self.resource.write_text("fixture resource\n")
        self.resource.chmod(0o644)

    def test_copyfile_reproduces_nonlaunchable_identical_binary(self):
        shutil.copytree(self.source, self.destination, copy_function=shutil.copyfile)
        copied = self.destination / "Contents/MacOS/usAIge"
        self.assertEqual(STAGING.digest(copied), STAGING.digest(self.executable))
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode) & 0o111, 0)
        with self.assertRaisesRegex(ValueError, "execute permission"):
            STAGING.application_executable(self.destination)

    def test_staging_preserves_modes_bytes_symlinks_and_replaces_old_bundle(self):
        helper = self.source / "Contents/MacOS/helper"
        helper.write_bytes(b"#!/bin/sh\nexit 0\n")
        helper.chmod(0o751)
        alias = self.source / "Contents/Resources/readme-link"
        alias.symlink_to("readme.txt")
        stale = self.destination / "Contents/Resources/obsolete.txt"
        stale.parent.mkdir(parents=True)
        stale.write_text("old signed resource")

        STAGING.copy_application(self.source, self.destination)

        copied = STAGING.application_executable(self.destination)
        self.assertEqual(STAGING.digest(copied), STAGING.digest(self.executable))
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((copied.parent / "helper").stat().st_mode), 0o751)
        self.assertEqual(stat.S_IMODE((self.destination / "Contents/Resources/readme.txt").stat().st_mode), 0o644)
        self.assertTrue((self.destination / "Contents/Resources/readme-link").is_symlink())
        self.assertEqual((self.destination / "Contents/Resources/readme-link").readlink(), Path("readme.txt"))
        self.assertFalse(stale.exists())

    def test_invalid_source_does_not_remove_existing_destination(self):
        self.destination.mkdir(parents=True)
        retained = self.destination / "retained"
        retained.write_text("previous app")
        self.executable.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "execute permission"):
            STAGING.copy_application(self.source, self.destination)
        self.assertEqual(retained.read_text(), "previous app")

    def test_identical_or_overlapping_paths_are_rejected(self):
        for destination in (self.source, self.source / "nested.app", self.root / "build"):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                STAGING.copy_application(self.source, destination)
        self.assertTrue(self.executable.exists())

    def test_symlinked_destination_is_rejected_without_touching_target(self):
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "nonsymlink"):
            STAGING.copy_application(self.source, self.destination)
        self.assertTrue(self.executable.exists())

    def test_postcopy_validation_detects_permission_loss(self):
        original_copy2 = shutil.copy2

        def losing_execute_bits(source, destination, *arguments, **options):
            result = original_copy2(source, destination, *arguments, **options)
            if Path(source).name == "usAIge":
                Path(destination).chmod(0o644)
            return result

        with patch.object(STAGING.shutil, "copy2", side_effect=losing_execute_bits):
            with self.assertRaisesRegex(ValueError, "execute permission"):
                STAGING.copy_application(self.source, self.destination)

    def test_postcopy_validation_detects_byte_changes(self):
        original_copy2 = shutil.copy2

        def changing_binary(source, destination, *arguments, **options):
            result = original_copy2(source, destination, *arguments, **options)
            if Path(source).name == "usAIge":
                with Path(destination).open("ab") as stream:
                    stream.write(b"changed")
            return result

        with patch.object(STAGING.shutil, "copy2", side_effect=changing_binary):
            with self.assertRaisesRegex(ValueError, "bytes do not match"):
                STAGING.copy_application(self.source, self.destination)

    def test_unsafe_executable_name_is_rejected(self):
        with (self.source / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "../Resources/readme.txt"}, stream)
        with self.assertRaisesRegex(ValueError, "invalid executable name"):
            STAGING.application_executable(self.source)


if __name__ == "__main__":
    unittest.main()
