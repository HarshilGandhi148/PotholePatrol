# PotholePatrol

Detecting &amp; reporting potholes.

## Project layout

| Path | Contents |
| --- | --- |
| `ios/YOLOiOSApp/Models/Detect/pothole-yolo11n.mlpackage` | Core ML model the iPhone app runs |
| `ios/YOLOiOSApp/Models/Detect/best.mlpackage` | The first model we compared, kept for reference |
| `best.mlpackage` | Copy of the original RDD2022 model, no longer used by the app |
| [`desktop/`](desktop/) | Computer version: live webcam detection and the Core ML export script |
| [`docs/model-comparison/`](docs/model-comparison/) | Side-by-side images from our model comparison |

## How we chose our model

Our first model often labeled real potholes as cracks, so we compared it with two pothole-specific models and kept the one that worked best for us.

| | RDD2022 YOLOv8m | **YOLO11n (chosen)** | YOLOv8s |
| --- | --- | --- | --- |
| Classes | 4 road damage types | Pothole only | Pothole only |
| App model size | 50 MB | 5 MB | 21 MB |

### Results

All tests used 640 px input and a 0.25 confidence threshold. We checked by eye whether each photo's boxes landed on the pothole, and the score shown is that pothole's box.

| Our test | RDD2022 YOLOv8m | **YOLO11n** | YOLOv8s |
| --- | --- | --- | --- |
| Photo: shallow pothole (`pot1`) | Missed | **Found (0.86)** | Found (0.68) |
| Photo: deep pothole (`pot2`) | Missed | **Found (0.66)** | Found (0.70) |
| Photo: `IMG_1755` | Missed | **Missed (0.22)**, plus a false alarm on a curb (0.54) | Found (0.47) |
| Photo: `IMG_1756` | Missed | **Found (0.79)** | Found (0.74) |
| Photo: `IMG_1757` | Missed | **Found (0.65)** | Found (0.60) |
| Our phone video (7 s, 221 frames): frames with a pothole box | 0% | **100%** | 76% |
| Third-party rural road clip (28 s, 692 frames): frames with a pothole box | 23% | **100%** | 99% |

The video rows count frames with any pothole box, so they include any wrong boxes. Nearly every frame in those clips shows a pothole.

We then ran all three models live on an iPhone and chose YOLO11n, which is also the smallest. All three models remain listed in `RecordViewController` (`ios/YOLOiOSApp/YOLOiOSApp/SceneDelegate.swift`). To bring the RDD2022 model back into the app's picker, set its `inPicker` to `true`. YOLOv8s isn't included in this repo because its author doesn't state a license, so using it means downloading the weights from the link below and converting them to Core ML.

### Limits of this comparison

- This is a small informal test on a handful of photos and two videos, not a measured accuracy score. We didn't hand-label the data.
- We haven't measured false alarms on undamaged roads. We did see some, including boxes on a curb, a shadow and a dirt patch.
- We haven't yet tested from a phone mounted in a moving car.

### Examples

Our phone video. The first model calls this pothole an alligator crack:

![Three models on a frame from our phone video](docs/model-comparison/phone-video-frame.jpg)

A deep pothole:

![Three models on a photo of a deep pothole](docs/model-comparison/photo-deep-pothole.jpg)

A shallow pothole:

![Three models on a photo of a shallow pothole](docs/model-comparison/photo-shallow-pothole.jpg)

## Credits

| Model | Source | License | Training data |
| --- | --- | --- | --- |
| YOLO11n (in use) | [`SPatel02/pothole-detection-yolo11`](https://huggingface.co/SPatel02/pothole-detection-yolo11) | AGPL-3.0 | [Pothole dataset v1](https://universe.roboflow.com/brad-dwyer/pothole-voxrl/dataset/1) by Atikur Rahman Chitholian, ODbL v1.0 |
| YOLOv8s (compared, not included) | [`Samdutse/pothole-yolov8`](https://huggingface.co/Samdutse/pothole-yolov8) | Not stated by the author | Smartathon pothole dataset |
| RDD2022 YOLOv8m (compared, also used by `desktop/`) | [`dronefreak/rdd2022-yolov8m`](https://huggingface.co/dronefreak/rdd2022-yolov8m) | AGPL-3.0 | RDD2022, CC BY-SA 4.0 |

The iPhone app is built on [Ultralytics YOLO iOS](https://github.com/ultralytics/yolo-ios-app), AGPL-3.0.
