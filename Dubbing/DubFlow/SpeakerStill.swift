import AVFoundation
import Vision

nonisolated enum SpeakerStillError: LocalizedError, Equatable {
    case unreadableFrame(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .unreadableFrame(let seconds):
            "The frame at \(seconds.preciseClockString) couldn't be read for a role card."
        }
    }
}

/// A role card's still: one frame, cropped to the card around a character's face and kept inside the picture,
/// so letterbox bars stay out.
nonisolated enum SpeakerStill {
    /// Width over height of the role card.
    static let aspectRatio = 3.0 / 4.0
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

    /// The face whose centre is nearest `centerX`, if one is within `maximumOffset` of it; with no `centerX`, the
    /// largest face.
    static func chosenFace(_ faces: [CGRect], centerX: Double?, maximumOffset: Double) -> CGRect? {
        guard let centerX else {
            return faces.max { $0.width * $0.height < $1.width * $1.height }
        }
        return faces.filter { abs($0.midX - centerX) <= maximumOffset }.min { abs($0.midX - centerX) < abs($1.midX - centerX) }
    }

    /// A crop with `aspectRatio` inside `picture`. Around a face it zooms until the face fills a third of the
    /// height, but no further than 60% of the picture height so the still stays sharp, and puts the face in the
    /// upper part. Without a face it spans the picture's height around `centerX`. Whole pixels, top-left origin,
    /// for a `picture` in whole pixels.
    static func framing(face: CGRect?, centerX: Double, picture: CGRect, aspectRatio: Double) -> CGRect {
        var height = face.map { min(picture.height, max($0.height * 3, picture.height * 0.6)) } ?? picture.height
        var width = height * aspectRatio
        if width > picture.width {
            width = picture.width
            height = width / aspectRatio
        }
        let x = min(max(picture.minX, centerX - width / 2), picture.maxX - width)
        let y = face.map { min(max(picture.minY, $0.midY - height * 0.4), picture.maxY - height) } ?? picture.midY - height / 2
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: width.rounded(.down), height: height.rounded(.down))
    }

    /// The frame at `seconds`, cropped to a role card around the face nearest `faceCenterX` (a fraction of the
    /// frame width), or around the largest face when no position is given.
    @concurrent
    static func portrait(videoURL: URL, seconds: Double, faceCenterX: Double?) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_920, height: 1_920)
        // The card shows this exact moment, not a nearby keyframe that may be a different shot.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: mediaTime(seconds)).image
        let size = CGSize(width: frame.width, height: frame.height)
        let picture = try pictureArea(of: frame, seconds: seconds)
        let faces = try await onRunnableDevice(DetectFaceRectanglesRequest()).perform(on: frame)
            .map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
            .filter { picture.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        let hintX = faceCenterX.map { $0 * size.width }
        let face = chosenFace(faces, centerX: hintX, maximumOffset: size.width * 0.2)
        let crop = framing(face: face, centerX: face.map { Double($0.midX) } ?? hintX ?? Double(picture.midX), picture: picture, aspectRatio: aspectRatio)
        guard let still = frame.cropping(to: crop) else { throw SpeakerStillError.unreadableFrame(seconds: seconds) }
        return still
    }

    /// The picture area of a full frame in whole pixels, measured on a small grayscale copy. Each side where a
    /// bar was found is trimmed by one more measuring pixel, so the soft edge where it meets the picture stays out.
    private static func pictureArea(of frame: CGImage, seconds: Double) throws -> CGRect {
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
        guard drawn else { throw SpeakerStillError.unreadableFrame(seconds: seconds) }
        let found = pictureArea(luminance: luminance, width: width, height: height)
        let scale = Double(frame.width) / Double(width)
        let left = ((found.minX > 0 ? found.minX + 1 : 0) * scale).rounded(.up)
        let top = ((found.minY > 0 ? found.minY + 1 : 0) * scale).rounded(.up)
        let right = (found.maxX < Double(width) ? (found.maxX - 1) * scale : Double(frame.width)).rounded(.down)
        let bottom = (found.maxY < Double(height) ? (found.maxY - 1) * scale : Double(frame.height)).rounded(.down)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The Simulator can't run Vision's face models on a GPU or Neural Engine, so they run on its CPU there.
    private static func onRunnableDevice<Request: VisionRequest>(_ request: Request) -> Request {
        #if targetEnvironment(simulator)
        var request = request
        let cpu = request.supportedComputeStageDevices[.main]?.first { device in
            if case .cpu = device { true } else { false }
        }
        request.setComputeDevice(cpu, for: .main)
        return request
        #else
        return request
        #endif
    }
}
