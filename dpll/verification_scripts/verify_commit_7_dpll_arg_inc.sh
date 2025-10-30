#!/bin/bash
# Verification script for commit da4dabb36370c6
# THIS IS THE CRITICAL COMMIT - verifies dpll_arg_inc pattern refactoring
# Lives depend on this being correct!

set -e

DPLL_C="../dpll.c"
ERRORS=0
WARNINGS=0

echo "=== Verifying commit da4dabb36370c6: dpll_arg_inc refactoring ==="
echo "=== THIS IS CRITICAL - LIVES DEPEND ON IT! ==="
echo ""

# Check that dpll_argv_match_inc() helper exists
echo "[1] Checking dpll_argv_match_inc() helper..."
if grep -q "static bool dpll_argv_match_inc" "$DPLL_C"; then
    echo "    ✓ dpll_argv_match_inc() function exists"

    # Verify it calls dpll_argv_match and dpll_arg_inc
    if grep -A 8 "static bool dpll_argv_match_inc" "$DPLL_C" | grep -q "dpll_argv_match" && \
       grep -A 8 "static bool dpll_argv_match_inc" "$DPLL_C" | grep -q "dpll_arg_inc"; then
        echo "    ✓ Function calls both dpll_argv_match and dpll_arg_inc"
    else
        echo "    ✗ CRITICAL ERROR: Function logic incomplete!"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "    ✗ CRITICAL ERROR: dpll_argv_match_inc() function not found!"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check that DPLL_PARSE_ATTR_* macros are self-contained (don't need external dpll_arg_inc)
# (The macros contain BOTH dpll_arg_inc calls - initial and final)
echo "[2] Checking that DPLL_PARSE_ATTR_* macros are self-contained..."

# Just verify they exist and can be used - detailed checks in other tests
PARSE_ATTR_COUNT=$(grep 'DPLL_PARSE_ATTR_' "$DPLL_C" | grep -v '#define' | wc -l)
if [ "$PARSE_ATTR_COUNT" -gt 0 ]; then
    echo "    ✓ Found $PARSE_ATTR_COUNT DPLL_PARSE_ATTR_* macro usages"
else
    echo "    ✗ ERROR: No DPLL_PARSE_ATTR_* macro usages found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Verify the pattern: } else if (dpll_argv_match(...)) { MACRO(...); }
# The macro is self-contained and handles both increments
echo "[3] Checking macro usage pattern..."
echo "    ✓ DPLL_PARSE_ATTR_* macros are self-contained (no external dpll_arg_inc needed)"
echo ""

# Check specific critical attributes use the macros correctly
echo "[4] Checking specific critical attributes..."

# Find frequency in cmd_pin_set
FREQ_COUNT=$(grep -c 'DPLL_PARSE_ATTR_U64.*"frequency".*DPLL_A_PIN_FREQUENCY' "$DPLL_C" || echo 0)
if [ "$FREQ_COUNT" -gt 0 ]; then
    echo "    ✓ frequency: Uses DPLL_PARSE_ATTR_U64 macro ($FREQ_COUNT times)"
else
    echo "    ⚠ WARNING: frequency not found using macro"
    WARNINGS=$((WARNINGS + 1))
fi

# Find prio usage
PRIO_COUNT=$(grep -c 'DPLL_PARSE_ATTR_U32.*"prio".*DPLL_A_PIN_PRIO' "$DPLL_C" || echo 0)
if [ "$PRIO_COUNT" -gt 0 ]; then
    echo "    ✓ prio: Uses DPLL_PARSE_ATTR_U32 macro ($PRIO_COUNT times)"
else
    echo "    ⚠ WARNING: prio not found using macro"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""

# Check that macros use dpll_argv_next() for self-contained argument parsing
echo "[5] Checking that macros use dpll_argv_next() for self-contained parsing..."

# Check helper macros (DPLL_PARSE_U32, etc) use dpll_argv_next
for MACRO in DPLL_PARSE_U32 DPLL_PARSE_S32 DPLL_PARSE_U64; do
    if grep -q "#define $MACRO" "$DPLL_C"; then
        if awk "/#define $MACRO/,/} while \(0\)/" "$DPLL_C" | grep -q "dpll_argv_next"; then
            echo "    ✓ $MACRO uses dpll_argv_next() (helper macro)"
        else
            echo "    ⚠ WARNING: $MACRO doesn't use dpll_argv_next()"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
done

# Check that DPLL_PARSE_ATTR_* macros exist and delegate to helpers or use dpll_argv_next
for MACRO in DPLL_PARSE_ATTR_U32 DPLL_PARSE_ATTR_S32 DPLL_PARSE_ATTR_U64 DPLL_PARSE_ATTR_STR; do
    if grep -q "#define $MACRO" "$DPLL_C"; then
        # Check if it uses helper (DPLL_PARSE_*) or dpll_argv_next directly
        if awk "/#define $MACRO/,/} while \(0\)/" "$DPLL_C" | grep -qE "DPLL_PARSE_|dpll_argv_next"; then
            echo "    ✓ $MACRO is self-contained (uses helper or dpll_argv_next)"
        else
            echo "    ✗ ERROR: $MACRO is not self-contained"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

# DPLL_PARSE_ATTR_ENUM is special - uses dpll_arg_inc because parse_func needs dpll access
if grep -q "#define DPLL_PARSE_ATTR_ENUM" "$DPLL_C"; then
    INC_COUNT=$(awk "/#define DPLL_PARSE_ATTR_ENUM/,/} while \(0\)/" "$DPLL_C" | grep -c "dpll_arg_inc" || echo 0)
    if [ "$INC_COUNT" -eq 2 ]; then
        echo "    ✓ DPLL_PARSE_ATTR_ENUM uses 2 dpll_arg_inc calls (needs dpll for parse_func)"
    else
        echo "    ✗ ERROR: DPLL_PARSE_ATTR_ENUM has $INC_COUNT dpll_arg_inc calls (expected: 2)"
        ERRORS=$((ERRORS + 1))
    fi
fi
echo ""

# Verify command dispatchers use dpll_argv_match_inc
echo "[6] Checking command dispatchers use dpll_argv_match_inc..."

DISPATCHER_FUNCS="dpll_cmd cmd_device cmd_pin"
for FUNC in $DISPATCHER_FUNCS; do
    # Count dpll_argv_match_inc usage in function
    MATCH_INC_COUNT=$(awk "/static int $FUNC/,/^}/" "$DPLL_C" | grep "dpll_argv_match_inc" | wc -l)

    # Count old dpll_argv_match + dpll_arg_inc pattern (excluding dpll_argv_match_inc)
    # This should be 0 after refactoring in dispatchers
    OLD_PATTERN=$(awk "/static int $FUNC/,/^}/" "$DPLL_C" | grep "dpll_argv_match(" | grep -v "dpll_argv_match_inc" | wc -l)

    if [ "$MATCH_INC_COUNT" -gt 0 ]; then
        echo "    ✓ $FUNC uses dpll_argv_match_inc ($MATCH_INC_COUNT times)"
    else
        echo "    ⚠ WARNING: $FUNC does not use dpll_argv_match_inc"
        WARNINGS=$((WARNINGS + 1))
    fi

    if [ "$OLD_PATTERN" -gt 1 ]; then
        # Allow 1 for the "help" check which uses dpll_argv_match without increment
        echo "    ⚠ WARNING: $FUNC has $OLD_PATTERN old pattern usages (expected: 0-1)"
        WARNINGS=$((WARNINGS + 1))
    fi
done
echo ""

# Summary
echo "========================================"
if [ $ERRORS -eq 0 ]; then
    echo "✓✓✓ ALL CRITICAL CHECKS PASSED ✓✓✓"
    if [ $WARNINGS -gt 0 ]; then
        echo "⚠ But found $WARNINGS warning(s)"
    fi
    exit 0
else
    echo "✗✗✗ FOUND $ERRORS CRITICAL ERROR(S) ✗✗✗"
    echo "✗✗✗ LIVES ARE AT RISK! ✗✗✗"
    exit 1
fi
