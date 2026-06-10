# lib/measure.sh - Sampling loop. Writes CSV rows with full experimental context.
# Requires: common.sh, odpm.sh, thermal.sh, freq_control.sh sourced first.
#
# CSV schema (one row per sample):
#
#   phase             e.g. "little_idle", "little_stress", "combined_idle",
#                         "combined_stress", "validation_idle", "validation_stress"
#   config_id         unique id for this configuration (same for idle+stress pair)
#   rep               repetition number
#   workload          "idle" | "stress"   (redundant with phase suffix, easier to filter)
#   active_clusters   comma-separated: e.g. "little" or "little,big,prime"
#   f_little_kHz      pinned freq or 0 if offline
#   f_big_kHz         pinned freq or 0 if offline
#   f_prime_kHz       pinned freq or 0 if offline
#   rho_little        f_little / max_little (0 if offline)
#   rho_big           f_big    / max_big    (0 if offline)
#   rho_prime         f_prime  / max_prime  (0 if offline)
#   timestamp_ms
#   -- powers (W, lpf snapshots) --
#   cpu_total_W       sum of three cluster rails
#   little_W
#   big_W
#   prime_W
#   little_main_W     Little CPU rail only (no memory)
#   little_mem_W      Little L3/memory rail
#   ram_W             MIF rail
#   system_W          sum of peripheral rails
#   batt_W
#   -- voltages (V) --
#   v_little_V
#   v_big_V
#   v_prime_V
#   batt_V
#   -- currents (mA) --
#   ram_mA
#   system_mA
#   batt_mA
#   -- temperatures (C) --
#   t_little_C
#   t_big_C
#   t_prime_C
#   t_batt_C
#   -- energy counters (uJ, cumulative since boot) --
#   E_little_main_uJ  CH3 - S4M_VDD_CPUCL0
#   E_little_mem_uJ   CH9 - S9M_VDD_CPUCL0_M
#   E_big_uJ          CH2 - S3M_VDD_CPUCL1
#   E_prime_uJ        CH1 - S2M_VDD_CPUCL2
#   -- per-CPU freqs (kHz) and usage (%) --
#   freq_cpu0 ... freq_cpu8
#   usage_cpu0 ... usage_cpu8

# Write the CSV header to a file.
# Usage: write_csv_header <path>
write_csv_header() {
  path="$1"
  {
    printf "phase,config_id,rep,workload,active_clusters,"
    printf "f_little_kHz,f_big_kHz,f_prime_kHz,"
    printf "rho_little,rho_big,rho_prime,"
    printf "timestamp_ms,"
    printf "cpu_total_W,little_W,big_W,prime_W,little_main_W,little_mem_W,"
    printf "ram_W,system_W,batt_W,"
    printf "v_little_V,v_big_V,v_prime_V,batt_V,"
    printf "ram_mA,system_mA,batt_mA,"
    printf "t_little_C,t_big_C,t_prime_C,t_batt_C,"
    printf "E_little_main_uJ,E_little_mem_uJ,E_big_uJ,E_prime_uJ"
    for c in $ALL_CORES; do printf ",freq_cpu%s" "$c"; done
    for c in $ALL_CORES; do printf ",usage_cpu%s" "$c"; done
    printf "\n"
  } > "$path"
}

# Compute per-CPU usage from two /proc/stat snapshots.
# Usage: cpu_usage_from_stat <before_text> <after_text> <cpu_id>
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

# Read a CPU's current frequency. Returns "offline" if core is down.
# Usage: read_cpu_freq <cpu_id>
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

# Main sampling loop. Writes sample rows to the given CSV.
# Caller has already:
#   - configured cluster online/offline state
#   - pinned frequencies
#   - started (or not) stress workload
#   - verified thermal baseline
#
# Arguments (all passed through to CSV columns):
#   $1  phase              e.g. "little_idle", "little_stress", "combined_idle", ...
#   $2  config_id          unique label for this configuration
#   $3  rep                repetition number
#   $4  workload           "idle" | "stress"
#   $5  active_clusters    comma-separated
#   $6  f_little_kHz       (0 if cluster offline)
#   $7  f_big_kHz
#   $8  f_prime_kHz
#   $9  csv_path
sample_loop() {
  phase="$1"; config_id="$2"; rep="$3"; workload="$4"; active="$5"
  fL="$6"; fB="$7"; fP="$8"; csv="$9"

  # Precompute rho values
  maxL=$(cluster_max_freq_khz little)
  maxB=$(cluster_max_freq_khz big)
  maxP=$(cluster_max_freq_khz prime)
  rL=$(awk -v f="$fL" -v m="$maxL" 'BEGIN{ if(f>0) printf("%.4f", f/m); else print "0.0000" }')
  rB=$(awk -v f="$fB" -v m="$maxB" 'BEGIN{ if(f>0) printf("%.4f", f/m); else print "0.0000" }')
  rP=$(awk -v f="$fP" -v m="$maxP" 'BEGIN{ if(f>0) printf("%.4f", f/m); else print "0.0000" }')

  log_info "Sampling: phase=$phase config=$config_id rep=$rep workload=$workload active=[$active] for ${DURATION_SEC}s"

  END_MS=$(( $(now_ms) + DURATION_SEC * 1000 ))
  n=0

  while [ "$(now_ms)" -lt "$END_MS" ]; do
    TS=$(now_ms)

    # --- One-shot power reads ---
    POWERS=$(read_all_cluster_powers_uw)
    L_uw=$(echo "$POWERS" | awk '{print $1}')
    B_uw=$(echo "$POWERS" | awk '{print $2}')
    P_uw=$(echo "$POWERS" | awk '{print $3}')
    T_uw=$(echo "$POWERS" | awk '{print $4}')
    Lmain_uw=$(echo "$POWERS" | awk '{print $5}')
    Lmem_uw=$(echo "$POWERS"  | awk '{print $6}')

    # --- Energy counter reads (cumulative uJ) ---
    ENERGY=$(read_cpu_energy_counters_uj)
    E_lmain=$(echo "$ENERGY" | awk '{print $1}')
    E_lmem=$(echo  "$ENERGY" | awk '{print $2}')
    E_big=$(echo   "$ENERGY" | awk '{print $3}')
    E_prime=$(echo "$ENERGY" | awk '{print $4}')

    RAM_uw=$(read_ram_power_uw)
    SYS_uw=$(read_system_power_uw)
    RAM_mA=$(read_ram_current_ma)
    SYS_mA=$(read_system_current_ma)

    VOLTS=$(read_all_cluster_voltages_uv)
    VL_uv=$(echo "$VOLTS" | awk '{print $1}')
    VB_uv=$(echo "$VOLTS" | awk '{print $2}')
    VP_uv=$(echo "$VOLTS" | awk '{print $3}')

    BATT=$(read_battery_metrics)
    BV=$(echo "$BATT" | awk '{print $1}')
    BI=$(echo "$BATT" | awk '{print $2}')
    BP=$(echo "$BATT" | awk '{print $3}')

    TL=$(read_cluster_temp little)
    TB=$(read_cluster_temp big)
    TP=$(read_cluster_temp prime)
    TBat=$(read_batt_temp)

    # Convert uW -> W
    cpu_W=$(awk   -v x="$T_uw"     'BEGIN{printf("%.6f", x/1e6)}')
    l_W=$(awk     -v x="$L_uw"     'BEGIN{printf("%.6f", x/1e6)}')
    b_W=$(awk     -v x="$B_uw"     'BEGIN{printf("%.6f", x/1e6)}')
    p_W=$(awk     -v x="$P_uw"     'BEGIN{printf("%.6f", x/1e6)}')
    lmn_W=$(awk   -v x="$Lmain_uw" 'BEGIN{printf("%.6f", x/1e6)}')
    lmem_W=$(awk  -v x="$Lmem_uw"  'BEGIN{printf("%.6f", x/1e6)}')
    ram_W=$(awk   -v x="$RAM_uw"   'BEGIN{printf("%.6f", x/1e6)}')
    sys_W=$(awk   -v x="$SYS_uw"   'BEGIN{printf("%.6f", x/1e6)}')
    vL=$(awk      -v x="$VL_uv"    'BEGIN{printf("%.3f", x/1e6)}')
    vB=$(awk      -v x="$VB_uv"    'BEGIN{printf("%.3f", x/1e6)}')
    vP=$(awk      -v x="$VP_uv"    'BEGIN{printf("%.3f", x/1e6)}')

    # CPU usage window
    STAT_B=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)
    sleep "$INTERVAL"
    STAT_A=$(grep "^cpu[0-9]" /proc/stat 2>/dev/null)

    # Write row
    {
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s" \
        "$phase" "$config_id" "$rep" "$workload" "$active" \
        "$fL" "$fB" "$fP" "$rL" "$rB" "$rP" "$TS"
      printf ",%s,%s,%s,%s,%s,%s,%s,%s,%s" \
        "$cpu_W" "$l_W" "$b_W" "$p_W" "$lmn_W" "$lmem_W" \
        "$ram_W" "$sys_W" "$BP"
      printf ",%s,%s,%s,%s" \
        "$vL" "$vB" "$vP" "$BV"
      printf ",%s,%s,%s" \
        "$RAM_mA" "$SYS_mA" "$BI"
      printf ",%s,%s,%s,%s" \
        "$TL" "$TB" "$TP" "$TBat"
      printf ",%s,%s,%s,%s" \
        "$E_lmain" "$E_lmem" "$E_big" "$E_prime"
      for c in $ALL_CORES; do printf ",%s" "$(read_cpu_freq "$c")"; done
      for c in $ALL_CORES; do printf ",%s" "$(cpu_usage_from_stat "$STAT_B" "$STAT_A" "$c")"; done
      printf "\n"
    } >> "$csv"

    n=$((n+1))
  done

  log_ok "Collected $n samples"
}