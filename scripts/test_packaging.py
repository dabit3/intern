import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PackagingPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="intern-packaging-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.build_log = self.directory / "build.log"
        binary = self.directory / "xcodebuild"
        binary.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$PACKAGING_BUILD_LOG"\nexit 19\n')
        binary.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": f"{self.directory}:/usr/bin:/bin:/usr/sbin:/sbin",
            "PACKAGING_BUILD_LOG": str(self.build_log),
            "SIGNING_IDENTITY": "",
            "NOTARY_PROFILE": "",
            "RELEASE_VERSION": "0.1.0",
            "RELEASE_BUILD": "1",
        }

    def run_packager(self, *arguments, **environment):
        return subprocess.run(
            ["/bin/sh", str(ROOT / "scripts/make-dmg.sh"), *map(str, arguments)],
            cwd=ROOT,
            env={**self.environment, **environment},
            capture_output=True,
            text=True,
            timeout=15,
        )

    def assert_rejected_before_build(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.build_log.exists(), result.stdout + result.stderr)

    def test_help_does_not_build(self):
        result = self.run_packager("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NOTARY_PROFILE", result.stdout)
        self.assertFalse(self.build_log.exists())

    def test_existing_output_is_not_overwritten(self):
        output = self.directory / "Intern.dmg"
        output.write_bytes(b"existing release")
        result = self.run_packager(output)
        self.assert_rejected_before_build(result, "already exists")
        self.assertEqual(output.read_bytes(), b"existing release")

    def test_existing_checksum_is_not_overwritten(self):
        output = self.directory / "Intern.dmg"
        checksum = self.directory / "Intern.dmg.sha256"
        checksum.write_text("existing checksum")
        result = self.run_packager(output)
        self.assert_rejected_before_build(result, "already exists")
        self.assertEqual(checksum.read_text(), "existing checksum")

    def test_output_symlink_is_not_followed(self):
        output = self.directory / "Intern.dmg"
        output.symlink_to(self.directory / "missing-target")
        result = self.run_packager(output)
        self.assert_rejected_before_build(result, "already exists")
        self.assertTrue(output.is_symlink())

    def test_invalid_version_is_rejected(self):
        for version in ("latest", "1.2", "1.2.3.4", "1.2.3-beta"):
            with self.subTest(version=version):
                result = self.run_packager(self.directory / "Intern.dmg", RELEASE_VERSION=version)
                self.assert_rejected_before_build(result, "RELEASE_VERSION")

    def test_invalid_build_number_is_rejected(self):
        for number in ("0", "00", "-1", "abc", "1.2"):
            with self.subTest(number=number):
                result = self.run_packager(self.directory / "Intern.dmg", RELEASE_BUILD=number)
                self.assert_rejected_before_build(result, "RELEASE_BUILD")

    def test_notarization_requires_signing_identity(self):
        result = self.run_packager(self.directory / "Intern.dmg", NOTARY_PROFILE="test-profile")
        self.assert_rejected_before_build(result, "SIGNING_IDENTITY")

    def test_missing_output_directory_is_rejected(self):
        result = self.run_packager(self.directory / "missing" / "Intern.dmg")
        self.assert_rejected_before_build(result, "Output directory")

    def test_extra_arguments_are_rejected(self):
        result = self.run_packager(self.directory / "Intern.dmg", "extra")
        self.assert_rejected_before_build(result, "Usage")

    def test_build_is_universal_and_versioned(self):
        result = self.run_packager(
            self.directory / "Intern.dmg", RELEASE_VERSION="1.2.3", RELEASE_BUILD="42"
        )
        self.assertEqual(result.returncode, 19, result.stderr)
        arguments = self.build_log.read_text().splitlines()
        for expected in (
            "Release", "generic/platform=macOS", "ARCHS=arm64 x86_64",
            "ONLY_ACTIVE_ARCH=NO", "ENABLE_HARDENED_RUNTIME=YES",
            "MARKETING_VERSION=1.2.3", "CURRENT_PROJECT_VERSION=42",
        ):
            self.assertIn(expected, arguments)

    def test_failed_build_does_not_publish_partial_files(self):
        directory = self.directory / "Release artifacts"
        directory.mkdir()
        output = directory / "Intern.dmg"
        result = self.run_packager(output)
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertFalse(output.exists())
        self.assertFalse(output.with_suffix(".dmg.sha256").exists())


@unittest.skipUnless(sys.platform == "darwin", "Xcode project verification uses macOS plutil")
class BuildIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(ROOT / "Intern.xcodeproj/project.pbxproj")],
            check=True,
            capture_output=True,
            text=True,
        )
        objects = json.loads(result.stdout)["objects"]
        target = next(
            value for value in objects.values()
            if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Intern"
        )
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        cls.settings = {
            objects[key]["name"]: objects[key]["buildSettings"] for key in configurations
        }

    def test_debug_has_separate_permission_identity(self):
        self.assertEqual(
            self.settings["Debug"]["PRODUCT_BUNDLE_IDENTIFIER"],
            "com.devin.typesafe.jev-launcher.debug",
        )

    def test_debug_is_named_distinctly_in_permission_prompts(self):
        self.assertEqual(self.settings["Debug"]["INFOPLIST_KEY_CFBundleDisplayName"], "Intern Dev")

    def test_release_preserves_existing_settings_and_permissions(self):
        self.assertEqual(
            self.settings["Release"]["PRODUCT_BUNDLE_IDENTIFIER"],
            "com.devin.typesafe.jev-launcher",
        )
        self.assertEqual(self.settings["Release"]["INFOPLIST_KEY_CFBundleDisplayName"], "Intern")


if __name__ == "__main__":
    unittest.main()
