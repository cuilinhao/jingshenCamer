"""源码结构检查，仅防止链路退化；不代表 iOS 编译/渲染或真机通过。"""
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT/'TestCamer'
class SourceContracts(unittest.TestCase):
    def read(self, name): return (APP/name).read_text()
    def test_photo_output_prepares_native_depth(self):
        c = self.read('CameraManager.swift')
        for token in ['photoOutput.isDepthDataDeliveryEnabled = true', 'settings.isDepthDataDeliveryEnabled =',
                      'settings.isDepthDataFiltered = true', 'NativeDepthSnapshot(depthData: depth)', 'photo.depthData']:
            self.assertIn(token, c)
        # 内存采集容器现在保留深度元数据；最终导出隐私由实际原生渲染测试验证。
        self.assertIn('photo.nativeDepth', self.read('DepthPhotoProcessor.swift'))
    def test_ordinary_preview_has_no_stream_processor(self):
        src = '\n'.join(p.read_text() for p in APP.glob('*.swift'))
        self.assertIn('AVCaptureVideoPreviewLayer', src)
        self.assertNotRegex(src, r'AVCapture(?:Video|Depth)DataOutput\s*\(')
        self.assertNotRegex(src, r'CIKernel\s*\(|CIColorKernel\s*\(')
        ui = self.read('ViewController.swift')
        self.assertIn('updateDepthPanel() // 仅更新下一次拍照参数；不渲染预览。', ui)
    def test_virtual_camera_candidates_and_zoom_limits(self):
        c = self.read('CameraManager.swift')
        for token in ['.builtInDualWideCamera', '.builtInDualCamera', '.builtInTrueDepthCamera',
                      'minAvailableVideoZoomFactor', 'maxAvailableVideoZoomFactor']:
            self.assertIn(token, c)
    def test_disparity_uses_float_and_row_stride(self):
        c = self.read('NativeDepthSnapshot.swift')
        for token in ['kCVPixelFormatType_DisparityFloat32', 'CVPixelBufferGetBytesPerRow',
                      'CVPixelBufferUnlockBaseAddress', 'width*height']:
            self.assertIn(token, c)
    def test_depth_renderer_and_explicit_fallback(self):
        p = self.read('DepthPhotoProcessor.swift')
        self.assertIn('depth.oriented', p.replace('nativeDepth.raster.oriented', 'depth.oriented'))
        self.assertIn('DepthMath.makePlan', p)
        self.assertIn('EffectMeasurement', p)
        self.assertIn('measurement.hasVisibleChange ? .applied : .weakEffect', p)
        self.assertIn('fallback=ordinary photo', p)
    def test_only_baked_jpeg_is_saved_and_no_focus_persistence(self):
        # TestLog is the explicit diagnostic text sink requested by the user.
        # Image/depth/focus processing still may not write to disk directly.
        src = '\n'.join(p.read_text() for p in APP.glob('*.swift') if p.name != 'TestLog.swift')
        self.assertNotRegex(src, r'JSONEncoder|JSONDecoder|UserDefaults|write\(to:|NSKeyedArchiver|URLSession')
        result_struct = self.read('DepthPhotoProcessor.swift').split('struct ProcessedPhoto: Sendable {', 1)[1].split('\n}', 1)[0]
        self.assertNotRegex(result_struct, r'let\s+\w*(?:Focus|focus|depth|Depth)\w*\s*:')
        vc = self.read('ViewController.swift')
        self.assertIn('saveToPhotoLibrary(photo.jpegData)', vc)
        self.assertIn('camera.focus(at:', vc)
        self.assertIn('hasDepthData', self.read('CaptureModels.swift'))
    def test_no_external_depth_model_fallback(self):
        src = '\n'.join(p.read_text() for p in APP.glob('*.swift'))
        # Apple 人物 mask 仅保护真实深度渲染中的主体；无深度回退由原生管线测试验证。
        self.assertNotRegex(src, r'MLModel\(')
        self.assertIn('VNDetectFaceRectanglesRequest', src)
        for p in APP.rglob('*'):
            self.assertNotIn(p.suffix, ('.m', '.mm', '.cpp', '.metal', '.mlmodel', '.mlpackage'))
    def test_terminal_callback_and_identity_guard(self):
        c = self.read('CameraManager.swift')
        for t in ['didFinishCaptureFor', 'resolvedSettings.uniqueID', 'captureTimeout', 'pending.id == id']:
            self.assertIn(t, c)
    def test_sharp_region_preserves_full_resolution(self):
        c = self.read('DepthBlurRenderer.swift')
        self.assertIn('workingLongEdge: CGFloat = 2048', c)
        self.assertIn('blend(scaledBlur, over: original', c)
        self.assertIn('plan.maxRadius(longEdge:', c)
    def test_no_gamma_conversion_for_mask_intermediate(self):
        c = self.read('DepthBlurRenderer.swift')
        self.assertIn('format: .RGBA8, colorSpace: nil)', c)
        self.assertIn('[.colorSpace: NSNull()]', c)
    def test_result_diagnostics_and_weak_effect_compare(self):
        ui = self.read('ViewController.swift')
        self.assertIn('DepthDiagnosticsViewController', ui)
        self.assertIn('outcome.canCompare', ui)
        self.assertIn('diagnosticMaskData', ui)
        self.assertIn('comparisonControls.isHidden = true', ui)
    def test_ios17_and_worker_isolation(self):
        proj = (ROOT/'TestCamer.xcodeproj/project.pbxproj').read_text()
        self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 17.0;', proj)
        self.assertIn('CURRENT_PROJECT_VERSION = 3;', proj)
        self.assertNotIn('SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor', proj)
        self.assertNotIn('packageProductDependencies', proj)
        self.assertIn('windowScene?.interfaceOrientation', self.read('ViewController.swift'))
if __name__ == '__main__': unittest.main(verbosity=2)
