#!/system/bin/sh
# phase3_asymmetric.sh - Phase 3: asymmetric rho configs, all clusters active
#
# Validation set for the composition power model. Each config pins the three
# clusters to DIFFERENT rho values so we can test that α per cluster predicts
# that cluster's contribution independently, rather than having been fit to a
# correlated symmetric sweep.
#
# Config list below: 12 combinations covering one-cluster-maxed,
# two-cluster-maxed, diagonal, and mixed loads.
#
# Usage:
#   sh phase3_asymmetric.sh
#   sh phase3_asymmetric.sh "0.3,1.0,0.5 1.0,0.3,1.0"   # override list
#
# Each config is a CSV triple "rhoL,rhoB,rhoP" separated by spaces.
#
# Env overrides:
#   DURATION_SEC=60 INTERVAL=0.5 NUM_REPS=3 TEMP_TOLERANCE=2.0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/cgroups.sh"
. "$SCRIPT_DIR/lib/freq_control.sh"
. "$SCRIPT_DIR/lib/odpm.sh"
. "$SCRIPT_DIR/lib/stress.sh"
. "$SCRIPT_DIR/lib/thermal.sh"
. "$SCRIPT_DIR/lib/measure.sh"

require_root

# --- Parse args -------------------------------------------------------------
# Each entry is rhoL,rhoB,rhoP. Chosen to cover:
#   * single-cluster-maxed (3)
#   * two-cluster-maxed    (3)
#   * diagonal gradients   (3)
#   * mixed / off-grid     (3)
DEFAULT_CONFIGS="\
1.0,0.3,0.3 \
0.3,1.0,0.3 \
0.3,0.3,1.0 \
1.0,1.0,0.3 \
1.0,0.3,1.0 \
0.3,1.0,1.0 \
0.3,0.6,0.9 \
0.9,0.6,0.3 \
0.5,1.0,0.7 \
0.7,0.4,1.0 \
0.8,0.5,0.6 \
0.4,0.8,0.5"

if [ -n "$1" ]; then
  CONFIGS="$1"
else
  CONFIGS="$DEFAULT_CONFIGS"
fi

# --- Setup ------------------------------------------------------------------
OUT_DIR="$DATA_DIR/phase3"
mkdir -p "$OUT_DIR"

NUM_CONFIGS=$(echo "$CONFIGS" | wc -w)

echo "========================================================================"
echo " PHASE 3: Asymmetric rho configs (validation set)"
echo "========================================================================"
echo "Configs:         $NUM_CONFIGS triples"
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
  cleanup_cgroups
  start_thermal_hal
  pm stay-awake false >/dev/null 2>&1 || svc power stayon false >/dev/null 2>&1 || true
}
trap cleanup_all INT TERM EXIT

detect_stress_tool
setup_cgroups
move_tasks_to_system

# All clusters online
online_all
for cluster in $CLUSTERS; do
  set_governor "$cluster" performance
done

capture_baseline_temp

# Pre-compute available freqs
LFREQS="$(list_freqs little)"
BFREQS="$(list_freqs big)"
PFREQS="$(list_freqs prime)"
MAXL=$(cluster_max_freq_khz little)
MAXB=$(cluster_max_freq_khz big)
MAXP=$(cluster_max_freq_khz prime)

# --- Sweep configs ----------------------------------------------------------
config_idx=0
for entry in $CONFIGS; do
  config_idx=$((config_idx + 1))

  rhoL=$(echo "$entry" | cut -d',' -f1)
  rhoB=$(echo "$entry" | cut -d',' -f2)
  rhoP=$(echo "$entry" | cut -d',' -f3)

  tL=$(awk -v m="$MAXL" -v r="$rhoL" 'BEGIN{printf("%d", m*r)}')
  tB=$(awk -v m="$MAXB" -v r="$rhoB" 'BEGIN{printf("%d", m*r)}')
  tP=$(awk -v m="$MAXP" -v r="$rhoP" 'BEGIN{printf("%d", m*r)}')

  fL=$(snap_to_freq "$tL" $LFREQS)
  fB=$(snap_to_freq "$tB" $BFREQS)
  fP=$(snap_to_freq "$tP" $PFREQS)

  aL=$(awk -v f="$fL" -v m="$MAXL" 'BEGIN{printf("%.3f", f/m)}')
  aB=$(awk -v f="$fB" -v m="$MAXB" 'BEGIN{printf("%.3f", f/m)}')
  aP=$(awk -v f="$fP" -v m="$MAXP" 'BEGIN{printf("%.3f", f/m)}')

  # Config IDs include target rhos so validate.py can parse them if needed
  config_id="asym_${config_idx}_L${rhoL}_B${rhoB}_P${rhoP}"

  echo ""
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃  [${config_idx}/${NUM_CONFIGS}] ${config_id}"
  echo "┃   little=${fL}kHz(ρ=${aL})  big=${fB}kHz(ρ=${aB})  prime=${fP}kHz(ρ=${aP})"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"

  rep=1
  while [ "$rep" -le "$NUM_REPS" ]; do
    online_all
    pin_frequency little "$fL"
    pin_frequency big    "$fB"
    pin_frequency prime  "$fP"
    sleep 0.5
    verify_frequency little "$fL" || log_warn "little drift"
    verify_frequency big    "$fB" || log_warn "big drift"
    verify_frequency prime  "$fP" || log_warn "prime drift"

    wait_for_target_temp "before ${config_id} rep${rep}" || true

    online_all
    pin_frequency little "$fL"
    pin_frequency big    "$fB"
    pin_frequency prime  "$fP"
    sleep 0.5

    csv="$OUT_DIR/${config_id}_rep${rep}.csv"
    write_csv_header "$csv"

    # --- IDLE ---
    sleep 2
    sample_loop "combined_idle" "$config_id" "$rep" "idle" "little+big+prime" \
                "$fL" "$fB" "$fP" "$csv"

    # --- STRESS ---
    pids=$(start_stress_on_cpus "$ALL_CORES")
    log_info "Stress started on all cores: pids=$pids"
    sleep 2

    sample_loop "combined_stress" "$config_id" "$rep" "stress" "little+big+prime" \
                "$fL" "$fB" "$fP" "$csv"

    stop_stress
    filter_csv_quality "$csv"
    log_ok "Finished rep $rep of $NUM_REPS for $config_id"
    rep=$((rep + 1))
  done
done

echo ""
echo "========================================================================"
echo " PHASE 3 COMPLETE"
echo "========================================================================"
echo "CSV files in: $OUT_DIR"
ls -1 "$OUT_DIR"