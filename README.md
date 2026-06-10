# Fine-Grained Hybrid Power Modeling for On-Device Computing on Multi-Cluster SoCs

Reproducible measurement and modeling pipeline for the paper:

> Jallouli et al., "Fine-Grained Hybrid Power Modeling for On-Device Computing
> on Multi-Cluster SoCs", *Sustainable Computing: Informatics and Systems*, 2025.

---

## Repository Structure

```
.
├── scripts/
│   ├── lib/              # Shared shell libraries (ODPM, freq control, cgroups, etc.)
│   ├── collection/       # Data collection scripts for each measurement phase
│   ├── main.sh           # Top-level entry point for data collection
│   └── validate.sh       # On-device validation runner
│
├── training/             # Python model fitting scripts
│   ├── fit_alpha.py          # Phase 1: per-cluster dynamic coefficients
│   ├── fit_cluster_combos.py # Phase 2c: infrastructure + static floor
│   ├── fit_composition.py    # Full model composition and parameter export
│   └── fit_little_floor.py   # Per-cluster static floor fitting
│
├── validation/           # Python evaluation scripts
│   ├── evaluate_full_model.py  # Held-out and cross-λ validation
│   ├── score_baseline.py       # Baseline model comparison
│   └── validate_all_rhos.py    # Per-λ accuracy report
│
├── ml_inference/         # ML inference measurement and scoring
│   ├── ml_inference_merged.sh  # Inference data collection script
│   └── score_ml_inference.py   # Energy prediction evaluation
│
└── data/
    ├── pixel8pro/        # Tensor G3 (Pixel 8 Pro) measurements
    │   ├── phase1/           # Isolated per-cluster measurements
    │   ├── phase1b_thermal/  # Single-cluster thermal sweeps
    │   ├── phase2/           # Full-CPU thermal sweeps (pre/post throttling)
    │   ├── phase2b_thermal/  # Per-λ thermal sweeps
    │   ├── phase2c_combos/   # Pairwise cluster combination sweeps
    │   ├── phase3/           # Asymmetric utilization validation
    │   ├── ml_inference/     # ML inference power logs (1-hour runs)
    │   └── params/           # Fitted model parameters (JSON)
    └── pixel9/           # Tensor G4 (Pixel 9) measurements
        ├── phase1/
        ├── phase2/
        ├── phase2b_thermal/
        ├── phase2c_combos/
        └── params/
```

---

## Requirements

### On-device (Android, Termux)
- Termux with root or ADB shell access
- stress-ng installed (`pkg install stress-ng`)
- Device: Google Pixel 8 Pro (Tensor G3) or Pixel 9 (Tensor G4)

### Offline (macOS / Linux)
```bash
pip install numpy scipy pandas matplotlib
```

---

## Reproducing the Results

### Step 1 — Data Collection (on device)
```bash
# Isolated per-cluster measurements
bash scripts/collection/isolated.sh

# Pairwise cluster combination sweeps
bash scripts/collection/cluster_combo.sh

# Continuous thermal profiling
bash scripts/collection/thermal_sweep.sh
```

### Step 2 — Model Fitting (offline)
```bash
python training/fit_alpha.py          # Fit C_eff per cluster
python training/fit_cluster_combos.py # Fit kappa_infra, kappa_floor
python training/fit_composition.py    # Assemble full model
```

### Step 3 — Validation (offline)
```bash
python validation/evaluate_full_model.py  # Held-out + cross-λ
python validation/score_baseline.py       # Baseline comparison
python validation/validate_all_rhos.py    # Per-λ table
```

### Step 4 — ML Inference Evaluation (offline)
```bash
python ml_inference/score_ml_inference.py
```

---

## Fitted Parameters

Pre-fitted parameters for both devices are in `data/<device>/params/`:

| File | Contents |
|------|----------|
| `composition_params.json` | Full model: C_eff, leakage, infra, floor |
| `composition_simple_params.json` | Dynamic-only baseline parameters |
| `combo_infra_params.json` | Infrastructure term per cluster combo |
| `static_floor_params.json` | Per-cluster static floor coefficients |

---

## Citation

```bibtex
@article{jallouli2025hybrid,
  title   = {Fine-Grained Hybrid Power Modeling for On-Device Computing
             on Multi-Cluster {SoC}s},
  author  = {Jallouli, Chaimae and Boubouh, Karim and Basmadjian, Robert},
  journal = {Sustainable Computing: Informatics and Systems},
  year    = {2025}
}
```

---

## License

MIT License. See `LICENSE` for details.
