import AVFoundation
import Vision

/// A role card's still: one frame, cropped to the card around a character's face and kept inside the picture,
/// so letterbox bars stay out.
nonisolated enum SpeakerStill {
    /// Width over height of the role card.
    static let aspectRatio = 3.0 / 4.0

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
        let picture = try VideoPicture.pictureArea(of: frame, seconds: seconds)
        let faces = try await onRunnableDevice(DetectFaceRectanglesRequest()).perform(on: frame)
            .map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
            .filter { picture.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        let hintX = faceCenterX.map { $0 * size.width }
        let face = chosenFace(faces, centerX: hintX, maximumOffset: size.width * 0.2)
        let crop = framing(face: face, centerX: face.map { Double($0.midX) } ?? hintX ?? Double(picture.midX), picture: picture, aspectRatio: aspectRatio)
        guard let still = frame.cropping(to: crop) else { throw VideoPictureError.unreadableFrame(seconds: seconds) }
        return still
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
