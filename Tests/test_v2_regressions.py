"""Source guards only: NOT a camera or Core Image rendering test."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'TestCamer'
class V2Regressions(unittest.TestCase):
    def test_direct_depth_is_transferred_not_only_boolean(self):
        c = (APP/'CameraManager.swift').read_text()
        self.assertIn('NativeDepthSnapshot', c, 'photo.depthData must travel to renderer, not only hasDepthData')
    def test_success_requires_measured_output_change(self):
        c = (APP/'DepthPhotoProcessor.swift').read_text()
        self.assertIn('EffectMeasurement', c, 'non-nil CGImage is not evidence of visible depth blur')
    def test_renderer_has_continuous_near_and_far_blur(self):
        p = APP/'DepthBlurRenderer.swift'
        self.assertTrue(p.exists(), 'missing explicit depth-driven renderer')
        c = p.read_text()
        for token in ['near', 'far', 'maskedVariableBlur', 'edgePreserveUpsample']:
            self.assertIn(token, c)
if __name__ == '__main__': unittest.main(verbosity=2)
