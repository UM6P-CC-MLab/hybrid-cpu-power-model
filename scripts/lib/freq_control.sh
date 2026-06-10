# lib/freq_control.sh - Frequency pinning and cluster online/offline
# Requires: common.sh sourced first

# Set governor on a cluster
# Usage: set_governor <cluster> <governor>
set_governor() {
  cluster="$1"; gov="$2"
  policy="$(cluster_policy "$cluster")"
  echo "$gov" > "/sys/devices/system/cpu/cpufreq/policy${policy}/scaling_governor"
  cur="$(cat "/sys/devices/system/cpu/cpufreq/policy${policy}/scaling_governor")"
  if [ "$cur" != "$gov" ]; then
    log_error "Failed to set governor on $cluster: requested=$gov got=$cur"
    return 1
  fi
}

# List available frequencies for a cluster (kHz, space-separated)
# Usage: list_freqs <cluster>
list_freqs() {
  cluster="$1"
  policy="$(cluster_policy "$cluster")"
  cat "/sys/devices/system/cpu/cpufreq/policy${policy}/scaling_available_frequencies"
}

# Pin a cluster to a specific frequency (kHz).
# Handles min/max ordering: we always lower min to cpuinfo_min_freq first,
# then set max to target, then raise min to target. This avoids the case
# where the kernel rejects a write because new_max < current_min or vice versa.
# Usage: pin_frequency <cluster> <freq_khz>
pin_frequency() {
  cluster="$1"; target="$2"
  policy="$(cluster_policy "$cluster")"
  pdir="/sys/devices/system/cpu/cpufreq/policy${policy}"

  # Ensure sysfs files are writable
  chmod 666 "$pdir/scaling_min_freq" 2>/dev/null || true
  chmod 666 "$pdir/scaling_max_freq" 2>/dev/null || true
  chmod 666 "$pdir/scaling_governor" 2>/dev/null || true

  # Ensure performance governor is set (needed for min=max pinning to stick)
  cur_gov="$(cat "$pdir/scaling_governor")"
  if [ "$cur_gov" != "performance" ]; then
    echo "performance" > "$pdir/scaling_governor"
  fi

  cpuinfo_min="$(cat "$pdir/cpuinfo_min_freq")"

  # Step 1: drop min to floor
  echo "$cpuinfo_min" > "$pdir/scaling_min_freq"
  # Step 2: set max to target
  echo "$target"     > "$pdir/scaling_max_freq"
  # Step 3: raise min to target
  echo "$target"     > "$pdir/scaling_min_freq"
}

# Verify that a cluster is actually running at the requested frequency.
# Allows ±1 step tolerance (governor may have snapped).
# Returns 0 if OK, 1 if mismatch. Prints actual freq on stderr.
# Usage: verify_frequency <cluster> <expected_khz>
verify_frequency() {
  cluster="$1"; expected="$2"
  policy="$(cluster_policy "$cluster")"
  cur="$(cat "/sys/devices/system/cpu/cpufreq/policy${policy}/scaling_cur_freq")"
  if [ "$cur" = "$expected" ]; then
    return 0
  fi
  # Tolerate drift within 1% of expected
  diff_pct=$(awk -v a="$cur" -v b="$expected" 'BEGIN{
    d=a-b; if(d<0)d=-d; printf("%.2f", d*100.0/b)
  }')
  warn_msg="freq drift: cluster=$cluster expected=$expected got=$cur (${diff_pct}% off)"
  log_warn "$warn_msg"
  # Return 1 only if drift > 5%
  awk -v d="$diff_pct" 'BEGIN{ exit (d<=5.0)?0:1 }'
}

# Bring a CPU online (can't offline cpu0)
# Usage: cpu_set_online <cpu_id> <0|1>
cpu_set_online() {
  c="$1"; val="$2"
  [ "$c" = "0" ] && return 0   # cpu0 always on
  f="/sys/devices/system/cpu/cpu${c}/online"
  [ -w "$f" ] && echo "$val" > "$f" 2>/dev/null || true
}

# Offline all CPUs in a cluster (except cpu0 if it's in the cluster)
# Usage: offline_cluster <cluster>
offline_cluster() {
  cluster="$1"
  for c in $(cluster_cpus "$cluster"); do
    cpu_set_online "$c" 0
  done
}

# Online all CPUs in a cluster
# Usage: online_cluster <cluster>
online_cluster() {
  cluster="$1"
  for c in $(cluster_cpus "$cluster"); do
    cpu_set_online "$c" 1
  done
}

# Bring entire system online
online_all() {
  for c in $ALL_CORES; do
    cpu_set_online "$c" 1
  done
}

# Report current state of all clusters (for logging/debugging)
report_cluster_state() {
  for cluster in $CLUSTERS; do
    policy="$(cluster_policy "$cluster")"
    pdir="/sys/devices/system/cpu/cpufreq/policy${policy}"
    gov="$(cat "$pdir/scaling_governor" 2>/dev/null || echo '?')"
    cur="$(cat "$pdir/scaling_cur_freq" 2>/dev/null || echo '?')"
    min="$(cat "$pdir/scaling_min_freq" 2>/dev/null || echo '?')"
    max="$(cat "$pdir/scaling_max_freq" 2>/dev/null || echo '?')"
    cpus=""
    for c in $(cluster_cpus "$cluster"); do
      online=$([ "$c" = "0" ] && echo "1" || cat "/sys/devices/system/cpu/cpu${c}/online" 2>/dev/null || echo "?")
      cpus="${cpus}cpu${c}=${online} "
    done
    echo "  $cluster: gov=$gov cur=$cur min=$min max=$max $cpus"
  done
}

# Thermal HAL control - Pixel-specific
stop_thermal_hal() {
  stop vendor.thermal-hal-2-0 2>/dev/null || true
  stop thermal-hal-2-0 2>/dev/null || true
  stop thermal-engine 2>/dev/null || true
  log_info "Thermal HAL stopped (if running)"
}

start_thermal_hal() {
  start vendor.thermal-hal-2-0 2>/dev/null || true
  start thermal-hal-2-0 2>/dev/null || true
  start thermal-engine 2>/dev/null || true
  log_info "Thermal HAL restarted"
}