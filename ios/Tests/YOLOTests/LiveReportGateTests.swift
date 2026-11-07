import XCTest

@testable import UltralyticsYOLO

final class LiveReportGateTests: XCTestCase {
  private let here = GeoCoordinate(latitude: 40, longitude: -86)

  private func track(
    id: Int = 1, trackedTime: TimeInterval = 2, confidence: Float = 0.7,
    measuredRect: CGRect? = CGRect(x: 0.3, y: 0.5, width: 0.3, height: 0.2)
  ) -> TrackedDetection {
    TrackedDetection(
      id: id, rect: measuredRect ?? .zero, confidence: confidence, classIndex: 0,
      className: "pothole", measuredRect: measuredRect, trackedTime: trackedTime)
  }

  func testReportsWhenCertain() {
    XCTAssertTrue(LiveReportGate().shouldReport(track(), at: here))
  }

  func testWaitsUntilTrackedLongEnough() {
    XCTAssertFalse(LiveReportGate().shouldReport(track(trackedTime: 0.9), at: here))
  }

  func testIgnoresLowConfidence() {
    XCTAssertFalse(LiveReportGate().shouldReport(track(confidence: 0.49), at: here))
  }

  func testNeedsALocation() {
    XCTAssertFalse(LiveReportGate().shouldReport(track(), at: nil))
  }

  func testNotDuringAHeldFrame() {
    XCTAssertFalse(LiveReportGate().shouldReport(track(measuredRect: nil), at: here))
  }

  func testNotWhileCutOffByTheFrame() {
    let cutOff = CGRect(x: 0.3, y: 0.7, width: 0.3, height: 0.3)
    XCTAssertFalse(LiveReportGate().shouldReport(track(measuredRect: cutOff), at: here))
  }

  func testReportsEachPotholeOnce() {
    let gate = LiveReportGate()
    gate.markReported(track(), at: here)
    XCTAssertFalse(gate.shouldReport(track(), at: here))
  }

  func testSkipsAnotherTrackAtTheSamePlace() {
    let gate = LiveReportGate()
    gate.markReported(track(id: 1), at: here)
    let nearby = GeoCoordinate(latitude: 40.00002, longitude: -86)  // About 2 m north.
    XCTAssertFalse(gate.shouldReport(track(id: 2), at: nearby))
    XCTAssertFalse(gate.wantsPhoto(of: [track(id: 2)]))
  }

  func testReportsASecondPotholeCloseToTheFirst() {
    let gate = LiveReportGate()
    gate.markReported(track(id: 1), at: here)
    let close = GeoCoordinate(latitude: 40.00005, longitude: -86)  // About 6 m north.
    XCTAssertTrue(gate.shouldReport(track(id: 2), at: close))
  }

  func testCloserPotholeFillsMoreOfThePhoto() throws {
    let gate = LiveReportGate()
    let far = try XCTUnwrap(gate.photoArea(of: track(measuredRect: CGRect(x: 0.4, y: 0.5, width: 0.1, height: 0.05))))
    let near = try XCTUnwrap(gate.photoArea(of: track(measuredRect: CGRect(x: 0.3, y: 0.5, width: 0.3, height: 0.2))))
    XCTAssertGreaterThan(near, far)
  }

  func testPhotoIsNotReplacedByACutOffFrame() {
    let cutOff = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.5)
    XCTAssertNil(LiveReportGate().photoArea(of: track(measuredRect: cutOff)))
  }

  func testPhotoIsNotReplacedByAWeakOrHeldFrame() {
    let gate = LiveReportGate()
    XCTAssertNil(gate.photoArea(of: track(confidence: 0.4)))
    XCTAssertNil(gate.photoArea(of: track(measuredRect: nil)))
  }

  func testOnlyKeepsPhotosWhileSomethingCanBeReported() {
    let gate = LiveReportGate()
    XCTAssertFalse(gate.wantsPhoto(of: []))
    XCTAssertTrue(gate.wantsPhoto(of: [track()]))
    gate.markReported(track(), at: here)
    XCTAssertFalse(gate.wantsPhoto(of: [track()]))
  }

  func testTrackerReportsHowLongItHasFollowedAPothole() {
    let tracker = DetectionTracker()
    let detection = TrackerDetection(
      rect: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.1), confidence: 0.6, classIndex: 0,
      className: "pothole")
    var shown = [TrackedDetection]()
    for frame in 0..<16 {
      shown = tracker.update([detection], at: Double(frame) * 0.1, appearThreshold: 0.25)
    }
    XCTAssertEqual(shown.first?.trackedTime ?? 0, 1.5, accuracy: 0.001)
  }
}
