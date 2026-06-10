# lib/cgroups.sh - cpuset cgroup shielding to confine OS tasks to cpu0
# Requires: common.sh sourced first.
#
# Purpose: During measurement, we don't want Android background tasks
# waking up on Big/Prime cores, because those cores are pinned at max
# voltage and any activity on them causes disproportionate power draw.
#
# Strategy (TWO cgroups):
#   - /dev/cpuset/shield_system  cpus=0        for existing OS tasks (kworker, daemons, shell)
#   - /dev/cpuset/shield_workers cpus=ALL_CORES for our stress workers
#
# Why two groups: if we confine our stress workers to the system cgroup,
# they all pile onto cpu0. If we put them in shield_workers, they can run
# on any core (and taskset pins them to the right one). Meanwhile, every
# OS background task we moved into shield_system stays on cpu0, clear of
# our measurement.

CGROUP_ROOT="/dev/cpuset"
CGROUP_SYSTEM="$CGROUP_ROOT/shield_system"
CGROUP_WORKERS="$CGROUP_ROOT/shield_workers"

# Build the cpu range string for the workers cgroup from ALL_CORES.
# Result is a contiguous range like "0-7" or "0-8" depending on device.
# Falls back to "0-8" if ALL_CORES is unset (Pixel 8 Pro default).
_workers_cpu_range() {
  if [ -z "$ALL_CORES" ]; then
    echo "0-8"
    return
  fi
  # Find first and last CPU in the list
  first=""
  last=""
  for c in $ALL_CORES; do
    [ -z "$first" ] && first="$c"
    last="$c"
  done
  echo "${first}-${last}"
}

# Create both shield cpusets.
setup_cgroups() {
  workers_range="$(_workers_cpu_range)"

  if [ ! -d "$CGROUP_SYSTEM" ]; then
    mkdir -p "$CGROUP_SYSTEM" 2>/dev/null || true
  fi
  echo "0"   > "$CGROUP_SYSTEM/cpus" 2>/dev/null || true
  echo "0"   > "$CGROUP_SYSTEM/mems" 2>/dev/null || true

  if [ ! -d "$CGROUP_WORKERS" ]; then
    mkdir -p "$CGROUP_WORKERS" 2>/dev/null || true
  fi
  echo "$workers_range" > "$CGROUP_WORKERS/cpus" 2>/dev/null || true
  echo "0"              > "$CGROUP_WORKERS/mems" 2>/dev/null || true

  # Verify what actually got written — log the realized values
  actual_workers="$(cat "$CGROUP_WORKERS/cpus" 2>/dev/null || echo '???')"
  actual_system="$(cat "$CGROUP_SYSTEM/cpus" 2>/dev/null || echo '???')"
  log_info "cgroups created: shield_system (cpu=$actual_system), shield_workers (cpu=$actual_workers)"

  if [ "$actual_workers" != "$workers_range" ]; then
    log_warn "shield_workers cpus mismatch: requested '$workers_range', got '$actual_workers'"
    log_warn "  This will prevent stress workers from running on the requested cores!"
  fi
}

# Move every currently-running task into the shield_system cpuset.
# Must be called BEFORE starting any stress workers — once a worker is
# in shield_workers, we don't want to move it back to system.
move_tasks_to_system() {
  if [ ! -d "$CGROUP_SYSTEM" ]; then
    log_warn "cgroup not set up; skipping task move"
    return
  fi
  local moved=0
  for pid in $(cat "$CGROUP_ROOT/tasks" 2>/dev/null); do
    if echo "$pid" > "$CGROUP_SYSTEM/tasks" 2>/dev/null; then
      moved=$((moved + 1))
    fi
  done
  log_info "Moved $moved tasks into shield_system (some kernel threads are pinned and refuse)"
}

# Place a specific PID into shield_workers so it can run on any core.
# Called by stress-start code for each stress worker.
# Usage: assign_to_workers <pid>
assign_to_workers() {
  pid="$1"
  [ -n "$pid" ] || return
  if [ ! -d "$CGROUP_WORKERS" ]; then
    return
  fi
  echo "$pid" > "$CGROUP_WORKERS/tasks" 2>/dev/null || true
}

# Release all tasks back to the root cpuset and remove the shields.
cleanup_cgroups() {
  for grp in "$CGROUP_WORKERS" "$CGROUP_SYSTEM"; do
    if [ -d "$grp" ]; then
      for pid in $(cat "$grp/tasks" 2>/dev/null); do
        echo "$pid" > "$CGROUP_ROOT/tasks" 2>/dev/null || true
      done
      rmdir "$grp" 2>/dev/null || true
    fi
  done
  log_info "cgroups torn down"
}