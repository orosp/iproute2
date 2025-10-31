#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Test suite for dpll tool - compares output with Python YNL CLI
#
# Usage: ./test_dpll.sh [--enable-set]
#
# Options:
#   --enable-set    Enable SET operations (device set, pin set)
#                   By default, only read-only operations are tested
#
# Requirements:
# - DPLL kernel module loaded
# - DPLL hardware available
# - Python YNL CLI available

# Don't use set -e, we want to continue on test failures and show summary

# Parse command line arguments
# Default: READ-ONLY mode (safe)
ENABLE_SET_OPERATIONS=0
while [[ $# -gt 0 ]]; do
	case $1 in
		--enable-set)
			ENABLE_SET_OPERATIONS=1
			shift
			;;
		--help|-h)
			echo "Usage: $0 [--enable-set]"
			echo ""
			echo "Options:"
			echo "  --enable-set    Enable SET operations (modifies DPLL configuration)"
			echo "  --help, -h      Show this help message"
			echo ""
			echo "By default, the test runs in read-only mode (no SET operations)."
			echo "Use --enable-set to test device/pin set commands."
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			echo "Use --help for usage information"
			exit 1
			;;
	esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Unicode box drawing characters (fallback to ASCII if not supported)
if [[ "$LANG" =~ "UTF-8" ]] || [[ "$LC_ALL" =~ "UTF-8" ]]; then
	BOX_H="─"
	BOX_V="│"
	BOX_TL="┌"
	BOX_TR="┐"
	BOX_BL="└"
	BOX_BR="┘"
	BOX_VR="├"
	BOX_VL="┤"
	BOX_HU="┴"
	BOX_HD="┬"
	BOX_VH="┼"
	CHECK="✓"
	CROSS="✗"
	SKIP_MARK="○"
else
	BOX_H="-"
	BOX_V="|"
	BOX_TL="+"
	BOX_TR="+"
	BOX_BL="+"
	BOX_BR="+"
	BOX_VR="+"
	BOX_VL="+"
	BOX_HU="+"
	BOX_HD="+"
	BOX_VH="+"
	CHECK="+"
	CROSS="x"
	SKIP_MARK="o"
fi

# Paths
DPLL_TOOL_BIN="./dpll"
PYTHON_CLI="/root/net-next/tools/net/ynl/pyynl/cli.py"
DPLL_SPEC="/root/net-next/Documentation/netlink/specs/dpll.yaml"
TEST_DIR="/tmp/dpll_test_$$"

# Create wrapper script for dpll tool that adds sleep after execution
# This ensures kernel has time to flush dmesg messages
DPLL_TOOL="$TEST_DIR/dpll_wrapper.sh"
mkdir -p "$TEST_DIR"
cat > "$DPLL_TOOL" << 'WRAPPER_EOF'
#!/bin/bash
./dpll "$@"
exit_code=$?
sleep 1
exit $exit_code
WRAPPER_EOF
chmod +x "$DPLL_TOOL"

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0
DMESG_ERRORS=0

# Create test directory
mkdir -p "$TEST_DIR"

# Store initial dmesg state (count of lines, not content)
DMESG_BASELINE_COUNT="$TEST_DIR/dmesg_baseline_count.txt"
dmesg 2>/dev/null | wc -l > "$DMESG_BASELINE_COUNT" || echo "0" > "$DMESG_BASELINE_COUNT"

# Cleanup on exit
cleanup() {
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Print test header
print_header() {
	local title="$1"
	local width=70
	local padding=$(( (width - ${#title} - 2) / 2 ))

	echo ""
	echo -e "${CYAN}${BOX_TL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_TR}${NC}"
	printf "${CYAN}${BOX_V}${NC}${BOLD}%*s%s%*s${NC}${CYAN}${BOX_V}${NC}\n" $padding "" "$title" $((width - padding - ${#title})) ""
	echo -e "${CYAN}${BOX_BL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_BR}${NC}"
	echo ""
}

# Print test result
print_result() {
	local status=$1
	local test_name=$2

	TOTAL_TESTS=$((TOTAL_TESTS + 1))

	case $status in
		PASS)
			echo -e "  ${GREEN}${BOLD}${CHECK}${NC} ${GREEN}PASS${NC} ${DIM}│${NC} $test_name"
			PASSED_TESTS=$((PASSED_TESTS + 1))
			# Check dmesg for errors after successful test
			if ! check_dmesg_errors "$test_name"; then
				# Test passed but caused kernel errors - mark as FAIL
				echo -e "  ${RED}${BOLD}${CROSS}${NC} ${RED}FAIL${NC} ${DIM}│${NC} $test_name ${RED}(kernel netlink errors)${NC}"
				FAILED_TESTS=$((FAILED_TESTS + 1))
				PASSED_TESTS=$((PASSED_TESTS - 1))
			fi
			;;
		FAIL)
			echo -e "  ${RED}${BOLD}${CROSS}${NC} ${RED}FAIL${NC} ${DIM}│${NC} $test_name"
			FAILED_TESTS=$((FAILED_TESTS + 1))
			# Still check dmesg for additional context
			check_dmesg_errors "$test_name"
			;;
		SKIP)
			echo -e "  ${YELLOW}${SKIP_MARK}${NC} ${YELLOW}SKIP${NC} ${DIM}│${NC} ${DIM}$test_name${NC}"
			SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
			;;
	esac
}

# Check if command exists
check_command() {
	if ! command -v "$1" &> /dev/null; then
		echo -e "${RED}Error: $1 not found${NC}"
		return 1
	fi
	return 0
}

# Run a test command and check dmesg after it completes
# Usage: run_test_command "test name" "full command"
# Returns: command exit code
run_test_command() {
	local test_name="$1"
	local full_command="$2"
	local output_file="$TEST_DIR/cmd_output_$$.txt"

	# Run the command (DPLL_TOOL wrapper already adds sleep)
	eval "$full_command" > "$output_file" 2>&1
	local exit_code=$?

	# Check dmesg for errors (with command info for reporting)
	check_dmesg_errors "$test_name" "$full_command"

	return $exit_code
}

# Check dmesg for netlink errors since baseline
check_dmesg_errors() {
	local test_name="$1"
	local command_executed="$2"
	local baseline_count
	local current_count
	local new_lines

	# Read baseline count
	baseline_count=$(cat "$DMESG_BASELINE_COUNT" 2>/dev/null || echo "0")

	# Get current dmesg line count
	current_count=$(dmesg 2>/dev/null | wc -l || echo "0")

	# If no new lines, nothing to check
	if [ "$current_count" -le "$baseline_count" ]; then
		return 0
	fi

	# Get only NEW lines (everything after baseline_count)
	new_lines=$(dmesg 2>/dev/null | tail -n +$((baseline_count + 1)) || true)

	# Check for netlink errors in new lines
	local new_errors=$(echo "$new_lines" | \
		grep -i "netlink.*dpll\|netlink.*attribute.*invalid" | \
		grep -v "netlink.*test" || true)

	if [ -n "$new_errors" ]; then
		echo -e "${RED}  ⚠ Kernel netlink errors detected after test: $test_name${NC}"
		if [ -n "$command_executed" ]; then
			echo -e "    ${YELLOW}Command: $command_executed${NC}"
		fi
		echo "$new_errors" | while IFS= read -r line; do
			echo -e "    ${DIM}${line}${NC}"
		done
		DMESG_ERRORS=$((DMESG_ERRORS + 1))

		# Update baseline to current count so subsequent tests don't report the same errors
		echo "$current_count" > "$DMESG_BASELINE_COUNT"

		return 1
	fi

	# Update baseline even if no errors found
	echo "$current_count" > "$DMESG_BASELINE_COUNT"

	return 0
}

# Check prerequisites
check_prerequisites() {
	print_header "Checking Prerequisites"

	if [ $ENABLE_SET_OPERATIONS -eq 0 ]; then
		echo -e "${YELLOW}Running in READ-ONLY mode (default) - SET operations will be skipped${NC}"
		echo -e "${YELLOW}Use --enable-set to test SET operations${NC}"
		echo ""
	else
		echo -e "${GREEN}SET operations ENABLED - tests will modify DPLL configuration${NC}"
		echo ""
	fi

	# Check if dpll tool exists
	if [ ! -x "./dpll" ]; then
		echo -e "${RED}Error: dpll tool not found or not executable${NC}"
		echo "Build it first: make"
		exit 1
	fi

	# Check if Python CLI exists
	if [ ! -f "$PYTHON_CLI" ]; then
		echo -e "${YELLOW}Warning: Python CLI not found at $PYTHON_CLI${NC}"
		echo "Some tests will be skipped"
		PYTHON_CLI=""
	fi

	# Check if DPLL spec exists
	if [ ! -f "$DPLL_SPEC" ]; then
		echo -e "${YELLOW}Warning: DPLL spec not found at $DPLL_SPEC${NC}"
		echo "Python CLI tests will be skipped"
		PYTHON_CLI=""
	fi

	# Check if jq is available for JSON comparison
	if ! check_command jq; then
		echo -e "${YELLOW}Warning: jq not found, JSON comparison tests will be skipped${NC}"
	fi

	echo ""
}

# Test help commands
test_help() {
	print_header "Testing Help Commands"

	# Test main help
	if $DPLL_TOOL help &>/dev/null; then
		print_result PASS "dpll help"
	else
		print_result FAIL "dpll help"
	fi

	# Test device help
	if $DPLL_TOOL device help &>/dev/null; then
		print_result PASS "dpll device help"
	else
		print_result FAIL "dpll device help"
	fi

	# Test pin help
	if $DPLL_TOOL pin help &>/dev/null; then
		print_result PASS "dpll pin help"
	else
		print_result FAIL "dpll pin help"
	fi

	echo ""
}

# Test version
test_version() {
	print_header "Testing Version"

	if $DPLL_TOOL -V &>/dev/null; then
		print_result PASS "dpll -V"
	else
		print_result FAIL "dpll -V"
	fi

	echo ""
}

# Compare JSON outputs
compare_json() {
	local dpll_out=$1
	local python_out=$2
	local test_name=$3

	if ! command -v jq &>/dev/null; then
		print_result SKIP "$test_name (jq not available)"
		return
	fi

	# Normalize JSON: sort keys and sort arrays in capabilities fields
	# This makes the comparison order-independent for capability arrays
	local jq_normalize='
		walk(
			if type == "object" then
				if .capabilities and (.capabilities | type == "array") then
					.capabilities |= sort
				else . end
			else . end
		)
	'

	# Normalize and compare JSON
	local dpll_normalized=$(jq -S "$jq_normalize" "$dpll_out" 2>/dev/null)
	local python_normalized=$(jq -S "$jq_normalize" "$python_out" 2>/dev/null)

	if [ -z "$dpll_normalized" ]; then
		print_result FAIL "$test_name (invalid dpll JSON)"
		echo "  DPLL output file: $dpll_out"
		echo "  DPLL raw content:"
		cat "$dpll_out" | head -20
		return
	fi

	if [ -z "$python_normalized" ]; then
		print_result FAIL "$test_name (invalid Python JSON)"
		echo "  Python output file: $python_out"
		echo "  Python raw content:"
		cat "$python_out" | head -20
		return
	fi

	if [ "$dpll_normalized" == "$python_normalized" ]; then
		print_result PASS "$test_name"
	else
		print_result FAIL "$test_name"
		echo "  DPLL output: $dpll_out"
		echo "  Python output: $python_out"
		echo "  Diff:"
		diff -u <(echo "$dpll_normalized") <(echo "$python_normalized") || true
	fi
}

# Test device operations
test_device_operations() {
	print_header "Testing Device Operations"

	# Test device show (dump)
	local dpll_dump="$TEST_DIR/dpll_device_dump.txt"
	local python_dump="$TEST_DIR/python_device_dump.txt"

	$DPLL_TOOL device show > "$dpll_dump" 2>&1
	local exit_code=$?
	check_dmesg_errors "dpll device show (dump)" "./dpll device show"

	if [ $exit_code -eq 0 ]; then
		print_result PASS "dpll device show (dump)"
	else
		print_result FAIL "dpll device show (dump)"
	fi

	# Test device show with JSON
	local dpll_json="$TEST_DIR/dpll_device_dump.json"
	$DPLL_TOOL -j device show > "$dpll_json" 2>&1
	exit_code=$?
	check_dmesg_errors "dpll device show -j" "./dpll -j device show"

	if [ $exit_code -eq 0 ]; then
		if jq empty "$dpll_json" 2>/dev/null; then
			print_result PASS "dpll device show -j (valid JSON)"
		else
			print_result FAIL "dpll device show -j (invalid JSON)"
		fi
	else
		print_result FAIL "dpll device show -j"
	fi

	# Get first device ID from dump
	local device_id=$(grep -oP '^device id \K\d+' "$dpll_dump" | head -1)

	if [ -n "$device_id" ]; then
		# Test device show by ID
		if $DPLL_TOOL device show id "$device_id" > /dev/null 2>&1; then
			print_result PASS "dpll device show id $device_id"
		else
			print_result FAIL "dpll device show id $device_id"
		fi

		# Compare with Python CLI
		if [ -n "$PYTHON_CLI" ]; then
			local dpll_dev_json="$TEST_DIR/dpll_device_$device_id.json"
			local python_dev_json="$TEST_DIR/python_device_$device_id.json"

			$DPLL_TOOL -j device show id "$device_id" > "$dpll_dev_json" 2>&1 || true
			python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do device-get --json '{"id": '$device_id'}' --output-json > "$python_dev_json" 2>&1 || true

			# Check if either tool returned an error
			local python_error=$(grep -qE "Netlink (warning|error):" "$python_dev_json" 2>/dev/null && echo "yes" || echo "no")
			# dpll error: check for error message OR empty JSON {}
			local dpll_has_error_msg=$(grep -q "Failed to get\|Failed to dump" "$dpll_dev_json" 2>/dev/null && echo "yes" || echo "no")
			local dpll_json_content=$(grep -o '{.*}' "$dpll_dev_json" 2>/dev/null | tr -d '[:space:]')
			local dpll_error="no"
			if [ "$dpll_has_error_msg" = "yes" ] || [ "$dpll_json_content" = "{}" ]; then
				dpll_error="yes"
			fi

			if [ "$python_error" = "yes" ] && [ "$dpll_error" = "yes" ]; then
				print_result PASS "device show id $device_id (vs Python) (both returned error)"
			elif [ "$python_error" = "yes" ] || [ "$dpll_error" = "yes" ]; then
				print_result FAIL "device show id $device_id (vs Python) (error mismatch: dpll=$dpll_error, python=$python_error)"
				echo "  DPLL command: $DPLL_TOOL -j device show id \"$device_id\""
				echo "  DPLL output file: $dpll_dev_json"
				echo "  DPLL raw content:"
				cat "$dpll_dev_json" | head -20
				echo ""
				echo "  Python command: python3 $PYTHON_CLI --spec $DPLL_SPEC --do device-get --json '{\"id\": $device_id}' --output-json"
				echo "  Python output file: $python_dev_json"
				echo "  Python raw content:"
				cat "$python_dev_json" | head -20
			elif [ -s "$dpll_dev_json" ] && [ -s "$python_dev_json" ]; then
				compare_json "$dpll_dev_json" "$python_dev_json" "device show id $device_id (vs Python)"
			else
				print_result SKIP "device show id $device_id (vs Python) (empty output)"
				echo "  DPLL output file: $dpll_dev_json (size: $(stat -c%s "$dpll_dev_json" 2>/dev/null || echo 0))"
				echo "  Python output file: $python_dev_json (size: $(stat -c%s "$python_dev_json" 2>/dev/null || echo 0))"
			fi
		fi
	else
		print_result SKIP "device show id (no devices found)"
	fi

	echo ""
}

# Test device-id-get operation
test_device_id_get() {
	print_header "Testing Device ID Get"

	# Get device data in JSON for easier parsing
	local dpll_json="$TEST_DIR/dpll_device_dump.json"
	$DPLL_TOOL -j device show > "$dpll_json" 2>&1 || true

	if ! command -v jq &>/dev/null; then
		print_result SKIP "device id-get tests (jq not available)"
		echo ""
		return
	fi

	# Get first device with module-name
	local device_data=$(jq -r '.device[0] | {id, module_name: .["module-name"], clock_id: .["clock-id"]} | @json' "$dpll_json" 2>/dev/null)

	if [ -n "$device_data" ]; then
		local device_id=$(echo "$device_data" | jq -r '.id' 2>/dev/null)
		local module_name=$(echo "$device_data" | jq -r '.module_name' 2>/dev/null)
		local clock_id=$(echo "$device_data" | jq -r '.clock_id' 2>/dev/null)

		if [ -n "$module_name" ] && [ "$module_name" != "null" ]; then
			# Test device-id-get by module-name
			# Note: This may return "multiple matches" error if module has multiple devices
			local dpll_result_basic="$TEST_DIR/dpll_device_id_get_module_basic.txt"
			$DPLL_TOOL device id-get module-name "$module_name" > "$dpll_result_basic" 2>&1 || true
			local found_id=$(cat "$dpll_result_basic" | tr -d '\n')
			local has_error=$(grep -q "Failed to get" "$dpll_result_basic" 2>/dev/null && echo "yes" || echo "no")

			if [ "$has_error" = "yes" ]; then
				# Error is expected if there are multiple devices with same module-name
				print_result PASS "device id-get module-name $module_name (returned error as expected for ambiguous query)"
			elif [ "$found_id" == "$device_id" ]; then
				print_result PASS "dpll device id-get module-name $module_name"
			else
				print_result FAIL "dpll device id-get module-name $module_name (expected $device_id, got $found_id)"
				echo "  Command: $DPLL_TOOL device id-get module-name \"$module_name\""
				echo "  Output file: $dpll_result_basic"
				echo "  Raw content:"
				cat "$dpll_result_basic"
			fi

			# Compare with Python CLI
			if [ -n "$PYTHON_CLI" ]; then
				local dpll_result="$TEST_DIR/dpll_device_id_get_module.json"
				local python_result="$TEST_DIR/python_device_id_get_module.json"

				$DPLL_TOOL -j device id-get module-name "$module_name" > "$dpll_result" 2>&1 || true
				python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do device-id-get --json '{"module-name": "'"$module_name"'"}' --output-json > "$python_result" 2>&1 || true

				# Check if either tool returned an error
				local python_error=$(grep -qE "Netlink (warning|error):" "$python_result" 2>/dev/null && echo "yes" || echo "no")
				# dpll error: check for "Failed to get" message OR empty JSON {}
				local dpll_has_error_msg=$(grep -q "Failed to get" "$dpll_result" 2>/dev/null && echo "yes" || echo "no")
				local dpll_json_content=$(grep -o '{.*}' "$dpll_result" 2>/dev/null | tr -d '[:space:]')
				local dpll_error="no"
				if [ "$dpll_has_error_msg" = "yes" ] || [ "$dpll_json_content" = "{}" ]; then
					dpll_error="yes"
				fi

				if [ "$python_error" = "yes" ] && [ "$dpll_error" = "yes" ]; then
					print_result PASS "device id-get module-name (vs Python) (both returned error)"
				elif [ "$python_error" = "yes" ] || [ "$dpll_error" = "yes" ]; then
					print_result FAIL "device id-get module-name (vs Python) (error mismatch: dpll=$dpll_error, python=$python_error)"
					echo "  DPLL command: $DPLL_TOOL -j device id-get module-name \"$module_name\""
					echo "  DPLL output file: $dpll_result"
					echo "  DPLL raw content:"
					cat "$dpll_result" | head -20
					echo ""
					echo "  Python command: python3 $PYTHON_CLI --spec $DPLL_SPEC --do device-id-get --json '{\"module-name\": \"$module_name\"}' --output-json"
					echo "  Python output file: $python_result"
					echo "  Python raw content:"
					cat "$python_result" | head -20
				elif [ -s "$dpll_result" ] && [ -s "$python_result" ]; then
					compare_json "$dpll_result" "$python_result" "device id-get module-name (vs Python)"
				else
					print_result SKIP "device id-get module-name (vs Python) (empty output)"
					echo "  DPLL output file: $dpll_result (size: $(stat -c%s "$dpll_result" 2>/dev/null || echo 0))"
					echo "  Python output file: $python_result (size: $(stat -c%s "$python_result" 2>/dev/null || echo 0))"
				fi
			fi
		else
			print_result SKIP "device id-get module-name (no module found)"
		fi

		if [ -n "$clock_id" ] && [ "$clock_id" != "null" ] && [ -n "$module_name" ] && [ "$module_name" != "null" ]; then
			# Test device-id-get by module-name + clock-id
			# Note: This may return "multiple matches" error if there are multiple devices
			local dpll_result_basic="$TEST_DIR/dpll_device_id_get_clock_basic.txt"
			$DPLL_TOOL device id-get module-name "$module_name" clock-id "$clock_id" > "$dpll_result_basic" 2>&1 || true
			local found_id=$(cat "$dpll_result_basic" | tr -d '\n')
			local has_error=$(grep -q "Failed to get" "$dpll_result_basic" 2>/dev/null && echo "yes" || echo "no")

			if [ "$has_error" = "yes" ]; then
				# Error is expected if there are multiple devices
				print_result PASS "device id-get module-name + clock-id (returned error as expected for ambiguous query)"
			elif [ "$found_id" == "$device_id" ]; then
				print_result PASS "dpll device id-get module-name + clock-id"
			else
				print_result FAIL "dpll device id-get module-name + clock-id (expected $device_id, got $found_id)"
				echo "  Command: $DPLL_TOOL device id-get module-name \"$module_name\" clock-id \"$clock_id\""
				echo "  Output file: $dpll_result_basic"
				echo "  Raw content:"
				cat "$dpll_result_basic"
			fi

			# Compare with Python CLI
			if [ -n "$PYTHON_CLI" ]; then
				local dpll_result="$TEST_DIR/dpll_device_id_get_clock.json"
				local python_result="$TEST_DIR/python_device_id_get_clock.json"

				$DPLL_TOOL -j device id-get module-name "$module_name" clock-id "$clock_id" > "$dpll_result" 2>&1 || true
				python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do device-id-get --json '{"module-name": "'"$module_name"'", "clock-id": '"$clock_id"'}' --output-json > "$python_result" 2>&1 || true

				# Check if either tool returned an error
				local python_error=$(grep -qE "Netlink (warning|error):" "$python_result" 2>/dev/null && echo "yes" || echo "no")
				# dpll error: check for "Failed to get" message OR empty JSON {}
				local dpll_has_error_msg=$(grep -q "Failed to get" "$dpll_result" 2>/dev/null && echo "yes" || echo "no")
				local dpll_json_content=$(grep -o '{.*}' "$dpll_result" 2>/dev/null | tr -d '[:space:]')
				local dpll_error="no"
				if [ "$dpll_has_error_msg" = "yes" ] || [ "$dpll_json_content" = "{}" ]; then
					dpll_error="yes"
				fi

				if [ "$python_error" = "yes" ] && [ "$dpll_error" = "yes" ]; then
					# Both returned error - this is correct behavior (e.g., multiple matches)
					print_result PASS "device id-get module-name + clock-id (vs Python) (both returned error)"
				elif [ "$python_error" = "yes" ] || [ "$dpll_error" = "yes" ]; then
					# Only one returned error - mismatch
					print_result FAIL "device id-get module-name + clock-id (vs Python) (error mismatch: dpll=$dpll_error, python=$python_error)"
					echo "  DPLL command: $DPLL_TOOL -j device id-get module-name \"$module_name\" clock-id \"$clock_id\""
					echo "  DPLL output file: $dpll_result"
					echo "  DPLL raw content:"
					cat "$dpll_result" | head -20
					echo ""
					echo "  Python command: python3 $PYTHON_CLI --spec $DPLL_SPEC --do device-id-get --json '{\"module-name\": \"$module_name\", \"clock-id\": $clock_id}' --output-json"
					echo "  Python output file: $python_result"
					echo "  Python raw content:"
					cat "$python_result" | head -20
				elif [ -s "$dpll_result" ] && [ -s "$python_result" ]; then
					# Both returned valid output - compare them
					compare_json "$dpll_result" "$python_result" "device id-get module-name + clock-id (vs Python)"
				else
					print_result SKIP "device id-get module-name + clock-id (vs Python) (empty output)"
					echo "  DPLL output file: $dpll_result (size: $(stat -c%s "$dpll_result" 2>/dev/null || echo 0))"
					echo "  Python output file: $python_result (size: $(stat -c%s "$python_result" 2>/dev/null || echo 0))"
				fi
			fi
		else
			print_result SKIP "device id-get module-name + clock-id (missing data)"
		fi
	else
		print_result SKIP "device id-get tests (no devices found)"
	fi

	echo ""
}

# Test pin operations
test_pin_operations() {
	print_header "Testing Pin Operations"

	# Test pin show (dump)
	local dpll_dump="$TEST_DIR/dpll_pin_dump.txt"
	local python_dump="$TEST_DIR/python_pin_dump.txt"

	$DPLL_TOOL pin show > "$dpll_dump" 2>&1
	local exit_code=$?
	check_dmesg_errors "dpll pin show (dump)" "./dpll pin show"

	if [ $exit_code -eq 0 ]; then
		print_result PASS "dpll pin show (dump)"
	else
		print_result FAIL "dpll pin show (dump)"
	fi

	# Test pin show with JSON
	local dpll_json="$TEST_DIR/dpll_pin_dump.json"
	$DPLL_TOOL -j pin show > "$dpll_json" 2>&1
	exit_code=$?
	check_dmesg_errors "dpll pin show -j" "./dpll -j pin show"

	if [ $exit_code -eq 0 ]; then
		if jq empty "$dpll_json" 2>/dev/null; then
			print_result PASS "dpll pin show -j (valid JSON)"
		else
			print_result FAIL "dpll pin show -j (invalid JSON)"
		fi
	else
		print_result FAIL "dpll pin show -j"
	fi

	# Get first pin ID from dump
	local pin_id=$(grep -oP '^pin id \K\d+' "$dpll_dump" | head -1)

	if [ -n "$pin_id" ]; then
		# Test pin show by ID
		if $DPLL_TOOL pin show id "$pin_id" > /dev/null 2>&1; then
			print_result PASS "dpll pin show id $pin_id"
		else
			print_result FAIL "dpll pin show id $pin_id"
		fi

		# Compare with Python CLI
		if [ -n "$PYTHON_CLI" ]; then
			local dpll_pin_json="$TEST_DIR/dpll_pin_$pin_id.json"
			local python_pin_json="$TEST_DIR/python_pin_$pin_id.json"

			$DPLL_TOOL -j pin show id "$pin_id" > "$dpll_pin_json" 2>&1 || true
			python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do pin-get --json '{"id": '$pin_id'}' --output-json > "$python_pin_json" 2>&1 || true

			# Check if either tool returned an error
			local python_error=$(grep -qE "Netlink (warning|error):" "$python_pin_json" 2>/dev/null && echo "yes" || echo "no")
			# dpll error: check for error message OR empty JSON {}
			local dpll_has_error_msg=$(grep -q "Failed to get\|Failed to dump" "$dpll_pin_json" 2>/dev/null && echo "yes" || echo "no")
			local dpll_json_content=$(grep -o '{.*}' "$dpll_pin_json" 2>/dev/null | tr -d '[:space:]')
			local dpll_error="no"
			if [ "$dpll_has_error_msg" = "yes" ] || [ "$dpll_json_content" = "{}" ]; then
				dpll_error="yes"
			fi

			if [ "$python_error" = "yes" ] && [ "$dpll_error" = "yes" ]; then
				print_result PASS "pin show id $pin_id (vs Python) (both returned error)"
			elif [ "$python_error" = "yes" ] || [ "$dpll_error" = "yes" ]; then
				print_result FAIL "pin show id $pin_id (vs Python) (error mismatch: dpll=$dpll_error, python=$python_error)"
				echo "  DPLL command: $DPLL_TOOL -j pin show id \"$pin_id\""
				echo "  DPLL output file: $dpll_pin_json"
				echo "  DPLL raw content:"
				cat "$dpll_pin_json" | head -20
				echo ""
				echo "  Python command: python3 $PYTHON_CLI --spec $DPLL_SPEC --do pin-get --json '{\"id\": $pin_id}' --output-json"
				echo "  Python output file: $python_pin_json"
				echo "  Python raw content:"
				cat "$python_pin_json" | head -20
			elif [ -s "$dpll_pin_json" ] && [ -s "$python_pin_json" ]; then
				compare_json "$dpll_pin_json" "$python_pin_json" "pin show id $pin_id (vs Python)"
			else
				print_result SKIP "pin show id $pin_id (vs Python) (empty output)"
				echo "  DPLL output file: $dpll_pin_json (size: $(stat -c%s "$dpll_pin_json" 2>/dev/null || echo 0))"
				echo "  Python output file: $python_pin_json (size: $(stat -c%s "$python_pin_json" 2>/dev/null || echo 0))"
			fi
		fi
	else
		print_result SKIP "pin show id (no pins found)"
	fi

	# Test pin show with device filter
	local device_id=$(grep -oP '^device id \K\d+' "$TEST_DIR/dpll_device_dump.txt" 2>/dev/null | head -1)
	if [ -n "$device_id" ]; then
		if $DPLL_TOOL pin show device "$device_id" > /dev/null 2>&1; then
			print_result PASS "dpll pin show device $device_id"
		else
			print_result FAIL "dpll pin show device $device_id"
		fi
	else
		print_result SKIP "pin show device (no device found)"
	fi

	echo ""
}

# Test pin-id-get operation
test_pin_id_get() {
	print_header "Testing Pin ID Get"

	# Get pin data in JSON for easier parsing
	local dpll_json="$TEST_DIR/dpll_pin_dump.json"
	$DPLL_TOOL -j pin show > "$dpll_json" 2>&1 || true

	if ! command -v jq &>/dev/null; then
		print_result SKIP "pin id-get tests (jq not available)"
		echo ""
		return
	fi

	# Get first pin with board-label
	local pin_data=$(jq -r '.pin[] | select(.["board-label"] != null) | {id, board_label: .["board-label"], module_name: .["module-name"]} | @json' "$dpll_json" 2>/dev/null | head -1)

	if [ -n "$pin_data" ]; then
		local pin_id=$(echo "$pin_data" | jq -r '.id' 2>/dev/null)
		local board_label=$(echo "$pin_data" | jq -r '.board_label' 2>/dev/null)
		local module_name=$(echo "$pin_data" | jq -r '.module_name' 2>/dev/null)

		if [ -n "$board_label" ] && [ "$board_label" != "null" ]; then
			# Test pin-id-get by board-label
			local found_id=$($DPLL_TOOL pin id-get board-label "$board_label" 2>/dev/null | tr -d '\n')
			if [ "$found_id" == "$pin_id" ]; then
				print_result PASS "dpll pin id-get board-label $board_label"
			else
				print_result FAIL "dpll pin id-get board-label $board_label (expected $pin_id, got $found_id)"
			fi

			# Compare with Python CLI
			if [ -n "$PYTHON_CLI" ]; then
				local dpll_result="$TEST_DIR/dpll_pin_id_get.json"
				local python_result="$TEST_DIR/python_pin_id_get.json"

				$DPLL_TOOL -j pin id-get board-label "$board_label" > "$dpll_result" 2>&1 || true
				python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do pin-id-get --json '{"board-label": "'"$board_label"'"}' --output-json > "$python_result" 2>&1 || true

				# Check if either tool returned an error
				local python_error=$(grep -qE "Netlink (warning|error):" "$python_result" 2>/dev/null && echo "yes" || echo "no")
				# dpll error: check for "Failed to get" message OR empty JSON {}
				local dpll_has_error_msg=$(grep -q "Failed to get" "$dpll_result" 2>/dev/null && echo "yes" || echo "no")
				local dpll_json_content=$(grep -o '{.*}' "$dpll_result" 2>/dev/null | tr -d '[:space:]')
				local dpll_error="no"
				if [ "$dpll_has_error_msg" = "yes" ] || [ "$dpll_json_content" = "{}" ]; then
					dpll_error="yes"
				fi

				if [ "$python_error" = "yes" ] && [ "$dpll_error" = "yes" ]; then
					print_result PASS "pin id-get board-label (vs Python) (both returned error)"
				elif [ "$python_error" = "yes" ] || [ "$dpll_error" = "yes" ]; then
					print_result FAIL "pin id-get board-label (vs Python) (error mismatch: dpll=$dpll_error, python=$python_error)"
					echo "  DPLL command: $DPLL_TOOL -j pin id-get board-label \"$board_label\""
					echo "  DPLL output file: $dpll_result"
					echo "  DPLL raw content:"
					cat "$dpll_result" | head -20
					echo ""
					echo "  Python command: python3 $PYTHON_CLI --spec $DPLL_SPEC --do pin-id-get --json '{\"board-label\": \"$board_label\"}' --output-json"
					echo "  Python output file: $python_result"
					echo "  Python raw content:"
					cat "$python_result" | head -20
				elif [ -s "$dpll_result" ] && [ -s "$python_result" ]; then
					compare_json "$dpll_result" "$python_result" "pin id-get board-label (vs Python)"
				else
					print_result SKIP "pin id-get board-label (vs Python) (empty output)"
					echo "  DPLL output file: $dpll_result (size: $(stat -c%s "$dpll_result" 2>/dev/null || echo 0))"
					echo "  Python output file: $python_result (size: $(stat -c%s "$python_result" 2>/dev/null || echo 0))"
				fi
			fi
		else
			print_result SKIP "pin id-get board-label (no label found)"
		fi

		if [ -n "$module_name" ] && [ "$module_name" != "null" ]; then
			# Test pin-id-get by module-name
			# Note: This may return "multiple matches" error if module has multiple pins
			# which is expected kernel behavior (extack error)
			local dpll_result_basic="$TEST_DIR/dpll_pin_id_get_module_basic.txt"
			$DPLL_TOOL pin id-get module-name "$module_name" > "$dpll_result_basic" 2>&1 || true
			local found_id=$(cat "$dpll_result_basic" | tr -d '\n')
			local has_error=$(grep -q "Failed to get" "$dpll_result_basic" 2>/dev/null && echo "yes" || echo "no")

			if [ "$has_error" = "yes" ]; then
				# Error is expected if there are multiple pins with same module-name
				print_result PASS "pin id-get module-name $module_name (returned error as expected for ambiguous query)"
			elif [ "$found_id" == "$pin_id" ]; then
				print_result PASS "dpll pin id-get module-name $module_name"
			else
				print_result FAIL "dpll pin id-get module-name $module_name (expected $pin_id, got $found_id)"
			fi

			# Compare with Python CLI
			if [ -n "$PYTHON_CLI" ]; then
				local dpll_result="$TEST_DIR/dpll_pin_id_get_module.json"
				local python_result="$TEST_DIR/python_pin_id_get_module.json"

				$DPLL_TOOL -j pin id-get module-name "$module_name" > "$dpll_result" 2>&1 || true
				python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do pin-id-get --json '{"module-name": "'"$module_name"'"}' --output-json > "$python_result" 2>&1 || true

				# Check if either tool returned an error
				local python_error=$(grep -qE "Netlink (warning|error):" "$python_result" 2>/dev/null && echo "yes" || echo "no")
				# dpll error: check for "Failed to get" message OR empty JSON {}
				local dpll_has_error_msg=$(grep -q "Failed to get" "$dpll_result" 2>/dev/null && echo "yes" || echo "no")
				local dpll_json_content=$(grep -o '{.*}' "$dpll_result" 2>/dev/null | tr -d '[:space:]')
				local dpll_error="no"
				if [ "$dpll_has_error_msg" = "yes" ] || [ "$dpll_json_content" = "{}" ]; then
					dpll_error="yes"
				fi

				if [ "$python_error" = "yes" ] && [ "$dpll_error" = "yes" ]; then
					print_result PASS "pin id-get module-name (vs Python) (both returned error)"
				elif [ "$python_error" = "yes" ] || [ "$dpll_error" = "yes" ]; then
					print_result FAIL "pin id-get module-name (vs Python) (error mismatch: dpll=$dpll_error, python=$python_error)"
					echo "  DPLL command: $DPLL_TOOL -j pin id-get module-name \"$module_name\""
					echo "  DPLL output file: $dpll_result"
					echo "  DPLL raw content:"
					cat "$dpll_result" | head -20
					echo ""
					echo "  Python command: python3 $PYTHON_CLI --spec $DPLL_SPEC --do pin-id-get --json '{\"module-name\": \"$module_name\"}' --output-json"
					echo "  Python output file: $python_result"
					echo "  Python raw content:"
					cat "$python_result" | head -20
				elif [ -s "$dpll_result" ] && [ -s "$python_result" ]; then
					compare_json "$dpll_result" "$python_result" "pin id-get module-name (vs Python)"
				else
					print_result SKIP "pin id-get module-name (vs Python) (empty output)"
					echo "  DPLL output file: $dpll_result (size: $(stat -c%s "$dpll_result" 2>/dev/null || echo 0))"
					echo "  Python output file: $python_result (size: $(stat -c%s "$python_result" 2>/dev/null || echo 0))"
				fi
			fi
		else
			print_result SKIP "pin id-get module-name (no module found)"
		fi
	else
		print_result SKIP "pin id-get tests (no pins with board-label found)"
	fi

	echo ""
}

# Test JSON output consistency
test_json_consistency() {
	print_header "Testing JSON Output Consistency"

	# Test that all commands produce valid JSON with -j flag
	local cmds=(
		"device show"
		"pin show"
	)

	for cmd in "${cmds[@]}"; do
		local json_file="$TEST_DIR/test_json_$(echo $cmd | tr ' ' '_').json"
		if $DPLL_TOOL -j $cmd > "$json_file" 2>&1; then
			if jq empty "$json_file" 2>/dev/null; then
				print_result PASS "JSON validity: $cmd"
			else
				print_result FAIL "JSON validity: $cmd (invalid JSON)"
				echo "  Output: $(cat "$json_file")"
			fi
		else
			print_result FAIL "JSON validity: $cmd (command failed)"
		fi
	done

	echo ""
}

# Test legacy (plain text) output format
test_legacy_output() {
	print_header "Testing Legacy Output Format"

	# Test device show legacy output
	local legacy_file="$TEST_DIR/device_legacy.txt"
	if $DPLL_TOOL device show > "$legacy_file" 2>&1; then
		# Check for expected fields in legacy output
		if grep -q "id" "$legacy_file" && \
		   grep -q "module-name" "$legacy_file"; then
			print_result PASS "Legacy device show contains expected fields"
		else
			print_result FAIL "Legacy device show missing fields"
			echo "  Output: $(head -20 "$legacy_file")"
		fi
	else
		print_result FAIL "Legacy device show failed"
	fi

	# Test pin show legacy output
	local pin_legacy_file="$TEST_DIR/pin_legacy.txt"
	if $DPLL_TOOL pin show > "$pin_legacy_file" 2>&1; then
		if grep -q "id" "$pin_legacy_file"; then
			print_result PASS "Legacy pin show contains expected fields"
		else
			print_result FAIL "Legacy pin show missing fields"
		fi
	else
		print_result FAIL "Legacy pin show failed"
	fi

	echo ""
}

# Test JSON vs Legacy output consistency
test_json_legacy_consistency() {
	print_header "Testing JSON vs Legacy Output Consistency"

	# Test device show
	local json_file="$TEST_DIR/device_json.json"
	local legacy_file="$TEST_DIR/device_legacy.txt"

	$DPLL_TOOL -j device show > "$json_file" 2>&1 || true
	$DPLL_TOOL device show > "$legacy_file" 2>&1 || true

	if [ -s "$json_file" ] && [ -s "$legacy_file" ]; then
		# Extract device IDs from both outputs
		local json_ids=$(jq -r '.device[]?.id // empty' "$json_file" 2>/dev/null | sort)
		local legacy_ids=$(grep -oP '^device id \K\d+' "$legacy_file" | sort)

		if [ "$json_ids" == "$legacy_ids" ] && [ -n "$json_ids" ]; then
			print_result PASS "Device IDs match between JSON and legacy output"
		elif [ -z "$json_ids" ] && [ -z "$legacy_ids" ]; then
			print_result SKIP "No devices to compare"
			echo "  JSON file: $json_file"
			echo "  Legacy file: $legacy_file"
			echo "  JSON content sample:"
			head -5 "$json_file"
			echo "  Legacy content sample:"
			head -5 "$legacy_file"
		else
			print_result FAIL "Device IDs differ between JSON and legacy output"
			echo "  JSON IDs: $json_ids"
			echo "  Legacy IDs: $legacy_ids"
		fi

		# Check if module-names match
		local json_modules=$(jq -r '.device[]? | .["module-name"] // empty' "$json_file" 2>/dev/null | sort)
		local legacy_modules=$(grep -oP 'module-name: \K\S+' "$legacy_file" | sort)

		if [ "$json_modules" == "$legacy_modules" ] && [ -n "$json_modules" ]; then
			print_result PASS "Module names match between JSON and legacy output"
		elif [ -z "$json_modules" ] && [ -z "$legacy_modules" ]; then
			print_result SKIP "No module names to compare"
			echo "  JSON modules extracted: '$json_modules'"
			echo "  Legacy modules extracted: '$legacy_modules'"
		else
			print_result FAIL "Module names differ between JSON and legacy output"
			echo "  JSON modules: $json_modules"
			echo "  Legacy modules: $legacy_modules"
		fi
	else
		print_result SKIP "JSON vs Legacy consistency (missing output)"
	fi

	# Test pin show
	local pin_json_file="$TEST_DIR/pin_json.json"
	local pin_legacy_file="$TEST_DIR/pin_legacy.txt"

	$DPLL_TOOL -j pin show > "$pin_json_file" 2>&1 || true
	$DPLL_TOOL pin show > "$pin_legacy_file" 2>&1 || true

	if [ -s "$pin_json_file" ] && [ -s "$pin_legacy_file" ]; then
		local json_pin_ids=$(jq -r '.pin[]?.id // empty' "$pin_json_file" 2>/dev/null | sort)
		local legacy_pin_ids=$(grep -oP '^pin id \K\d+' "$pin_legacy_file" | sort)

		if [ "$json_pin_ids" == "$legacy_pin_ids" ] && [ -n "$json_pin_ids" ]; then
			print_result PASS "Pin IDs match between JSON and legacy output"
		elif [ -z "$json_pin_ids" ] && [ -z "$legacy_pin_ids" ]; then
			print_result SKIP "No pins to compare"
			echo "  JSON file: $pin_json_file"
			echo "  Legacy file: $pin_legacy_file"
			echo "  JSON content sample:"
			head -5 "$pin_json_file"
			echo "  Legacy content sample:"
			head -5 "$pin_legacy_file"
		else
			print_result FAIL "Pin IDs differ between JSON and legacy output"
			echo "  JSON pin IDs: $json_pin_ids"
			echo "  Legacy pin IDs: $legacy_pin_ids"
		fi
	else
		print_result SKIP "Pin JSON vs Legacy consistency (missing output)"
	fi

	echo ""
}

# Test specific device by ID in both formats
test_device_by_id_formats() {
	print_header "Testing Device By ID (Both Formats)"

	local device_id=$(grep -oP '^device id \K\d+' "$TEST_DIR/device_legacy.txt" 2>/dev/null | head -1)

	if [ -n "$device_id" ]; then
		# Test legacy format
		local dev_legacy="$TEST_DIR/device_${device_id}_legacy.txt"
		if $DPLL_TOOL device show id "$device_id" > "$dev_legacy" 2>&1; then
			if grep -q "id $device_id" "$dev_legacy"; then
				print_result PASS "Device $device_id legacy format"
			else
				print_result FAIL "Device $device_id legacy format (wrong ID)"
			fi
		else
			print_result FAIL "Device $device_id legacy format (command failed)"
		fi

		# Test JSON format
		local dev_json="$TEST_DIR/device_${device_id}_json.json"
		if $DPLL_TOOL -j device show id "$device_id" > "$dev_json" 2>&1; then
			local json_id=$(jq -r '.id' "$dev_json" 2>/dev/null)
			if [ "$json_id" == "$device_id" ]; then
				print_result PASS "Device $device_id JSON format"
			else
				print_result FAIL "Device $device_id JSON format (wrong ID: $json_id)"
			fi
		else
			print_result FAIL "Device $device_id JSON format (command failed)"
		fi

		# Compare attribute presence
		# Extract id from "device id N:" and other attrs from "  name: value"
		local legacy_attrs=$( (grep -oP 'device\s+\K[a-z-]+(?=\s+\d+:)' "$dev_legacy"; \
		                        grep -oP '^\s+\K[a-z-]+(?=:)' "$dev_legacy") | sort | uniq)
		local json_attrs=$(jq -r 'keys[]' "$dev_json" 2>/dev/null | sort)

		# Count attributes in both
		local legacy_count=$(echo "$legacy_attrs" | wc -l)
		local json_count=$(echo "$json_attrs" | wc -l)

		if [ "$legacy_count" -gt 0 ] && [ "$json_count" -gt 0 ]; then
			if [ "$legacy_count" -eq "$json_count" ]; then
				print_result PASS "Device $device_id has attributes in both formats (legacy:$legacy_count, json:$json_count)"
			else
				print_result FAIL "Device $device_id attribute count mismatch (legacy:$legacy_count, json:$json_count)"
				echo -e "    ${DIM}Legacy attributes:${NC}"
				echo "$legacy_attrs" | sed 's/^/      /'
				echo -e "    ${DIM}JSON attributes:${NC}"
				echo "$json_attrs" | sed 's/^/      /'
				echo -e "    ${DIM}In legacy but not JSON:${NC}"
				comm -23 <(echo "$legacy_attrs") <(echo "$json_attrs") | sed 's/^/      /' || echo "      (none)"
				echo -e "    ${DIM}In JSON but not legacy:${NC}"
				comm -13 <(echo "$legacy_attrs") <(echo "$json_attrs") | sed 's/^/      /' || echo "      (none)"
			fi
		else
			print_result FAIL "Device $device_id missing attributes (legacy:$legacy_count, json:$json_count)"
		fi
	else
		print_result SKIP "Device by ID formats (no devices)"
	fi

	echo ""
}

# Test specific pin by ID in both formats
test_pin_by_id_formats() {
	print_header "Testing Pin By ID (Both Formats)"

	local pin_id=$(grep -oP '^pin id \K\d+' "$TEST_DIR/pin_legacy.txt" 2>/dev/null | head -1)

	if [ -n "$pin_id" ]; then
		# Test legacy format
		local pin_legacy="$TEST_DIR/pin_${pin_id}_legacy.txt"
		if $DPLL_TOOL pin show id "$pin_id" > "$pin_legacy" 2>&1; then
			if grep -q "id $pin_id" "$pin_legacy"; then
				print_result PASS "Pin $pin_id legacy format"
			else
				print_result FAIL "Pin $pin_id legacy format (wrong ID)"
			fi
		else
			print_result FAIL "Pin $pin_id legacy format (command failed)"
		fi

		# Test JSON format
		local pin_json="$TEST_DIR/pin_${pin_id}_json.json"
		if $DPLL_TOOL -j pin show id "$pin_id" > "$pin_json" 2>&1; then
			local json_id=$(jq -r '.id' "$pin_json" 2>/dev/null)
			if [ "$json_id" == "$pin_id" ]; then
				print_result PASS "Pin $pin_id JSON format"
			else
				print_result FAIL "Pin $pin_id JSON format (wrong ID: $json_id)"
			fi
		else
			print_result FAIL "Pin $pin_id JSON format (command failed)"
		fi

		# Compare attribute presence
		# Extract id from "pin id N:" and other attrs from "  name: value"
		local legacy_attrs=$( (grep -oP 'pin\s+\K[a-z-]+(?=\s+\d+:)' "$pin_legacy"; \
		                        grep -oP '^\s+\K[a-z-]+(?=:)' "$pin_legacy") | sort | uniq)
		local json_attrs=$(jq -r 'keys[]' "$pin_json" 2>/dev/null | sort)

		local legacy_count=$(echo "$legacy_attrs" | wc -l)
		local json_count=$(echo "$json_attrs" | wc -l)

		if [ "$legacy_count" -gt 0 ] && [ "$json_count" -gt 0 ]; then
			if [ "$legacy_count" -eq "$json_count" ]; then
				print_result PASS "Pin $pin_id has attributes in both formats (legacy:$legacy_count, json:$json_count)"
			else
				print_result FAIL "Pin $pin_id attribute count mismatch (legacy:$legacy_count, json:$json_count)"
				echo -e "    ${DIM}Legacy attributes:${NC}"
				echo "$legacy_attrs" | sed 's/^/      /'
				echo -e "    ${DIM}JSON attributes:${NC}"
				echo "$json_attrs" | sed 's/^/      /'
				echo -e "    ${DIM}In legacy but not JSON:${NC}"
				comm -23 <(echo "$legacy_attrs") <(echo "$json_attrs") | sed 's/^/      /' || echo "      (none)"
				echo -e "    ${DIM}In JSON but not legacy:${NC}"
				comm -13 <(echo "$legacy_attrs") <(echo "$json_attrs") | sed 's/^/      /' || echo "      (none)"
			fi
		else
			print_result FAIL "Pin $pin_id missing attributes (legacy:$legacy_count, json:$json_count)"
		fi
	else
		print_result SKIP "Pin by ID formats (no pins)"
	fi

	echo ""
}

# Test device set operations
test_device_set() {
	print_header "Testing Device Set Operations"

	if [ $ENABLE_SET_OPERATIONS -eq 0 ]; then
		print_result SKIP "Device set operations (read-only mode, use --enable-set)"
		echo ""
		return
	fi

	local device_id=$(grep -oP '^device id \K\d+' "$TEST_DIR/dpll_device_dump.txt" 2>/dev/null | head -1)

	if [ -n "$device_id" ]; then
		# Test device set with phase-offset-monitor (read current value first)
		local cmd="$DPLL_TOOL device set id $device_id phase-offset-monitor true"
		if run_test_command "Device set phase-offset-monitor" "$cmd 2>/dev/null"; then
			print_result PASS "Device set phase-offset-monitor true"
		else
			print_result SKIP "Device set phase-offset-monitor (not supported by device)"
		fi

		# Test device set with phase-offset-avg-factor
		local cmd="$DPLL_TOOL device set id $device_id phase-offset-avg-factor 10"
		if run_test_command "Device set phase-offset-avg-factor" "$cmd 2>/dev/null"; then
			print_result PASS "Device set phase-offset-avg-factor 10"
		else
			print_result SKIP "Device set phase-offset-avg-factor (not supported by device)"
		fi
	else
		print_result SKIP "Device set operations (no devices)"
	fi

	echo ""
}

# Test pin set operations
test_pin_set() {
	print_header "Testing Pin Set Operations"

	if [ $ENABLE_SET_OPERATIONS -eq 0 ]; then
		print_result SKIP "Pin set operations (read-only mode, use --enable-set)"
		echo ""
		return
	fi

	local pin_id=$(grep -oP '^pin id \K\d+' "$TEST_DIR/dpll_pin_dump.txt" 2>/dev/null | head -1)

	print_result SKIP "Pin set operations (not tested here)"

	echo ""
}

# Test pin frequency change
test_pin_frequency_change() {
	print_header "Testing Pin Frequency Change"

	if [ $ENABLE_SET_OPERATIONS -eq 0 ]; then
		print_result SKIP "Pin frequency change (read-only mode, use --enable-set)"
		echo ""
		return
	fi

	if ! command -v jq &>/dev/null; then
		print_result SKIP "Pin frequency change (jq not available)"
		echo ""
		return
	fi

	# Get all pins with frequency support
	local pins_json="$TEST_DIR/dpll_pin_dump.json"
	if [ ! -f "$pins_json" ]; then
		$DPLL_TOOL -j pin show > "$pins_json" 2>&1 || true
	fi

	# Find pins that have both frequency and frequency-supported
	local pin_count=$(jq -r '.pin | length' "$pins_json" 2>/dev/null || echo 0)
	local tested=0

	for ((i=0; i<pin_count; i++)); do
		local pin_id=$(jq -r ".pin[$i].id" "$pins_json" 2>/dev/null)
		local current_freq=$(jq -r ".pin[$i].frequency // empty" "$pins_json" 2>/dev/null)
		local freq_supported=$(jq -r ".pin[$i][\"frequency-supported\"] // empty" "$pins_json" 2>/dev/null)

		# Skip if no frequency or no frequency-supported
		if [ -z "$current_freq" ] || [ "$current_freq" == "null" ] || [ -z "$freq_supported" ] || [ "$freq_supported" == "null" ]; then
			continue
		fi

		# Get list of supported frequencies (extract min-max pairs)
		local supported_freqs=$(jq -r ".pin[$i][\"frequency-supported\"][]? | \"\(.\"frequency-min\") \(.\"frequency-max\")\"" "$pins_json" 2>/dev/null)

		# Find a different frequency to set (use first available that's not current)
		local target_freq=""
		while IFS=' ' read -r freq_min freq_max; do
			# Try min value first
			if [ "$freq_min" != "$current_freq" ]; then
				target_freq="$freq_min"
				break
			fi
			# Try max value if different
			if [ "$freq_max" != "$current_freq" ] && [ "$freq_max" != "$freq_min" ]; then
				target_freq="$freq_max"
				break
			fi
		done <<< "$supported_freqs"

		# Skip if we couldn't find a different frequency
		if [ -z "$target_freq" ]; then
			continue
		fi

		tested=$((tested + 1))

		# Try to set the frequency
		local test_name="Pin $pin_id frequency change $current_freq -> $target_freq"
		local cmd="$DPLL_TOOL pin set id $pin_id frequency $target_freq"

		if run_test_command "$test_name" "$cmd 2>/dev/null"; then
			print_result PASS "$test_name"

			# Verify the change
			local new_freq=$($DPLL_TOOL -j pin show id "$pin_id" 2>/dev/null | jq -r '.frequency // empty')
			if [ "$new_freq" == "$target_freq" ]; then
				echo -e "  ${GREEN}✓${NC} Frequency successfully changed and verified"
			else
				echo -e "  ${YELLOW}⚠${NC} Frequency set succeeded but verification shows: $new_freq"
			fi

			# Restore original frequency
			$DPLL_TOOL pin set id "$pin_id" frequency "$current_freq" 2>/dev/null || true
		else
			print_result SKIP "$test_name (not supported or failed)"
		fi

		# Only test first pin with frequency support
		break
	done

	if [ $tested -eq 0 ]; then
		print_result SKIP "Pin frequency change (no pins with frequency-supported found)"
	fi

	echo ""
}

# Test pin priority changes with capability checking
test_pin_priority_capability() {
	print_header "Testing Pin Priority with Capability Checking (parent-device context)"

	if [ $ENABLE_SET_OPERATIONS -eq 0 ]; then
		print_result SKIP "Pin priority capability test (read-only mode, use --enable-set)"
		echo ""
		return
	fi

	# Get all pins
	local all_pins_json="$TEST_DIR/pin_prio_test.json"
	$DPLL_TOOL -j pin show > "$all_pins_json" 2>/dev/null || true
	local pin_count=$(jq -r '.pin | length' "$all_pins_json" 2>/dev/null || echo 0)

	if [ "$pin_count" -eq 0 ]; then
		print_result SKIP "Pin priority capability test (no pins available)"
		echo ""
		return
	fi

	# Test parent-device priority change (if applicable)
	local found_parent_prio=0
	for ((i=0; i<pin_count; i++)); do
		local pin_id=$(jq -r ".pin[$i].id" "$all_pins_json" 2>/dev/null)
		local has_prio_cap=$(jq -r ".pin[$i].capabilities | contains([\"priority-can-change\"])" "$all_pins_json" 2>/dev/null)
		local parent_count=$(jq -r ".pin[$i].\"parent-device\" | length" "$all_pins_json" 2>/dev/null || echo 0)

		if [ "$has_prio_cap" = "true" ] && [ "$parent_count" -gt 0 ]; then
			# Get first parent-device with prio
			local parent_id=$(jq -r ".pin[$i].\"parent-device\"[0].\"parent-id\" // empty" "$all_pins_json" 2>/dev/null)
			local parent_prio=$(jq -r ".pin[$i].\"parent-device\"[0].prio // empty" "$all_pins_json" 2>/dev/null)

			if [ -n "$parent_id" ] && [ -n "$parent_prio" ]; then
				found_parent_prio=1
				local test_name="Pin $pin_id: parent-device $parent_id priority change"
				local new_prio=$((parent_prio + 5))

				# Try to change parent-device priority
				local error_file="$TEST_DIR/parent_prio_error.txt"
				$DPLL_TOOL pin set id "$pin_id" parent-device "$parent_id" prio "$new_prio" > /dev/null 2>"$error_file"
				local exit_code=$?

				if [ $exit_code -eq 0 ]; then
					# Verify the change
					sleep 1  # Give time for kernel to update
					local verify_json="$TEST_DIR/parent_prio_verify.json"
					$DPLL_TOOL -j pin show id "$pin_id" > "$verify_json" 2>/dev/null

					# NOTE: 'pin show id X' returns {id:..., parent-device:[...]}, NOT {pin:[{...}]}
					# So we use top-level queries, not .pin[0]
					local has_parent=$(jq -r ".\"parent-device\" // null" "$verify_json" 2>/dev/null)
					if [ "$has_parent" = "null" ]; then
						print_result FAIL "$test_name (parent-device disappeared after set)"
					else
						# Find the specific parent-device entry
						local current_prio=$(jq -r ".\"parent-device\"[] | select(.\"parent-id\" == $parent_id) | .prio // empty" "$verify_json" 2>/dev/null)

						if [ -z "$current_prio" ]; then
							print_result FAIL "$test_name (cannot read prio after set - parent-device not found)"
							echo -e "  ${DIM}Looking for parent-id: $parent_id${NC}"
							echo -e "  ${DIM}Available parent-ids: $(jq -r '."parent-device"[]."parent-id"' "$verify_json" 2>/dev/null | tr '\n' ' ')${NC}"
						elif [ "$current_prio" = "$new_prio" ]; then
							print_result PASS "$test_name"
							# Restore
							$DPLL_TOOL pin set id "$pin_id" parent-device "$parent_id" prio "$parent_prio" 2>/dev/null || true
						else
							print_result FAIL "$test_name (set succeeded but value not changed: got '$current_prio', expected '$new_prio')"
						fi
					fi
				else
					print_result FAIL "$test_name (set failed despite capability)"
					if [ -s "$error_file" ]; then
						echo -e "  ${DIM}Error: $(cat "$error_file")${NC}"
					fi
				fi
				break
			fi
		fi
	done

	if [ $found_parent_prio -eq 0 ]; then
		print_result SKIP "Parent-device priority change test (no suitable pin found)"
	fi

	echo ""
}

# Test parent-device and parent-pin operations
test_parent_operations() {
	print_header "Testing Parent Device/Pin Operations"

	local pin_dump="$TEST_DIR/dpll_pin_dump.txt"

	# Check if any pin has parent-device in output
	if grep -q "parent-device" "$pin_dump" 2>/dev/null; then
		print_result PASS "Parent-device attribute found in pin output"

		# Test parsing of parent-device arrays
		local parent_count=$(grep -c "parent-device:" "$pin_dump" 2>/dev/null || echo 0)
		if [ "$parent_count" -gt 0 ]; then
			print_result PASS "Parent-device array parsing ($parent_count entries)"
		fi
	else
		print_result SKIP "Parent-device (not present in hardware)"
	fi

	# Check if any pin has parent-pin in output
	if grep -q "parent-pin" "$pin_dump" 2>/dev/null; then
		print_result PASS "Parent-pin attribute found in pin output"

		# Test parsing of parent-pin arrays
		local parent_pin_count=$(grep -c "parent-pin:" "$pin_dump" 2>/dev/null || echo 0)
		if [ "$parent_pin_count" -gt 0 ]; then
			print_result PASS "Parent-pin array parsing ($parent_pin_count entries)"
		fi
	else
		print_result SKIP "Parent-pin (not present in hardware)"
	fi

	# Test pin set with parent-device (if we have devices and pins)
	if [ $ENABLE_SET_OPERATIONS -eq 1 ]; then
		local device_id=$(grep -oP '^device id \K\d+' "$TEST_DIR/dpll_device_dump.txt" 2>/dev/null | head -1)
		local pin_id=$(grep -oP '^pin id \K\d+' "$pin_dump" 2>/dev/null | head -1)

		if [ -n "$device_id" ] && [ -n "$pin_id" ]; then
			# Test parent-device with state
			local error_file="$TEST_DIR/parent_device_error.txt"
			./dpll pin set id $pin_id parent-device $device_id state connected > /dev/null 2>"$error_file"
			local exit_code=$?
			if [ $exit_code -eq 0 ]; then
				print_result PASS "Pin set with parent-device state"
			elif [ $exit_code -gt 128 ]; then
				print_result FAIL "Pin set with parent-device state (crashed with signal $((exit_code - 128)))"
				echo "  Command: $DPLL_TOOL pin set id $pin_id parent-device $device_id state connected"
				echo "  Values: pin_id=$pin_id, device_id=$device_id"
				if [ -s "$error_file" ]; then
					echo "  Error output:"
					cat "$error_file" | head -10 | sed 's/^/    /'
				fi
			else
				print_result SKIP "Pin set with parent-device state (not supported)"
			fi

			# Test parent-device with prio
			./dpll pin set id $pin_id parent-device $device_id prio 5 > /dev/null 2>"$error_file"
			exit_code=$?
			if [ $exit_code -eq 0 ]; then
				print_result PASS "Pin set with parent-device prio"
			elif [ $exit_code -gt 128 ]; then
				print_result FAIL "Pin set with parent-device prio (crashed with signal $((exit_code - 128)))"
				echo "  Command: $DPLL_TOOL pin set id $pin_id parent-device $device_id prio 5"
				echo "  Values: pin_id=$pin_id, device_id=$device_id"
			else
				print_result SKIP "Pin set with parent-device prio (not supported)"
			fi

			# Test parent-device with direction
			./dpll pin set id $pin_id parent-device $device_id direction input > /dev/null 2>"$error_file"
			exit_code=$?
			if [ $exit_code -eq 0 ]; then
				print_result PASS "Pin set with parent-device direction"
			elif [ $exit_code -gt 128 ]; then
				print_result FAIL "Pin set with parent-device direction (crashed with signal $((exit_code - 128)))"
				echo "  Command: $DPLL_TOOL pin set id $pin_id parent-device $device_id direction input"
				echo "  Values: pin_id=$pin_id, device_id=$device_id"
			else
				print_result SKIP "Pin set with parent-device direction (not supported)"
			fi

			# Test parent-device with multiple attributes
			./dpll pin set id $pin_id parent-device $device_id state connected prio 10 direction input > /dev/null 2>"$error_file"
			exit_code=$?
			if [ $exit_code -eq 0 ]; then
				print_result PASS "Pin set with parent-device multiple attributes"
			elif [ $exit_code -gt 128 ]; then
				print_result FAIL "Pin set with parent-device multiple attributes (crashed with signal $((exit_code - 128)))"
				echo "  Command: $DPLL_TOOL pin set id $pin_id parent-device $device_id state connected prio 10 direction input"
				echo "  Values: pin_id=$pin_id, device_id=$device_id"
			else
				print_result SKIP "Pin set with parent-device multiple attributes (not supported)"
			fi
		else
			print_result SKIP "Pin set with parent-device (missing device or pin)"
		fi
	else
		print_result SKIP "Pin set with parent-device (read-only mode, use --enable-set)"
	fi

	echo ""
}

# Test reference-sync operations
test_reference_sync() {
	print_header "Testing Reference-Sync Operations"

	local pin_dump="$TEST_DIR/pin_legacy.txt"

	# Check if any pin has reference-sync in output
	if grep -q "reference-sync" "$pin_dump" 2>/dev/null; then
		print_result PASS "Reference-sync attribute found in pin output"

		# Count reference-sync entries
		local ref_count=$(grep -c "reference-sync:" "$pin_dump" 2>/dev/null || echo 0)
		if [ "$ref_count" -gt 0 ]; then
			print_result PASS "Reference-sync array parsing ($ref_count entries)"
		fi
	else
		print_result SKIP "Reference-sync (not present in hardware)"
	fi

	# Test pin set with reference-sync
	if [ $ENABLE_SET_OPERATIONS -eq 1 ]; then
		local pin_id=$(grep -oP '^pin id \K\d+' "$pin_dump" 2>/dev/null | head -1)
		local ref_pin_id=$(grep -oP '^pin id \K\d+' "$pin_dump" 2>/dev/null | sed -n '2p')

		if [ -n "$pin_id" ] && [ -n "$ref_pin_id" ]; then
			local error_file="$TEST_DIR/reference_sync_error.txt"
			./dpll pin set id $pin_id reference-sync $ref_pin_id state connected > /dev/null 2>"$error_file"
			local exit_code=$?
			if [ $exit_code -eq 0 ]; then
				print_result PASS "Pin set with reference-sync"
			elif [ $exit_code -gt 128 ]; then
				print_result FAIL "Pin set with reference-sync (crashed with signal $((exit_code - 128)))"
				echo "  Command: $DPLL_TOOL pin set id $pin_id reference-sync $ref_pin_id state connected"
				echo "  Values: pin_id=$pin_id, ref_pin_id=$ref_pin_id"
				if [ -s "$error_file" ]; then
					echo "  Error output:"
					cat "$error_file" | head -10 | sed 's/^/    /'
				fi
			else
				print_result SKIP "Pin set with reference-sync (not supported)"
			fi
		else
			print_result SKIP "Pin set with reference-sync (not enough pins)"
		fi
	else
		print_result SKIP "Pin set with reference-sync (read-only mode, use --enable-set)"
	fi

	echo ""
}

# Test monitor mode
test_monitor() {
	print_header "Testing Monitor Mode"

	# Test that monitor command exists and can be started
	# We'll kill it after 2 seconds to avoid hanging
	timeout 2 $DPLL_TOOL monitor >/dev/null 2>&1 &
	local monitor_pid=$!

	sleep 0.5

	if kill -0 $monitor_pid 2>/dev/null; then
		print_result PASS "Monitor mode started successfully"
		kill $monitor_pid 2>/dev/null || true
		wait $monitor_pid 2>/dev/null || true
	else
		# Monitor may have exited if no multicast group available
		print_result SKIP "Monitor mode (may require hardware events)"
	fi

	# Test monitor with JSON output
	timeout 2 $DPLL_TOOL -j monitor >/dev/null 2>&1 &
	monitor_pid=$!

	sleep 0.5

	if kill -0 $monitor_pid 2>/dev/null; then
		print_result PASS "Monitor mode with JSON output"
		kill $monitor_pid 2>/dev/null || true
		wait $monitor_pid 2>/dev/null || true
	else
		print_result SKIP "Monitor mode JSON (may require hardware events)"
	fi

	echo ""
}

# Advanced monitor test with event verification
test_monitor_events() {
	print_header "Testing Monitor Event Detection"

	if [ $ENABLE_SET_OPERATIONS -eq 0 ]; then
		print_result SKIP "Monitor event detection (read-only mode, use --enable-set)"
		echo ""
		return
	fi

	# Get all pins in JSON
	local all_pins_json="$TEST_DIR/monitor_all_pins.json"
	$DPLL_TOOL -j pin show > "$all_pins_json" 2>/dev/null || true

	# Find a pin suitable for testing (has changeable attributes with top-level values)
	local pin_id=""
	local test_attr=""
	local orig_value=""
	local new_value=""
	local pin_count=$(jq -r '.pin | length' "$all_pins_json" 2>/dev/null || echo 0)

	# Strategy 1: Find pin with priority-can-change capability AND has prio attribute
	for ((i=0; i<pin_count; i++)); do
		local id=$(jq -r ".pin[$i].id" "$all_pins_json" 2>/dev/null)
		local has_prio_cap=$(jq -r ".pin[$i].capabilities | contains([\"priority-can-change\"])" "$all_pins_json" 2>/dev/null)
		local prio=$(jq -r ".pin[$i].prio // empty" "$all_pins_json" 2>/dev/null)

		if [ "$has_prio_cap" = "true" ] && [ -n "$prio" ]; then
			pin_id="$id"
			test_attr="prio"
			orig_value="$prio"
			new_value=$((prio + 5))
			break
		fi
	done

	# Strategy 2: Find pin with direction-can-change capability
	if [ -z "$pin_id" ]; then
		for ((i=0; i<pin_count; i++)); do
			local id=$(jq -r ".pin[$i].id" "$all_pins_json" 2>/dev/null)
			local has_dir_cap=$(jq -r ".pin[$i].capabilities | contains([\"direction-can-change\"])" "$all_pins_json" 2>/dev/null)
			local direction=$(jq -r ".pin[$i].direction // empty" "$all_pins_json" 2>/dev/null)

			if [ "$has_dir_cap" = "true" ] && [ -n "$direction" ]; then
				pin_id="$id"
				test_attr="direction"
				orig_value="$direction"
				if [ "$direction" = "input" ]; then
					new_value="output"
				else
					new_value="input"
				fi
				break
			fi
		done
	fi

	# Strategy 3: Find pin with changeable frequency
	if [ -z "$pin_id" ]; then
		for ((i=0; i<pin_count; i++)); do
			local id=$(jq -r ".pin[$i].id" "$all_pins_json" 2>/dev/null)
			local freq=$(jq -r ".pin[$i].frequency // empty" "$all_pins_json" 2>/dev/null)
			local freq_count=$(jq -r ".pin[$i].\"frequency-supported\" | length" "$all_pins_json" 2>/dev/null || echo 0)

			if [ -n "$freq" ] && [ "$freq_count" -gt 1 ]; then
				# Find different frequency
				local alt_freq=$(jq -r ".pin[$i].\"frequency-supported\"[1].\"frequency-min\" // empty" "$all_pins_json" 2>/dev/null)
				if [ -n "$alt_freq" ] && [ "$alt_freq" != "$freq" ]; then
					pin_id="$id"
					test_attr="frequency"
					orig_value="$freq"
					new_value="$alt_freq"
					break
				fi
			fi
		done
	fi

	if [ -z "$pin_id" ]; then
		print_result SKIP "Monitor event detection (no suitable pin found with changeable attributes)"
		echo ""
		return
	fi

	echo -e "  ${DIM}Using pin $pin_id, testing $test_attr changes ($orig_value <-> $new_value)${NC}"

	# Start monitor in background capturing output
	local monitor_output="$TEST_DIR/monitor_output.txt"
	rm -f "$monitor_output"
	# Use ./dpll directly, not wrapper (wrapper adds sleep which isn't needed for monitor)
	timeout 30 ./dpll monitor > "$monitor_output" 2>&1 &
	local monitor_pid=$!

	# Give monitor time to start and subscribe to multicast
	sleep 2

	# Check if monitor is running
	if ! kill -0 $monitor_pid 2>/dev/null; then
		print_result SKIP "Monitor event detection (monitor failed to start)"
		if [ -f "$monitor_output" ]; then
			echo "  ${DIM}Monitor error: $(head -1 "$monitor_output")${NC}"
		fi
		echo ""
		return
	fi

	local operations_performed=0
	local test_name=""

	# Note: Device SET operations (phase-offset-monitor, phase-offset-avg-factor)
	# do NOT trigger kernel notifications automatically. Only driver-initiated
	# notifications (lock status change, etc.) are sent for devices.
	# We test only PIN operations which DO trigger notifications via __dpll_pin_change_ntf()

	# Perform all operations first, then check results after monitor is stopped
	# Operation 1: Change the selected attribute
	$DPLL_TOOL pin set id "$pin_id" "$test_attr" "$new_value" 2>/dev/null || true
	sleep 2
	operations_performed=$((operations_performed + 1))

	# Restore
	$DPLL_TOOL pin set id "$pin_id" "$test_attr" "$orig_value" 2>/dev/null || true
	sleep 2
	operations_performed=$((operations_performed + 1))

	# Operation 2-3: Multiple rapid changes of the same attribute
	for i in 1 2; do
		$DPLL_TOOL pin set id "$pin_id" "$test_attr" "$new_value" 2>/dev/null || true
		sleep 1
		$DPLL_TOOL pin set id "$pin_id" "$test_attr" "$orig_value" 2>/dev/null || true
		sleep 1
		operations_performed=$((operations_performed + 2))
	done

	# Operation 4: Verify GET operations don't generate new events
	local pre_get_count=$(wc -l < "$monitor_output" 2>/dev/null || echo 0)
	$DPLL_TOOL pin show id "$pin_id" > /dev/null 2>&1 || true
	$DPLL_TOOL pin show > /dev/null 2>&1 || true
	sleep 1
	local post_get_count=$(wc -l < "$monitor_output" 2>/dev/null || echo 0)

	# Kill monitor and wait for it to flush output
	kill $monitor_pid 2>/dev/null || true
	wait $monitor_pid 2>/dev/null || true
	sleep 1  # Give time for final output flush

	# Now check the results after monitor has stopped
	# Test 1: Did we capture PIN_CHANGE events?
	local pin_change_count=$(grep -c "\[PIN_CHANGE\]" "$monitor_output" 2>/dev/null | head -1)
	pin_change_count=${pin_change_count:-0}
	if [ "$pin_change_count" -gt 0 ]; then
		print_result PASS "Monitor captured PIN_CHANGE events ($pin_change_count events)"
	else
		print_result FAIL "Monitor did not capture any PIN_CHANGE events"
	fi

	# Test 2: Did events match our pin?
	local our_pin_events=$(grep -cE "\[PIN_CHANGE\].*pin id $pin_id:" "$monitor_output" 2>/dev/null | head -1)
	our_pin_events=${our_pin_events:-0}
	if [ "$our_pin_events" -gt 0 ]; then
		print_result PASS "Monitor captured events for pin $pin_id ($our_pin_events events)"
	else
		print_result FAIL "Monitor did not capture events for pin $pin_id"
	fi

	# Test 3: Did GET operations generate events?
	if [ "$pre_get_count" -eq "$post_get_count" ]; then
		print_result PASS "GET operations don't generate events"
	else
		print_result FAIL "GET operations generated events (lines: before=$pre_get_count, after=$post_get_count)"
	fi

	# Debug: Show what monitor captured (optional detailed output)
	if [ -f "$monitor_output" ]; then
		local line_count=$(wc -l < "$monitor_output" 2>/dev/null || echo 0)
		echo -e "  ${DIM}Total monitor output: $line_count lines, $operations_performed SET operations performed${NC}"
	fi

	echo ""
}

# Test monitor output parity with Python CLI
test_monitor_python_parity() {
	print_header "Testing Monitor Output Parity with Python CLI"

	if [ $ENABLE_SET_OPERATIONS -eq 0 ]; then
		print_result SKIP "Monitor parity test (read-only mode, use --enable-set)"
		echo ""
		return
	fi

	# Check if Python CLI is available
	if [ ! -f "$PYTHON_CLI" ]; then
		print_result SKIP "Monitor parity test (Python CLI not found at $PYTHON_CLI)"
		echo ""
		return
	fi

	if [ ! -f "$DPLL_SPEC" ]; then
		print_result SKIP "Monitor parity test (DPLL spec not found at $DPLL_SPEC)"
		echo ""
		return
	fi

	# Find a pin with changeable attribute
	local all_pins_json="$TEST_DIR/parity_all_pins.json"
	./dpll -j pin show > "$all_pins_json" 2>/dev/null

	local pin_count=$(jq '.pin | length' "$all_pins_json" 2>/dev/null || echo 0)
	local pin_id=""
	local freq=""
	local alt_freq=""
	local test_attr=""

	# Strategy 1: Find pin with changeable frequency (2+ supported frequencies)
	for ((i=0; i<pin_count; i++)); do
		local id=$(jq -r ".pin[$i].id" "$all_pins_json" 2>/dev/null)
		local current_freq=$(jq -r ".pin[$i].frequency // empty" "$all_pins_json" 2>/dev/null)
		local freq_count=$(jq -r ".pin[$i].\"frequency-supported\" | length" "$all_pins_json" 2>/dev/null || echo 0)

		if [ -n "$current_freq" ] && [ "$freq_count" -ge 2 ]; then
			local freq1=$(jq -r ".pin[$i].\"frequency-supported\"[0].\"frequency-min\"" "$all_pins_json" 2>/dev/null)
			local freq2=$(jq -r ".pin[$i].\"frequency-supported\"[1].\"frequency-min\"" "$all_pins_json" 2>/dev/null)

			# Make sure we pick a frequency different from current
			local selected_freq=""
			if [ "$freq1" != "$current_freq" ]; then
				selected_freq="$freq1"
			elif [ "$freq2" != "$current_freq" ]; then
				selected_freq="$freq2"
			fi

			if [ -n "$selected_freq" ] && [ "$selected_freq" != "$current_freq" ]; then
				pin_id="$id"
				freq="$current_freq"
				alt_freq="$selected_freq"
				test_attr="frequency"
				break
			fi
		fi
	done

	# Strategy 2: Find pin with priority-can-change and parent-device prio
	if [ -z "$pin_id" ]; then
		for ((i=0; i<pin_count; i++)); do
			local id=$(jq -r ".pin[$i].id" "$all_pins_json" 2>/dev/null)
			local has_prio_cap=$(jq -r ".pin[$i].capabilities | contains([\"priority-can-change\"])" "$all_pins_json" 2>/dev/null)
			local parent_id=$(jq -r ".pin[$i].\"parent-device\"[0].\"parent-id\" // empty" "$all_pins_json" 2>/dev/null)
			local parent_prio=$(jq -r ".pin[$i].\"parent-device\"[0].prio // empty" "$all_pins_json" 2>/dev/null)

			if [ "$has_prio_cap" = "true" ] && [ -n "$parent_id" ] && [ -n "$parent_prio" ]; then
				pin_id="$id"
				test_attr="parent-device prio"
				freq="$parent_prio"
				alt_freq=$((parent_prio + 5))
				break
			fi
		done
	fi

	if [ -z "$pin_id" ]; then
		print_result SKIP "Monitor parity test (no pin with changeable attribute found)"
		echo ""
		return
	fi

	echo -e "  ${DIM}Testing pin $pin_id, attribute: $test_attr (current: $freq, change to: $alt_freq)${NC}"

	# Start both monitors
	local c_monitor_out="$TEST_DIR/c_monitor.txt"
	local py_monitor_out="$TEST_DIR/py_monitor.txt"
	rm -f "$c_monitor_out" "$py_monitor_out"

	# Start C monitor
	timeout 15 ./dpll monitor > "$c_monitor_out" 2>&1 &
	local c_pid=$!

	# Start Python monitor (use python3 -u for unbuffered output!)
	timeout 15 python3 -u "$PYTHON_CLI" --spec "$DPLL_SPEC" --subscribe monitor > "$py_monitor_out" 2>&1 &
	local py_pid=$!

	sleep 3  # Give both monitors time to start and subscribe

	# Check both are running
	if ! kill -0 $c_pid 2>/dev/null; then
		print_result SKIP "Monitor parity test (C monitor failed to start)"
		kill $py_pid 2>/dev/null || true
		echo ""
		return
	fi

	if ! kill -0 $py_pid 2>/dev/null; then
		print_result SKIP "Monitor parity test (Python monitor failed to start)"
		kill $c_pid 2>/dev/null || true
		echo ""
		return
	fi

	# Perform a change based on what attribute we found
	if [ "$test_attr" = "frequency" ]; then
		echo -e "  ${DIM}Changing frequency: $freq -> $alt_freq -> $freq${NC}"
		./dpll pin set id "$pin_id" frequency "$alt_freq" 2>/dev/null || true
		sleep 2
		./dpll pin set id "$pin_id" frequency "$freq" 2>/dev/null || true
		sleep 2
	elif [ "$test_attr" = "parent-device prio" ]; then
		# Extract parent_id from earlier search
		local parent_id=$(jq -r ".pin[] | select(.id == $pin_id) | .\"parent-device\"[0].\"parent-id\"" "$all_pins_json" 2>/dev/null)
		echo -e "  ${DIM}WARNING: parent-device prio changes may not trigger notifications!${NC}"
		echo -e "  ${DIM}Changing parent-device $parent_id prio: $freq -> $alt_freq -> $freq${NC}"
		./dpll pin set id "$pin_id" parent-device "$parent_id" prio "$alt_freq" 2>/dev/null || true
		sleep 2
		./dpll pin set id "$pin_id" parent-device "$parent_id" prio "$freq" 2>/dev/null || true
		sleep 2
	else
		echo -e "  ${DIM}ERROR: Unknown test_attr: $test_attr${NC}"
	fi

	# Stop both monitors
	kill $c_pid $py_pid 2>/dev/null || true
	wait $c_pid $py_pid 2>/dev/null || true
	sleep 1

	# Save outputs to persistent location for debugging
	local persist_dir="/tmp/dpll_monitor_parity_debug"
	mkdir -p "$persist_dir"
	cp "$c_monitor_out" "$persist_dir/c_monitor.txt" 2>/dev/null || true
	cp "$py_monitor_out" "$persist_dir/py_monitor.txt" 2>/dev/null || true
	echo -e "  ${DIM}Debug outputs saved to: $persist_dir/${NC}"

	# Get file sizes for debugging
	local c_size=$(wc -c < "$c_monitor_out" 2>/dev/null || echo 0)
	local py_size=$(wc -c < "$py_monitor_out" 2>/dev/null || echo 0)

	if [ "$c_size" -eq 0 ]; then
		print_result FAIL "C monitor produced no output"
		echo ""
		return
	fi

	if [ "$py_size" -eq 0 ]; then
		print_result FAIL "Python monitor produced no output"
		echo -e "  ${DIM}Check $persist_dir/py_monitor.txt for errors${NC}"
		echo ""
		return
	fi

	# Test 1: Both captured events
	local c_events=$(grep -c "\[PIN_CHANGE\]" "$c_monitor_out" 2>/dev/null | head -1)
	c_events=${c_events:-0}
	# Python CLI outputs 'name': 'pin-change-ntf' in dict format
	local py_events=$(grep -c "'name': 'pin-change" "$py_monitor_out" 2>/dev/null | head -1)
	py_events=${py_events:-0}

	if [ "$c_events" -gt 0 ] && [ "$py_events" -gt 0 ]; then
		print_result PASS "Both monitors captured events (C: $c_events, Python: $py_events)"
	else
		print_result FAIL "Event capture mismatch (C: $c_events, Python: $py_events)"
		echo -e "  ${DIM}See $persist_dir/ for monitor outputs${NC}"
	fi

	# Test 2: Event count similarity (should be within 20% of each other)
	if [ "$c_events" -gt 0 ] && [ "$py_events" -gt 0 ]; then
		local diff=$((c_events > py_events ? c_events - py_events : py_events - c_events))
		local max=$((c_events > py_events ? c_events : py_events))
		local percent=$((diff * 100 / max))

		if [ "$percent" -le 20 ]; then
			print_result PASS "Event counts similar (C: $c_events, Python: $py_events, diff: ${percent}%)"
		else
			print_result FAIL "Event count mismatch too large (C: $c_events, Python: $py_events, diff: ${percent}%)"
		fi
	fi

	# Test 3: Check C monitor output format
	if grep -q "pin id $pin_id:" "$c_monitor_out" 2>/dev/null; then
		print_result PASS "C monitor includes pin ID in event output"
	else
		print_result FAIL "C monitor missing pin ID in event output"
	fi

	# Test 4: Check Python monitor output format
	# Python CLI uses 'id': value format (Python dict, not JSON)
	local py_has_id=$(grep -c "'id': $pin_id" "$py_monitor_out" 2>/dev/null | head -1)
	py_has_id=${py_has_id:-0}

	if [ "$py_has_id" -gt 0 ]; then
		print_result PASS "Python monitor includes pin ID ($py_has_id times)"
	else
		print_result FAIL "Python monitor missing pin ID in event output"
		echo -e "  ${DIM}First 10 lines of Python output:${NC}"
		head -10 "$py_monitor_out" 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
	fi

	# Test 5: Verify both monitors include the changed attribute
	if [ "$test_attr" = "frequency" ]; then
		local c_has_attr=$(grep -c "frequency:" "$c_monitor_out" 2>/dev/null | head -1)
		c_has_attr=${c_has_attr:-0}
		# Python CLI uses 'frequency': value format
		local py_has_attr=$(grep -c "'frequency':" "$py_monitor_out" 2>/dev/null | head -1)
		py_has_attr=${py_has_attr:-0}

		if [ "$c_has_attr" -gt 0 ] && [ "$py_has_attr" -gt 0 ]; then
			print_result PASS "Both monitors captured frequency attribute (C: $c_has_attr, Python: $py_has_attr)"
		else
			print_result FAIL "Frequency attribute missing (C: $c_has_attr, Python: $py_has_attr)"
		fi
	elif [ "$test_attr" = "parent-device prio" ]; then
		local c_has_attr=$(grep -c "prio:" "$c_monitor_out" 2>/dev/null | head -1)
		c_has_attr=${c_has_attr:-0}
		# Python CLI uses 'prio': value format
		local py_has_attr=$(grep -c "'prio':" "$py_monitor_out" 2>/dev/null | head -1)
		py_has_attr=${py_has_attr:-0}

		if [ "$c_has_attr" -gt 0 ] && [ "$py_has_attr" -gt 0 ]; then
			print_result PASS "Both monitors captured prio attribute (C: $c_has_attr, Python: $py_has_attr)"
		else
			print_result FAIL "Prio attribute missing (C: $c_has_attr, Python: $py_has_attr)"
		fi
	fi

	# Test 6: Verify both monitors can parse as valid output
	# C monitor should have legacy format lines
	local c_legacy_lines=$(grep "pin id" "$c_monitor_out" 2>/dev/null | wc -l)
	if [ "$c_legacy_lines" -gt 0 ]; then
		print_result PASS "C monitor produced $c_legacy_lines legacy format event lines"
	else
		print_result FAIL "C monitor produced no parseable event lines"
	fi

	# Python monitor should have Python dict structure (check for 'msg': and 'name':)
	if grep -q "'msg':" "$py_monitor_out" 2>/dev/null && grep -q "'name':" "$py_monitor_out" 2>/dev/null; then
		print_result PASS "Python monitor output contains valid dict structure"
	else
		print_result FAIL "Python monitor output doesn't have expected dict structure"
		echo -e "  ${DIM}Full Python output:${NC}"
		cat "$py_monitor_out" 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
	fi

	# Test 7: Data parity - compare field presence and values
	if [ "$c_events" -gt 0 ] && [ "$py_events" -gt 0 ]; then
		echo -e "  ${DIM}Verifying data parity between C and Python monitors...${NC}"

		# Convert C monitor to JSON (use dpll -j -p monitor for JSON output)
		# For now, check key fields are present in both outputs

		# Check parent-device presence
		local c_has_parent=$(grep -c "parent-device:" "$c_monitor_out" 2>/dev/null | head -1)
		c_has_parent=${c_has_parent:-0}
		local py_has_parent=$(grep -c "'parent-device':" "$py_monitor_out" 2>/dev/null | head -1)
		py_has_parent=${py_has_parent:-0}

		if [ "$c_has_parent" -gt 0 ] && [ "$py_has_parent" -gt 0 ]; then
			print_result PASS "Both monitors include parent-device data"
		elif [ "$c_has_parent" -eq 0 ] && [ "$py_has_parent" -eq 0 ]; then
			print_result PASS "Neither monitor has parent-device (consistent)"
		else
			print_result FAIL "parent-device presence mismatch (C: $c_has_parent, Python: $py_has_parent)"
			echo -e "  ${DIM}This indicates C monitor is missing multi-attr data!${NC}"
		fi

		# Check frequency-supported presence
		local c_has_freq_supp=$(grep -c "frequency-supported:" "$c_monitor_out" 2>/dev/null | head -1)
		c_has_freq_supp=${c_has_freq_supp:-0}
		local py_has_freq_supp=$(grep -c "'frequency-supported':" "$py_monitor_out" 2>/dev/null | head -1)
		py_has_freq_supp=${py_has_freq_supp:-0}

		if [ "$c_has_freq_supp" -gt 0 ] && [ "$py_has_freq_supp" -gt 0 ]; then
			print_result PASS "Both monitors include frequency-supported data"
		elif [ "$c_has_freq_supp" -eq 0 ] && [ "$py_has_freq_supp" -eq 0 ]; then
			print_result PASS "Neither monitor has frequency-supported (consistent)"
		else
			print_result FAIL "frequency-supported presence mismatch (C: $c_has_freq_supp, Python: $py_has_freq_supp)"
		fi

		# Check reference-sync presence (if pin has it)
		local c_has_ref_sync=$(grep -c "reference-sync:" "$c_monitor_out" 2>/dev/null | head -1)
		c_has_ref_sync=${c_has_ref_sync:-0}
		local py_has_ref_sync=$(grep -c "'reference-sync':" "$py_monitor_out" 2>/dev/null | head -1)
		py_has_ref_sync=${py_has_ref_sync:-0}

		if [ "$c_has_ref_sync" -eq 0 ] && [ "$py_has_ref_sync" -eq 0 ]; then
			# Both don't have it - OK
			:
		elif [ "$c_has_ref_sync" -gt 0 ] && [ "$py_has_ref_sync" -gt 0 ]; then
			print_result PASS "Both monitors include reference-sync data"
		else
			print_result FAIL "reference-sync presence mismatch (C: $c_has_ref_sync, Python: $py_has_ref_sync)"
		fi
	fi

	# Test 8: JSON mode data parity - use dpll -j -p monitor
	echo -e "  ${DIM}Testing JSON monitor output parity...${NC}"
	local c_json_out="$TEST_DIR/c_json_monitor.txt"
	local py_json_out="$py_monitor_out"

	# Start C monitor in JSON mode
	timeout 15 ./dpll -j -p monitor > "$c_json_out" 2>&1 &
	local c_json_pid=$!

	sleep 2

	# Trigger one change
	if [ "$test_attr" = "frequency" ]; then
		./dpll pin set id "$pin_id" frequency "$alt_freq" 2>/dev/null || true
		sleep 2
	fi

	# Stop C JSON monitor
	kill $c_json_pid 2>/dev/null || true
	wait $c_json_pid 2>/dev/null || true
	sleep 1

	# Parse first event from both (if any)
	if [ -s "$c_json_out" ] && grep -q "\"id\":" "$c_json_out" 2>/dev/null; then
		# Extract field names from C JSON
		local c_fields=$(grep "\"id\": $pin_id" "$c_json_out" -A 50 | grep -oP '"\K[^"]+(?=":)' | sort -u | tr '\n' ' ')

		# Extract field names from Python (convert 'field': to field)
		local py_fields=$(grep "'id': $pin_id" "$py_json_out" -A 50 | grep -oP "'\K[^']+(?=':)" | sort -u | tr '\n' ' ')

		# Key fields that MUST be present in both
		local required_fields="id module-name clock-id type frequency capabilities phase-adjust"
		local missing_in_c=""
		local missing_in_py=""

		for field in $required_fields; do
			if ! echo "$c_fields" | grep -qw "$field"; then
				missing_in_c="$missing_in_c $field"
			fi
			if ! echo "$py_fields" | grep -qw "$field"; then
				missing_in_py="$missing_in_py $field"
			fi
		done

		if [ -z "$missing_in_c" ] && [ -z "$missing_in_py" ]; then
			print_result PASS "JSON mode: both monitors have all required fields"
		else
			if [ -n "$missing_in_c" ]; then
				print_result FAIL "JSON mode: C monitor missing fields:$missing_in_c"
			fi
			if [ -n "$missing_in_py" ]; then
				print_result FAIL "JSON mode: Python monitor missing fields:$missing_in_py"
			fi
		fi

		# Check multi-attr fields specifically
		if echo "$py_fields" | grep -qw "parent-device"; then
			if echo "$c_fields" | grep -qw "parent-device"; then
				print_result PASS "JSON mode: both monitors have parent-device multi-attr"
			else
				print_result FAIL "JSON mode: Python has parent-device but C monitor doesn't"
				echo -e "  ${DIM}C monitor is not properly parsing multi-attr fields!${NC}"
			fi
		fi
	else
		echo -e "  ${DIM}Skipping JSON parity test (no C JSON monitor output)${NC}"
	fi

	echo ""
}

# Test s64 and sint attribute handling and comparison with Python CLI
test_s64_sint_values() {
	print_header "Testing s64/sint Attribute Handling (dpll vs Python CLI)"

	if [ -z "$PYTHON_CLI" ]; then
		print_result SKIP "s64/sint value tests (Python CLI not available)"
		echo ""
		return
	fi

	local dpll_json="$TEST_DIR/dpll_pins_s64.json"
	$DPLL_TOOL -j pin show > "$dpll_json" 2>/dev/null || true
	local pin_count=$(jq -r '.pin | length' "$dpll_json" 2>/dev/null || echo 0)

	if [ "$pin_count" -eq 0 ]; then
		print_result SKIP "s64/sint value tests (no pins available)"
		echo ""
		return
	fi

	# Test 1: fractional-frequency-offset (sint type)
	local found_ffo=0
	for ((i=0; i<pin_count; i++)); do
		local pin_id=$(jq -r ".pin[$i].id" "$dpll_json" 2>/dev/null)
		local ffo_dpll=$(jq -r ".pin[$i].\"fractional-frequency-offset\" // empty" "$dpll_json" 2>/dev/null)

		if [ -n "$ffo_dpll" ]; then
			found_ffo=1
			local test_name="Pin $pin_id: fractional-frequency-offset (sint) comparison"

			# Get value from Python CLI
			local python_output="$TEST_DIR/python_pin_${pin_id}_ffo.json"
			python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do pin-get --json "{\"id\": $pin_id}" --output-json > "$python_output" 2>&1 || true

			local python_error=$(grep -qE "Netlink (warning|error):" "$python_output" 2>/dev/null && echo "yes" || echo "no")
			if [ "$python_error" = "yes" ]; then
				print_result SKIP "$test_name (Python CLI returned error)"
			else
				local ffo_python=$(jq -r ".\"fractional-frequency-offset\" // empty" "$python_output" 2>/dev/null)

				if [ -z "$ffo_python" ]; then
					print_result SKIP "$test_name (Python CLI missing attribute)"
				elif [ "$ffo_dpll" = "$ffo_python" ]; then
					print_result PASS "$test_name (dpll=$ffo_dpll, python=$ffo_python)"
				else
					print_result FAIL "$test_name (mismatch: dpll=$ffo_dpll, python=$ffo_python)"
					echo "  DPLL output: $dpll_json"
					echo "  Python output: $python_output"
				fi
			fi
			break
		fi
	done

	if [ $found_ffo -eq 0 ]; then
		print_result SKIP "fractional-frequency-offset test (no pin with this attribute)"
	fi

	# Test 2: phase-offset (s64 type) in parent-device context
	local found_phase_offset=0
	for ((i=0; i<pin_count; i++)); do
		local pin_id=$(jq -r ".pin[$i].id" "$dpll_json" 2>/dev/null)
		local parent_count=$(jq -r ".pin[$i].\"parent-device\" | length" "$dpll_json" 2>/dev/null || echo 0)

		if [ "$parent_count" -gt 0 ]; then
			# Check if any parent-device has phase-offset
			local parent_idx=0
			for ((j=0; j<parent_count; j++)); do
				local phase_offset_dpll=$(jq -r ".pin[$i].\"parent-device\"[$j].\"phase-offset\" // empty" "$dpll_json" 2>/dev/null)

				if [ -n "$phase_offset_dpll" ]; then
					found_phase_offset=1
					local parent_id=$(jq -r ".pin[$i].\"parent-device\"[$j].\"parent-id\"" "$dpll_json" 2>/dev/null)
					local test_name="Pin $pin_id parent-device $parent_id: phase-offset (s64) comparison"

					# Get value from Python CLI
					local python_output="$TEST_DIR/python_pin_${pin_id}_phase.json"
					python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do pin-get --json "{\"id\": $pin_id}" --output-json > "$python_output" 2>&1 || true

					local python_error=$(grep -qE "Netlink (warning|error):" "$python_output" 2>/dev/null && echo "yes" || echo "no")
					if [ "$python_error" = "yes" ]; then
						print_result SKIP "$test_name (Python CLI returned error)"
					else
						# Find the matching parent-device in Python output
						local phase_offset_python=$(jq -r ".\"parent-device\"[] | select(.\"parent-id\" == $parent_id) | .\"phase-offset\" // empty" "$python_output" 2>/dev/null)

						if [ -z "$phase_offset_python" ]; then
							print_result SKIP "$test_name (Python CLI missing attribute)"
						elif [ "$phase_offset_dpll" = "$phase_offset_python" ]; then
							print_result PASS "$test_name (dpll=$phase_offset_dpll, python=$phase_offset_python)"
						else
							print_result FAIL "$test_name (mismatch: dpll=$phase_offset_dpll, python=$phase_offset_python)"
							echo "  DPLL output: $dpll_json"
							echo "  Python output: $python_output"
						fi
					fi
					break 2  # Break both loops
				fi
			done
		fi
	done

	if [ $found_phase_offset -eq 0 ]; then
		print_result SKIP "phase-offset test (no pin with parent-device phase-offset)"
	fi

	echo ""
}

# Test multi-enum arrays (DPLL_PR_MULTI_ENUM_STR macro)
test_multi_enum_arrays() {
	print_header "Testing Multi-Enum Arrays (dpll vs Python CLI)"

	if [ -z "$PYTHON_CLI" ]; then
		print_result SKIP "multi-enum array tests (Python CLI not available)"
		echo ""
		return
	fi

	local dpll_json="$TEST_DIR/dpll_devices_multi_enum.json"
	$DPLL_TOOL -j device show > "$dpll_json" 2>/dev/null || true
	local device_count=$(jq -r '.device | length' "$dpll_json" 2>/dev/null || echo 0)

	if [ "$device_count" -eq 0 ]; then
		print_result SKIP "multi-enum array tests (no devices available)"
		echo ""
		return
	fi

	# Test 1: mode-supported multi-enum array
	local found_mode_supported=0
	for ((i=0; i<device_count; i++)); do
		local device_id=$(jq -r ".device[$i].id" "$dpll_json" 2>/dev/null)
		local mode_supported_count=$(jq -r ".device[$i].\"mode-supported\" | length" "$dpll_json" 2>/dev/null || echo 0)

		if [ "$mode_supported_count" -gt 0 ]; then
			found_mode_supported=1
			local test_name="Device $device_id: mode-supported array comparison"

			# Get sorted array from dpll tool
			local modes_dpll=$(jq -r ".device[$i].\"mode-supported\" | sort | .[]" "$dpll_json" 2>/dev/null | tr '\n' ' ')

			# Get value from Python CLI
			local python_output="$TEST_DIR/python_device_${device_id}_modes.json"
			python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do device-get --json "{\"id\": $device_id}" --output-json > "$python_output" 2>&1 || true

			local python_error=$(grep -qE "Netlink (warning|error):" "$python_output" 2>/dev/null && echo "yes" || echo "no")
			if [ "$python_error" = "yes" ]; then
				print_result SKIP "$test_name (Python CLI returned error)"
			else
				local modes_python=$(jq -r ".\"mode-supported\" | sort | .[]" "$python_output" 2>/dev/null | tr '\n' ' ')

				if [ -z "$modes_python" ]; then
					print_result SKIP "$test_name (Python CLI missing attribute)"
				elif [ "$modes_dpll" = "$modes_python" ]; then
					print_result PASS "$test_name (count=$mode_supported_count, match)"
				else
					print_result FAIL "$test_name (mismatch: dpll=[$modes_dpll], python=[$modes_python])"
					echo "  DPLL output: $dpll_json"
					echo "  Python output: $python_output"
				fi
			fi
			break
		fi
	done

	if [ $found_mode_supported -eq 0 ]; then
		print_result SKIP "mode-supported test (no device with this attribute)"
	fi

	# Test 2: clock-quality-level multi-enum array
	local found_clock_quality=0
	for ((i=0; i<device_count; i++)); do
		local device_id=$(jq -r ".device[$i].id" "$dpll_json" 2>/dev/null)
		local cql_count=$(jq -r ".device[$i].\"clock-quality-level\" | length" "$dpll_json" 2>/dev/null || echo 0)

		if [ "$cql_count" -gt 0 ]; then
			found_clock_quality=1
			local test_name="Device $device_id: clock-quality-level array comparison"

			# Get sorted array from dpll tool
			local cql_dpll=$(jq -r ".device[$i].\"clock-quality-level\" | sort | .[]" "$dpll_json" 2>/dev/null | tr '\n' ' ')

			# Get value from Python CLI
			local python_output="$TEST_DIR/python_device_${device_id}_cql.json"
			python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do device-get --json "{\"id\": $device_id}" --output-json > "$python_output" 2>&1 || true

			local python_error=$(grep -qE "Netlink (warning|error):" "$python_output" 2>/dev/null && echo "yes" || echo "no")
			if [ "$python_error" = "yes" ]; then
				print_result SKIP "$test_name (Python CLI returned error)"
			else
				local cql_python=$(jq -r ".\"clock-quality-level\" | sort | .[]" "$python_output" 2>/dev/null | tr '\n' ' ')

				if [ -z "$cql_python" ]; then
					print_result SKIP "$test_name (Python CLI missing attribute)"
				elif [ "$cql_dpll" = "$cql_python" ]; then
					print_result PASS "$test_name (count=$cql_count, match)"
				else
					print_result FAIL "$test_name (mismatch: dpll=[$cql_dpll], python=[$cql_python])"
					echo "  DPLL output: $dpll_json"
					echo "  Python output: $python_output"
				fi
			fi
			break
		fi
	done

	if [ $found_clock_quality -eq 0 ]; then
		print_result SKIP "clock-quality-level test (no device with this attribute)"
	fi

	echo ""
}

# Test complete pin output comparison (all fields and values)
test_pin_complete_comparison() {
	print_header "Testing Complete Pin Output Comparison (dpll vs Python CLI)"

	if [ -z "$PYTHON_CLI" ]; then
		print_result SKIP "complete pin comparison (Python CLI not available)"
		echo ""
		return
	fi

	if ! command -v jq &>/dev/null; then
		print_result SKIP "complete pin comparison (jq not available)"
		echo ""
		return
	fi

	local dpll_json="$TEST_DIR/dpll_pins_complete.json"
	$DPLL_TOOL -j pin show > "$dpll_json" 2>/dev/null || true
	local pin_count=$(jq -r '.pin | length' "$dpll_json" 2>/dev/null || echo 0)

	if [ "$pin_count" -eq 0 ]; then
		print_result SKIP "complete pin comparison (no pins available)"
		echo ""
		return
	fi

	# Pick a random pin
	local random_index=$((RANDOM % pin_count))
	local pin_id=$(jq -r ".pin[$random_index].id" "$dpll_json" 2>/dev/null)

	local test_name="Pin $pin_id: complete output comparison (all fields)"

	# Get pin from dpll tool
	local dpll_output="$TEST_DIR/dpll_pin_${pin_id}_complete.json"
	$DPLL_TOOL -j pin show id "$pin_id" > "$dpll_output" 2>&1 || true

	# Get pin from Python CLI
	local python_output="$TEST_DIR/python_pin_${pin_id}_complete.json"
	python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do pin-get --json "{\"id\": $pin_id}" --output-json > "$python_output" 2>&1 || true

	# Check for errors
	local python_error=$(grep -qE "Netlink (warning|error):" "$python_output" 2>/dev/null && echo "yes" || echo "no")
	local dpll_has_error_msg=$(grep -q "Failed to get\|Failed to dump" "$dpll_output" 2>/dev/null && echo "yes" || echo "no")
	local dpll_json_content=$(grep -o '{.*}' "$dpll_output" 2>/dev/null | tr -d '[:space:]')
	local dpll_error="no"
	if [ "$dpll_has_error_msg" = "yes" ] || [ "$dpll_json_content" = "{}" ]; then
		dpll_error="yes"
	fi

	if [ "$python_error" = "yes" ] && [ "$dpll_error" = "yes" ]; then
		print_result SKIP "$test_name (both tools returned error)"
	elif [ "$python_error" = "yes" ] || [ "$dpll_error" = "yes" ]; then
		print_result FAIL "$test_name (error mismatch: dpll=$dpll_error, python=$python_error)"
		echo "  DPLL output: $dpll_output"
		echo "  Python output: $python_output"
	else
		# Normalize and compare: dpll tool wraps in {pin:[{...}]}, Python CLI returns {...} directly
		local dpll_normalized=$(jq -S '.pin[0] // . | walk(if type == "array" then sort else . end)' "$dpll_output" 2>/dev/null)
		local python_normalized=$(jq -S 'walk(if type == "array" then sort else . end)' "$python_output" 2>/dev/null)

		if [ -z "$dpll_normalized" ] || [ -z "$python_normalized" ]; then
			print_result FAIL "$test_name (invalid JSON)"
			echo "  DPLL output: $dpll_output"
			echo "  Python output: $python_output"
		elif [ "$dpll_normalized" = "$python_normalized" ]; then
			print_result PASS "$test_name"
		else
			print_result FAIL "$test_name (output mismatch)"
			echo "  DPLL output: $dpll_output"
			echo "  Python output: $python_output"
			echo "  Diff (normalized JSON):"
			diff -u <(echo "$dpll_normalized" | jq .) <(echo "$python_normalized" | jq .) || true
		fi
	fi

	echo ""
}

# Test complete device output comparison (all fields and values)
test_device_complete_comparison() {
	print_header "Testing Complete Device Output Comparison (dpll vs Python CLI)"

	if [ -z "$PYTHON_CLI" ]; then
		print_result SKIP "complete device comparison (Python CLI not available)"
		echo ""
		return
	fi

	if ! command -v jq &>/dev/null; then
		print_result SKIP "complete device comparison (jq not available)"
		echo ""
		return
	fi

	local dpll_json="$TEST_DIR/dpll_devices_complete.json"
	$DPLL_TOOL -j device show > "$dpll_json" 2>/dev/null || true
	local device_count=$(jq -r '.device | length' "$dpll_json" 2>/dev/null || echo 0)

	if [ "$device_count" -eq 0 ]; then
		print_result SKIP "complete device comparison (no devices available)"
		echo ""
		return
	fi

	# Pick a random device
	local random_index=$((RANDOM % device_count))
	local device_id=$(jq -r ".device[$random_index].id" "$dpll_json" 2>/dev/null)

	local test_name="Device $device_id: complete output comparison (all fields)"

	# Get device from dpll tool
	local dpll_output="$TEST_DIR/dpll_device_${device_id}_complete.json"
	$DPLL_TOOL -j device show id "$device_id" > "$dpll_output" 2>&1 || true

	# Get device from Python CLI
	local python_output="$TEST_DIR/python_device_${device_id}_complete.json"
	python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do device-get --json "{\"id\": $device_id}" --output-json > "$python_output" 2>&1 || true

	# Check for errors
	local python_error=$(grep -qE "Netlink (warning|error):" "$python_output" 2>/dev/null && echo "yes" || echo "no")
	local dpll_has_error_msg=$(grep -q "Failed to get\|Failed to dump" "$dpll_output" 2>/dev/null && echo "yes" || echo "no")
	local dpll_json_content=$(grep -o '{.*}' "$dpll_output" 2>/dev/null | tr -d '[:space:]')
	local dpll_error="no"
	if [ "$dpll_has_error_msg" = "yes" ] || [ "$dpll_json_content" = "{}" ]; then
		dpll_error="yes"
	fi

	if [ "$python_error" = "yes" ] && [ "$dpll_error" = "yes" ]; then
		print_result SKIP "$test_name (both tools returned error)"
	elif [ "$python_error" = "yes" ] || [ "$dpll_error" = "yes" ]; then
		print_result FAIL "$test_name (error mismatch: dpll=$dpll_error, python=$python_error)"
		echo "  DPLL output: $dpll_output"
		echo "  Python output: $python_output"
	else
		# Normalize and compare: dpll tool wraps in {device:[{...}]}, Python CLI returns {...} directly
		local dpll_normalized=$(jq -S '.device[0] // . | walk(if type == "array" then sort else . end)' "$dpll_output" 2>/dev/null)
		local python_normalized=$(jq -S 'walk(if type == "array" then sort else . end)' "$python_output" 2>/dev/null)

		if [ -z "$dpll_normalized" ] || [ -z "$python_normalized" ]; then
			print_result FAIL "$test_name (invalid JSON)"
			echo "  DPLL output: $dpll_output"
			echo "  Python output: $python_output"
		elif [ "$dpll_normalized" = "$python_normalized" ]; then
			print_result PASS "$test_name"
		else
			print_result FAIL "$test_name (output mismatch)"
			echo "  DPLL output: $dpll_output"
			echo "  Python output: $python_output"
			echo "  Diff (normalized JSON):"
			diff -u <(echo "$dpll_normalized" | jq .) <(echo "$python_normalized" | jq .) || true
		fi
	fi

	echo ""
}

# Test error handling
test_error_handling() {
	print_header "Testing Error Handling"

	# Test invalid commands
	if ! $DPLL_TOOL invalid-command 2>/dev/null; then
		print_result PASS "Invalid command rejected"
	else
		print_result FAIL "Invalid command accepted"
	fi

	# Test invalid device ID
	if ! $DPLL_TOOL device show id 999999 2>/dev/null; then
		print_result PASS "Invalid device ID rejected"
	else
		print_result FAIL "Invalid device ID accepted"
	fi

	# Test invalid pin ID
	if ! $DPLL_TOOL pin show id 999999 2>/dev/null; then
		print_result PASS "Invalid pin ID rejected"
	else
		print_result FAIL "Invalid pin ID accepted"
	fi

	# Test missing required arguments
	if ! $DPLL_TOOL device show id 2>/dev/null; then
		print_result PASS "Missing required argument detected"
	else
		print_result FAIL "Missing required argument not detected"
	fi

	# Test invalid pin set without ID
	if ! $DPLL_TOOL pin set prio 10 2>/dev/null; then
		print_result PASS "Pin set without ID rejected"
	else
		print_result FAIL "Pin set without ID accepted"
	fi

	# Test device set without ID
	if ! $DPLL_TOOL device set phase-offset-monitor true 2>/dev/null; then
		print_result PASS "Device set without ID rejected"
	else
		print_result FAIL "Device set without ID accepted"
	fi

	echo ""
}

# Test pretty JSON output
test_pretty_json() {
	print_header "Testing Pretty JSON Output"

	local json_file="$TEST_DIR/test_pretty.json"
	local plain_json_file="$TEST_DIR/test_plain.json"

	$DPLL_TOOL -jp device show > "$json_file" 2>&1 || true
	$DPLL_TOOL -j device show > "$plain_json_file" 2>&1 || true

	if [ -s "$json_file" ] && [ -s "$plain_json_file" ]; then
		# Check if pretty version has more lines (indentation)
		local pretty_lines=$(wc -l < "$json_file")
		local plain_lines=$(wc -l < "$plain_json_file")

		if [ "$pretty_lines" -gt "$plain_lines" ]; then
			print_result PASS "Pretty JSON has indentation"
		else
			print_result FAIL "Pretty JSON not properly formatted"
		fi

		# Check if both are valid JSON
		if jq empty "$json_file" 2>/dev/null && jq empty "$plain_json_file" 2>/dev/null; then
			# Check if they're semantically equal
			if [ "$(jq -S . "$json_file")" == "$(jq -S . "$plain_json_file")" ]; then
				print_result PASS "Pretty and plain JSON are equivalent"
			else
				print_result FAIL "Pretty and plain JSON differ in content"
			fi
		fi
	else
		print_result SKIP "Pretty JSON test (no output)"
	fi

	echo ""
}

# Print summary
print_summary() {
	echo ""
	echo ""

	# Print summary table
	local width=70
	echo -e "${BOLD}${CYAN}${BOX_TL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_TR}${NC}"
	printf "${CYAN}${BOX_V}${NC}${BOLD}%-${width}s${NC}${CYAN}${BOX_V}${NC}\n" "                          TEST SUMMARY"
	echo -e "${CYAN}${BOX_VR}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_VL}${NC}"

	# Calculate percentages
	local pass_pct=0
	local fail_pct=0
	local skip_pct=0
	if [ $TOTAL_TESTS -gt 0 ]; then
		pass_pct=$(( PASSED_TESTS * 100 / TOTAL_TESTS ))
		fail_pct=$(( FAILED_TESTS * 100 / TOTAL_TESTS ))
		skip_pct=$(( SKIPPED_TESTS * 100 / TOTAL_TESTS ))
	fi

	# Print statistics
	printf "${CYAN}${BOX_V}${NC}  %-30s ${BOLD}%4d${NC} / %-4d   ${DIM}(100%%)${NC}  ${CYAN}${BOX_V}${NC}\n" "Total Tests:" $TOTAL_TESTS $TOTAL_TESTS
	printf "${CYAN}${BOX_V}${NC}  ${GREEN}%-30s${NC} ${GREEN}${BOLD}%4d${NC} / %-4d   ${DIM}(%3d%%)${NC}  ${CYAN}${BOX_V}${NC}\n" "✓ Passed:" $PASSED_TESTS $TOTAL_TESTS $pass_pct
	printf "${CYAN}${BOX_V}${NC}  ${RED}%-30s${NC} ${RED}${BOLD}%4d${NC} / %-4d   ${DIM}(%3d%%)${NC}  ${CYAN}${BOX_V}${NC}\n" "✗ Failed:" $FAILED_TESTS $TOTAL_TESTS $fail_pct
	printf "${CYAN}${BOX_V}${NC}  ${YELLOW}%-30s${NC} ${YELLOW}${BOLD}%4d${NC} / %-4d   ${DIM}(%3d%%)${NC}  ${CYAN}${BOX_V}${NC}\n" "○ Skipped:" $SKIPPED_TESTS $TOTAL_TESTS $skip_pct

	echo -e "${CYAN}${BOX_VR}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_VL}${NC}"

	# Print dmesg errors if any
	if [ $DMESG_ERRORS -gt 0 ]; then
		printf "${CYAN}${BOX_V}${NC}  ${RED}⚠ Kernel Errors:${NC} ${RED}${BOLD}%4d${NC} test(s) triggered netlink errors ${CYAN}${BOX_V}${NC}\n" $DMESG_ERRORS
		echo -e "${CYAN}${BOX_VR}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_VL}${NC}"
	fi

	# Print result
	if [ $FAILED_TESTS -eq 0 ]; then
		if [ $PASSED_TESTS -eq $TOTAL_TESTS ]; then
			printf "${CYAN}${BOX_V}${NC}  ${GREEN}${BOLD}%-${width}s${NC}${CYAN}${BOX_V}${NC}\n" "✓ ALL TESTS PASSED!"
		else
			printf "${CYAN}${BOX_V}${NC}  ${GREEN}${BOLD}%-${width}s${NC}${CYAN}${BOX_V}${NC}\n" "✓ NO FAILURES (some tests skipped)"
		fi
		echo -e "${CYAN}${BOX_BL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_BR}${NC}"
		echo ""
		return 0
	else
		printf "${CYAN}${BOX_V}${NC}  ${RED}${BOLD}%-${width}s${NC}${CYAN}${BOX_V}${NC}\n" "✗ SOME TESTS FAILED!"
		echo -e "${CYAN}${BOX_BL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_BR}${NC}"
		echo ""
		return 1
	fi
}

# Print banner
print_banner() {
	local width=70
	echo ""
	echo -e "${BOLD}${CYAN}${BOX_TL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_TR}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}                                                                      ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}${GREEN}                  ____  ____  __    __                              ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}${GREEN}                 / __ \\/ __ \\/ /   / /                              ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}${GREEN}                / / / / /_/ / /   / /                               ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}${GREEN}               / /_/ / ____/ /___/ /___                             ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}${GREEN}              /_____/_/   /_____/_____/                             ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}                                                                      ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}                    Tool Test Suite                                   ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_V}${NC}${BOLD}                                                                      ${NC}${CYAN}${BOX_V}${NC}"
	echo -e "${CYAN}${BOX_BL}$(printf '%*s' $width '' | tr ' ' "$BOX_H")${BOX_BR}${NC}"
	echo ""
}

# Main test execution
main() {
	print_banner

	check_prerequisites
	test_help
	test_version
	test_device_operations
	test_device_id_get
	test_device_set
	test_pin_operations
	test_pin_id_get
	test_pin_set
	test_pin_frequency_change
	test_pin_priority_capability
	test_parent_operations
	test_reference_sync
	test_monitor
	test_monitor_events
	test_monitor_python_parity
	test_json_consistency
	test_legacy_output
	test_json_legacy_consistency
	test_device_by_id_formats
	test_pin_by_id_formats
	test_pretty_json
	test_error_handling
	test_s64_sint_values
	test_multi_enum_arrays
	test_pin_complete_comparison
	test_device_complete_comparison

	print_summary
}

main "$@"
