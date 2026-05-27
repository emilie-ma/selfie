import CoreImage
import UIKit

/// Snapchat-style front-camera output: neutral color, less pore texture (frequency separation).
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

        normalized = downsampleForProcessing(normalized)

        guard isFrontCamera else {
            return normalized.jpegData(compressionQuality: SnapchatCameraTuning.jpegQuality) ?? data
        }

        guard let processed = applySnapchatLook(to: normalized) else {
            return normalized.jpegData(compressionQuality: SnapchatCameraTuning.jpegQuality) ?? data
        }

        return processed.jpegData(compressionQuality: SnapchatCameraTuning.jpegQuality) ?? data
    }

    // MARK: - Snapchat look (texture only, no color grade)

    private static func applySnapchatLook(to image: UIImage) -> UIImage? {
        guard var ciImage = CIImage(image: image, options: [.applyOrientationProperty: true]) else { return nil }

        if SnapchatCameraTuning.postCaptureCropScale > 1.0 {
            ciImage = centerCrop(ciImage, scale: SnapchatCameraTuning.postCaptureCropScale)
        }

        ciImage = reduceNoise(ciImage)
        ciImage = softenSkinTexture(ciImage)

        let outputExtent = ciImage.extent.integral
        guard let cgImage = ciContext.createCGImage(ciImage, from: outputExtent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Frequency separation: blur only removes fine detail; color/luminance base stays intact.
    private static func softenSkinTexture(_ input: CIImage) -> CIImage {
        let retention = CGFloat(SnapchatCameraTuning.skinTextureRetention)
        guard retention < 1.0 else { return input }

        let sigma = SnapchatCameraTuning.smoothBlurRadius
        guard let blurred = input.applyingGaussianBlur(sigma: sigma).clampedToExtent() else {
            return input
        }

        // highPass = original − blurred (texture / pores live here)
        guard let subtract = CIFilter(name: "CISubtractBlendMode") else { return input }
        subtract.setValue(input, forKey: kCIInputBackgroundImageKey)
        subtract.setValue(blurred, forKey: kCIInputImageKey)
        guard var highPass = subtract.outputImage?.cropped(to: input.extent) else { return input }

        if retention > 0 {
            guard let scale = CIFilter(name: "CIColorMatrix") else { return input }
            scale.setValue(highPass, forKey: kCIInputImageKey)
            scale.setValue(CIVector(x: retention, y: 0, z: 0, w: 0), forKey: "inputRVector")
            scale.setValue(CIVector(x: 0, y: retention, z: 0, w: 0), forKey: "inputGVector")
            scale.setValue(CIVector(x: 0, y: 0, z: retention, w: 0), forKey: "inputBVector")
            scale.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            scale.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
            highPass = scale.outputImage?.cropped(to: input.extent) ?? highPass
        }

        // Recombine: blurred base + attenuated texture
        guard let add = CIFilter(name: "CIAdditionCompositing") else { return input }
        add.setValue(highPass, forKey: kCIInputImageKey)
        add.setValue(blurred, forKey: kCIInputBackgroundImageKey)
        return add.outputImage?.cropped(to: input.extent) ?? input
    }

    private static func reduceNoise(_ input: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CINoiseReduction") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(SnapchatCameraTuning.noiseLevel, forKey: "inputNoiseLevel")
        filter.setValue(SnapchatCameraTuning.noiseSharpness, forKey: "inputSharpness")
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }

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
