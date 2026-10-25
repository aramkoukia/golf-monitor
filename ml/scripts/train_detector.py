"""Fine-tune an Ultralytics YOLO detector on the assembled golf dataset (MPS).

Usage: python train_detector.py <data.yaml> <project_dir> <run_name> [epochs] [base]
"""
import sys
from ultralytics import YOLO

data, project, name = sys.argv[1], sys.argv[2], sys.argv[3]
epochs = int(sys.argv[4]) if len(sys.argv) > 4 else 60
base = sys.argv[5] if len(sys.argv) > 5 else "yolo11n.pt"
model = YOLO(base)
model.train(
    data=data, project=project, name=name, exist_ok=True,
    epochs=epochs, imgsz=640, batch=16, device="mps", workers=6,
    patience=25, cos_lr=True, close_mosaic=10,
    # Small, fast objects: keep scale jitter moderate, no rotation, no vertical flip.
    scale=0.4, degrees=0.0, flipud=0.0, fliplr=0.5, mosaic=1.0, mixup=0.0,
    hsv_h=0.015, hsv_s=0.5, hsv_v=0.4, plots=True, verbose=True,
)
metrics = model.val(data=data, imgsz=640, device="mps")
print("FINAL mAP50", metrics.box.map50, "mAP50-95", metrics.box.map)
