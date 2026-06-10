#!/system/bin/sh
# phase3_validation.sh - Phase 3: asymmetric (rho_L, rho_B, rho_P) configurations
#
# Used to validate that a model fit on Phase 2 (symmetric) data generalizes
# to asymmetric cases. If predictions on these configs are poor, the model
# likely needs per-cluster throttle weights, not a single tau.
#
# Usage:
#   sh phase3_validation.sh [config1 config2 ...]
#
# Each config is a comma-separated triple: rho_little,rho_big,rho_prime
# e.g. "0.3,0.9,0.9"
#
# Default configs probe asymmetries that symmetric sweep missed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/freq_control.sh"
. "$SCRIPT_DIR/lib/odpm.sh"
. "$SCRIPT_DIR/lib/stress.sh"
. "$SCRIPT_DIR/lib/thermal.sh"
. "$SCRIPT_DIR/lib/measure.sh"

require_root

# --- Default asymmetric configs --------------------------------------------
# Each line: rho_L  rho_B  rho_P
# Rationale:
#   (0.3, 0.9, 0.9)  -> little relaxed, big+prime stressed: does prime throttle more when little is idle?
#   (0.9, 0.9, 0.3)  -> prime relaxed, big+little stressed: no prime means lots of headroom?
#   (1.0, 0.3, 1.0)  -> big relaxed, extremes at max
#   (0.5, 1.0, 0.2)  -> only big pushed hard
#   (1.0, 1.0, 1.0)  -> sanity: should match phase2 rho=1.0
DEFAULT_CONFIGS="0.3,0.9,0.9 0.9,0.9,0.3 1.0,0.3,1.0 0.5,1.0,0.2 1.0,1.0,1.0"

if [ $# -gt 0 ]; then
  CONFIGS="$*"
else
  CONFIGS="$DEFAULT_CONFIGS"
fi

# --- Setup ------------------------------------------------------------------
OUT_DIR="$DATA_DIR/phase3"
mkdir -p "$OUT_DIR"

echo "========================================================================"
echo " PHASE 3: Asymmetric validation configs"
echo "========================================================================"
echo "Configs:         $CONFIGS"
echo "Duration/sample: ${DURATION_SEC}s @ ${INTERVAL}s interval"
echo "Repetitions:     $NUM_REPS"
echo "Temp tolerance:  ±${TEMP_TOLERANCE}°C"
echo "Output:          $OUT_DIR"
echo "========================================================================"

pm stay-awake true >/dev/null 2>&1 || svc power stayon true >/dev/null 2>&1 || true

stop_thermal_hal

cleanup_all() {
  log_info "Cleanup: stopping stress, onlining all, restoring thermal HAL"
  stop_stress
  online_all
  for cluster in $CLUSTERS; do
    set_governor "$cluster" performance 2>/dev/null || true
  done
  start_thermal_hal
  pm stay-awake false >/dev/null 2>&1 || svc power stayon false >/dev/null 2>&1 || true
}
trap cleanup_all INT TERM EXIT

detect_stress_tool

online_all
for cluster in $CLUSTERS; do
  set_governor "$cluster" performance
done

capture_baseline_temp

LFREQS="$(list_freqs little)"
BFREQS="$(list_freqs big)"
PFREQS="$(list_freqs prime)"
MAXL=$(cluster_max_freq_khz little)
MAXB=$(cluster_max_freq_khz big)
MAXP=$(cluster_max_freq_khz prime)

# --- Run each config --------------------------------------------------------
for triple in $CONFIGS; do
  rL=$(echo "$triple" | cut -d, -f1)
  rB=$(echo "$triple" | cut -d, -f2)
  rP=$(echo "$triple" | cut -d, -f3)

  tL=$(awk -v m="$MAXL" -v r="$rL" 'BEGIN{printf("%d", m*r)}')
  tB=$(awk -v m="$MAXB" -v r="$rB" 'BEGIN{printf("%d", m*r)}')
  tP=$(awk -v m="$MAXP" -v r="$rP" 'BEGIN{printf("%d", m*r)}')

  fL=$(snap_to_freq "$tL" $LFREQS)
  fB=$(snap_to_freq "$tB" $BFREQS)
  fP=$(snap_to_freq "$tP" $PFREQS)

  aL=$(awk -v f="$fL" -v m="$MAXL" 'BEGIN{printf("%.3f", f/m)}')
  aB=$(awk -v f="$fB" -v m="$MAXB" 'BEGIN{printf("%.3f", f/m)}')
  aP=$(awk -v f="$fP" -v m="$MAXP" 'BEGIN{printf("%.3f", f/m)}')

  # Config ID safe for filenames
  config_id="asym_L${rL}_B${rB}_P${rP}"

  echo ""
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  $config_id  little=${fL}kHz(ρ=${aL})  big=${fB}kHz(ρ=${aB})  prime=${fP}kHz(ρ=${aP})"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"

  rep=1
  while [ "$rep" -le "$NUM_REPS" ]; do
    online_all
    pin_frequency little "$fL"
    pin_frequency big    "$fB"
    pin_frequency prime  "$fP"
    sleep 0.5

    wait_for_target_temp "before ${config_id} rep${rep}" || true

    online_all
    pin_frequency little "$fL"
    pin_frequency big    "$fB"
    pin_frequency prime  "$fP"
    sleep 0.5

    csv="$OUT_DIR/${config_id}_rep${rep}.csv"
    write_csv_header "$csv"

    # --- IDLE MEASUREMENT ---
    sleep 2
    sample_loop "validation_idle" "$config_id" "$rep" "idle" "little,big,prime" \
                "$fL" "$fB" "$fP" "$csv"

    # --- STRESS MEASUREMENT ---
    pids=$(start_stress_on_cpus "$ALL_CORES")
    log_info "Stress started: pids=$pids"
    sleep 2

    sample_loop "validation_stress" "$config_id" "$rep" "stress" "little,big,prime" \
                "$fL" "$fB" "$fP" "$csv"

    stop_stress
    log_ok "Finished rep $rep of $NUM_REPS for $config_id (idle+stress)"
    rep=$((rep + 1))
  done
done

echo ""
echo "========================================================================"
echo " PHASE 3 COMPLETE"
echo "========================================================================"
echo "CSV files in: $OUT_DIR"
ls -1 "$OUT_DIR"