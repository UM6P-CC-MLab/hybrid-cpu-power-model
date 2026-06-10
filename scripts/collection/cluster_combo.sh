#!/system/bin/sh
# phase2c_cluster_combos.sh - Thermal sweep across cluster combinations.
#
# Runs stress on specific subsets of clusters while keeping bystander clusters
# ONLINE at min frequency (not offlined). This enables measurement of the
# per-cluster static floor P_static_c for all three clusters.
#
# Supports both Tensor G3 (Pixel 8 Pro) and Tensor G4 (Pixel 9) automatically.
#
# Tensor G3: Little=cpu0-3(policy0)  Big=cpu4-7(policy4)  Prime=cpu8(policy8)
# Tensor G4: Little=cpu0-3(policy0)  Big=cpu4-6(policy4)  Prime=cpu7(policy7)
#
# The three configurations:
#   big_prime     — Big+Prime stressed, Little online at min freq  → P_static_little
#   little_prime  — Little+Prime stressed, Big online at min freq  → P_static_big
#   little_big    — Little+Big stressed, Prime online at min freq  → P_static_prime
#
# Usage:
#   sh phase2c_cluster_combos.sh                         # all three combos
#   sh phase2c_cluster_combos.sh "big_prime,little_big"  # subset
#
# Env overrides:
#   SWEEP_DURATION_SEC=900   total continuous logging time per combo
#   SWEEP_INTERVAL=1.0       seconds between samples
#   SWEEP_NUM_REPS=1         repetitions per combo
#   COOLDOWN_TARGET_C=35     cooldown target before each sweep

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
# Device detection
# ============================================================================
if [ -d /sys/devices/system/cpu/cpufreq/policy8 ]; then
    DEVICE="pixel8pro"
    ALL_CORES="0 1 2 3 4 5 6 7 8"
    LITTLE_CPUS="0 1 2 3"
    BIG_CPUS="4 5 6 7"
    PRIME_CPUS="8"
    LITTLE_POLICY=0
    BIG_POLICY=4
    PRIME_POLICY=8
    LITTLE_MIN_FREQ=324000
    BIG_MIN_FREQ=402000
    PRIME_MIN_FREQ=500000
    LITTLE_MAX_FREQ=1704000
    BIG_MAX_FREQ=2367000
    PRIME_MAX_FREQ=2914000
else
    DEVICE="pixel9"
    ALL_CORES="0 1 2 3 4 5 6 7"
    LITTLE_CPUS="0 1 2 3"
    BIG_CPUS="4 5 6"
    PRIME_CPUS="7"
    LITTLE_POLICY=0
    BIG_POLICY=4
    PRIME_POLICY=7
    LITTLE_MIN_FREQ=300000
    BIG_MIN_FREQ=400000
    PRIME_MIN_FREQ=400000
    LITTLE_MAX_FREQ=1900000
    BIG_MAX_FREQ=2600000
    PRIME_MAX_FREQ=3100000
fi
log_info "Device: ${DEVICE}  BIG_CPUS=${BIG_CPUS}  PRIME_CPUS=${PRIME_CPUS}  PRIME_POLICY=${PRIME_POLICY}"

# ============================================================================
# Configuration
# ============================================================================
SWEEP_DURATION_SEC="${SWEEP_DURATION_SEC:-900}"
SWEEP_INTERVAL="${SWEEP_INTERVAL:-1.0}"
SWEEP_NUM_REPS="${SWEEP_NUM_REPS:-1}"
COOLDOWN_TARGET_C="${COOLDOWN_TARGET_C:-35}"

ALL_COMBOS="big_prime little_prime little_big"

if [ -n "$1" ]; then
    COMBOS=$(echo "$1" | tr ',' ' ')
else
    COMBOS="$ALL_COMBOS"
fi

IDLE_SEC=$(awk -v d="$SWEEP_DURATION_SEC" \
    'BEGIN{x=int(d*0.10); print (x<60)?60:x}')

OUT_DIR="$DATA_DIR/phase2c_combos"
mkdir -p "$OUT_DIR"

echo "========================================================================"
echo " PHASE 2c: Cluster combination thermal sweeps (${DEVICE})"
echo " Bystander clusters: ONLINE at min frequency (not offlined)"
echo "========================================================================"
echo "Combos:         $COMBOS"
echo "Sweep duration: ${SWEEP_DURATION_SEC}s @ ${SWEEP_INTERVAL}s interval"
echo "Idle baseline:  ${IDLE_SEC}s"
echo "Repetitions:    $SWEEP_NUM_REPS"
echo "Cooldown:       to ${COOLDOWN_TARGET_C}°C"
echo "Output:         $OUT_DIR"
echo "========================================================================"

pm stay-awake true >/dev/null 2>&1 || svc power stayon true >/dev/null 2>&1 || true
stop_thermal_hal

cleanup_all() {
    trap '' INT TERM EXIT
    log_info "Cleanup: killing stress, onlining all cores, restoring thermal HAL"
    kill 0 2>/dev/null || true
    sleep 1
    killall stress-ng 2>/dev/null || killall stress 2>/dev/null || true
    for c in $ALL_CORES; do
        f="/sys/devices/system/cpu/cpu${c}/online"
        [ -e "$f" ] && echo 1 > "$f" 2>/dev/null || true
    done
    for pol in 0 4 $PRIME_POLICY; do
        g="/sys/devices/system/cpu/cpufreq/policy${pol}/scaling_governor"
        [ -e "$g" ] && echo schedutil > "$g" 2>/dev/null || true
    done
    echo $LITTLE_MAX_FREQ > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || true
    echo $BIG_MAX_FREQ    > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq 2>/dev/null || true
    echo $PRIME_MAX_FREQ  > /sys/devices/system/cpu/cpufreq/policy${PRIME_POLICY}/scaling_max_freq 2>/dev/null || true
    start_thermal_hal
    pm stay-awake false >/dev/null 2>&1 || svc power stayon false >/dev/null 2>&1 || true
    log_ok "Cleanup done"
    exit 0
}
trap cleanup_all INT TERM EXIT

detect_stress_tool
setup_cgroups
move_tasks_to_system

# Online all cores and set performance governor
for c in $ALL_CORES; do
    f="/sys/devices/system/cpu/cpu${c}/online"
    [ -e "$f" ] && echo 1 > "$f" 2>/dev/null || true
done
for cluster in little big prime; do
    set_governor "$cluster" performance
done

capture_baseline_temp

# Pin all to min before initial cooldown
pin_frequency "little" "$LITTLE_MIN_FREQ"
pin_frequency "big"    "$BIG_MIN_FREQ"
pin_frequency "prime"  "$PRIME_MIN_FREQ"

# ============================================================================
# wait_for_cooldown
# ============================================================================
wait_for_cooldown() {
    label="$1"
    log_info "Cooling down to ${COOLDOWN_TARGET_C}°C before $label..."
    while true; do
        max_temp=0
        for zone in /sys/class/thermal/thermal_zone*/; do
            type=$(cat "${zone}type" 2>/dev/null || echo "")
            case "$type" in
                LITTLE|BIG|PRIME|MID|cpu*|CPU*|big*|little*|prime*)
                    t=$(cat "${zone}temp" 2>/dev/null || echo 0)
                    [ "$t" -gt "$max_temp" ] && max_temp="$t"
                    ;;
            esac
        done
        if [ "$max_temp" -eq 0 ]; then
            for f in /sys/class/thermal/thermal_zone*/temp; do
                t=$(cat "$f" 2>/dev/null || echo 0)
                [ "$t" -gt "$max_temp" ] && max_temp="$t"
            done
        fi
        max_c=$(( max_temp / 1000 ))
        [ "$max_temp" -le $(( COOLDOWN_TARGET_C * 1000 )) ] && break
        log_info "  Cooling... ${max_c}°C (CPU zones) — waiting 15s"
        sleep 15
    done
    log_ok "Cooled to ${max_c}°C"
}

log_info "Initial cooldown to ${COOLDOWN_TARGET_C}°C..."
wait_for_cooldown "script start"

# ============================================================================
# configure_combo_env — active clusters at max freq, bystander at min freq
# No cluster is offlined.
# Sets shell variables: ACTIVE_CLUSTERS, STRESS_CORES, fL, fB, fP
# ============================================================================
configure_combo_env() {
    _combo="$1"

    # Online all cores first
    for c in $ALL_CORES; do
        f="/sys/devices/system/cpu/cpu${c}/online"
        [ -e "$f" ] && echo 1 > "$f" 2>/dev/null || true
    done

    case "$_combo" in
        big_prime)
            ACTIVE_CLUSTERS="big+prime"
            STRESS_CORES="$BIG_CPUS $PRIME_CPUS"
            pin_frequency "big"    "$BIG_MAX_FREQ"
            pin_frequency "prime"  "$PRIME_MAX_FREQ"
            pin_frequency "little" "$LITTLE_MIN_FREQ"   # bystander
            fL=$LITTLE_MIN_FREQ; fB=$BIG_MAX_FREQ; fP=$PRIME_MAX_FREQ
            log_info "  Active:    big=${BIG_MAX_FREQ}kHz  prime=${PRIME_MAX_FREQ}kHz"
            log_info "  Bystander: little=${LITTLE_MIN_FREQ}kHz (online)"
            ;;
        little_prime)
            ACTIVE_CLUSTERS="little+prime"
            STRESS_CORES="$LITTLE_CPUS $PRIME_CPUS"
            pin_frequency "little" "$LITTLE_MAX_FREQ"
            pin_frequency "prime"  "$PRIME_MAX_FREQ"
            pin_frequency "big"    "$BIG_MIN_FREQ"      # bystander
            fL=$LITTLE_MAX_FREQ; fB=$BIG_MIN_FREQ; fP=$PRIME_MAX_FREQ
            log_info "  Active:    little=${LITTLE_MAX_FREQ}kHz  prime=${PRIME_MAX_FREQ}kHz"
            log_info "  Bystander: big=${BIG_MIN_FREQ}kHz (online)"
            ;;
        little_big)
            ACTIVE_CLUSTERS="little+big"
            STRESS_CORES="$LITTLE_CPUS $BIG_CPUS"
            pin_frequency "little" "$LITTLE_MAX_FREQ"
            pin_frequency "big"    "$BIG_MAX_FREQ"
            pin_frequency "prime"  "$PRIME_MIN_FREQ"    # bystander
            fL=$LITTLE_MAX_FREQ; fB=$BIG_MAX_FREQ; fP=$PRIME_MIN_FREQ
            log_info "  Active:    little=${LITTLE_MAX_FREQ}kHz  big=${BIG_MAX_FREQ}kHz"
            log_info "  Bystander: prime=${PRIME_MIN_FREQ}kHz (online)"
            ;;
        *)
            log_warn "Unknown combo: $_combo — skipping"
            return 1
            ;;
    esac

    log_info "  Online CPUs: $(cat /sys/devices/system/cpu/online)"
    sleep 0.5
    return 0
}

# ============================================================================
# CSV header
# ============================================================================
write_combo_header() {
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
# Power/battery helpers
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
# sample_one_row — device-aware rho computation via BIG_CPUS/PRIME_CPUS vars
# ============================================================================
sample_one_row() {
    _phase="$1"; _config="$2"; _rep="$3"; _workload="$4"; _active="$5"
    _fL_pin="$6"; _fB_pin="$7"; _fP_pin="$8"; _csv="$9"
    _stat_b="${10}"; _stat_a="${11}"

    TS=$(now_ms)

    POWERS=$(read_all_cluster_powers_uw)
    L_uw=$(echo "$POWERS"     | awk '{print $1}')
    B_uw=$(echo "$POWERS"     | awk '{print $2}')
    P_uw=$(echo "$POWERS"     | awk '{print $3}')
    T_uw=$(echo "$POWERS"     | awk '{print $4}')
    Lmain_uw=$(echo "$POWERS" | awk '{print $5}')
    Lmem_uw=$(echo "$POWERS"  | awk '{print $6}')
    RAM_uw=$(read_ram_power_uw)

    VOLTS=$(read_all_cluster_voltages_uv)
    VL_uv=$(echo "$VOLTS" | awk '{print $1}')
    VB_uv=$(echo "$VOLTS" | awk '{print $2}')
    VP_uv=$(echo "$VOLTS" | awk '{print $3}')

    TL=$(read_cluster_temp little)
    TB=$(read_cluster_temp big)
    TP=$(read_cluster_temp prime)

    fL_cur=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq \
             2>/dev/null || echo "$_fL_pin")
    fB_cur=$(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq \
             2>/dev/null || echo "$_fB_pin")
    fP_cur=$(cat /sys/devices/system/cpu/cpufreq/policy${PRIME_POLICY}/scaling_cur_freq \
             2>/dev/null || echo "$_fP_pin")

    BV=$(read_batt_voltage_v)
    BI=$(read_batt_current_ma)
    BP=$(read_batt_power_w)
    TBat=$(read_batt_temp_c)

    RAM_mA=$(grep "S1M_VDD_MIF" "$ODPM_MAIN/lpf_current" 2>/dev/null \
        | awk -F', ' '{printf("%.1f", $2); exit}' || echo 0.0)

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

    # All cores online — read actual frequency for each
    CPU_FREQS=""
    for c in $ALL_CORES; do
        f_cur=$(cat /sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq \
                2>/dev/null || echo "0")
        CPU_FREQS="$CPU_FREQS $f_cur"
    done

    # Per-core utilization from /proc/stat snapshots
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

    # rho_L: Little cores cpu0-3 (same on both devices)
    rho_L=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk '
        /^cpu[0-3] / {
            if(!seen[$1]++){idle1[$1]=$5; tot1[$1]=$2+$3+$4+$5+$6+$7+$8+$9}
            else {dt=($2+$3+$4+$5+$6+$7+$8+$9)-tot1[$1]; di=$5-idle1[$1]
                  if(dt>0){s+=100*(1-di/dt); n++}}
        }
        END{if(n>0) printf("%.4f",s/n/100); else print "0.0000"}')

    # rho_B: BIG_CPUS variable (cpu4-7 on G3, cpu4-6 on G4)
    rho_B=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk -v cpus="$BIG_CPUS" '
        BEGIN{ n=split(cpus,ca," "); for(i=1;i<=n;i++) t["cpu"ca[i]]=1 }
        ($1 in t) {
            if(!seen[$1]++){idle1[$1]=$5; tot1[$1]=$2+$3+$4+$5+$6+$7+$8+$9}
            else {dt=($2+$3+$4+$5+$6+$7+$8+$9)-tot1[$1]; di=$5-idle1[$1]
                  if(dt>0){s+=100*(1-di/dt); n++}}
        }
        END{if(n>0) printf("%.4f",s/n/100); else print "0.0000"}')

    # rho_P: PRIME_CPUS variable (cpu8 on G3, cpu7 on G4)
    rho_P=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk -v cpus="$PRIME_CPUS" '
        BEGIN{ split(cpus,ca," "); pc="cpu"ca[1] }
        $1==pc {
            if(!seen++){idle1=$5; tot1=$2+$3+$4+$5+$6+$7+$8+$9}
            else {dt=($2+$3+$4+$5+$6+$7+$8+$9)-tot1; di=$5-idle1
                  if(dt>0) printf("%.4f",(1-di/dt)); else print "0.0000"; exit}
        }
        END{if(!seen) print "0.0000"}')

    {
        printf "%s,%s,%s,%s,%s," \
               "$_phase" "$_config" "$_rep" "$_workload" "$_active"
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
# Main combo loop
# ============================================================================
for combo in $COMBOS; do

    ACTIVE_CLUSTERS=""
    STRESS_CORES=""
    fL=0; fB=0; fP=0

    configure_combo_env "$combo" || continue

    echo ""
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  combo: ${combo}  active: ${ACTIVE_CLUSTERS}"
    echo "┃  stress_cores: ${STRESS_CORES}"
    echo "┃  fL=${fL}kHz  fB=${fB}kHz  fP=${fP}kHz"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"

    rep=1
    while [ "$rep" -le "$SWEEP_NUM_REPS" ]; do

        # Cool before each rep then re-apply config
        wait_for_cooldown "${combo} rep${rep}"
        configure_combo_env "$combo"

        csv="$OUT_DIR/combo_${combo}_rep${rep}.csv"
        write_combo_header "$csv"

        # ── Idle baseline ─────────────────────────────────────────────────
        log_info "Idle baseline (${IDLE_SEC}s)..."
        n=0
        END_MS=$(( $(now_ms) + IDLE_SEC * 1000 ))
        while [ "$(now_ms)" -lt "$END_MS" ]; do
            STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
            sleep "$SWEEP_INTERVAL"
            STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
            sample_one_row "combo_idle" "combo_${combo}" "$rep" "idle" \
                           "$ACTIVE_CLUSTERS" \
                           "$fL" "$fB" "$fP" "$csv" \
                           "$STAT_BEFORE" "$STAT_AFTER"
            n=$(( n + 1 ))
        done
        log_ok "Idle baseline: $n samples"

        # ── Stress sweep ──────────────────────────────────────────────────
        log_info "Stress on cores: ${STRESS_CORES} for ${SWEEP_DURATION_SEC}s..."
        pids=$(start_stress_on_cpus "$STRESS_CORES")

        n=0
        END_MS=$(( $(now_ms) + SWEEP_DURATION_SEC * 1000 ))
        while [ "$(now_ms)" -lt "$END_MS" ]; do
            STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
            sleep "$SWEEP_INTERVAL"
            STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
            sample_one_row "combo_sweep" "combo_${combo}" "$rep" "stress" \
                           "$ACTIVE_CLUSTERS" \
                           "$fL" "$fB" "$fP" "$csv" \
                           "$STAT_BEFORE" "$STAT_AFTER"
            n=$(( n + 1 ))
        done
        stop_stress
        log_ok "Stress sweep: $n samples"
        log_ok "CSV: $csv  ($(wc -l < "$csv") rows)"

        rep=$(( rep + 1 ))
    done
done

echo ""
echo "========================================================================"
echo " PHASE 2c COMPLETE (${DEVICE})"
echo "========================================================================"
echo "CSV files in: $OUT_DIR"
ls -1 "$OUT_DIR"