"""Narrow source-wiring checks; these do not replace device interaction tests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def section(text, start, end=None):
    """The source slice after `start`, so a missing seam fails as an assertion."""
    assert start in text, f'missing source seam: {start}'
    body = text.split(start, 1)[1]
    if end is not None:
        assert end in body, f'missing source seam: {end}'
        body = body.split(end, 1)[0]
    return body


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

    def test_focus_area_reset_moves_indicator_and_device_together(self):
        view_model = (ROOT / 'App/Modules/CameraCapture/CameraViewModel.swift').read_text()
        body = section(view_model, 'func resetFocusAreaToCenter()', '\n    }')
        self.assertIn('setMeteringPoint(', body)
        self.assertIn('session.recenterFocusAndExposurePoint()', body)

    def test_focus_points_of_interest_written_in_one_place(self):
        # The tap path and the switch reset must share the device write; a second
        # copy of the point assignments is how the box and the sensor drift apart.
        session = (ROOT / 'App/Modules/CameraCapture/CameraSession.swift').read_text()
        self.assertEqual(session.count('device.focusPointOfInterest = point'), 1)
        self.assertEqual(session.count('device.exposurePointOfInterest = point'), 1)
        self.assertEqual(session.count('.focusPointOfInterest = '), 1)
        self.assertEqual(session.count('.exposurePointOfInterest = '), 1)
        recenter = section(session, 'func recenterFocusAndExposurePoint()', '\n    }')
        self.assertIn('writeFocusAndExposurePoint(', recenter)

    def test_focus_area_reset_keeps_manual_locks_and_white_balance(self):
        session = (ROOT / 'App/Modules/CameraCapture/CameraSession.swift').read_text()
        recenter = section(session, 'func recenterFocusAndExposurePoint()', '\n    }')
        # A switch reset must not drop a held exposure pin or re-pin the film
        # shutter; it moves the metering area only.
        self.assertNotIn('invalidateMetering()', recenter)
        self.assertNotIn('pinShutterToFilm()', recenter)
        self.assertNotIn('applyWhiteBalanceLock', recenter)
        helper = section(session, 'private func writeFocusAndExposurePoint(', '\n    }')
        self.assertIn('CameraManualFocusPolicy.allowsAutofocusOnTap(', helper)
        self.assertNotIn('exposureMode =', helper)
        self.assertNotIn('focusMode = .locked', helper)

    def test_lens_switch_resets_only_after_a_successful_real_switch(self):
        view_model = (ROOT / 'App/Modules/CameraCapture/CameraViewModel.swift').read_text()
        body = section(view_model, 'func selectLens(_ lens: CameraLens',
                       'private func restoreExposureAfterLensSwitch')
        self.assertEqual(body.count('resetFocusAreaToCenter()'), 1)
        reset_at = body.index('resetFocusAreaToCenter()')
        self.assertGreater(reset_at, body.index('if error == nil {'))
        self.assertGreater(reset_at, body.index('previousLens != lens'))
        self.assertGreater(reset_at, body.index('session.selectCamera(lens, photoIntent: isDevelopmentPhotoMode)'))

    def test_photo_mode_switch_is_a_project_configuration(self):
        # The on/off switch lives in project.yml per configuration, is copied
        # into Info.plist under the key the policy reads, and is read there
        # rather than from a stored preference.
        project = (ROOT / 'project.yml').read_text()
        self.assertEqual(project.count('PHOTO_MODE_ENABLED: YES'), 3)
        self.assertIn('PhotoModeEnabled: $(PHOTO_MODE_ENABLED)', project)
        policy = (ROOT / 'App/Modules/CameraCapture/DevelopmentPhotoFeature.swift').read_text()
        self.assertIn('infoPlistKey = "PhotoModeEnabled"', policy)
        self.assertIn('object(forInfoDictionaryKey: infoPlistKey)', policy)

    def test_video_fallback_swaps_the_session_input(self):
        # The still profile's own entry transaction normally swaps the video
        # input. A fallback install is handed a sensor the session has never
        # held, so it must swap it itself or the preview, the recording and the
        # lens row disagree about which camera is live.
        session = (ROOT / 'App/Modules/CameraCapture/CameraSession.swift').read_text()
        body = section(session, 'private func installSharedVideoOnQueue(',
                       'private func launchSharedVideoRequest')
        self.assertIn('explicit.uniqueID != activeDevice?.uniqueID', body)
        self.assertLess(body.index('try addDevice(explicit)'),
                        body.index('session.sessionPreset = .inputPriority'))

    def test_photo_mode_change_resets_only_after_the_switch_commits(self):
        view_model = (ROOT / 'App/Modules/CameraCapture/CameraViewModel.swift').read_text()
        body = section(view_model, 'func setDevelopmentPhotoMode(_ enabled: Bool',
                       'private func presentPhotoExposure')
        self.assertEqual(body.count('resetFocusAreaToCenter()'), 1)
        self.assertGreater(body.index('resetFocusAreaToCenter()'),
                           body.index('isDevelopmentPhotoMode = enabled'))
        self.assertGreater(body.index('resetFocusAreaToCenter()'),
                           body.index('guard enabled != isDevelopmentPhotoMode'))

    def test_content_view_resets_on_a_committed_non_photo_mode_change(self):
        body = section(self.content, 'private func selectCameraMode(_ mode: CameraMode)',
                       'private func controlBarHorizontalInset')
        self.assertIn('cameraViewModel.resetFocusAreaToCenter()', body)
        reset_at = body.rindex('cameraViewModel.resetFocusAreaToCenter()')
        self.assertGreater(reset_at, body.index('cameraMode.select(mode, enabled: true'))

    def test_debug_snapshots_selected_gauge(self):
        body = self.content.split('private func openDebugFrame()', 1)[1].split('\n    }', 1)[0]
        self.assertIn('library.lastGauge(for:', body)
        self.assertIn('overridingGauge(gauge)', body)


if __name__ == '__main__':
    unittest.main()