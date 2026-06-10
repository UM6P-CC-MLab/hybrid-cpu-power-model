# lib/odpm.sh - ODPM power rail readers for Pixel 8 Pro (Tensor G3)
# Requires: common.sh sourced first.
#
# ODPM channel map (iio:device1/lpf_power and energy_value):
#   CH1  S2M_VDD_CPUCL2      -> Prime
#   CH2  S3M_VDD_CPUCL1      -> Big
#   CH3  S4M_VDD_CPUCL0      -> Little
#   CH9  S9M_VDD_CPUCL0_M    -> Little memory/L3 (counted as part of Little)
#   CH0  S1M_VDD_MIF         -> RAM (DRAM controller)
#
# lpf_power values are microwatts (uW) — instantaneous low-pass-filtered power.
# lpf_current values are milliamps (mA).
# energy_value values are microjoules (uJ) — MONOTONIC cumulative since boot.
#
# Use lpf_power for instantaneous readings; use energy_value diffs for
# accurate window-averaged power (no aliasing, exact integration).

# --- Per-cluster power readers ---------------------------------------------

# Read a single ODPM channel power (uW) by grep pattern
# Usage: read_odpm_channel_uw <pattern> <device_file>
read_odpm_channel_uw() {
  pattern="$1"; file="$2"
  grep "$pattern" "$file" 2>/dev/null | awk -F', ' '{print $2+0; exit}' || echo 0
}

# Read power for a specific cluster (uW), including Little's L3/memory rail.
# Usage: read_cluster_power_uw <cluster>
read_cluster_power_uw() {
  cluster="$1"
  case "$cluster" in
    little)
      main=$(read_odpm_channel_uw "CPUCL0\]"  "$ODPM_MAIN/lpf_power")
      case "$DEVICE_MODEL" in
        "Pixel 9"*)
          # No little_mem rail on Pixel 9
          echo "${main:-0}"
          ;;
        *)
          mem=$(read_odpm_channel_uw "CPUCL0_M" "$ODPM_MAIN/lpf_power")
          awk -v a="${main:-0}" -v b="${mem:-0}" 'BEGIN{print a+b}'
          ;;
      esac
      ;;
    big)
      main=$(read_odpm_channel_uw "CPUCL1\]" "$ODPM_MAIN/lpf_power")
      case "$DEVICE_MODEL" in
        "Pixel 9"*)
          mem=$(read_odpm_channel_uw "CPUCL1_M" "$ODPM_MAIN/lpf_power")
          awk -v a="${main:-0}" -v b="${mem:-0}" 'BEGIN{print a+b}'
          ;;
        *)
          echo "${main:-0}"
          ;;
      esac
      ;;
    prime)
      read_odpm_channel_uw "CPUCL2\]" "$ODPM_MAIN/lpf_power"
      ;;
  esac
}
# Read all three cluster powers in one pass, plus total CPU power.
# Returns: "little_uW big_uW prime_uW total_uW little_main_uW little_mem_uW"
# Uses one grep per channel on the same file (fast enough).
read_all_cluster_powers_uw() {
  f="$ODPM_MAIN/lpf_power"
  l_main=$(read_odpm_channel_uw "CPUCL0\]"  "$f")
  l_mem=$(read_odpm_channel_uw  "CPUCL0_M"  "$f")
  b=$(read_odpm_channel_uw      "CPUCL1\]"  "$f")
  p=$(read_odpm_channel_uw      "CPUCL2\]"  "$f")
  awk -v lm="${l_main:-0}" -v lc="${l_mem:-0}" -v b="${b:-0}" -v p="${p:-0}" \
    'BEGIN{ l = lm + lc; printf("%d %d %d %d %d %d", l, b, p, l+b+p, lm, lc) }'
}

# --- Energy counters (cumulative uJ) ---------------------------------------
# Read the four CPU-relevant rail energy counters in microjoules from
# iio:device1/energy_value. Format example:
#   CH3(T=1305699856)[S4M_VDD_CPUCL0], 43359307733
#
# These are MONOTONIC counters since boot. To compute the window-averaged
# power between two reads at times t1 and t2 (in seconds):
#   P_avg_W = (E2 - E1) / (t2 - t1) / 1e6
#
# Returns: "little_main_uJ little_mem_uJ big_uJ prime_uJ"
read_cpu_energy_counters_uj() {
  f="$ODPM_MAIN/energy_value"
  if [ ! -r "$f" ]; then
    echo "0 0 0 0"
    return
  fi
  # Format: "CHn(T=...)[NAME], value"  →  awk -F', ' on $2.
  # Match exactly the same patterns used for lpf_power so channel mapping
  # stays consistent.
  cat "$f" 2>/dev/null | awk -F', ' '
    /\[S4M_VDD_CPUCL0\]/      { lm = $2+0 }   # CH3 - Little main
    /\[S9M_VDD_CPUCL0_M\]/    { lc = $2+0 }   # CH9 - Little mem
    /\[S3M_VDD_CPUCL1\]/      { b  = $2+0 }   # CH2 - Big
    /\[S2M_VDD_CPUCL2\]/      { p  = $2+0 }   # CH1 - Prime
    END { printf("%d %d %d %d\n", lm+0, lc+0, b+0, p+0) }

  '
}

# --- Per-cluster voltage (correct way; avoids the total-power/single-V bug) --
# Read a cluster's supply voltage in microvolts.
# Usage: read_cluster_voltage_uv <cluster>
read_cluster_voltage_uv() {
  cluster="$1"
  reg=$(cluster_regulator "$cluster")
  f="/sys/class/regulator/regulator.${reg}/microvolts"
  [ -r "$f" ] && cat "$f" 2>/dev/null || echo 0
}

# Read all three cluster voltages (uV).
# Returns: "little_uV big_uV prime_uV"
read_all_cluster_voltages_uv() {
  l=$(read_cluster_voltage_uv little)
  b=$(read_cluster_voltage_uv big)
  p=$(read_cluster_voltage_uv prime)
  echo "${l:-0} ${b:-0} ${p:-0}"
}

# --- RAM (MIF) readers ------------------------------------------------------
read_ram_current_ma() {
  grep "CH0\[S1M_VDD_MIF\]" "$ODPM_MAIN/lpf_current" 2>/dev/null \
    | awk -F', ' '{printf("%.1f", $2); exit}'
}

read_ram_power_uw() {
  grep "CH0\[S1M_VDD_MIF\]" "$ODPM_MAIN/lpf_power" 2>/dev/null \
    | awk -F', ' '{print $2+0; exit}' || echo 0
}

# --- System power (sum of peripheral rails) ---------------------------------
# Same channel groupings as your existing script. Returns uW.
read_system_power_uw() {
  s1=$(grep -E "CH4\[|CH6\[|CH8\[|CH10\[|CH11\[" "$ODPM_MAIN/lpf_power" 2>/dev/null \
    | awk -F', ' '{sum += $2+0} END {printf("%.0f", sum)}')
  s0=$(grep -E "CH0\[|CH1\[|CH4\[|CH5\[|CH9\[|CH10\[|CH11\[" "$ODPM_PERI/lpf_power" 2>/dev/null \
    | awk -F', ' '{sum += $2+0} END {printf("%.0f", sum)}')
  awk -v a="${s1:-0}" -v b="${s0:-0}" 'BEGIN{printf("%d", a+b)}'
}

read_system_current_ma() {
  s1=$(grep -E "CH4\[|CH6\[|CH8\[|CH10\[|CH11\[" "$ODPM_MAIN/lpf_current" 2>/dev/null \
    | awk -F', ' '{sum += $2+0} END {printf("%.1f", sum)}')
  s0=$(grep -E "CH0\[|CH1\[|CH4\[|CH5\[|CH9\[|CH10\[|CH11\[" "$ODPM_PERI/lpf_current" 2>/dev/null \
    | awk -F', ' '{sum += $2+0} END {printf("%.1f", sum)}')
  awk -v a="${s1:-0}" -v b="${s0:-0}" 'BEGIN{printf("%.1f", a+b)}'
}

# --- Battery readers --------------------------------------------------------
read_batt_voltage_uv() {
  if [ -r /sys/class/power_supply/battery/voltage_now ]; then
    cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0
  else
    MV="$(dumpsys battery 2>/dev/null | awk 'tolower($0) ~ /^ *voltage/ {print $2; exit}')"
    [ -n "$MV" ] || MV=0
    echo $(( MV * 1000 ))
  fi
}

read_batt_current_ua() {
  I=""
  if [ -r /sys/class/power_supply/battery/current_now ]; then
    I="$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)"
  elif [ -r /sys/class/power_supply/battery/current_avg ]; then
    I="$(cat /sys/class/power_supply/battery/current_avg 2>/dev/null)"
  else
    I="$(dumpsys battery 2>/dev/null | awk 'tolower($0) ~ /current now/ {print $3; exit}')"
  fi
  [ -n "$I" ] || I=0
  case "$I" in -*) I="${I#-}";; esac
  echo "$I"
}

# Returns: "batt_V batt_mA batt_W"
read_battery_metrics() {
  V_uV=$(read_batt_voltage_uv)
  I_uA=$(read_batt_current_ua)
  awk -v v="$V_uV" -v i="$I_uA" 'BEGIN {
    V_v  = v / 1000000.0
    I_ma = i / 1000.0
    P_w  = (v * i) / 1e12
    printf("%.3f %.1f %.6f", V_v, I_ma, P_w)
  }'
}