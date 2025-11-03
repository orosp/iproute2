#!/bin/bash
# Verification script for commit 2dbb035f2eb513
# Verifies that dpll_arg_required() replacements are correct

set -e

DPLL_C="../dpll.c"
ERRORS=0

echo "=== Verifying commit 2dbb035f2eb513: argument checking helper ==="
echo ""

# Check that dpll_arg_required() exists
echo "[1] Checking dpll_arg_required() function..."
if grep -q "static int dpll_arg_required" "$DPLL_C"; then
    echo "    ✓ dpll_arg_required() function exists"

    # Verify it checks argc and prints error
    if grep -A 10 "static int dpll_arg_required" "$DPLL_C" | grep -q "dpll_argc" && \
       grep -A 10 "static int dpll_arg_required" "$DPLL_C" | grep -q "pr_err"; then
        echo "    ✓ Function checks argc and prints error"
    else
        echo "    ✗ ERROR: Function logic incomplete"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "    ✗ ERROR: dpll_arg_required() function not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check that old pattern was replaced
echo "[2] Checking that old argument checking pattern was replaced..."
# argc checks are legitimate in helper functions (dpll_argv, dpll_arg_inc, dpll_argv_match, dpll_arg_required)
# Count should be around 4-5 (one in each helper)
OLD_PATTERN_COUNT=$(grep -n 'if (dpll_argc(dpll) == 0)' "$DPLL_C" | wc -l)
if [ "$OLD_PATTERN_COUNT" -le 6 ]; then
    echo "    ✓ Found $OLD_PATTERN_COUNT argc checks (in helper functions)"
else
    echo "    ✗ ERROR: Found $OLD_PATTERN_COUNT argc checks (expected: 4-6)"
    echo "    May indicate unrefactored code!"
    grep -n 'if (dpll_argc(dpll) == 0)' "$DPLL_C" || true
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check dpll_arg_required usage count
echo "[3] Checking dpll_arg_required() usage count..."
USAGE_COUNT=$(grep -c "dpll_arg_required(" "$DPLL_C" || echo 0)
# Subtract 1 for function definition
USAGE_COUNT=$((USAGE_COUNT - 1))
if [ "$USAGE_COUNT" -ge 30 ]; then
    echo "    ✓ dpll_arg_required() used $USAGE_COUNT times (expected: 30+)"
else
    echo "    ⚠ WARNING: dpll_arg_required() used only $USAGE_COUNT times (expected: 30+)"
fi
echo ""

# Verify consistent return pattern after dpll_arg_required
echo "[4] Checking return pattern after dpll_arg_required()..."
# Pattern should be: if (dpll_arg_required(...)) return -EINVAL;
CORRECT_PATTERN_COUNT=$(grep -A 1 'dpll_arg_required(' "$DPLL_C" | grep -c 'return -EINVAL' || echo 0)
if [ "$CORRECT_PATTERN_COUNT" -ge "$USAGE_COUNT" ]; then
    echo "    ✓ All dpll_arg_required() calls followed by 'return -EINVAL'"
else
    echo "    ⚠ WARNING: Some dpll_arg_required() calls may not have proper return"
    echo "    Found $CORRECT_PATTERN_COUNT returns for $USAGE_COUNT usages"
fi
echo ""

# Check that there are no leftover "requires an argument" without using helper
echo "[5] Checking for orphaned 'requires an argument' messages..."
ORPHAN_COUNT=$(grep -c 'requires an argument' "$DPLL_C" || echo 0)
# Should be in dpll_arg_required() and possibly dpll_parse_state/direction
if [ "$ORPHAN_COUNT" -le 3 ]; then
    echo "    ✓ Found $ORPHAN_COUNT 'requires an argument' messages (acceptable)"
else
    echo "    ✗ ERROR: Found $ORPHAN_COUNT instances of 'requires an argument'"
    echo "    Expected: 1-3 (in helper functions)"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Summary
echo "========================================"
if [ $ERRORS -eq 0 ]; then
    echo "✓ ALL CHECKS PASSED"
    exit 0
else
    echo "✗ FOUND $ERRORS ERROR(S)"
    exit 1
fi
