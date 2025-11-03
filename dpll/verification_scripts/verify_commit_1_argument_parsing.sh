#!/bin/bash
# Verification script for commit dbff62bb3ec913
# Verifies that dpll_parse_state() and dpll_parse_direction() replacements are correct

set -e

DPLL_C="../dpll.c"
ERRORS=0

echo "=== Verifying commit dbff62bb3ec913: argument parsing helpers ==="
echo ""

# Check that dpll_parse_state() exists and has correct logic
echo "[1] Checking dpll_parse_state() function..."
if grep -q "static int dpll_parse_state" "$DPLL_C"; then
    echo "    ✓ dpll_parse_state() function exists"

    # Verify it handles all 3 states
    if grep -A 20 "static int dpll_parse_state" "$DPLL_C" | grep -q "connected" && \
       grep -A 20 "static int dpll_parse_state" "$DPLL_C" | grep -q "disconnected" && \
       grep -A 20 "static int dpll_parse_state" "$DPLL_C" | grep -q "selectable"; then
        echo "    ✓ Function handles all 3 states (connected, disconnected, selectable)"
    else
        echo "    ✗ ERROR: Function missing state handling"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "    ✗ ERROR: dpll_parse_state() function not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check that dpll_parse_direction() exists and has correct logic
echo "[2] Checking dpll_parse_direction() function..."
if grep -q "static int dpll_parse_direction" "$DPLL_C"; then
    echo "    ✓ dpll_parse_direction() function exists"

    # Verify it handles both directions
    if grep -A 15 "static int dpll_parse_direction" "$DPLL_C" | grep -q "input" && \
       grep -A 15 "static int dpll_parse_direction" "$DPLL_C" | grep -q "output"; then
        echo "    ✓ Function handles both directions (input, output)"
    else
        echo "    ✗ ERROR: Function missing direction handling"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "    ✗ ERROR: dpll_parse_direction() function not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check that old inline parsing was replaced
echo "[3] Checking that inline state parsing was replaced..."
# There should be NO lines like: if (matches(dpll_argv(dpll), "connected") == 0)
INLINE_STATE_COUNT=$(grep 'matches(dpll_argv.*"connected")' "$DPLL_C" | wc -l)
if [ "$INLINE_STATE_COUNT" -eq 0 ]; then
    echo "    ✓ No inline state parsing found (all replaced with dpll_parse_state)"
else
    echo "    ✗ ERROR: Found $INLINE_STATE_COUNT inline state parsing instances"
    ERRORS=$((ERRORS + 1))
fi
echo ""

echo "[4] Checking that inline direction parsing was replaced..."
INLINE_DIR_COUNT=$(grep 'matches(dpll_argv.*"input").*DPLL_A_PIN_DIRECTION' "$DPLL_C" | wc -l)
if [ "$INLINE_DIR_COUNT" -eq 0 ]; then
    echo "    ✓ No inline direction parsing found (all replaced with dpll_parse_direction)"
else
    echo "    ✗ ERROR: Found $INLINE_DIR_COUNT inline direction parsing instances"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check dpll_parse_state usage count (should be 4 places)
echo "[5] Checking dpll_parse_state() usage count..."
STATE_USAGE=$(grep -c "dpll_parse_state(" "$DPLL_C" || echo 0)
# Subtract 1 for function definition
STATE_USAGE=$((STATE_USAGE - 1))
if [ "$STATE_USAGE" -ge 4 ]; then
    echo "    ✓ dpll_parse_state() used $STATE_USAGE times (expected: 4+)"
else
    echo "    ⚠ WARNING: dpll_parse_state() used only $STATE_USAGE times (expected: 4)"
fi
echo ""

# Check dpll_parse_direction usage count (should be 2 places)
echo "[6] Checking dpll_parse_direction() usage count..."
DIR_USAGE=$(grep -c "dpll_parse_direction(" "$DPLL_C" || echo 0)
# Subtract 1 for function definition
DIR_USAGE=$((DIR_USAGE - 1))
if [ "$DIR_USAGE" -ge 2 ]; then
    echo "    ✓ dpll_parse_direction() used $DIR_USAGE times (expected: 2+)"
else
    echo "    ⚠ WARNING: dpll_parse_direction() used only $DIR_USAGE times (expected: 2)"
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
