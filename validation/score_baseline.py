#!/usr/bin/env python3
"""
score_baselines.py - Compare baseline power models against our hybrid model.

Models evaluated:
  1. Carroll and Heiser 2010:  per-frequency lookup table
  2. Zhang et al. 2010:        P = (beta_uh*freq_h + beta_ul*freq_l)*util + beta_CPU
  3. Baek and Liu 2015:        P_c = alpha_c * V_c^2 * f_c  (single-point)
  4. Hybrid (ours):            P = sum_c [alpha_c * V_c^2 * f_c * rho_c]
                                 + sum_c [beta_floor_c * delta_bys_c]
                                 + P_infra * delta_act
                                 + P0 * exp(T_max / T0)

Validation procedure — identical to fit_composition.py + validate_all_rhos.py:

  Training data (baselines fitted here, hybrid params loaded from JSON):
    - Phase 2 stress rows with T_max < 55°C
    - 80% of pre-throttle thermal rows across all lambda values,
      stratified by lambda (same seed=42 as fit_composition.py)

  Evaluation sets:
    - Test set:      remaining 20% of pre-throttle thermal (stratified by lambda)
    - Stress test:   ALL post-throttle rows pooled across every lambda value
    - Cross-lambda:  full thermal sweep (pre+post) scored per lambda file

Usage:
    python3 score_baselines.py <data_root>
"""

import sys
import json
import re
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from sklearn.model_selection import StratifiedShuffleSplit

plt.rcParams.update({
    "axes.grid": True,
    "grid.alpha": 0.3,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "font.size": 11,
})

T_PHASE2_MAX = 55.0
TRAIN_FRAC   = 0.80
SPLIT_SEED   = 42

# Bystander threshold — cluster c is a bystander when rho_c < this
RHO_BYSTANDER = 0.05
# Active threshold — any cluster above this activates P_infra
RHO_ACTIVE    = 0.10

FEATURE_COLS = ["V_little", "V_big", "V_prime",
                "f_little", "f_big", "f_prime",
                "rho_little", "rho_big", "rho_prime",
                "T_little", "T_big", "T_prime",
                "measured_W", "source", "lambda_val"]


# ---------------------------------------------------------------------------
# Column helpers
# ---------------------------------------------------------------------------

def _coerce(df: pd.DataFrame) -> pd.DataFrame:
    num_cols = [
        "timestamp_ms", "cpu_total_W",
        "freq_cpu0", "freq_cpu4", "freq_cpu8", "freq_cpu7",
        "v_little_V", "v_big_V", "v_prime_V",
        "t_little_C", "t_big_C", "t_prime_C",
        "rho_little", "rho_big", "rho_prime",
        "usage_cpu0", "usage_cpu1", "usage_cpu2", "usage_cpu3",
        "usage_cpu4", "usage_cpu5", "usage_cpu6", "usage_cpu7", "usage_cpu8",
    ]
    for c in num_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def _get_prime_col(df: pd.DataFrame) -> str:
    return "freq_cpu8" if "freq_cpu8" in df.columns else "freq_cpu7"


def _normalise(df: pd.DataFrame) -> pd.DataFrame:
    prime_col = _get_prime_col(df)
    df = df.rename(columns={
        "v_little_V": "V_little", "v_big_V": "V_big", "v_prime_V": "V_prime",
        "freq_cpu0":  "f_little", "freq_cpu4": "f_big", prime_col:  "f_prime",
        "t_little_C": "T_little", "t_big_C":  "T_big", "t_prime_C": "T_prime",
    })
    # Recompute rho from usage_cpu* columns — same logic as evaluate_full_model.py
    # Priority: existing rho_* column → recompute from usage_cpu* → fallback 1.0
    cluster_cores = {
        "little": list(range(4)),
        "big":    [4, 5, 6, 7],
        "prime":  [8, 7],   # cpu8 on G3, cpu7 on G4
    }
    for cluster, cores in cluster_cores.items():
        col = f"rho_{cluster}"
        usage_cols = [f"usage_cpu{c}" for c in cores if f"usage_cpu{c}" in df.columns]
        if usage_cols:
            usage  = df[usage_cols].apply(pd.to_numeric, errors="coerce").fillna(0.0)
            online = usage.columns[(usage > 0).any(axis=0)].tolist()
            computed = usage[online].mean(axis=1) / 100.0 if online else pd.Series(0.0, index=df.index)
            # Use computed if rho column missing or all-zero
            if col not in df.columns or df[col].abs().sum() == 0:
                df[col] = computed
            else:
                df[col] = pd.to_numeric(df[col], errors="coerce").fillna(computed)
        elif col not in df.columns:
            df[col] = 1.0  # no usage data available — assume full utilization
    return df


def _split_pre_post(stress: pd.DataFrame) -> tuple:
    f_l_init = stress["f_little"].iloc[0]
    f_b_init = stress["f_big"].iloc[0]
    f_p_init = stress["f_prime"].iloc[0]
    throttled = (
        (stress["f_little"] < f_l_init) |
        (stress["f_big"]    < f_b_init) |
        (stress["f_prime"]  < f_p_init)
    )
    boundary = int(throttled.idxmax()) if throttled.any() else len(stress)
    return stress.iloc[:boundary].copy(), stress.iloc[boundary:].copy()


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_phase2(root: Path) -> pd.DataFrame:
    phase2_dir = root / "phase2"
    if not phase2_dir.exists():
        raise FileNotFoundError(f"No phase2/ directory in {root}")
    dfs = []
    for csv_file in sorted(phase2_dir.glob("*.csv")):
        df = _coerce(pd.read_csv(csv_file, sep=None, engine="python", decimal=","))
        stress = df[df["workload"] == "stress"].copy() if "workload" in df.columns else df.copy()
        if len(stress) > 0:
            dfs.append(stress)
    raw = pd.concat(dfs, ignore_index=True)
    raw = _normalise(raw)
    raw["measured_W"] = raw["cpu_total_W"]
    raw["source"]     = "phase2"
    raw["lambda_val"] = 1.0
    raw["T_max"]      = raw[["T_little", "T_big", "T_prime"]].max(axis=1)
    n_before = len(raw)
    raw = raw[raw["T_max"] < T_PHASE2_MAX].copy()
    print(f"  Phase 2 T filter (< {T_PHASE2_MAX}°C): {n_before} → {len(raw)} rows")
    # Ensure rho columns exist
    for col in ["rho_little", "rho_big", "rho_prime"]:
        if col not in raw.columns:
            raw[col] = 1.0
    return raw[FEATURE_COLS].dropna().reset_index(drop=True)


def load_all_thermal_sweeps(root: Path) -> tuple:
    thermal_dir = root / "phase2b_thermal"
    if not thermal_dir.exists():
        raise FileNotFoundError(f"No phase2b_thermal/ directory in {root}")
    pre_dfs, post_dfs = [], []
    for csv_file in sorted(thermal_dir.glob("thermal_rho_*.csv")):
        stem  = csv_file.stem
        parts = stem.split("_")
        try:
            lam = float(parts[parts.index("rho") + 1])
        except (ValueError, IndexError):
            continue
        df = _coerce(pd.read_csv(csv_file, sep=None, engine="python", decimal=","))
        stress = df[df["workload"] == "stress"].copy().reset_index(drop=True) \
                 if "workload" in df.columns else df.copy()
        if len(stress) == 0:
            continue
        stress = _normalise(stress)
        stress["measured_W"] = stress["cpu_total_W"]
        stress["lambda_val"] = lam
        pre, post = _split_pre_post(stress)
        pre["source"]  = f"thermal_pre_lam{lam:.2f}"
        post["source"] = f"thermal_post_lam{lam:.2f}"
        # Ensure rho columns
        for col in ["rho_little", "rho_big", "rho_prime"]:
            for part in [pre, post]:
                if col not in part.columns:
                    part[col] = lam
        pre_clean  = pre[FEATURE_COLS].dropna()
        post_clean = post[FEATURE_COLS].dropna()
        if len(pre_clean)  > 0: pre_dfs.append(pre_clean)
        if len(post_clean) > 0: post_dfs.append(post_clean)
        print(f"    λ={lam:.2f}: pre={len(pre_clean)}  post={len(post_clean)}")
    pre_all  = pd.concat(pre_dfs,  ignore_index=True) if pre_dfs  else pd.DataFrame(columns=FEATURE_COLS)
    post_all = pd.concat(post_dfs, ignore_index=True) if post_dfs else pd.DataFrame(columns=FEATURE_COLS)
    return pre_all, post_all


def stratified_split(df: pd.DataFrame) -> tuple:
    strata = df["lambda_val"].round(2).astype(str).values
    sss = StratifiedShuffleSplit(
        n_splits=1, test_size=1.0 - TRAIN_FRAC, random_state=SPLIT_SEED
    )
    train_idx, test_idx = next(sss.split(df, strata))
    return df.iloc[train_idx].copy(), df.iloc[test_idx].copy()


def load_full_sweeps_per_lambda(root: Path) -> dict:
    thermal_dir = root / "phase2b_thermal"
    sweeps = {}
    for csv_file in sorted(thermal_dir.glob("thermal_rho_*.csv")):
        m = re.search(r"thermal_rho_(\d+\.\d+)", csv_file.name)
        if not m:
            continue
        lam = float(m.group(1))
        df  = _coerce(pd.read_csv(csv_file, sep=None, engine="python", decimal=","))
        stress = df[df["workload"] == "stress"].copy().reset_index(drop=True) \
                 if "workload" in df.columns else df.copy()
        if len(stress) < 3:
            continue
        stress = _normalise(stress)
        stress["measured_W"] = stress["cpu_total_W"]
        stress["lambda_val"] = lam
        stress["source"]     = f"thermal_full_lam{lam:.2f}"
        for col in ["rho_little", "rho_big", "rho_prime"]:
            if col not in stress.columns:
                stress[col] = lam
        sweeps[lam] = stress[FEATURE_COLS].dropna().reset_index(drop=True)
    return sweeps


def load_hybrid_params(root: Path) -> tuple:
    """Load all four-term model parameters."""
    params_path = root / "composition_simple_params.json"
    with open(params_path) as f:
        params = json.load(f)
    if "alphas_fit" in params and "alphas" not in params:
        params["alphas"] = {c: {"alpha": params["alphas_fit"][c]["alpha"]}
                            for c in ["little", "big", "prime"]}

    # Infrastructure params — use median of P_infra_at_inference_W
    # to match evaluate_full_model.py exactly
    P_infra = 0.0
    infra_path = root / "combo_infra_params.json"
    if infra_path.exists():
        with open(infra_path) as f:
            infra = json.load(f)
        combos = infra.get("combos", {})
        vals = [v["P_infra_at_inference_W"] for v in combos.values()
                if np.isfinite(v.get("P_infra_at_inference_W", float("nan")))]
        P_infra = float(np.median(vals)) if vals else 0.0
        print(f"  P_infra = {P_infra:.4f} W  (median P_infra_at_inference_W across combos)")
    else:
        print("  combo_infra_params.json not found — P_infra=0")

    # Static floor params
    P_static = {}
    static_path = root / "static_floor_params.json"
    if static_path.exists():
        with open(static_path) as f:
            static = json.load(f)
        for cl, v in static.get("P_static", {}).items():
            val = float(v.get("P_static_at_inference_W", v.get("P_static_W", 0.0)))
            if val > 0:
                P_static[cl] = val
        print(f"  P_static = { {k: round(v,4) for k,v in P_static.items()} }")
    else:
        print("  static_floor_params.json not found — P_static=0")

    return params, P_infra, P_static


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def metrics(measured: np.ndarray, predicted: np.ndarray, label: str = "") -> dict:
    res    = measured - predicted
    rmse   = float(np.sqrt(np.mean(res ** 2)))
    mae    = float(np.mean(np.abs(res)))
    bias   = float(np.mean(res))
    ss_res = float(np.sum(res ** 2))
    ss_tot = float(np.sum((measured - measured.mean()) ** 2))
    r2     = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    rel    = 100.0 * rmse / measured.mean() if measured.mean() > 0 else float("nan")
    return {
        "model":       label,
        "n":           int(len(measured)),
        "rmse_W":      round(rmse,  4),
        "mae_W":       round(mae,   4),
        "bias_W":      round(bias,  4),
        "r2":          round(r2,    4),
        "rel_pct":     round(rel,   2),
        "mean_meas_W": round(float(measured.mean()),    4),
        "mean_pred_W": round(float(np.mean(predicted)), 4),
    }


# ---------------------------------------------------------------------------
# Model 1 — Carroll and Heiser 2010
# ---------------------------------------------------------------------------

def build_carroll_lookup(root: Path) -> dict:
    phase1_dir = root / "phase1"
    if not phase1_dir.exists():
        raise FileNotFoundError(f"No phase1/ directory in {root}")
    lookup = {"little": {}, "big": {}, "prime": {}}
    cluster_freq_col  = {"little": "f_little_kHz", "big": "f_big_kHz",  "prime": "f_prime_kHz"}
    cluster_power_col = {"little": "little_W",      "big": "big_W",      "prime": "prime_W"}
    for csv_file in sorted(phase1_dir.glob("*.csv")):
        df = pd.read_csv(csv_file, sep=None, engine="python")
        if "active_clusters" not in df.columns or len(df) == 0:
            continue
        cluster = df["active_clusters"].iloc[0]
        if cluster not in lookup:
            continue
        stress = df[df["workload"] == "stress"].copy() if "workload" in df.columns else df.copy()
        if len(stress) == 0:
            continue
        f_col = cluster_freq_col.get(cluster)
        p_col = cluster_power_col.get(cluster, "cpu_total_W")
        for c in [f_col, p_col]:
            if c and c in stress.columns:
                stress[c] = pd.to_numeric(stress[c], errors="coerce")
        freq_hz = (float(stress[f_col].mean()) * 1e3
                   if f_col and f_col in stress.columns else 0.0)
        if p_col not in stress.columns:
            p_col = "cpu_total_W"
        p_stress = float(pd.to_numeric(stress[p_col], errors="coerce").mean())
        if not np.isnan(p_stress) and freq_hz > 0:
            lookup[cluster][freq_hz] = p_stress
    for cluster, table in lookup.items():
        n = len(table)
        f_range = (f"{min(table)/1e6:.1f}–{max(table)/1e6:.1f} GHz" if n > 0 else "none")
        print(f"    {cluster}: {n} points ({f_range})")
    return lookup


def predict_carroll(df: pd.DataFrame, lookup: dict) -> np.ndarray:
    f_map = {"little": "f_little", "big": "f_big", "prime": "f_prime"}
    total = np.zeros(len(df))
    for cluster, f_col in f_map.items():
        table = lookup.get(cluster, {})
        if not table or f_col not in df.columns:
            continue
        freqs   = np.array(sorted(table.keys()))
        powers  = np.array([table[f] for f in freqs])
        f_query = df[f_col].values * 1e3
        for i, fq in enumerate(f_query):
            total[i] += powers[int(np.argmin(np.abs(freqs - fq)))]
    return total


# ---------------------------------------------------------------------------
# Model 2 — Zhang et al. 2010 / PowerTutor
# ---------------------------------------------------------------------------

def _zhang_features(df: pd.DataFrame, f_thresh: float):
    f_big_hz = df["f_big"].values * 1e3
    freq_h   = (f_big_hz >= f_thresh).astype(float)
    freq_l   = 1.0 - freq_h
    usage_cols = [c for c in df.columns if c.startswith("usage_cpu")]
    util = df[usage_cols].mean(axis=1).values if usage_cols else np.full(len(df), 100.0)
    cpu_on = np.ones(len(df))
    return np.column_stack([freq_h * util, freq_l * util, cpu_on]), util


def fit_zhang(df: pd.DataFrame) -> tuple:
    f_big_hz = df["f_big"].values * 1e3
    f_thresh = (f_big_hz.min() + f_big_hz.max()) / 2.0
    X, _     = _zhang_features(df, f_thresh)
    p        = df["measured_W"].values
    coeffs, _, _, _ = np.linalg.lstsq(X, p, rcond=None)
    beta_uh, beta_ul, beta_cpu = float(coeffs[0]), float(coeffs[1]), float(coeffs[2])
    print(f"    band threshold: {f_thresh/1e9:.3f} GHz")
    print(f"    beta_uh={beta_uh:.6f}  beta_ul={beta_ul:.6f}  beta_CPU={beta_cpu:.4f}")
    return beta_uh, beta_ul, beta_cpu, f_thresh


def predict_zhang(df: pd.DataFrame, beta_uh, beta_ul, beta_cpu, f_thresh) -> np.ndarray:
    X, _ = _zhang_features(df, f_thresh)
    return X @ np.array([beta_uh, beta_ul, beta_cpu])


# ---------------------------------------------------------------------------
# Model 3 — Baek and Liu 2015
# ---------------------------------------------------------------------------

def fit_baek(root: Path) -> dict:
    phase1_dir = root / "phase1"
    alphas = {}
    cluster_map = {
        "little": {"f_col": "f_little_kHz", "v_col": "v_little_V", "p_col": "little_W"},
        "big":    {"f_col": "f_big_kHz",    "v_col": "v_big_V",    "p_col": "big_W"},
        "prime":  {"f_col": "f_prime_kHz",  "v_col": "v_prime_V",  "p_col": "prime_W"},
    }
    for csv_file in sorted(phase1_dir.glob("*.csv")):
        df = pd.read_csv(csv_file, sep=None, engine="python")
        if "active_clusters" not in df.columns or len(df) == 0:
            continue
        cluster = df["active_clusters"].iloc[0]
        if cluster not in cluster_map:
            continue
        cols = cluster_map[cluster]
        for c in cols.values():
            if c in df.columns:
                df[c] = pd.to_numeric(df[c], errors="coerce")
        stress = df[df["workload"] == "stress"].dropna(
            subset=[cols["f_col"], cols["v_col"], cols["p_col"]])
        if len(stress) == 0:
            continue
        idx_fmax = stress[cols["f_col"]].idxmax()
        row  = stress.loc[idx_fmax]
        f_hz = float(row[cols["f_col"]]) * 1e3
        v    = float(row[cols["v_col"]])
        p    = float(row[cols["p_col"]])
        if v > 0 and f_hz > 0:
            alpha = p / (v**2 * f_hz)
            if cluster not in alphas or f_hz > alphas[cluster]["f_hz"]:
                alphas[cluster] = {"alpha": alpha, "f_hz": f_hz, "V": v, "P": p}
    for c, v in alphas.items():
        print(f"    {c}: alpha={v['alpha']:.4e}  (f={v['f_hz']/1e6:.1f} MHz, V={v['V']:.3f}V)")
    return {c: v["alpha"] for c, v in alphas.items()}


def predict_baek(df: pd.DataFrame, alphas: dict) -> np.ndarray:
    f_l = df["f_little"].values * 1e3
    f_b = df["f_big"].values    * 1e3
    f_p = df["f_prime"].values  * 1e3
    p_l = alphas.get("little", 0) * (df["V_little"].values**2) * f_l
    p_b = alphas.get("big",    0) * (df["V_big"].values**2)    * f_b
    p_p = alphas.get("prime",  0) * (df["V_prime"].values**2)  * f_p
    return p_l + p_b + p_p


# ---------------------------------------------------------------------------
# Model 4 — Hybrid (ours): full four-term model
# ---------------------------------------------------------------------------

def predict_hybrid(df: pd.DataFrame, params: dict,
                   P_infra: float = 0.0,
                   P_static: dict = None) -> np.ndarray:
    """
    Full four-term hybrid model — identical to evaluate_full_model.py:
        P = P_dyn + P_floor + P_infra + P_leak

    P_dyn:   alpha_c * V_c^2 * f_c * rho_c  per cluster
    P_floor: kappa_floor_c when rho_c < 0.05 and others active
    P_infra: constant when any cluster rho > 0.10
    P_leak:  P0 * exp(T_max / T0)
    """
    if P_static is None:
        P_static = {}
    alphas = params["alphas"]
    a_l = alphas["little"]["alpha"]
    a_b = alphas["big"]["alpha"]
    a_p = alphas["prime"]["alpha"]
    P0  = params["leakage"]["P0"]
    T0  = params["leakage"]["T0"]

    f_l = df["f_little"].values * 1e3
    f_b = df["f_big"].values    * 1e3
    f_p = df["f_prime"].values  * 1e3

    rho_l = df["rho_little"].values if "rho_little" in df.columns else np.ones(len(df))
    rho_b = df["rho_big"].values    if "rho_big"    in df.columns else np.ones(len(df))
    rho_p = df["rho_prime"].values  if "rho_prime"  in df.columns else np.ones(len(df))

    # Term 1: dynamic
    p_dyn = (a_l * (df["V_little"].values**2) * f_l * rho_l +
             a_b * (df["V_big"].values**2)    * f_b * rho_b +
             a_p * (df["V_prime"].values**2)  * f_p * rho_p)

    # Term 2: leakage
    T_max  = df[["T_little", "T_big", "T_prime"]].max(axis=1).values
    p_leak = P0 * np.exp(T_max / T0)

    # Term 3: infrastructure — active when any cluster rho > RHO_ACTIVE
    delta_act = ((rho_l > RHO_ACTIVE) | (rho_b > RHO_ACTIVE) | (rho_p > RHO_ACTIVE))
    p_infra   = np.where(delta_act, P_infra, 0.0)

    # Term 4: per-cluster static floor — bystander when rho_c < RHO_BYSTANDER
    p_floor = np.zeros(len(df))
    for cluster, rho_c in [("little", rho_l), ("big", rho_b), ("prime", rho_p)]:
        if cluster in P_static and P_static[cluster] > 0:
            delta_bys = ((rho_c < RHO_BYSTANDER) & delta_act)
            p_floor  += np.where(delta_bys, P_static[cluster], 0.0)

    return p_dyn + p_leak + p_infra + p_floor


# ---------------------------------------------------------------------------
# Prediction dispatcher
# ---------------------------------------------------------------------------

def get_preds(df: pd.DataFrame, carroll, beta_uh, beta_ul, beta_cpu,
              f_band, params, P_infra, P_static) -> dict:
    return {
        "Carroll-Heiser":   predict_carroll(df, carroll),
        "Zhang/PowerTutor": predict_zhang(df, beta_uh, beta_ul, beta_cpu, f_band),
        "Hybrid (ours)":    predict_hybrid(df, params, P_infra, P_static),
    }


# ---------------------------------------------------------------------------
# Printing / plotting
# ---------------------------------------------------------------------------

COLORS = {
    "Carroll-Heiser":   "#1f77b4",
    "Zhang/PowerTutor": "#ff7f0e",
    "Baek-Liu":         "#9467bd",
    "Hybrid (ours)":    "#2ca02c",
}


def print_table(results: list):
    hdr = f"  {'Model':<25} {'RMSE':>8} {'Rel%':>8} {'Bias':>9} {'R²':>8}"
    print(hdr)
    print(f"  {'─' * len(hdr.strip())}")
    for r in results:
        marker = " ◀" if r["model"] == "Hybrid (ours)" else ""
        print(f"  {r['model']:<25} "
              f"{r['rmse_W']:>7.3f}W "
              f"{r['rel_pct']:>7.1f}% "
              f"{r['bias_W']:>+8.3f}W "
              f"{r['r2']:>8.3f}{marker}")


def plot_bar_comparison(results_by_dataset: dict, plots_dir: Path):
    held = [k for k in results_by_dataset if "Test" in k or "Stress" in k]
    if not held:
        return
    fig, axes = plt.subplots(1, len(held), figsize=(5 * len(held), 6), sharey=False)
    if len(held) == 1:
        axes = [axes]
    for ax, dataset in zip(axes, held):
        rows   = results_by_dataset[dataset]
        names  = [r["model"]   for r in rows]
        rmses  = [r["rmse_W"]  for r in rows]
        rels   = [r["rel_pct"] for r in rows]
        colors = [COLORS.get(n, "#aaaaaa") for n in names]
        x    = np.arange(len(names))
        bars = ax.bar(x, rmses, color=colors, edgecolor="black", linewidth=0.5)
        for bar, rmse, rel in zip(bars, rmses, rels):
            ax.text(bar.get_x() + bar.get_width() / 2,
                    bar.get_height() + 0.02,
                    f"{rmse:.3f}W\n({rel:.1f}%)",
                    ha="center", va="bottom", fontsize=9)
        ax.set_title(dataset.replace("_", " ").title())
        ax.set_xticks(x)
        ax.set_xticklabels(names, rotation=20, ha="right", fontsize=9)
        ax.set_ylabel("RMSE (W)")
        ax.set_ylim(0, max(rmses) * 1.4)
    fig.suptitle("Model comparison: RMSE on held-out data", fontsize=13)
    fig.tight_layout()
    out = plots_dir / "baseline_comparison_rmse.png"
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"\n  Plot: {out.name}")


def plot_cross_lambda(cross_lambda_results: list, plots_dir: Path):
    if not cross_lambda_results:
        return
    df = pd.DataFrame(cross_lambda_results).sort_values("lambda_val")
    models = df["model"].unique()
    fig, ax = plt.subplots(figsize=(9, 5))
    for model in models:
        sub = df[df["model"] == model].sort_values("lambda_val")
        ax.plot(sub["lambda_val"], sub["rmse_W"],
                "o-", label=model, color=COLORS.get(model, "#aaaaaa"), linewidth=2)
    ax.set_xlabel("λ (CPU utilization)")
    ax.set_ylabel("RMSE (W)")
    ax.set_title("Cross-λ validation: RMSE per operating point")
    ax.legend()
    fig.tight_layout()
    out = plots_dir / "baseline_cross_lambda_rmse.png"
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"  Plot: {out.name}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 score_baselines.py <data_root>", file=sys.stderr)
        sys.exit(1)
    root      = Path(sys.argv[1])
    plots_dir = root / "plots"
    plots_dir.mkdir(exist_ok=True)

    print("Loading hybrid model params...")
    params, P_infra, P_static = load_hybrid_params(root)
    alphas = params["alphas"]
    P0     = params["leakage"]["P0"]
    T0     = params["leakage"]["T0"]
    print(f"  alpha: L={alphas['little']['alpha']:.4e}  "
          f"B={alphas['big']['alpha']:.4e}  "
          f"P={alphas['prime']['alpha']:.4e}")
    print(f"  leak:  P0={P0:.6f} W   T0={T0:.2f} °C")

    print("\nLoading Phase 2...")
    p2 = load_phase2(root)
    print(f"  {len(p2)} rows after T filter")

    print("\nLoading thermal sweeps...")
    pre_all, post_all = load_all_thermal_sweeps(root)
    print(f"\n  Total pre-throttle rows:  {len(pre_all)}")
    print(f"  Total post-throttle rows: {len(post_all)}")

    pre_train, pre_test = stratified_split(pre_all)
    train = pd.concat([p2, pre_train], ignore_index=True)
    test  = pre_test.copy()

    print(f"\nSplit (seed={SPLIT_SEED}, train_frac={TRAIN_FRAC}):")
    print(f"  Train:       {len(train):>5} rows")
    print(f"  Test:        {len(test):>5} rows  (20% pre-throttle, stratified by λ)")
    print(f"  Stress test: {len(post_all):>5} rows  (all post-throttle, OOD)")

    print("\nFitting baselines on training data...")
    print("  Carroll-Heiser (frequency lookup from Phase 1):")
    carroll = build_carroll_lookup(root)
    print("  Zhang/PowerTutor:")
    beta_uh, beta_ul, beta_cpu, f_band = fit_zhang(train)


    datasets = {
        "Stress test (all post-throttle, OOD)": post_all,
    }

    all_results = {}
    for name, df in datasets.items():
        if len(df) == 0:
            continue
        print(f"\n{'═'*65}")
        print(f"  {name}  (n={len(df)})")
        print(f"{'═'*65}")
        measured = df["measured_W"].values
        preds = get_preds(df, carroll, beta_uh, beta_ul, beta_cpu,
                          f_band, params, P_infra, P_static)
        results = [metrics(measured, pred, label=label)
                   for label, pred in preds.items()]
        all_results[name] = results
        print_table(results)

    print(f"\n{'═'*65}")
    print("  Cross-λ validation")
    print(f"{'═'*65}")
    sweeps = load_full_sweeps_per_lambda(root)

    cross_lambda_rows = []
    cross_lambda_plot = []

    models_ordered = ["Carroll-Heiser", "Zhang/PowerTutor", "Hybrid (ours)"]
    col_w = 22
    header = f"  {'λ':>5}  {'n':>4}  {'train?':>7}  " + \
             "  ".join(f"{'RMSE '+m[:8]:>{col_w}}" for m in models_ordered)
    print(f"\n{header}")
    print(f"  {'─'*len(header.strip())}")

    for lam in sorted(sweeps.keys()):
        df   = sweeps[lam]
        meas = df["measured_W"].values
        is_train = abs(lam - 1.0) < 0.01
        preds = get_preds(df, carroll, beta_uh, beta_ul, beta_cpu,
                          f_band, params, P_infra, P_static)
        row_str = f"  {lam:>5.2f}  {len(df):>4}  {'(train)' if is_train else '':>7}  "
        for model_name, pred in preds.items():
            m = metrics(meas, pred, label=model_name)
            rmse_str = f"{m['rmse_W']:.3f}W ({m['rel_pct']:.1f}%)"
            row_str += f"{rmse_str:>{col_w}}  "
            cross_lambda_rows.append({
                "lambda_val": lam, "model": model_name,
                "was_training": is_train, **m
            })
            cross_lambda_plot.append({
                "lambda_val": lam, "model": model_name,
                "rmse_W": m["rmse_W"], "rel_pct": m["rel_pct"],
            })
        print(row_str)

    val_rows = [r for r in cross_lambda_rows if not r["was_training"]]
    if val_rows:
        print(f"\n  Cross-λ summary (excluding λ=1.0 training):")
        for model_name in models_ordered:
            sub = [r for r in val_rows if r["model"] == model_name]
            mean_rmse = np.mean([r["rmse_W"]  for r in sub])
            mean_rel  = np.mean([r["rel_pct"] for r in sub])
            worst     = max(sub, key=lambda r: r["rmse_W"])
            marker = " ◀" if model_name == "Hybrid (ours)" else ""
            print(f"    {model_name:<25}  mean RMSE={mean_rmse:.3f}W  "
                  f"mean rel={mean_rel:.1f}%  "
                  f"worst={worst['rmse_W']:.3f}W (λ={worst['lambda_val']:.2f}){marker}")

    plot_bar_comparison(all_results, plots_dir)
    plot_cross_lambda(cross_lambda_plot, plots_dir)

    rows = []
    for dname, results in all_results.items():
        for r in results:
            rows.append({"dataset": dname, **r})
    pd.DataFrame(rows).to_csv(root / "baseline_comparison.csv", index=False)
    pd.DataFrame(cross_lambda_rows).to_csv(root / "baseline_cross_lambda.csv", index=False)
    print(f"\nSaved: baseline_comparison.csv  baseline_cross_lambda.csv")

    print(f"\n{'═'*65}")
    print("  HELD-OUT SUMMARY")
    print(f"{'═'*65}")
    for dname, results in all_results.items():
        if "Stress" in dname:
            print(f"\n  {dname}  (n={results[0]['n']}):")
            print_table(results)


if __name__ == "__main__":
    main()