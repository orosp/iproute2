#!/bin/bash
# Verification script for commit 2c40599bc29933
# Verifies that DPLL_PARSE_ATTR_U32/S32/U64 macro replacements are correct

set -e

DPLL_C="../dpll.c"
ERRORS=0

echo "=== Verifying commit 2c40599bc29933: integer parsing macros ==="
echo ""

# Check that macros exist
echo "[1] Checking macro definitions..."
if grep -q "#define DPLL_PARSE_ATTR_U32" "$DPLL_C"; then
    echo "    ✓ DPLL_PARSE_ATTR_U32 macro defined"
else
    echo "    ✗ ERROR: DPLL_PARSE_ATTR_U32 macro not found"
    ERRORS=$((ERRORS + 1))
fi

if grep -q "#define DPLL_PARSE_ATTR_S32" "$DPLL_C"; then
    echo "    ✓ DPLL_PARSE_ATTR_S32 macro defined"
else
    echo "    ✗ ERROR: DPLL_PARSE_ATTR_S32 macro not found"
    ERRORS=$((ERRORS + 1))
fi

if grep -q "#define DPLL_PARSE_ATTR_U64" "$DPLL_C"; then
    echo "    ✓ DPLL_PARSE_ATTR_U64 macro defined"
else
    echo "    ✗ ERROR: DPLL_PARSE_ATTR_U64 macro not found"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Check that macros contain required elements
echo "[2] Checking macro implementation..."
for MACRO in DPLL_PARSE_ATTR_U32 DPLL_PARSE_ATTR_S32 DPLL_PARSE_ATTR_U64; do
    echo "    Checking $MACRO..."

    # Check for dpll_arg_required
    if grep -A 20 "#define $MACRO" "$DPLL_C" | grep -q "dpll_arg_required"; then
        echo "      ✓ Contains dpll_arg_required check"
    else
        echo "      ✗ ERROR: Missing dpll_arg_required check"
        ERRORS=$((ERRORS + 1))
    fi

    # Check for error handling
    if grep -A 20 "#define $MACRO" "$DPLL_C" | grep -q "pr_err"; then
        echo "      ✓ Contains error handling with pr_err"
    else
        echo "      ✗ ERROR: Missing error handling"
        ERRORS=$((ERRORS + 1))
    fi

    # Check for mnl_attr_put
    if grep -A 20 "#define $MACRO" "$DPLL_C" | grep -q "mnl_attr_put"; then
        echo "      ✓ Contains mnl_attr_put call"
    else
        echo "      ✗ ERROR: Missing mnl_attr_put call"
        ERRORS=$((ERRORS + 1))
    fi

    # Check for dpll_arg_inc
    if grep -A 20 "#define $MACRO" "$DPLL_C" | grep -q "dpll_arg_inc"; then
        echo "      ✓ Contains dpll_arg_inc call"
    else
        echo "      ✗ ERROR: Missing dpll_arg_inc call"
        ERRORS=$((ERRORS + 1))
    fi
    echo ""
done

# Check that old inline patterns were replaced
echo "[3] Checking that old inline integer parsing was replaced..."

# Old pattern for U32: get_u32(&val, ...) + mnl_attr_put_u32 + dpll_arg_inc
# Should be very few or none of these patterns outside macros
OLD_U32_PATTERN=$(grep -c 'get_u32(&.*dpll_argv(dpll)' "$DPLL_C" || echo 0)
if [ "$OLD_U32_PATTERN" -eq 0 ]; then
    echo "    ✓ No old inline U32 parsing found"
else
    echo "    ⚠ WARNING: Found $OLD_U32_PATTERN inline U32 parsing instances"
    echo "    (May be legitimate if not all patterns were replaced)"
fi

# Check macro usage
echo ""
echo "[4] Checking macro usage..."
U32_USAGE=$(grep -c "DPLL_PARSE_ATTR_U32(" "$DPLL_C" || echo 0)
S32_USAGE=$(grep -c "DPLL_PARSE_ATTR_S32(" "$DPLL_C" || echo 0)
U64_USAGE=$(grep -c "DPLL_PARSE_ATTR_U64(" "$DPLL_C" || echo 0)

echo "    DPLL_PARSE_ATTR_U32 used: $U32_USAGE times"
echo "    DPLL_PARSE_ATTR_S32 used: $S32_USAGE times"
echo "    DPLL_PARSE_ATTR_U64 used: $U64_USAGE times"
echo "    Total macro usage: $((U32_USAGE + S32_USAGE + U64_USAGE)) times"

if [ $((U32_USAGE + S32_USAGE + U64_USAGE)) -ge 7 ]; then
    echo "    ✓ Macros used at least 7 times (as expected)"
else
    echo "    ⚠ WARNING: Macros used less than 7 times"
fi
echo ""

# Verify specific attributes are using macros
echo "[5] Checking specific attribute usage..."
ATTRS_TO_CHECK="phase-offset-avg-factor clock-id prio frequency phase-adjust"

for ATTR in $ATTRS_TO_CHECK; do
    # Check if attribute is parsed using macro
    if grep -B 5 "DPLL_PARSE_ATTR_" "$DPLL_C" | grep -q "\"$ATTR\""; then
        echo "    ✓ Attribute '$ATTR' uses macro"
    else
        echo "    ? Attribute '$ATTR' not found with macro (may not be applicable)"
    fi
done
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
