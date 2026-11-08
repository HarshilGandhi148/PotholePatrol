# Pothole Patrol

An iPhone app that uses on-device computer vision to detect potholes, tag their GPS locations, and report them to the agency responsible for maintaining the road. No video leaves the vehicle, and the city owns all collected data.

## Why we built it

We're students at Purdue in West Lafayette, and the roads around campus are full of potholes. Everyone complains about them, but almost nobody reports them, so they get worse until someone finally does.

City vehicles like buses, garbage trucks and maintenance trucks already drive almost every street, every week. If their cameras could spot potholes on their own, nobody would need to remember to report anything. Pothole Patrol is our first step toward that: the detection runs on the device, and it works today on an iPhone.

## What it does

The Scan tab has three ways to find potholes:

- **Live Scan:** mount the phone and tap Start before driving. The camera shows steady boxes around potholes, with each one's estimated area and location. When the app is sure about a pothole, it takes a photo, once per pothole, and adds it to the count on the Save button. Tapping Save adds them to My Reports and sends them to the backend.
- **Upload a Video:** pick a road video from your photos and choose where it was filmed. The app finds potholes in it the same way Live Scan does. The video itself never leaves the phone, and only the photos of the potholes found are sent.
- **Report a Photo:** while standing still, take one photo of a pothole. Your location is filled in automatically, and you can correct it before uploading.

The backend then works out who owns the road, merges duplicate reports, and gives each pothole a plain name like "Pothole on East 116th Street near Madden Drive". From the pothole's page, the app opens that agency's own form and fills in what it can. **The resident always taps the agency's Submit button themselves**, so the app never files a report without them.

Other tabs show reported potholes on a map, the reports made from this phone, and a separate sign-in for officials to see a ranked repair queue and update a pothole's status.

## How we built it

**iPhone app:** built in Xcode on top of the [Ultralytics YOLO iOS app](https://github.com/ultralytics/yolo-ios-app).

| Tool | What it does |
|---|---|
| Swift | The app's programming language |
| SwiftUI | Screens and navigation |
| UIKit | The live camera view, and the parts of the Ultralytics app built on it |
| AVFoundation | Reads the camera feed and uploaded videos for the model |
| Core Motion and Core Location | Phone tilt, direction and GPS, used to estimate size and location |
| MapKit | Maps of reported potholes, and choosing a location |
| WebKit | Shows the agency's form, so the app can fill it in |

**Model:** a YOLO11n object detection model, converted to Core ML so detection runs entirely on the iPhone with no internet connection. Sending reports still needs a connection. See [How we chose our model](#how-we-chose-our-model).

**Backend:** the server code is on the [`backend-docs`](../../tree/backend-docs) branch, along with its API guide in `backend.md`.

| Tool | What it does | Why we chose it | At scale |
|---|---|---|---|
| Python | Backend language | Best tools for map data, and fast to build in | Keep it |
| FastAPI | Runs the API routes | Validates input and generates API docs | Keep it |
| Uvicorn | Runs FastAPI | The standard choice | Run several copies |
| SQLite | Database | One file and no setup, which is enough for a hackathon | Move to Postgres with PostGIS |
| Shapely | Map geometry | Finds the nearest road and checks city limits | PostGIS could do this |
| pyproj | Converts GPS to meters | "Within 25 m" needs real distances, not degrees | Keep it |
| Pillow | Image processing | Strips hidden photo metadata and resizes images | Keep it |
| pytest | Automated tests | Over 100 tests run in seconds | Keep it, and add CI |
| ngrok | Public HTTPS link to a laptop | iPhones require HTTPS, and it took minutes to set up | Replace with real hosting |
| Disk storage | Saves photos | Simple | Move to cloud storage |

Road ownership currently covers Indianapolis (all of Marion County) and Fishers. Anywhere else, including Lafayette and West Lafayette, a report is still saved, but its owner comes back as unknown.

## How the app steadies and sizes potholes

### Steady boxes

`DetectionTracker` follows each pothole across frames, so a box doesn't blink when the model misses a frame or a score hovers near the threshold.

- **Appearing:** a pothole must be seen 3 times within 0.5 s at a similar size, scoring at least 0.25 each time. A detection whose width or height differs by more than 1.5x from the previous one restarts that count, which filters out boxes that pop up at inconsistent sizes.
- **Staying:** once shown, a box stays while its score is at least 0.15, and through gaps of up to 0.5 s.

On our 7-second phone video, this cut boxes turning on and off by 86-89% at 10, 15 and 30 FPS.

### When a pothole is saved

Showing a box is cheap to get wrong, but a saved report reaches other people, so `LiveReportGate` asks for more. A pothole must be tracked for at least 1 s, with confidence of at least 0.5, fully in frame, and, in Live Scan, measured with GPS in at least 5 good frames. While it stays in view, its photo is replaced whenever it fills more of the frame, so the saved photo is the closest clear one.

### Size

A pothole's size in pixels depends on how far away it is, so the app works out where its box sits on the road. `GroundPlaneMeasurer` uses three inputs and no distance sensor:

- The phone's height above the road, set with the on-screen slider.
- The phone's tilt, from its motion sensors.
- The camera's lens data.

For each box:

1. Each box edge becomes a ray from the camera.
2. `t = h / (d · n)` finds where that ray hits the road, where `d` is the ray, `n` points straight down and `h` is the phone's height.
3. Width and length are the distances between those road points.
4. Area is shown in square feet, treating the pothole as an ellipse: `area = π/4 × width × length`.

A pothole twice as far away looks half as wide but is measured at twice the distance, so its size comes out the same. Each pothole uses the median of its measurements, from frames where its box is fully in view, at least 40 px wide and within 8 m. Length also requires frames within 5 m, because it's much more sensitive to box error, so a pothole shows only its distance until it's that close.

Measure the phone's height with a tape. A height that's 10% off makes width and length 10% off, and area about 21% off.

An uploaded video records no tilt or height, so you enter them, and the lens is assumed to be an iPhone's main camera. Sizes from a video are rough as a result.

### Location

The same calculation gives each pothole's distance ahead of and to the side of the phone. Adding those to the phone's GPS position and direction gives the pothole's latitude and longitude, using the median across frames.

The direction comes from the GPS course at 3 m/s or more, which assumes the camera faces the direction of travel, and from the compass otherwise. The result can't be more accurate than the phone's GPS, which is usually off by several meters. Location needs GPS accuracy within 20 m.

### Limits

- Size describes the box, not the hole's exact outline, and it doesn't measure depth.
- It assumes a flat road. Hills and crowned roads add error, especially at a distance.
- It hasn't been checked against tape measurements yet. Our tests only use simulated potholes, where it recovers the size to within 1% at 2-8 m.

## How we chose our model

Our first model often labeled real potholes as alligator cracks, so we compared it with two pothole-specific models on our own photos and kept the one that worked best.

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

We then ran all three models live on an iPhone and chose YOLO11n, which is also the smallest. All three remain listed in `RecordViewController` (`ios/YOLOiOSApp/YOLOiOSApp/SceneDelegate.swift`). To bring the RDD2022 model back into the app's picker, set its `inPicker` to `true`. YOLOv8s isn't included in this repo because its author doesn't state a license, so using it means downloading the weights from the link in [Credits](#credits) and converting them to Core ML.

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

## Challenges we ran into

- **Our first model wasn't good enough.** On real potholes we photographed, it often labeled them as alligator cracking instead. Picking a model meant testing several on our own data, because published benchmark scores didn't tell us how they'd do on our roads.
- **Getting the model onto an iPhone.** Converting it to Core ML, setting up code signing with a free Apple account, and getting the app to recognize a custom model each took real debugging.
- **Connecting the phone to the backend.** iPhones block plain HTTP, so we needed an HTTPS tunnel before the app could send reports to a laptop.

## What's next

- **LiDAR for depth,** to measure how deep a pothole is instead of only estimating its area
- **Pothole validation,** so crews or residents can confirm a detection before a repair is scheduled
- **Accelerometer data,** to catch potholes the vehicle actually hits
- **A map filter** to show the potholes you recorded yourself
- **Importing public pothole data,** such as existing resident reports, to combine with our detections
- **Blurring license plates and faces** in any saved photo
- **More towns,** starting with Lafayette and West Lafayette

## Project layout

| Path | Contents |
| --- | --- |
| [`ios/YOLOiOSApp/`](ios/YOLOiOSApp/) | The iPhone app. [`POTHOLE_PATROL.md`](ios/YOLOiOSApp/POTHOLE_PATROL.md) covers its screens, privacy and backend connection. |
| `ios/YOLOiOSApp/Models/Detect/pothole-yolo11n.mlpackage` | The Core ML model the app runs |
| `ios/YOLOiOSApp/Models/Detect/best.mlpackage` | The first model we compared, kept for reference |
| [`ios/Sources/UltralyticsYOLO/`](ios/Sources/UltralyticsYOLO/) | The Ultralytics detection library, plus our tracker, size and video code |
| `best.mlpackage` | Copy of the original RDD2022 model, no longer used by the app |
| [`desktop/`](desktop/) | Computer version: live webcam detection and the Core ML export script |
| [`docs/model-comparison/`](docs/model-comparison/) | Side-by-side images from our model comparison |

## Credits

| Model | Source | License | Training data |
| --- | --- | --- | --- |
| YOLO11n (in use) | [`SPatel02/pothole-detection-yolo11`](https://huggingface.co/SPatel02/pothole-detection-yolo11) | AGPL-3.0 | [Pothole dataset v1](https://universe.roboflow.com/brad-dwyer/pothole-voxrl/dataset/1) by Atikur Rahman Chitholian, ODbL v1.0 |
| YOLOv8s (compared, not included) | [`Samdutse/pothole-yolov8`](https://huggingface.co/Samdutse/pothole-yolov8) | Not stated by the author | Smartathon pothole dataset |
| RDD2022 YOLOv8m (compared, also used by `desktop/`) | [`dronefreak/rdd2022-yolov8m`](https://huggingface.co/dronefreak/rdd2022-yolov8m) | AGPL-3.0 | RDD2022, CC BY-SA 4.0 |

The iPhone app is built on [Ultralytics YOLO iOS](https://github.com/ultralytics/yolo-ios-app), AGPL-3.0.
