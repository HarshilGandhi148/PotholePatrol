from huggingface_hub import hf_hub_download
from ultralytics import YOLO

# Put a copy of best.pt in this folder
path = hf_hub_download("dronefreak/rdd2022-yolov8m", "best.pt", local_dir=".")

# Convert it to Core ML for the iPhone
YOLO(path).export(format="coreml", nms=True)