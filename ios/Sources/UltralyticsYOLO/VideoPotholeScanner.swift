import AVFoundation
import CoreImage
import Foundation
import simd

/// Reads an upright video frame by frame, at a limited rate, for detection.
@available(iOS 15.0, macOS 12.0, *)
public final class VideoFrameReader {
  public let duration: TimeInterval
  public let creationDate: Date?
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let orientation: CGImagePropertyOrientation
  private let frameInterval: TimeInterval
  private let maximumSide: CGFloat
  private var nextFrameTime: TimeInterval = 0

  public init(url: URL, framesPerSecond: Double = 10, maximumSide: CGFloat = 1280) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let transform = try await track.load(.preferredTransform)
    duration = try await asset.load(.duration).seconds
    let date = try? await asset.load(.creationDate)
    creationDate = try? await date?.load(.dateValue)
    reader = try AVAssetReader(asset: asset)
    output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
    orientation = Self.orientation(of: transform)
    frameInterval = 1 / framesPerSecond
    self.maximumSide = maximumSide
  }

  /// The next frame due, or `nil` at the end of the video.
  public func nextFrame() -> (image: CIImage, time: TimeInterval)? {
    while let sample = output.copyNextSampleBuffer() {
      let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      guard time >= nextFrameTime, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
      nextFrameTime = time + frameInterval
      let upright = CIImage(cvPixelBuffer: buffer).oriented(orientation)
      let scale = min(maximumSide / max(upright.extent.width, upright.extent.height), 1)
      let scaled = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      return (scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY)), time)
    }
    return nil
  }

  /// Phones store video sideways, with a transform saying how to turn it upright.
  private static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
    switch (transform.a, transform.b, transform.c, transform.d) {
    case (0, 1, -1, 0): return .right
    case (0, -1, 1, 0): return .left
    case (-1, 0, 0, -1): return .down
    default: return .up
    }
  }
}

/// A pothole found in a video, with the closest photo of it so far.
public struct VideoPothole {
  public let id: Int
  public var photo: CGImage
  public var photoArea: CGFloat
  /// Seconds into the video when `photo` was taken.
  public var time: TimeInterval
  /// `nil` if the pothole was never measured, such as when it stayed more than 8 m away.
  public var size: EstimatedSize?
}

/// Finds potholes in a video using the same checks as Live Scan.
///
/// A video has no GPS or motion data, so the person chooses its location, and size depends on the height and tilt they
/// enter. Every pothole shares that one location, so location can't count toward whether a pothole is certain or tell
/// two potholes apart.
public final class VideoPotholeScanner {
  public private(set) var potholes = [VideoPothole]()
  private let tracker = DetectionTracker()
  private let sizeEstimator = ObjectSizeEstimator()
  private let gate: LiveReportGate
  private let context = CIContext()
  private let height: Double
  private let tiltDegrees: Double
  private let fieldOfViewDegrees: Double
  private let maximumPotholes = 30
  /// Stands in for the location `LiveReportGate` requires, since nothing about it can vary here.
  private let anyCoordinate = GeoCoordinate(latitude: 0, longitude: 0)

  /// - Parameters:
  ///   - height: The camera's height above the road, in meters.
  ///   - tiltDegrees: How far below level the camera points.
  ///   - fieldOfViewDegrees: Across the long side of the frame. The default is roughly an iPhone's main camera in video.
  public init(height: Double, tiltDegrees: Double, fieldOfViewDegrees: Double = 69) {
    self.height = height
    self.tiltDegrees = tiltDegrees
    self.fieldOfViewDegrees = fieldOfViewDegrees
    var settings = LiveReportGate.Settings()
    settings.minimumSeparation = 0
    gate = LiveReportGate(settings: settings)
  }

  /// Advances by one frame, and returns the steady boxes to display.
  public func process(
    _ detections: [TrackerDetection], in image: CIImage, at time: TimeInterval, appearThreshold: Float = 0.25
  ) -> [TrackedDetection] {
    let tracks = tracker.update(detections, at: time, appearThreshold: appearThreshold)
    let camera = camera(for: image.extent.size)
    sizeEstimator.retain(ids: Set(tracks.map(\.id)))

    for track in tracks {
      if let rect = track.measuredRect {
        sizeEstimator.add(id: track.id, rect: rect, imageSize: image.extent.size, camera: camera, rotationRate: 0)
      }
      if let index = potholes.firstIndex(where: { $0.id == track.id }) {
        if let size = sizeEstimator.size(id: track.id) { potholes[index].size = size }
        if let area = gate.photoArea(of: track), area > potholes[index].photoArea,
          let photo = context.createCGImage(image, from: image.extent)
        {
          potholes[index].photo = photo
          potholes[index].photoArea = area
          potholes[index].time = time
        }
      } else if potholes.count < maximumPotholes, gate.shouldReport(track, at: anyCoordinate),
        let area = gate.photoArea(of: track), let photo = context.createCGImage(image, from: image.extent)
      {
        gate.markReported(track, at: anyCoordinate)
        potholes.append(
          VideoPothole(
            id: track.id, photo: photo, photoArea: area, time: time,
            size: sizeEstimator.size(id: track.id)))
      }
    }
    return tracks
  }

  /// The size estimate for a box on screen, if there's one yet.
  public func size(ofTrack id: Int) -> EstimatedSize? {
    sizeEstimator.size(id: id)
  }

  public func removeAllPotholes() {
    potholes.removeAll()
  }

  private func camera(for size: CGSize) -> GroundPlaneCamera {
    let focal = Double(max(size.width, size.height)) / 2 / tan(fieldOfViewDegrees * .pi / 360)
    let tilt = tiltDegrees * .pi / 180
    return GroundPlaneCamera(
      intrinsics: CameraIntrinsics(
        fx: focal, fy: focal, cx: Double(size.width) / 2, cy: Double(size.height) / 2),
      down: SIMD3(0, cos(tilt), sin(tilt)), height: height)
  }
}
