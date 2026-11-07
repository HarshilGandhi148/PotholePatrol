import CoreGraphics
import Foundation
import simd

/// A pinhole camera's focal lengths and principal point, in pixels of the image they describe.
public struct CameraIntrinsics: Equatable {
  public let fx: Double
  public let fy: Double
  public let cx: Double
  public let cy: Double

  public init(fx: Double, fy: Double, cx: Double, cy: Double) {
    self.fx = fx
    self.fy = fy
    self.cx = cx
    self.cy = cy
  }

  /// Reads the matrix layout AVFoundation uses: focal lengths on the diagonal, principal point in the third column.
  public init(matrix: simd_float3x3) {
    self.init(
      fx: Double(matrix[0][0]), fy: Double(matrix[1][1]), cx: Double(matrix[2][0]),
      cy: Double(matrix[2][1]))
  }

  /// Rescales these values to an image of the given size.
  ///
  /// The matrix can describe a larger image than the one being processed, or one that isn't rotated to match it.
  /// The principal point sits near the center of the image it describes, which reveals that image's shape.
  public func matched(to size: CGSize) -> CameraIntrinsics {
    let isSwapped = (cy > cx) != (size.height > size.width)
    let focalX = isSwapped ? fy : fx
    let focalY = isSwapped ? fx : fy
    let scale = Double(max(size.width, size.height)) / (2 * max(cx, cy))
    return CameraIntrinsics(
      fx: focalX * scale, fy: focalY * scale, cx: Double(size.width) / 2,
      cy: Double(size.height) / 2)
  }
}

/// How the image buffer is rotated relative to the phone, using the same names as the interface orientation.
public enum BufferOrientation {
  case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

  /// Converts gravity from the phone's axes (x right, y toward the top, z out of the screen) to the back camera's
  /// image axes (x right, y down, z forward), and returns it as a unit vector pointing at the ground.
  public func cameraDown(fromDeviceGravity gravity: SIMD3<Double>) -> SIMD3<Double> {
    let down: SIMD3<Double>
    switch self {
    case .portrait: down = SIMD3(gravity.x, -gravity.y, -gravity.z)
    case .portraitUpsideDown: down = SIMD3(-gravity.x, gravity.y, -gravity.z)
    case .landscapeLeft: down = SIMD3(gravity.y, gravity.x, -gravity.z)
    case .landscapeRight: down = SIMD3(-gravity.y, -gravity.x, -gravity.z)
    }
    return simd_normalize(down)
  }
}

/// An object's size on the road, in meters.
public struct GroundMeasurement: Equatable {
  public let width: Double
  public let length: Double
  /// Distance along the road from the point directly below the camera to the box center.
  public let distance: Double
  /// How far the box center is ahead of the camera, in the direction it's facing.
  public let ahead: Double
  /// How far the box center is to the right of the camera.
  public let right: Double
}

/// A point on Earth, in degrees.
public struct GeoCoordinate: Equatable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }

  /// The distance to another point, in meters. Accurate over the short distances used here.
  func distance(to other: GeoCoordinate) -> Double {
    let metersPerDegree = 111_195.0
    let north = (other.latitude - latitude) * metersPerDegree
    let east = (other.longitude - longitude) * metersPerDegree * cos(latitude * .pi / 180)
    return hypot(north, east)
  }

  /// The point this many meters north and east. Accurate over the short distances used here.
  func offsetBy(north: Double, east: Double) -> GeoCoordinate {
    let metersPerDegree = 111_195.0
    return GeoCoordinate(
      latitude: latitude + north / metersPerDegree,
      longitude: longitude + east / (metersPerDegree * cos(latitude * .pi / 180)))
  }
}

/// Where the camera is on Earth and which way it faces, used to place what it sees.
public struct CameraGeoPose {
  public let position: GeoCoordinate
  /// Compass direction the camera faces, in degrees clockwise from north.
  public let bearing: Double

  public init(position: GeoCoordinate, bearing: Double) {
    self.position = position
    self.bearing = bearing
  }

  /// The compass direction of the back camera from a motion attitude in a north-referenced frame (x north, y west, z
  /// up). Those two rotation matrix entries give the camera's direction, whichever way the phone is rotated.
  public static func bearing(attitudeM31 m31: Double, attitudeM32 m32: Double) -> Double {
    let degrees = atan2(m32, -m31) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
  }

  /// The location of something `ahead` and `right` of the camera, in meters.
  public func coordinate(ahead: Double, right: Double) -> GeoCoordinate {
    let angle = bearing * .pi / 180
    return position.offsetBy(
      north: ahead * cos(angle) - right * sin(angle),
      east: ahead * sin(angle) + right * cos(angle))
  }
}

/// Works out real-world size from a box by assuming the box lies on a flat road.
///
/// With the camera's height and tilt known, each pixel below the horizon corresponds to one point on the road, so this
/// doesn't need a separate distance sensor.
public struct GroundPlaneCamera {
  public let intrinsics: CameraIntrinsics
  /// Unit vector pointing at the ground, in camera axes.
  public let down: SIMD3<Double>
  public let height: Double

  public init(intrinsics: CameraIntrinsics, down: SIMD3<Double>, height: Double) {
    self.intrinsics = intrinsics
    self.down = down
    self.height = height
  }

  /// The road point seen at a pixel, or `nil` if that pixel is at or above the horizon.
  func groundPoint(atPixel pixel: CGPoint) -> SIMD3<Double>? {
    let ray = SIMD3(
      (Double(pixel.x) - intrinsics.cx) / intrinsics.fx,
      (Double(pixel.y) - intrinsics.cy) / intrinsics.fy, 1)
    let descent = simd_dot(ray, down)
    guard descent > 0.01 else { return nil }
    return ray * (height / descent)
  }

  /// Measures a box given in image pixels, or returns `nil` if any part of it is at or above the horizon.
  public func measure(pixelBox box: CGRect) -> GroundMeasurement? {
    guard let left = groundPoint(atPixel: CGPoint(x: box.minX, y: box.midY)),
      let rightEdge = groundPoint(atPixel: CGPoint(x: box.maxX, y: box.midY)),
      let far = groundPoint(atPixel: CGPoint(x: box.midX, y: box.minY)),
      let near = groundPoint(atPixel: CGPoint(x: box.midX, y: box.maxY)),
      let center = groundPoint(atPixel: CGPoint(x: box.midX, y: box.midY))
    else { return nil }

    let alongRoad = center - down * simd_dot(center, down)
    // The camera's direction flattened onto the road. Pointing straight down, it has no direction along the road.
    let opticalAxis = SIMD3<Double>(0, 0, 1)
    let flattened = opticalAxis - down * simd_dot(opticalAxis, down)
    let forward = simd_length(flattened) > 0.01 ? simd_normalize(flattened) : SIMD3(0, 0, 0)
    return GroundMeasurement(
      width: simd_distance(left, rightEdge), length: simd_distance(near, far),
      distance: simd_length(alongRoad), ahead: simd_dot(alongRoad, forward),
      right: simd_dot(alongRoad, simd_cross(down, forward)))
  }
}

/// A tracked object's estimated size. `length` is `nil` until the object has been measured from close enough.
public struct EstimatedSize: Equatable {
  public let width: Double
  public let length: Double?
  public let distance: Double
  /// Where the object is on Earth, or `nil` without a usable position and direction for the camera.
  public let coordinate: GeoCoordinate?

  /// Area in square meters, treating the object as an ellipse since potholes are roughly round. `nil` until `length`
  /// is known.
  public var area: Double? {
    length.map { .pi / 4 * width * $0 }
  }
}

/// Combines each tracked object's per-frame measurements into one stable size.
///
/// Near the horizon a one-pixel box error is a large error on the road, so only frames likely to be accurate count,
/// and each size is a median so that one bad frame can't move it.
public final class ObjectSizeEstimator {
  public struct Settings {
    public var maximumDistance = 8.0
    /// Length is far more sensitive to box error than width, so it needs closer measurements.
    public var maximumLengthDistance = 5.0
    public var minimumPixelWidth: CGFloat = 40
    /// A box this close to the frame's edge, as a fraction of the frame, may be cut off.
    public var edgeMargin: CGFloat = 0.01
    public var minimumSamples = 5
    /// Rotation above this, in radians per second, means tilt readings and boxes may not line up.
    public var maximumRotationRate = 0.6
    /// Corrects for boxes being slightly larger than the holes they surround. Fit from tape measurements.
    public var calibration = 1.0
    public var maximumSamples = 120

    public init() {}
  }

  private struct Samples {
    var widths = [Double]()
    var lengths = [Double]()
    var latitudes = [Double]()
    var longitudes = [Double]()
    var distance = 0.0
  }

  private let settings: Settings
  private var samples = [Int: Samples]()

  public init(settings: Settings = Settings()) {
    self.settings = settings
  }

  public func reset() {
    samples.removeAll()
  }

  /// Forgets every object not in `ids`, so memory doesn't grow as objects leave.
  public func retain(ids: Set<Int>) {
    samples = samples.filter { ids.contains($0.key) }
  }

  /// Adds one frame's measurement of an object. `rect` is normalized to the image, and `imageSize` is in pixels.
  public func add(
    id: Int, rect: CGRect, imageSize: CGSize, camera: GroundPlaneCamera, rotationRate: Double,
    pose: CameraGeoPose? = nil
  ) {
    let pixelBox = CGRect(
      x: rect.minX * imageSize.width, y: rect.minY * imageSize.height,
      width: rect.width * imageSize.width, height: rect.height * imageSize.height)
    guard let measurement = camera.measure(pixelBox: pixelBox) else { return }

    var entry = samples[id] ?? Samples()
    entry.distance = measurement.distance
    let margin = settings.edgeMargin
    let isInsideFrame =
      rect.minX >= margin && rect.minY >= margin && rect.maxX <= 1 - margin
      && rect.maxY <= 1 - margin
    if isInsideFrame, measurement.distance <= settings.maximumDistance,
      pixelBox.width >= settings.minimumPixelWidth, rotationRate <= settings.maximumRotationRate
    {
      entry.widths.append(measurement.width * settings.calibration)
      entry.widths = entry.widths.suffix(settings.maximumSamples)
      if let pose {
        let coordinate = pose.coordinate(ahead: measurement.ahead, right: measurement.right)
        entry.latitudes.append(coordinate.latitude)
        entry.longitudes.append(coordinate.longitude)
        entry.latitudes = entry.latitudes.suffix(settings.maximumSamples)
        entry.longitudes = entry.longitudes.suffix(settings.maximumSamples)
      }
      if measurement.distance <= settings.maximumLengthDistance {
        entry.lengths.append(measurement.length * settings.calibration)
        entry.lengths = entry.lengths.suffix(settings.maximumSamples)
      }
    }
    samples[id] = entry
  }

  /// The object's current size, or `nil` until it has enough good measurements.
  public func size(id: Int) -> EstimatedSize? {
    guard let entry = samples[id], entry.widths.count >= settings.minimumSamples else { return nil }
    return EstimatedSize(
      width: median(entry.widths),
      length: entry.lengths.count >= settings.minimumSamples ? median(entry.lengths) : nil,
      distance: entry.distance,
      coordinate: entry.latitudes.count >= settings.minimumSamples
        ? GeoCoordinate(latitude: median(entry.latitudes), longitude: median(entry.longitudes))
        : nil)
  }

  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
}
