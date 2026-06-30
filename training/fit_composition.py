#!/usr/bin/env python3
"""
fit_composition.py - Two-term power model (dynamic + leakage only).

Model:
    P_total = P_dyn + P_leak(T)

where:
    P_dyn     = sum_c [alpha_c * V_c^2 * f_c]  -- analytical CMOS
    P_leak(T) = P0 * exp(T_max / T0)           -- temperature-varying leakage

Frequency source: per-core freq_cpu* averaged per cluster (actual delivered
frequency). On Tensor G3 the policy-level f_*_kHz tracks the achieved
frequency closely, but on Tensor G4 it remains pinned at the commanded
setpoint while the hardware silently throttles individual cores. Per-core
readings reflect the true delivered frequency on both devices.

Topology is auto-detected from the columns present in the CSVs:
    - G3: 9 cores (cpu0-8), Prime = cpu8, big = cpu4-7
    - G4: 8 cores (cpu0-7), Prime = cpu7, big = cpu4-6

Data split strategy:
    All pre-throttle data (Phase 2 + thermal sweeps) is pooled and split
    80/20 stratified by lambda value.

    Post-throttle data is by default held out as an OOD stress test.
    Use --use_post_throttle to include it in training for a better leakage
    fit when pre-throttle data has insufficient high-temperature coverage.

    Train  (80% of pre-throttle [+ post-throttle if flag set])
    Test   (20% of pre-throttle, stratified by lambda)
    Stress (post-throttle, OOD — empty if --use_post_throttle)

Alpha values are loaded from composition_params.json and frozen.
Only P0 and T0 are fitted here.

Usage:
    python3 fit_composition.py <data_root> [--seed N] [--thermal_dir DIR]
                               [--use_post_throttle]
"""

import sys
import json
import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.optimize import minimize
from sklearn.model_selection import StratifiedShuffleSplit

plt.rcParams.update({
    "axes.grid": True,
    "grid.alpha": 0.3,
    "axes.spines.top": False,
    "axes.spines.right": False,
})

CLUSTERS     = ["little", "big", "prime"]
FEATURE_COLS = ["V_little", "V_big", "V_prime",
                "f_little", "f_big", "f_prime",
                "T_little", "T_big", "T_prime",
                "measured_W", "source", "lambda_val"]
TRAIN_FRAC   = 0.80
T_PHASE2_MAX = 55.0


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
    throttling; on G3 it gives a slightly tighter estimate too.
    """
    for cluster in ["little", "big", "prime"]:
        cores = topology[cluster]
        cols = [f"freq_cpu{c}" for c in cores if f"freq_cpu{c}" in df.columns]
        if not cols:
            continue
        freq_per_core = df[cols].apply(pd.to_numeric, errors="coerce")
        df[f"f_{cluster}_kHz"] = freq_per_core.mean(axis=1)
    return df


# ---------------------------------------------------------------------------
# Column normalisation
# ---------------------------------------------------------------------------

def _normalise(df: pd.DataFrame) -> pd.DataFrame:
    """
    Rename raw sysfs columns to model column names.
    f_*_kHz at this point already holds per-core mean (see compute_cluster_freq).
    """
    return df.rename(columns={
        "v_little_V":   "V_little",
        "v_big_V":      "V_big",
        "v_prime_V":    "V_prime",
        "f_little_kHz": "f_little",
        "f_big_kHz":    "f_big",
        "f_prime_kHz":  "f_prime",
        "t_little_C":   "T_little",
        "t_big_C":      "T_big",
        "t_prime_C":    "T_prime",
    })


def _coerce(df: pd.DataFrame) -> pd.DataFrame:
    num_cols = [
        "cpu_total_W",
        "f_little_kHz", "f_big_kHz", "f_prime_kHz",
        "v_little_V", "v_big_V", "v_prime_V",
        "t_little_C", "t_big_C", "t_prime_C",
    ]
    # Per-core freq columns
    for c in range(9):
        num_cols.append(f"freq_cpu{c}")
    for c in num_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def _split_pre_post(stress: pd.DataFrame) -> tuple:
    """
    Split at first throttle onset.
    Throttling detected as per-core delivered frequency dropping below
    initial value by >3%.
    """
    f_l_init = stress["f_little"].iloc[0]
    f_b_init = stress["f_big"].iloc[0]
    f_p_init = stress["f_prime"].iloc[0]
    throttled = (
        (stress["f_little"] < f_l_init * 0.97) |
        (stress["f_big"]    < f_b_init * 0.97) |
        (stress["f_prime"]  < f_p_init * 0.97)
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
        with open(csv_file) as fh:
            sep = "\t" if "\t" in fh.readline() else ","
        df = pd.read_csv(csv_file, sep=sep, engine="python", decimal=",")
        dfs.append(df)
    if not dfs:
        raise FileNotFoundError(f"No CSVs in {phase2_dir}")

    raw = pd.concat(dfs, ignore_index=True)
    raw = _coerce(raw)

    # Detect topology and replace policy freq with per-core mean
    topology = detect_topology(raw)
    raw = compute_cluster_freq(raw, topology)

    if "workload" in raw.columns:
        stress = raw[raw["workload"] == "stress"].copy().reset_index(drop=True)
    else:
        stress = raw.copy().reset_index(drop=True)

    for col in ["f_little_kHz", "f_big_kHz", "f_prime_kHz"]:
        if col not in stress.columns:
            raise KeyError(f"Missing required column {col} in Phase 2 data.")

    stress = _normalise(stress)
    stress["measured_W"] = stress["cpu_total_W"]
    stress["source"]     = "phase2"
    stress["lambda_val"] = 1.0

    stress["T_max"] = stress[["T_little", "T_big", "T_prime"]].max(axis=1)
    n_before = len(stress)
    stress = stress[stress["T_max"] < T_PHASE2_MAX].copy()
    print(f"  Phase 2 temperature filter (T < {T_PHASE2_MAX}°C): "
          f"{n_before} → {len(stress)} rows")

    return stress[FEATURE_COLS].dropna().reset_index(drop=True)


def load_all_thermal_sweeps(root: Path,
                             thermal_subdir: str = "phase2b_thermal") -> tuple:
    thermal_dir = root / thermal_subdir
    if not thermal_dir.exists():
        raise FileNotFoundError(f"No {thermal_subdir}/ directory in {root}")

    pre_dfs, post_dfs = [], []
    idle_baseline = 0.0
    topology_seen = None

    for csv_file in sorted(thermal_dir.glob("thermal_rho_*.csv")):
        stem  = csv_file.stem
        parts = stem.split("_")
        try:
            lam = float(parts[parts.index("rho") + 1])
        except (ValueError, IndexError):
            print(f"  WARNING: could not parse lambda from {csv_file.name}, skipping")
            continue

        with open(csv_file) as fh:
            sep = "\t" if "\t" in fh.readline() else ","
        df = pd.read_csv(csv_file, sep=sep, engine="python", decimal=",")
        df = _coerce(df)

        # Detect topology and replace policy freq with per-core mean
        topology = detect_topology(df)
        if topology_seen is None:
            topology_seen = topology["device"]
            print(f"  Detected topology: Tensor {topology_seen}")
        df = compute_cluster_freq(df, topology)

        phase_col = "phase" if "phase" in df.columns else "workload"

        if abs(lam - 1.0) < 0.01:
            idle = df[df[phase_col].str.contains("idle", na=False)]
            if len(idle) > 0:
                idle_baseline = float(idle["cpu_total_W"].mean())

        stress = df[df[phase_col].str.contains("stress|sweep", na=False)].copy()
        stress = stress.reset_index(drop=True)

        if len(stress) == 0:
            continue

        for col in ["f_little_kHz", "f_big_kHz", "f_prime_kHz"]:
            if col not in stress.columns:
                raise KeyError(f"Missing {col} in {csv_file.name}.")

        stress = _normalise(stress)
        stress["measured_W"] = stress["cpu_total_W"]
        stress["lambda_val"] = lam

        pre, post = _split_pre_post(stress)
        pre["source"]  = f"thermal_pre_lam{lam:.2f}"
        post["source"] = f"thermal_post_lam{lam:.2f}"

        pre_clean  = pre[FEATURE_COLS].dropna()
        post_clean = post[FEATURE_COLS].dropna()

        if len(pre_clean)  > 0: pre_dfs.append(pre_clean)
        if len(post_clean) > 0: post_dfs.append(post_clean)

        print(f"  {csv_file.name}: λ={lam:.2f}  "
              f"pre={len(pre_clean)}  post={len(post_clean)}")

    if not pre_dfs:
        raise FileNotFoundError("No pre-throttle thermal data found.")

    pre_all  = pd.concat(pre_dfs,  ignore_index=True)
    post_all = pd.concat(post_dfs, ignore_index=True) if post_dfs \
               else pd.DataFrame(columns=FEATURE_COLS)

    return pre_all, post_all, idle_baseline


def stratified_split(df: pd.DataFrame, train_frac: float, seed: int) -> tuple:
    strata = df["lambda_val"].round(2).astype(str).values
    sss = StratifiedShuffleSplit(
        n_splits=1, test_size=1.0 - train_frac, random_state=seed
    )
    train_idx, test_idx = next(sss.split(df, strata))
    return df.iloc[train_idx].copy(), df.iloc[test_idx].copy()


# ---------------------------------------------------------------------------
# Temperature distribution diagnostic
# ---------------------------------------------------------------------------

def print_temp_distribution(df: pd.DataFrame, label: str):
    T_max = df[["T_little", "T_big", "T_prime"]].max(axis=1)
    bins   = [0, 40, 50, 60, 70, 80, 90, 120]
    labels = ["<40", "40-50", "50-60", "60-70", "70-80", "80-90", ">90"]
    print(f"\n  [{label}] Temperature distribution (n={len(df)}, "
          f"T_max range {T_max.min():.0f}–{T_max.max():.0f}°C):")
    for i, lbl in enumerate(labels):
        mask = (T_max >= bins[i]) & (T_max < bins[i+1])
        if mask.sum() > 0:
            print(f"    T={lbl:6s}°C: n={mask.sum():4d}  "
                  f"({100*mask.sum()/len(df):.0f}%)")


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

def predict_pdyn(df: pd.DataFrame, alphas: dict) -> np.ndarray:
    a_l = alphas["little"]["alpha"]
    a_b = alphas["big"]["alpha"]
    a_p = alphas["prime"]["alpha"]
    p_l = a_l * (df["V_little"].values ** 2) * (df["f_little"].values * 1e3)
    p_b = a_b * (df["V_big"].values    ** 2) * (df["f_big"].values    * 1e3)
    p_p = a_p * (df["V_prime"].values  ** 2) * (df["f_prime"].values  * 1e3)
    return p_l + p_b + p_p


def predict_pleak(df: pd.DataFrame, P0: float, T0: float) -> np.ndarray:
    T_max = df[["T_little", "T_big", "T_prime"]].max(axis=1).values
    return P0 * np.exp(T_max / T0)


def predict_total(df: pd.DataFrame, alphas: dict,
                  P0: float, T0: float) -> np.ndarray:
    return predict_pdyn(df, alphas) + predict_pleak(df, P0, T0)


# ---------------------------------------------------------------------------
# Fitting
# ---------------------------------------------------------------------------

def fit_leakage(train_df: pd.DataFrame, alphas: dict) -> tuple:
    measured = train_df["measured_W"].values

    def loss(params):
        P0, T0 = params
        if P0 <= 0 or T0 <= 0:
            return 1e10
        residual = measured - predict_pdyn(train_df, alphas) \
                             - predict_pleak(train_df, P0, T0)
        return float(np.mean(residual ** 2))

    res = minimize(loss, x0=[0.05, 30.0], method="L-BFGS-B",
                   bounds=[(0.001, 5.0), (5.0, 200.0)])
    return float(res.x[0]), float(res.x[1]), res


# ---------------------------------------------------------------------------
# Metrics and plots
# ---------------------------------------------------------------------------

def metrics(measured: np.ndarray, predicted: np.ndarray) -> dict:
    res    = measured - predicted
    rmse   = float(np.sqrt(np.mean(res ** 2)))
    bias   = float(np.mean(res))
    ss_res = float(np.sum(res ** 2))
    ss_tot = float(np.sum((measured - measured.mean()) ** 2))
    r2     = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    return {"rmse_W": round(rmse, 4), "bias_W": round(bias, 4),
            "r2": round(r2, 4), "n": int(len(measured))}


def plot_scatter(df, predicted, title, out):
    fig, ax = plt.subplots(figsize=(8, 7))
    measured = df["measured_W"].values
    lambdas  = sorted(df["lambda_val"].unique())
    cmap     = plt.cm.get_cmap("tab10", len(lambdas))
    for i, lam in enumerate(lambdas):
        m = df["lambda_val"].values == lam
        ax.scatter(predicted[m], measured[m],
                   label=f"λ={lam:.2f} (n={int(m.sum())})",
                   color=cmap(i), s=40, alpha=0.7,
                   edgecolor="black", linewidth=0.3)
    lo = min(predicted.min(), measured.min()) * 0.9
    hi = max(predicted.max(), measured.max()) * 1.05
    ax.plot([lo, hi], [lo, hi], "k--", alpha=0.5, label="y = x")
    rmse = float(np.sqrt(np.mean((measured - predicted) ** 2)))
    ss   = float(np.sum((measured - measured.mean()) ** 2))
    r2   = 1 - float(np.sum((measured - predicted) ** 2)) / ss if ss > 0 else float("nan")
    ax.set_title(f"{title}\nRMSE={rmse:.3f} W  R²={r2:.3f}")
    ax.set_xlabel("Predicted (W)"); ax.set_ylabel("Measured (W)")
    ax.legend(fontsize=7, ncol=2)
    ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
    fig.tight_layout()
    fig.savefig(out, dpi=150); plt.close(fig)
    print(f"  wrote {out.name}")


def plot_residuals_vs_T(df, predicted, out):
    fig, ax = plt.subplots(figsize=(9, 6))
    measured  = df["measured_W"].values
    residuals = measured - predicted
    T_max     = df[["T_little", "T_big", "T_prime"]].max(axis=1).values
    lambdas   = sorted(df["lambda_val"].unique())
    cmap      = plt.cm.get_cmap("tab10", len(lambdas))
    for i, lam in enumerate(lambdas):
        m = df["lambda_val"].values == lam
        ax.scatter(T_max[m], residuals[m], label=f"λ={lam:.2f}",
                   color=cmap(i), s=40, alpha=0.7,
                   edgecolor="black", linewidth=0.3)
    ax.axhline(0, color="black", linewidth=0.8, alpha=0.6)
    ax.set_xlabel("T_max (°C)"); ax.set_ylabel("Residual (W)")
    ax.set_title("Residuals vs temperature")
    ax.legend(fontsize=7, ncol=2)
    fig.tight_layout()
    fig.savefig(out, dpi=150); plt.close(fig)
    print(f"  wrote {out.name}")


def plot_term_decomposition(df, alphas, P0, T0, out):
    p_dyn  = predict_pdyn(df, alphas)
    p_leak = predict_pleak(df, P0, T0)
    total  = df["measured_W"].values
    fig, ax = plt.subplots(figsize=(7, 5))
    labels = ["P_dyn", "P_leak(T)", "Total (pred)", "Total (meas)"]
    values = [p_dyn.mean(), p_leak.mean(),
              (p_dyn + p_leak).mean(), total.mean()]
    colors = ["#1f77b4", "#d62728", "#ff7f0e", "#2ca02c"]
    ax.bar(labels, values, color=colors, edgecolor="black", linewidth=0.5)
    ax.set_ylabel("Mean power (W)")
    ax.set_title("Mean contribution of each model term (training set)")
    for i, v in enumerate(values):
        ax.text(i, v + 0.01, f"{v:.3f}", ha="center", fontsize=9)
    fig.tight_layout()
    fig.savefig(out, dpi=150); plt.close(fig)
    print(f"  wrote {out.name}")


# ---------------------------------------------------------------------------
# Measurement quality filters
# ---------------------------------------------------------------------------

def filter_stable_windows(df: pd.DataFrame, col: str = "measured_W",
                          window: int = 10, cv_threshold: float = 0.02) -> pd.DataFrame:
    """
    Exclude samples where the trailing coefficient of variation (std / mean)
    over `window` rows exceeds `cv_threshold`.  A CV above 2 % signals that
    the measurement epoch has not yet reached steady-state — the chip is still
    in a thermal or power transient.  Rows near the start of a group where the
    full window is not yet available retain their NaN CV and are kept.
    """
    rolling = df[col].rolling(window=window, min_periods=window)
    cv = rolling.std() / rolling.mean().abs()
    mask = cv.isna() | (cv <= cv_threshold)
    n_before = len(df)
    out = df[mask].copy()
    print(f"  CV filter (window={window}, CV ≤ {cv_threshold:.0%}): "
          f"{n_before} → {len(out)} rows  (dropped {n_before - len(out)})")
    return out


def remove_isolated_spikes(df: pd.DataFrame, col: str = "measured_W",
                           half_win: int = 2, threshold: float = 0.10) -> pd.DataFrame:
    """
    Remove isolated single-sample spikes while preserving sustained shifts.

    For each sample x_i, the symmetric neighbourhood [i-half_win, i+half_win]
    (excluding x_i itself) is used to compute:
        local_median — robust centre of the neighbourhood
        local_cv     — coefficient of variation of those neighbours

    A sample is flagged as an isolated spike and dropped when both hold:
        (a) |x_i - local_median| / local_median > threshold  (outlying value)
        (b) local_cv < threshold                              (neighbours stable)

    Condition (b) is the discriminator: if neighbours are themselves dispersed
    — as during throttling onset where power drops across several consecutive
    samples — both the candidate and its surroundings are in motion, so the
    point belongs to a genuine sustained shift and is retained.
    """
    x = df[col].to_numpy()
    n = len(x)
    spike = np.zeros(n, dtype=bool)

    for i in range(n):
        lo = max(0, i - half_win)
        hi = min(n, i + half_win + 1)
        neighbors = np.concatenate([x[lo:i], x[i + 1:hi]])
        if len(neighbors) < 2:
            continue
        local_med = float(np.median(neighbors))
        if local_med == 0:
            continue
        local_cv = float(neighbors.std()) / abs(local_med)
        dev = abs(x[i] - local_med) / abs(local_med)
        if dev > threshold and local_cv < threshold:
            spike[i] = True

    out = df[~spike].copy()
    print(f"  Spike filter (half_win={half_win}, threshold={threshold:.0%}): "
          f"removed {int(spike.sum())}/{len(df)} samples")
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data_root")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--thermal_dir", type=str, default="phase2b_thermal",
                        help="Subdirectory under data_root containing thermal sweep CSVs "
                             "(default: phase2b_thermal)")
    parser.add_argument("--use_post_throttle", action="store_true", default=False,
                        help="Include post-throttle rows in training for better "
                             "leakage fit when pre-throttle data lacks high-T coverage. "
                             "Stress test set will be empty when this flag is set.")
    args = parser.parse_args()

    root  = Path(args.data_root)
    seed  = args.seed
    plots = root / "plots"
    plots.mkdir(exist_ok=True)

    # ── Load alpha's ──────────────────────────────────────────────────────────
    for fname in ["composition_params.json", "composition_full_params.json"]:
        pf = root / fname
        if pf.exists():
            with open(pf) as f:
                old_params = json.load(f)
            print(f"Loaded params from {fname}")
            break
    else:
        print("No params file found — run fit_alpha.py first.", file=sys.stderr)
        sys.exit(1)

    alphas = old_params.get("alphas") or old_params.get("alphas_fit")
    if alphas is None:
        print("No 'alphas' key in params file.", file=sys.stderr); sys.exit(1)

    print("Loaded α's (fixed, from Phase 1):")
    for c in CLUSTERS:
        print(f"  α_{c} = {alphas[c]['alpha']:.4e}")

    # ── Load data ─────────────────────────────────────────────────────────────
    print("\nLoading Phase 2 data...")
    p2 = load_phase2(root)
    print(f"  {len(p2)} stress rows")

    print("\nLoading thermal sweeps...")
    pre_all, post_all, idle_baseline = load_all_thermal_sweeps(root, args.thermal_dir)
    print(f"\n  Total pre-throttle rows:  {len(pre_all)}")
    print(f"  Total post-throttle rows: {len(post_all)}")
    print(f"  Idle baseline:            {idle_baseline:.4f} W")

    print_temp_distribution(pre_all, "Pre-throttle")
    if len(post_all) > 0:
        print_temp_distribution(post_all, "Post-throttle")

    # ── Measurement quality filters ───────────────────────────────────────────
    print("\nApplying measurement quality filters...")
    p2      = filter_stable_windows(p2)
    p2      = remove_isolated_spikes(p2)
    pre_all = filter_stable_windows(pre_all)
    pre_all = remove_isolated_spikes(pre_all)
    if len(post_all) > 0:
        post_all = filter_stable_windows(post_all)
        post_all = remove_isolated_spikes(post_all)

    # ── Pool and split ────────────────────────────────────────────────────────
    pre_train, pre_test = stratified_split(pre_all, TRAIN_FRAC, seed)
    train = pd.concat([p2, pre_train], ignore_index=True)
    test  = pre_test.copy()

    # Optionally include post-throttle rows in training
    if args.use_post_throttle and len(post_all) > 0:
        print(f"\n  --use_post_throttle: adding {len(post_all)} post-throttle rows to train")
        train = pd.concat([train, post_all], ignore_index=True)
        print(f"  New train size: {len(train)}")
        print_temp_distribution(train, "Train (with post-throttle)")
        post_all = pd.DataFrame(columns=FEATURE_COLS)  # OOD holdout now empty
    else:
        print_temp_distribution(train, "Train (pre-throttle only)")

    print(f"\nSplit (seed={seed}, train_frac={TRAIN_FRAC}"
          f"{', +post_throttle' if args.use_post_throttle else ''}):")
    print(f"  Train: {len(train)} rows  "
          f"(Phase 2: {len(p2)}, thermal: {len(train)-len(p2)})")
    print(f"  Test:  {len(test)} rows  (pre-throttle 20%, stratified by λ)")
    print(f"  Stress test: {len(post_all)} rows  (post-throttle OOD)")

    print("\n  Test set breakdown by λ:")
    for lam in sorted(test["lambda_val"].unique()):
        n = int((test["lambda_val"] == lam).sum())
        print(f"    λ={lam:.2f}: {n} rows")

    # Dynamic power sanity check
    p_dyn_check = predict_pdyn(train, alphas)
    mean_meas   = train["measured_W"].mean()
    print(f"\n  Dynamic power sanity check: "
          f"mean P_dyn={p_dyn_check.mean():.4f} W  "
          f"mean measured={mean_meas:.4f} W  "
          f"ratio={100*p_dyn_check.mean()/mean_meas:.1f}%")

    # ── Fit ───────────────────────────────────────────────────────────────────
    print("\n=== Fitting leakage parameters (P0, T0) ===")
    P0, T0, res = fit_leakage(train, alphas)
    print(f"  optimizer success: {res.success}")
    print(f"  P0 = {P0:.6f} W")
    print(f"  T0 = {T0:.2f} °C  (leakage doubles every {T0*0.693:.1f}°C)")

    print(f"  Leakage at 50°C: {P0*np.exp(50/T0):.4f} W")
    print(f"  Leakage at 70°C: {P0*np.exp(70/T0):.4f} W")
    print(f"  Leakage at 90°C: {P0*np.exp(90/T0):.4f} W")

    # ── Evaluate ──────────────────────────────────────────────────────────────
    pred_train = predict_total(train, alphas, P0, T0)
    pred_test  = predict_total(test,  alphas, P0, T0)
    pred_post  = predict_total(post_all, alphas, P0, T0) \
                 if len(post_all) > 0 else np.array([])

    train_m = metrics(train["measured_W"].values, pred_train)
    test_m  = metrics(test["measured_W"].values,  pred_test)

    print(f"\n=== Performance ===")
    print(f"  Train  (n={train_m['n']:3d}):  "
          f"RMSE {train_m['rmse_W']:.4f} W  "
          f"R² {train_m['r2']:.4f}  "
          f"bias {train_m['bias_W']:+.4f} W")
    print(f"  Test   (n={test_m['n']:3d}):  "
          f"RMSE {test_m['rmse_W']:.4f} W  "
          f"R² {test_m['r2']:.4f}  "
          f"bias {test_m['bias_W']:+.4f} W")

    if len(post_all) > 0:
        post_m = metrics(post_all["measured_W"].values, pred_post)
        print(f"  Stress (n={post_m['n']:3d}):  "
              f"RMSE {post_m['rmse_W']:.4f} W  "
              f"R² {post_m['r2']:.4f}  "
              f"bias {post_m['bias_W']:+.4f} W  "
              f"(post-throttle OOD)")
    else:
        post_m = {}
        if args.use_post_throttle:
            print(f"  Stress: n/a (post-throttle rows included in training)")

    p_dyn_train  = predict_pdyn(train, alphas)
    p_leak_train = predict_pleak(train, P0, T0)
    print(f"\nMean term contributions (training set):")
    print(f"  P_dyn:     {p_dyn_train.mean():.4f} W  "
          f"({100*p_dyn_train.mean()/mean_meas:.1f}%)")
    print(f"  P_leak(T): {p_leak_train.mean():.4f} W  "
          f"({100*p_leak_train.mean()/mean_meas:.1f}%)")

    # ── Save ──────────────────────────────────────────────────────────────────
    out_params = {
        "model": "two_term_dyn_leak",
        "formula": "P_total = sum_c[alpha_c * V_c^2 * f_c] + P0 * exp(T_max/T0)",
        "frequency_source": "per-core mean from freq_cpu* (actual delivered freq)",
        "split": {
            "strategy": "stratified_80_20_by_lambda",
            "seed": seed,
            "train_frac": TRAIN_FRAC,
            "use_post_throttle": args.use_post_throttle,
            "n_train": train_m["n"],
            "n_test":  test_m["n"],
            "n_stress_test": int(len(post_all)),
        },
        "alphas": alphas,
        "leakage": {"P0": P0, "T0": T0,
                    "driver": "T_max = max(T_little, T_big, T_prime)"},
        "train_metrics": train_m,
        "test_metrics":  test_m,
        "stress_test_metrics": post_m,
    }
    out_json = root / "composition_simple_params.json"
    with open(out_json, "w") as f:
        json.dump(out_params, f, indent=2)
    print(f"\nWrote {out_json}")

    # ── Plots ─────────────────────────────────────────────────────────────────
    plot_scatter(train, pred_train, "Training set", plots / "W1_train.png")
    plot_scatter(test,  pred_test,  "Test set (held out, pre-throttle)",
                 plots / "W2_test.png")
    if len(post_all) > 0:
        plot_scatter(post_all, pred_post,
                     "Stress test (post-throttle, OOD)",
                     plots / "W3_stress.png")
    all_pre = pd.concat([train, test], ignore_index=True)
    pred_all_pre = predict_total(all_pre, alphas, P0, T0)
    plot_residuals_vs_T(all_pre, pred_all_pre, plots / "W4_residuals_vs_T.png")
    plot_term_decomposition(train, alphas, P0, T0,
                            plots / "W5_term_decomposition.png")


if __name__ == "__main__":
    main()

# #!/usr/bin/env python3
# """
# fit_composition.py - Two-term power model (dynamic + leakage only).
#
# Model:
#     P_total = P_dyn + P_leak(T)
#
# where:
#     P_dyn     = sum_c [alpha_c * V_c^2 * f_c]  -- analytical CMOS
#     P_leak(T) = P0 * exp(T_max / T0)           -- temperature-varying leakage
#
# Frequency source: f_*_kHz (commanded setpoint) NOT freq_cpu* (achieved).
# During pinned calibration runs the setpoint is stable; freq_cpu* fluctuates
# due to sampling jitter and momentary idle quanta, biasing the dynamic term.
#
# Data split strategy:
#     All pre-throttle data (Phase 2 + thermal sweeps) is pooled and split
#     80/20 stratified by lambda value.
#
#     Post-throttle data is by default held out as an OOD stress test.
#     Use --use_post_throttle to include it in training for a better leakage
#     fit when pre-throttle data has insufficient high-temperature coverage.
#
#     Train  (80% of pre-throttle [+ post-throttle if flag set])
#     Test   (20% of pre-throttle, stratified by lambda)
#     Stress (post-throttle, OOD — empty if --use_post_throttle)
#
# Alpha values are loaded from composition_params.json and frozen.
# Only P0 and T0 are fitted here.
#
# Usage:
#     python3 fit_composition.py <data_root> [--seed N] [--thermal_dir DIR]
#                                [--use_post_throttle]
# """
#
# import sys
# import json
# import argparse
# from pathlib import Path
#
# import numpy as np
# import pandas as pd
# import matplotlib.pyplot as plt
# from scipy.optimize import minimize
# from sklearn.model_selection import StratifiedShuffleSplit
#
# plt.rcParams.update({
#     "axes.grid": True,
#     "grid.alpha": 0.3,
#     "axes.spines.top": False,
#     "axes.spines.right": False,
# })
#
# CLUSTERS     = ["little", "big", "prime"]
# FEATURE_COLS = ["V_little", "V_big", "V_prime",
#                 "f_little", "f_big", "f_prime",
#                 "T_little", "T_big", "T_prime",
#                 "measured_W", "source", "lambda_val"]
# TRAIN_FRAC   = 0.80
# T_PHASE2_MAX = 55.0
#
#
# # ---------------------------------------------------------------------------
# # Column normalisation
# # ---------------------------------------------------------------------------
#
# def _normalise(df: pd.DataFrame) -> pd.DataFrame:
#     """
#     Rename raw sysfs columns to model column names.
#     Uses f_*_kHz (commanded setpoint) for frequency.
#     """
#     return df.rename(columns={
#         "v_little_V":   "V_little",
#         "v_big_V":      "V_big",
#         "v_prime_V":    "V_prime",
#         "f_little_kHz": "f_little",
#         "f_big_kHz":    "f_big",
#         "f_prime_kHz":  "f_prime",
#         "t_little_C":   "T_little",
#         "t_big_C":      "T_big",
#         "t_prime_C":    "T_prime",
#     })
#
#
# def _coerce(df: pd.DataFrame) -> pd.DataFrame:
#     num_cols = [
#         "cpu_total_W",
#         "f_little_kHz", "f_big_kHz", "f_prime_kHz",
#         "v_little_V", "v_big_V", "v_prime_V",
#         "t_little_C", "t_big_C", "t_prime_C",
#     ]
#     for c in num_cols:
#         if c in df.columns:
#             df[c] = pd.to_numeric(df[c], errors="coerce")
#     return df
#
#
# def _split_pre_post(stress: pd.DataFrame) -> tuple:
#     """
#     Split at first throttle onset.
#     Throttling detected as setpoint dropping below initial value by >3%.
#     """
#     f_l_init = stress["f_little"].iloc[0]
#     f_b_init = stress["f_big"].iloc[0]
#     f_p_init = stress["f_prime"].iloc[0]
#     throttled = (
#         (stress["f_little"] < f_l_init * 0.97) |
#         (stress["f_big"]    < f_b_init * 0.97) |
#         (stress["f_prime"]  < f_p_init * 0.97)
#     )
#     boundary = int(throttled.idxmax()) if throttled.any() else len(stress)
#     return stress.iloc[:boundary].copy(), stress.iloc[boundary:].copy()
#
#
# # ---------------------------------------------------------------------------
# # Data loading
# # ---------------------------------------------------------------------------
#
# def load_phase2(root: Path) -> pd.DataFrame:
#     phase2_dir = root / "phase2"
#     if not phase2_dir.exists():
#         raise FileNotFoundError(f"No phase2/ directory in {root}")
#
#     dfs = []
#     for csv_file in sorted(phase2_dir.glob("*.csv")):
#         with open(csv_file) as fh:
#             sep = "\t" if "\t" in fh.readline() else ","
#         df = pd.read_csv(csv_file, sep=sep, engine="python", decimal=",")
#         dfs.append(df)
#     if not dfs:
#         raise FileNotFoundError(f"No CSVs in {phase2_dir}")
#
#     raw = pd.concat(dfs, ignore_index=True)
#     raw = _coerce(raw)
#
#     if "workload" in raw.columns:
#         stress = raw[raw["workload"] == "stress"].copy().reset_index(drop=True)
#     else:
#         stress = raw.copy().reset_index(drop=True)
#
#     for col in ["f_little_kHz", "f_big_kHz", "f_prime_kHz"]:
#         if col not in stress.columns:
#             raise KeyError(f"Missing required column {col} in Phase 2 data.")
#
#     stress = _normalise(stress)
#     stress["measured_W"] = stress["cpu_total_W"]
#     stress["source"]     = "phase2"
#     stress["lambda_val"] = 1.0
#
#     stress["T_max"] = stress[["T_little", "T_big", "T_prime"]].max(axis=1)
#     n_before = len(stress)
#     stress = stress[stress["T_max"] < T_PHASE2_MAX].copy()
#     print(f"  Phase 2 temperature filter (T < {T_PHASE2_MAX}°C): "
#           f"{n_before} → {len(stress)} rows")
#
#     return stress[FEATURE_COLS].dropna().reset_index(drop=True)
#
#
# def load_all_thermal_sweeps(root: Path,
#                              thermal_subdir: str = "phase2b_thermal") -> tuple:
#     thermal_dir = root / thermal_subdir
#     if not thermal_dir.exists():
#         raise FileNotFoundError(f"No {thermal_subdir}/ directory in {root}")
#
#     pre_dfs, post_dfs = [], []
#     idle_baseline = 0.0
#
#     for csv_file in sorted(thermal_dir.glob("thermal_rho_*.csv")):
#         stem  = csv_file.stem
#         parts = stem.split("_")
#         try:
#             lam = float(parts[parts.index("rho") + 1])
#         except (ValueError, IndexError):
#             print(f"  WARNING: could not parse lambda from {csv_file.name}, skipping")
#             continue
#
#         with open(csv_file) as fh:
#             sep = "\t" if "\t" in fh.readline() else ","
#         df = pd.read_csv(csv_file, sep=sep, engine="python", decimal=",")
#         df = _coerce(df)
#
#         phase_col = "phase" if "phase" in df.columns else "workload"
#
#         if abs(lam - 1.0) < 0.01:
#             idle = df[df[phase_col].str.contains("idle", na=False)]
#             if len(idle) > 0:
#                 idle_baseline = float(idle["cpu_total_W"].mean())
#
#         stress = df[df[phase_col].str.contains("stress|sweep", na=False)].copy()
#         stress = stress.reset_index(drop=True)
#
#         if len(stress) == 0:
#             continue
#
#         for col in ["f_little_kHz", "f_big_kHz", "f_prime_kHz"]:
#             if col not in stress.columns:
#                 raise KeyError(f"Missing {col} in {csv_file.name}.")
#
#         stress = _normalise(stress)
#         stress["measured_W"] = stress["cpu_total_W"]
#         stress["lambda_val"] = lam
#
#         pre, post = _split_pre_post(stress)
#         pre["source"]  = f"thermal_pre_lam{lam:.2f}"
#         post["source"] = f"thermal_post_lam{lam:.2f}"
#
#         pre_clean  = pre[FEATURE_COLS].dropna()
#         post_clean = post[FEATURE_COLS].dropna()
#
#         if len(pre_clean)  > 0: pre_dfs.append(pre_clean)
#         if len(post_clean) > 0: post_dfs.append(post_clean)
#
#         print(f"  {csv_file.name}: λ={lam:.2f}  "
#               f"pre={len(pre_clean)}  post={len(post_clean)}")
#
#     if not pre_dfs:
#         raise FileNotFoundError("No pre-throttle thermal data found.")
#
#     pre_all  = pd.concat(pre_dfs,  ignore_index=True)
#     post_all = pd.concat(post_dfs, ignore_index=True) if post_dfs \
#                else pd.DataFrame(columns=FEATURE_COLS)
#
#     return pre_all, post_all, idle_baseline
#
#
# def stratified_split(df: pd.DataFrame, train_frac: float, seed: int) -> tuple:
#     strata = df["lambda_val"].round(2).astype(str).values
#     sss = StratifiedShuffleSplit(
#         n_splits=1, test_size=1.0 - train_frac, random_state=seed
#     )
#     train_idx, test_idx = next(sss.split(df, strata))
#     return df.iloc[train_idx].copy(), df.iloc[test_idx].copy()
#
#
# # ---------------------------------------------------------------------------
# # Temperature distribution diagnostic
# # ---------------------------------------------------------------------------
#
# def print_temp_distribution(df: pd.DataFrame, label: str):
#     T_max = df[["T_little", "T_big", "T_prime"]].max(axis=1)
#     bins   = [0, 40, 50, 60, 70, 80, 90, 120]
#     labels = ["<40", "40-50", "50-60", "60-70", "70-80", "80-90", ">90"]
#     print(f"\n  [{label}] Temperature distribution (n={len(df)}, "
#           f"T_max range {T_max.min():.0f}–{T_max.max():.0f}°C):")
#     for i, lbl in enumerate(labels):
#         mask = (T_max >= bins[i]) & (T_max < bins[i+1])
#         if mask.sum() > 0:
#             print(f"    T={lbl:6s}°C: n={mask.sum():4d}  "
#                   f"({100*mask.sum()/len(df):.0f}%)")
#
#
# # ---------------------------------------------------------------------------
# # Model
# # ---------------------------------------------------------------------------
#
# def predict_pdyn(df: pd.DataFrame, alphas: dict) -> np.ndarray:
#
#     a_l = alphas["little"]["alpha"]
#     a_b = alphas["big"]["alpha"]
#     a_p = alphas["prime"]["alpha"]
#     p_l = a_l * (df["V_little"].values ** 2) * (df["f_little"].values * 1e3)
#     p_b = a_b * (df["V_big"].values    ** 2) * (df["f_big"].values    * 1e3)
#     p_p = a_p * (df["V_prime"].values  ** 2) * (df["f_prime"].values  * 1e3)
#     return p_l + p_b + p_p
#
#
# def predict_pleak(df: pd.DataFrame, P0: float, T0: float) -> np.ndarray:
#     T_max = df[["T_little", "T_big", "T_prime"]].max(axis=1).values
#     return P0 * np.exp(T_max / T0)
#
#
# def predict_total(df: pd.DataFrame, alphas: dict,
#                   P0: float, T0: float) -> np.ndarray:
#     return predict_pdyn(df, alphas) + predict_pleak(df, P0, T0)
#
#
# # ---------------------------------------------------------------------------
# # Fitting
# # ---------------------------------------------------------------------------
#
# def fit_leakage(train_df: pd.DataFrame, alphas: dict) -> tuple:
#     measured = train_df["measured_W"].values
#
#     def loss(params):
#         P0, T0 = params
#         if P0 <= 0 or T0 <= 0:
#             return 1e10
#         residual = measured - predict_pdyn(train_df, alphas) \
#                              - predict_pleak(train_df, P0, T0)
#         return float(np.mean(residual ** 2))
#
#     res = minimize(loss, x0=[0.05, 30.0], method="L-BFGS-B",
#                    bounds=[(0.001, 5.0), (5.0, 200.0)])
#     return float(res.x[0]), float(res.x[1]), res
#
#
# # ---------------------------------------------------------------------------
# # Metrics and plots
# # ---------------------------------------------------------------------------
#
# def metrics(measured: np.ndarray, predicted: np.ndarray) -> dict:
#     res    = measured - predicted
#     rmse   = float(np.sqrt(np.mean(res ** 2)))
#     bias   = float(np.mean(res))
#     ss_res = float(np.sum(res ** 2))
#     ss_tot = float(np.sum((measured - measured.mean()) ** 2))
#     r2     = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
#     return {"rmse_W": round(rmse, 4), "bias_W": round(bias, 4),
#             "r2": round(r2, 4), "n": int(len(measured))}
#
#
# def plot_scatter(df, predicted, title, out):
#     fig, ax = plt.subplots(figsize=(8, 7))
#     measured = df["measured_W"].values
#     lambdas  = sorted(df["lambda_val"].unique())
#     cmap     = plt.cm.get_cmap("tab10", len(lambdas))
#     for i, lam in enumerate(lambdas):
#         m = df["lambda_val"].values == lam
#         ax.scatter(predicted[m], measured[m],
#                    label=f"λ={lam:.2f} (n={int(m.sum())})",
#                    color=cmap(i), s=40, alpha=0.7,
#                    edgecolor="black", linewidth=0.3)
#     lo = min(predicted.min(), measured.min()) * 0.9
#     hi = max(predicted.max(), measured.max()) * 1.05
#     ax.plot([lo, hi], [lo, hi], "k--", alpha=0.5, label="y = x")
#     rmse = float(np.sqrt(np.mean((measured - predicted) ** 2)))
#     ss   = float(np.sum((measured - measured.mean()) ** 2))
#     r2   = 1 - float(np.sum((measured - predicted) ** 2)) / ss if ss > 0 else float("nan")
#     ax.set_title(f"{title}\nRMSE={rmse:.3f} W  R²={r2:.3f}")
#     ax.set_xlabel("Predicted (W)"); ax.set_ylabel("Measured (W)")
#     ax.legend(fontsize=7, ncol=2)
#     ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
#     fig.tight_layout()
#     fig.savefig(out, dpi=150); plt.close(fig)
#     print(f"  wrote {out.name}")
#
#
# def plot_residuals_vs_T(df, predicted, out):
#     fig, ax = plt.subplots(figsize=(9, 6))
#     measured  = df["measured_W"].values
#     residuals = measured - predicted
#     T_max     = df[["T_little", "T_big", "T_prime"]].max(axis=1).values
#     lambdas   = sorted(df["lambda_val"].unique())
#     cmap      = plt.cm.get_cmap("tab10", len(lambdas))
#     for i, lam in enumerate(lambdas):
#         m = df["lambda_val"].values == lam
#         ax.scatter(T_max[m], residuals[m], label=f"λ={lam:.2f}",
#                    color=cmap(i), s=40, alpha=0.7,
#                    edgecolor="black", linewidth=0.3)
#     ax.axhline(0, color="black", linewidth=0.8, alpha=0.6)
#     ax.set_xlabel("T_max (°C)"); ax.set_ylabel("Residual (W)")
#     ax.set_title("Residuals vs temperature")
#     ax.legend(fontsize=7, ncol=2)
#     fig.tight_layout()
#     fig.savefig(out, dpi=150); plt.close(fig)
#     print(f"  wrote {out.name}")
#
#
# def plot_term_decomposition(df, alphas, P0, T0, out):
#     p_dyn  = predict_pdyn(df, alphas)
#     p_leak = predict_pleak(df, P0, T0)
#     total  = df["measured_W"].values
#     fig, ax = plt.subplots(figsize=(7, 5))
#     labels = ["P_dyn", "P_leak(T)", "Total (pred)", "Total (meas)"]
#     values = [p_dyn.mean(), p_leak.mean(),
#               (p_dyn + p_leak).mean(), total.mean()]
#     colors = ["#1f77b4", "#d62728", "#ff7f0e", "#2ca02c"]
#     ax.bar(labels, values, color=colors, edgecolor="black", linewidth=0.5)
#     ax.set_ylabel("Mean power (W)")
#     ax.set_title("Mean contribution of each model term (training set)")
#     for i, v in enumerate(values):
#         ax.text(i, v + 0.01, f"{v:.3f}", ha="center", fontsize=9)
#     fig.tight_layout()
#     fig.savefig(out, dpi=150); plt.close(fig)
#     print(f"  wrote {out.name}")
#
#
# # ---------------------------------------------------------------------------
# # Main
# # ---------------------------------------------------------------------------
#
# def main():
#     parser = argparse.ArgumentParser()
#     parser.add_argument("data_root")
#     parser.add_argument("--seed", type=int, default=42)
#     parser.add_argument("--thermal_dir", type=str, default="phase2b_thermal",
#                         help="Subdirectory under data_root containing thermal sweep CSVs "
#                              "(default: phase2b_thermal)")
#     parser.add_argument("--use_post_throttle", action="store_true", default=False,
#                         help="Include post-throttle rows in training for better "
#                              "leakage fit when pre-throttle data lacks high-T coverage. "
#                              "Stress test set will be empty when this flag is set.")
#     args = parser.parse_args()
#
#     root  = Path(args.data_root)
#     seed  = args.seed
#     plots = root / "plots"
#     plots.mkdir(exist_ok=True)
#
#     # ── Load alpha's ──────────────────────────────────────────────────────────
#     for fname in ["composition_params.json", "composition_full_params.json"]:
#         pf = root / fname
#         if pf.exists():
#             with open(pf) as f:
#                 old_params = json.load(f)
#             print(f"Loaded params from {fname}")
#             break
#     else:
#         print("No params file found — run fit_alpha.py first.", file=sys.stderr)
#         sys.exit(1)
#
#     alphas = old_params.get("alphas") or old_params.get("alphas_fit")
#     if alphas is None:
#         print("No 'alphas' key in params file.", file=sys.stderr); sys.exit(1)
#
#     print("Loaded α's (fixed, from Phase 1):")
#     for c in CLUSTERS:
#         print(f"  α_{c} = {alphas[c]['alpha']:.4e}")
#
#     # ── Load data ─────────────────────────────────────────────────────────────
#     print("\nLoading Phase 2 data...")
#     p2 = load_phase2(root)
#     print(f"  {len(p2)} stress rows")
#
#     print("\nLoading thermal sweeps...")
#     pre_all, post_all, idle_baseline = load_all_thermal_sweeps(root, args.thermal_dir)
#     print(f"\n  Total pre-throttle rows:  {len(pre_all)}")
#     print(f"  Total post-throttle rows: {len(post_all)}")
#     print(f"  Idle baseline:            {idle_baseline:.4f} W")
#
#     print_temp_distribution(pre_all, "Pre-throttle")
#     if len(post_all) > 0:
#         print_temp_distribution(post_all, "Post-throttle")
#
#     # ── Pool and split ────────────────────────────────────────────────────────
#     pre_train, pre_test = stratified_split(pre_all, TRAIN_FRAC, seed)
#     train = pd.concat([p2, pre_train], ignore_index=True)
#     test  = pre_test.copy()
#
#     # Optionally include post-throttle rows in training
#     if args.use_post_throttle and len(post_all) > 0:
#         print(f"\n  --use_post_throttle: adding {len(post_all)} post-throttle rows to train")
#         train = pd.concat([train, post_all], ignore_index=True)
#         print(f"  New train size: {len(train)}")
#         print_temp_distribution(train, "Train (with post-throttle)")
#         post_all = pd.DataFrame(columns=FEATURE_COLS)  # OOD holdout now empty
#     else:
#         print_temp_distribution(train, "Train (pre-throttle only)")
#
#     print(f"\nSplit (seed={seed}, train_frac={TRAIN_FRAC}"
#           f"{', +post_throttle' if args.use_post_throttle else ''}):")
#     print(f"  Train: {len(train)} rows  "
#           f"(Phase 2: {len(p2)}, thermal: {len(train)-len(p2)})")
#     print(f"  Test:  {len(test)} rows  (pre-throttle 20%, stratified by λ)")
#     print(f"  Stress test: {len(post_all)} rows  (post-throttle OOD)")
#
#     print("\n  Test set breakdown by λ:")
#     for lam in sorted(test["lambda_val"].unique()):
#         n = int((test["lambda_val"] == lam).sum())
#         print(f"    λ={lam:.2f}: {n} rows")
#
#     # Dynamic power sanity check
#     p_dyn_check = predict_pdyn(train, alphas)
#     mean_meas   = train["measured_W"].mean()
#     print(f"\n  Dynamic power sanity check: "
#           f"mean P_dyn={p_dyn_check.mean():.4f} W  "
#           f"mean measured={mean_meas:.4f} W  "
#           f"ratio={100*p_dyn_check.mean()/mean_meas:.1f}%")
#
#     # ── Fit ───────────────────────────────────────────────────────────────────
#     print("\n=== Fitting leakage parameters (P0, T0) ===")
#     P0, T0, res = fit_leakage(train, alphas)
#     print(f"  optimizer success: {res.success}")
#     print(f"  P0 = {P0:.6f} W")
#     print(f"  T0 = {T0:.2f} °C  (leakage doubles every {T0*0.693:.1f}°C)")
#
#     # Sanity check: leakage at typical temperatures
#     print(f"  Leakage at 50°C: {P0*np.exp(50/T0):.4f} W")
#     print(f"  Leakage at 70°C: {P0*np.exp(70/T0):.4f} W")
#     print(f"  Leakage at 90°C: {P0*np.exp(90/T0):.4f} W")
#
#     # ── Evaluate ──────────────────────────────────────────────────────────────
#     pred_train = predict_total(train, alphas, P0, T0)
#     pred_test  = predict_total(test,  alphas, P0, T0)
#     pred_post  = predict_total(post_all, alphas, P0, T0) \
#                  if len(post_all) > 0 else np.array([])
#
#     train_m = metrics(train["measured_W"].values, pred_train)
#     test_m  = metrics(test["measured_W"].values,  pred_test)
#
#     print(f"\n=== Performance ===")
#     print(f"  Train  (n={train_m['n']:3d}):  "
#           f"RMSE {train_m['rmse_W']:.4f} W  "
#           f"R² {train_m['r2']:.4f}  "
#           f"bias {train_m['bias_W']:+.4f} W")
#     print(f"  Test   (n={test_m['n']:3d}):  "
#           f"RMSE {test_m['rmse_W']:.4f} W  "
#           f"R² {test_m['r2']:.4f}  "
#           f"bias {test_m['bias_W']:+.4f} W")
#
#     if len(post_all) > 0:
#         post_m = metrics(post_all["measured_W"].values, pred_post)
#         print(f"  Stress (n={post_m['n']:3d}):  "
#               f"RMSE {post_m['rmse_W']:.4f} W  "
#               f"R² {post_m['r2']:.4f}  "
#               f"bias {post_m['bias_W']:+.4f} W  "
#               f"(post-throttle OOD)")
#     else:
#         post_m = {}
#         if args.use_post_throttle:
#             print(f"  Stress: n/a (post-throttle rows included in training)")
#
#     p_dyn_train  = predict_pdyn(train, alphas)
#     p_leak_train = predict_pleak(train, P0, T0)
#     print(f"\nMean term contributions (training set):")
#     print(f"  P_dyn:     {p_dyn_train.mean():.4f} W  "
#           f"({100*p_dyn_train.mean()/mean_meas:.1f}%)")
#     print(f"  P_leak(T): {p_leak_train.mean():.4f} W  "
#           f"({100*p_leak_train.mean()/mean_meas:.1f}%)")
#
#     # ── Save ──────────────────────────────────────────────────────────────────
#     out_params = {
#         "model": "two_term_dyn_leak",
#         "formula": "P_total = sum_c[alpha_c * V_c^2 * f_c] + P0 * exp(T_max/T0)",
#         "frequency_source": "f_*_kHz (commanded setpoint)",
#         "split": {
#             "strategy": "stratified_80_20_by_lambda",
#             "seed": seed,
#             "train_frac": TRAIN_FRAC,
#             "use_post_throttle": args.use_post_throttle,
#             "n_train": train_m["n"],
#             "n_test":  test_m["n"],
#             "n_stress_test": int(len(post_all)),
#         },
#         "alphas": alphas,
#         "leakage": {"P0": P0, "T0": T0,
#                     "driver": "T_max = max(T_little, T_big, T_prime)"},
#         "train_metrics": train_m,
#         "test_metrics":  test_m,
#         "stress_test_metrics": post_m,
#     }
#     out_json = root / "composition_simple_params.json"
#     with open(out_json, "w") as f:
#         json.dump(out_params, f, indent=2)
#     print(f"\nWrote {out_json}")
#
#     # ── Plots ─────────────────────────────────────────────────────────────────
#     plot_scatter(train, pred_train, "Training set", plots / "W1_train.png")
#     plot_scatter(test,  pred_test,  "Test set (held out, pre-throttle)",
#                  plots / "W2_test.png")
#     if len(post_all) > 0:
#         plot_scatter(post_all, pred_post,
#                      "Stress test (post-throttle, OOD)",
#                      plots / "W3_stress.png")
#     all_pre = pd.concat([train, test], ignore_index=True)
#     pred_all_pre = predict_total(all_pre, alphas, P0, T0)
#     plot_residuals_vs_T(all_pre, pred_all_pre, plots / "W4_residuals_vs_T.png")
#     plot_term_decomposition(train, alphas, P0, T0,
#                             plots / "W5_term_decomposition.png")
#
#
# if __name__ == "__main__":
#     main()