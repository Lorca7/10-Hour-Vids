import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO

enum ImageLoader {
    /// Loads a photo (JPEG, PNG, HEIC, TIFF, …) with its camera orientation applied.
    static func load(_ url: URL, maxPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AppError("“\(url.lastPathComponent)” isn’t a readable image.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppError("“\(url.lastPathComponent)” couldn’t be decoded.")
        }
        return image
    }

    /// The photo's full size in pixels, after orientation.
    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }
}

enum FrameRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws the video frame: background, then the photo placed according to `mode`.
    static func draw(image: CGImage?, in ctx: CGContext, width: Int, height: Int, mode: FitMode, background: RGBColor) {
        let W = CGFloat(width), H = CGFloat(height)
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        ctx.setFillColor(CGColor(srgbRed: background.r, green: background.g, blue: background.b, alpha: 1))
        ctx.fill(canvas)
        guard let image else { return }
        ctx.interpolationQuality = .high

        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        func centered(_ scale: CGFloat) -> CGRect {
            let w = iw * scale, h = ih * scale
            return CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h)
        }
        let fitScale = min(W / iw, H / ih)
        let fillScale = max(W / iw, H / ih)

        switch mode {
        case .fit:
            ctx.draw(image, in: centered(fitScale))
        case .fill:
            ctx.draw(image, in: centered(fillScale))
        case .blur:
            if let blurred = blurredFill(image, size: canvas.size) {
                ctx.draw(blurred, in: canvas)
            }
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.3))
            ctx.fill(canvas)
            ctx.draw(image, in: centered(fitScale))
        }
    }

    private static func blurredFill(_ image: CGImage, size: CGSize) -> CGImage? {
        // Work at quarter size: the result is blurry anyway, and this is much faster.
        let small = CGSize(width: max(16, (size.width / 4).rounded()), height: max(9, (size.height / 4).rounded()))
        var ci = CIImage(cgImage: image)
        let scale = max(small.width / ci.extent.width, small.height / ci.extent.height)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = ci.extent.minX + (ci.extent.width - small.width) / 2
        let dy = ci.extent.minY + (ci.extent.height - small.height) / 2
        ci = ci.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
        let rect = CGRect(origin: .zero, size: small)
        let blurred = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(small.width) * 0.035)
            .cropped(to: rect)
        return ciContext.createCGImage(blurred, from: rect)
    }

    static func renderImage(image: CGImage?, width: Int, height: Int, mode: FitMode, background: RGBColor) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        draw(image: image, in: ctx, width: width, height: height, mode: mode, background: background)
        return ctx.makeImage()
    }

    static func makePixelBuffer(image: CGImage?, width: Int, height: Int, mode: FitMode, background: RGBColor) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw AppError("Couldn’t allocate a video frame.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw AppError("Couldn’t draw the video frame.") }
        draw(image: image, in: ctx, width: width, height: height, mode: mode, background: background)
        return buffer
    }
}
