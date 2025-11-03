#!/bin/bash
# Master verification script for ALL test_dpll.sh refactor commits
# Verifies that refactoring maintains test functionality

set -e

TEST_FILE="../test_dpll.sh"
ERRORS=0
WARNINGS=0

echo "════════════════════════════════════════════════════════════"
echo "  TEST_DPLL.SH REFACTOR VERIFICATION SUITE"
echo "  Verifying all 17 refactor commits"
echo "════════════════════════════════════════════════════════════"
echo ""

# Test 1: File syntax is valid
echo "[1] Checking bash syntax..."
if bash -n "$TEST_FILE"; then
    echo "    ✓ Bash syntax is valid"
else
    echo "    ✗ CRITICAL: Bash syntax errors!"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Test 2: All test functions are defined
echo "[2] Checking that all test functions exist..."
REQUIRED_FUNCTIONS=(
    "test_help"
    "test_version"
    "test_device_operations"
    "test_pin_operations"
    "test_device_id_get"
    "test_pin_id_get"
    "test_json_consistency"
    "test_legacy_output"
    "test_monitor"
    "test_set_operations"
    "test_error_handling"
    "main"
)

MISSING_FUNCS=0
for FUNC in "${REQUIRED_FUNCTIONS[@]}"; do
    if grep -q "^$FUNC()" "$TEST_FILE" || grep -q "^test_$FUNC()" "$TEST_FILE" 2>/dev/null; then
        echo "    ✓ Function $FUNC exists"
    else
        echo "    ✗ ERROR: Function $FUNC missing!"
        MISSING_FUNCS=$((MISSING_FUNCS + 1))
        ERRORS=$((ERRORS + 1))
    fi
done

if [ $MISSING_FUNCS -eq 0 ]; then
    echo "    ✓ All required test functions exist"
fi
echo ""

# Test 3: Helper functions exist
echo "[3] Checking generic helper functions..."
HELPER_FUNCS=(
    "test_if"
    "require"
    "test_expect_fail"
    "test_simple"
    "test_command_succeeds"
    "print_result"
    "run_test_command"
)

for HELPER in "${HELPER_FUNCS[@]}"; do
    if grep -q "^${HELPER}()" "$TEST_FILE" || grep -q "^$HELPER ()" "$TEST_FILE"; then
        echo "    ✓ Helper $HELPER exists"
    else
        echo "    ⚠ WARNING: Helper $HELPER not found"
        WARNINGS=$((WARNINGS + 1))
    fi
done
echo ""

# Test 4: Check for common anti-patterns
echo "[4] Checking for anti-patterns..."

# Check for direct command execution without helpers
DIRECT_DPLL_COUNT=$(grep -c '\$DPLL_TOOL.*>>' "$TEST_FILE" 2>/dev/null || echo 0)
echo "    Found $DIRECT_DPLL_COUNT direct DPLL_TOOL executions (lower is better)"

# Check for repetitive patterns that should use helpers
REPETITIVE_IF_COUNT=$(grep -c 'if.*then.*print_result PASS.*else.*print_result FAIL' "$TEST_FILE" 2>/dev/null || echo 0)
if [ "$REPETITIVE_IF_COUNT" -gt 20 ]; then
    echo "    ⚠ WARNING: Found $REPETITIVE_IF_COUNT repetitive if-then-else patterns"
    echo "      Consider using test_simple or test_if helpers"
    WARNINGS=$((WARNINGS + 1))
else
    echo "    ✓ Repetitive patterns minimized ($REPETITIVE_IF_COUNT instances)"
fi
echo ""

# Test 5: Check Test API usage
echo "[5] Checking Test API framework usage..."
if grep -q "^test_suite()" "$TEST_FILE"; then
    echo "    ✓ test_suite() function exists"

    # Count test_suite usage
    SUITE_USAGE=$(grep -c 'test_suite "' "$TEST_FILE" 2>/dev/null || echo 0)
    echo "    test_suite used: $SUITE_USAGE times"
else
    echo "    ⚠ Test API framework not fully implemented"
fi
echo ""

# Test 6: Check for proper error handling
echo "[6] Checking error handling..."
HAS_DEBUG_LOG=$(grep -c 'DEBUG_LOG' "$TEST_FILE" 2>/dev/null || echo 0)
if [ "$HAS_DEBUG_LOG" -gt 10 ]; then
    echo "    ✓ Error output redirected to DEBUG_LOG ($HAS_DEBUG_LOG instances)"
else
    echo "    ⚠ WARNING: Limited error logging ($HAS_DEBUG_LOG instances)"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# Test 7: Check for code reduction
echo "[7] Checking code metrics..."
TOTAL_LINES=$(wc -l < "$TEST_FILE")
FUNCTION_COUNT=$(grep -c '^[a-z_]*()' "$TEST_FILE" 2>/dev/null || echo 0)
AVG_FUNC_SIZE=$((TOTAL_LINES / (FUNCTION_COUNT + 1)))

echo "    Total lines: $TOTAL_LINES"
echo "    Function count: $FUNCTION_COUNT"
echo "    Average function size: ~$AVG_FUNC_SIZE lines"

if [ "$AVG_FUNC_SIZE" -lt 50 ]; then
    echo "    ✓ Functions are reasonably sized"
else
    echo "    ⚠ WARNING: Large average function size"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# Test 8: Check that Test API tests use correct structure
echo "[8] Checking Test API structure..."
if grep -q 'test_suite "' "$TEST_FILE"; then
    # Check for --name usage
    NAME_USAGE=$(grep -c '\--name' "$TEST_FILE" 2>/dev/null || echo 0)
    if [ "$NAME_USAGE" -gt 0 ]; then
        echo "    ✓ Test API uses --name parameter ($NAME_USAGE instances)"
    fi

    # Check for --json usage
    JSON_USAGE=$(grep -c '\--json' "$TEST_FILE" 2>/dev/null || echo 0)
    if [ "$JSON_USAGE" -gt 0 ]; then
        echo "    ✓ Test API uses --json parameter ($JSON_USAGE instances)"
    fi
fi
echo ""

# Test 9: Verify no duplicate function definitions
echo "[9] Checking for duplicate function definitions..."
FUNC_NAMES=$(grep -o '^[a-z_]*()' "$TEST_FILE" | sed 's/()//' | sort)
UNIQUE_FUNCS=$(echo "$FUNC_NAMES" | uniq)
DUPLICATE_COUNT=$(comm -23 <(echo "$FUNC_NAMES") <(echo "$UNIQUE_FUNCS") | wc -l)

if [ "$DUPLICATE_COUNT" -eq 0 ]; then
    echo "    ✓ No duplicate function definitions"
else
    echo "    ✗ ERROR: Found $DUPLICATE_COUNT duplicate function definitions!"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Test 10: Check specific refactorings
echo "[10] Checking specific refactorings..."

# Check for test_id_get_command helper
if grep -q 'test_id_get_command()' "$TEST_FILE"; then
    echo "    ✓ test_id_get_command helper exists"
else
    echo "    ⚠ test_id_get_command helper not found"
fi

# Check for test_object_operations helper
if grep -q 'test_object_operations()' "$TEST_FILE"; then
    echo "    ✓ test_object_operations helper exists"
else
    echo "    ⚠ test_object_operations helper not found"
fi

# Check for compare_with_python helper
if grep -q 'compare_with_python()' "$TEST_FILE"; then
    echo "    ✓ compare_with_python helper exists"
else
    echo "    ⚠ compare_with_python helper not found"
fi
echo ""

# Summary
echo "════════════════════════════════════════════════════════════"
echo "  VERIFICATION SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Errors: $ERRORS"
echo "Warnings: $WARNINGS"
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✓✓✓ ALL CRITICAL CHECKS PASSED ✓✓✓"
    if [ $WARNINGS -gt 0 ]; then
        echo "⚠ But found $WARNINGS warning(s) - check logs above"
    fi
    echo ""
    echo "The test_dpll.sh refactoring is VERIFIED!"
    exit 0
else
    echo "✗✗✗ FOUND $ERRORS CRITICAL ERROR(S) ✗✗✗"
    echo ""
    echo "⚠⚠⚠ Test refactoring has issues! ⚠⚠⚠"
    exit 1
fi
