"""Live road damage detection from a webcam using a pretrained YOLO model."""

# ============================ SETTINGS: edit these ============================
CAMERA = 0  # Which camera to use. Try 1 if 0 is the wrong one.
CONFIDENCE = 0.25  # 0 to 1. Higher means fewer false alarms. Below 0.25 has no effect on the iPhone model.
IMAGE_SIZE = 640  # Pixels the model sees. Keep at 640 for the iPhone model, built for that size.
# The iPhone app's Core ML model, relative to this file. Can also be a Hugging Face
# repo containing a best.pt, such as "dronefreak/rdd2022-yolov8m".
MODEL = "../ios/YOLOiOSApp/Models/Detect/best.mlpackage"
HIDDEN_CLASSES = {"longitudinal_crack", "transverse_crack"}  # Never drawn. Matches the app.
# ==============================================================================

import argparse
import colorsys
import sys
import time
from pathlib import Path

import cv2
import torch
from huggingface_hub import hf_hub_download
from ultralytics import YOLO

WEIGHTS_FILENAME = "best.pt"
WINDOW_TITLE = "Road damage detection (q or Esc to quit)"
QUIT_KEYS = {ord("q"), 27}  # 27 is Esc
POTHOLE_COLOR = (0, 0, 255)  # BGR red
FPS_SMOOTHING = 0.9
IMAGE_OUTPUT = Path(__file__).resolve().parent.parent / "runs" / "images"
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--camera", type=int, default=CAMERA, help=f"camera index (default: {CAMERA})"
    )
    parser.add_argument(
        "--conf",
        type=float,
        default=CONFIDENCE,
        help=f"confidence threshold (default: {CONFIDENCE})",
    )
    parser.add_argument(
        "--imgsz",
        type=int,
        default=IMAGE_SIZE,
        help=f"image size used by the model, in pixels (default: {IMAGE_SIZE})",
    )
    parser.add_argument(
        "--model",
        default=MODEL,
        help=f"local model path, or Hugging Face repo containing {WEIGHTS_FILENAME} "
        f"(default: {MODEL})",
    )
    parser.add_argument(
        "--images",
        type=Path,
        help=f"check an image or a folder of images instead of the webcam; saves to {IMAGE_OUTPUT}",
    )
    return parser.parse_args()


def load_model(model):
    local_path = Path(__file__).resolve().parent / model
    if local_path.exists():
        return YOLO(str(local_path), task="detect")
    return YOLO(hf_hub_download(repo_id=model, filename=WEIGHTS_FILENAME), task="detect")


def visible_class_ids(names):
    return [cid for cid, name in names.items() if name not in HIDDEN_CLASSES]


def detect(model, frame, conf, imgsz, device, classes):
    """Return the result for a frame, plus the scale from the frame to the result's coordinates.

    Ultralytics shrinks with INTER_LINEAR, which leaves aliasing on large images, and on road
    photos that changes the predicted crack type. Shrinking with INTER_AREA first avoids this.
    """
    scale = min(imgsz / max(frame.shape[:2]), 1.0)
    small = cv2.resize(frame, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    result = model.predict(
        small, conf=conf, imgsz=imgsz, device=device, classes=classes, verbose=False
    )[0]
    return result, scale


def run_on_images(model, source, conf, imgsz):
    paths = [source] if source.is_file() else sorted(source.glob("*"))
    paths = [path for path in paths if path.suffix.lower() in IMAGE_SUFFIXES]
    if not paths:
        print(f"Error: no images found at {source}.", file=sys.stderr)
        return 1

    names = model.names
    colors = build_class_colors(names)
    device = pick_device()
    classes = visible_class_ids(names)
    IMAGE_OUTPUT.mkdir(parents=True, exist_ok=True)

    for path in paths:
        image = cv2.imread(str(path))
        if image is None:
            print(f"{path.name}: could not read it (iPhone HEIC photos must be converted first)")
            continue
        result, scale = detect(model, image, conf, imgsz, device, classes)
        found = [f"{names[int(b.cls[0])]} {float(b.conf[0]):.2f}" for b in result.boxes]
        print(f"{path.name}: {', '.join(found) or 'no detections'}")
        draw_detections(image, result, names, colors, scale)
        cv2.imwrite(str(IMAGE_OUTPUT / path.name), image)

    print(f"Saved to {IMAGE_OUTPUT}")
    return 0


def pick_device():
    """Prefer Apple's GPU, which Ultralytics only uses when asked for by name.

    None leaves the choice to Ultralytics: CUDA if available, otherwise CPU.
    """
    return "mps" if torch.backends.mps.is_available() else None


def build_class_colors(names):
    """Map each class id to a distinct BGR color, with potholes in red."""
    colors = {}
    # Hues start past red and stop short of wrapping back to it, so that no
    # other class can be mistaken for a pothole.
    others = [cid for cid, name in names.items() if "pothole" not in name.lower()]
    for i, cid in enumerate(others):
        hue = 0.12 + 0.73 * i / max(len(others) - 1, 1)
        r, g, b = colorsys.hsv_to_rgb(hue, 1.0, 1.0)
        colors[cid] = (int(b * 255), int(g * 255), int(r * 255))
    for cid in names:
        colors.setdefault(cid, POTHOLE_COLOR)
    return colors


def draw_label(frame, text, x, y, color):
    """Draw black text on a filled color tag, kept inside the top of the frame."""
    font, scale, thickness = cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1
    (width, height), baseline = cv2.getTextSize(text, font, scale, thickness)
    top = max(y - height - baseline - 4, 0)
    bottom = top + height + baseline + 4
    cv2.rectangle(frame, (x, top), (x + width + 4, bottom), color, cv2.FILLED)
    cv2.putText(
        frame, text, (x + 2, bottom - baseline - 2), font, scale, (0, 0, 0), thickness, cv2.LINE_AA
    )


def draw_detections(frame, result, names, colors, scale):
    for box in result.boxes:
        x1, y1, x2, y2 = (int(v / scale) for v in box.xyxy[0])
        cid = int(box.cls[0])
        color = colors[cid]
        cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
        draw_label(frame, f"{names[cid]} {float(box.conf[0]):.2f}", x1, y1, color)


def draw_fps(frame, fps):
    text = f"FPS: {fps:.1f}"
    position = (10, 30)
    font, scale = cv2.FONT_HERSHEY_SIMPLEX, 0.8
    # A dark outline keeps the text readable on any background.
    cv2.putText(frame, text, position, font, scale, (0, 0, 0), 4, cv2.LINE_AA)
    cv2.putText(frame, text, position, font, scale, (255, 255, 255), 2, cv2.LINE_AA)


def camera_error_message(index):
    message = f"Error: could not open camera {index}."
    if sys.platform == "darwin":
        message += (
            "\nOn macOS, grant Terminal or your IDE camera permission in "
            "System Settings → Privacy & Security → Camera, then restart it."
        )
    return message + "\nIf the camera is in use or absent, close other apps or try --camera 1."


def run(model, cap, conf, imgsz):
    names = model.names
    colors = build_class_colors(names)
    device = pick_device()
    classes = visible_class_ids(names)
    fps = 0.0
    last = time.perf_counter()

    while True:
        ok, frame = cap.read()
        if not ok:
            print("Error: lost the camera feed.", file=sys.stderr)
            return 1

        result, scale = detect(model, frame, conf, imgsz, device, classes)
        draw_detections(frame, result, names, colors, scale)

        now = time.perf_counter()
        instant = 1.0 / max(now - last, 1e-6)
        fps = instant if fps == 0.0 else FPS_SMOOTHING * fps + (1 - FPS_SMOOTHING) * instant
        last = now
        draw_fps(frame, fps)

        cv2.imshow(WINDOW_TITLE, frame)
        if cv2.waitKey(1) & 0xFF in QUIT_KEYS:
            return 0


def main():
    args = parse_args()

    if args.images:
        return run_on_images(load_model(args.model), args.images, args.conf, args.imgsz)

    cap = None
    try:
        # Check the camera first, so a permission problem shows up before the download.
        print(f"Opening camera {args.camera} (macOS may ask for permission)...", flush=True)
        cap = cv2.VideoCapture(args.camera)
        if not cap.isOpened():
            print(camera_error_message(args.camera), file=sys.stderr)
            return 1
        model = load_model(args.model)
        return run(model, cap, args.conf, args.imgsz)
    except KeyboardInterrupt:
        return 0
    finally:
        if cap is not None:
            cap.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    sys.exit(main())
