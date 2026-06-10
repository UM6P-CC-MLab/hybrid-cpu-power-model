# lib/common.sh - Central device constants for Pixel 8 Pro (Tensor G3)
# Sourced by every other script. Edit here if device changes.

OUT_ROOT="/data/local/tmp/throttling_study"
DATA_DIR="$OUT_ROOT/data"
LIB_DIR="$OUT_ROOT/lib"

# --- Cluster map ------------------------------------------------------------
# Three parallel arrays indexed by cluster name.
# Kernel naming vs. physical cluster:
#   CPUCL0 rail = Little (cpu0-3)
#   CPUCL1 rail = Big    (cpu4-7)
#   CPUCL2 rail = Prime  (cpu8)
#   thermal BIG zone    = Prime core
#   thermal MID zone    = Big cluster
#   thermal LITTLE zone = Little cluster

# Cluster names we iterate over
CLUSTERS="little big prime"

cluster_policy() {
  case "$DEVICE_MODEL" in
    "Pixel 9"*)
      case "$1" in
        little) echo "0" ;;
        big)    echo "4" ;;
        prime)  echo "7" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      case "$1" in
        little) echo "0" ;;
        big)    echo "4" ;;
        prime)  echo "8" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}


cluster_cpus() {
  case "$DEVICE_MODEL" in
    "Pixel 9"*)
      case "$1" in
        little) echo "0 1 2 3" ;;
        big)    echo "4 5 6" ;;
        prime)  echo "7" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      case "$1" in
        little) echo "0 1 2 3" ;;
        big)    echo "4 5 6 7" ;;
        prime)  echo "8" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

cluster_thermal_zone() {
  case "$DEVICE_MODEL" in
    "Pixel 9"*)
      # Pixel 9: zone0=BIG (Prime), zone1=MID (Big), zone2=LITTLE
      case "$1" in
        little) echo "2" ;;
        big)    echo "1" ;;
        prime)  echo "0" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      # Pixel 8 Pro: zone0=BIG (Prime), zone1=BIG (Big), zone2=LITTLE
      case "$1" in
        little) echo "2" ;;
        big)    echo "1" ;;
        prime)  echo "0" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

# Detect device once
DEVICE_MODEL=$(getprop ro.product.model 2>/dev/null || echo "unknown")

cluster_regulator() {
  case "$DEVICE_MODEL" in
    "Pixel 9"|"Pixel 9 Pro"|"Pixel 9 Pro XL"|"Pixel 9 Pro Fold")
      case "$1" in
        little) echo "55" ;;
        big)    echo "52" ;;
        prime)  echo "54" ;;
        *) return 1 ;;
      esac
      ;;
    "Pixel 8 Pro"|*)
      case "$1" in
        little) echo "51" ;;
        big)    echo "50" ;;
        prime)  echo "49" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

# Cluster -> max frequency (kHz) - used for rho calculations in Phase 2
# These are read from scaling_available_frequencies the first time, but
# hardcoded here as sanity check / fallback.
cluster_max_freq_khz() {
  case "$DEVICE_MODEL" in
    "Pixel 9"*)
      case "$1" in
        little) echo "1950000" ;;
        big)    echo "2600000" ;;
        prime)  echo "3105000" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      case "$1" in
        little) echo "1704000" ;;
        big)    echo "2367000" ;;
        prime)  echo "2914000" ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

# --- ODPM paths -------------------------------------------------------------
ODPM_MAIN="/sys/bus/iio/devices/iio:device1"
ODPM_PERI="/sys/bus/iio/devices/iio:device0"

# --- All CPUs (for full-system operations) ----------------------------------
case "$DEVICE_MODEL" in
  "Pixel 9"*) ALL_CORES="0 1 2 3 4 5 6 7" ;;
  *)          ALL_CORES="0 1 2 3 4 5 6 7 8" ;;
esac
SYSTEM_CORE="0"  # OS tasks confined here during measurement

# --- Default experiment parameters (overridable via env or args) ------------
: "${DURATION_SEC:=60}"
: "${INTERVAL:=0.5}"
: "${NUM_REPS:=3}"
: "${TEMP_TOLERANCE:=2.0}"
: "${MAX_TEMP_WAIT:=600}"
: "${COOLDOWN_SEC:=30}"

# --- Helpers ----------------------------------------------------------------
now_ms() {
  TS="$(date +%s%3N 2>/dev/null || true)"
  [ -n "$TS" ] || TS=$(( $(date +%s) * 1000 ))
  echo "$TS"
}

log_info()  { echo "[*] $*" >&2; }
log_ok()    { echo "[✓] $*" >&2; }
log_warn()  { echo "[!] $*" >&2; }
log_error() { echo "[X] $*" >&2; }

# Snap a target frequency (kHz) to the nearest available value from a list
# Usage: snap_to_freq <target_khz> <space-separated freq list>
snap_to_freq() {
  target="$1"; shift
  echo "$@" | awk -v t="$target" '{
    best=$1; best_diff = (t>$1 ? t-$1 : $1-t)
    for (i=2; i<=NF; i++) {
      d = (t>$i ? t-$i : $i-t)
      if (d < best_diff) { best=$i; best_diff=d }
    }
    print best
  }'
}

# Sanity: must be root
require_root() {
  id 2>/dev/null | grep -q "uid=0" || { log_error "Run as root (su)"; exit 1; }
}