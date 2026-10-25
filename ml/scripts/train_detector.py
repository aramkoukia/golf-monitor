"""Fine-tune an Ultralytics YOLO detector on the assembled golf dataset
(Apple Silicon / MPS).

Usage:
  python train_detector.py --data <data.yaml> --project <dir> --name <run> \
      [--epochs 30] [--hours 4.5] [--imgsz 640] [--batch 16] [--workers 4] [--base yolo11n.pt]
"""
import argparse

from ultralytics import YOLO

ap = argparse.ArgumentParser()
ap.add_argument("--data", required=True)
ap.add_argument("--project", required=True)
ap.add_argument("--name", required=True)
ap.add_argument("--epochs", type=int, default=30)
ap.add_argument("--hours", type=float, default=0, help="wall-clock cap; 0 = none")
ap.add_argument("--imgsz", type=int, default=640)
ap.add_argument("--batch", type=int, default=16)
ap.add_argument("--workers", type=int, default=4)
ap.add_argument("--base", default="yolo11n.pt")
ap.add_argument("--resume", action="store_true")
a = ap.parse_args()

model = YOLO(a.base)
extra = {"time": a.hours} if a.hours > 0 else {}
model.train(
    data=a.data, project=a.project, name=a.name, exist_ok=True, resume=a.resume,
    epochs=a.epochs, imgsz=a.imgsz, batch=a.batch, device="mps", workers=a.workers,
    patience=12, cos_lr=True, close_mosaic=5, save_period=1,
    # Small, fast objects: moderate scale jitter, no rotation, no vertical flip.
    # Horizontal flip doubles as left-handed golfers.
    scale=0.35, degrees=0.0, flipud=0.0, fliplr=0.5, mosaic=1.0, mixup=0.0,
    hsv_h=0.015, hsv_s=0.5, hsv_v=0.4, plots=True, verbose=True,
    **extra,
)
metrics = model.val(data=a.data, imgsz=a.imgsz, device="mps")
print("FINAL mAP50", metrics.box.map50, "mAP50-95", metrics.box.map)
for i, name in model.names.items():
    try:
        print(f"CLASS {name}: AP50 {metrics.box.ap50[i]:.3f}")
    except Exception:  # noqa: BLE001
        pass
