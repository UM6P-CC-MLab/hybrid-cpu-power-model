#!/system/bin/sh
# phase2b_thermal_sweep.sh - Continuous thermal sweep at fixed frequency.
#
# Holds all three clusters at a fixed configuration and logs telemetry
# continuously while the chip heats up from baseline to thermal steady-state.
# Unlike phase2/phase3, this does NOT reset temperature between samples and
# does NOT average — every sample is a row in the output CSV.
#
# Purpose: get hundreds of (T, P, V) samples at fixed (f_L, f_B, f_P) so the
# leakage term P_leak(T) can be fit independently of frequency/voltage effects.
#
# Sampling matches ml_inference_merged.sh exactly:
#   - /proc/stat snapshot before and after each sleep interval
#   - utilization computed over the actual sleep window (not from pinned freq)
#   - actual current frequency logged per sample (captures throttling)
#   - idle baseline at 10% of sweep duration, minimum 60s
#
# Default: one run at rho=1.0 (max load, fastest heating).
# Optional: pass a list of rho values to run multiple sweeps.
#
# Usage:
#   sh phase2b_thermal_sweep.sh                    # rho=1.0 only
#   sh phase2b_thermal_sweep.sh "1.0,0.8,0.6"      # multiple sweeps
#
# Env overrides:
#   SWEEP_DURATION_SEC=900   total continuous logging time per rho
#   SWEEP_INTERVAL=0.5       seconds between samples
#   SWEEP_NUM_REPS=1         repetitions per rho
#   SWEEP_COOLDOWN_SEC=120   wait between reps/rho values for full cooldown

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/cgroups.sh"
. "$SCRIPT_DIR/lib/freq_control.sh"
. "$SCRIPT_DIR/lib/odpm.sh"
. "$SCRIPT_DIR/lib/stress.sh"
. "$SCRIPT_DIR/lib/thermal.sh"
. "$SCRIPT_DIR/lib/measure.sh"

require_root

# ============================================================================
# Arguments
# ============================================================================
# Default rhos resolved after cluster max freqs are known (see below)
SWEEP_DURATION_SEC="${SWEEP_DURATION_SEC:-900}"
SWEEP_INTERVAL="${SWEEP_INTERVAL:-0.5}"
SWEEP_NUM_REPS="${SWEEP_NUM_REPS:-1}"
SWEEP_COOLDOWN_SEC="${SWEEP_COOLDOWN_SEC:-120}"

# RHOS is set from argument if provided; otherwise set below after
# cluster max frequencies are known (rho_min requires MAXL).
if [ -n "$1" ]; then
    RHOS=$(echo "$1" | tr ',' ' ')
fi

# Idle baseline = 10% of sweep duration, minimum 60s
IDLE_SEC=$(awk -v d="$SWEEP_DURATION_SEC" \
    'BEGIN{x=int(d*0.10); print (x<60)?60:x}')

EXPECTED_SAMPLES=$(awk -v d="$SWEEP_DURATION_SEC" -v i="$SWEEP_INTERVAL" \
    'BEGIN{printf("%d", d/i)}')

# ============================================================================
# Setup
# ============================================================================
OUT_DIR="$DATA_DIR/phase2b_thermal"
mkdir -p "$OUT_DIR"

ALL_CORES="0 1 2 3 4 5 6 7 8"
LITTLE_CORES="0 1 2 3"
BIG_CORES="4 5 6 7"
PRIME_CORES="8"

echo "========================================================================"
echo " PHASE 2b: Continuous thermal sweep (fixed freq, T varies)"
echo "========================================================================"
echo "Rho values:        $RHOS"
echo "Sweep duration:    ${SWEEP_DURATION_SEC}s @ ${SWEEP_INTERVAL}s interval"
echo "Idle baseline:     ${IDLE_SEC}s (10% of sweep, min 60s)"
echo "Expected samples:  ~${EXPECTED_SAMPLES} per rep"
echo "Repetitions:       $SWEEP_NUM_REPS"
echo "Cooldown between:  ${SWEEP_COOLDOWN_SEC}s"
echo "Output:            $OUT_DIR"
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

# Compute rho_min from actual minimum frequency of Little cluster.
# If no argument was passed, default sweep is: rho_min, 0.50, 1.0
# These three points span low/mid/max frequency for leakage independence validation.
MINL=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq 2>/dev/null || echo 324000)
RHO_MIN=$(awk -v mn="$MINL" -v mx="$MAXL" 'BEGIN{printf("%.2f", mn/mx)}')

if [ -z "$1" ]; then
    RHOS="$RHO_MIN 0.50 1.0"
    log_info "Default rho sweep: rho_min=${RHO_MIN}  0.50  1.0"
fi

# ============================================================================
# CSV header
# ============================================================================
write_thermal_header() {
    csv="$1"
    {
        printf "phase,config_id,rep,workload,active_clusters,"
        printf "f_little_kHz,f_big_kHz,f_prime_kHz,"
        printf "rho_little,rho_big,rho_prime,"
        printf "timestamp_ms,"
        printf "cpu_total_W,little_W,big_W,prime_W,little_main_W,little_mem_W,"
        printf "ram_W,system_W,batt_W,"
        printf "v_little_V,v_big_V,v_prime_V,batt_V,"
        printf "ram_mA,system_mA,batt_mA,"
        printf "t_little_C,t_big_C,t_prime_C,t_batt_C"
        for c in $ALL_CORES; do printf ",freq_cpu%s" "$c"; done
        for c in $ALL_CORES; do printf ",usage_cpu%s" "$c"; done
        printf "\n"
    } > "$csv"
}

# ============================================================================
# read_ram_power_uw — consistent with merged script
# ============================================================================
read_ram_power_uw() {
    grep "S1M_VDD_MIF" "$ODPM_MAIN/lpf_power" 2>/dev/null \
        | awk -F', ' '{print $2+0; exit}' || echo 0
}

read_batt_power_w() {
    uv=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)
    ua=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)
    case "$ua" in -*) ua="${ua#-}";; esac
    awk -v v="$uv" -v i="$ua" 'BEGIN{printf("%.6f", (v*i)/1e12)}'
}

read_batt_voltage_v() {
    uv=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)
    awk -v x="$uv" 'BEGIN{printf("%.3f", x/1e6)}'
}

read_batt_current_ma() {
    ua=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)
    case "$ua" in -*) ua="${ua#-}";; esac
    awk -v x="$ua" 'BEGIN{printf("%.1f", x/1000)}'
}

read_batt_temp_c() {
    t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0)
    awk -v x="$t" 'BEGIN{printf("%.1f", x/10)}'
}

# ============================================================================
# sample_one_row — inline sampling matching ml_inference_merged.sh exactly.
#
# Arguments:
#   $1  phase label        (e.g. thermal_sweep or thermal_idle)
#   $2  config_id          (e.g. thermal_rho_1.0)
#   $3  rep
#   $4  workload           (stress or idle)
#   $5  fL_pin             pinned little freq (kHz) — used as fallback only
#   $6  fB_pin             pinned big freq (kHz)
#   $7  fP_pin             pinned prime freq (kHz)
#   $8  csv path
#   $9  STAT_BEFORE        /proc/stat snapshot before sleep
#   $10 STAT_AFTER         /proc/stat snapshot after sleep
# ============================================================================
sample_one_row() {
    _phase="$1"
    _config="$2"
    _rep="$3"
    _workload="$4"
    _fL_pin="$5"
    _fB_pin="$6"
    _fP_pin="$7"
    _csv="$8"
    _stat_b="$9"
    _stat_a="${10}"

    TS=$(now_ms)

    # ODPM power reads
    POWERS=$(read_all_cluster_powers_uw)
    L_uw=$(echo "$POWERS"    | awk '{print $1}')
    B_uw=$(echo "$POWERS"    | awk '{print $2}')
    P_uw=$(echo "$POWERS"    | awk '{print $3}')
    T_uw=$(echo "$POWERS"    | awk '{print $4}')
    Lmain_uw=$(echo "$POWERS" | awk '{print $5}')
    Lmem_uw=$(echo "$POWERS"  | awk '{print $6}')
    RAM_uw=$(read_ram_power_uw)

    # Voltage reads
    VOLTS=$(read_all_cluster_voltages_uv)
    VL_uv=$(echo "$VOLTS" | awk '{print $1}')
    VB_uv=$(echo "$VOLTS" | awk '{print $2}')
    VP_uv=$(echo "$VOLTS" | awk '{print $3}')

    # Temperature reads
    TL=$(read_cluster_temp little)
    TB=$(read_cluster_temp big)
    TP=$(read_cluster_temp prime)

    # Actual current frequency per policy — captures throttling
    fL_cur=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq \
             2>/dev/null || echo "$_fL_pin")
    fB_cur=$(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq \
             2>/dev/null || echo "$_fB_pin")
    fP_cur=$(cat /sys/devices/system/cpu/cpufreq/policy8/scaling_cur_freq \
             2>/dev/null || echo "$_fP_pin")

    # Battery
    BV=$(read_batt_voltage_v)
    BI=$(read_batt_current_ma)
    BP=$(read_batt_power_w)
    TBat=$(read_batt_temp_c)

    RAM_mA=$(grep "S1M_VDD_MIF" "$ODPM_MAIN/lpf_current" 2>/dev/null \
        | awk -F', ' '{printf("%.1f", $2); exit}' || echo 0.0)

    # Convert power uW -> W in one awk call
    POWERS_W=$(awk -v l="$L_uw" -v b="$B_uw" -v p="$P_uw" -v t="$T_uw" \
                   -v lm="$Lmain_uw" -v lme="$Lmem_uw" -v ra="$RAM_uw" \
        'BEGIN{printf("%.6f %.6f %.6f %.6f %.6f %.6f %.6f",
            l/1e6, b/1e6, p/1e6, t/1e6, lm/1e6, lme/1e6, ra/1e6)}')
    l_W=$(echo "$POWERS_W"    | awk '{print $1}')
    b_W=$(echo "$POWERS_W"    | awk '{print $2}')
    p_W=$(echo "$POWERS_W"    | awk '{print $3}')
    cpu_W=$(echo "$POWERS_W"  | awk '{print $4}')
    lmn_W=$(echo "$POWERS_W"  | awk '{print $5}')
    lmem_W=$(echo "$POWERS_W" | awk '{print $6}')
    ram_W=$(echo "$POWERS_W"  | awk '{print $7}')

    VOLTAGES_V=$(awk -v vl="$VL_uv" -v vb="$VB_uv" -v vp="$VP_uv" \
        'BEGIN{printf("%.3f %.3f %.3f", vl/1e6, vb/1e6, vp/1e6)}')
    vL=$(echo "$VOLTAGES_V" | awk '{print $1}')
    vB=$(echo "$VOLTAGES_V" | awk '{print $2}')
    vP=$(echo "$VOLTAGES_V" | awk '{print $3}')

    # Per-core frequencies (read actual, not pinned — shows throttling)
    CPU_FREQS=""
    for c in $ALL_CORES; do
        onl="/sys/devices/system/cpu/cpu${c}/online"
        if [ "$c" != "0" ] && [ -r "$onl" ] && \
           [ "$(cat "$onl" 2>/dev/null)" != "1" ]; then
            CPU_FREQS="$CPU_FREQS offline"
        else
            f_cur=$(cat /sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq \
                    2>/dev/null || echo "offline")
            CPU_FREQS="$CPU_FREQS $f_cur"
        fi
    done

    # Per-core utilization from /proc/stat snapshots (over actual sleep window)
    CPU_USAGES=""
    for c in $ALL_CORES; do
        u=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk -v core="cpu${c}" '
            $1==core && !seen {
                idle1=$5; total1=$2+$3+$4+$5+$6+$7+$8+$9; seen=1; next
            }
            $1==core && seen {
                idle2=$5; total2=$2+$3+$4+$5+$6+$7+$8+$9
                dt=total2-total1; di=idle2-idle1
                if(dt>0) printf("%.1f",(1.0-di/dt)*100.0)
                else print "0.0"; exit
            }
            END { if(!seen) print "0.0" }')
        CPU_USAGES="$CPU_USAGES $u"
    done

    # Cluster-level rho from per-core stat snapshots
    rho_L=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk '
        /^cpu[0-3] / {
            if(!seen[$1]++){idle1[$1]=$5; tot1[$1]=$2+$3+$4+$5+$6+$7+$8+$9}
            else {
                dt=($2+$3+$4+$5+$6+$7+$8+$9)-tot1[$1]
                di=$5-idle1[$1]
                if(dt>0){s+=100*(1-di/dt); n++}
            }
        }
        END{if(n>0) printf("%.4f",s/n/100); else print "0.0000"}')

    rho_B=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk '
        /^cpu[4-7] / {
            if(!seen[$1]++){idle1[$1]=$5; tot1[$1]=$2+$3+$4+$5+$6+$7+$8+$9}
            else {
                dt=($2+$3+$4+$5+$6+$7+$8+$9)-tot1[$1]
                di=$5-idle1[$1]
                if(dt>0){s+=100*(1-di/dt); n++}
            }
        }
        END{if(n>0) printf("%.4f",s/n/100); else print "0.0000"}')

    rho_P=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk '
        /^cpu8 / {
            if(!seen++){idle1=$5; tot1=$2+$3+$4+$5+$6+$7+$8+$9}
            else {
                dt=($2+$3+$4+$5+$6+$7+$8+$9)-tot1
                di=$5-idle1
                if(dt>0) printf("%.4f",(1-di/dt))
                else print "0.0000"; exit
            }
        }
        END{if(!seen) print "0.0000"}')

    # Write row
    {
        printf "%s,%s,%s,%s,%s," \
               "$_phase" "$_config" "$_rep" "$_workload" "little+big+prime"
        printf "%s,%s,%s,"   "$fL_cur" "$fB_cur" "$fP_cur"
        printf "%s,%s,%s,"   "$rho_L"  "$rho_B"  "$rho_P"
        printf "%s,"         "$TS"
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s," \
               "$cpu_W" "$l_W" "$b_W" "$p_W" "$lmn_W" "$lmem_W" \
               "$ram_W" "0.000000" "$BP"
        printf "%s,%s,%s,%s," "$vL" "$vB" "$vP" "$BV"
        printf "%s,%s,%s,"    "$RAM_mA" "0.0" "$BI"
        printf "%s,%s,%s,%s"  "$TL" "$TB" "$TP" "$TBat"
        for freq  in $CPU_FREQS;  do printf ",%s" "$freq";  done
        for usage in $CPU_USAGES; do printf ",%s" "$usage"; done
        printf "\n"
    } >> "$_csv"
}

# ============================================================================
# Main sweep loop
# ============================================================================
for rho in $RHOS; do
    tL=$(awk -v m="$MAXL" -v r="$rho" 'BEGIN{printf("%d", m*r)}')
    tB=$(awk -v m="$MAXB" -v r="$rho" 'BEGIN{printf("%d", m*r)}')
    tP=$(awk -v m="$MAXP" -v r="$rho" 'BEGIN{printf("%d", m*r)}')

    fL=$(snap_to_freq "$tL" $LFREQS)
    fB=$(snap_to_freq "$tB" $BFREQS)
    fP=$(snap_to_freq "$tP" $PFREQS)

    aL=$(awk -v f="$fL" -v m="$MAXL" 'BEGIN{printf("%.3f", f/m)}')
    aB=$(awk -v f="$fB" -v m="$MAXB" 'BEGIN{printf("%.3f", f/m)}')
    aP=$(awk -v f="$fP" -v m="$MAXP" 'BEGIN{printf("%.3f", f/m)}')

    config_id="thermal_rho_${rho}"

    echo ""
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  ${config_id}"
    echo "┃  little=${fL}kHz(ρ=${aL})  big=${fB}kHz(ρ=${aB})  prime=${fP}kHz(ρ=${aP})"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"

    rep=1
    while [ "$rep" -le "$SWEEP_NUM_REPS" ]; do
        online_all
        pin_frequency little "$fL"
        pin_frequency big    "$fB"
        pin_frequency prime  "$fP"
        sleep 0.5
        verify_frequency little "$fL" || log_warn "little drift"
        verify_frequency big    "$fB" || log_warn "big drift"
        verify_frequency prime  "$fP" || log_warn "prime drift"

        # Cool down completely so each sweep starts from a cold baseline
        log_info "Cooling down to baseline temperature before sweep..."
        wait_for_target_temp "before ${config_id} rep${rep}" || true

        # Re-pin after cooldown
        online_all
        pin_frequency little "$fL"
        pin_frequency big    "$fB"
        pin_frequency prime  "$fP"
        sleep 0.5

        csv="$OUT_DIR/${config_id}_rep${rep}.csv"
        write_thermal_header "$csv"

        # ── Phase 1: Idle baseline ─────────────────────────────────────────
        log_info "Recording idle baseline (${IDLE_SEC}s)..."
        n=0
        END_MS=$(( $(now_ms) + IDLE_SEC * 1000 ))
        while [ "$(now_ms)" -lt "$END_MS" ]; do
            STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
            sleep "$SWEEP_INTERVAL"
            STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
            sample_one_row "thermal_idle" "$config_id" "$rep" "idle" \
                           "$fL" "$fB" "$fP" "$csv" \
                           "$STAT_BEFORE" "$STAT_AFTER"
            n=$(( n + 1 ))
        done
        log_ok "Idle baseline: $n samples"

        # ── Phase 2: Continuous stress sweep ──────────────────────────────
        log_info "Starting stress and continuous logging for ${SWEEP_DURATION_SEC}s..."
        pids=$(start_stress_on_cpus "$ALL_CORES")
        log_info "Stress started on all cores: pids=$pids"

        n=0
        END_MS=$(( $(now_ms) + SWEEP_DURATION_SEC * 1000 ))
        while [ "$(now_ms)" -lt "$END_MS" ]; do
            STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
            sleep "$SWEEP_INTERVAL"
            STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
            sample_one_row "thermal_sweep" "$config_id" "$rep" "stress" \
                           "$fL" "$fB" "$fP" "$csv" \
                           "$STAT_BEFORE" "$STAT_AFTER"
            n=$(( n + 1 ))
        done
        log_ok "Stress sweep: $n samples"

        stop_stress
        log_ok "Finished rep $rep / $SWEEP_NUM_REPS for $config_id"
        log_ok "CSV: $csv  ($(wc -l < "$csv") rows)"

        # Cooldown between reps and between rho values
        num_rhos=$(echo "$RHOS" | wc -w)
        if [ "$rep" -lt "$SWEEP_NUM_REPS" ] || [ "$num_rhos" -gt 1 ]; then
            log_info "Cooldown ${SWEEP_COOLDOWN_SEC}s before next run..."
            sleep "$SWEEP_COOLDOWN_SEC"
        fi

        rep=$(( rep + 1 ))
    done
done

echo ""
echo "========================================================================"
echo " PHASE 2b COMPLETE"
echo "========================================================================"
echo "CSV files in: $OUT_DIR"
ls -1 "$OUT_DIR"