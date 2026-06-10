# mobile-soc-power-modeling

Measurement and modeling pipeline accompanying the paper **"Fine-Grained Hybrid Power Modeling for On-Device Computing on Multi-Cluster SoCs"**, published in *Sustainable Computing: Informatics and Systems*.

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

## Usage

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

### 4 — ML inference evaluation (offline)
```bash
python ml_inference/score_ml_inference.py
```

---

Fitted parameters for both devices are available under `data/<device>/params/`.
