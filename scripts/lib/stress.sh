# lib/stress.sh - Stress workload detection and control
# Requires: common.sh sourced first.

# Detected stress workload (set by detect_stress_tool)
STRESS_CMD=""
STRESS_NG_BIN="/data/local/tmp/stress-ng"

detect_stress_tool() {
  log_info "Detecting stress workload..."

  if [ -x "$STRESS_NG_BIN" ]; then
    STRESS_CMD="stress-ng"
    log_ok "Using stress-ng at $STRESS_NG_BIN"
    return 0
  fi
  if command -v stress-ng >/dev/null 2>&1; then
    STRESS_NG_BIN="stress-ng"
    STRESS_CMD="stress-ng"
    log_ok "Using stress-ng from PATH"
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    if printf 'test' | openssl enc -aes-256-cbc -nosalt -pass pass:deadbeef -out /dev/null 2>/dev/null; then
      STRESS_CMD="aes"
      log_ok "Using AES-256-CBC fallback (openssl)"
      return 0
    fi
  fi

  if command -v awk >/dev/null 2>&1; then
    STRESS_CMD="gemm"
    log_ok "Using GEMM fallback (awk)"
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    STRESS_CMD="sha256"
    log_ok "Using SHA-256 fallback"
    return 0
  fi

  if command -v yes >/dev/null 2>&1; then
    STRESS_CMD="yes"
    log_warn "Using 'yes' fallback (low power draw)"
    return 0
  fi

  log_error "No usable stress workload found"
  return 1
}

# Convert a CPU id to a taskset hex mask.
# Usage: core_mask <cpu_id>  -> e.g. core_mask 4 -> "10"
core_mask() {
  case "$1" in
    0) echo "1"   ;; 1) echo "2"   ;; 2) echo "4"   ;;
    3) echo "8"   ;; 4) echo "10"  ;; 5) echo "20"  ;;
    6) echo "40"  ;; 7) echo "80"  ;; 8) echo "100" ;;
    *) printf "%x\n" $((1 << $1)) ;;
  esac
}

# Start a stress worker on a specific CPU.
# Echoes the PID.
# Usage: start_stress_on_cpu <cpu_id>
start_stress_on_cpu() {
  cpu_id="$1"
  mask="$(core_mask "$cpu_id")"

  case "$STRESS_CMD" in
    stress-ng)
      "$STRESS_NG_BIN" \
        --temp-path /data/local/tmp \
        --cpu 1 --cpu-method matrixprod \
        --taskset "$cpu_id" \
        --quiet --timeout 0 >/dev/null 2>&1 &
      ;;
    aes)
      taskset "$mask" sh -c '
        while true; do
          dd if=/dev/urandom bs=65536 count=64 2>/dev/null | \
            openssl enc -aes-256-cbc -nosalt -pass pass:deadbeef -out /dev/null 2>/dev/null
        done' >/dev/null 2>&1 &
      ;;
    gemm)
      taskset "$mask" awk 'BEGIN {
        N = 64
        for (i=0;i<N;i++) for (j=0;j<N;j++) { A[i,j]=rand(); B[i,j]=rand() }
        while (1) {
          for (i=0;i<N;i++) for (j=0;j<N;j++) {
            s=0; for (k=0;k<N;k++) s += A[i,k]*B[k,j]; C[i,j]=s
          }
        }
      }' >/dev/null 2>&1 &
      ;;
    sha256)
      taskset "$mask" sh -c '
        while true; do
          dd if=/dev/urandom bs=65536 count=64 2>/dev/null | sha256sum >/dev/null 2>/dev/null
        done' >/dev/null 2>&1 &
      ;;
    yes)
      taskset "$mask" yes >/dev/null 2>&1 &
      ;;
  esac
  PID=$!
  # If cgroup shielding is in use, move this worker to shield_workers so
  # it's not confined to shield_system's cpu0. The function is defined in
  # lib/cgroups.sh; if cgroups aren't loaded, skip.
  if type assign_to_workers >/dev/null 2>&1; then
    assign_to_workers "$PID"
  fi
  echo "$PID"
}

# Start stress on every CPU in a space-separated list.
# Echoes the PIDs.
# Usage: start_stress_on_cpus "0 1 2 3"
start_stress_on_cpus() {
  cpus="$1"
  PIDS=""
  for c in $cpus; do
    pid=$(start_stress_on_cpu "$c")
    PIDS="$PIDS $pid"
  done
  echo "$PIDS"
}

# Kill all stress workers. Broad sweep to be safe.
stop_stress() {
  pkill -f stress-ng            2>/dev/null || true
  pkill -f "openssl enc"        2>/dev/null || true
  pkill -f "dd if=/dev/urandom" 2>/dev/null || true
  pkill sha256sum               2>/dev/null || true
  pkill yes                     2>/dev/null || true
  pkill -f "awk.*BEGIN"         2>/dev/null || true
  sleep 0.3
}