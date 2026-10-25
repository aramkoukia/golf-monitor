"""Export a trained YOLO .pt to a Core ML detector with built-in NMS, then
compile it to .mlmodelc for bundling (Xcode's CoreML build step is bypassed).

Run with the pinned export venv (numpy<2, torch 2.7, coremltools 8.3):
  python export_coreml.py <best.pt> <out_dir> <ModelName> [imgsz]
"""
import os, shutil, subprocess, sys
from ultralytics import YOLO

pt, out_dir, name = sys.argv[1], sys.argv[2], sys.argv[3]
imgsz = int(sys.argv[4]) if len(sys.argv) > 4 else 640
os.makedirs(out_dir, exist_ok=True)
pkg = YOLO(pt).export(format="coreml", imgsz=imgsz, nms=True, half=True)
dst_pkg = os.path.join(out_dir, f"{name}.mlpackage")
shutil.rmtree(dst_pkg, ignore_errors=True)
shutil.move(pkg, dst_pkg)
tmp = os.path.join(out_dir, "_compiled")
shutil.rmtree(tmp, ignore_errors=True)
os.makedirs(tmp)
subprocess.run(["xcrun", "coremlcompiler", "compile", dst_pkg, tmp], check=True, stdout=subprocess.DEVNULL)
compiled = os.path.join(out_dir, f"{name}.mlmodelc")
shutil.rmtree(compiled, ignore_errors=True)
shutil.move(os.path.join(tmp, f"{name}.mlmodelc"), compiled)
shutil.rmtree(tmp)
print("exported", dst_pkg, compiled)
