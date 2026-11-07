# PotholePatrol: computer version

`webcam.py` opens your webcam and draws live boxes around road damage (longitudinal, transverse and alligator cracks, plus potholes) using a pretrained YOLOv8 model. Each box shows the class name and confidence, potholes are red, and the FPS is shown in the corner.

## Setup and run

Run these from the repo root:

```bash
cd desktop
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python webcam.py
```

The first run downloads the weights (about 50 MB). Later runs use the Hugging Face cache.

Press `q` or Esc to quit.

## Settings

Change the defaults in the `SETTINGS` block at the top of `webcam.py`, or override them for one run with a flag, such as `python webcam.py --conf 0.25`.

| Setting | Flag | Default | Description |
| --- | --- | --- | --- |
| `CAMERA` | `--camera` | `0` | Camera index |
| `CONFIDENCE` | `--conf` | `0.25` | Confidence threshold, from 0 to 1 |
| `IMAGE_SIZE` | `--imgsz` | `640` | Pixels the model sees: lower is faster, higher finds smaller damage |
| `MODEL` | `--model` | `dronefreak/rdd2022-yolov8m` | Hugging Face repo containing a `best.pt` |

## Camera permission on macOS

If the camera can't be opened, grant Terminal or your IDE access in System Settings → Privacy & Security → Camera, then restart it.

## Testing indoors

Pointing a webcam at a real road is hard indoors. Hold up a phone or second screen showing photos of potholes and cracked pavement instead.

## Exporting the iPhone model

`python export_coreml.py` downloads `best.pt` and converts it to `best.mlpackage` in this folder. The iPhone model in the repo root is a copy of that output, so replace it if you re-export.

## Credits

- Model: [`dronefreak/rdd2022-yolov8m`](https://huggingface.co/dronefreak/rdd2022-yolov8m), AGPL-3.0
- Dataset: RDD2022, CC BY-SA 4.0
