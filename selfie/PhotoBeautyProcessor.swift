import CoreImage
import UIKit

/// Snapchat-style front-camera output. Mirroring comes from AVCapture (isVideoMirrored) — we only bake orientation + beauty.
enum PhotoBeautyProcessor {

    private static let ciContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .cacheIntermediates: false
        ])
    }()

    static func prepareSnapchatPhoto(
        from data: Data,
        isFrontCamera: Bool,
        applyMirrorFallback: Bool = false
    ) -> Data {
        guard let image = UIImage(data: data) else { return data }

        var normalized = renderNormalized(image)
        if isFrontCamera && applyMirrorFallback {
            normalized = renderHorizontallyFlipped(normalized)
        }

        // Downsample before Core Image — largest memory win for full-res captures.
        normalized = downsampleForProcessing(normalized)

        guard isFrontCamera else {
            return normalized.jpegData(compressionQuality: SnapchatCameraTuning.jpegQuality) ?? data
        }

        guard let processed = applySnapchatLook(to: normalized) else {
            return normalized.jpegData(compressionQuality: SnapchatCameraTuning.jpegQuality) ?? data
        }

        return processed.jpegData(compressionQuality: SnapchatCameraTuning.jpegQuality) ?? data
    }

    // MARK: - Snapchat look (Core Image)

    private static func applySnapchatLook(to image: UIImage) -> UIImage? {
        guard var ciImage = CIImage(image: image, options: [.applyOrientationProperty: true]) else { return nil }

        if SnapchatCameraTuning.postCaptureCropScale > 1.0 {
            ciImage = centerCrop(ciImage, scale: SnapchatCameraTuning.postCaptureCropScale)
        }

        ciImage = reduceNoise(ciImage)
        ciImage = softenSkin(ciImage)
        ciImage = softenShadows(ciImage)
        ciImage = applyWarmTone(ciImage)
        ciImage = applyColorGrade(ciImage)

        let outputExtent = ciImage.extent.integral
        guard let cgImage = ciContext.createCGImage(ciImage, from: outputExtent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Scales so the longest side ≤ beautyProcessingLongEdge before filter chain runs.
    private static func downsampleForProcessing(_ image: UIImage) -> UIImage {
        let maxEdge = SnapchatCameraTuning.beautyProcessingLongEdge
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let longEdge = max(pixelW, pixelH)
        guard longEdge > maxEdge else { return image }

        let scale = maxEdge / longEdge
        let newSize = CGSize(width: pixelW * scale, height: pixelH * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Edge-preserving smooth: blend a blurred copy to kill pore grit while keeping eyes/brows.
    private static func softenSkin(_ input: CIImage) -> CIImage {
        let blend = CGFloat(SnapchatCameraTuning.skinSmoothBlend)
        guard blend > 0 else { return input }

        let radius = SnapchatCameraTuning.smoothBlurRadius
        guard let blurred = input.applyingGaussianBlur(sigma: radius).clampedToExtent() else {
            return input
        }

        guard let dissolved = CIFilter(name: "CIDissolveTransition") else { return input }
        dissolved.setValue(input, forKey: kCIInputImageKey)
        dissolved.setValue(blurred, forKey: kCIInputTargetImageKey)
        dissolved.setValue(blend, forKey: kCIInputTimeKey)
        return dissolved.outputImage?.cropped(to: input.extent) ?? input
    }

    private static func reduceNoise(_ input: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CINoiseReduction") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(SnapchatCameraTuning.noiseLevel, forKey: "inputNoiseLevel")
        filter.setValue(SnapchatCameraTuning.noiseSharpness, forKey: "inputSharpness")
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }

    private static func softenShadows(_ input: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIHighlightShadowAdjust") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(SnapchatCameraTuning.localContrastReduction, forKey: "inputShadowAmount")
        filter.setValue(-0.04, forKey: "inputHighlightAmount")
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }

    private static func applyWarmTone(_ input: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(
            CIVector(x: SnapchatCameraTuning.warmthNeutral, y: 0),
            forKey: "inputNeutral"
        )
        filter.setValue(
            CIVector(x: SnapchatCameraTuning.warmthTarget, y: 0),
            forKey: "inputTargetNeutral"
        )
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }

    private static func applyColorGrade(_ input: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(SnapchatCameraTuning.saturation, forKey: kCIInputSaturationKey)
        filter.setValue(SnapchatCameraTuning.contrast, forKey: kCIInputContrastKey)
        filter.setValue(SnapchatCameraTuning.brightness, forKey: kCIInputBrightnessKey)
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }

    private static func centerCrop(_ image: CIImage, scale: CGFloat) -> CIImage {
        guard scale > 1 else { return image }
        let extent = image.extent
        let cropW = extent.width / scale
        let cropH = extent.height / scale
        let rect = CGRect(
            x: extent.midX - cropW / 2,
            y: extent.midY - cropH / 2,
            width: cropW,
            height: cropH
        )
        return image.cropped(to: rect)
    }

    // MARK: - Orientation

    private static func renderHorizontallyFlipped(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: image.size.width, y: 0)
            ctx.cgContext.scaleBy(x: -1, y: 1)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func renderNormalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

private extension CIImage {
    func clampedToExtent() -> CIImage? {
        applyingFilter("CIAffineClamp", parameters: [
            kCIInputTransformKey: CGAffineTransform.identity
        ])
    }
}
