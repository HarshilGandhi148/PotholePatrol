# Task: Run a pretrained road damage model on the webcam

Build a small Python app in this (empty) folder that opens the computer's webcam and draws live boxes around road damage, using a pretrained model from Hugging Face. **Do not train anything.**

## Model

- Hugging Face repo: `dronefreak/rdd2022-yolov8m`
- Weights file: `best.pt`
- Framework: Ultralytics YOLO
- Classes: `longitudinal_crack`, `transverse_crack`, `alligator_crack`, `pothole`. Read the names from `model.names`; don't hardcode them.

Load it like this:

```python
from huggingface_hub import hf_hub_download
from ultralytics import YOLO

weights = hf_hub_download(repo_id="dronefreak/rdd2022-yolov8m", filename="best.pt")
model = YOLO(weights)
```

## What to build

1. `webcam.py` that:
   - Opens the webcam with OpenCV (`cv2.VideoCapture`), camera index from a `--camera` flag (default `0`).
   - Runs the model on each frame and draws boxes with class name and confidence.
   - Uses a distinct color per class (pothole in red).
   - Shows FPS in the corner.
   - Takes `--conf` (default `0.4`) for the confidence threshold.
   - Takes `--model` (default `dronefreak/rdd2022-yolov8m`) so a different Hugging Face repo with a `best.pt` can be swapped in.
   - Quits on `q` or Esc, and releases the camera cleanly.
   - Prints a clear error if the camera can't be opened (on macOS, mention granting Terminal or the IDE camera permission in System Settings → Privacy & Security → Camera).
2. `requirements.txt` with `ultralytics`, `huggingface_hub`, `opencv-python`.
3. `README.md` with setup and run steps:

```bash
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python webcam.py
```

The README must also credit the model (`dronefreak/rdd2022-yolov8m`, AGPL-3.0) and the dataset (RDD2022, CC BY-SA 4.0).

## Notes

- The first run downloads the weights (about 50 MB); later runs use the Hugging Face cache.
- Use the GPU automatically if one is available (Ultralytics does this by default). It must still run on CPU.
- Keep it to one script; no web UI, no database, no saving video.
- When done, run `python -c "import webcam"` to check it imports, and tell me the exact command to start it.

## Testing tip

Pointing a webcam at a real road is hard indoors. To test, hold up a phone or second screen showing photos of potholes and cracked pavement.