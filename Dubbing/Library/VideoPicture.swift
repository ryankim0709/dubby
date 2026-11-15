import CoreGraphics
import Foundation

nonisolated enum VideoPictureError: LocalizedError, Equatable {
    case unreadableFrame(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .unreadableFrame(let seconds):
            "The frame at \(seconds.preciseClockString) couldn't be read."
        }
    }
}

/// A browse frame and its picture bounds, shared by still artwork and fill-sized video.
nonisolated struct VideoPicture: Sendable {
    let image: CGImage
    let sourceSize: CGSize
    let area: CGRect

    init(frame: CGImage, seconds: Double) throws {
        let area = try Self.pictureArea(of: frame, seconds: seconds)
        guard let image = frame.cropping(to: area) else { throw VideoPictureError.unreadableFrame(seconds: seconds) }
        self.image = image
        sourceSize = CGSize(width: frame.width, height: frame.height)
        self.area = area
    }

    func playerFrame(in bounds: CGRect) -> CGRect {
        // Round the fill scale outward so floating-point arithmetic cannot leave an edge uncovered.
        let scale = max(bounds.width / area.width, bounds.height / area.height).nextUp
        return CGRect(
            x: bounds.midX - area.midX * scale,
            y: bounds.midY - area.midY * scale,
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
    }

    /// Brightest a bar's pixels may be, out of 255; bars are black apart from compression noise.
    static let barLuminance: UInt8 = 24
    /// Width of the grayscale copy that bars are measured on.
    private static let measuringWidth = 320

    /// The rows and columns of a grayscale image that hold picture, without the black bars at its edges, in
    /// pixels with the origin at the top left. An image that is all black is returned whole.
    static func pictureArea(luminance: [UInt8], width: Int, height: Int) -> CGRect {
        func holdsPicture(_ values: some Sequence<UInt8>) -> Bool { values.contains { $0 > barLuminance } }
        let rows = (0..<height).filter { holdsPicture(luminance[($0 * width)..<(($0 + 1) * width)]) }
        let columns = (0..<width).filter { column in holdsPicture(stride(from: column, to: width * height, by: width).lazy.map { luminance[$0] }) }
        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    /// The picture area of a full frame in whole pixels, measured on a small grayscale copy. Each side where a
    /// bar was found is trimmed by one more measuring pixel, so the soft edge where it meets the picture stays out.
    static func pictureArea(of frame: CGImage, seconds: Double) throws -> CGRect {
        let width = measuringWidth
        let height = max(1, Int((Double(frame.height) * Double(width) / Double(frame.width)).rounded()))
        var luminance = [UInt8](repeating: 0, count: width * height)
        let drawn = luminance.withUnsafeMutableBytes { pixels -> Bool in
            guard let context = CGContext(
                data: pixels.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw VideoPictureError.unreadableFrame(seconds: seconds) }
        let found = pictureArea(luminance: luminance, width: width, height: height)
        let scale = Double(frame.width) / Double(width)
        let left = ((found.minX > 0 ? found.minX + 1 : 0) * scale).rounded(.up)
        let top = ((found.minY > 0 ? found.minY + 1 : 0) * scale).rounded(.up)
        let right = (found.maxX < Double(width) ? (found.maxX - 1) * scale : Double(frame.width)).rounded(.down)
        let bottom = (found.maxY < Double(height) ? (found.maxY - 1) * scale : Double(frame.height)).rounded(.down)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
