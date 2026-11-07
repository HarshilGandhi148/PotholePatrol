import XCTest
import simd

@testable import UltralyticsYOLO

final class GroundPlaneMeasurerTests: XCTestCase {
  private let imageSize = CGSize(width: 1280, height: 720)
  private let intrinsics = CameraIntrinsics(fx: 950, fy: 950, cx: 640, cy: 360)

  /// A camera pitched down by `pitch` and rolled by `roll` (both in degrees), with its forward direction along the road.
  private func camera(
    pitch: Double, roll: Double = 0, height: Double = 1.2
  ) -> (camera: GroundPlaneCamera, toWorld: simd_double3x3) {
    let p = pitch * .pi / 180
    let r = roll * .pi / 180
    // World axes: x right, y down, z forward along the road. Columns are the camera's axes in world coordinates.
    let pitched = simd_double3x3(
      SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p)))
    let rolled = simd_double3x3(
      SIMD3(cos(r), sin(r), 0), SIMD3(-sin(r), cos(r), 0), SIMD3(0, 0, 1))
    let toWorld = pitched * rolled
    let down = toWorld.transpose * SIMD3(0, 1, 0)
    return (GroundPlaneCamera(intrinsics: intrinsics, down: down, height: height), toWorld)
  }

  /// The image box a detector would draw around an elliptical pothole `width` by `length`, centered `distance` ahead
  /// and `side` to the right, found by projecting its outline from the road into the image.
  private func box(
    width: Double, length: Double, distance: Double, side: Double = 0, height: Double = 1.2,
    toWorld: simd_double3x3
  ) -> CGRect {
    let toCamera = toWorld.transpose
    let pixels = (0..<720).map { step -> CGPoint in
      let angle = Double(step) * .pi / 360
      let point =
        toCamera
        * SIMD3(
          side + width / 2 * cos(angle), height, distance + length / 2 * sin(angle))
      return CGPoint(
        x: intrinsics.fx * point.x / point.z + intrinsics.cx,
        y: intrinsics.fy * point.y / point.z + intrinsics.cy)
    }
    let xs = pixels.map(\.x)
    let ys = pixels.map(\.y)
    return CGRect(
      x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }

  func testRecoversKnownSizeAtEveryDistanceAndPitch() throws {
    for distance in [2.0, 3, 5, 8] {
      for pitch in [5.0, 10, 20] {
        let (camera, toWorld) = camera(pitch: pitch)
        let measured = try XCTUnwrap(
          camera.measure(
            pixelBox: box(width: 0.6, length: 0.5, distance: distance, toWorld: toWorld)))
        XCTAssertEqual(measured.width, 0.6, accuracy: 0.006, "\(distance) m at \(pitch)°")
        XCTAssertEqual(measured.length, 0.5, accuracy: 0.005, "\(distance) m at \(pitch)°")
      }
    }
  }

  func testPixelSizeShrinksWhileMeasuredSizeStaysTheSame() throws {
    let (camera, toWorld) = camera(pitch: 10)
    let nearBox = box(width: 0.6, length: 0.5, distance: 3, toWorld: toWorld)
    let farBox = box(width: 0.6, length: 0.5, distance: 8, toWorld: toWorld)
    XCTAssertGreaterThan(nearBox.width, farBox.width * 2)
    let near = try XCTUnwrap(camera.measure(pixelBox: nearBox))
    let far = try XCTUnwrap(camera.measure(pixelBox: farBox))
    XCTAssertEqual(near.width, far.width, accuracy: 0.01)
  }

  func testMeasuresPotholeOffToTheSide() throws {
    let (camera, toWorld) = camera(pitch: 10)
    let measured = try XCTUnwrap(
      camera.measure(
        pixelBox: box(width: 0.6, length: 0.5, distance: 5, side: 1.2, toWorld: toWorld)))
    XCTAssertEqual(measured.width, 0.6, accuracy: 0.03)
    XCTAssertEqual(measured.distance, hypot(5, 1.2), accuracy: 0.05)
  }

  func testRollIsHandled() throws {
    for roll in [-5.0, 5] {
      let (camera, toWorld) = camera(pitch: 10, roll: roll)
      // Rolled boxes aren't aligned with the road, so check the distance at the center of a small box.
      let measured = try XCTUnwrap(
        camera.measure(pixelBox: box(width: 0.1, length: 0.1, distance: 5, toWorld: toWorld)))
      XCTAssertEqual(measured.distance, 5, accuracy: 0.05)
    }
  }

  func testReportsDistanceAlongTheRoad() throws {
    let (camera, toWorld) = camera(pitch: 10)
    let measured = try XCTUnwrap(
      camera.measure(pixelBox: box(width: 0.6, length: 0.5, distance: 5, toWorld: toWorld)))
    XCTAssertEqual(measured.distance, 5, accuracy: 0.05)
  }

  func testRejectsBoxAtOrAboveHorizon() {
    let (camera, _) = camera(pitch: 0)
    XCTAssertNil(camera.measure(pixelBox: CGRect(x: 600, y: 100, width: 80, height: 40)))
    XCTAssertNil(camera.measure(pixelBox: CGRect(x: 600, y: 340, width: 80, height: 40)))
  }

  func testHeightErrorScalesSizeProportionally() throws {
    let (trueCamera, toWorld) = camera(pitch: 10)
    let wrong = GroundPlaneCamera(
      intrinsics: intrinsics, down: trueCamera.down, height: 1.2 * 1.1)
    let measured = try XCTUnwrap(
      wrong.measure(pixelBox: box(width: 0.6, length: 0.5, distance: 5, toWorld: toWorld)))
    XCTAssertEqual(measured.width, 0.66, accuracy: 0.007)
  }

  func testIntrinsicsAreScaledToTheImage() {
    let matched = CameraIntrinsics(fx: 3000, fy: 3000, cx: 2000, cy: 1125)
      .matched(to: CGSize(width: 1280, height: 720))
    XCTAssertEqual(matched.fx, 960, accuracy: 0.001)
    XCTAssertEqual(matched.cx, 640)
    XCTAssertEqual(matched.cy, 360)
  }

  func testIntrinsicsAreRotatedToMatchPortraitImage() {
    let matched = CameraIntrinsics(fx: 3000, fy: 3100, cx: 2000, cy: 1125)
      .matched(to: CGSize(width: 720, height: 1280))
    XCTAssertEqual(matched.fx, 3100 * 0.32, accuracy: 0.001)
    XCTAssertEqual(matched.fy, 3000 * 0.32, accuracy: 0.001)
    XCTAssertEqual(matched.cx, 360)
    XCTAssertEqual(matched.cy, 640)
  }

  func testGravityInEveryOrientation() {
    // Phone held upright with its back camera level: gravity runs toward the phone's bottom edge.
    let upright = SIMD3<Double>(0, -1, 0)
    XCTAssertEqual(BufferOrientation.portrait.cameraDown(fromDeviceGravity: upright), SIMD3(0, 1, 0))
    // Turned so the top of the phone points left (landscape right): gravity runs toward the phone's left edge.
    XCTAssertEqual(
      BufferOrientation.landscapeRight.cameraDown(fromDeviceGravity: SIMD3(-1, 0, 0)),
      SIMD3(0, 1, 0))
    XCTAssertEqual(
      BufferOrientation.landscapeLeft.cameraDown(fromDeviceGravity: SIMD3(1, 0, 0)), SIMD3(0, 1, 0))
    // Phone flat on its back with the camera facing the ground: gravity runs into the screen.
    XCTAssertEqual(
      BufferOrientation.portrait.cameraDown(fromDeviceGravity: SIMD3(0, 0, -1)), SIMD3(0, 0, 1))
  }

  // MARK: - ObjectSizeEstimator

  private func normalized(_ box: CGRect) -> CGRect {
    CGRect(
      x: box.minX / imageSize.width, y: box.minY / imageSize.height,
      width: box.width / imageSize.width, height: box.height / imageSize.height)
  }

  private func add(
    _ estimator: ObjectSizeEstimator, distance: Double, count: Int = 5, width: Double = 0.6,
    rotationRate: Double = 0
  ) {
    let (camera, toWorld) = camera(pitch: 10)
    let rect = normalized(box(width: width, length: 0.5, distance: distance, toWorld: toWorld))
    for _ in 0..<count {
      estimator.add(
        id: 1, rect: rect, imageSize: imageSize, camera: camera, rotationRate: rotationRate)
    }
  }

  func testNoSizeUntilEnoughSamples() {
    let estimator = ObjectSizeEstimator()
    add(estimator, distance: 4, count: 4)
    XCTAssertNil(estimator.size(id: 1))
    add(estimator, distance: 4, count: 1)
    XCTAssertEqual(estimator.size(id: 1)?.width ?? 0, 0.6, accuracy: 0.01)
  }

  func testFarObjectIsIgnored() {
    let estimator = ObjectSizeEstimator()
    add(estimator, distance: 9, count: 20)
    XCTAssertNil(estimator.size(id: 1))
  }

  func testLengthWaitsForCloseMeasurements() throws {
    let estimator = ObjectSizeEstimator()
    add(estimator, distance: 7)
    XCTAssertNil(try XCTUnwrap(estimator.size(id: 1)).length)
    add(estimator, distance: 4)
    XCTAssertEqual(try XCTUnwrap(estimator.size(id: 1)).length ?? 0, 0.5, accuracy: 0.01)
  }

  func testOutliersDoNotMoveTheMedian() throws {
    let estimator = ObjectSizeEstimator()
    add(estimator, distance: 4, count: 7)
    add(estimator, distance: 4, count: 2, width: 2)
    XCTAssertEqual(try XCTUnwrap(estimator.size(id: 1)).width, 0.6, accuracy: 0.01)
  }

  func testShakingFramesAreIgnored() {
    let estimator = ObjectSizeEstimator()
    add(estimator, distance: 4, count: 10, rotationRate: 2)
    XCTAssertNil(estimator.size(id: 1))
  }

  func testBoxCutOffByFrameIsIgnored() {
    let estimator = ObjectSizeEstimator()
    let (camera, _) = camera(pitch: 10)
    for _ in 0..<10 {
      estimator.add(
        id: 1, rect: CGRect(x: 0, y: 0.6, width: 0.3, height: 0.2), imageSize: imageSize,
        camera: camera, rotationRate: 0)
    }
    XCTAssertNil(estimator.size(id: 1))
  }

  func testTooFewPixelsIsIgnored() {
    let estimator = ObjectSizeEstimator()
    add(estimator, distance: 7, count: 10, width: 0.2)
    XCTAssertNil(estimator.size(id: 1))
  }

  func testCalibrationScalesSize() throws {
    var settings = ObjectSizeEstimator.Settings()
    settings.calibration = 0.9
    let estimator = ObjectSizeEstimator(settings: settings)
    add(estimator, distance: 4)
    XCTAssertEqual(try XCTUnwrap(estimator.size(id: 1)).width, 0.54, accuracy: 0.01)
  }

  func testRetainForgetsOtherObjects() {
    let estimator = ObjectSizeEstimator()
    add(estimator, distance: 4)
    estimator.retain(ids: [2])
    XCTAssertNil(estimator.size(id: 1))
  }
}
