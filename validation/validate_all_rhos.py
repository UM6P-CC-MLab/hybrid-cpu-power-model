#!/usr/bin/env python3
"""
validate_all_rhos.py - Score the fitted model against all thermal sweeps.

Auto-detects all `thermal_rho_*.csv` files in <data_root>/phase2b_thermal/,
applies the model from composition_simple_params.json to each, and reports
RMSE / R² / bias per ρ. Excludes the rho=1.0 file used for training.

Outputs:
  <data_root>/cross_rho_validation.csv   — summary table
  <data_root>/plots/V_cross_rho_*.png    — per-ρ scatter plots
  <data_root>/plots/V_cross_rho_summary.png — RMSE-vs-ρ summary

Usage:
    python3 validate_all_rhos.py <data_root>

Example:
    python3 validate_all_rhos.py data/pixel8pro
    python3 validate_all_rhos.py data/pixel9
"""

import sys
import json
import re
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

plt.rcParams.update({
    "axes.grid": True,
    "grid.alpha": 0.3,
    "axes.spines.top": False,
    "axes.spines.right": False,
})


def load_csv(csv_path: Path):
    df = pd.read_csv(csv_path, sep=None, engine="python", decimal=",")
    num_cols = [
        "timestamp_ms", "cpu_total_W",
        "freq_cpu0", "freq_cpu4", "freq_cpu8", "freq_cpu7",
        "v_little_V", "v_big_V", "v_prime_V",
        "t_little_C", "t_big_C", "t_prime_C",
    ]
    for c in num_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def predict(df, params):
    a_l = params["alphas"]["little"]["alpha"]
    a_b = params["alphas"]["big"]["alpha"]
    a_p = params["alphas"]["prime"]["alpha"]
    P0  = params["leakage"]["P0"]
    T0  = params["leakage"]["T0"]

    # Prime freq column differs between Pixel 8 Pro (cpu8) and Pixel 9 (cpu7)
    f_l = df["freq_cpu0"].values * 1e3
    f_b = df["freq_cpu4"].values * 1e3
    if "freq_cpu8" in df.columns:
        f_p = df["freq_cpu8"].values * 1e3
    elif "freq_cpu7" in df.columns:
        f_p = df["freq_cpu7"].values * 1e3
    else:
        raise KeyError("No prime-cluster freq column found (freq_cpu7 or freq_cpu8).")

    # Dynamic term
    p_dyn_l = a_l * (df["v_little_V"].values ** 2) * f_l
    p_dyn_b = a_b * (df["v_big_V"].values    ** 2) * f_b
    p_dyn_p = a_p * (df["v_prime_V"].values  ** 2) * f_p
    p_dyn = p_dyn_l + p_dyn_b + p_dyn_p

    # Leakage term
    T_max = df[["t_little_C", "t_big_C", "t_prime_C"]].max(axis=1).values
    p_leak = P0 * np.exp(T_max / T0)

    # Idle term — present only in three-term model
    idle_models = params.get("idle_models")
    if idle_models is not None:
        # Three-term model: P_total = P_idle(f) + P_dyn + P_leak(T)
        if "total" in idle_models:
            # New: single total model driven by f_big
            m = idle_models["total"]
            a, b = m["a"], m["b"]
            p_idle = a * f_b + b   # f_b is already in Hz
        else:
            # Legacy: per-cluster model
            p_idle = np.zeros(len(df))
            freq_map = {"little": f_l, "big": f_b, "prime": f_p}
            for cluster, f_hz in freq_map.items():
                m = idle_models.get(cluster, {})
                p_idle += m.get("a", 0.0) * f_hz + m.get("b", 0.0)
        return p_idle + p_dyn + p_leak
    else:
        # Two-term model (backward compatible)
        return p_dyn + p_leak


def metrics(measured, predicted):
    residuals = measured - predicted
    rmse = float(np.sqrt(np.mean(residuals ** 2)))
    mae = float(np.mean(np.abs(residuals)))
    bias = float(np.mean(residuals))
    ss_res = float(np.sum(residuals ** 2))
    ss_tot = float(np.sum((measured - measured.mean()) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    rel_rmse_pct = 100 * rmse / measured.mean() if measured.mean() > 0 else float("nan")
    return {
        "n": int(len(measured)),
        "rmse_W": rmse,
        "mae_W": mae,
        "bias_W": bias,
        "r2": r2,
        "rel_rmse_pct": rel_rmse_pct,
        "mean_measured_W": float(measured.mean()),
        "mean_predicted_W": float(np.mean(predicted)),
    }


def parse_rho_from_filename(name: str):
    m = re.search(r"thermal_rho_(\d+\.\d+)", name)
    return float(m.group(1)) if m else None


def plot_scatter(rho, df, predicted, out: Path):
    fig, ax = plt.subplots(figsize=(7, 6))
    measured = df["cpu_total_W"].values
    T_max = df[["t_little_C", "t_big_C", "t_prime_C"]].max(axis=1).values
    sc = ax.scatter(predicted, measured, c=T_max, cmap="plasma",
                    s=40, alpha=0.7, edgecolor="black", linewidth=0.3)
    lo = min(predicted.min(), measured.min()) * 0.9
    hi = max(predicted.max(), measured.max()) * 1.05
    ax.plot([lo, hi], [lo, hi], "k--", alpha=0.5, label="y = x")
    cbar = fig.colorbar(sc, ax=ax)
    cbar.set_label("T_max (°C)")
    rmse = float(np.sqrt(np.mean((measured - predicted) ** 2)))
    ax.set_title(f"ρ = {rho}: predicted vs measured  (RMSE = {rmse:.3f} W)")
    ax.set_xlabel("Predicted (W)")
    ax.set_ylabel("Measured (W)")
    ax.set_xlim(lo, hi)
    ax.set_ylim(lo, hi)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_summary(results: pd.DataFrame, out: Path):
    fig, axes = plt.subplots(1, 3, figsize=(16, 5))

    ax = axes[0]
    ax.plot(results["rho"], results["rmse_W"], "o-", color="#1f77b4", linewidth=2)
    ax.set_xlabel("ρ")
    ax.set_ylabel("RMSE (W)")
    ax.set_title("RMSE vs ρ")
    ax.set_ylim(bottom=0)

    ax = axes[1]
    ax.plot(results["rho"], results["bias_W"], "o-", color="#d62728", linewidth=2)
    ax.axhline(0, color="black", linewidth=0.8, alpha=0.6)
    ax.set_xlabel("ρ")
    ax.set_ylabel("Bias = mean(measured − predicted) (W)")
    ax.set_title("Mean bias vs ρ")

    ax = axes[2]
    ax.plot(results["rho"], results["rel_rmse_pct"], "o-", color="#2ca02c", linewidth=2)
    ax.set_xlabel("ρ")
    ax.set_ylabel("Relative RMSE (%)")
    ax.set_title("Relative RMSE vs ρ")
    ax.set_ylim(bottom=0)

    fig.suptitle("Cross-ρ validation summary", fontsize=14, y=1.02)
    fig.tight_layout()
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 validate_all_rhos.py <data_root>", file=sys.stderr)
        sys.exit(1)
    root = Path(sys.argv[1])

    if root.name == "data" or not (root / "data").exists():
        save_dir = root
    else:
        save_dir = root / "data"

    plots = save_dir / "plots"
    plots.mkdir(parents=True, exist_ok=True)

    # Load model
    params_path = save_dir / "composition_simple_params.json"
    if not params_path.exists():
        print(f"ERROR: {params_path} not found. Run fit_composition.py first.", file=sys.stderr)
        sys.exit(1)
    with open(params_path) as f:
        params = json.load(f)
    print(f"Loaded model from {params_path.name}:")
    print(f"  α_little = {params['alphas']['little']['alpha']:.4e}")
    print(f"  α_big    = {params['alphas']['big']['alpha']:.4e}")
    print(f"  α_prime  = {params['alphas']['prime']['alpha']:.4e}")
    print(f"  P0       = {params['leakage']['P0']:.4f} W")
    print(f"  T0       = {params['leakage']['T0']:.2f} °C")

    # Find all thermal sweep CSVs
    thermal_dir = save_dir / "phase2b_thermal"
    if not thermal_dir.exists():
        print(f"ERROR: {thermal_dir} not found.", file=sys.stderr)
        sys.exit(1)

    all_csvs = sorted(thermal_dir.glob("thermal_rho_*.csv"))
    if not all_csvs:
        print(f"ERROR: no thermal_rho_*.csv files in {thermal_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"\nFound {len(all_csvs)} thermal sweep CSV(s):")
    for c in all_csvs:
        print(f"  {c.name}")

    # Score each
    results = []
    for csv_path in all_csvs:
        rho = parse_rho_from_filename(csv_path.name)
        if rho is None:
            print(f"  skipping {csv_path.name} (can't parse ρ)")
            continue

        df = load_csv(csv_path)
        if "workload" in df.columns:
            stress = df[df["workload"] == "stress"].copy().reset_index(drop=True)
        else:
            stress = df.copy().reset_index(drop=True)

        if len(stress) < 3:
            print(f"  skipping {csv_path.name} (only {len(stress)} samples)")
            continue

        try:
            pred = predict(stress, params)
        except Exception as e:
            print(f"  error scoring {csv_path.name}: {e}")
            continue

        m = metrics(stress["cpu_total_W"].values, pred)
        m["rho"] = rho
        m["filename"] = csv_path.name
        m["was_training"] = (rho == 1.0)
        results.append(m)

        # Per-ρ scatter
        plot_path = plots / f"V_cross_rho_{rho:.2f}.png"
        plot_scatter(rho, stress, pred, plot_path)
        print(f"  ρ={rho}: RMSE={m['rmse_W']:.3f} W  bias={m['bias_W']:+.3f} W  "
              f"R²={m['r2']:.3f}  ({m['rel_rmse_pct']:.1f}% rel.)  → {plot_path.name}")

    if not results:
        print("ERROR: no valid results.", file=sys.stderr)
        sys.exit(1)

    # Save summary table
    df_results = pd.DataFrame(results)
    df_results = df_results.sort_values("rho").reset_index(drop=True)

    cols = ["rho", "n", "mean_measured_W", "mean_predicted_W",
            "rmse_W", "mae_W", "bias_W", "rel_rmse_pct", "r2",
            "was_training", "filename"]
    df_results[cols].to_csv(save_dir / "cross_rho_validation.csv", index=False)
    print(f"\nWrote {save_dir / 'cross_rho_validation.csv'}")

    # Print summary table
    print(f"\n=== Cross-ρ validation summary ===")
    print(f"{'ρ':>6}  {'n':>4}  {'mean_meas':>10}  {'mean_pred':>10}  "
          f"{'RMSE':>8}  {'bias':>8}  {'R²':>7}  {'rel%':>7}  {'note':<10}")
    print("-" * 92)
    for _, row in df_results.iterrows():
        note = "(training)" if row["was_training"] else ""
        print(f"  {row['rho']:>4.2f}  {int(row['n']):>4}  "
              f"{row['mean_measured_W']:>10.3f}  {row['mean_predicted_W']:>10.3f}  "
              f"{row['rmse_W']:>8.3f}  {row['bias_W']:>+8.3f}  "
              f"{row['r2']:>7.3f}  {row['rel_rmse_pct']:>6.1f}%  {note}")

    # Aggregates excluding training
    val_only = df_results[~df_results["was_training"]]
    if len(val_only) > 0:
        print(f"\nAcross all cross-ρ validation (excluding training):")
        print(f"  Mean RMSE         = {val_only['rmse_W'].mean():.3f} W")
        print(f"  Worst-case RMSE   = {val_only['rmse_W'].max():.3f} W "
              f"(at ρ={val_only.loc[val_only['rmse_W'].idxmax(), 'rho']})")
        print(f"  Mean rel RMSE     = {val_only['rel_rmse_pct'].mean():.1f}%")
        print(f"  Mean abs bias     = {val_only['bias_W'].abs().mean():.3f} W")

    # Summary plot
    plot_summary(df_results, plots / "V_cross_rho_summary.png")
    print(f"\nWrote {plots / 'V_cross_rho_summary.png'}")


if __name__ == "__main__":
    main()