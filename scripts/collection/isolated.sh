#!/system/bin/sh
# phase1_isolated.sh - Phase 1 + Phase 1b: per-cluster C_eff and leakage sweep.
#
# Pixel 9 / Tensor G4 variant.
# CPU topology:
#   Little:  cpu0-3  (4x Cortex-A520), policy0
#   Big:     cpu4-6  (3x Cortex-A720), policy4
#   Prime:   cpu7    (1x Cortex-X4),   policy7
#
# For each target cluster:
#   Part A — C_eff calibration (phase1/)
#     Runs idle + stress at three pinned frequencies: f_min, f_mid, f_max.
#     Other clusters remain ONLINE at min frequency (not offlined).
#     Output: phase1/<cluster>_<freq>_rep<N>.csv
#
#   Part B — Per-cluster thermal sweep (phase1b_thermal/)
#     After Part A, holds at f_max and stresses continuously from cold to
#     throttling. Other clusters remain online at min frequency.
#     Output: phase1b_thermal/<cluster>_max_thermal_rep<N>.csv
#
# Usage:
#   sh phase1_isolated.sh <cluster> [cluster2 ...]
#   sh phase1_isolated.sh all
#
# Env overrides:
#   STATIC_DURATION_SEC=300   stress duration per frequency point
#   IDLE_DURATION_SEC=60      idle baseline duration per frequency point
#   STATIC_INTERVAL=1.0       sampling interval for static points
#   THERMAL_DURATION_SEC=900  thermal sweep duration at f_max
#   THERMAL_INTERVAL=1.0      sampling interval for thermal sweep
#   NUM_REPS=1                repetitions per frequency point
#   COOLDOWN_TARGET_C=35      target temperature before each rep

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
if [ $# -eq 0 ]; then
    echo "Usage: $0 <cluster> [cluster2 ...] | all" >&2
    exit 1
fi

CLUSTERS_TO_RUN=""
if [ "$1" = "all" ]; then
    CLUSTERS_TO_RUN="$CLUSTERS"
else
    for arg in "$@"; do
        case "$arg" in
            little|big|prime) CLUSTERS_TO_RUN="$CLUSTERS_TO_RUN $arg" ;;
            *) log_error "Unknown cluster: $arg"; exit 1 ;;
        esac
    done
fi

# ============================================================================
# Parameters
# ============================================================================
STATIC_DURATION_SEC="${STATIC_DURATION_SEC:-300}"
IDLE_DURATION_SEC="${IDLE_DURATION_SEC:-60}"
STATIC_INTERVAL="${STATIC_INTERVAL:-1.0}"
THERMAL_DURATION_SEC="${THERMAL_DURATION_SEC:-900}"
THERMAL_INTERVAL="${THERMAL_INTERVAL:-1.0}"
NUM_REPS="${NUM_REPS:-1}"
COOLDOWN_TARGET_C="${COOLDOWN_TARGET_C:-35}"

THERMAL_IDLE_SEC=$(awk -v d="$THERMAL_DURATION_SEC" \
    'BEGIN{x=int(d*0.10); print (x<60)?60:x}')

OUT_PHASE1="${DATA_DIR}/phase1"
OUT_THERMAL="${DATA_DIR}/phase1b_thermal"
mkdir -p "$OUT_PHASE1" "$OUT_THERMAL"

# ============================================================================
# Device detection — auto-configure CPU topology
#
# Tensor G3 (Pixel 8 Pro):  9 cores
#   Little  cpu0-3  policy0   (4x Cortex-A510)
#   Big     cpu4-7  policy4   (4x Cortex-A715)
#   Prime   cpu8    policy8   (1x Cortex-X3)
#
# Tensor G4 (Pixel 9):      8 cores
#   Little  cpu0-3  policy0   (4x Cortex-A520)
#   Big     cpu4-6  policy4   (3x Cortex-A720)
#   Prime   cpu7    policy7   (1x Cortex-X4)
#
# Detection: if policy8 exists → G3, else → G4
# ============================================================================
if [ -d /sys/devices/system/cpu/cpufreq/policy8 ]; then
    DEVICE="pixel8pro"
    log_info "Detected Tensor G3 (Pixel 8 Pro) — 9-core topology"
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
    log_info "Detected Tensor G4 (Pixel 9) — 8-core topology"
    ALL_CORES="0 1 2 3 4 5 6 7"
    LITTLE_CPUS="0 1 2 3"
    BIG_CPUS="4 5 6"
    PRIME_CPUS="7"
    LITTLE_POLICY=0
    BIG_POLICY=4
    PRIME_POLICY=7
    # Verify on device:
    # cat /sys/devices/system/cpu/cpufreq/policy{0,4,7}/scaling_available_frequencies
    LITTLE_MIN_FREQ=300000
    BIG_MIN_FREQ=400000
    PRIME_MIN_FREQ=400000
    LITTLE_MAX_FREQ=1900000
    BIG_MAX_FREQ=2600000
    PRIME_MAX_FREQ=3100000
fi
log_info "Device: ${DEVICE}  ALL_CORES=${ALL_CORES}  PRIME_POLICY=${PRIME_POLICY}"

echo "========================================================================"
echo " PHASE 1 + 1b: Per-cluster C_eff and leakage sweep (${DEVICE})"
echo " Topology: Little=cpu0-3(policy0)  Big=${BIG_CPUS}(policy4)  Prime=${PRIME_CPUS}(policy${PRIME_POLICY})"
echo " Other clusters: ONLINE at min frequency (not offlined)"
echo "========================================================================"
echo "Clusters:          $CLUSTERS_TO_RUN"
echo "Frequencies/cluster: f_min, f_mid, f_max (3 points)"
echo "Static:            ${IDLE_DURATION_SEC}s idle + ${STATIC_DURATION_SEC}s stress @ ${STATIC_INTERVAL}s"
echo "Reps/frequency:    $NUM_REPS"
echo "Thermal sweep:     ${THERMAL_DURATION_SEC}s @ ${THERMAL_INTERVAL}s (idle: ${THERMAL_IDLE_SEC}s)"
echo "Cooldown target:   ${COOLDOWN_TARGET_C}°C"
echo "Output phase1:     $OUT_PHASE1"
echo "Output phase1b:    $OUT_THERMAL"
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
    # Restore max frequencies
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

for cluster in $CLUSTERS; do
    set_governor "$cluster" performance
done

capture_baseline_temp

# Lock all clusters to min frequency before initial cooldown
log_info "Pinning all clusters to min frequency before initial cooldown..."
pin_frequency "little" "$LITTLE_MIN_FREQ"
pin_frequency "big"    "$BIG_MIN_FREQ"
pin_frequency "prime"  "$PRIME_MIN_FREQ"
log_info "  little=${LITTLE_MIN_FREQ}kHz  big=${BIG_MIN_FREQ}kHz  prime=${PRIME_MIN_FREQ}kHz"

log_info "Initial cooldown to ${COOLDOWN_TARGET_C}°C before any measurements..."
wait_for_cooldown "script start"

# ============================================================================
# configure_cluster_env
# ============================================================================
configure_cluster_env() {
    target="$1"
    freq="$2"

    # Online all cores (device-specific via ALL_CORES)
    for c in $ALL_CORES; do
        f="/sys/devices/system/cpu/cpu${c}/online"
        [ -e "$f" ] && echo 1 > "$f" 2>/dev/null || true
    done

    # Pin target cluster to requested frequency
    pin_frequency "$target" "$freq"

    # Pin bystander clusters to min frequency
    case "$target" in
        little)
            pin_frequency "big"   "$BIG_MIN_FREQ"
            pin_frequency "prime" "$PRIME_MIN_FREQ"
            log_info "  Bystanders pinned: big=${BIG_MIN_FREQ}kHz  prime=${PRIME_MIN_FREQ}kHz"
            ;;
        big)
            pin_frequency "little" "$LITTLE_MIN_FREQ"
            pin_frequency "prime"  "$PRIME_MIN_FREQ"
            log_info "  Bystanders pinned: little=${LITTLE_MIN_FREQ}kHz  prime=${PRIME_MIN_FREQ}kHz"
            ;;
        prime)
            pin_frequency "little" "$LITTLE_MIN_FREQ"
            pin_frequency "big"    "$BIG_MIN_FREQ"
            log_info "  Bystanders pinned: little=${LITTLE_MIN_FREQ}kHz  big=${BIG_MIN_FREQ}kHz"
            ;;
    esac

    log_info "  Online CPUs: $(cat /sys/devices/system/cpu/online)"
    sleep 0.5
}

# ============================================================================
# CSV header — 8 cores (cpu0-7)
# ============================================================================
write_phase1_header() {
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
# sample_one_row — Tensor G4 variant
# rho_B uses cpu4-6 (3 cores), rho_P uses cpu7
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

    # Per-core frequencies — 8 cores (cpu0-7)
    CPU_FREQS=""
    for c in $ALL_CORES; do
        f_cur=$(cat /sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq \
                2>/dev/null || echo "0")
        CPU_FREQS="$CPU_FREQS $f_cur"
    done

    # Per-core utilization — 8 cores
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

    # rho_L: cpu0-3 (4 cores)
    rho_L=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk '
        /^cpu[0-3] / {
            if(!seen[$1]++){idle1[$1]=$5; tot1[$1]=$2+$3+$4+$5+$6+$7+$8+$9}
            else {dt=($2+$3+$4+$5+$6+$7+$8+$9)-tot1[$1]; di=$5-idle1[$1]
                  if(dt>0){s+=100*(1-di/dt); n++}}
        }
        END{if(n>0) printf("%.4f",s/n/100); else print "0.0000"}')

    # rho_B: BIG_CPUS cores (cpu4-7 on G3, cpu4-6 on G4)
    rho_B=$(printf '%s\n%s\n' "$_stat_b" "$_stat_a" | awk -v cpus="$BIG_CPUS" '
        BEGIN{ n=split(cpus,ca," "); for(i=1;i<=n;i++) t["cpu"ca[i]]=1 }
        ($1 in t) {
            if(!seen[$1]++){idle1[$1]=$5; tot1[$1]=$2+$3+$4+$5+$6+$7+$8+$9}
            else {dt=($2+$3+$4+$5+$6+$7+$8+$9)-tot1[$1]; di=$5-idle1[$1]
                  if(dt>0){s+=100*(1-di/dt); n++}}
        }
        END{if(n>0) printf("%.4f",s/n/100); else print "0.0000"}')

    # rho_P: PRIME_CPUS (cpu8 on G3, cpu7 on G4)
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
# wait_for_cooldown
# ============================================================================
wait_for_cooldown() {
    label="$1"
    log_info "Cooling down to ${COOLDOWN_TARGET_C}°C before $label..."
    while true; do
        max_temp=0
        # Only check CPU-relevant thermal zones — excludes RF, modem, battery
        # sensors which run permanently hot and are unrelated to CPU state.
        for zone in /sys/class/thermal/thermal_zone*/; do
            type=$(cat "${zone}type" 2>/dev/null || echo "")
            case "$type" in
                LITTLE|BIG|PRIME|MID|cpu*|CPU*|big*|little*|prime*)
                    t=$(cat "${zone}temp" 2>/dev/null || echo 0)
                    [ "$t" -gt "$max_temp" ] && max_temp="$t"
                    ;;
            esac
        done
        # Fallback: if no CPU zones matched, use global max
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

# ============================================================================
# detect_throttle
# ============================================================================
detect_throttle() {
    fL_init="$1"; fB_init="$2"; fP_init="$3"
    fL_cur=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null || echo 0)
    fB_cur=$(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq 2>/dev/null || echo 0)
    fP_cur=$(cat /sys/devices/system/cpu/cpufreq/policy${PRIME_POLICY}/scaling_cur_freq 2>/dev/null || echo 0)
    awk -v fl_i="$fL_init" -v fl_c="$fL_cur" \
        -v fb_i="$fB_init" -v fb_c="$fB_cur" \
        -v fp_i="$fP_init" -v fp_c="$fP_cur" \
    'BEGIN {
        throttled = 0
        if (fl_i > 0 && fl_c < fl_i * 0.97) throttled = 1
        if (fb_i > 0 && fb_c < fb_i * 0.97) throttled = 1
        if (fp_i > 0 && fp_c < fp_i * 0.97) throttled = 1
        exit throttled
    }'
}

# ============================================================================
# Main per-cluster loop
# ============================================================================
for target_cluster in $CLUSTERS_TO_RUN; do

    echo ""
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  CLUSTER: $target_cluster"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"

    case "$target_cluster" in
        little) ACTIVE_LABEL="little" ;;
        big)    ACTIVE_LABEL="big"    ;;
        prime)  ACTIVE_LABEL="prime"  ;;
    esac

    active_cpus="$(cluster_cpus "$target_cluster")"

    # Cool first (all clusters already at min freq from previous step or init)
    # then configure env for this cluster
    wait_for_cooldown "start of cluster ${target_cluster}"
    configure_cluster_env "$target_cluster" \
        "$(list_freqs "$target_cluster" | awk '{print $1}')"

    ALL_FREQS="$(list_freqs "$target_cluster")"
    FREQ_MIN=$(echo "$ALL_FREQS" | awk '{print $1}')
    FREQ_MAX=$(echo "$ALL_FREQS" | awk '{print $NF}')
    FREQ_MID=$(echo "$ALL_FREQS" | awk '{n=NF; mid=int((n+1)/2); print $mid}')

    log_info "Available freqs: $ALL_FREQS"
    log_info "Operating points: min=${FREQ_MIN}kHz  mid=${FREQ_MID}kHz  max=${FREQ_MAX}kHz"

    # ── PART A ──────────────────────────────────────────────────────────────
    echo ""
    log_info "=== Part A: C_eff static sweep (phase1/) ==="

    for freq_target in $FREQ_MIN $FREQ_MID $FREQ_MAX; do
        fL=0; fB=0; fP=0
        case "$target_cluster" in
            little) fL=$freq_target ;;
            big)    fB=$freq_target ;;
            prime)  fP=$freq_target ;;
        esac

        config_id="${target_cluster}_${freq_target}"
        log_info "--- Config: $config_id ---"

        rep=1
        while [ "$rep" -le "$NUM_REPS" ]; do

            wait_for_cooldown "idle phase of ${config_id} rep${rep}"
            configure_cluster_env "$target_cluster" "$freq_target"

            csv="$OUT_PHASE1/${config_id}_rep${rep}.csv"
            write_phase1_header "$csv"

            case "$target_cluster" in
                little) pol=0 ;; big) pol=4 ;; prime) pol=$PRIME_POLICY ;;
            esac
            actual=$(cat /sys/devices/system/cpu/cpufreq/policy${pol}/scaling_cur_freq \
                     2>/dev/null || echo "?")
            log_info "  Pinned to ${freq_target}kHz — actual: ${actual}kHz"

            # Idle
            log_info "  Idle (${IDLE_DURATION_SEC}s)..."
            n=0
            END_MS=$(( $(now_ms) + IDLE_DURATION_SEC * 1000 ))
            while [ "$(now_ms)" -lt "$END_MS" ]; do
                STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
                sleep "$STATIC_INTERVAL"
                STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
                sample_one_row "${target_cluster}_idle" "$config_id" "$rep" \
                               "idle" "$ACTIVE_LABEL" \
                               "$fL" "$fB" "$fP" "$csv" \
                               "$STAT_BEFORE" "$STAT_AFTER"
                n=$(( n + 1 ))
            done
            log_ok "  Idle: $n samples"

            wait_for_cooldown "stress phase of ${config_id} rep${rep}"
            configure_cluster_env "$target_cluster" "$freq_target"

            # Stress
            log_info "  Stress (${STATIC_DURATION_SEC}s)..."
            pids=$(start_stress_on_cpus "$active_cpus")
            sleep 2

            n=0
            END_MS=$(( $(now_ms) + STATIC_DURATION_SEC * 1000 ))
            while [ "$(now_ms)" -lt "$END_MS" ]; do
                STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
                sleep "$STATIC_INTERVAL"
                STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
                sample_one_row "${target_cluster}_stress" "$config_id" "$rep" \
                               "stress" "$ACTIVE_LABEL" \
                               "$fL" "$fB" "$fP" "$csv" \
                               "$STAT_BEFORE" "$STAT_AFTER"
                n=$(( n + 1 ))
            done
            stop_stress
            log_ok "  Stress: $n samples  →  $csv"

            rep=$(( rep + 1 ))
        done
    done

    # ── PART B ──────────────────────────────────────────────────────────────
    echo ""
    log_info "=== Part B: Thermal sweep at f_max=${FREQ_MAX}kHz (phase1b_thermal/) ==="

    fL=0; fB=0; fP=0
    case "$target_cluster" in
        little) fL=$FREQ_MAX ;;
        big)    fB=$FREQ_MAX ;;
        prime)  fP=$FREQ_MAX ;;
    esac

    wait_for_cooldown "thermal sweep"
    configure_cluster_env "$target_cluster" "$FREQ_MAX"

    thermal_csv="$OUT_THERMAL/${target_cluster}_max_thermal_rep1.csv"
    write_phase1_header "$thermal_csv"

    fL_init=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null || echo 0)
    fB_init=$(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq 2>/dev/null || echo 0)
    fP_init=$(cat /sys/devices/system/cpu/cpufreq/policy${PRIME_POLICY}/scaling_cur_freq 2>/dev/null || echo 0)

    log_info "  Thermal idle baseline (${THERMAL_IDLE_SEC}s)..."
    n=0
    END_MS=$(( $(now_ms) + THERMAL_IDLE_SEC * 1000 ))
    while [ "$(now_ms)" -lt "$END_MS" ]; do
        STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
        sleep "$THERMAL_INTERVAL"
        STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
        sample_one_row "thermal_idle" "${target_cluster}_max_thermal" "1" \
                       "idle" "$ACTIVE_LABEL" \
                       "$fL" "$fB" "$fP" "$thermal_csv" \
                       "$STAT_BEFORE" "$STAT_AFTER"
        n=$(( n + 1 ))
    done
    log_ok "  Thermal idle: $n samples"

    log_info "  Thermal stress sweep (${THERMAL_DURATION_SEC}s max)..."
    pids=$(start_stress_on_cpus "$active_cpus")
    sleep 2

    n_pre=0; n_post=0; throttled=0
    END_MS=$(( $(now_ms) + THERMAL_DURATION_SEC * 1000 ))

    while [ "$(now_ms)" -lt "$END_MS" ]; do
        STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
        sleep "$THERMAL_INTERVAL"
        STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)

        if [ "$throttled" = "0" ]; then
            detect_throttle "$fL_init" "$fB_init" "$fP_init"
            if [ $? -ne 0 ]; then
                throttled=1
                log_info "  Throttle onset detected"
            fi
        fi

        phase_label="thermal_sweep"
        [ "$throttled" = "1" ] && phase_label="thermal_post"

        sample_one_row "$phase_label" "${target_cluster}_max_thermal" "1" \
                       "stress" "$ACTIVE_LABEL" \
                       "$fL" "$fB" "$fP" "$thermal_csv" \
                       "$STAT_BEFORE" "$STAT_AFTER"

        if [ "$throttled" = "0" ]; then
            n_pre=$(( n_pre + 1 ))
        else
            n_post=$(( n_post + 1 ))
        fi
    done

    stop_stress
    log_ok "  Thermal sweep: ${n_pre} pre-throttle + ${n_post} post-throttle samples"
    log_ok "  → $thermal_csv  ($(wc -l < "$thermal_csv") rows)"

done

echo ""
echo "========================================================================"
echo " PHASE 1 + 1b COMPLETE (${DEVICE})"
echo "========================================================================"
echo "Phase1 CSVs:    $OUT_PHASE1"
ls -1 "$OUT_PHASE1" | wc -l
echo "Phase1b CSVs:   $OUT_THERMAL"
ls -1 "$OUT_THERMAL"