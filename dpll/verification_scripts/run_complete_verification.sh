#!/bin/bash
# Complete verification suite - verifies BOTH dpll.c and test_dpll.sh refactors

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_ERRORS=0

echo "════════════════════════════════════════════════════════════"
echo "  COMPLETE DPLL REFACTORING VERIFICATION"
echo "  Verifying dpll.c (7 commits) + test_dpll.sh (17 commits)"
echo "════════════════════════════════════════════════════════════"
echo ""

# Part 1: Verify dpll.c refactors
echo "┌────────────────────────────────────────────────────────────┐"
echo "│ PART 1: DPLL.C REFACTOR VERIFICATION                      │"
echo "└────────────────────────────────────────────────────────────┘"
echo ""

if bash "$SCRIPT_DIR/run_all_verifications.sh"; then
    echo ""
    echo "✓✓✓ DPLL.C REFACTORS: ALL VERIFIED ✓✓✓"
    DPLL_C_STATUS="PASS"
else
    echo ""
    echo "✗✗✗ DPLL.C REFACTORS: FAILED ✗✗✗"
    DPLL_C_STATUS="FAIL"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
fi

echo ""
echo ""

# Part 2: Verify test_dpll.sh refactors
echo "┌────────────────────────────────────────────────────────────┐"
echo "│ PART 2: TEST_DPLL.SH REFACTOR VERIFICATION                │"
echo "└────────────────────────────────────────────────────────────┘"
echo ""

if bash "$SCRIPT_DIR/verify_all_test_refactors.sh"; then
    echo ""
    echo "✓✓✓ TEST_DPLL.SH REFACTORS: ALL VERIFIED ✓✓✓"
    TEST_SH_STATUS="PASS"
else
    echo ""
    echo "✗✗✗ TEST_DPLL.SH REFACTORS: FAILED ✗✗✗"
    TEST_SH_STATUS="FAIL"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
fi

echo ""
echo ""

# Final Summary
echo "════════════════════════════════════════════════════════════"
echo "  FINAL COMPLETE VERIFICATION SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "dpll.c refactors (7 commits):         $DPLL_C_STATUS"
echo "test_dpll.sh refactors (17 commits):  $TEST_SH_STATUS"
echo ""
echo "Total verification sets: 2"
echo "Passed: $((2 - TOTAL_ERRORS))"
echo "Failed: $TOTAL_ERRORS"
echo ""

if [ $TOTAL_ERRORS -eq 0 ]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║  ✓✓✓ ALL REFACTORINGS VERIFIED CORRECT ✓✓✓               ║"
    echo "║                                                            ║"
    echo "║  24 commits verified (7 dpll.c + 17 test_dpll.sh)         ║"
    echo "║  Lives are safe! Code is correct! 🎉                      ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    exit 0
else
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║  ✗✗✗ VERIFICATION FAILURES DETECTED ✗✗✗                  ║"
    echo "║                                                            ║"
    echo "║  ⚠⚠⚠ CRITICAL: Review failures above! ⚠⚠⚠               ║"
    echo "║  ⚠⚠⚠ Lives may be at risk! ⚠⚠⚠                          ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    exit 1
fi
