#!/usr/bin/env python3
"""
evaluate_full_model.py — Evaluate the full four-term model on held-out data.
"""

import sys
import json
import argparse
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.model_selection import StratifiedShuffleSplit

FEATURE_COLS = ["V_little", "V_big", "V_prime",
                "f_little", "f_big", "f_prime",
                "T_little", "T_big", "T_prime",
                "rho_little", "rho_big", "rho_prime",
                "measured_W", "source", "lambda_val"]
TRAIN_FRAC   = 0.80
T_PHASE2_MAX = 55.0
RHO_TH_ACT   = 0.10
RHO_TH_BYS   = 0.05


def _normalise(df):
    # Use actual per-core frequencies (freq_cpu*) for throttle detection,
    # not the static policy target (f_*_kHz).
    # On G3: prime=cpu8, on G4: prime=cpu7.
    prime_freq = "freq_cpu8" if "freq_cpu8" in df.columns else "freq_cpu7"
    df = df.rename(columns={
        "v_little_V":   "V_little",  "v_big_V":   "V_big",  "v_prime_V":   "V_prime",
        "freq_cpu0":    "f_little",  "freq_cpu4":  "f_big",  prime_freq:    "f_prime",
        "t_little_C":   "T_little",  "t_big_C":   "T_big",  "t_prime_C":   "T_prime",
    })
    return df


def _coerce(df):
    num_cols = ["cpu_total_W",
                "f_little_kHz", "f_big_kHz", "f_prime_kHz",
                "freq_cpu0", "freq_cpu1", "freq_cpu2", "freq_cpu3",
                "freq_cpu4", "freq_cpu5", "freq_cpu6", "freq_cpu7", "freq_cpu8",
                "v_little_V", "v_big_V", "v_prime_V",
                "t_little_C", "t_big_C", "t_prime_C",
                "rho_little", "rho_big", "rho_prime"]
    for c in num_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def _split_pre_post(stress):
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


def load_phase2(root):
    phase2_dir = root / "phase2"
    if not phase2_dir.exists():
        return pd.DataFrame(columns=FEATURE_COLS)
    dfs = []
    for csv in sorted(phase2_dir.glob("*.csv")):
        df = pd.read_csv(csv, sep=None, engine="python", decimal=",")
        dfs.append(df)
    if not dfs:
        return pd.DataFrame(columns=FEATURE_COLS)
    raw = pd.concat(dfs, ignore_index=True)
    raw = _coerce(raw)
    stress = raw[raw["workload"] == "stress"].copy() if "workload" in raw.columns else raw.copy()
    stress = _normalise(stress.reset_index(drop=True))
    stress["measured_W"] = stress["cpu_total_W"]
    stress["source"]     = "phase2"
    stress["lambda_val"] = 1.0
    stress["T_max"] = stress[["T_little", "T_big", "T_prime"]].max(axis=1)
    stress = stress[stress["T_max"] < T_PHASE2_MAX].copy()
    return stress[FEATURE_COLS].dropna().reset_index(drop=True)


def load_thermal_sweeps(root):
    thermal_dir = root / "phase2b_thermal"
    pre_dfs, post_dfs = [], []
    for csv in sorted(thermal_dir.glob("thermal_rho_*.csv")):
        parts = csv.stem.split("_")
        lam = float(parts[parts.index("rho") + 1])
        df = pd.read_csv(csv, sep=None, engine="python", decimal=",")
        df = _coerce(df)
        phase_col = "phase" if "phase" in df.columns else "workload"
        stress = df[df[phase_col].str.contains("stress|sweep", na=False)].copy().reset_index(drop=True)
        if len(stress) == 0:
            continue
        stress = _normalise(stress)
        stress["measured_W"] = stress["cpu_total_W"]
        stress["lambda_val"] = lam
        pre, post = _split_pre_post(stress)
        pre["source"]  = f"thermal_pre_lam{lam:.2f}"
        post["source"] = f"thermal_post_lam{lam:.2f}"
        pre_c  = pre[FEATURE_COLS].dropna()
        post_c = post[FEATURE_COLS].dropna()
        if len(pre_c)  > 0: pre_dfs.append(pre_c)
        if len(post_c) > 0: post_dfs.append(post_c)
    pre_all  = pd.concat(pre_dfs,  ignore_index=True) if pre_dfs  else pd.DataFrame(columns=FEATURE_COLS)
    post_all = pd.concat(post_dfs, ignore_index=True) if post_dfs else pd.DataFrame(columns=FEATURE_COLS)
    return pre_all, post_all


def stratified_split(df, train_frac, seed):
    strata = df["lambda_val"].round(2).astype(str).values
    sss = StratifiedShuffleSplit(n_splits=1, test_size=1.0 - train_frac, random_state=seed)
    train_idx, test_idx = next(sss.split(df, strata))
    return df.iloc[train_idx].copy(), df.iloc[test_idx].copy()


def predict_full(df, alphas, P0, T0, kappa_infra, kappa_floor):
    a_l = alphas["little"]["alpha"]
    a_b = alphas["big"]["alpha"]
    a_p = alphas["prime"]["alpha"]

    p_dyn = (
        a_l * df["V_little"].values**2 * df["f_little"].values * 1e3 * df["rho_little"].values
      + a_b * df["V_big"].values**2    * df["f_big"].values    * 1e3 * df["rho_big"].values
      + a_p * df["V_prime"].values**2  * df["f_prime"].values  * 1e3 * df["rho_prime"].values
    )
    T_max  = df[["T_little", "T_big", "T_prime"]].max(axis=1).values
    p_leak = P0 * np.exp(T_max / T0)

    rho_L     = df["rho_little"].values
    rho_B     = df["rho_big"].values
    rho_P     = df["rho_prime"].values
    delta_act = ((rho_L > RHO_TH_ACT) | (rho_B > RHO_TH_ACT) | (rho_P > RHO_TH_ACT)).astype(float)
    p_infra   = kappa_infra * delta_act

    p_floor = np.zeros(len(df))
    for cluster, rho_c in [("little", rho_L), ("big", rho_B), ("prime", rho_P)]:
        if cluster in kappa_floor:
            delta_bys = ((rho_c < RHO_TH_BYS) & (delta_act > 0)).astype(float)
            p_floor  += kappa_floor[cluster] * delta_bys

    return p_dyn + p_leak + p_infra + p_floor


def metrics(measured, predicted):
    res    = measured - predicted
    rmse   = float(np.sqrt(np.mean(res**2)))
    bias   = float(np.mean(res))
    rel    = 100.0 * rmse / measured.mean() if measured.mean() > 0 else float("nan")
    ss_res = float(np.sum(res**2))
    ss_tot = float(np.sum((measured - measured.mean())**2))
    r2     = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    return {
        "rmse": rmse, "bias": bias, "rel": rel, "r2": r2,
        "n": len(measured),
        "mean_meas": float(measured.mean()),
        "mean_pred": float(predicted.mean()),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data_root")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    root = Path(args.data_root)

    with open(root / "composition_simple_params.json") as f:
        comp = json.load(f)
    alphas = comp["alphas"]
    P0 = comp["leakage"]["P0"]
    T0 = comp["leakage"]["T0"]

    with open(root / "combo_infra_params.json") as f:
        infra_params = json.load(f)
    infra_vals = [v["P_infra_at_inference_W"] for v in infra_params["combos"].values()
                  if np.isfinite(v.get("P_infra_at_inference_W", float("nan")))]
    kappa_infra = float(np.median(infra_vals))

    with open(root / "static_floor_params.json") as f:
        static_params = json.load(f)
    kappa_floor = {
        cl: v["P_static_at_inference_W"]
        for cl, v in static_params["P_static"].items()
    }

    print("Loaded parameters:")
    print(f"  alpha_little = {alphas['little']['alpha']:.4e}")
    print(f"  alpha_big    = {alphas['big']['alpha']:.4e}")
    print(f"  alpha_prime  = {alphas['prime']['alpha']:.4e}")
    print(f"  P0           = {P0:.6f} W")
    print(f"  T0           = {T0:.2f} C")
    print(f"  kappa_infra  = {kappa_infra:.4f} W  (median across {len(infra_vals)} combos)")
    print(f"  kappa_floor  = {kappa_floor}")

    p2 = load_phase2(root)
    pre_all, post_all = load_thermal_sweeps(root)
    pre_train, pre_test = stratified_split(pre_all, TRAIN_FRAC, args.seed)
    train = pd.concat([p2, pre_train], ignore_index=True)
    test  = pre_test.copy()

    print(f"Split (seed={args.seed}):")
    print(f"  Train:  {len(train)} rows")
    print(f"  Test:   {len(test)} rows")
    print(f"  Stress: {len(post_all)} rows")

    print("=== Full four-term model performance ===")
    hdr = f"  {'Set':<8} {'n':>4}  {'RMSE (W)':>9}  {'Rel (%)':>8}  {'Bias (W)':>9}  {'R2':>7}  {'Mean meas':>10}"
    print(hdr)
    print(f"  {'-'*70}")
    for label, df in [("Train", train), ("Test", test), ("Stress", post_all)]:
        if len(df) == 0:
            continue
        pred = predict_full(df, alphas, P0, T0, kappa_infra, kappa_floor)
        m = metrics(df["measured_W"].values, pred)
        print(f"  {label:<8} {m['n']:>4}  "
              f"{m['rmse']:>9.4f}  "
              f"{m['rel']:>7.1f}%  "
              f"{m['bias']:>+9.4f}  "
              f"{m['r2']:>7.4f}  "
              f"{m['mean_meas']:>10.4f} W")


if __name__ == "__main__":
    main()