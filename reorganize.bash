#!/usr/bin/env bash
# reorganize.sh — run from the root of your throttling_study repo
# Creates the clean structure in-place. Safe: nothing is deleted until
# you explicitly run the cleanup block at the bottom.
set -euo pipefail

REPO_ROOT="$(pwd)"

# ─────────────────────────────────────────────
# 1. CREATE TARGET DIRECTORY STRUCTURE
# ─────────────────────────────────────────────
mkdir -p scripts/lib
mkdir -p scripts/collection
mkdir -p training
mkdir -p validation
mkdir -p ml_inference
mkdir -p data/pixel8pro/params
mkdir -p data/pixel8pro/phase1
mkdir -p data/pixel8pro/phase1b_thermal
mkdir -p data/pixel8pro/phase2
mkdir -p data/pixel8pro/phase2b_thermal
mkdir -p data/pixel8pro/phase2c_combos
mkdir -p data/pixel8pro/phase3
mkdir -p data/pixel8pro/ml_inference
mkdir -p data/pixel9/params
mkdir -p data/pixel9/phase1
mkdir -p data/pixel9/phase2
mkdir -p data/pixel9/phase2b_thermal
mkdir -p data/pixel9/phase2c_combos

# ─────────────────────────────────────────────
# 2. MOVE SHELL LIBRARIES
# ─────────────────────────────────────────────
for f in lib/cgroups.sh lib/common.sh lib/freq_control.sh lib/measure.sh \
          lib/odpm.sh lib/stress.sh lib/thermal.sh lib/validate.sh; do
  [ -f "$f" ] && mv "$f" "scripts/lib/$(basename $f)"
done

# ─────────────────────────────────────────────
# 3. MOVE DATA COLLECTION SCRIPTS
# ─────────────────────────────────────────────
for f in data/isolated.sh data/thermal_sweep.sh \
          data/cluster_combo.sh data/combined.sh; do
  [ -f "$f" ] && mv "$f" "scripts/collection/$(basename $f)"
done

# ─────────────────────────────────────────────
# 4. MOVE TOP-LEVEL SCRIPTS
# ─────────────────────────────────────────────
[ -f main.sh ]     && mv main.sh     scripts/main.sh
[ -f validate.sh ] && mv validate.sh scripts/validate.sh

# ─────────────────────────────────────────────
# 5. MOVE ML INFERENCE SCRIPTS
# ─────────────────────────────────────────────
[ -f ml_inference/ml_inference_merged.sh ] && \
  mv ml_inference/ml_inference_merged.sh ml_inference/ml_inference_merged.sh
[ -f ml_inference/score_ml_inference.py ] && \
  mv ml_inference/score_ml_inference.py ml_inference/score_ml_inference.py

# ─────────────────────────────────────────────
# 6. PIXEL 8 PRO — MEASUREMENT DATA
# ─────────────────────────────────────────────
# Phase 1 — isolated
for f in throttling_data/pixel8pro/phase1/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/phase1/"
done

# Phase 1b — single-cluster thermal
for f in throttling_data/pixel8pro/phase1b_thermal/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/phase1b_thermal/"
done

# Phase 2 — thermal sweeps
for f in throttling_data/pixel8pro/phase2/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/phase2/"
done

# Phase 2b — thermal rho sweeps
for f in throttling_data/pixel8pro/phase2b_thermal/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/phase2b_thermal/"
done

# Phase 2c — pairwise cluster combos
for f in throttling_data/pixel8pro/phase2c_combos/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/phase2c_combos/"
done

# Phase 3 — asymmetric rho validation
for f in throttling_data/pixel8pro/phase3/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/phase3/"
done

# Fitted parameters (JSON)
for f in throttling_data/pixel8pro/*.json; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/params/"
done

# Derived fitting datasets (CSV at root level)
for f in throttling_data/pixel8pro/fitting_dataset_phase1.csv \
         throttling_data/pixel8pro/fitting_dataset_phase2.csv \
         throttling_data/pixel8pro/baseline_comparison.csv \
         throttling_data/pixel8pro/baseline_cross_lambda.csv \
         throttling_data/pixel8pro/cross_rho_validation.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/"
done

# ML inference — only latest/
for f in throttling_data/pixel8pro/ml_inference/latest/*.csv \
         throttling_data/pixel8pro/ml_inference/latest/*.txt; do
  [ -f "$f" ] && mv "$f" "data/pixel8pro/ml_inference/"
done

# ─────────────────────────────────────────────
# 7. PIXEL 9 — MEASUREMENT DATA
# ─────────────────────────────────────────────
for f in throttling_data/pixel9/phase1/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel9/phase1/"
done

for f in throttling_data/pixel9/phase2/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel9/phase2/"
done

for f in throttling_data/pixel9/phase2b_thermal/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel9/phase2b_thermal/"
done

for f in throttling_data/pixel9/phase2c_combos/*.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel9/phase2c_combos/"
done

for f in throttling_data/pixel9/*.json; do
  [ -f "$f" ] && mv "$f" "data/pixel9/params/"
done

for f in throttling_data/pixel9/fitting_dataset_phase1.csv \
         throttling_data/pixel9/fitting_dataset_phase2.csv \
         throttling_data/pixel9/cross_rho_validation.csv; do
  [ -f "$f" ] && mv "$f" "data/pixel9/"
done

# ─────────────────────────────────────────────
# 8. WRITE .gitignore
# ─────────────────────────────────────────────
cat > .gitignore << 'EOF'
# macOS
.DS_Store
.AppleDouble
.LSOverride

# IDE
.idea/
*.iml
.vscode/

# Python
__pycache__/
*.py[cod]
*.egg-info/
.env
.venv/

# Generated outputs — reproducible from scripts
data/**/plots/
throttling_data/

# Old / unused data — not part of reproducible pipeline
**/unused/
**/old/
**/initial/
**/pinned/
**/unplugged/
**/upgraded/
EOF

# ─────────────────────────────────────────────
# 9. WRITE README.md
# ─────────────────────────────────────────────
cat > README.md << 'EOF'
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
EOF

# ─────────────────────────────────────────────
# 10. CLEANUP — remove empty dirs and junk
#     (only runs after all moves succeed)
# ─────────────────────────────────────────────
echo ""
echo "=== Moves complete. Cleaning up... ==="

# Remove .DS_Store files recursively
find . -name ".DS_Store" -delete

# Remove now-empty source directories
rm -rf lib/
rm -rf data/                        # original data/ (collection scripts), now empty
rm -rf throttling_data/             # all originals moved or intentionally excluded
rm -rf .idea/

# Remove untitled folder
rm -rf "throttling_data/pixel9/untitled folder" 2>/dev/null || true

echo ""
echo "=== Done. New structure: ==="
find . -not -path './.git/*' -not -name '.DS_Store' | sort
