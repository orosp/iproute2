#!/bin/bash
# Verification script for commit 13f076086ae97f
# Verifies DPLL_PARSE_ATTR_STR macro

set -e

DPLL_C="../dpll.c"
ERRORS=0

echo "=== Verifying commit 13f076086ae97f: string parsing macro ==="
echo ""

echo "[1] Checking DPLL_PARSE_ATTR_STR macro..."
if grep -q "#define DPLL_PARSE_ATTR_STR" "$DPLL_C"; then
    echo "    ✓ DPLL_PARSE_ATTR_STR macro defined"

    # Check contains required elements
    if grep -A 20 "#define DPLL_PARSE_ATTR_STR" "$DPLL_C" | grep -q "dpll_arg_required" && \
       grep -A 20 "#define DPLL_PARSE_ATTR_STR" "$DPLL_C" | grep -q "mnl_attr_put_strz" && \
       grep -A 20 "#define DPLL_PARSE_ATTR_STR" "$DPLL_C" | grep -q "dpll_arg_inc"; then
        echo "    ✓ Macro contains all required elements"
    else
        echo "    ✗ ERROR: Macro missing required elements"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "    ✗ ERROR: DPLL_PARSE_ATTR_STR macro not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

echo "[2] Checking macro usage..."
STR_USAGE=$(grep -c "DPLL_PARSE_ATTR_STR(" "$DPLL_C" || echo 0)
echo "    DPLL_PARSE_ATTR_STR used: $STR_USAGE times"

if [ "$STR_USAGE" -ge 4 ]; then
    echo "    ✓ Macro used at least 4 times"
else
    echo "    ⚠ WARNING: Macro used less than expected"
fi
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✓ ALL CHECKS PASSED"
    exit 0
else
    echo "✗ FOUND $ERRORS ERROR(S)"
    exit 1
fi
