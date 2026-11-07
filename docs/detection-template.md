# Detection data template

What the app sends the backend for each pothole. Use the same fields when saving training data.

**Status:** the first 5 fields work today. The backend accepts the rest without an error but doesn't save them yet.

Send it as `multipart/form-data` to `POST /detections`, one request per pothole.

## Fields

### Works today

| Field | Type | Required | Example | Where it comes from |
|---|---|---|---|---|
| `photo` | JPEG or PNG file | Yes | `pothole.jpg` | `result.originalImage`, full frame, not cropped |
| `lat` | number | Yes | `39.77309` | Core Location, at the moment of the frame |
| `lng` | number | Yes | `-86.02417` | Core Location, at the moment of the frame |
| `captured_at` | ISO 8601 string | Yes | `2026-11-07T17:50:00Z` | Time of the frame |
| `device_id` | string, 8 to 128 characters | Yes | `7F3A9C10-2B44-4E0B-9A11-0C1D2E3F4A5B` | Random UUID, created once |

### GPS quality

| Field | Type | Required | Example | Where it comes from |
|---|---|---|---|---|
| `gps_accuracy_m` | number | Yes | `6.5` | `CLLocation.horizontalAccuracy` |
| `heading_deg` | number, 0 to 360 | No | `184.0` | `CLLocation.course`. Send nothing if it's negative. |
| `capture_source` | `live` or `gallery` | Yes | `live` | `gallery` for photos picked from the library |

### Detection

| Field | Type | Required | Example | Where it comes from |
|---|---|---|---|---|
| `class_name` | string | Yes | `pothole` | `box.cls` |
| `confidence` | number, 0 to 1 | Yes | `0.87` | `box.conf` |
| `box_x` | number, 0 to 1 | Yes | `0.45` | `box.xywhn.minX` |
| `box_y` | number, 0 to 1 | Yes | `0.62` | `box.xywhn.minY` |
| `box_width` | number, 0 to 1 | Yes | `0.10` | `box.xywhn.width` |
| `box_height` | number, 0 to 1 | Yes | `0.06` | `box.xywhn.height` |
| `image_width_px` | integer | Yes | `1920` | `result.orig_shape.width` |
| `image_height_px` | integer | Yes | `1080` | `result.orig_shape.height` |
| `model_version` | string | Yes | `rdd2022-yolov8m-1` | Set by the team. Change it with each new model. |

The box origin is the top-left corner of the image, and the values are fractions of the image size. Don't flip them.

### Size

Leave these out if they can't be worked out. **Never send a guess.**

| Field | Type | Required | Example | Where it comes from |
|---|---|---|---|---|
| `width_cm` | number | No | `55` | Across the road. Calculated below. |
| `length_cm` | number | No | `66` | Along the road. Calculated below. |
| `size_method` | `camera_geometry`, `lidar` or `manual` | If size is sent | `camera_geometry` | How the size was measured |
| `camera_height_m` | number | If size is sent | `1.2` | Phone height above the road, set once per mount |
| `camera_pitch_deg` | number | If size is sent | `10` | Tilt down from level, from Core Motion at the moment of the frame |
| `focal_length_px` | number | If size is sent | `1506.9` | Calculated below |

## Full example

```bash
curl -X POST https://BASE_URL/detections \
  -H "ngrok-skip-browser-warning: true" \
  -F photo=@pothole.jpg \
  -F lat=39.77309 \
  -F lng=-86.02417 \
  -F captured_at=2026-11-07T17:50:00Z \
  -F device_id=7F3A9C10-2B44-4E0B-9A11-0C1D2E3F4A5B \
  -F gps_accuracy_m=6.5 \
  -F heading_deg=184.0 \
  -F capture_source=live \
  -F class_name=pothole \
  -F confidence=0.87 \
  -F box_x=0.45 \
  -F box_y=0.62 \
  -F box_width=0.10 \
  -F box_height=0.06 \
  -F image_width_px=1920 \
  -F image_height_px=1080 \
  -F model_version=rdd2022-yolov8m-1 \
  -F width_cm=55 \
  -F length_cm=66 \
  -F size_method=camera_geometry \
  -F camera_height_m=1.2 \
  -F camera_pitch_deg=10 \
  -F focal_length_px=1506.9
```

## Rules

- **Send `pothole` only.** Skip the three crack classes.
- **Send one request per pothole.** Don't send again until the phone has moved more than 25 m.
- **Skip poor GPS.** Don't send if `gps_accuracy_m` is over about 20.
- **Match the photo and the box.** The box must come from the exact frame sent, and the frame must not be cropped.
- **Gallery photos:** use the location and time stored in the photo, never the phone's current GPS. Leave out the camera and size fields unless they're known.

**Don't send:**

- A session or trip ID. It would link potholes into a route, which breaks the rule against storing vehicle routes.
- A continuous GPS track, or speed.
- Severity labels such as "bad" or "large". Size is a measurement, not a rating.
- Names or contact details.

## Calculating size

**Use `GroundPlaneMeasurer` on the `pothole_processing` branch instead of the function below.** It uses the camera's real lens data and takes a median across frames. Send its result as `width_cm` and `length_cm`, with `size_method` set to `camera_geometry`. The function here is the simple version, for reference.

The model outputs a box, not centimetres, and the app doesn't read camera or motion data yet. This function works out size from the box and the camera's position, assuming a flat road.

```swift
import CoreGraphics
import Foundation

struct PotholeSize {
    let widthCm: Double
    let lengthCm: Double
}

/// Estimates size by assuming a flat road. Returns nil if the box touches or passes the horizon.
/// box: normalized, top-left origin. pitchDeg: how far the camera tilts down from level.
func estimateSize(
    box: CGRect,
    imageWidthPx: Double,
    imageHeightPx: Double,
    focalLengthPx f: Double,
    cameraHeightM h: Double,
    cameraPitchDeg: Double
) -> PotholeSize? {
    let pitch = cameraPitchDeg * .pi / 180
    let centerY = imageHeightPx / 2

    // Angle below level for an image row, and how far along the road that row lands.
    func angle(_ row: Double) -> Double { pitch + atan((row - centerY) / f) }
    func groundDistance(_ row: Double) -> Double? {
        let a = angle(row)
        return a > 0.02 ? h / tan(a) : nil
    }

    let topRow = box.minY * imageHeightPx
    let bottomRow = box.maxY * imageHeightPx
    guard let far = groundDistance(topRow), let near = groundDistance(bottomRow) else { return nil }

    let middle = (topRow + bottomRow) / 2
    let slantDistance = h / sin(angle(middle))
    let widthM = box.width * imageWidthPx * slantDistance / f
    return PotholeSize(widthCm: widthM * 100, lengthCm: (far - near) * 100)
}
```

**Focal length:** `(longest image side in px / 2) / tan(videoFieldOfView / 2)`, using `AVCaptureDevice.activeFormat.videoFieldOfView` converted to radians. The example above uses 1920 px and 65 degrees, which gives 1506.9.

**Pitch:** read it from `CMDeviceMotion` at the moment of the frame, not once at the start of the drive.

**How accurate it is:** in a simulated test, a 50 × 60 cm patch 5 m away came back as 50 × 60 cm. That's the best case, with exact inputs and a box that fits perfectly. Small input errors matter a lot:

| Input error | Result for the same 50 × 60 cm patch |
|---|---|
| Camera height off by 20 cm | 58 × 69 cm |
| Pitch off by +2 degrees | 43 × 45 cm |
| Pitch off by -2 degrees | 58 × 83 cm |

Real results will be worse, because the box is looser than the pothole and roads aren't flat. Show it as an estimate, and don't show size in the app until it has been checked against real potholes.

Depth isn't in this template, because one camera can't measure it.

## Saving training data

Save one `.json` file per detection next to its photo, with the same names:

```text
training/
  detection-0001.jpg
  detection-0001.json
```

```json
{
  "lat": 39.77309,
  "lng": -86.02417,
  "captured_at": "2026-11-07T17:50:00Z",
  "gps_accuracy_m": 6.5,
  "capture_source": "live",
  "class_name": "pothole",
  "confidence": 0.87,
  "box_x": 0.45,
  "box_y": 0.62,
  "box_width": 0.10,
  "box_height": 0.06,
  "image_width_px": 1920,
  "image_height_px": 1080,
  "model_version": "rdd2022-yolov8m-1",
  "width_cm": 55,
  "length_cm": 66,
  "size_method": "camera_geometry",
  "camera_height_m": 1.2,
  "camera_pitch_deg": 10,
  "focal_length_px": 1506.9,
  "measured_width_cm": 50,
  "measured_length_cm": 60,
  "reviewed_is_pothole": true
}
```

These two sets of fields are only for training, and are never sent to the API:

| Field | Type | Meaning |
|---|---|---|
| `measured_width_cm`, `measured_length_cm` | number or null | Measured on the real pothole with a tape. This is the only way to check or train size. |
| `reviewed_is_pothole` | boolean or null | A person checked the photo. `false` records a wrong detection. |

**Don't train size from `width_cm` and `length_cm`.** Those are our own estimates, so a model would only learn to repeat them.

**To retrain the detector,** YOLO label files use the box centre, not the top-left corner:

```text
class_id  box_x + box_width / 2  box_y + box_height / 2  box_width  box_height
```

Use the class number from the model's own class list.
