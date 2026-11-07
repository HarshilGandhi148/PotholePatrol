import CoreGraphics
import Foundation

/// Decides when a tracked object is certain enough to photograph and report, and makes sure each is reported once.
///
/// Showing a box is cheap to get wrong, but a report reaches other people, so this asks for more than `DetectionTracker`
/// does. The object must have stayed tracked for a while, score well, be fully in frame, and have a measured location.
public final class LiveReportGate {
  public struct Settings {
    public var minimumTrackedTime: TimeInterval = 1
    public var minimumConfidence: Float = 0.5
    /// Anything closer than this to an earlier capture, in meters, is taken to be the same object seen again. Keep this
    /// small enough for potholes close together to count separately, but above the wobble in measured locations.
    public var minimumSeparation = 3.0
    /// A box this close to the frame's edge, as a fraction of the frame, may be cut off in the photo.
    public var edgeMargin: CGFloat = 0.01

    public init() {}
  }

  private let settings: Settings
  private var handledIDs = Set<Int>()
  private var reportedCoordinates = [GeoCoordinate]()

  public init(settings: Settings = Settings()) {
    self.settings = settings
  }

  /// Whether any of these objects could still be reported, so the next frame's image needs to be kept.
  public func wantsPhoto(of tracks: [TrackedDetection]) -> Bool {
    tracks.contains { !handledIDs.contains($0.id) }
  }

  /// Whether to report this object using the current frame.
  public func shouldReport(_ track: TrackedDetection, at coordinate: GeoCoordinate?) -> Bool {
    guard !handledIDs.contains(track.id), track.trackedTime >= settings.minimumTrackedTime,
      track.confidence >= settings.minimumConfidence, let rect = track.measuredRect,
      isFullyInFrame(rect), let coordinate
    else { return false }

    if reportedCoordinates.contains(where: { $0.distance(to: coordinate) < settings.minimumSeparation }) {
      handledIDs.insert(track.id)
      return false
    }
    return true
  }

  /// How much of the frame this object fills, if this frame would make a good photo of it. The larger this is, the
  /// closer the camera is, so a captured object's photo can be replaced whenever this grows.
  public func photoArea(of track: TrackedDetection) -> CGFloat? {
    guard track.confidence >= settings.minimumConfidence, let rect = track.measuredRect,
      isFullyInFrame(rect)
    else { return nil }
    return track.rect.width * track.rect.height
  }

  public func markReported(_ track: TrackedDetection, at coordinate: GeoCoordinate) {
    handledIDs.insert(track.id)
    reportedCoordinates.append(coordinate)
  }

  private func isFullyInFrame(_ rect: CGRect) -> Bool {
    let margin = settings.edgeMargin
    return rect.minX >= margin && rect.minY >= margin && rect.maxX <= 1 - margin
      && rect.maxY <= 1 - margin
  }
}
