import Foundation
import AVFoundation
import CoreImage
import ImageIO

/// Caches the last camera frame (NV12 or 32BGRA) and exposes helpers
/// to build a Flutter map and to write JPEGs.
final class LastFrameStore {

    // MARK: - Cached frame

    struct StoredFrame {
        enum Payload {
            case nv12(y: Data, uv: Data)              // tightly packed: yBPR = width, uvBPR = width
            case bgra(bytes: Data, bytesPerRow: Int)  // tightly packed: bpr = width * 4
        }
        let payload: Payload
        let width: Int
        let height: Int
        let tsNs: UInt64
    }

    // MARK: - Public hooks

    /// Called after `accept(...)` if a frame was cached successfully.
    /// Provides a Flutter-compatible map (format/width/height/planes/etc).
    var onFrameListener: (([String: Any]) -> Void)?

    /// Whether to copy `Data` objects when producing the Flutter map.
    var copyBytesForCallback: Bool = true

    // You can still update these, but we do NOT embed EXIF anymore.
    var metaAperture: Double?
    var metaExposureTimeNs: Int64?
    var metaIso: Double?

    // MARK: - Internals

    private(set) var last: StoredFrame?
    private var lastAcceptTsNs: UInt64 = 0

    /// Throttling between accepts (nanoseconds). 10ms by default.
    var defaultMinIntervalNs: UInt64 = 10_000_000

    // MARK: - Accept a sample buffer and cache a tightly packed copy

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

            let yBpr  = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
            let uvH   = h / 2

            // Pack Y tightly: bytesPerRow = width
            var yData = Data(count: w * h)
            yData.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.baseAddress else { return }
                for row in 0..<h {
                    let srcRow = yBase.advanced(by: row * yBpr)
                    memcpy(dstPtr.advanced(by: row * w), srcRow, w)
                }
            }

            // Pack UV tightly: bytesPerRow = width (U,V,U,V,...)
            var uvData = Data(count: w * uvH)
            uvData.withUnsafeMutableBytes { dst in
                guard let dstPtr = dst.baseAddress else { return }
                for row in 0..<uvH {
                    let srcRow = uvBase.advanced(by: row * uvBpr)
                    memcpy(dstPtr.advanced(by: row * w), srcRow, w)
                }
            }

            newFrame = StoredFrame(
                payload: .nv12(y: yData, uv: uvData),
                width: w, height: h, tsNs: now
            )

        case kCVPixelFormatType_32BGRA:
            // Pack BGRA tightly to width*4 per row
            guard let base = CVPixelBufferGetBaseAddress(pixel) else { return false }
            let srcBpr   = CVPixelBufferGetBytesPerRow(pixel)
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
                width: w, height: h, tsNs: now
            )

        default:
            // Unsupported format – ignore.
            return false
        }

        guard let f = newFrame else { return false }
        last = f
        lastAcceptTsNs = now

        if let listener = onFrameListener,
           let map = buildPreviewFrameMap(copyBytes: copyBytesForCallback) {
            listener(map)
        }
        return true
    }

    // MARK: - Build Flutter map

    /// Builds a Flutter-standard map for the last stored frame.
    /// For NV12: two planes (Y and interleaved UV). For BGRA: one plane.
    func buildPreviewFrameMap(copyBytes: Bool) -> [String: Any]? {
        guard let f = last else { return nil }

        switch f.payload {
        case let .nv12(y, uv):
            let yBytes  = copyBytes ? Data(y)  : y
            let uvBytes = copyBytes ? Data(uv) : uv

            let ySTD  = FlutterStandardTypedData(bytes: yBytes)
            let uvSTD = FlutterStandardTypedData(bytes: uvBytes)

            let yPlane: [String: Any] = [
                "bytes": ySTD, "bytesPerRow": f.width, "bytesPerPixel": 1,
                "width": f.width, "height": f.height,
            ]
            let uvPlane: [String: Any] = [
                "bytes": uvSTD, "bytesPerRow": f.width, "bytesPerPixel": 2,
                "width": f.width, "height": f.height / 2,
            ]

            return [
                "format": Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                "width": f.width,
                "height": f.height,
                "planes": [yPlane, uvPlane],
            ]

        case let .bgra(bytes, bytesPerRow):
            let data = copyBytes ? Data(bytes) : bytes
            let std  = FlutterStandardTypedData(bytes: data)

            let plane: [String: Any] = [
                "bytes": std, "bytesPerRow": bytesPerRow, "bytesPerPixel": 4,
                "width": f.width, "height": f.height,
            ]
            return [
                "format": Int(kCVPixelFormatType_32BGRA),
                "width": f.width, "height": f.height,
                "planes": [plane],
            ]
        }
    }

    // MARK: - Metadata (kept for compatibility; not embedded to JPEG)

    func updateMetadata(aperture: Double?, exposureTimeNs: Int64?, iso: Double?) {
        self.metaAperture = aperture
        self.metaExposureTimeNs = exposureTimeNs
        self.metaIso = iso
    }
    func updateMetadata(aperture: Double?, exposureTimeSeconds: Double?, iso: Double?) {
        let ns = exposureTimeSeconds.map { Int64($0 * 1_000_000_000.0) }
        updateMetadata(aperture: aperture, exposureTimeNs: ns, iso: iso)
    }
    func updateMetadata(aperture: Double?, exposureDuration: CMTime?, iso: Double?) {
        let ns: Int64?
        if let t = exposureDuration, t.isNumeric && t.timescale != 0 {
            ns = Int64((Double(t.value) / Double(t.timescale)) * 1_000_000_000.0)
        } else { ns = nil }
        updateMetadata(aperture: aperture, exposureTimeNs: ns, iso: iso)
    }

    // MARK: - JPEG writing (path + rotation, no EXIF)

    enum JPEGError: Error {
        case noFrame
        case cannotCreateDestination
        case finalizeFailed
    }

    /// Writes the last frame to a JPEG file by path, with optional rotation.
    /// - Parameters:
    ///   - path: destination file path
    ///   - rotationDegrees: 0 / 90 / 180 / 270 (clockwise)
    ///   - quality: 0...100
    /// - Returns: the same `path` on success
    @discardableResult
    func writeJpeg(to path: String, rotationDegrees: Int = 0, quality: Int = 92) throws -> String {
        guard let f = last, let cg = makeCGImage(from: f) else { throw JPEGError.noFrame }

        // Clamp quality to 0...100 and convert to 0...1
        let qq = max(0, min(100, quality))
        let qf = CGFloat(qq) / 100.0

        // Make sure directory exists
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // Apply rotation via CoreImage (no EXIF tags, real pixel rotation)
        let rotatedCG = try rotate(cgImage: cg, degrees: rotationDegrees)

        // Use "public.jpeg" UTI directly
        let jpegUTI: CFString = "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, jpegUTI, 1, nil) else {
            throw JPEGError.cannotCreateDestination
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: qf
        ]
        CGImageDestinationAddImage(dest, rotatedCG, options as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw JPEGError.finalizeFailed
        }
        return path
    }

    /// Legacy convenience wrapper (non-throwing). Returns true on success.
    @discardableResult
    func writeJpeg(path: String, quality: CGFloat = 0.92) -> Bool {
        do {
            _ = try writeJpeg(to: path,
                              rotationDegrees: 0,
                              quality: Int(round(quality * 100)))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Rotation

private func rotate(cgImage: CGImage, degrees: Int) throws -> CGImage {
    let norm = ((degrees % 360) + 360) % 360
    if norm == 0 {
        return cgImage
    }

    // Use CIImage to rotate by 90/180/270 without EXIF.
    let ci = CIImage(cgImage: cgImage)
    let oriented: CIImage
    switch norm {
    case 90:  oriented = ci.oriented(.right)  // 90° CW
    case 180: oriented = ci.oriented(.down)   // 180°
    case 270: oriented = ci.oriented(.left)   // 270° CW (i.e., 90° CCW)
    default:
        // Fallback for non-right-angle values: rotate arbitrary angle.
        oriented = ci.transformed(by: CGAffineTransform(rotationAngle: CGFloat(norm) * .pi / 180))
    }
    let ctx = CIContext(options: nil)
    guard let out = ctx.createCGImage(oriented, from: oriented.extent) else {
        throw LastFrameStore.JPEGError.finalizeFailed
    }
    return out
}

// MARK: - CGImage construction

private func makeCGImage(from f: LastFrameStore.StoredFrame) -> CGImage? {
    switch f.payload {
    case let .bgra(bytes, bytesPerRow):
        // Direct BGRA -> CGImage
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()

        // bitmapInfo = byteOrder32Little + premultipliedFirst alpha
        let alpha = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(alpha)

        return CGImage(
            width: f.width,
            height: f.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )

    case let .nv12(y, uv):
        // Rebuild a temporary NV12 CVPixelBuffer from tightly-packed planes,
        // then render to CGImage via CoreImage.
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [ kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary ]
        guard CVPixelBufferCreate(
            nil, f.width, f.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attrs as CFDictionary, &pb
        ) == kCVReturnSuccess, let pixel = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }

        guard
            let yBase  = CVPixelBufferGetBaseAddressOfPlane(pixel, 0),
            let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)
        else { return nil }

        let yDstBpr  = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        let uvDstBpr = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1)
        let uvH = f.height / 2

        y.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return }
            for row in 0..<f.height {
                memcpy(yBase.advanced(by: row * yDstBpr),
                       srcPtr.advanced(by: row * f.width),
                       f.width)
            }
        }
        uv.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return }
            for row in 0..<uvH {
                memcpy(uvBase.advanced(by: row * uvDstBpr),
                       srcPtr.advanced(by: row * f.width),
                       f.width)
            }
        }

        let ci = CIImage(cvPixelBuffer: pixel)
        let ctx = CIContext(options: nil)
        return ctx.createCGImage(ci, from: ci.extent)
    }
}
