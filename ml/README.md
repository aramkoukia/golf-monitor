# GolfMonitor on-device models

Everything here runs **on the iPhone** (Core ML / Vision). Nothing is sent to
a server. Models ship precompiled (`.mlmodelc`) in
`GolfMonitor/Resources/MLModels/` because Xcode's sandboxed Core ML build step
can't run in every environment; the source `.mlpackage`s live in
`ml/models/`.

**Bundled artifacts in this checkout:** `COCODetector.mlmodelc` and
`GolferPose.mlmodelc` are present under `GolfMonitor/Resources/MLModels/`.
The trained `GolfBallDetector.mlpackage` at the repository root is also added
to the app target and compiled by Xcode; `ModelCatalog` loads it as the
`GolfDetector` model. `SwingNetEncoder` and `SwingNetSequence` are not
bundled, so the app does not run SwingNet. `GolfDetector` is used for
calibration and periodic ball detection during recorded-clip analysis; the
v1 blob tracker fills in frame-to-frame continuity and still tracks the club.
See `docs/V2_PLAN.md`.

| Model | File | What it does | Base / licence |
|---|---|---|---|
| **GolfDetector** | `GolfBallDetector.mlpackage` (Xcode compiled) | Detects golf balls (fine-tuned YOLOv8n). Used for calibration and periodic ball detection during recorded-clip tracking. | Ultralytics YOLOv8n fine-tuned by us → AGPL-3.0 (Ultralytics) |
| **GolferPose** | `GolferPose.mlmodelc` (bundled) | 17-keypoint body pose (YOLO11n-pose). Fallback when Apple Vision body pose is unavailable (e.g. Simulator). | Ultralytics YOLO11n-pose → AGPL-3.0 |
| **SwingNet** | `SwingNetEncoder.mlmodelc` + `SwingNetSequence.mlmodelc` (not bundled) | Intended GolfDB swing-event detector (address, takeaway, half-way back, top, delivery, impact, release, finish). MobileNetV2 + BiLSTM. | McNally et al., *GolfDB* (CVPRW 2019) — **CC BY-NC 4.0** (non-commercial) |
| COCODetector | `COCODetector.mlmodelc` (bundled) | Generic COCO YOLOv8n sports-ball fallback for calibration. Not golf-specific. | Ultralytics → AGPL-3.0 |
| Apple Vision | (system) | Primary body pose on device (`VNDetectHumanBodyPoseRequest`). | Apple |

Because the bundled Ultralytics-derived models are AGPL-3.0 and SwingNet is
CC BY-NC 4.0, GolfMonitor must stay **open source and non-commercial** while
it ships them.

## GolfDetector: data and training

Golf-specific detection was the missing piece of v1 (the generic COCO model
rarely finds a golf ball and has no club class). There is no single open
dataset with phone footage of balls, clubs and club heads, so the detector is
**distilled**: open datasets with ground truth are combined with
pseudo-labels from teacher models, plus synthetic small/motion-blurred balls.

### Sources (all downloadable without an account)

| Source | Content | Licence |
|---|---|---|
| [Open Images V7](https://storage.googleapis.com/openimages/web/index.html) "Golf ball" boxes | 386 images, 532 human boxes (group boxes dropped) | Annotations CC BY 4.0, images CC BY 2.0 |
| Open Images V7 image-level labels | 1,272 golfer / golf-club scenes; 245 scenes with golf ball *verified absent* (hard negatives); 1,500 outdoor grass/sky scenes (backgrounds, negatives) | CC BY 4.0 / CC BY 2.0 |
| [QUT Golf Ball Detector v4](https://universe.roboflow.com/queensland-university-of-technology-ltic3/golf-ball-detector-3gtdk/dataset/4) (mirror: `huggingface.co/jamesrowe08/yolov5-golf`) | random 7,000-image sample of 39,921 train images (range-read from the archive) | CC BY 4.0 |
| [galf](https://universe.roboflow.com/clg-plzss/galf) test split (mirror: `github.com/bc005007/YOLO_train`) | 1,020 phone-footage images: 931 balls, 839 club heads, 546 club boxes | CC BY 4.0 |
| Wikimedia Commons golf videos/images | CC0 / public-domain / CC BY clips (Kanagawa practice swing — Nesnad, CC BY 4.0; Diego Garcia Long Drive — U.S. Navy, PD; Man practicing golf swing — Nesnad, CC BY 4.0) and permissively licensed driving-range / ball / club photos | per file (see `data/commons-manifest.json` at training time) |
| Synthetic | 7,000 composites: real + procedurally rendered balls (white/yellow/pink/orange range balls) pasted at 5–56 px with directional motion blur and shadows onto ball-free backgrounds (`scripts/synth_balls.py`) | ours |

**Held-out test set:** the CC0 clip *Suvichaya Vinijchaitham Golf Swing Slow
Mo 2026* (Wikimedia Commons, CC0) — four swings (face-on/down-the-line, iron
and driver) shot in 240 fps slow motion. It is never used for training; it is
also bundled as demo content.

### Teachers (used only to create labels — not shipped)

- club / club head: a Core ML Ultralytics detector with classes `{club, head}`
  from the GolfTracer iOS project (github.com/jeremiahgivens/GolfTracer)
- golf ball: OpenFlight's YOLO11n golf-ball ONNX (github.com/open-flight/openflight, AGPL-3.0),
  run on native-resolution tiles
- hands: Ultralytics YOLO11n-pose wrists, to reject gloves/club heads detected as balls

Uncertain teacher detections are blurred out of the training image rather
than left as unlabeled objects (`scripts/autolabel_teachers.py`).

### Pipeline

```
scripts/fetch_openimages_golfball.py      Open Images golf-ball boxes → YOLO
scripts/fetch_openimages_backgrounds.py   ball-verified-absent golf scenes
scripts/fetch_openimages_outdoor.py       grass/sky/net backgrounds
scripts/fetch_openimages_golfers.py       golfer / club scenes
scripts/zip_range_extract.py              sample members of a remote dataset ZIP
scripts/synth_balls.py                    synthetic small / blurred balls
scripts/autolabel_teachers.py             teacher pseudo-labels (club, head, ball)
scripts/build_dataset_v2.py               merge + native-resolution 640 crops + split
scripts/train_detector.py                 YOLO11n fine-tune on Apple Silicon (MPS)
scripts/export_coreml.py                  Core ML (NMS pipeline, fp16) + compile
scripts/eval_detector.py                  held-out CC0 evaluation vs teacher pseudo-GT
scripts/swingnet_export.py                SwingNet → two Core ML models
```

Two Python environments are used: a training env (PyTorch + Ultralytics) and
an export env pinned to `numpy<2`, `torch 2.7`, `coremltools 8.3` (newer
NumPy/PyTorch break the coremltools converter).

### Results

See the bottom of this file (filled in after training).
