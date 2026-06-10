#!/usr/bin/env bash
# fix_paths.sh — run from the root of your repo AFTER reorganize.sh
# Updates all hardcoded throttling_data/ references to data/
set -euo pipefail

# ─────────────────────────────────────────────
# fit_little_floor.py
# ../throttling_data/pixel8pro  →  ../data/pixel8pro
# ─────────────────────────────────────────────
sed -i '' \
  's|Path("../throttling_data/pixel8pro")|Path("../data/pixel8pro")|g' \
  training/fit_little_floor.py

echo "✓ training/fit_little_floor.py"

# ─────────────────────────────────────────────
# fit_alpha.py — three occurrences:
#
#  1. elif (root / "throttling_data" / "phase1").exists():
#       →  elif (root / "data" / "phase1").exists():
#
#  2. phase1_dir = root / "throttling_data" / "phase1"
#       →  phase1_dir = root / "data" / "phase1"
#
#  3. if root.name == "throttling_data" or not (root / "throttling_data").exists():
#       →  if root.name == "data" or not (root / "data").exists():
#
#  4. save_dir = root / "throttling_data"
#       →  save_dir = root / "data"
# ─────────────────────────────────────────────
sed -i '' \
  's|root / "throttling_data" / "phase1"|root / "data" / "phase1"|g' \
  training/fit_alpha.py

sed -i '' \
  's|root\.name == "throttling_data"|root.name == "data"|g' \
  training/fit_alpha.py

sed -i '' \
  's|root / "throttling_data"|root / "data"|g' \
  training/fit_alpha.py

echo "✓ training/fit_alpha.py"

# ─────────────────────────────────────────────
# validate_all_rhos.py — two occurrences (same pattern as fit_alpha):
#
#  1. if root.name == "throttling_data" or not (root / "throttling_data").exists():
#  2. save_dir = root / "throttling_data"
# ─────────────────────────────────────────────
sed -i '' \
  's|root\.name == "throttling_data"|root.name == "data"|g' \
  validation/validate_all_rhos.py

sed -i '' \
  's|root / "throttling_data"|root / "data"|g' \
  validation/validate_all_rhos.py

echo "✓ validation/validate_all_rhos.py"

# ─────────────────────────────────────────────
# Catch-all: warn about any remaining references
# ─────────────────────────────────────────────
echo ""
REMAINING=$(grep -r "throttling_data" training/ validation/ ml_inference/ 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
  echo "⚠️  Remaining references to throttling_data (manual fix needed):"
  echo "$REMAINING"
else
  echo "✓ No remaining throttling_data references."
fi
