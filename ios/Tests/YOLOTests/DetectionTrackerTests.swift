import XCTest

@testable import UltralyticsYOLO

final class DetectionTrackerTests: XCTestCase {
  private let frameTime: TimeInterval = 1.0 / 15
  private let pothole = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.1)

  private func detection(_ rect: CGRect, _ confidence: Float = 0.6) -> TrackerDetection {
    TrackerDetection(rect: rect, confidence: confidence, classIndex: 0, className: "pothole")
  }

  /// Runs one frame per entry, where `nil` means the model found nothing, and returns what was shown after each.
  private func run(
    _ tracker: DetectionTracker, _ frames: [TrackerDetection?], startingAt start: Int = 0
  ) -> [[TrackedDetection]] {
    frames.enumerated().map { index, detection in
      tracker.update(
        detection.map { [$0] } ?? [], at: TimeInterval(start + index) * frameTime,
        appearThreshold: 0.25)
    }
  }

  func testSingleFrameDetectionNeverShows() {
    let shown = run(DetectionTracker(), [detection(pothole)] + Array(repeating: nil, count: 20))
    XCTAssertTrue(shown.allSatisfy(\.isEmpty))
  }

  func testShowsOnThirdDetection() {
    let shown = run(DetectionTracker(), Array(repeating: detection(pothole), count: 3))
    XCTAssertEqual(shown.map(\.count), [0, 0, 1])
  }

  func testDetectionsTooFarApartNeverConfirm() {
    let frames: [TrackerDetection?] = (0..<30).map { $0 % 10 == 0 ? detection(pothole) : nil }
    XCTAssertTrue(run(DetectionTracker(), frames).allSatisfy(\.isEmpty))
  }

  func testShortMissDoesNotHideBox() {
    let tracker = DetectionTracker()
    _ = run(tracker, Array(repeating: detection(pothole), count: 3))
    let shown = run(tracker, [nil, nil, detection(pothole)], startingAt: 3)
    XCTAssertEqual(shown.map(\.count), [1, 1, 1])
    XCTAssertEqual(Set(shown.flatMap { $0.map(\.id) }).count, 1)
  }

  func testHeldBoxHasNoMeasurement() {
    let tracker = DetectionTracker()
    let confirmed = run(tracker, Array(repeating: detection(pothole), count: 3))
    XCTAssertNotNil(confirmed[2][0].measuredRect)
    XCTAssertNil(run(tracker, [nil], startingAt: 3)[0][0].measuredRect)
  }

  func testScoreBetweenThresholdsDoesNotToggle() {
    let tracker = DetectionTracker()
    _ = run(tracker, Array(repeating: detection(pothole), count: 3))
    let scores: [Float] = (0..<30).map { $0 % 2 == 0 ? 0.26 : 0.16 }
    let shown = run(tracker, scores.map { detection(pothole, $0) }, startingAt: 3)
    XCTAssertTrue(shown.allSatisfy { $0.count == 1 })
  }

  func testScoreBelowStayThresholdExpires() {
    let tracker = DetectionTracker()
    _ = run(tracker, Array(repeating: detection(pothole), count: 3))
    let shown = run(tracker, Array(repeating: detection(pothole, 0.12), count: 15), startingAt: 3)
    XCTAssertEqual(shown.first?.count, 1)
    XCTAssertEqual(shown.last?.count, 0)
  }

  func testWeakDetectionCannotStartTrack() {
    let shown = run(DetectionTracker(), Array(repeating: detection(pothole, 0.2), count: 20))
    XCTAssertTrue(shown.allSatisfy(\.isEmpty))
  }

  func testObjectReturningAfterHoldIsNewTrack() {
    let tracker = DetectionTracker()
    let first = run(tracker, Array(repeating: detection(pothole), count: 3))
    let gone = run(tracker, Array(repeating: nil, count: 10), startingAt: 3)
    let second = run(tracker, Array(repeating: detection(pothole), count: 3), startingAt: 13)
    XCTAssertEqual(gone.last?.count, 0)
    XCTAssertNotEqual(first[2][0].id, second[2][0].id)
  }

  func testOverlappingDuplicateIsNotShown() {
    let tracker = DetectionTracker()
    let shifted = pothole.offsetBy(dx: 0.01, dy: 0)
    for frame in 0..<6 {
      let shown = tracker.update(
        [detection(pothole), detection(shifted, 0.5)], at: TimeInterval(frame) * frameTime,
        appearThreshold: 0.25)
      XCTAssertLessThanOrEqual(shown.count, 1)
    }
  }

  func testSeparatePotholesKeepTheirOwnIDs() {
    let tracker = DetectionTracker()
    let other = CGRect(x: 0.05, y: 0.1, width: 0.1, height: 0.05)
    var shown = [TrackedDetection]()
    for frame in 0..<6 {
      shown = tracker.update(
        [detection(pothole), detection(other)], at: TimeInterval(frame) * frameTime,
        appearThreshold: 0.25)
    }
    XCTAssertEqual(shown.count, 2)
    XCTAssertEqual(Set(shown.map(\.id)).count, 2)
  }

  func testFollowsFastMovingBoxWithoutOverlap() {
    let tracker = DetectionTracker()
    var ids = Set<Int>()
    for frame in 0..<8 {
      let moved = pothole.offsetBy(dx: 0, dy: CGFloat(frame) * 0.04).insetBy(dx: 0.07, dy: 0.03)
      let shown = tracker.update(
        [detection(moved)], at: TimeInterval(frame) * frameTime, appearThreshold: 0.25)
      ids.formUnion(shown.map(\.id))
    }
    XCTAssertEqual(ids.count, 1)
  }

  func testHeldBoxKeepsMovingAtTrackedVelocity() {
    let tracker = DetectionTracker()
    var last = [TrackedDetection]()
    for frame in 0..<6 {
      last = tracker.update(
        [detection(pothole.offsetBy(dx: 0, dy: CGFloat(frame) * 0.01))],
        at: TimeInterval(frame) * frameTime, appearThreshold: 0.25)
    }
    let before = last[0].rect.midY
    let held = tracker.update([], at: 6 * frameTime, appearThreshold: 0.25)
    XCTAssertGreaterThan(held[0].rect.midY, before)
  }

  func testBehaviorDoesNotDependOnFrameRate() {
    for frameTime in [1.0 / 10, 1.0 / 30] {
      let tracker = DetectionTracker()
      for frame in 0..<3 {
        _ = tracker.update(
          [detection(pothole)], at: TimeInterval(frame) * frameTime, appearThreshold: 0.25)
      }
      let start = 2 * frameTime
      XCTAssertEqual(tracker.update([], at: start + 0.4, appearThreshold: 0.25).count, 1)
      XCTAssertEqual(tracker.update([], at: start + 0.6, appearThreshold: 0.25).count, 0)
    }
  }

  func testResetClearsTracks() {
    let tracker = DetectionTracker()
    _ = run(tracker, Array(repeating: detection(pothole), count: 3))
    tracker.reset()
    XCTAssertTrue(tracker.update([], at: 1, appearThreshold: 0.25).isEmpty)
  }
}
