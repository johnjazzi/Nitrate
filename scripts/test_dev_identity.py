#!/usr/bin/env python3
"""Verify isolated local identities in XcodeGen output without compiling an app."""

import json
from pathlib import Path
import shlex
import subprocess
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent


class DevIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["xcodegen", "generate"], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL)
        project_path = ROOT / "Nitrate.xcodeproj"
        project = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-",
            str(project_path / "project.pbxproj"),
        ], text=True))
        objects = project["objects"]
        root = objects[project["rootObject"]]
        cls.target = next(objects[key] for key in root["targets"]
                          if objects[key]["name"] == "Nitrate")

        def configurations(owner):
            keys = objects[owner["buildConfigurationList"]]["buildConfigurations"]
            return {objects[key]["name"]: objects[key]["buildSettings"] for key in keys}

        inherited = configurations(root)
        cls.settings = {name: inherited[name] | settings
                        for name, settings in configurations(cls.target).items()}
        cls.schemes = {path.stem: ET.parse(path).getroot()
                       for path in (project_path / "xcshareddata" / "xcschemes").glob("*.xcscheme")}

    def test_debug_and_dev_release_are_isolated_from_production(self):
        self.assertEqual(set(self.settings), {"Debug", "DevRelease", "Release"})
        for name, identifier, display_name in (
            ("Debug", "com.nitrate.app.dev", "Nitrate Dev"),
            ("DevRelease", "com.nitrate.app.dev", "Nitrate Dev"),
            ("Release", "com.nitrate.app", "Nitrate"),
        ):
            with self.subTest(configuration=name):
                settings = self.settings[name]
                self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], identifier)
                self.assertEqual(settings["INFOPLIST_KEY_CFBundleDisplayName"], display_name)
                self.assertEqual(settings["PRODUCT_NAME"], "Nitrate")
        self.assertEqual(self.target["productName"], "Nitrate")

    def test_dev_release_uses_release_compiler_behavior(self):
        self.assertTrue("DevRelease" in self.settings, "Missing local release configuration")
        debug = self.settings["Debug"]
        release = self.settings["Release"]
        dev_release = self.settings["DevRelease"]
        self.assertIn("DEBUG", shlex.split(debug["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]))
        self.assertEqual(debug["SWIFT_OPTIMIZATION_LEVEL"], "-Onone")
        for name, settings in (("Release", release), ("DevRelease", dev_release)):
            with self.subTest(configuration=name):
                self.assertNotIn("DEBUG", shlex.split(settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")))
                self.assertNotIn("DEBUG=1", settings.get("GCC_PREPROCESSOR_DEFINITIONS", []))
                self.assertEqual(settings["SWIFT_OPTIMIZATION_LEVEL"], "-O")
                self.assertEqual(settings["SWIFT_COMPILATION_MODE"], "wholemodule")
                self.assertEqual(settings.get("ENABLE_TESTABILITY", "NO"), "NO")

    def test_schemes_keep_local_archives_out_of_production_release(self):
        self.assertTrue("NitrateDev" in self.schemes, "Missing local development scheme")
        for name, archive_config in (("Nitrate", "Release"), ("NitrateDev", "DevRelease")):
            with self.subTest(scheme=name):
                scheme = self.schemes[name]
                launch = scheme.find("LaunchAction")
                assert launch is not None, "Missing launch action"
                self.assertEqual(launch.attrib["buildConfiguration"], "Debug")
                fixture = launch.find("StoreKitConfigurationFileReference")
                assert fixture is not None, "Missing local StoreKit fixture"
                self.assertEqual(fixture.attrib["identifier"], "../../StoreKit/Nitrate.storekit")
                for action in ("ArchiveAction", "ProfileAction"):
                    element = scheme.find(action)
                    assert element is not None, f"Missing {action}"
                    self.assertEqual(element.attrib["buildConfiguration"], archive_config)
                entries = scheme.findall("BuildAction/BuildActionEntries/BuildActionEntry")
                self.assertEqual(len(entries), 1)
                self.assertEqual(entries[0].attrib["buildForArchiving"], "YES")
                reference = entries[0].find("BuildableReference")
                assert reference is not None, "Missing app buildable reference"
                self.assertEqual(reference.attrib["BlueprintName"], "Nitrate")
                self.assertEqual(reference.attrib["BuildableName"], "Nitrate.app")
        archive = self.schemes["Nitrate"].find("ArchiveAction")
        assert archive is not None, "Missing production archive action"
        production = self.settings[archive.attrib["buildConfiguration"]]
        self.assertEqual(production["PRODUCT_BUNDLE_IDENTIFIER"], "com.nitrate.app")
        self.assertEqual(production["INFOPLIST_KEY_CFBundleDisplayName"], "Nitrate")

    def test_signing_and_product_metadata_are_shared_without_identity_leaks(self):
        for name, settings in self.settings.items():
            with self.subTest(configuration=name):
                self.assertEqual(settings["CODE_SIGN_STYLE"], "Automatic")
                self.assertEqual(settings["DEVELOPMENT_TEAM"], "U43C6BCZFS")
                self.assertEqual(settings["CODE_SIGN_IDENTITY"], "Apple Development")
                self.assertEqual(settings["PROVISIONING_PROFILE_SPECIFIER"], "")
                self.assertEqual(settings["MARKETING_VERSION"], "0.1.2")
                self.assertEqual(str(settings["CURRENT_PROJECT_VERSION"]), "2")
                self.assertNotIn("CODE_SIGN_ENTITLEMENTS", settings)


if __name__ == "__main__":
    unittest.main(verbosity=2)
