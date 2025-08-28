import AVFoundation
import CoreImage
import Flutter
import Foundation
import ImageIO
import VideoToolbox

/// Stored frame payload: either NV12 (Y + interleaved UV) or BGRA (tightly packed).
private enum StoredPayload {
    case nv12(y: Data, uv: Data)  // Y: w*h, UV: w*(h/2) tightly packed
    case bgra(bytes: Data, bytesPerRow: Int)  // tightly packed: bytesPerRow == width * 4
}

/// Lightweight snapshot of the latest frame.
private struct StoredFrame {
    let payload: StoredPayload
    let width: Int
    let height: Int
    let tsNs: UInt64
}

/// - Caches the last frame (NV12 or BGRA).
/// - Exposes a per-frame callback invoked on the same thread as `accept`.
/// - Builds a Dart-friendly map (`planes`) compatible with your parser.
/// - Saves JPEG with pixel rotation (no EXIF orientation).
final class LastFrameStore {
    typealias OnFrameListener = (_ frame: [String: Any]) -> Void

    /// Throttling (~5 fps by default): 200ms.
    private let defaultMinIntervalNs: UInt64 = 200_000_000
    private var lastAcceptTsNs: UInt64 = 0

    // MARK: - Metadata (updated by the camera before accept)
    private var metaAperture: Double?
    private var metaExposureTimeNs: Int?
    private var metaIso: Double?

    /// Latest frame.
    private var last: StoredFrame?

    /// Optional listener.
    private var onFrameListener: OnFrameListener?
    private var copyBytesForCallback: Bool = true

    // MARK: - Public API

    /// Register a per-frame listener. Pass `nil` to clear.
    func setOnFrameListener(_ listener: OnFrameListener?, copyBytesForCallback: Bool) {
        self.onFrameListener = listener
        self.copyBytesForCallback = copyBytesForCallback
    }

    /// Clear the listener.
    func clearOnFrameListener() {
        self.onFrameListener = nil
    }

    /// Update per-frame metadata so it can be embedded into the preview map.
    func updateMetadata(aperture: Double?, exposureTimeNs: Int?, iso: Double?) {
        // Store simple value types; called from the same queue as `accept`.
        self.metaAperture = aperture
        self.metaExposureTimeNs = exposureTimeNs
        self.metaIso = iso
    }

    /// Accept a CMSampleBuffer (NV12 or 32BGRA).
    /// Copies into tightly packed buffers and updates the cache.
    @discardableResult
    func accept(_ sampleBuffer: CMSampleBuffer, minIntervalNs: UInt64? = nil) -> Bool {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let minNs = minIntervalNs ?? defaultMinIntervalNs
        if now &- lastAcceptTsNs < minNs { return false }

        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        let fmt = CVPixelBufferGetPixelFormatType(pixel)

        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }

        let w = CVPixelBufferGetWidth(pixel)
        let h = CVPixelBufferGetHeight(pixel)

        let newFrame: StoredFrame?

        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            // NV12: plane 0 (Y), plane 1 (interleaved UV)
            guard
                let yBase = CVPixelBufferGetBaseAddressOfPlane(pixel, 0),
                let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)
            else { return false }

            let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
            let uvH = h / 2

            var yData = Data(count: w * h)
            yData.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.baseAddress else { return }
                // Pack Y tightly: bytesPerRow = width
                for row in 0..<h {
                    let srcRow = yBase.advanced(by: row * yBpr)
                    memcpy(dstPtr.advanced(by: row * w), srcRow, w)
                }
            }

            var uvData = Data(count: w * uvH)
            uvData.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.baseAddress else { return }
                // Pack UV tightly: bytesPerRow = width (U,V,U,V,...)
                for row in 0..<uvH {
                    let srcRow = uvBase.advanced(by: row * uvBpr)
                    memcpy(dstPtr.advanced(by: row * w), srcRow, w)
                }
            }

            newFrame = StoredFrame(
                payload: .nv12(y: yData, uv: uvData), width: w, height: h, tsNs: now)

        case kCVPixelFormatType_32BGRA:
            // BGRA: pack tightly to width*4 per row (avoid platform-dependent stride).
            guard let base = CVPixelBufferGetBaseAddress(pixel) else { return false }
            let srcBpr = CVPixelBufferGetBytesPerRow(pixel)
            let tightBpr = w * 4

            var bgra = Data(count: h * tightBpr)
            bgra.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.baseAddress else { return }
                for row in 0..<h {
                    let srcRow = base.advanced(by: row * srcBpr)
                    memcpy(dstPtr.advanced(by: row * tightBpr), srcRow, tightBpr)
                }
            }

            newFrame = StoredFrame(
                payload: .bgra(bytes: bgra, bytesPerRow: tightBpr),
                width: w, height: h, tsNs: now)

        default:
            // Unsupported format – ignore.
            return false
        }

        guard let f = newFrame else { return false }
        last = f
        lastAcceptTsNs = now

        if let listener = onFrameListener,
            let map = buildPreviewFrameMap(copyBytes: copyBytesForCallback)
        {

            listener(map)
        }
        return true
    }

    /// Whether we have at least one cached frame.
    var hasFrame: Bool { return last != nil }

    /// Build a Dart-friendly map (`planes`) for the latest frame.
    /// - NV12 => 2 planes (Y and interleaved UV)
    /// - BGRA => 1 plane
    func buildPreviewFrameMap(copyBytes: Bool) -> [String: Any]? {
        guard let f = last else { return nil }

        let ySTD = FlutterStandardTypedData(bytes: copyBytes ? Data(f.y) : f.y)
        let uvSTD = FlutterStandardTypedData(bytes: copyBytes ? Data(f.uv) : f.uv)

        let yPlane: [String: Any] = [
            "bytes": ySTD, "bytesPerRow": f.width, "bytesPerPixel": 1,
            "width": f.width, "height": f.height,
        ]
        let uvPlane: [String: Any] = [
            "bytes": uvSTD, "bytesPerRow": f.width, "bytesPerPixel": 2,
            "width": f.width, "height": f.height / 2,
        ]

        var out: [String: Any] = [
            "format": Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            "width": f.width, "height": f.height, "planes": [yPlane, uvPlane],
        ]

        out["lensAperture"] = metaAperture ?? NSNull()
        out["sensorExposureTime"] = metaExposureTimeNs ?? NSNull()  // ns
        out["sensorSensitivity"] = metaIso ?? NSNull()

        return out
    }

    /// Save the latest frame as JPEG (no EXIF orientation). Rotation is applied in pixels.
    @discardableResult
    func writeJpeg(to outputPath: String, rotationDegrees: Int, quality: Int) throws -> String {
        guard let f = last else {
            throw NSError(
                domain: "LastFrameStore", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No frame available"])
        }

        let clampedQ = max(1, min(100, quality))

        let cgImage: CGImage
        switch f.payload {
        case let .nv12(y, uv):
            // Rebuild a CVPixelBuffer (NV12) and render with CoreImage.
            var pixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            let status = CVPixelBufferCreate(
                nil,
                f.width,
                f.height,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                attrs as CFDictionary,
                &pixelBuffer)
            guard status == kCVReturnSuccess, let pb = pixelBuffer else {
                throw NSError(
                    domain: "LastFrameStore", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "CVPixelBuffer create failed"])
            }

            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }

            guard
                let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)
            else {
                throw NSError(
                    domain: "LastFrameStore", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "CVPixelBuffer plane addr failed"])
            }

            (y as NSData).getBytes(yDst, length: y.count)
            (uv as NSData).getBytes(uvDst, length: uv.count)

            let ci = CIImage(cvPixelBuffer: pb)
            let rotated = orient(ci, by: rotationDegrees)
            let context = CIContext()
            guard
                let out = context.createCGImage(
                    rotated,
                    from: rotated.extent,
                    format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            else {
                throw NSError(
                    domain: "LastFrameStore", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "CI to CGImage failed"])
            }
            cgImage = out

        case let .bgra(bytes, bytesPerRow):
            // Create CGImage from tight BGRA buffer, then rotate via CI.
            guard let provider = CGDataProvider(data: bytes as CFData) else {
                throw NSError(
                    domain: "LastFrameStore", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "CGDataProvider failed"])
            }
            // BGRA: little-endian + premultipliedFirst (matches iOS memory layout).
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little)

            guard
                let base = CGImage(
                    width: f.width,
                    height: f.height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo,
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent)
            else {
                throw NSError(
                    domain: "LastFrameStore", code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "CGImage(BGRA) create failed"])
            }

            let ci = CIImage(cgImage: base)
            let rotated = orient(ci, by: rotationDegrees)
            let context = CIContext()
            guard
                let out = context.createCGImage(
                    rotated,
                    from: rotated.extent,
                    format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            else {
                throw NSError(
                    domain: "LastFrameStore", code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "CI to CGImage failed"])
            }
            cgImage = out
        }

        try writeCGImageAsJPEG(cgImage, to: outputPath, quality: clampedQ)
        return outputPath
    }

    // MARK: - Helpers

    /// Map degrees to CIImage orientation.
    private func orient(_ ci: CIImage, by deg: Int) -> CIImage {
        let d = (deg % 360 + 360) % 360
        switch d {
        case 90: return ci.oriented(.right)
        case 180: return ci.oriented(.down)
        case 270: return ci.oriented(.left)
        default: return ci
        }
    }

    private func writeCGImageAsJPEG(_ img: CGImage, to path: String, quality: Int) throws {
        let destType: CFString = "public.jpeg" as CFString

        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, destType, 1, nil) else {
            throw NSError(
                domain: "LastFrameStore",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "CGImageDestination create failed"]
            )
        }

        let q = max(1, min(100, quality))
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: CGFloat(q) / 100.0
        ]

        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(
                domain: "LastFrameStore",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "JPEG finalize failed"]
            )
        }
    }

}
