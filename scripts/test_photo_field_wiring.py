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

    def test_still_renderer_does_not_apply_orientation_twice(self):
        # Measured: CIRAWFilter returns an already-oriented image, so a second
        # rotation delivers every frame 90 degrees out.
        renderer = (ROOT / 'App/Modules/ProcessingPipeline/DevelopmentPhotoRenderer.swift').read_text()
        self.assertNotIn('oriented(forExifOrientation:', renderer)

    def test_still_capture_sets_the_photo_connection_rotation_before_the_request(self):
        # The DNG's EXIF orientation follows the photo connection's angle, so the
        # angle must be installed on the connection immediately before capturePhoto.
        capture = (ROOT / 'App/Modules/CameraCapture/CameraPhotoCapture.swift').read_text()
        applied = capture.index('        applyCaptureRotation()')
        request = capture.index('output.capturePhoto(with: settings, delegate: self)')
        self.assertLess(applied, request)
        self.assertIn('isVideoRotationAngleSupported(requested)', capture)

    def test_still_capture_manifest_records_requested_applied_and_support(self):
        capture = (ROOT / 'App/Modules/CameraCapture/CameraPhotoCapture.swift').read_text()
        manifest = capture.split('private func writeManifest', 1)[1]
        for key in ('rotationAngleRequested', 'rotationAngleApplied', 'rotationAngleSupported'):
            self.assertIn(f'"{key}"', manifest)

    def test_frozen_tap_orientation_reaches_the_photo_request(self):
        session = (ROOT / 'App/Modules/CameraCapture/CameraSession.swift').read_text()
        self.assertIn('captureRotationAngle(for: frozenOrientation ?? .unknown)', session)
        self.assertIn('controller.capture(rotationAngle: rotationAngle', session)
        view_model = (ROOT / 'App/Modules/CameraCapture/CameraViewModel.swift').read_text()
        self.assertIn('CameraOrientationObserver.shared.deliveryOrientation', view_model)
        self.assertIn('session.captureDevelopmentPhoto(frozenOrientation: frozenOrientation)',
                      view_model)

    def test_every_pending_still_resume_carries_the_frozen_angle(self):
        controller = (ROOT / 'App/Modules/CameraCapture/DevelopmentPhotoController.swift').read_text()
        self.assertGreaterEqual(controller.count('rotationAngle: pending.rotationAngle'), 3)
        self.assertIn('rotationAngle: rotationAngle', controller)

    def test_debug_snapshots_selected_gauge(self):
        body = self.content.split('private func openDebugFrame()', 1)[1].split('\n    }', 1)[0]
        self.assertIn('library.lastGauge(for:', body)
        self.assertIn('overridingGauge(gauge)', body)


if __name__ == '__main__':
    unittest.main()
