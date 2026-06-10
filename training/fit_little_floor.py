#!/usr/bin/env python3
"""
fit_little_floor.py — Fit Little rail static floor from phase2c_combos data.

The Little rail draws a near-constant overhead when Big or Prime are active,
even when Little cores are idle (rho_little ~ 0). This floor captures memory
bus, cache coherency, and VR overhead that lands on the Little rail as a
side effect of other clusters working.

Model addition:
    P_little_floor * 1(rho_big > 0.1 or rho_prime > 0.1)

Fitted from phase2c_combos stress rows where rho_little < 0.05.
No temperature filter — uses all stress rows and includes leakage correction.

Usage:
    python3 fit_little_floor.py <data_root>
"""

import sys
import json
import numpy as np
import pandas as pd
from pathlib import Path

def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("../data/pixel8pro")

    # Load model params
    for fname in ["composition_simple_params.json", "composition_params.json"]:
        pf = root / fname
        if pf.exists():
            with open(pf) as f:
                params = json.load(f)
            print(f"Loaded params from {fname}")
            break
    else:
        print("No params file found."); sys.exit(1)

    alphas  = params["alphas"]
    a_l     = alphas["little"]["alpha"]
    a_b     = alphas["big"]["alpha"]
    a_p     = alphas["prime"]["alpha"]
    P0      = params["leakage"]["P0"]
    T0      = params["leakage"]["T0"]

    print(f"  alpha_little={a_l:.4e}  alpha_big={a_b:.4e}  alpha_prime={a_p:.4e}")
    print(f"  P0={P0:.6f}  T0={T0:.2f}°C")

    combos_dir = root / "phase2c_combos"
    if not combos_dir.exists():
        print(f"Not found: {combos_dir}"); sys.exit(1)

    results = {}

    for csv_path in sorted(combos_dir.glob("*.csv")):
        df = pd.read_csv(csv_path, decimal=",")
        for c in df.columns:
            if c not in ["phase","config_id","workload","active_clusters"]:
                df[c] = pd.to_numeric(df[c], errors="coerce")

        phase_col = "phase" if "phase" in df.columns else "workload"
        stress = df[df[phase_col].str.contains("stress|sweep", na=False)].copy()

        if len(stress) == 0:
            print(f"\n{csv_path.name}: no stress rows"); continue

        active = stress["active_clusters"].dropna().iloc[0]

        # Temperature distribution
        T_max = stress[["t_little_C","t_big_C","t_prime_C"]].max(axis=1)
        print(f"\n{csv_path.name}  active={active}  n={len(stress)}")
        print(f"  T_max range: {T_max.min():.0f}–{T_max.max():.0f}°C  "
              f"mean={T_max.mean():.1f}°C")
        print(f"  rho: L={stress['rho_little'].mean():.3f}  "
              f"B={stress['rho_big'].mean():.3f}  "
              f"P={stress['rho_prime'].mean():.3f}")

        # Per-row dynamic prediction
        stress["p_dyn_l"] = (a_l * stress["v_little_V"]**2
                             * stress["f_little_kHz"] * 1e3
                             * stress["rho_little"])
        stress["p_dyn_b"] = (a_b * stress["v_big_V"]**2
                             * stress["f_big_kHz"] * 1e3
                             * stress["rho_big"])
        stress["p_dyn_p"] = (a_p * stress["v_prime_V"]**2
                             * stress["f_prime_kHz"] * 1e3
                             * stress["rho_prime"])

        # Leakage correction per row
        stress["p_leak"] = P0 * np.exp(T_max.values / T0)

        # Little rail residual after removing dynamic and leakage
        # residual = little_W - p_dyn_l - p_leak
        # When Little is idle, p_dyn_l ~ 0, so residual = Little floor + noise
        stress["little_residual"] = (stress["little_W"]
                                     - stress["p_dyn_l"]
                                     - stress["p_leak"])

        # Filter to rows where Little is genuinely idle
        little_idle = stress[stress["rho_little"] < 0.05].copy()
        little_active = stress[stress["rho_little"] >= 0.05].copy()

        print(f"  little_idle rows (rho_l<0.05): n={len(little_idle)}")
        print(f"  little_active rows:             n={len(little_active)}")

        if len(little_idle) > 0:
            floor_raw    = little_idle["little_W"].median()
            floor_corrected = little_idle["little_residual"].median()
            floor_std    = little_idle["little_residual"].std()

            print(f"  little_W measured (median):         {floor_raw:.4f} W")
            print(f"  p_dyn_l (median):                   "
                  f"{little_idle['p_dyn_l'].median():.4f} W")
            print(f"  p_leak  (median):                   "
                  f"{little_idle['p_leak'].median():.4f} W")
            print(f"  Little floor (leakage-corrected):   "
                  f"{floor_corrected:.4f} W  ±{floor_std:.4f}")

            # Temperature breakdown
            bins   = [0,40,50,60,70,80,90,120]
            labels = ["<40","40-50","50-60","60-70","70-80","80-90",">90"]
            T_idle = little_idle[["t_little_C","t_big_C","t_prime_C"]].max(axis=1)
            print(f"  T distribution (little_idle rows):")
            for i, lbl in enumerate(labels):
                mask = (T_idle >= bins[i]) & (T_idle < bins[i+1])
                if mask.sum() > 0:
                    sub = little_idle[mask.values]
                    print(f"    T={lbl:6s}°C: n={mask.sum():3d}  "
                          f"floor={sub['little_residual'].median():.4f}W")

            results[active] = {
                "n_idle_rows": int(len(little_idle)),
                "P_little_floor_raw_W": round(float(floor_raw), 6),
                "P_little_floor_W": round(float(floor_corrected), 6),
                "std_W": round(float(floor_std), 6),
                "T_mean": round(float(T_idle.mean()), 1),
            }
        else:
            print(f"  No rows with rho_little < 0.05")

        # Also show full residual stats for context
        total_residual = (stress["little_W"]
                          - stress["p_dyn_l"]
                          - stress["p_leak"]).median()
        print(f"  Full stress little residual (median): {total_residual:.4f} W")

    print("\n=== Little floor summary ===")
    for combo, v in results.items():
        print(f"  {combo:25s}: floor={v['P_little_floor_W']:.4f}W  "
              f"±{v['std_W']:.4f}  n={v['n_idle_rows']}  "
              f"T_mean={v['T_mean']:.0f}°C")

    if results:
        floors = [v["P_little_floor_W"] for v in results.values()]
        mean_floor = float(np.mean(floors))
        print(f"\n  Mean: {mean_floor:.4f}W")
        print(f"  Std:  {float(np.std(floors)):.4f}W")

        out = root / "little_floor_params.json"
        with open(out, "w") as f:
            json.dump({
                "description": "Little rail static floor — active when Big or Prime running",
                "formula": "P_little_floor applied when rho_big>0.1 or rho_prime>0.1",
                "note": "Leakage-corrected using fitted P0/T0 from composition_simple_params",
                "combos": results,
                "P_little_floor_W": round(mean_floor, 6),
            }, f, indent=2)
        print(f"\nWrote {out}")
    else:
        print("\nNo results — check phase2c_combos data")

if __name__ == "__main__":
    main()