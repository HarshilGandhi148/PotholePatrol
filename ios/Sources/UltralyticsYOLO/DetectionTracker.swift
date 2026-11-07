import CoreGraphics
import Foundation

/// One raw detection from a single frame, in normalized image coordinates.
public struct TrackerDetection {
  public let rect: CGRect
  public let confidence: Float
  public let classIndex: Int
  public let className: String

  public init(rect: CGRect, confidence: Float, classIndex: Int, className: String) {
    self.rect = rect
    self.confidence = confidence
    self.classIndex = classIndex
    self.className = className
  }
}

/// A confirmed object to display. It keeps the same `id` for as long as the tracker follows it.
public struct TrackedDetection {
  public let id: Int
  /// Smoothed box in normalized image coordinates, clipped to the frame.
  public let rect: CGRect
  public let confidence: Float
  public let classIndex: Int
  public let className: String
  /// This frame's unsmoothed box, or `nil` while the track is being held through a missed detection.
  public let measuredRect: CGRect?
  /// How long the tracker has been following this object, in seconds.
  public let trackedTime: TimeInterval
}

/// Turns per-frame detections into steady boxes, so a detection that blinks in and out doesn't make its box flicker.
///
/// A new object must be seen several times before it is shown, then stays until it has been missing for `holdDuration`.
/// Timing is in seconds, so behavior doesn't depend on the frame rate.
public final class DetectionTracker {
  public struct Settings {
    /// A shown object stays while its score is above the appear threshold minus this margin.
    public var confidenceMargin: Float = 0.10
    /// How many strong detections are needed within `confirmationWindow` before an object is shown.
    public var confirmations = 3
    public var confirmationWindow: TimeInterval = 0.5
    /// A detection only counts toward `confirmations` if its width and height are each within this factor of the
    /// previous strong detection. Comparing neighbors allows for boxes growing as the camera approaches.
    public var maximumSizeChange: CGFloat = 1.5
    /// How long a shown object survives without a detection.
    public var holdDuration: TimeInterval = 0.5
    /// Time constant of the box smoothing. Larger is steadier but lags more.
    public var smoothingTime: TimeInterval = 0.12
    public var minimumMatchIoU: CGFloat = 0.2
    public var duplicateIoU: CGFloat = 0.5
    /// Limit on predicted movement, in image widths or heights per second.
    public var maximumSpeed: CGFloat = 2

    public init() {}
  }

  private struct Track {
    let id: Int
    let classIndex: Int
    let className: String
    let firstSeen: TimeInterval
    var rect: CGRect
    var confidence: Float
    var velocity = CGVector.zero
    var sizeVelocity = CGVector.zero
    var isConfirmed = false
    var strongHits: [TimeInterval]
    var lastStrongRect: CGRect
    var lastSeen: TimeInterval
    var lastMeasuredRect: CGRect
    var lastMeasuredTime: TimeInterval
    var measuredRect: CGRect?
  }

  private let settings: Settings
  private var tracks = [Track]()
  private var nextID = 0
  private var lastTime: TimeInterval?

  public init(settings: Settings = Settings()) {
    self.settings = settings
  }

  public func reset() {
    tracks.removeAll()
    lastTime = nil
  }

  /// Advances the tracker by one frame and returns the objects to display, ordered by `id`.
  public func update(
    _ detections: [TrackerDetection], at time: TimeInterval, appearThreshold: Float
  ) -> [TrackedDetection] {
    let elapsed = max(time - (lastTime ?? time), 0)
    lastTime = time
    let stayThreshold = max(appearThreshold - settings.confidenceMargin, 0)

    for index in tracks.indices {
      tracks[index].rect = predictedRect(for: tracks[index], after: elapsed)
      tracks[index].measuredRect = nil
    }

    let smoothing = CGFloat(1 - exp(-elapsed / settings.smoothingTime))
    var isMatched = [Bool](repeating: false, count: detections.count)
    for (trackIndex, detectionIndex) in matches(between: tracks, and: detections) {
      isMatched[detectionIndex] = true
      apply(
        detections[detectionIndex], toTrackAt: trackIndex, at: time, smoothing: smoothing,
        appearThreshold: appearThreshold, stayThreshold: stayThreshold)
    }

    // Weak detections keep a known object alive, but can't start a new one.
    for (index, detection) in detections.enumerated()
    where !isMatched[index] && detection.confidence >= appearThreshold {
      startTrack(for: detection, at: time)
    }

    removeExpiredTracks(at: time)
    removeDuplicateTracks()

    let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    return tracks.filter(\.isConfirmed).compactMap { track in
      let clipped = track.rect.intersection(frame)
      guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
      return TrackedDetection(
        id: track.id, rect: clipped, confidence: track.confidence, classIndex: track.classIndex,
        className: track.className, measuredRect: track.measuredRect,
        trackedTime: time - track.firstSeen)
    }
  }

  private func predictedRect(for track: Track, after elapsed: TimeInterval) -> CGRect {
    let time = CGFloat(elapsed)
    let width = max(track.rect.width + track.sizeVelocity.dx * time, 0.001)
    let height = max(track.rect.height + track.sizeVelocity.dy * time, 0.001)
    let centerX = track.rect.midX + track.velocity.dx * time
    let centerY = track.rect.midY + track.velocity.dy * time
    return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
  }

  /// Pairs tracks with detections, best overlap first. Fast-moving objects can have no overlap with their predicted
  /// position, so nearby boxes of a similar size can also match, but only after every overlapping pair.
  private func matches(
    between tracks: [Track], and detections: [TrackerDetection]
  ) -> [(track: Int, detection: Int)] {
    var candidates = [(track: Int, detection: Int, score: CGFloat)]()
    for (trackIndex, track) in tracks.enumerated() {
      for (detectionIndex, detection) in detections.enumerated()
      where detection.classIndex == track.classIndex {
        if let score = matchScore(track.rect, detection.rect) {
          candidates.append((trackIndex, detectionIndex, score))
        }
      }
    }

    var usedTracks = Set<Int>()
    var usedDetections = Set<Int>()
    var result = [(track: Int, detection: Int)]()
    for candidate in candidates.sorted(by: { $0.score > $1.score })
    where !usedTracks.contains(candidate.track) && !usedDetections.contains(candidate.detection) {
      usedTracks.insert(candidate.track)
      usedDetections.insert(candidate.detection)
      result.append((candidate.track, candidate.detection))
    }
    return result
  }

  /// Overlap scores are at least `minimumMatchIoU`. Proximity scores stay below it, so overlap always wins.
  private func matchScore(_ predicted: CGRect, _ detected: CGRect) -> CGFloat? {
    let overlap = intersectionOverUnion(predicted, detected)
    if overlap >= settings.minimumMatchIoU { return overlap }

    let largestSide = max(predicted.width, predicted.height, detected.width, detected.height)
    let distance = hypot(predicted.midX - detected.midX, predicted.midY - detected.midY)
    let limit = largestSide * 0.75
    let areaRatio =
      (predicted.width * predicted.height) / max(detected.width * detected.height, .leastNonzeroMagnitude)
    guard distance < limit, areaRatio > 0.25, areaRatio < 4 else { return nil }
    return settings.minimumMatchIoU * 0.99 * (1 - distance / limit)
  }

  private func apply(
    _ detection: TrackerDetection, toTrackAt index: Int, at time: TimeInterval, smoothing: CGFloat,
    appearThreshold: Float, stayThreshold: Float
  ) {
    var track = tracks[index]
    track.rect = interpolate(from: track.rect, to: detection.rect, by: smoothing)
    track.confidence += (detection.confidence - track.confidence) * Float(smoothing)
    updateVelocity(of: &track, with: detection.rect, at: time)

    if detection.confidence >= appearThreshold {
      if !isSimilarSize(detection.rect, track.lastStrongRect) { track.strongHits.removeAll() }
      track.lastStrongRect = detection.rect
      track.strongHits.append(time)
      track.strongHits.removeAll { time - $0 > settings.confirmationWindow }
      if track.strongHits.count >= settings.confirmations { track.isConfirmed = true }
    }
    if detection.confidence >= stayThreshold {
      track.lastSeen = time
      track.measuredRect = detection.rect
    }
    tracks[index] = track
  }

  private func isSimilarSize(_ first: CGRect, _ second: CGRect) -> Bool {
    let widthChange = max(first.width, second.width) / max(min(first.width, second.width), .leastNonzeroMagnitude)
    let heightChange = max(first.height, second.height) / max(min(first.height, second.height), .leastNonzeroMagnitude)
    return widthChange <= settings.maximumSizeChange && heightChange <= settings.maximumSizeChange
  }

  private func updateVelocity(of track: inout Track, with rect: CGRect, at time: TimeInterval) {
    let elapsed = CGFloat(time - track.lastMeasuredTime)
    guard elapsed > 0.001 else { return }

    let previous = track.lastMeasuredRect
    let measured = CGVector(
      dx: limited((rect.midX - previous.midX) / elapsed),
      dy: limited((rect.midY - previous.midY) / elapsed))
    let measuredSize = CGVector(
      dx: limited((rect.width - previous.width) / elapsed),
      dy: limited((rect.height - previous.height) / elapsed))
    track.velocity = CGVector(
      dx: (track.velocity.dx + measured.dx) / 2, dy: (track.velocity.dy + measured.dy) / 2)
    track.sizeVelocity = CGVector(
      dx: (track.sizeVelocity.dx + measuredSize.dx) / 2,
      dy: (track.sizeVelocity.dy + measuredSize.dy) / 2)
    track.lastMeasuredRect = rect
    track.lastMeasuredTime = time
  }

  private func limited(_ speed: CGFloat) -> CGFloat {
    min(max(speed, -settings.maximumSpeed), settings.maximumSpeed)
  }

  private func startTrack(for detection: TrackerDetection, at time: TimeInterval) {
    tracks.append(
      Track(
        id: nextID, classIndex: detection.classIndex, className: detection.className,
        firstSeen: time, rect: detection.rect, confidence: detection.confidence, strongHits: [time],
        lastStrongRect: detection.rect, lastSeen: time, lastMeasuredRect: detection.rect, lastMeasuredTime: time, measuredRect: detection.rect))
    nextID += 1
    if settings.confirmations <= 1 { tracks[tracks.count - 1].isConfirmed = true }
  }

  private func removeExpiredTracks(at time: TimeInterval) {
    tracks.removeAll { track in
      if !track.isConfirmed {
        return time - (track.strongHits.last ?? track.lastSeen) > settings.confirmationWindow
      }
      let isGone = time - track.lastSeen > settings.holdDuration
      let hasLeftFrame =
        track.rect.midX < 0 || track.rect.midX > 1 || track.rect.midY < 0 || track.rect.midY > 1
      return isGone || hasLeftFrame
    }
  }

  /// Keeps one track when two follow the same object: a confirmed one over an unconfirmed one, then the older one.
  private func removeDuplicateTracks() {
    let ranked = tracks.sorted {
      $0.isConfirmed != $1.isConfirmed ? $0.isConfirmed : $0.id < $1.id
    }
    var kept = [Track]()
    for track in ranked
    where !kept.contains(where: { keptTrack in
      intersectionOverUnion(keptTrack.rect, track.rect) >= settings.duplicateIoU
    }) {
      kept.append(track)
    }
    tracks = kept.sorted { $0.id < $1.id }
  }

  private func interpolate(from start: CGRect, to end: CGRect, by amount: CGFloat) -> CGRect {
    CGRect(
      x: start.minX + (end.minX - start.minX) * amount,
      y: start.minY + (end.minY - start.minY) * amount,
      width: start.width + (end.width - start.width) * amount,
      height: start.height + (end.height - start.height) * amount)
  }

  private func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> CGFloat {
    let overlap = first.intersection(second)
    guard !overlap.isNull else { return 0 }
    let overlapArea = overlap.width * overlap.height
    let unionArea = first.width * first.height + second.width * second.height - overlapArea
    return unionArea > 0 ? overlapArea / unionArea : 0
  }
}
