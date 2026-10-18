#!/usr/bin/env python3
"""Check generated iOS target metadata before archiving (requires XcodeGen)."""

import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parent.parent


class ReleaseMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["xcodegen", "generate"], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL)
        project = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-",
            str(ROOT / "Nitrate.xcodeproj" / "project.pbxproj"),
        ], text=True))
        objects = project["objects"]
        root = objects[project["rootObject"]]
        target = next(objects[key] for key in root["targets"]
                      if objects[key]["name"] == "Nitrate")

        def configurations(owner):
            keys = objects[owner["buildConfigurationList"]]["buildConfigurations"]
            return {objects[key]["name"]: objects[key]["buildSettings"] for key in keys}

        inherited = configurations(root)
        cls.settings = {name: inherited[name] | settings
                        for name, settings in configurations(target).items()}

    def test_target_is_iphone_only(self):
        for name, settings in self.settings.items():
            with self.subTest(configuration=name):
                self.assertEqual(str(settings["TARGETED_DEVICE_FAMILY"]), "1",
                                 "Portrait-only camera must not declare native iPad multitasking support")

    def test_required_capabilities_use_registered_names(self):
        for name, settings in self.settings.items():
            with self.subTest(configuration=name):
                self.assertEqual(
                    settings["INFOPLIST_KEY_UIRequiredDeviceCapabilities"].split(),
                    ["metal", "video-camera"],
                    "Apple registers video-camera, not video-capture",
                )

    def test_export_compliance_declaration_is_explicit(self):
        for name, settings in self.settings.items():
            with self.subTest(configuration=name):
                self.assertEqual(settings.get("INFOPLIST_KEY_ITSAppUsesNonExemptEncryption"), "NO")

    def test_release_has_advanced_past_initial_beta(self):
        # A floor, not a pinned current version: later releases/builds pass
        # without editing this regression for the initial repeated 0.1.1 (1).
        for name, settings in self.settings.items():
            with self.subTest(configuration=name):
                version = tuple(map(int, settings["MARKETING_VERSION"].split(".")))
                self.assertGreaterEqual(version, (0, 1, 2))
                self.assertGreaterEqual(int(settings["CURRENT_PROJECT_VERSION"]), 2)

    def test_preserves_portrait_camera_interface(self):
        for name, settings in self.settings.items():
            with self.subTest(configuration=name):
                self.assertEqual(settings["INFOPLIST_KEY_UISupportedInterfaceOrientations"],
                                 "UIInterfaceOrientationPortrait")


if __name__ == "__main__":
    unittest.main(verbosity=2)
