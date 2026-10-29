"""Narrow source-wiring checks; these do not replace device interaction tests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PhotoFieldWiringTests(unittest.TestCase):
    def setUp(self):
        self.content = (ROOT / 'App/ContentView.swift').read_text()

    def test_photo_shutter_resolves_current_library_gauge(self):
        callback = self.content.split('onPhotoCapture:', 1)[1].split('photoExposure:', 1)[0]
        self.assertIn('library.lastGauge(for:', callback)
        self.assertRegex(callback, r'takeDevelopmentPhoto\(gauge:\s*gauge\)')

    def test_rescue_uses_requested_ev_in_neutral_meter_coordinates(self):
        body = self.content.split('private var shouldOfferDaylightRescue:', 1)[1].split('\n    }', 1)[0]
        self.assertNotIn('isManualExposure ? 0', body)
        self.assertIn('targetEV: cameraViewModel.liveExposureBias', body)

    def test_photo_and_debug_share_output_interpretation(self):
        renderer = (ROOT / 'App/Modules/ProcessingPipeline/DevelopmentPhotoRenderer.swift').read_text()
        self.assertIn('FilmOutputDisplayConverter.linearImage(fromGamma24: finished)', renderer)

    def test_debug_snapshots_selected_gauge(self):
        body = self.content.split('private func openDebugFrame()', 1)[1].split('\n    }', 1)[0]
        self.assertIn('library.lastGauge(for:', body)
        self.assertIn('overridingGauge(gauge)', body)


if __name__ == '__main__':
    unittest.main()
