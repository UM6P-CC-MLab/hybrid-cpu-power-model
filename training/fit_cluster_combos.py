#!/usr/bin/env python3
"""
fit_cluster_combos.py — Fit per-cluster infrastructure power from combination sweeps.

Loads CSVs produced by phase2c_cluster_combos.sh and fits the infrastructure
power term that appears when specific cluster combinations are simultaneously
active. This power is not captured by the per-cluster dynamic term (C_eff·V²·f·ρ)
or the global leakage term.

Model extension:
    P_total = sum_c [ C_eff_c · V²_c · f_c · ρ_c ]   # dynamic (Phase 1)
            + P_infra(combo)                            # combo-specific constant
            + P0 · exp(T_max / T0)                     # global leakage (Phase 2b)

Where P_infra(combo) is fitted per combination from the residual:
    P_infra = mean(cpu_total_W - P_dyn - P_leak) over the stress phase

Frequency source: per-core mean from freq_cpu* columns (actual delivered
frequency). On Tensor G4 the policy-level f_*_kHz stays pinned at the
commanded setpoint while the hardware throttles per-core; the per-core
readings reflect the true delivered frequency on both G3 and G4.

Topology is auto-detected from the columns present in the CSVs:
    - G3: 9 cores (cpu0-8), Prime = cpu8, big = cpu4-7
    - G4: 8 cores (cpu0-7), Prime = cpu7, big = cpu4-6

Key addition vs previous version:
    - Per-core frequency for honest f on G4
    - Temperature-stratified P_infra reporting per combo
    - Little rail above-floor analysis stratified by temperature
    - P_infra at inference operating temperature (~61°C) explicitly reported

Usage:
    python3 fit_cluster_combos.py <data_root> [--params composition_simple_params.json]

Output:
    <data_root>/combo_infra_params.json — P_infra per combination
    <data_root>/plots/C1_infra_by_combo.png
    <data_root>/plots/C2_residuals_vs_T_by_combo.png
    <data_root>/plots/C3_per_rail_by_combo.png
    <data_root>/plots/C4_little_floor_vs_T.png
"""

import sys
import json
import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.optimize import curve_fit

plt.rcParams.update({
    "axes.grid": True, "grid.alpha": 0.3,
    "axes.spines.top": False, "axes.spines.right": False,
})

# Which cluster is the bystander in each two-cluster combo
COMBO_BYSTANDER = {
    "big_prime":    "little",
    "little_prime": "big",
    "little_big":   "prime",
}

BYSTANDER_RAIL = {
    "little": "little_W",
    "big":    "big_W",
    "prime":  "prime_W",
}

COMBO_N_ACTIVE = {
    "little_only":  1,
    "big_only":     1,
    "prime_only":   1,
    "little_big":   2,
    "little_prime": 2,
    "big_prime":    2,
    "all":          3,
}

T_BINS   = [0, 40, 50, 60, 70, 80, 90, 120]
T_LABELS = ["<40", "40-50", "50-60", "60-70", "70-80", "80-90", ">90"]

# Inference operating temperature — used to report P_infra at a specific T
T_INFERENCE = 61.0


# ---------------------------------------------------------------------------
# Topology detection and per-core frequency averaging
# ---------------------------------------------------------------------------

def detect_topology(df: pd.DataFrame) -> dict:
    """
    Detect Tensor G3 vs G4 from columns present.
    G3 has freq_cpu8; G4 stops at cpu7.
    """
    if "freq_cpu8" in df.columns:
        return {
            "device": "G3",
            "little": [0, 1, 2, 3],
            "big":    [4, 5, 6, 7],
            "prime":  [8],
        }
    else:
        return {
            "device": "G4",
            "little": [0, 1, 2, 3],
            "big":    [4, 5, 6],
            "prime":  [7],
        }


def compute_cluster_freq(df: pd.DataFrame, topology: dict) -> pd.DataFrame:
    """
    Replace policy-level f_*_kHz with per-core mean from freq_cpu* columns.
    On G4 this is necessary because the policy setpoint hides hardware
    throttling; on G3 it tracks the policy value closely.
    """

    for cluster in ["little", "big", "prime"]:
        cores = topology[cluster]
        cols = [f"freq_cpu{c}" for c in cores if f"freq_cpu{c}" in df.columns]
        if not cols:
            continue
        # Coerce "offline" and other non-numeric values to NaN, then fill with 0
        freq_per_core = df[cols].apply(pd.to_numeric, errors="coerce").fillna(0.0)
        # Per-core mean, treating offline as 0 contribution
        df[f"f_{cluster}_kHz"] = freq_per_core.mean(axis=1)

    return df


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load_combo_csvs(combos_dir: Path) -> tuple:
    """
    Load combo CSVs, detect topology, and apply per-core freq override.
    Returns (concatenated DataFrame, topology dict).
    """
    frames = []
    topology = None
    for csv_path in sorted(combos_dir.glob("combo_*.csv")):
        with open(csv_path) as fh:
            sep = "\t" if "\t" in fh.readline() else ","
        df = pd.read_csv(csv_path, sep=sep, decimal=",")
        for c in df.columns:
            if c not in ["phase", "config_id", "workload", "active_clusters"]:
                df[c] = pd.to_numeric(df[c], errors="coerce")

        # Detect topology on first file, then apply per-core freq override
        if topology is None:
            topology = detect_topology(df)
            print(f"  Detected topology: Tensor {topology['device']}")
        df = compute_cluster_freq(df, topology)

        stem  = csv_path.stem
        parts = stem.split("_")
        combo = "_".join(parts[1:-1])
        df["combo"] = combo
        df["rep"]   = parts[-1]
        frames.append(df)
        print(f"  {csv_path.name}: combo={combo}  rows={len(df)}")

    if not frames:
        raise FileNotFoundError(f"No combo CSVs found in {combos_dir}")
    return pd.concat(frames, ignore_index=True), topology


def recompute_rho(df: pd.DataFrame, topology: dict) -> pd.DataFrame:
    for cluster in ["little", "big", "prime"]:
        cores = topology[cluster]
        cols = [f"usage_cpu{c}" for c in cores if f"usage_cpu{c}" in df.columns]
        if not cols:
            df[f"rho_{cluster}"] = 0.0
            continue
        usage = df[cols].apply(pd.to_numeric, errors="coerce").fillna(0.0)
        online_cols = usage.columns[(usage > 0).any(axis=0)].tolist()
        df[f"rho_{cluster}"] = (
            usage[online_cols].mean(axis=1) / 100.0 if online_cols else 0.0
        )
    return df


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

def predict_pdyn(df: pd.DataFrame, alphas: dict) -> np.ndarray:
    a_l = alphas["little"]["alpha"]
    a_b = alphas["big"]["alpha"]
    a_p = alphas["prime"]["alpha"]
    p_l = a_l * df["v_little_V"].values**2 * df["f_little_kHz"].values * 1e3 * df["rho_little"].values
    p_b = a_b * df["v_big_V"].values**2    * df["f_big_kHz"].values    * 1e3 * df["rho_big"].values
    p_p = a_p * df["v_prime_V"].values**2  * df["f_prime_kHz"].values  * 1e3 * df["rho_prime"].values
    return p_l + p_b + p_p


def predict_pleak(df: pd.DataFrame, P0: float, T0: float) -> np.ndarray:
    T_max = df[["t_little_C", "t_big_C", "t_prime_C"]].max(axis=1).values
    return P0 * np.exp(T_max / T0)


# ---------------------------------------------------------------------------
# Temperature-stratified analysis
# ---------------------------------------------------------------------------

def t_bin(T_max: np.ndarray) -> np.ndarray:
    bins = np.digitize(T_max, T_BINS) - 1
    bins = np.clip(bins, 0, len(T_LABELS) - 1)
    return bins


def stratified_residual(stress: pd.DataFrame, alphas: dict,
                         P0: float, T0: float) -> pd.DataFrame:
    """
    Compute residual per row and return dataframe with T_max, residual,
    little_W, and T bin label.
    """
    p_dyn  = predict_pdyn(stress, alphas)
    p_leak = predict_pleak(stress, P0, T0)
    T_max  = stress[["t_little_C","t_big_C","t_prime_C"]].max(axis=1).values
    residual = stress["cpu_total_W"].values - p_dyn - p_leak

    out = pd.DataFrame({
        "T_max":     T_max,
        "residual":  residual,
        "p_dyn":     p_dyn,
        "p_leak":    p_leak,
        "little_W":  stress["little_W"].values,
        "rho_little": stress["rho_little"].values,
        "T_bin_idx": t_bin(T_max),
    })
    out["T_bin"] = [T_LABELS[i] for i in out["T_bin_idx"]]
    return out


# ---------------------------------------------------------------------------
# Per-combo analysis
# ---------------------------------------------------------------------------

def analyse_combo(stress: pd.DataFrame, idle: pd.DataFrame,
                  combo: str, alphas: dict, P0: float, T0: float) -> dict:
    floor = {}
    for c in ["little_W", "big_W", "prime_W", "cpu_total_W"]:
        if c in idle.columns and len(idle) > 0:
            clean_idle = idle[idle["rho_little"] < 0.05] if "rho_little" in idle.columns \
                         else idle
            floor[c] = float(clean_idle[c].median()) if len(clean_idle) > 0 \
                       else float(idle[c].median())

    if len(stress) == 0:
        return {"combo": combo, "n": 0}

    sr = stratified_residual(stress, alphas, P0, T0)

    T_max    = sr["T_max"].values
    residual = sr["residual"].values

    # Temperature-stratified P_infra
    t_strat = {}
    for i, lbl in enumerate(T_LABELS):
        mask = sr["T_bin_idx"].values == i
        if mask.sum() >= 3:
            sub = sr[mask]
            t_strat[lbl] = {
                "n":           int(mask.sum()),
                "P_infra_W":   round(float(sub["residual"].median()), 4),
                "little_W":    round(float(sub["little_W"].median()), 4),
                "rho_little":  round(float(sub["rho_little"].median()), 4),
            }

    P_infra_at_inference = _interpolate_at_T(sr, T_INFERENCE)

    little_idle_mask = sr["rho_little"] < 0.05
    little_floor_strat = {}
    if little_idle_mask.sum() >= 3:
        sub = sr[little_idle_mask]
        for i, lbl in enumerate(T_LABELS):
            bin_mask = sub["T_bin_idx"].values == i
            if bin_mask.sum() >= 2:
                little_floor_strat[lbl] = {
                    "n": int(bin_mask.sum()),
                    "little_W": round(float(sub[bin_mask]["little_W"].median()), 4),
                    "residual": round(float(sub[bin_mask]["residual"].median()), 4),
                }

    P_static = {}
    bystander = COMBO_BYSTANDER.get(combo)
    if bystander is not None:
        rail_col = BYSTANDER_RAIL[bystander]
        rho_col  = f"rho_{bystander}"
        if rail_col in stress.columns and rho_col in stress.columns:
            bystander_mask = stress[rho_col].values < 0.05
            if bystander_mask.sum() >= 3:
                sub_stress = stress[bystander_mask]
                sub_sr     = stratified_residual(sub_stress, alphas, P0, T0)
                P_static[bystander] = {
                    "n_total":  int(bystander_mask.sum()),
                    "P_static_W": round(float(stress[bystander_mask][rail_col].median()), 4),
                }
                P_static[bystander]["P_static_at_inference_W"] = round(
                    float(_interpolate_rail_at_T(
                        sub_stress, sub_sr, rail_col, T_INFERENCE)), 4)
                bin_strat = {}
                for i, lbl in enumerate(T_LABELS):
                    bin_mask = sub_sr["T_bin_idx"].values == i
                    if bin_mask.sum() >= 2:
                        bin_strat[lbl] = {
                            "n": int(bin_mask.sum()),
                            "P_static_W": round(
                                float(sub_stress[bin_mask][rail_col].median()), 4),
                        }
                P_static[bystander]["T_stratified"] = bin_strat

    rail_above = {}
    for c in ["little_W", "big_W", "prime_W"]:
        if c in stress.columns:
            rail_above[c] = float((stress[c].values - floor.get(c, 0.0)).mean())

    r2_exp = float("nan")
    mask_finite = np.isfinite(T_max) & np.isfinite(residual)
    try:
        def exp_model(T, P0_c, T0_c):
            return P0_c * np.exp(T / T0_c)
        popt, _ = curve_fit(exp_model, T_max[mask_finite], residual[mask_finite],
                            p0=[0.01, 30.0],
                            bounds=([1e-8, 5.0], [10.0, 200.0]),
                            maxfev=5000)
        P_pred_exp = exp_model(T_max[mask_finite], *popt)
        ss_res = np.sum((residual[mask_finite] - P_pred_exp)**2)
        ss_tot = np.sum((residual[mask_finite] - residual[mask_finite].mean())**2)
        r2_exp = float(1 - ss_res/ss_tot) if ss_tot > 0 else float("nan")
    except RuntimeError:
        pass

    return {
        "combo":                  combo,
        "n_active":               COMBO_N_ACTIVE.get(combo, -1),
        "n":                      int(len(stress)),
        "idle_floor_W":           floor,
        "mean_meas_W":            float(np.mean(stress["cpu_total_W"].values)),
        "mean_dyn_W":             float(np.mean(sr["p_dyn"].values)),
        "mean_leak_W":            float(np.mean(sr["p_leak"].values)),
        "mean_residual_W":        float(np.mean(residual)),
        "median_residual_W":      float(np.median(residual)),
        "std_residual_W":         float(np.std(residual)),
        "T_range":                (float(np.nanmin(T_max)), float(np.nanmax(T_max))),
        "r2_exp_residual":        r2_exp,
        "rail_above_floor_W":     rail_above,
        "T_stratified":           t_strat,
        "little_floor_stratified": little_floor_strat,
        "P_infra_at_inference_W": P_infra_at_inference,
        "rho_mean": {
            "little": float(stress["rho_little"].mean()),
            "big":    float(stress["rho_big"].mean()),
            "prime":  float(stress["rho_prime"].mean()),
        },
        "P_static": P_static,
    }


def _interpolate_at_T(sr: pd.DataFrame, T_target: float) -> float:
    mask = (sr["T_max"] >= T_target - 5) & (sr["T_max"] <= T_target + 5)
    if mask.sum() >= 3:
        return round(float(sr[mask]["residual"].median()), 4)
    if len(sr) > 0:
        sr_sorted = sr.copy()
        sr_sorted["dist"] = (sr_sorted["T_max"] - T_target).abs()
        nearest = sr_sorted.nsmallest(max(5, int(len(sr)*0.1)), "dist")
        return round(float(nearest["residual"].median()), 4)
    return float("nan")


def _interpolate_rail_at_T(stress: pd.DataFrame, sr: pd.DataFrame,
                            rail_col: str, T_target: float) -> float:
    T_max = sr["T_max"].values
    mask  = (T_max >= T_target - 5) & (T_max <= T_target + 5)
    if mask.sum() >= 3:
        return float(stress[mask][rail_col].median())
    if len(stress) > 0:
        dist    = np.abs(T_max - T_target)
        nearest = np.argsort(dist)[:max(5, int(len(stress)*0.1))]
        return float(stress.iloc[nearest][rail_col].median())
    return float("nan")


# ---------------------------------------------------------------------------
# Plots
# ---------------------------------------------------------------------------

def plot_infra_by_combo(results: list, out: Path):
    combos   = [r["combo"] for r in results if r.get("n", 0) > 0]
    infra    = [r["median_residual_W"] for r in results if r.get("n", 0) > 0]
    n_active = [r["n_active"] for r in results if r.get("n", 0) > 0]

    colors = {1: "#1f77b4", 2: "#ff7f0e", 3: "#2ca02c"}
    bar_colors = [colors.get(n, "gray") for n in n_active]

    fig, ax = plt.subplots(figsize=(9, 5))
    bars = ax.bar(combos, infra, color=bar_colors, edgecolor="black", linewidth=0.5)
    ax.axhline(0, color="black", linewidth=0.8, alpha=0.5)
    ax.set_ylabel("Median infrastructure power (W)", fontsize=12)
    ax.set_title("Infrastructure power residual by cluster combination\n"
                 "(measured − dynamic − leakage)", fontsize=13)
    for bar, val in zip(bars, infra):
        ax.text(bar.get_x() + bar.get_width()/2, val + 0.005,
                f"{val:.3f}W", ha="center", fontsize=10)
    from matplotlib.patches import Patch
    legend_elements = [Patch(facecolor=colors[1], label="N_active=1"),
                       Patch(facecolor=colors[2], label="N_active=2"),
                       Patch(facecolor=colors[3], label="N_active=3")]
    ax.legend(handles=legend_elements, fontsize=10)
    fig.tight_layout()
    fig.savefig(out, dpi=150); plt.close(fig)
    print(f"  wrote {out.name}")


def plot_residuals_vs_T(data: pd.DataFrame, alphas: dict,
                        P0: float, T0: float, out: Path):
    stress = data[data["phase"] == "combo_sweep"].copy()
    if len(stress) == 0:
        return

    p_dyn    = predict_pdyn(stress, alphas)
    p_leak   = predict_pleak(stress, P0, T0)
    residual = stress["cpu_total_W"].values - p_dyn - p_leak
    T_max    = stress[["t_little_C","t_big_C","t_prime_C"]].max(axis=1).values

    combos = sorted(stress["combo"].unique())
    cmap   = plt.cm.get_cmap("tab10", len(combos))

    fig, ax = plt.subplots(figsize=(10, 6))
    for i, combo in enumerate(combos):
        mask = stress["combo"].values == combo
        ax.scatter(T_max[mask], residual[mask],
                   label=f"{combo} (n={mask.sum()})",
                   color=cmap(i), s=25, alpha=0.6,
                   edgecolor="black", linewidth=0.2)
    ax.axhline(0, color="black", linewidth=0.8, alpha=0.5)
    ax.axvline(T_INFERENCE, color="red", linewidth=1.0, linestyle="--",
               alpha=0.6, label=f"T_inference={T_INFERENCE:.0f}°C")
    ax.set_xlabel("T_max (°C)", fontsize=12)
    ax.set_ylabel("Residual = measured − dynamic − leakage (W)", fontsize=12)
    ax.set_title("Infrastructure power residual vs temperature by combo", fontsize=13)
    ax.legend(fontsize=9)
    fig.tight_layout()
    fig.savefig(out, dpi=150); plt.close(fig)
    print(f"  wrote {out.name}")


def plot_per_rail_by_combo(results: list, out: Path):
    combos = [r["combo"] for r in results if r.get("n", 0) > 0]
    rails  = ["little_W", "big_W", "prime_W"]
    colors = {"little_W": "#1f77b4", "big_W": "#ff7f0e", "prime_W": "#2ca02c"}

    x     = np.arange(len(combos))
    width = 0.25
    fig, ax = plt.subplots(figsize=(10, 5))
    for i, rail in enumerate(rails):
        vals = [r["rail_above_floor_W"].get(rail, 0.0)
                for r in results if r.get("n", 0) > 0]
        ax.bar(x + (i - 1) * width, vals, width,
               label=rail.replace("_W", ""), color=colors[rail],
               edgecolor="black", linewidth=0.4, alpha=0.85)

    ax.set_xticks(x)
    ax.set_xticklabels(combos, fontsize=11)
    ax.set_ylabel("Mean above-floor power (W)", fontsize=12)
    ax.set_title("Per-rail power above idle floor by cluster combination", fontsize=13)
    ax.legend(fontsize=10)
    ax.axhline(0, color="black", linewidth=0.8, alpha=0.5)
    fig.tight_layout()
    fig.savefig(out, dpi=150); plt.close(fig)
    print(f"  wrote {out.name}")


def plot_little_floor_vs_T(results: list, out: Path):
    bp = next((r for r in results if r.get("combo") == "big_prime"
               and r.get("n", 0) > 0), None)
    if bp is None:
        return

    strat = bp.get("little_floor_stratified", {})
    if not strat:
        print("  No Little floor stratified data for big_prime — skipping plot")
        return

    T_mids = []
    lw_vals = []
    res_vals = []
    bin_edges = T_BINS
    for i, lbl in enumerate(T_LABELS):
        if lbl in strat:
            T_mid = (bin_edges[i] + bin_edges[i+1]) / 2
            T_mids.append(T_mid)
            lw_vals.append(strat[lbl]["little_W"])
            res_vals.append(strat[lbl]["residual"])

    if len(T_mids) < 2:
        return

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))

    axes[0].plot(T_mids, lw_vals, "o-", color="#1f77b4", linewidth=2, markersize=8)
    axes[0].axvline(T_INFERENCE, color="red", linestyle="--", alpha=0.6,
                    label=f"T_inference={T_INFERENCE:.0f}°C")
    axes[0].set_xlabel("T_max bin midpoint (°C)", fontsize=12)
    axes[0].set_ylabel("Little rail power (W)", fontsize=12)
    axes[0].set_title("Little rail power vs temperature\n(big+prime combo, rho_little<0.05)",
                      fontsize=12)
    axes[0].legend(fontsize=10)

    axes[1].plot(T_mids, res_vals, "o-", color="#d62728", linewidth=2, markersize=8)
    axes[1].axhline(0, color="black", linewidth=0.8, alpha=0.5)
    axes[1].axvline(T_INFERENCE, color="red", linestyle="--", alpha=0.6,
                    label=f"T_inference={T_INFERENCE:.0f}°C")
    axes[1].set_xlabel("T_max bin midpoint (°C)", fontsize=12)
    axes[1].set_ylabel("Residual after leakage correction (W)", fontsize=12)
    axes[1].set_title("Little floor residual vs temperature\n(leakage-corrected)",
                      fontsize=12)
    axes[1].legend(fontsize=10)

    fig.tight_layout()
    fig.savefig(out, dpi=150); plt.close(fig)
    print(f"  wrote {out.name}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data_root")
    parser.add_argument("--params", type=str,
                        default="composition_simple_params.json")
    args = parser.parse_args()

    root       = Path(args.data_root)
    combos_dir = root / "phase2c_combos"
    plots_dir  = root / "plots"
    plots_dir.mkdir(exist_ok=True)

    params_path = root / args.params
    if not params_path.exists():
        print(f"ERROR: {params_path} not found", file=sys.stderr); sys.exit(1)
    with open(params_path) as f:
        params = json.load(f)

    alphas = params.get("alphas") or params.get("alphas_fit")
    P0     = params["leakage"]["P0"]
    T0     = params["leakage"]["T0"]

    print(f"Loaded params from {args.params}")
    print(f"  P0={P0:.6f}  T0={T0:.2f}°C")
    for cl in ["little","big","prime"]:
        print(f"  α_{cl} = {alphas[cl]['alpha']:.4e}")

    print(f"\nLoading combo CSVs from {combos_dir}...")
    if not combos_dir.exists():
        print(f"ERROR: {combos_dir} not found", file=sys.stderr); sys.exit(1)

    data, topology = load_combo_csvs(combos_dir)
    data = recompute_rho(data, topology)

    print(f"\nTotal rows: {len(data)}")
    print(f"Combos found: {sorted(data['combo'].unique())}")

    # Analyse each combo
    print("\n=== Per-combo infrastructure power analysis ===")
    results = []
    for combo in sorted(data["combo"].unique()):
        idle   = data[(data["combo"] == combo) &
                      (data["phase"] == "combo_idle")].copy()
        stress = data[(data["combo"] == combo) &
                      (data["phase"] == "combo_sweep")].copy()

        result = analyse_combo(stress, idle, combo, alphas, P0, T0)
        results.append(result)

        if result.get("n", 0) == 0:
            print(f"\n  {combo}: no stress data"); continue

        print(f"\n  {combo}  (N_active={result['n_active']}  n={result['n']})")
        print(f"    T range:      {result['T_range'][0]:.0f}–{result['T_range'][1]:.0f}°C")
        print(f"    rho:          L={result['rho_mean']['little']:.3f}  "
              f"B={result['rho_mean']['big']:.3f}  "
              f"P={result['rho_mean']['prime']:.3f}")
        print(f"    measured:     {result['mean_meas_W']:.4f} W")
        print(f"    dynamic:      {result['mean_dyn_W']:.4f} W")
        print(f"    leakage:      {result['mean_leak_W']:.4f} W")
        print(f"    residual:     mean={result['mean_residual_W']:.4f}  "
              f"median={result['median_residual_W']:.4f}  "
              f"std={result['std_residual_W']:.4f} W")
        print(f"    R²(exp~T):    {result['r2_exp_residual']:.4f}")
        print(f"    P_infra at T={T_INFERENCE:.0f}°C: "
              f"{result['P_infra_at_inference_W']:.4f} W")

        print(f"    Temperature-stratified P_infra:")
        for lbl, v in result["T_stratified"].items():
            print(f"      T={lbl:6s}°C: n={v['n']:3d}  "
                  f"P_infra={v['P_infra_W']:+.4f}W  "
                  f"little_W={v['little_W']:.4f}W  "
                  f"rho_l={v['rho_little']:.3f}")

        if result["little_floor_stratified"]:
            print(f"    Little floor (rho_little<0.05) by temperature:")
            for lbl, v in result["little_floor_stratified"].items():
                print(f"      T={lbl:6s}°C: n={v['n']:2d}  "
                      f"little_W={v['little_W']:.4f}W  "
                      f"residual={v['residual']:+.4f}W")

        print(f"    per-rail above idle floor:")
        for rail, val in result["rail_above_floor_W"].items():
            print(f"      {rail}: {val:.4f} W")

        if result.get("P_static"):
            print(f"    P_static (bystander cluster rail power):")
            for cl, v in result["P_static"].items():
                print(f"      {cl}: P_static={v['P_static_W']:.4f}W  "
                      f"at_inference={v['P_static_at_inference_W']:.4f}W  "
                      f"n={v['n_total']}")
                for lbl, bv in v.get("T_stratified", {}).items():
                    print(f"        T={lbl:6s}°C: n={bv['n']:3d}  "
                          f"P_static={bv['P_static_W']:.4f}W")

    print("\n=== Infrastructure power vs N_active ===")
    by_n = {}
    for r in results:
        if r.get("n", 0) == 0:
            continue
        n = r["n_active"]
        by_n.setdefault(n, []).append(r["median_residual_W"])
    for n in sorted(by_n.keys()):
        vals = by_n[n]
        print(f"  N_active={n}: median_infra={np.mean(vals):.4f}W  "
              f"values={[round(v,4) for v in vals]}")

    print(f"\n=== P_infra at T={T_INFERENCE:.0f}°C (inference operating temperature) ===")
    for r in results:
        if r.get("n", 0) == 0:
            continue
        print(f"  {r['combo']:20s}: {r['P_infra_at_inference_W']:.4f} W")

    print(f"\n=== P_static per cluster (bystander rail power at T={T_INFERENCE:.0f}°C) ===")
    all_static = {}
    for r in results:
        if r.get("n", 0) == 0 or not r.get("P_static"):
            continue
        for cl, v in r["P_static"].items():
            all_static[cl] = v["P_static_at_inference_W"]
            print(f"  P_static_{cl} = {v['P_static_at_inference_W']:.4f}W  "
                  f"(from {r['combo']} combo)")

    out_params = {
        "model_extension": "infrastructure_power_by_combo",
        "description": ("P_infra is the median residual after subtracting dynamic "
                        "and leakage terms. Temperature-stratified values also reported."),
        "base_params": args.params,
        "device": topology["device"],
        "frequency_source": "per-core mean from freq_cpu* (actual delivered freq)",
        "T_inference_C": T_INFERENCE,
        "combos": {r["combo"]: {
            "n_active":               r["n_active"],
            "n_samples":              r.get("n", 0),
            "P_infra_W":              round(r["median_residual_W"], 6),
            "P_infra_at_inference_W": r.get("P_infra_at_inference_W", float("nan")),
            "std_W":                  round(r["std_residual_W"], 6),
            "T_range_C":              r["T_range"],
            "r2_exp_residual":        r["r2_exp_residual"],
            "T_stratified":           r.get("T_stratified", {}),
            "little_floor_stratified": r.get("little_floor_stratified", {}),
            "P_static":               r.get("P_static", {}),
        } for r in results if r.get("n", 0) > 0},
        "P_static": {
            cl: {
                "P_static_W":              v["P_static_W"],
                "P_static_at_inference_W": v["P_static_at_inference_W"],
                "source_combo":            next(
                    r["combo"] for r in results
                    if r.get("P_static", {}).get(cl) is not None
                ),
            }
            for r in results if r.get("P_static")
            for cl, v in r["P_static"].items()
        },
    }
    out_json = root / "combo_infra_params.json"
    with open(out_json, "w") as f:
        json.dump(out_params, f, indent=2)
    print(f"\nWrote {out_json}")

    static_out = {
        "description": (
            "P_static_c is the median rail power of cluster c when it is a bystander "
            "(rho_c < 0.05) while other clusters are actively running. "
            "Fitted from phase2c_combos at inference operating temperature."
        ),
        "device": topology["device"],
        "T_inference_C": T_INFERENCE,
        "formula": "Applied when rho_c < 0.05 AND any other cluster rho > 0.1",
        "P_static": out_params.get("P_static", {}),
    }
    static_json = root / "static_floor_params.json"
    with open(static_json, "w") as f:
        json.dump(static_out, f, indent=2)
    print(f"Wrote {static_json}")

    plot_infra_by_combo(results, plots_dir / "C1_infra_by_combo.png")
    plot_residuals_vs_T(data, alphas, P0, T0,
                        plots_dir / "C2_residuals_vs_T_by_combo.png")
    plot_per_rail_by_combo(results, plots_dir / "C3_per_rail_by_combo.png")
    plot_little_floor_vs_T(results, plots_dir / "C4_little_floor_vs_T.png")


if __name__ == "__main__":
    main()