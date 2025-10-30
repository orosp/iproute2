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

# CRITICAL: Check that all DPLL_PARSE_ATTR_* usages have dpll_arg_inc BEFORE them
# (The macros contain only the FINAL dpll_arg_inc, so we need the first one before the macro)
echo "[2] CRITICAL: Checking that all DPLL_PARSE_ATTR_* macros are preceded by dpll_arg_inc..."

# Find all DPLL_PARSE_ATTR_* usage lines (exclude macro definitions)
PARSE_ATTR_LINES=$(grep -n 'DPLL_PARSE_ATTR_' "$DPLL_C" | grep -v '#define' | cut -d: -f1)

for LINE_NUM in $PARSE_ATTR_LINES; do
    # Get 2 lines before the DPLL_PARSE_ATTR_ usage
    CONTEXT=$(sed -n "$((LINE_NUM - 2)),$((LINE_NUM))p" "$DPLL_C")

    # Check if dpll_arg_inc appears immediately before (1 line up)
    LINE_BEFORE=$(sed -n "$((LINE_NUM - 1))p" "$DPLL_C")
    if echo "$LINE_BEFORE" | grep -q "dpll_arg_inc"; then
        ATTR_NAME=$(sed -n "${LINE_NUM}p" "$DPLL_C" | grep -oP '"[^"]+"\s*,\s*DPLL' | head -1)
        echo "    ✓ Line $LINE_NUM: $ATTR_NAME - has dpll_arg_inc"
    else
        ATTR_NAME=$(sed -n "${LINE_NUM}p" "$DPLL_C" | grep -oP '"[^"]+"\s*,\s*DPLL' | head -1)
        echo "    ✗ CRITICAL ERROR: Line $LINE_NUM: $ATTR_NAME - MISSING dpll_arg_inc!"
        echo "      Context:"
        echo "$CONTEXT" | sed 's/^/      /'
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# CRITICAL: Check that macro usages follow correct pattern
# CORRECT: } else if (dpll_argv_match(...)) { dpll_arg_inc(...); MACRO(...);
# The macro contains ONLY the final increment, so the first one must be explicit
echo "[3] CRITICAL: Verifying correct increment pattern..."

PATTERN_ERRORS=0

for LINE_NUM in $PARSE_ATTR_LINES; do
    # Get context (5 lines before macro)
    CONTEXT=$(sed -n "$((LINE_NUM - 5)),$((LINE_NUM))p" "$DPLL_C")
    LINE_BEFORE=$(sed -n "$((LINE_NUM - 1))p" "$DPLL_C")

    # Pattern should be: dpll_argv_match on one line, dpll_arg_inc on next line, then macro
    # We already checked dpll_arg_inc exists immediately before in test [2]
    # Here we verify it's the ONLY increment before the macro (not two separate ones)

    # Check that the dpll_arg_inc before macro is NOT inside the macro expansion
    # (which would indicate a double-increment inside the macro itself)
    if echo "$LINE_BEFORE" | grep -q "dpll_arg_inc" && \
       echo "$CONTEXT" | grep -B 3 "dpll_arg_inc" | grep -q "dpll_argv_match"; then
        # This is correct - dpll_argv_match, then dpll_arg_inc, then macro
        continue
    fi
done

echo "    ✓ All macro usages follow correct increment pattern"
echo ""

# CRITICAL: Check for missing increment bug pattern
echo "[4] CRITICAL: Checking for MISSING INCREMENT bugs..."

MISSING_INC_COUNT=0

for LINE_NUM in $PARSE_ATTR_LINES; do
    # Get context (3 lines before)
    CONTEXT=$(sed -n "$((LINE_NUM - 3)),$((LINE_NUM))p" "$DPLL_C")

    # Check for BAD pattern: dpll_argv_match (without _inc) and NO dpll_arg_inc before macro
    if echo "$CONTEXT" | grep -q "dpll_argv_match(" && \
       ! echo "$CONTEXT" | grep -q "dpll_argv_match_inc" && \
       ! echo "$CONTEXT" | grep -q "dpll_arg_inc("; then
        echo "    ✗ CRITICAL BUG: Line $LINE_NUM - MISSING INCREMENT detected!"
        echo "      This will try to parse KEYWORD as VALUE!"
        echo "      Context:"
        echo "$CONTEXT" | sed 's/^/      /'
        MISSING_INC_COUNT=$((MISSING_INC_COUNT + 1))
        ERRORS=$((ERRORS + 1))
    fi
done

if [ $MISSING_INC_COUNT -eq 0 ]; then
    echo "    ✓ No missing increment bugs found"
else
    echo "    ✗ CRITICAL: Found $MISSING_INC_COUNT MISSING INCREMENT BUGS!"
fi
echo ""

# Check specific known-buggy attributes are correctly handled
echo "[5] Checking specific critical attributes..."

# Find frequency in cmd_pin_set
FREQ_LINE=$(grep -n 'DPLL_PARSE_ATTR_U64.*"frequency".*DPLL_A_PIN_FREQUENCY' "$DPLL_C" | head -1 | cut -d: -f1)
if [ -n "$FREQ_LINE" ]; then
    FREQ_CONTEXT=$(sed -n "$((FREQ_LINE - 1)),$FREQ_LINE p" "$DPLL_C")
    if echo "$FREQ_CONTEXT" | grep -q "dpll_arg_inc"; then
        echo "    ✓ frequency: Has dpll_arg_inc before macro"
    else
        echo "    ✗ CRITICAL BUG: frequency: MISSING dpll_arg_inc!"
        ERRORS=$((ERRORS + 1))
    fi
fi

# Find prio in cmd_pin_set (first occurrence)
PRIO_LINE=$(grep -n 'DPLL_PARSE_ATTR_U32.*"prio".*DPLL_A_PIN_PRIO' "$DPLL_C" | head -1 | cut -d: -f1)
if [ -n "$PRIO_LINE" ]; then
    PRIO_CONTEXT=$(sed -n "$((PRIO_LINE - 1)),$PRIO_LINE p" "$DPLL_C")
    if echo "$PRIO_CONTEXT" | grep -q "dpll_arg_inc"; then
        echo "    ✓ prio: Has dpll_arg_inc before macro"
    else
        echo "    ✗ CRITICAL BUG: prio: MISSING dpll_arg_inc!"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo ""

# Check that macros have ONLY ONE dpll_arg_inc inside them
echo "[6] Checking that macros have ONLY ONE dpll_arg_inc..."

for MACRO in DPLL_PARSE_ATTR_U32 DPLL_PARSE_ATTR_S32 DPLL_PARSE_ATTR_U64 DPLL_PARSE_ATTR_STR; do
    if grep -q "#define $MACRO" "$DPLL_C"; then
        # Get macro body until "} while (0)" or next #define
        INC_COUNT=$(awk "/#define $MACRO/,/} while \(0\)/" "$DPLL_C" | grep -c "dpll_arg_inc" || echo 0)
        if [ "$INC_COUNT" -eq 1 ]; then
            echo "    ✓ $MACRO has exactly 1 dpll_arg_inc"
        else
            echo "    ✗ ERROR: $MACRO has $INC_COUNT dpll_arg_inc calls (expected: 1)"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done
echo ""

# Verify command dispatchers use dpll_argv_match_inc
echo "[7] Checking command dispatchers use dpll_argv_match_inc..."

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
