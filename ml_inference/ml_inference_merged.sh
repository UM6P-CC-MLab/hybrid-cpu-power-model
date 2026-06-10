#!/system/bin/sh
# ml_inference_merged.sh - Run TFLite benchmark inference on Pixel 8 Pro
#                          with integrated power logging.
#
# Merges ml_inference_runner.sh and ml_power_logger.sh into a single script.
# Idle baseline is logged for 10% of total duration before inference starts.
#
# Usage:
#   sh ml_inference_merged.sh [duration_sec] [model_path] [cluster] [interval_sec]
#
# Arguments:
#   duration_sec  : inference duration in seconds          (default: 120)
#   model_path    : path to .tflite model on device        (default: mobilenet_v1_quant.tflite)
#   cluster       : little | big | prime | prime_nooffline | prime_big3 | free  (default: big)
#   interval_sec  : power sampling interval in seconds     (default: 1.0)
#
# Examples:
#   sh ml_inference_merged.sh 3600 /data/local/tmp/mobilenet_v1_quant.tflite free 1.0
#   sh ml_inference_merged.sh 120  /data/local/tmp/mobilenet_v1_quant.tflite prime 0.5

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/freq_control.sh"
. "$SCRIPT_DIR/lib/thermal.sh"
. "$SCRIPT_DIR/lib/stress.sh"
. "$SCRIPT_DIR/lib/odpm.sh"

require_root

# ============================================================================
# Arguments
# ============================================================================
DURATION=${1:-120}
MODEL=${2:-/data/local/tmp/mobilenet_v1_quant.tflite}
CLUSTER=${3:-big}
INTERVAL=${4:-1.0}
BENCHMARK=/data/local/tmp/benchmark_model

# Idle duration = 10% of total inference duration, minimum 30s
IDLE_DURATION=$(awk -v d="$DURATION" 'BEGIN{
    x = int(d * 0.1)
    print (x < 30) ? 30 : x
}')

# ============================================================================
# Cluster definitions — Pixel 8 Pro (Tensor G3)
# ============================================================================
LITTLE_CPUS="0 1 2 3"
BIG_CPUS="4 5 6 7"
PRIME_CPUS="8"
ALL_CORES="0 1 2 3 4 5 6 7 8"

LITTLE_POLICY=0
BIG_POLICY=4
PRIME_POLICY=8

LITTLE_MAX_FREQ=1704000
BIG_MAX_FREQ=2367000
PRIME_MAX_FREQ=2914000

LITTLE_MIN_FREQ=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq 2>/dev/null || echo 324000)
BIG_MIN_FREQ=$(cat /sys/devices/system/cpu/cpufreq/policy4/cpuinfo_min_freq 2>/dev/null || echo 402000)
PRIME_MIN_FREQ=$(cat /sys/devices/system/cpu/cpufreq/policy8/cpuinfo_min_freq 2>/dev/null || echo 500000)

LITTLE_MAX=1704000
BIG_MAX=2367000
PRIME_MAX=2914000

# ============================================================================
# Resolve cluster config
# ============================================================================
case "$CLUSTER" in
    little|LITTLE)
        TARGET_CPUS="$LITTLE_CPUS"
        TARGET_POLICY=$LITTLE_POLICY
        TARGET_MAX_FREQ=$LITTLE_MAX_FREQ
        TARGET_THREADS=3
        TARGET_TASKSET="0f"
        HOUSEKEEPING_CPU=0
        OFFLINE_CPUS="4 5 6 7 8"
        ACTIVE_CLUSTER="little"
        CLUSTER_LABEL="Little (cpu0-3, Cortex-A510, max ${LITTLE_MAX_FREQ}kHz)"
        ;;
    big|BIG)
        TARGET_CPUS="$BIG_CPUS"
        TARGET_POLICY=$BIG_POLICY
        TARGET_MAX_FREQ=$BIG_MAX_FREQ
        TARGET_THREADS=4
        TARGET_TASKSET="f0"
        HOUSEKEEPING_CPU=0
        OFFLINE_CPUS="1 2 3 8"
        ACTIVE_CLUSTER="big"
        CLUSTER_LABEL="Big (cpu4-7, Cortex-A715, max ${BIG_MAX_FREQ}kHz)"
        ;;
    prime|PRIME)
        TARGET_CPUS="$PRIME_CPUS"
        TARGET_POLICY=$PRIME_POLICY
        TARGET_MAX_FREQ=$PRIME_MAX_FREQ
        TARGET_THREADS=1
        TARGET_TASKSET="100"
        HOUSEKEEPING_CPU=0
        OFFLINE_CPUS="1 2 3 4 5 6 7"
        ACTIVE_CLUSTER="prime"
        CLUSTER_LABEL="Prime (cpu8, Cortex-X3, max ${PRIME_MAX_FREQ}kHz)"
        ;;
    prime_nooffline|PRIME_NOOFFLINE)
        TARGET_CPUS="$PRIME_CPUS"
        TARGET_POLICY=$PRIME_POLICY
        TARGET_MAX_FREQ=$PRIME_MAX_FREQ
        TARGET_THREADS=1
        TARGET_TASKSET="100"
        HOUSEKEEPING_CPU=0
        OFFLINE_CPUS=""
        ACTIVE_CLUSTER="prime_nooffline"
        CLUSTER_LABEL="Prime nooffline (cpu8, Cortex-X3, schedutil, little+big at min freq)"
        ;;
    prime_big3|PRIME_BIG3)
        TARGET_CPUS="8 5 6 7"
        TARGET_POLICY=$PRIME_POLICY
        TARGET_MAX_FREQ=$PRIME_MAX_FREQ
        TARGET_THREADS=4
        MASK_CPU5=$(core_mask 5)
        MASK_CPU6=$(core_mask 6)
        MASK_CPU7=$(core_mask 7)
        MASK_CPU8=$(core_mask 8)
        TARGET_TASKSET=$(printf "%x" $(( 0x$MASK_CPU5 | 0x$MASK_CPU6 | 0x$MASK_CPU7 | 0x$MASK_CPU8 )))
        HOUSEKEEPING_CPU=0
        OFFLINE_CPUS="1 2 3 4"
        ACTIVE_CLUSTER="prime_big3"
        CLUSTER_LABEL="Prime+Big3 (cpu5-7+cpu8, Prime pinned max, Big schedutil)"
        ;;
    free|FREE|os|OS)
        TARGET_CPUS="0 1 2 3 4 5 6 7 8"
        TARGET_POLICY=""
        TARGET_MAX_FREQ=""
        TARGET_THREADS=4
        TARGET_TASKSET=""
        HOUSEKEEPING_CPU=0
        OFFLINE_CPUS=""
        ACTIVE_CLUSTER="free"
        CLUSTER_LABEL="Free (OS scheduler, all clusters available)"
        ;;
    *)
        log_error "Unknown cluster: '$CLUSTER'. Choose: little | big | prime | prime_nooffline | prime_big3 | free"
        exit 1
        ;;
esac

OUT_DIR="$DATA_DIR/ml_inference"
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/ml_inference_power_${CLUSTER}.csv"
RESULT_FILE="$OUT_DIR/inference_result_${CLUSTER}.txt"
ENERGY_FILE="$OUT_DIR/inference_energy_${CLUSTER}.txt"
BENCHMARK_PID=""

# ============================================================================
# Sanity checks
# ============================================================================
[ -x "$BENCHMARK" ] || {
    log_error "benchmark_model not found at $BENCHMARK"
    exit 1
}
[ -f "$MODEL" ] || {
    log_error "Model not found at $MODEL"
    exit 1
}

# ============================================================================
# Setup
# ============================================================================
log_info "=== ML Inference Power Measurement (merged) ==="
log_info "Model:         $(basename $MODEL)"
log_info "Duration:      ${DURATION}s inference  +  ${IDLE_DURATION}s idle baseline"
log_info "Cluster:       $CLUSTER_LABEL"
log_info "Sample rate:   every ${INTERVAL}s"
[ -n "$TARGET_TASKSET" ] && log_info "Taskset:  0x${TARGET_TASKSET}" || log_info "Taskset:  none (free scheduling)"

pm stay-awake true >/dev/null 2>&1 || svc power stayon true >/dev/null 2>&1 || true
stop_thermal_hal

cleanup() {
    log_info "Cleanup: restoring device state"
    # Kill benchmark if still running
    [ -n "$BENCHMARK_PID" ] && kill "$BENCHMARK_PID" 2>/dev/null || true
    for c in 0 1 2 3 4 5 6 7 8; do
        f="/sys/devices/system/cpu/cpu${c}/online"
        [ -e "$f" ] && echo 1 > "$f" 2>/dev/null || true
    done
    echo schedutil > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || true
    echo schedutil > /sys/devices/system/cpu/cpufreq/policy4/scaling_governor 2>/dev/null || true
    echo schedutil > /sys/devices/system/cpu/cpufreq/policy8/scaling_governor 2>/dev/null || true
    echo $LITTLE_MAX_FREQ > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || true
    echo $BIG_MAX_FREQ    > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq 2>/dev/null || true
    echo $PRIME_MAX_FREQ  > /sys/devices/system/cpu/cpufreq/policy8/scaling_max_freq 2>/dev/null || true
    start_thermal_hal
    pm stay-awake false >/dev/null 2>&1 || svc power stayon false >/dev/null 2>&1 || true
    log_ok "Done"
}
trap cleanup INT TERM EXIT

# ============================================================================
# Reset cpuset restrictions
# ============================================================================
log_info "Resetting cpuset restrictions..."
for cset in /dev/cpuset/cpus \
            /dev/cpuset/foreground/cpus \
            /dev/cpuset/top-app/cpus \
            /dev/cpuset/background/cpus \
            /dev/cpuset/system-background/cpus \
            /dev/cpuset/restricted/cpus; do
    [ -e "$cset" ] && echo 0-8 > "$cset" 2>/dev/null
done

# ============================================================================
# CPU configuration
# ============================================================================
log_info "Configuring CPUs for cluster: $CLUSTER..."

for c in 0 1 2 3 4 5 6 7 8; do
    f="/sys/devices/system/cpu/cpu${c}/online"
    [ -e "$f" ] && echo 1 > "$f" 2>/dev/null || true
done

for c in $OFFLINE_CPUS; do
    [ "$c" = "0" ] && continue
    f="/sys/devices/system/cpu/cpu${c}/online"
    [ -e "$f" ] && echo 0 > "$f" 2>/dev/null && log_info "  Offlined cpu${c}" || true
done

# ----------------------------------------------------------------------------
# Configure the TARGET cluster (and any composite-mode siblings)
# ----------------------------------------------------------------------------
if [ -n "$TARGET_POLICY" ]; then
    if [ "$CLUSTER" = "prime_nooffline" ]; then
        chmod 666 /sys/devices/system/cpu/cpufreq/policy${TARGET_POLICY}/scaling_min_freq 2>/dev/null
        chmod 666 /sys/devices/system/cpu/cpufreq/policy${TARGET_POLICY}/scaling_max_freq 2>/dev/null
        echo schedutil > /sys/devices/system/cpu/cpufreq/policy${TARGET_POLICY}/scaling_governor
        echo ${PRIME_MIN_FREQ} > /sys/devices/system/cpu/cpufreq/policy${TARGET_POLICY}/scaling_min_freq
        echo ${PRIME_MAX_FREQ} > /sys/devices/system/cpu/cpufreq/policy${TARGET_POLICY}/scaling_max_freq
        log_info "  Prime under schedutil (min=${PRIME_MIN_FREQ} max=${PRIME_MAX_FREQ} kHz)"
    elif [ "$CLUSTER" = "prime_big3" ]; then
        pin_frequency "prime" "$PRIME_MAX_FREQ"
        log_info "  Prime pinned to ${PRIME_MAX_FREQ} kHz"
        chmod 666 /sys/devices/system/cpu/cpufreq/policy${BIG_POLICY}/scaling_min_freq 2>/dev/null
        chmod 666 /sys/devices/system/cpu/cpufreq/policy${BIG_POLICY}/scaling_max_freq 2>/dev/null
        echo schedutil > /sys/devices/system/cpu/cpufreq/policy${BIG_POLICY}/scaling_governor 2>/dev/null
        echo ${BIG_MIN_FREQ} > /sys/devices/system/cpu/cpufreq/policy${BIG_POLICY}/scaling_min_freq 2>/dev/null
        echo ${BIG_MAX_FREQ} > /sys/devices/system/cpu/cpufreq/policy${BIG_POLICY}/scaling_max_freq 2>/dev/null
        log_info "  Big (cpu5-7) under schedutil (min=${BIG_MIN_FREQ} max=${BIG_MAX_FREQ} kHz)"
        pin_frequency "little" "$LITTLE_MIN_FREQ"
        log_info "  Little pinned to min freq (${LITTLE_MIN_FREQ} kHz)"
    else
        pin_frequency "$CLUSTER" "$TARGET_MAX_FREQ"
        log_info "  Pinned policy${TARGET_POLICY} to ${TARGET_MAX_FREQ} kHz"
    fi
fi

# ----------------------------------------------------------------------------
# Pin inactive (non-target) clusters to their minimum frequency.
#
# Each cluster is pinned to min ONLY when it is NOT the active target and
# NOT managed separately by a composite mode:
#   - prime_big3      manages little (min) and big (schedutil) in its own block
#   - prime_nooffline manages prime (schedutil) in its own block
# The key fix: the prime block now excludes CLUSTER="prime" so a prime run
# does not overwrite the max-frequency pin set above.
# ----------------------------------------------------------------------------
if [ "$CLUSTER" != "free" ]; then

    # --- Little: skip if Little is target, or prime_big3 (handled above) ---
    if [ "$CLUSTER" != "little" ] && [ "$CLUSTER" != "prime_big3" ]; then
        pin_frequency "little" "$LITTLE_MIN_FREQ"
        log_info "  Little pinned to min freq (${LITTLE_MIN_FREQ} kHz)"
    fi

    # --- Big: skip if Big is target, or prime_big3 (handled above) ---
    if [ "$CLUSTER" != "big" ] && [ "$CLUSTER" != "prime_big3" ]; then
        pin_frequency "big" "$BIG_MIN_FREQ"
        log_info "  Big pinned to min freq (${BIG_MIN_FREQ} kHz)"
    fi

    # --- Prime: skip if Prime is target in ANY prime mode ---
    #     prime           -> target at max (do NOT pin min)  [the original bug]
    #     prime_nooffline -> managed under schedutil above   (do NOT pin min)
    #     prime_big3      -> pinned to max above             (do NOT pin min)
    if [ "$CLUSTER" != "prime" ] && \
       [ "$CLUSTER" != "prime_nooffline" ] && \
       [ "$CLUSTER" != "prime_big3" ] && \
       [ -e /sys/devices/system/cpu/cpufreq/policy8 ]; then
        pin_frequency "prime" "$PRIME_MIN_FREQ"
        log_info "  Prime pinned to min freq (${PRIME_MIN_FREQ} kHz)"
    fi
fi

sleep 2

# ============================================================================
# Verify  (runs AFTER all pinning so it validates the final state)
# ============================================================================
log_info "=== Verification ==="
log_info "  Online CPUs:   $(cat /sys/devices/system/cpu/online 2>/dev/null)"
log_info "  Little freq:   $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null) kHz"
log_info "  Big freq:      $(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq 2>/dev/null) kHz"
[ -e /sys/devices/system/cpu/cpufreq/policy8 ] && \
log_info "  Prime freq:    $(cat /sys/devices/system/cpu/cpufreq/policy8/scaling_cur_freq 2>/dev/null) kHz"

if [ -n "$TARGET_POLICY" ] && [ "$CLUSTER" != "prime_nooffline" ] && [ "$CLUSTER" != "prime_big3" ]; then
    verify_frequency "$CLUSTER" "$TARGET_MAX_FREQ" || {
        log_error "Target cluster NOT at max freq. Aborting."
        exit 1
    }
    log_ok "  Target cluster at correct frequency."
fi

# ============================================================================
# Cool down
# ============================================================================
log_info "Waiting for device to cool down (target: all zones < 35C)..."
while true; do
    max_temp=0
    for f in /sys/class/thermal/thermal_zone*/temp; do
        t=$(cat "$f" 2>/dev/null || echo 0)
        [ "$t" -gt "$max_temp" ] && max_temp="$t"
    done
    max_c=$(( max_temp / 1000 ))
    [ "$max_temp" -le 35000 ] && break
    log_info "  Cooling... ${max_c}C — waiting 15s"
    sleep 15
done
log_ok "Device cooled. Max temp: ${max_c}C"

# Re-pin the target after cool-down (cooling can let governor drift)
if [ -n "$TARGET_POLICY" ] && [ "$CLUSTER" != "prime_nooffline" ] && [ "$CLUSTER" != "prime_big3" ]; then
    pin_frequency "$CLUSTER" "$TARGET_MAX_FREQ"
elif [ "$CLUSTER" = "prime_big3" ]; then
    pin_frequency "prime" "$PRIME_MAX_FREQ"
fi
for cset in /dev/cpuset/cpus /dev/cpuset/foreground/cpus /dev/cpuset/top-app/cpus; do
    [ -e "$cset" ] && echo 0-8 > "$cset" 2>/dev/null
done
sleep 0.5

# ============================================================================
# ODPM energy counter at start
# ============================================================================
ODPM_DEV=/sys/bus/iio/devices/iio:device1

read_odpm_energy_uj() {
    energy_file="$ODPM_DEV/energy_value"
    [ -f "$energy_file" ] || { echo 0; return; }
    awk -F', ' '
        /^CH1\(/ || /^CH2\(/ || /^CH3\(/ || /^CH9\(/ { sum += $2 }
        END { printf "%.0f", sum+0 }
    ' "$energy_file"
}

# ============================================================================
# CSV header
# ============================================================================
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
} > "$CSV"
log_info "CSV: $CSV"

# ============================================================================
# Logging helpers (from ml_power_logger.sh — unchanged)
# ============================================================================

cpu_usage_from_stat() {
    before="$1"; after="$2"; c="$3"
    printf '%s\n%s\n' "$before" "$after" | awk -v core="cpu${c}" '
        $1 == core && !seen {
            idle1=$5; total1=$2+$3+$4+$5+$6+$7+$8+$9; seen=1; next
        }
        $1 == core && seen {
            idle2=$5; total2=$2+$3+$4+$5+$6+$7+$8+$9
            dt=total2-total1; di=idle2-idle1
            if (dt>0) printf("%.1f", (1.0-di/dt)*100.0)
            else print "0.0"
            exit
        }
        END { if (!seen) print "0.0" }
    '
}

read_cpu_freq() {
    c="$1"
    if [ "$c" != "0" ]; then
        onl="/sys/devices/system/cpu/cpu${c}/online"
        if [ -r "$onl" ] && [ "$(cat "$onl" 2>/dev/null)" != "1" ]; then
            echo "offline"; return
        fi
    fi
    f="/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq"
    [ -r "$f" ] && cat "$f" 2>/dev/null || echo "offline"
}

read_freq_khz() {
    policy="$1"
    case "$policy" in
        0) core=0 ;; 4) core=4 ;; 8) core=8 ;; *) core=0 ;;
    esac
    if [ "$core" != "0" ]; then
        online=$(cat "/sys/devices/system/cpu/cpu${core}/online" 2>/dev/null || echo 1)
        if [ "$online" = "0" ]; then echo 0; return; fi
    fi
    val=$(cat "/sys/devices/system/cpu/cpufreq/policy${policy}/scaling_cur_freq" 2>/dev/null || echo 0)
    if [ "$val" = "0" ]; then
        val=$(cat "/sys/devices/system/cpu/cpufreq/policy${policy}/cpuinfo_cur_freq" 2>/dev/null || echo 0)
    fi
    echo "$val"
}

cluster_avg_usage() {
    cores="$1"; stat_b="$2"; stat_a="$3"
    printf '%s\n%s\n' "$stat_b" "$stat_a" | awk -v cores=" $cores " '
        BEGIN {
            split(cores, c_array, " ")
            for (i in c_array) {
                if (c_array[i] != "") target_cores["cpu" c_array[i]] = 1
            }
        }
        NR <= 9 {
            if ($1 in target_cores) {
                b1[$1] = $5
                bt1[$1] = $2+$3+$4+$5+$6+$7+$8+$9
            }
        }
        NR > 9 {
            if ($1 in target_cores) {
                b2[$1] = $5
                bt2[$1] = $2+$3+$4+$5+$6+$7+$8+$9
                dt = bt2[$1] - bt1[$1]
                di = b2[$1] - b1[$1]
                if (dt > 0) { sum += 100.0*(1.0-di/dt); count++ }
            }
        }
        END {
            if (count > 0) printf("%.4f", sum/count/100.0)
            else print "0.0000"
        }
    '
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

read_ram_power_uw() {
    grep "S1M_VDD_MIF" "$ODPM_MAIN/lpf_power" 2>/dev/null \
        | awk -F', ' '{print $2+0; exit}' || echo 0
}

log_sample() {
    phase="$1"
    workload="$2"

    STAT_BEFORE=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
    sleep "$INTERVAL"
    STAT_AFTER=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)

    TS=$(now_ms)

    POWERS=$(read_all_cluster_powers_uw)
    L_uw=$(echo "$POWERS" | awk '{print $1}')
    B_uw=$(echo "$POWERS" | awk '{print $2}')
    P_uw=$(echo "$POWERS" | awk '{print $3}')
    T_uw=$(echo "$POWERS" | awk '{print $4}')
    Lmain_uw=$(echo "$POWERS" | awk '{print $5}')
    Lmem_uw=$(echo "$POWERS" | awk '{print $6}')
    RAM_uw=$(read_ram_power_uw)

    VOLTS=$(read_all_cluster_voltages_uv)
    VL_uv=$(echo "$VOLTS" | awk '{print $1}')
    VB_uv=$(echo "$VOLTS" | awk '{print $2}')
    VP_uv=$(echo "$VOLTS" | awk '{print $3}')

    TL=$(read_cluster_temp little)
    TB=$(read_cluster_temp big)
    TP=$(read_cluster_temp prime)

    fL=$(read_freq_khz 0)
    fB=$(read_freq_khz 4)
    fP=$(read_freq_khz 8)

    rho_L=$(cluster_avg_usage "$LITTLE_CPUS" "$STAT_BEFORE" "$STAT_AFTER")
    rho_B=$(cluster_avg_usage "$BIG_CPUS"    "$STAT_BEFORE" "$STAT_AFTER")
    rho_P=$(cluster_avg_usage "$PRIME_CPUS"  "$STAT_BEFORE" "$STAT_AFTER")

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
    l_W=$(echo "$POWERS_W"   | awk '{print $1}')
    b_W=$(echo "$POWERS_W"   | awk '{print $2}')
    p_W=$(echo "$POWERS_W"   | awk '{print $3}')
    cpu_W=$(echo "$POWERS_W" | awk '{print $4}')
    lmn_W=$(echo "$POWERS_W" | awk '{print $5}')
    lmem_W=$(echo "$POWERS_W"| awk '{print $6}')
    ram_W=$(echo "$POWERS_W" | awk '{print $7}')

    VOLTAGES_V=$(awk -v vl="$VL_uv" -v vb="$VB_uv" -v vp="$VP_uv" \
        'BEGIN{printf("%.3f %.3f %.3f", vl/1e6, vb/1e6, vp/1e6)}')
    vL=$(echo "$VOLTAGES_V" | awk '{print $1}')
    vB=$(echo "$VOLTAGES_V" | awk '{print $2}')
    vP=$(echo "$VOLTAGES_V" | awk '{print $3}')

    CPU_FREQS=""
    for c in $ALL_CORES; do
        CPU_FREQS="$CPU_FREQS $(read_cpu_freq "$c")"
    done

    CPU_USAGES=""
    for c in $ALL_CORES; do
        CPU_USAGES="$CPU_USAGES $(cpu_usage_from_stat "$STAT_BEFORE" "$STAT_AFTER" "$c")"
    done

    {
        printf "%s,ml_inference,1,%s,%s," "$phase" "$workload" "$ACTIVE_CLUSTER"
        printf "%s,%s,%s,"  "$fL" "$fB" "$fP"
        printf "%s,%s,%s,"  "$rho_L" "$rho_B" "$rho_P"
        printf "%s,"        "$TS"
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s," \
            "$cpu_W" "$l_W" "$b_W" "$p_W" "$lmn_W" "$lmem_W" \
            "$ram_W" "0.000000" "$BP"
        printf "%s,%s,%s,%s," "$vL" "$vB" "$vP" "$BV"
        printf "%s,%s,%s,"    "$RAM_mA" "0.0" "$BI"
        printf "%s,%s,%s,%s"  "$TL" "$TB" "$TP" "$TBat"
        for freq in $CPU_FREQS;  do printf ",%s" "$freq";  done
        for usage in $CPU_USAGES; do printf ",%s" "$usage"; done
        printf "\n"
    } >> "$CSV"
}

# ============================================================================
# Phase 1: Idle baseline
# CPU is fully configured and settled — this is the true idle baseline
# at the same frequency/voltage state as the upcoming inference run.
# ============================================================================
log_info "=== Phase 1: Idle baseline (${IDLE_DURATION}s) ==="
n=0
end_idle=$(( $(now_ms) + IDLE_DURATION * 1000 ))
while [ "$(now_ms)" -lt "$end_idle" ]; do
    log_sample "ml_idle" "idle"
    n=$(( n + 1 ))
done
log_ok "Idle baseline: $n samples"

# ============================================================================
# Phase 2: Inference — start benchmark in background, log while it runs
# ============================================================================
log_info "=== Phase 2: Inference (${DURATION}s) ==="

ODPM_ENERGY_START=$(read_odpm_energy_uj)
T_START=$(now_ms)
log_info "ODPM energy counter at start: ${ODPM_ENERGY_START} uJ"

if [ -n "$TARGET_TASKSET" ]; then
    taskset ${TARGET_TASKSET} "$BENCHMARK" \
        --graph="$MODEL" \
        --num_threads=${TARGET_THREADS} \
        --use_xnnpack=true \
        --min_secs="$DURATION" \
        --max_secs="$DURATION" \
        --warmup_runs=5 \
        --num_runs=9999 \
        > "$RESULT_FILE" 2>&1 &
else
    "$BENCHMARK" \
        --graph="$MODEL" \
        --num_threads=${TARGET_THREADS} \
        --use_xnnpack=true \
        --min_secs="$DURATION" \
        --max_secs="$DURATION" \
        --warmup_runs=5 \
        --num_runs=9999 \
        > "$RESULT_FILE" 2>&1 &
fi
BENCHMARK_PID=$!
log_info "Benchmark PID: $BENCHMARK_PID"

n=0
end_inf=$(( T_START + DURATION * 1000 ))
while [ "$(now_ms)" -lt "$end_inf" ] && kill -0 "$BENCHMARK_PID" 2>/dev/null; do
    log_sample "ml_inference" "stress"
    n=$(( n + 1 ))
done

wait "$BENCHMARK_PID" 2>/dev/null
BENCHMARK_PID=""

ODPM_ENERGY_END=$(read_odpm_energy_uj)
T_END=$(now_ms)
log_ok "Inference: $n samples"

# ============================================================================
# Phase 3: Cooldown (10s)
# ============================================================================
log_info "=== Phase 3: Cooldown (10s) ==="
n=0
end_cool=$(( $(now_ms) + 10 * 1000 ))
while [ "$(now_ms)" -lt "$end_cool" ]; do
    log_sample "ml_cool" "idle"
    n=$(( n + 1 ))
done
log_ok "Cooldown: $n samples"

# ============================================================================
# Energy report
# ============================================================================
DURATION_MS=$(( T_END - T_START ))
DURATION_S=$(awk -v ms="$DURATION_MS" 'BEGIN{printf("%.3f", ms/1000)}')
ENERGY_UJ=$(( ODPM_ENERGY_END - ODPM_ENERGY_START ))
ENERGY_J=$(awk -v uj="$ENERGY_UJ" 'BEGIN{printf("%.6f", uj/1e6)}')
MEAN_POWER_W=$(awk -v ej="$ENERGY_J" -v ds="$DURATION_S" \
    'BEGIN{if(ds>0) printf("%.4f", ej/ds); else print "0"}')

AVG_US=$(grep "Inference (avg)" "$RESULT_FILE" 2>/dev/null | \
    grep -o "Inference (avg): [0-9.]*" | awk '{print $NF}')
if [ -n "$AVG_US" ] && [ "$AVG_US" != "0" ]; then
    IPS=$(awk -v us="$AVG_US" 'BEGIN{printf("%.2f", 1e6/us)}')
    NUM_INF=$(awk -v dur="$DURATION_S" -v ips="$IPS" 'BEGIN{printf("%.0f", dur*ips)}')
    ENERGY_PER_INF_MJ=$(awk -v e="$ENERGY_UJ" -v n="$NUM_INF" \
        'BEGIN{if(n>0) printf("%.4f", e/n/1000); else print "N/A"}')
else
    IPS="N/A"; NUM_INF="N/A"; ENERGY_PER_INF_MJ="N/A"
fi

{
    echo "==================================================="
    echo " ML Inference Energy Report"
    echo "==================================================="
    echo " Model:            $(basename $MODEL)"
    echo " Cluster:          $CLUSTER_LABEL"
    echo " Threads:          $TARGET_THREADS"
    echo " Idle duration:    ${IDLE_DURATION}s"
    echo " Inference:        ${DURATION_S}s"
    echo "---------------------------------------------------"
    echo " ODPM CPU Energy:"
    echo "   Start:          ${ODPM_ENERGY_START} uJ"
    echo "   End:            ${ODPM_ENERGY_END} uJ"
    echo "   Delta:          ${ENERGY_UJ} uJ  =  ${ENERGY_J} J"
    echo "   Mean power:     ${MEAN_POWER_W} W"
    echo "---------------------------------------------------"
    echo " Inference metrics:"
    echo "   Avg latency:    ${AVG_US} us"
    echo "   Throughput:     ${IPS} inferences/s"
    echo "   Est. count:     ${NUM_INF} inferences"
    echo "   Energy/inf:     ${ENERGY_PER_INF_MJ} mJ"
    echo "---------------------------------------------------"
    echo " Raw benchmark output:"
    grep -E "Inference \(avg\)|count=|avg=" "$RESULT_FILE" 2>/dev/null | tail -5
    echo "==================================================="
} | tee "$ENERGY_FILE"

log_ok "CSV:          $CSV  ($(wc -l < "$CSV") rows)"
log_ok "Energy report: $ENERGY_FILE"
log_ok "Benchmark log: $RESULT_FILE"