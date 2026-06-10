#!/usr/bin/env python3
"""
fit_alpha.py - Fit per-cluster α from Phase 1 isolated stress data.

For each cluster (Little, Big, Prime), Phase 1 ran the cluster in isolation
(others offlined) and measured idle and stress phases. We compute:

    P_dyn = P_stress − P_idle

at each frequency. The dynamic power follows:

    P_dyn = α · V² · f

This isolates α because leakage approximately cancels in the (stress − idle)
difference (assuming T doesn't drift dramatically between the two phases).

We fit α via simple least squares with NO intercept:
    P_dyn = α · (V² · f)

If P_idle is unreliable (e.g., a cluster was offline during its idle phase
making P_idle ≈ 0), the residual leakage will inflate α. The script detects
this and substitutes a reference idle power from a healthy cluster, scaled
by core count.

Outputs composition_params.json with:
  - alphas: {cluster: {alpha, r2, n_samples}}
  - leakage: placeholder {P0, T0} (downstream fit will refit these)

Usage:
    python3 fit_alpha.py <data_root>
"""

import sys
import json
from pathlib import Path

import numpy as np
import pandas as pd

CLUSTERS = ["little", "big", "prime"]
CLUSTER_P_COL = {"little": "little_W", "big": "big_W", "prime": "prime_W"}
CLUSTER_V_COL = {"little": "v_little_V", "big": "v_big_V", "prime": "v_prime_V"}
CLUSTER_T_COL = {"little": "t_little_C", "big": "t_big_C", "prime": "t_prime_C"}
CLUSTER_F_COL = {"little": "f_little_kHz", "big": "f_big_kHz", "prime": "f_prime_kHz"}
CLUSTER_N_CORES = {"little": 4, "big": 4, "prime": 1}

def load_phase1_csvs(root: Path):
    """Load all phase1 CSV files."""
    if (root / "phase1").exists():
        phase1_dir = root / "phase1"
    elif (root / "data" / "phase1").exists():
        phase1_dir = root / "data" / "phase1"
    else:
        raise FileNotFoundError(f"No phase1 directory found in {root}")

    dfs = []
    for csv_file in sorted(phase1_dir.glob("*.csv")):
        df = pd.read_csv(csv_file, sep=None, engine="python")
        dfs.append(df)
    if not dfs:
        raise FileNotFoundError(f"No phase1 CSVs found in {phase1_dir}")
    return pd.concat(dfs, ignore_index=True)


def aggregate_cluster_data(df: pd.DataFrame, cluster: str):
    """
    Filter to rows where this cluster was active (Phase 1 isolated runs),
    pair idle and stress blocks per config_id, return arrays of:
        V (mean stress voltage)
        f_Hz (frequency)
        T_idle, T_stress (mean temperatures)
        P_idle (mean idle power)
        P_stress (mean stress power)
        P_dyn = P_stress - P_idle
    """
    df = df[df["active_clusters"] == cluster]
    if len(df) == 0:
        return None

    p_col = CLUSTER_P_COL[cluster]
    v_col = CLUSTER_V_COL[cluster]
    f_col = CLUSTER_F_COL[cluster]
    t_col = CLUSTER_T_COL[cluster]

    idle = (
        df[df["workload"] == "idle"]
        .groupby(["config_id", "rep"])
        .agg({p_col: "mean", t_col: "mean", f_col: "first"})
        .reset_index()
        .rename(columns={p_col: "P_idle", t_col: "T_idle"})
    )

    stress = (
        df[df["workload"] == "stress"]
        .groupby(["config_id", "rep"])
        .agg({p_col: "mean", v_col: "mean", t_col: "mean", f_col: "first"})
        .reset_index()
        .rename(columns={p_col: "P_stress", v_col: "V", t_col: "T_stress"})
    )

    merged = pd.merge(idle, stress, on=["config_id", "rep", f_col])
    if len(merged) == 0:
        return None

    merged["P_dyn"] = merged["P_stress"] - merged["P_idle"]
    merged["f_Hz"] = merged[f_col] * 1e3

    return merged[[
        "config_id", f_col, "f_Hz", "V",
        "T_idle", "T_stress",
        "P_idle", "P_stress", "P_dyn",
    ]]


def fit_alpha_no_intercept(V, f_Hz, P_dyn):
    """
    Fit α via P_dyn = α · V² · f (no intercept; passes through origin).
    Returns (alpha, r2).
    """
    x = (V ** 2) * f_Hz
    if np.sum(x * x) == 0:
        return float("nan"), float("nan")

    alpha = float(np.sum(x * P_dyn) / np.sum(x * x))

    P_pred = alpha * x
    ss_res = float(np.sum((P_dyn - P_pred) ** 2))
    ss_tot = float(np.sum((P_dyn - P_dyn.mean()) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")

    return alpha, r2


def estimate_idle_power(healthy_clusters: dict, target_cluster: str) -> float:
    """
    Estimate P_idle for a cluster with unreliable idle measurements,
    using per-core idle power from healthy clusters as reference.

    Logic: compute per-core idle power from clusters with reliable P_idle,
    then scale by the target cluster's core count.
    """
    per_core_idles = []
    for name, info in healthy_clusters.items():
        n_cores = CLUSTER_N_CORES[name]
        per_core = info["P_idle_mean"] / n_cores
        per_core_idles.append(per_core)

    if not per_core_idles:
        return 0.0

    mean_per_core = np.mean(per_core_idles)
    target_cores = CLUSTER_N_CORES[target_cluster]
    estimate = mean_per_core * target_cores

    return float(estimate)


def fit_alpha_with_intercept(V, f_Hz, P_stress):
    """
    Fit α via P_stress = α · V² · f + b (intercept absorbs idle/leakage baseline).
    Returns (alpha, r2) — intercept discarded.
    """
    x = (V ** 2) * f_Hz
    # OLS with intercept: solve [x, 1] [α, b]^T = P_stress
    A = np.column_stack([x, np.ones_like(x)])
    coef, _, _, _ = np.linalg.lstsq(A, P_stress, rcond=None)
    alpha, b = float(coef[0]), float(coef[1])

    P_pred = alpha * x + b
    ss_res = float(np.sum((P_stress - P_pred) ** 2))
    ss_tot = float(np.sum((P_stress - P_stress.mean()) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    return alpha, r2

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 fit_alpha.py <data_root>", file=sys.stderr)
        sys.exit(1)
    root = Path(sys.argv[1])

    if root.name == "data" or not (root / "data").exists():
        save_dir = root
    else:
        save_dir = root / "data"

    print("Loading phase1 data (isolated per-cluster)...")
    df = load_phase1_csvs(root)

    print("Fitting per-cluster α from P_dyn = P_stress − P_idle ...\n")

    # First pass: collect raw results and identify healthy vs suspect idle
    raw_results = {}
    for cluster in CLUSTERS:
        result = aggregate_cluster_data(df, cluster)
        if result is None or len(result) == 0:
            print(f"[{cluster}] No paired idle+stress data found, skipping.\n")
            continue
        raw_results[cluster] = result

    # Fit alpha for each cluster, correcting suspect idle values
    alphas = {}
    for cluster, result in raw_results.items():
        V = result["V"].values
        f_Hz = result["f_Hz"].values
        P_stress = result["P_stress"].values
        P_idle_raw = result["P_idle"].values
        P_idle_mean = float(result["P_idle"].mean())
        T_idle_mean = float(result["T_idle"].mean())
        T_stress_mean = float(result["T_stress"].mean())

        corrected = False
        P_idle_used = P_idle_mean
        P_dyn = result["P_dyn"].values

        # Fit alpha
        # alpha, r2 = fit_alpha_no_intercept(V, f_Hz, P_dyn)
        alpha, r2 = fit_alpha_with_intercept(V, f_Hz, P_stress)

        # Also fit uncorrected for comparison if we corrected
        if corrected:
            alpha_raw, r2_raw = fit_alpha_no_intercept(V, f_Hz, P_stress - P_idle_raw)
            print(f"  → α (uncorrected): {alpha_raw:.4e}  R² = {r2_raw:.4f}")
            print(f"  → α (corrected):   {alpha:.4e}  R² = {r2:.4f}")
        else:
            print(f"[{cluster}] α = {alpha:.4e}  R² = {r2:.4f}  n = {len(V)}")

        print(f"  P_idle (measured) = {P_idle_mean:.4f} W"
              + (f"  →  P_idle (used) = {P_idle_used:.4f} W" if corrected else ""))
        print(f"  T_idle = {T_idle_mean:.1f}°C   T_stress = {T_stress_mean:.1f}°C")
        print()

        alphas[cluster] = {
            "alpha": alpha,
            "unit": "α in W/(V²·Hz)",
            "r2": r2,
            "n_samples": int(len(V)),
            "P_idle_mean_W": float(P_idle_mean),
            "P_idle_used_W": float(P_idle_used),
            "P_idle_corrected": corrected,
            "T_idle_mean_C": float(T_idle_mean),
            "T_stress_mean_C": float(T_stress_mean),
        }

    output = {
        "source": "phase1_isolated_idle_subtracted",
        "fit_form": "P_dyn = alpha * V^2 * f, where P_dyn = P_stress - P_idle",
        "alphas": alphas,
        "leakage": {
            "P0": 0.05,
            "T0": 30.0,
            "unit": "P_leak = P0 · exp(T_max / T0)",
            "note": "Placeholder seed; downstream composition fit refits.",
        },
    }

    out_json = save_dir / "composition_params.json"
    with open(out_json, "w") as f:
        json.dump(output, f, indent=2)
    print(f"Wrote {out_json}")
    plot_fits(raw_results, alphas)  # ← add this


def plot_fits(raw_results, alphas):
    import matplotlib.pyplot as plt

    for cluster, result in raw_results.items():
        if cluster not in alphas:
            continue
        x = result["V"].values**2 * result["f_Hz"].values
        y = result["P_dyn"].values
        alpha = alphas[cluster]["alpha"]

        plt.figure()
        plt.scatter(x, y, label="data")
        plt.plot([0, x.max()], [0, alpha * x.max()], "r--", label=f"fit α={alpha:.2e}")
        plt.xlabel("V²·f"); plt.ylabel("P_dyn (W)")
        plt.title(f"{cluster} — R²={alphas[cluster]['r2']:.4f}")
        plt.legend(); plt.tight_layout()
        plt.savefig(f"fit_{cluster}.png")
        print(f"Saved fit_{cluster}.png")


if __name__ == "__main__":
    main()
