# PotholePatrol: computer version

`webcam.py` opens your webcam and draws live boxes around alligator cracks and potholes, using the same Core ML model as the iPhone app (macOS only). Each box shows the class name and confidence, potholes are red, and the FPS is shown in the corner. Longitudinal and transverse cracks are hidden, as they are in the app.

## Setup and run

Run these from the repo root:

```bash
cd desktop
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python webcam.py
```

Press `q` or Esc to quit.

## Checking photos

```bash
python webcam.py --images ../data
```

This prints what was found in each image and saves copies with boxes to `../runs/images`. Convert iPhone HEIC photos first, even if they are named `.png`: `sips -s format jpeg NAME.png --out NAME.jpg`.

Use this rather than `yolo predict`, which shrinks large photos with a rougher resize that can change the predicted crack type.

## Settings

Change the defaults in the `SETTINGS` block at the top of `webcam.py`, or override them for one run with a flag, such as `python webcam.py --conf 0.25`.

| Setting | Flag | Default | Description |
| --- | --- | --- | --- |
| `CAMERA` | `--camera` | `0` | Camera index |
| `CONFIDENCE` | `--conf` | `0.25` | Confidence threshold, from 0 to 1. Values below 0.25 have no effect on the iPhone model |
| `IMAGE_SIZE` | `--imgsz` | `640` | Pixels the model sees. Keep at 640 for the iPhone model |
| `MODEL` | `--model` | `../ios/YOLOiOSApp/Models/Detect/best.mlpackage` | Local model path, or a Hugging Face repo containing a `best.pt` |
| `HIDDEN_CLASSES` | | `longitudinal_crack`, `transverse_crack` | Classes that are never drawn |

## Camera permission on macOS

If the camera can't be opened, grant Terminal or your IDE access in System Settings → Privacy & Security → Camera, then restart it.

## Testing indoors

Pointing a webcam at a real road is hard indoors. Hold up a phone or second screen showing photos of potholes and cracked pavement instead.

## Exporting the iPhone model

`python export_coreml.py` downloads `best.pt` and converts it to `best.mlpackage` in this folder. The iPhone model in the repo root is a copy of that output, so replace it if you re-export.

## Credits

- Model: [`dronefreak/rdd2022-yolov8m`](https://huggingface.co/dronefreak/rdd2022-yolov8m), AGPL-3.0
- Dataset: RDD2022, CC BY-SA 4.0
