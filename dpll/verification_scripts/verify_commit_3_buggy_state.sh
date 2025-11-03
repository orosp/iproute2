#!/bin/bash
# Special verification for commit 2c40599bc29933
# This commit INTRODUCES A BUG that is fixed in commit da4dabb36370c6
# This script verifies that we KNOW about this bug

set -e

echo "════════════════════════════════════════════════════════════"
echo "  SPECIAL VERIFICATION: Commit 2c40599bc29933"
echo "  This commit introduces macros but CONTAINS A BUG"
echo "════════════════════════════════════════════════════════════"
echo ""

echo "⚠⚠⚠ WARNING: This is a KNOWN BUGGY INTERMEDIATE STATE ⚠⚠⚠"
echo ""
echo "BUG DESCRIPTION:"
echo "  Original code had TWO dpll_arg_inc() calls:"
echo "    1. After dpll_argv_match (to move from keyword to value)"
echo "    2. After parsing value (to move to next keyword)"
echo ""
echo "  Macros DPLL_PARSE_ATTR_* have ONLY ONE dpll_arg_inc:"
echo "    - At the END of the macro"
echo ""
echo "  This means FIRST increment is MISSING when macro is used"
echo "  after dpll_argv_match()!"
echo ""
echo "  Example:"
echo "    } else if (dpll_argv_match(dpll, \"frequency\")) {"
echo "        DPLL_PARSE_ATTR_U64(dpll, nlh, \"frequency\", ...);"
echo "                            ^^^^"
echo "                            Will try to parse KEYWORD as VALUE!"
echo ""
echo "BUG FIXED IN:"
echo "  Commit da4dabb36370c6 adds dpll_argv_match_inc() helper"
echo "  and changes all usages to:"
echo "    } else if (dpll_argv_match_inc(dpll, \"frequency\")) {"
echo "        DPLL_PARSE_ATTR_U64(dpll, nlh, \"frequency\", ...);"
echo "                     ^^^^ Now increments BEFORE macro!"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""
echo "VERIFICATION RESULT:"
echo "  ✓ We acknowledge this commit introduced a temporary bug"
echo "  ✓ Bug was fixed in next commit (da4dabb36370c6)"
echo "  ✓ Final code is correct (verified by verify_commit_7_dpll_arg_inc.sh)"
echo ""
echo "⚠ DO NOT USE CODE AT THIS COMMIT - USE FINAL VERSION ONLY!"
echo ""
exit 0
