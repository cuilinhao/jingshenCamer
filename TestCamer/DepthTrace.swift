import Foundation
import AVFoundation
import ImageIO

/// 两个 App 共用相同诊断字段；只读尺寸、格式和能力，不转换或修改深度。
enum DepthTrace {
    static func depth(_ depth: AVDepthData?) -> String {
        guard let depth else { return "depth=none" }
        let map = depth.depthDataMap
        return "depth=\(CVPixelBufferGetWidth(map))x\(CVPixelBufferGetHeight(map))" +
            " depthType=\(depth.depthDataType) pixelType=\(CVPixelBufferGetPixelFormatType(map))" +
            " rowBytes=\(CVPixelBufferGetBytesPerRow(map)) quality=\(depth.depthDataQuality.rawValue)" +
            " accuracy=\(depth.depthDataAccuracy.rawValue) filtered=\(depth.isDepthDataFiltered)" +
            " calibration=\(depth.cameraCalibrationData != nil)"
    }

    /// 仅读附件描述，不额外构造 AVDepthData；避免日志改变后续转换的执行顺序。
    static func data(_ data: Data?) -> String {
        guard let data else { return "bytes=0 container=none" }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return "bytes=\(data.count) container=invalid"
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        func aux(_ type: CFString) -> String {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [String: Any] else { return "none" }
            let desc = info[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any] ?? [:]
            let w = desc[kCGImagePropertyWidth as String] as? NSNumber ?? -1
            let h = desc[kCGImagePropertyHeight as String] as? NSNumber ?? -1
            let pixel = desc[kCGImagePropertyPixelFormat as String] as? NSNumber ?? -1
            return "\(w)x\(h)/\(pixel)"
        }
        return "bytes=\(data.count) container=\(CGImageSourceGetType(source) as String? ?? "unknown")" +
            " rgb=\(props[kCGImagePropertyPixelWidth as String] ?? "?")x\(props[kCGImagePropertyPixelHeight as String] ?? "?")" +
            " exif=\(props[kCGImagePropertyOrientation as String] ?? "?")" +
            " auxDisparity=\(aux(kCGImageAuxiliaryDataTypeDisparity)) auxDepth=\(aux(kCGImageAuxiliaryDataTypeDepth))" +
            " auxMatte=\(aux(kCGImageAuxiliaryDataTypePortraitEffectsMatte))" +
            " auxHair=\(aux(kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte)) auxGlasses=\(aux(kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte))"
    }

#if os(iOS)
    static func photo(_ photo: AVCapturePhoto) -> String {
        let size = photo.resolvedSettings.photoDimensions
        let matte = photo.portraitEffectsMatte?.mattingImage
        return "photo=\(size.width)x\(size.height) raw=\(photo.isRawPhoto)" +
            " source=\(photo.sourceDeviceType?.rawValue ?? "unknown") fusion=\(photo.resolvedSettings.isVirtualDeviceFusionEnabled)" +
            " matte=\(matte.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "none")"
    }

    /// 在提交快门的队列读取实际输入，区分界面上的主摄和系统正在使用的设备。
    static func device(_ device: AVCaptureDevice?, output: AVCapturePhotoOutput, preset: AVCaptureSession.Preset? = nil) -> String {
        guard let device else { return "input=none" }
        let format = device.activeFormat
        let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let depth = device.activeDepthDataFormat.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
        let ranges: String
        if #available(iOS 17.2, *) {
            ranges = format.supportedVideoZoomRangesForDepthDataDelivery.map { "\($0.lowerBound)...\($0.upperBound)" }.joined(separator: ",")
        } else {
            ranges = format.supportedVideoZoomFactorsForDepthDataDelivery.map { "\($0)" }.joined(separator: ",")
        }
        return "preset=\(preset?.rawValue ?? "unknown") input=\(device.deviceType.rawValue) virtual=\(device.isVirtualDevice)" +
            " primary=\(device.activePrimaryConstituent?.deviceType.rawValue ?? "none") lock=\(device.activePrimaryConstituentDeviceSwitchingBehavior.rawValue)" +
            " zoom=\(device.videoZoomFactor) video=\(video.width)x\(video.height) videoType=\(CMFormatDescriptionGetMediaSubType(format.formatDescription))" +
            " formatPhotos=\(format.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }.joined(separator: ","))" +
            " depthFormats=\(format.supportedDepthDataFormats.count) activeDepth=\(depth.map { "\($0.width)x\($0.height)" } ?? "none") ranges=\(ranges)" +
            " outputDepth=\(output.isDepthDataDeliverySupported)/\(output.isDepthDataDeliveryEnabled)" +
            " outputMax=\(output.maxPhotoDimensions.width)x\(output.maxPhotoDimensions.height)" +
            // 就绪状态与输出能力只用于对照，不能当成照片已交付有效深度。
            " readiness=\(output.captureReadiness.rawValue) photoActive=\(output.connection(with: .video)?.isActive == true)" +
            " proRAW=\(output.isAppleProRAWEnabled) constituents=\(output.isVirtualDeviceConstituentPhotoDeliveryEnabled) live=\(output.isLivePhotoCaptureEnabled)" +
            " color=\(device.activeColorSpace.rawValue) hdr=\(device.isVideoHDREnabled) frameSeconds=\(device.activeVideoMinFrameDuration.seconds)" +
            " focusMode=\(device.focusMode.rawValue) exposureMode=\(device.exposureMode.rawValue) wbMode=\(device.whiteBalanceMode.rawValue)" +
            " iso=\(device.iso) exposureSeconds=\(device.exposureDuration.seconds)"
    }
#endif
}
