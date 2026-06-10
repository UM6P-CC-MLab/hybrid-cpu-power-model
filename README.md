# mobile-soc-power-modeling

Measurement and modeling pipeline accompanying the paper **"Fine-Grained Hybrid Power Modeling for On-Device Computing on Multi-Cluster SoCs"**, submitted in *Sustainable Computing: Informatics and Systems*.

Tested on Google Pixel 8 Pro (Tensor G3) and Pixel 9 (Tensor G4).

---

## Requirements

**On device (Termux)**
```bash
pkg install stress-ng
```

**Offline**
```bash
pip install numpy scipy pandas matplotlib
```

---

## Power Model

### 1 — Collect data (on device)
```bash
bash scripts/collection/isolated.sh       # per-cluster measurements
bash scripts/collection/cluster_combo.sh  # pairwise cluster sweeps
bash scripts/collection/thermal_sweep.sh  # continuous thermal profiling
```

### 2 — Fit the model (offline)
```bash
python training/fit_alpha.py
python training/fit_cluster_combos.py
python training/fit_composition.py
```

### 3 — Validate (offline)
```bash
python validation/evaluate_full_model.py
python validation/validate_all_rhos.py
python validation/score_baseline.py
```

Pre-fitted parameters for both devices are available under `data/<device>/params/`.

---

## ML Inference Evaluation

Models used: **MobileNetV1** (INT8), **MobileNetV2** (float32), **EfficientNet-Lite0** (INT8).

### 1 — Download models (laptop)
```bash
# MobileNetV1 INT8
curl -O https://storage.googleapis.com/download.tensorflow.org/models/tflite/mobilenet_v1_1.0_224_quant_and_labels.zip
unzip mobilenet_v1_1.0_224_quant_and_labels.zip

# MobileNetV2 float32
curl -O https://storage.googleapis.com/download.tensorflow.org/models/tflite_11_05_08/mobilenet_v2_1.0_224.tgz
tar -xzf mobilenet_v2_1.0_224.tgz

# EfficientNet-Lite0 INT8
curl -O https://storage.googleapis.com/cloud-tpu-checkpoints/efficientnet/lite/efficientnet-lite0-int8.tflite
```

### 2 — Push models to device
```bash
adb push mobilenet_v1_1.0_224_quant.tflite     /data/local/tmp/models/
adb push mobilenet_v2_1.0_224.tflite            /data/local/tmp/models/
adb push efficientnet-lite0-int8.tflite         /data/local/tmp/models/
```

### 3 — Run inference and collect power (on device)
```bash
bash ml_inference/ml_inference_merged.sh
```

### 4 — Score predictions (offline)
```bash
python ml_inference/score_ml_inference.py
```
