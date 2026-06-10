#!/system/bin/sh
# run_all.sh - Run Phase 1 (all three clusters) + Phase 2 + Phase 3 end to end
#
# Total time with defaults (NUM_REPS=3, DURATION_SEC=60):
#   Phase 1: (10+15+15) freqs * 3 reps * ~90s  = ~3h
#   Phase 2: 8 rhos * 3 reps * ~90s            = ~36m
#   Phase 3: 5 configs * 3 reps * ~90s         = ~22m
#   Total:   ~4-5 hours (longer with warm/cool cycles)
#
# Usage:
#   sh run_all.sh

set -m
trap '' PIPE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Signal handling for clean interruption
cleanup_main() {
  local exit_code=$?
  echo ""
  echo "########################################################################"
  echo "#  THROTTLING STUDY - INTERRUPTED BY USER"
  echo "########################################################################"
  exit 130
}
trap cleanup_main INT TERM

echo "########################################################################"
echo "#  FULL THROTTLING STUDY - ALL PHASES"
echo "########################################################################"
echo "Started: $(date)"
echo ""

sh "$SCRIPT_DIR/isolated.sh" all
phase1_exit=$?
if [ "$phase1_exit" -eq 130 ]; then
  echo "Phase 1 interrupted"
  exit 130
elif [ "$phase1_exit" -ne 0 ]; then
  echo "Phase 1 failed"
  exit 1
fi

sh "$SCRIPT_DIR/combined.sh"
phase2_exit=$?
if [ "$phase2_exit" -eq 130 ]; then
  echo "Phase 2 interrupted"
  exit 130
elif [ "$phase2_exit" -ne 0 ]; then
  echo "Phase 2 failed"
  exit 1
fi

sh "$SCRIPT_DIR/isolated.sh" all
phase3_exit=$?
if [ "$phase3_exit" -eq 130 ]; then
  echo "Phase 3 interrupted"
  exit 130
elif [ "$phase3_exit" -ne 0 ]; then
  echo "Phase 3 failed"
  exit 1
fi

echo ""
echo "########################################################################"
echo "#  ALL PHASES COMPLETE"
echo "########################################################################"
echo "Finished: $(date)"
echo ""
echo "Data tree:"
find /data/local/tmp/throttling_study/data -type d -print -exec sh -c 'ls -1 "$0" | wc -l' {} \;
echo ""
echo "Pull to host with:"
echo "  adb pull /data/local/tmp/throttling_study/data ./throttling_data"