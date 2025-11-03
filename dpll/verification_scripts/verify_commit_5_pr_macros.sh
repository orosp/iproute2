#!/bin/bash
# Verification script for commit 5bfc3310455135
# Verifies pr_out and pr_err macro simplification

set -e

DPLL_C="../dpll.c"
ERRORS=0

echo "=== Verifying commit 5bfc3310455135: pr_out/pr_err simplification ==="
echo ""

echo "[1] Checking simplified pr_out macro..."
if grep -q "#define pr_out" "$DPLL_C"; then
    # Should be simple: fprintf(stdout, ...)
    if grep "#define pr_out" "$DPLL_C" | grep -q "fprintf(stdout"; then
        echo "    ✓ pr_out is simplified to fprintf(stdout)"
    else
        echo "    ✗ ERROR: pr_out not simplified correctly"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "    ✗ ERROR: pr_out macro not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

echo "[2] Checking simplified pr_err macro..."
if grep -q "#define pr_err" "$DPLL_C"; then
    # Should be simple: fprintf(stderr, ...)
    if grep "#define pr_err" "$DPLL_C" | grep -q "fprintf(stderr"; then
        echo "    ✓ pr_err is simplified to fprintf(stderr)"
    else
        echo "    ✗ ERROR: pr_err not simplified correctly"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "    ✗ ERROR: pr_err macro not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✓ ALL CHECKS PASSED"
    exit 0
else
    echo "✗ FOUND $ERRORS ERROR(S)"
    exit 1
fi
