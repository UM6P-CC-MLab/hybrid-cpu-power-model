#!/usr/bin/env python3
"""
score_ml_inference.py — ML inference power and energy evaluation.

Model:
    P_total = sum_c [ C_eff_c * V^2_c * f_c * rho_c ]        # dynamic
            + P_static_c * 1(rho_c < 0.05, others active)    # per-cluster static floor
            + P_infra * 1(cpu_active)                         # shared infrastructure
            + P0 * exp(T_max / T0)                            # global leakage

P_static_c is the rail power cluster c draws as a bystander when other clusters
are active. Loaded from static_floor_params.json (fit_cluster_combos.py output).

P_infra is loaded from combo_infra_params.json (Phase 2c output).
If not found, falls back to zero (two-term model only).

Usage:
    python3 score_ml_inference.py <data_root> [cluster] [csv_filename]
"""

import sys
import json
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

plt.rcParams.update({
    "axes.grid": True, "grid.alpha": 0.3,
    "axes.spines.top": False, "axes.spines.right": False,
})

CLUSTER_CORES = {
    "little": [0, 1, 2, 3],
    "big":    [4, 5, 6, 7],
    "prime":  [8],
}

# Threshold above which a cluster is considered "active" for P_infra
RHO_ACTIVE_THRESHOLD = 0.1


def load_params(data_root: Path) -> tuple:
    """
    Load model params from composition_simple_params.json and
    infrastructure params from combo_infra_params.json.

    Returns (model_params, P_infra).
    P_infra is the mean infrastructure power across all combos,
    or 0.0 if combo_infra_params.json is not found.
    """
    # Load dynamic + leakage params
    model_params = None
    for fname in ["composition_simple_params.json", "composition_params.json"]:
        p = data_root / fname
        if p.exists():
            with open(p) as f:
                model_params = json.load(f)
            print(f"  Loaded model params from {fname}")
            break
    if model_params is None:
        raise FileNotFoundError(f"No model params JSON found in {data_root}")

    # Load infrastructure params
    infra_path = data_root / "combo_infra_params.json"
    P_infra = 0.0
    if infra_path.exists():
        with open(infra_path) as f:
            infra_params = json.load(f)
        # Use mean P_infra across all combos as the general estimate
        combos = infra_params.get("combos", {})
        if combos:
            values = [v["P_infra_W"] for v in combos.values() if v.get("n_samples", 0) > 0]
            P_infra = float(np.mean(values)) if values else 0.0
            print(f"  Loaded infra params from combo_infra_params.json")
            print(f"    P_infra combos: { {k: round(v['P_infra_W'],4) for k,v in combos.items()} }")
            print(f"    P_infra (mean): {P_infra:.4f} W")
    else:
        print(f"  combo_infra_params.json not found — P_infra=0.0 (two-term model)")

    # Load static floor params
    P_static = {}
    static_path = data_root / "static_floor_params.json"
    if static_path.exists():
        with open(static_path) as f:
            static_params = json.load(f)
        for cl, v in static_params.get("P_static", {}).items():
            P_static[cl] = float(v.get("P_static_at_inference_W",
                                       v.get("P_static_W", 0.0)))
        print(f"  Loaded static floor params from static_floor_params.json")
        for cl, val in P_static.items():
            print(f"    P_static_{cl} = {val:.4f} W")
    else:
        print(f"  static_floor_params.json not found — P_static=0 for all clusters")

    return model_params, P_infra, P_static


def load_csv(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path, decimal=",")
    num_cols = (
        ["timestamp_ms", "cpu_total_W", "little_W", "big_W", "prime_W",
         "v_little_V", "v_big_V", "v_prime_V",
         "f_little_kHz", "f_big_kHz", "f_prime_kHz",
         "rho_little", "rho_big", "rho_prime",
         "t_little_C", "t_big_C", "t_prime_C",
         "batt_W", "ram_W", "system_W", "usage_cpu8"]
        + [f"usage_cpu{c}" for c in range(9)]
        + [f"freq_cpu{c}"  for c in range(9)]
    )
    for c in num_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    for c in [f"usage_cpu{i}" for i in range(9)] + [f"freq_cpu{i}" for i in range(9)]:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def recompute_rho(df: pd.DataFrame) -> pd.DataFrame:
    for cluster, cores in CLUSTER_CORES.items():
        cols = [f"usage_cpu{c}" for c in cores if f"usage_cpu{c}" in df.columns]
        if not cols:
            continue
        usage = df[cols].copy().fillna(0.0)
        online_mask = (usage > 0).any(axis=0)
        online_cols = usage.columns[online_mask].tolist()
        df[f"rho_{cluster}"] = (
            usage[online_cols].mean(axis=1) / 100.0 if online_cols else 0.0
        )
    return df


def recompute_freq(df: pd.DataFrame) -> pd.DataFrame:
    for cluster, cores in CLUSTER_CORES.items():
        cols = [f"freq_cpu{c}" for c in cores if f"freq_cpu{c}" in df.columns]
        if not cols:
            continue
        freq = df[cols].apply(pd.to_numeric, errors="coerce")
        row_mean  = freq.mean(axis=1)
        logged_col = f"f_{cluster}_kHz"
        if logged_col in df.columns:
            fallback = pd.to_numeric(df[logged_col], errors="coerce")
            df[logged_col] = np.where(row_mean.isna(), fallback, row_mean)
        else:
            df[logged_col] = row_mean
    return df


def predict(df: pd.DataFrame, params: dict, P_infra: float,
            P_static: dict = None,
            active_cluster: str = None) -> np.ndarray:
    """
    Four-term model prediction:
        P = P_dyn
          + P_static_c * 1(rho_c < 0.05, any other cluster active)
          + P_infra * 1(cpu_active)
          + P_leak(T)

    P_static_c captures per-cluster rail power when cluster c is a
    bystander (idle while others work). Fitted from phase2c_combos.

    Returns a scalar mean power (W) for energy integration.
    """
    if P_static is None:
        P_static = {}
    alphas  = params.get("alphas") or params.get("alphas_fit")
    a_l = alphas["little"]["alpha"]
    a_b = alphas["big"]["alpha"]
    a_p = alphas["prime"]["alpha"]
    leakage = params.get("leakage", {})
    P0 = leakage.get("P0", 0.05)
    T0 = leakage.get("T0", 30.0)

    f_l = df["f_little_kHz"].values * 1e3
    f_b = df["f_big_kHz"].values    * 1e3
    f_p = (df["f_prime_kHz"].values * 1e3
           if "f_prime_kHz" in df.columns else np.zeros(len(df)))
    v_l = df["v_little_V"].values
    v_b = df["v_big_V"].values
    v_p = df["v_prime_V"].values

    rho_l = df["rho_little"].values if "rho_little" in df.columns else np.zeros(len(df))
    rho_b = df["rho_big"].values    if "rho_big" in df.columns    else np.zeros(len(df))
    rho_p = df["rho_prime"].values  if "rho_prime" in df.columns  else np.zeros(len(df))

    # Use mean-of-means for scalar prediction
    def safe_mean(arr):
        return float(np.mean(arr[np.isfinite(arr)])) if np.any(np.isfinite(arr)) else 0.0

    f_l_m  = safe_mean(f_l);  f_b_m  = safe_mean(f_b);  f_p_m  = safe_mean(f_p)
    v_l_m  = safe_mean(v_l);  v_b_m  = safe_mean(v_b);  v_p_m  = safe_mean(v_p)
    rho_l_m = safe_mean(rho_l); rho_b_m = safe_mean(rho_b); rho_p_m = safe_mean(rho_p)

    p_dyn_l = a_l * v_l_m**2 * f_l_m * rho_l_m
    p_dyn_b = a_b * v_b_m**2 * f_b_m * rho_b_m
    p_dyn_p = a_p * v_p_m**2 * f_p_m * rho_p_m

    if active_cluster == "little":
        p_dyn_b = 0.0; p_dyn_p = 0.0
    elif active_cluster == "big":
        p_dyn_l = 0.0; p_dyn_p = 0.0
    elif active_cluster == "prime":
        p_dyn_l = 0.0; p_dyn_b = 0.0

    # Infrastructure term — active when any cluster is under load
    cpu_active = (rho_l_m > RHO_ACTIVE_THRESHOLD or
                  rho_b_m > RHO_ACTIVE_THRESHOLD or
                  rho_p_m > RHO_ACTIVE_THRESHOLD)
    p_infra_applied = P_infra if cpu_active else 0.0

    # Per-cluster static floor — applied when cluster is a bystander
    # (rho_c < 0.05) while at least one other cluster is active
    others_active = cpu_active
    p_static_l = (P_static.get("little", 0.0)
                  if rho_l_m < 0.05 and others_active else 0.0)
    p_static_b = (P_static.get("big", 0.0)
                  if rho_b_m < 0.05 and others_active else 0.0)
    p_static_p = (P_static.get("prime", 0.0)
                  if rho_p_m < 0.05 and others_active else 0.0)
    p_static_total = p_static_l + p_static_b + p_static_p

    T_max      = df[["t_little_C", "t_big_C", "t_prime_C"]].max(axis=1).values
    T_max_mean = safe_mean(T_max)
    p_leak     = P0 * np.exp(T_max_mean / T0)

    total = (p_dyn_l + p_dyn_b + p_dyn_p
             + p_static_total
             + p_infra_applied + p_leak)
    print(f"  total:      {total:.6f} W")

    return float(total)


def compute_energy(df: pd.DataFrame, power) -> tuple:
    ts  = df["timestamp_ms"].values.astype(float)
    dt  = np.diff(ts)
    dt  = np.append(dt, dt[-1]) / 1000.0
    power_array = np.atleast_1d(power)
    return float(np.sum(power_array * dt)), dt, float(np.sum(dt))


def summarise(measured, predicted) -> dict:
    res  = measured - predicted
    rmse = float(np.sqrt(np.mean(res**2)))
    bias = float(np.mean(res))
    rel  = 100.0 * rmse / float(np.mean(measured)) if np.mean(measured) > 0 else float("nan")
    ss   = float(np.sum((measured - np.mean(measured))**2))
    r2   = float(1 - np.sum(res**2) / ss) if ss > 0 else float("nan")
    return {"rmse": rmse, "bias": bias, "rel_pct": rel, "r2": r2}


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 score_ml_inference.py <data_root> [cluster] [csv_filename]")
        sys.exit(1)

    root         = Path(sys.argv[1])
    cluster      = sys.argv[2] if len(sys.argv) > 2 else "big"
    csv_or_model = sys.argv[3] if len(sys.argv) > 3 else None

    params, P_infra, P_static = load_params(root)
    ml_dir = root / "ml_inference"

    if csv_or_model and csv_or_model.endswith(".csv"):
        csv_path   = ml_dir / "pinned" / csv_or_model
        if not csv_path.exists():
            csv_path = ml_dir / "free" / csv_or_model
        model_name = (csv_or_model
                      .replace("ml_inference_power_", "")
                      .replace(".csv", "")
                      .replace("free_", ""))
    else:
        model_name = csv_or_model if csv_or_model else "ml_inference"
        csv_path   = ml_dir / f"ml_inference_power_{cluster}.csv"

    if not csv_path.exists():
        print(f"ERROR: {csv_path} not found"); sys.exit(1)

    df        = load_csv(csv_path)
    df        = recompute_rho(df)
    df        = recompute_freq(df)

    idle      = df[df["phase"] == "ml_idle"].copy()
    inference = df[df["phase"] == "ml_inference"].copy()

    if len(inference) == 0:
        print("ERROR: no ml_inference rows found"); sys.exit(1)

    idle_cpu  = float(idle["cpu_total_W"].mean()) if len(idle) > 0 else 0.0
    idle_batt = float(idle["batt_W"].mean())      if len(idle) > 0 else 0.0

    meas       = inference["cpu_total_W"].values
    pred       = predict(inference, params, P_infra,
                         P_static=P_static, active_cluster=cluster)
    pred_array = np.full(len(inference), pred)

    E_meas, dt_s, dur = compute_energy(inference, meas)
    E_pred, _,    _   = compute_energy(inference, pred_array)
    E_batt, _,    _   = compute_energy(inference, inference["batt_W"].values)

    pm        = summarise(meas, pred_array)
    E_err_pct = 100.0 * (E_pred - E_meas) / E_meas

    print("=============per core usage===========")
    for c in range(9):
        col = f"usage_cpu{c}"
        if col in inference.columns:
            print(f"  {col}: {inference[col].mean():.2f}%")

    rho_l_avg = float(np.nanmean(inference["rho_little"].values)) if "rho_little" in inference.columns else 0.0
    rho_b_avg = float(np.nanmean(inference["rho_big"].values))    if "rho_big"    in inference.columns else 0.0
    rho_p_avg = float(np.nanmean(inference["rho_prime"].values))  if "rho_prime"  in inference.columns else 0.0
    f_l_avg   = float(np.nanmean(inference["f_little_kHz"].values)) if "f_little_kHz" in inference.columns else 0.0
    f_b_avg   = float(np.nanmean(inference["f_big_kHz"].values))    if "f_big_kHz"    in inference.columns else 0.0
    f_p_avg   = float(np.nanmean(inference["f_prime_kHz"].values))  if "f_prime_kHz"  in inference.columns else 0.0

    print(f"\n{model_name}  cluster={cluster}  n={len(inference)}  {dur:.1f}s")
    print(f"  Power   RMSE {pm['rmse']:.3f} W  "
          f"bias {pm['bias']:+.3f} W  "
          f"rel {pm['rel_pct']:.1f}%  "
          f"R² {pm['r2']:.3f}")
    print(f"Power measured {meas.mean():.3f} W  predicted {pred:.3f} W")
    print(f"  Energy  measured {E_meas:.2f} J  ({E_meas/3.6e6:.6f} kWh)  "
          f"predicted {E_pred:.2f} J  ({E_pred/3.6e6:.6f} kWh)  "
          f"error {E_err_pct:+.1f}%")
    print(f"  Battery measured {E_batt:.2f} J  ({E_batt/3.6e6:.6f} kWh)  "
          f"(idle baseline: cpu={idle_cpu:.3f} W  batt={idle_batt:.3f} W)")
    print(f"  Activity (ρ)    Little={rho_l_avg:.4f}  Big={rho_b_avg:.4f}  Prime={rho_p_avg:.4f}")
    print(f"  Mean freq (kHz) Little={f_l_avg:.0f}  Big={f_b_avg:.0f}  Prime={f_p_avg:.0f}")
    print(f"  P_infra applied: {P_infra:.4f} W")

    # ── Plot ─────────────────────────────────────────────────────────────────
    plots_dir = root / "plots"
    plots_dir.mkdir(exist_ok=True)
    t = (inference["timestamp_ms"].values -
         inference["timestamp_ms"].values[0]) / 1000.0

    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(t, np.cumsum(meas * dt_s),
            label=f"Measured ({E_meas:.2f} J)", color="#1f77b4", linewidth=1.5)
    ax.plot(t, np.cumsum(pred_array * dt_s),
            label=f"Predicted ({E_pred:.2f} J)", color="#d62728",
            linewidth=1.5, linestyle="--")
    ax.set_xlabel("Time (s)", fontsize=16)
    ax.set_ylabel("Cumulative Energy (J)", fontsize=16)
    ax.set_title(f"Cumulative CPU energy — {cluster} setting — {model_name}", fontsize=16)
    ax.tick_params(axis="both", which="major", labelsize=14)
    ax.legend(fontsize=14, loc="best")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out = plots_dir / f"ML_{model_name}_{cluster}.png"
    fig.savefig(out, dpi=150); plt.close(fig)
    print(f"  → {out}")


if __name__ == "__main__":
    main()