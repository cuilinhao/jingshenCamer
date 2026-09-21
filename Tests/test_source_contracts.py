"""Source-level regression checks. These do NOT replace an iOS build/device test."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / 'TestCamer'

class SourceContracts(unittest.TestCase):
    def read(self, name):
        p = APP / name
        self.assertTrue(p.exists(), f'Missing implementation: {name}')
        return p.read_text()

    def test_photo_output_prepares_native_depth(self):
        camera = self.read('CameraManager.swift')
        self.assertIn('photoOutput.isDepthDataDeliveryEnabled = true', camera)
        self.assertIn('settings.isDepthDataDeliveryEnabled =', camera)
        self.assertIn('settings.embedsDepthDataInPhoto =', camera)
        self.assertIn('photo.depthData', camera)

    def test_ordinary_preview_remains_without_stream_processors(self):
        source = '\n'.join(p.read_text() for p in APP.glob('*.swift'))
        self.assertIn('AVCaptureVideoPreviewLayer', source)
        self.assertNotRegex(source, r'AVCapture(?:Video|Depth)DataOutput\s*\(')
        self.assertNotRegex(source, r'CIKernel\s*\(|CIBlendWithMask|CIGaussianBlur')

    def test_virtual_camera_candidates_and_zoom_limits(self):
        camera = self.read('CameraManager.swift')
        for token in ['.builtInDualWideCamera', '.builtInDualCamera', '.builtInTrueDepthCamera',
                      'minAvailableVideoZoomFactor', 'maxAvailableVideoZoomFactor']:
            self.assertIn(token, camera)

    def test_depth_renderer_and_explicit_fallback(self):
        renderer = self.read('DepthPhotoProcessor.swift')
        self.assertIn('depthBlurEffectFilter', renderer)
        self.assertIn('inputAperture', renderer)
        self.assertIn('applyingExifOrientation', renderer)
        self.assertIn('CGImageDestinationCreateWithData', renderer)
        self.assertIn('fallback', renderer)

    def test_no_focus_persistence_or_third_party_sources(self):
        source = '\n'.join(p.read_text() for p in APP.glob('*.swift'))
        self.assertNotRegex(source, r'JSONEncoder|JSONDecoder|UserDefaults|write\(to:|inputFocusRect')
        for p in APP.rglob('*'):
            self.assertNotIn(p.suffix, ('.m', '.mm', '.cpp', '.metal', '.mlmodel', '.mlpackage'))
        self.assertIn('camera.focus(at:', self.read('ViewController.swift'))

    def test_terminal_capture_callback_and_identity_guard(self):
        camera = self.read('CameraManager.swift')
        self.assertIn('didFinishCaptureFor', camera)
        self.assertIn('resolvedSettings.uniqueID', camera)
        self.assertIn('captureTimeout', camera)

    def test_jpeg_saved_from_encoded_result_not_ui_preview(self):
        vc = self.read('ViewController.swift')
        self.assertIn('PHAssetCreationRequest.forAsset()', vc)
        self.assertIn('addResource(with: .photo', vc)
        self.assertNotIn('creationRequestForAsset(from: image)', vc)

    def test_preview_does_not_require_ios26_scene_geometry(self):
        vc = self.read('ViewController.swift')
        self.assertNotIn('?.effectiveGeometry.interfaceOrientation', vc)
        self.assertIn('windowScene?.interfaceOrientation', vc)

    def test_ios17_and_no_implicit_main_actor_for_worker(self):
        project = (ROOT / 'TestCamer.xcodeproj/project.pbxproj').read_text()
        self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 17.0;', project)
        self.assertNotIn('SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor', project)
        self.assertNotIn('packageProductDependencies', project)

if __name__ == '__main__':
    unittest.main(verbosity=2)
