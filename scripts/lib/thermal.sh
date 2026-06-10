# lib/thermal.sh - Thermal monitoring and baseline management
# Requires: common.sh, freq_control.sh, stress.sh sourced first.
#
# Per-cluster thermal zones:
#   thermal_zone2 = LITTLE (Little cluster)
#   thermal_zone1 = MID    (Big cluster)
#   thermal_zone0 = BIG    (Prime core)

# Read temperature for a specific cluster (degrees C).
# Usage: read_cluster_temp <cluster>
read_cluster_temp() {
  cluster="$1"
  zone=$(cluster_thermal_zone "$cluster")
  raw=$(cat "/sys/class/thermal/thermal_zone${zone}/temp" 2>/dev/null)
  [ -n "$raw" ] || raw=0
  awk -v x="$raw" 'BEGIN{printf("%.1f", x/1000.0)}'
}

# Read battery temperature (degrees C).
read_batt_temp() {
  raw=""
  if [ -r /sys/class/power_supply/battery/temp ]; then
    raw="$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
  else
    raw="$(dumpsys battery 2>/dev/null | awk 'tolower($0) ~ /^ *temperature/ {print $2; exit}')"
  fi
  [ -n "$raw" ] || raw=0
  abs_raw="${raw#-}"
  if [ "$abs_raw" -ge 1000 ]; then
    awk -v x="$raw" 'BEGIN{printf("%.1f", x/1000.0)}'
  else
    awk -v x="$raw" 'BEGIN{printf("%.1f", x/10.0)}'
  fi
}

# Read the max temperature across all three cluster zones.
read_max_cluster_temp() {
  l=$(read_cluster_temp little)
  b=$(read_cluster_temp big)
  p=$(read_cluster_temp prime)
  awk -v a="$l" -v b="$b" -v c="$p" 'BEGIN{
    m=a; if(b>m)m=b; if(c>m)m=c; printf("%.1f", m)
  }'
}

# --- Baseline capture -------------------------------------------------------
# Global: TARGET_TEMP (set here, consumed by wait_for_target_temp)

capture_baseline_temp() {
  log_info "Capturing thermal baseline..."
  online_all
  sleep 5

  TARGET_TEMP=$(read_max_cluster_temp)
  BATT_T=$(read_batt_temp)
  L_T=$(read_cluster_temp little)
  B_T=$(read_cluster_temp big)
  P_T=$(read_cluster_temp prime)

  log_info "Baseline captured:"
  log_info "  Little:  ${L_T}°C"
  log_info "  Big:     ${B_T}°C"
  log_info "  Prime:   ${P_T}°C"
  log_info "  Battery: ${BATT_T}°C"
  log_info "  Target (max cluster): ${TARGET_TEMP}°C ± ${TEMP_TOLERANCE}°C"

  export TARGET_TEMP
}

# --- Active thermal control -------------------------------------------------
# Waits until max cluster temp is within [target - tol, target + tol].
# Actively warms (runs light load on Little) if too cold.
# Actively cools (offlines non-system cores) if too hot.
# Usage: wait_for_target_temp "<reason for log>"
wait_for_target_temp() {
  reason="$1"

  if [ -z "$TARGET_TEMP" ]; then
    log_warn "No thermal baseline set — skipping wait"
    return 0
  fi

  log_info "Thermal control: $reason"
  log_info "  target=${TARGET_TEMP}°C ± ${TEMP_TOLERANCE}°C, max_wait=${MAX_TEMP_WAIT}s"

  TMIN=$(awk -v t="$TARGET_TEMP" -v tol="$TEMP_TOLERANCE" 'BEGIN{printf("%.1f", t-tol)}')
  TMAX=$(awk -v t="$TARGET_TEMP" -v tol="$TEMP_TOLERANCE" 'BEGIN{printf("%.1f", t+tol)}')

  # Stop any leftover workload
  stop_stress

  # For cooling: offline non-system cores to minimize heat gen
  for c in $ALL_CORES; do
    [ "$c" != "$SYSTEM_CORE" ] && cpu_set_online "$c" 0
  done

  elapsed=0
  warmup_active=0

  while [ "$elapsed" -lt "$MAX_TEMP_WAIT" ]; do
    CUR=$(read_max_cluster_temp)
    BAT=$(read_batt_temp)
    DELTA=$(awk -v c="$CUR" -v t="$TARGET_TEMP" 'BEGIN{printf("%.1f", c-t)}')

    STATE=$(awk -v c="$CUR" -v lo="$TMIN" -v hi="$TMAX" 'BEGIN{
      if (c < lo) print "COLD";
      else if (c > hi) print "HOT";
      else print "OK";
    }')

    if [ "$STATE" = "OK" ]; then
      if [ "$warmup_active" = "1" ]; then
        stop_stress
        warmup_active=0
      fi
      printf "\r" >&2
      log_ok "Thermal OK at ${CUR}°C (Δ${DELTA}°C) after ${elapsed}s"
      online_all
      return 0
    fi

    if [ "$STATE" = "COLD" ]; then
      if [ "$warmup_active" = "0" ]; then
        # Gentle warming: online Little + start small load on cpu1
        online_cluster little
        cpu_set_online 1 1
        start_stress_on_cpu 1 >/dev/null  # warm with cpu1 only
        warmup_active=1
      fi
      printf "\r  warmup   %3ds  max=%.1f°C (Δ%+.1f)  batt=%.1f°C        " \
        "$elapsed" "$CUR" "$DELTA" "$BAT" >&2
    else
      if [ "$warmup_active" = "1" ]; then
        stop_stress
        warmup_active=0
      fi
      printf "\r  cooldown %3ds  max=%.1f°C (Δ%+.1f)  batt=%.1f°C        " \
        "$elapsed" "$CUR" "$DELTA" "$BAT" >&2
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  printf "\n" >&2
  [ "$warmup_active" = "1" ] && stop_stress
  log_warn "Thermal target not reached in ${MAX_TEMP_WAIT}s (cur=${CUR}°C, target=${TARGET_TEMP}°C)"
  log_warn "Proceeding anyway."
  online_all
  return 1
}