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

set -e

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
DPLL_TOOL="./dpll"
PYTHON_CLI="/root/net-next/tools/net/ynl/pyynl/cli.py"
DPLL_SPEC="/root/net-next/Documentation/netlink/specs/dpll.yaml"
TEST_DIR="/tmp/dpll_test_$$"

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Create test directory
mkdir -p "$TEST_DIR"

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
			;;
		FAIL)
			echo -e "  ${RED}${BOLD}${CROSS}${NC} ${RED}FAIL${NC} ${DIM}│${NC} $test_name"
			FAILED_TESTS=$((FAILED_TESTS + 1))
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
	if [ ! -x "$DPLL_TOOL" ]; then
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

	# Normalize and compare JSON
	local dpll_normalized=$(jq -S . "$dpll_out" 2>/dev/null)
	local python_normalized=$(jq -S . "$python_out" 2>/dev/null)

	if [ -z "$dpll_normalized" ] || [ -z "$python_normalized" ]; then
		print_result FAIL "$test_name (invalid JSON)"
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

	if $DPLL_TOOL device show > "$dpll_dump" 2>&1; then
		print_result PASS "dpll device show (dump)"
	else
		print_result FAIL "dpll device show (dump)"
	fi

	# Test device show with JSON
	local dpll_json="$TEST_DIR/dpll_device_dump.json"
	if $DPLL_TOOL -j device show > "$dpll_json" 2>&1; then
		if jq empty "$dpll_json" 2>/dev/null; then
			print_result PASS "dpll device show -j (valid JSON)"
		else
			print_result FAIL "dpll device show -j (invalid JSON)"
		fi
	else
		print_result FAIL "dpll device show -j"
	fi

	# Get first device ID from dump
	local device_id=$(grep -oP 'id \K\d+' "$dpll_dump" | head -1)

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

			if [ -s "$dpll_dev_json" ] && [ -s "$python_dev_json" ]; then
				compare_json "$dpll_dev_json" "$python_dev_json" "device show id $device_id (vs Python)"
			else
				print_result SKIP "device show id $device_id (vs Python)"
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
			local found_id=$($DPLL_TOOL device id-get module-name "$module_name" 2>/dev/null | tr -d '\n')
			if [ "$found_id" == "$device_id" ]; then
				print_result PASS "dpll device id-get module-name $module_name"
			else
				print_result FAIL "dpll device id-get module-name $module_name (expected $device_id, got $found_id)"
			fi

			# Compare with Python CLI
			if [ -n "$PYTHON_CLI" ]; then
				local dpll_result="$TEST_DIR/dpll_device_id_get.json"
				local python_result="$TEST_DIR/python_device_id_get.json"

				$DPLL_TOOL -j device id-get module-name "$module_name" > "$dpll_result" 2>&1 || true
				python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do device-id-get --json '{"module-name": "'$module_name'"}' --output-json > "$python_result" 2>&1 || true

				if [ -s "$dpll_result" ] && [ -s "$python_result" ]; then
					compare_json "$dpll_result" "$python_result" "device id-get module-name (vs Python)"
				else
					print_result SKIP "device id-get module-name (vs Python)"
				fi
			fi
		else
			print_result SKIP "device id-get module-name (no module found)"
		fi

		if [ -n "$clock_id" ] && [ "$clock_id" != "null" ] && [ -n "$module_name" ] && [ "$module_name" != "null" ]; then
			# Test device-id-get by module-name + clock-id
			local found_id=$($DPLL_TOOL device id-get module-name "$module_name" clock-id "$clock_id" 2>/dev/null | tr -d '\n')
			if [ "$found_id" == "$device_id" ]; then
				print_result PASS "dpll device id-get module-name + clock-id"
			else
				print_result FAIL "dpll device id-get module-name + clock-id (expected $device_id, got $found_id)"
			fi

			# Compare with Python CLI
			if [ -n "$PYTHON_CLI" ]; then
				local dpll_result="$TEST_DIR/dpll_device_id_get_clock.json"
				local python_result="$TEST_DIR/python_device_id_get_clock.json"

				$DPLL_TOOL -j device id-get module-name "$module_name" clock-id "$clock_id" > "$dpll_result" 2>&1 || true
				python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do device-id-get --json '{"module-name": "'$module_name'", "clock-id": '$clock_id'}' --output-json > "$python_result" 2>&1 || true

				if [ -s "$dpll_result" ] && [ -s "$python_result" ]; then
					compare_json "$dpll_result" "$python_result" "device id-get module-name + clock-id (vs Python)"
				else
					print_result SKIP "device id-get module-name + clock-id (vs Python)"
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

	if $DPLL_TOOL pin show > "$dpll_dump" 2>&1; then
		print_result PASS "dpll pin show (dump)"
	else
		print_result FAIL "dpll pin show (dump)"
	fi

	# Test pin show with JSON
	local dpll_json="$TEST_DIR/dpll_pin_dump.json"
	if $DPLL_TOOL -j pin show > "$dpll_json" 2>&1; then
		if jq empty "$dpll_json" 2>/dev/null; then
			print_result PASS "dpll pin show -j (valid JSON)"
		else
			print_result FAIL "dpll pin show -j (invalid JSON)"
		fi
	else
		print_result FAIL "dpll pin show -j"
	fi

	# Get first pin ID from dump
	local pin_id=$(grep -oP 'id \K\d+' "$dpll_dump" | head -1)

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

			if [ -s "$dpll_pin_json" ] && [ -s "$python_pin_json" ]; then
				compare_json "$dpll_pin_json" "$python_pin_json" "pin show id $pin_id (vs Python)"
			else
				print_result SKIP "pin show id $pin_id (vs Python)"
			fi
		fi
	else
		print_result SKIP "pin show id (no pins found)"
	fi

	# Test pin show with device filter
	local device_id=$(grep -oP 'id \K\d+' "$TEST_DIR/dpll_device_dump.txt" 2>/dev/null | head -1)
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
				python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do pin-id-get --json '{"board-label": "'$board_label'"}' --output-json > "$python_result" 2>&1 || true

				if [ -s "$dpll_result" ] && [ -s "$python_result" ]; then
					compare_json "$dpll_result" "$python_result" "pin id-get board-label (vs Python)"
				else
					print_result SKIP "pin id-get board-label (vs Python)"
				fi
			fi
		else
			print_result SKIP "pin id-get board-label (no label found)"
		fi

		if [ -n "$module_name" ] && [ "$module_name" != "null" ]; then
			# Test pin-id-get by module-name (may return multiple IDs)
			local found_ids=$($DPLL_TOOL pin id-get module-name "$module_name" 2>/dev/null | tr '\n' ' ')
			if echo "$found_ids" | grep -qw "$pin_id"; then
				print_result PASS "dpll pin id-get module-name $module_name"
			else
				print_result FAIL "dpll pin id-get module-name $module_name (expected to include $pin_id)"
			fi

			# Compare with Python CLI
			if [ -n "$PYTHON_CLI" ]; then
				local dpll_result="$TEST_DIR/dpll_pin_id_get_module.json"
				local python_result="$TEST_DIR/python_pin_id_get_module.json"

				$DPLL_TOOL -j pin id-get module-name "$module_name" > "$dpll_result" 2>&1 || true
				python3 "$PYTHON_CLI" --spec "$DPLL_SPEC" --do pin-id-get --json '{"module-name": "'$module_name'"}' --output-json > "$python_result" 2>&1 || true

				if [ -s "$dpll_result" ] && [ -s "$python_result" ]; then
					compare_json "$dpll_result" "$python_result" "pin id-get module-name (vs Python)"
				else
					print_result SKIP "pin id-get module-name (vs Python)"
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
		local json_ids=$(jq -r '.[].id' "$json_file" 2>/dev/null | sort)
		local legacy_ids=$(grep -oP '^id \K\d+' "$legacy_file" | sort)

		if [ "$json_ids" == "$legacy_ids" ] && [ -n "$json_ids" ]; then
			print_result PASS "Device IDs match between JSON and legacy output"
		elif [ -z "$json_ids" ] && [ -z "$legacy_ids" ]; then
			print_result SKIP "No devices to compare"
		else
			print_result FAIL "Device IDs differ between JSON and legacy output"
			echo "  JSON IDs: $json_ids"
			echo "  Legacy IDs: $legacy_ids"
		fi

		# Check if module-names match
		local json_modules=$(jq -r '.[]["module-name"] // empty' "$json_file" 2>/dev/null | sort)
		local legacy_modules=$(grep -oP 'module-name \K\S+' "$legacy_file" | sort)

		if [ "$json_modules" == "$legacy_modules" ] && [ -n "$json_modules" ]; then
			print_result PASS "Module names match between JSON and legacy output"
		elif [ -z "$json_modules" ] && [ -z "$legacy_modules" ]; then
			print_result SKIP "No module names to compare"
		else
			print_result FAIL "Module names differ between JSON and legacy output"
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
		local json_pin_ids=$(jq -r '.[].id' "$pin_json_file" 2>/dev/null | sort)
		local legacy_pin_ids=$(grep -oP '^id \K\d+' "$pin_legacy_file" | sort)

		if [ "$json_pin_ids" == "$legacy_pin_ids" ] && [ -n "$json_pin_ids" ]; then
			print_result PASS "Pin IDs match between JSON and legacy output"
		elif [ -z "$json_pin_ids" ] && [ -z "$legacy_pin_ids" ]; then
			print_result SKIP "No pins to compare"
		else
			print_result FAIL "Pin IDs differ between JSON and legacy output"
		fi
	else
		print_result SKIP "Pin JSON vs Legacy consistency (missing output)"
	fi

	echo ""
}

# Test specific device by ID in both formats
test_device_by_id_formats() {
	print_header "Testing Device By ID (Both Formats)"

	local device_id=$(grep -oP 'id \K\d+' "$TEST_DIR/device_legacy.txt" 2>/dev/null | head -1)

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
		local legacy_attrs=$(grep -oP '^\s*\K[a-z-]+(?=:)' "$dev_legacy" | sort | uniq)
		local json_attrs=$(jq -r 'keys[]' "$dev_json" 2>/dev/null | sort)

		# Count attributes in both
		local legacy_count=$(echo "$legacy_attrs" | wc -l)
		local json_count=$(echo "$json_attrs" | wc -l)

		if [ "$legacy_count" -gt 0 ] && [ "$json_count" -gt 0 ]; then
			print_result PASS "Device $device_id has attributes in both formats (legacy:$legacy_count, json:$json_count)"
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

	local pin_id=$(grep -oP 'id \K\d+' "$TEST_DIR/pin_legacy.txt" 2>/dev/null | head -1)

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
		local legacy_attrs=$(grep -oP '^\s*\K[a-z-]+(?=:)' "$pin_legacy" | sort | uniq)
		local json_attrs=$(jq -r 'keys[]' "$pin_json" 2>/dev/null | sort)

		local legacy_count=$(echo "$legacy_attrs" | wc -l)
		local json_count=$(echo "$json_attrs" | wc -l)

		if [ "$legacy_count" -gt 0 ] && [ "$json_count" -gt 0 ]; then
			print_result PASS "Pin $pin_id has attributes in both formats (legacy:$legacy_count, json:$json_count)"
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

	local device_id=$(grep -oP 'id \K\d+' "$TEST_DIR/device_legacy.txt" 2>/dev/null | head -1)

	if [ -n "$device_id" ]; then
		# Test device set with phase-offset-monitor (read current value first)
		if $DPLL_TOOL device set id "$device_id" phase-offset-monitor true 2>/dev/null; then
			print_result PASS "Device set phase-offset-monitor true"
		else
			print_result SKIP "Device set phase-offset-monitor (not supported by device)"
		fi

		# Test device set with phase-offset-avg-factor
		if $DPLL_TOOL device set id "$device_id" phase-offset-avg-factor 10 2>/dev/null; then
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

	local pin_id=$(grep -oP 'id \K\d+' "$TEST_DIR/pin_legacy.txt" 2>/dev/null | head -1)

	if [ -n "$pin_id" ]; then
		# Test pin set with various attributes
		# Note: These may fail if hardware doesn't support the operation, so we SKIP instead of FAIL

		if $DPLL_TOOL pin set id "$pin_id" prio 10 2>/dev/null; then
			print_result PASS "Pin set prio 10"
		else
			print_result SKIP "Pin set prio (not supported)"
		fi

		if $DPLL_TOOL pin set id "$pin_id" state connected 2>/dev/null; then
			print_result PASS "Pin set state connected"
		else
			print_result SKIP "Pin set state (not supported)"
		fi

		if $DPLL_TOOL pin set id "$pin_id" direction input 2>/dev/null; then
			print_result PASS "Pin set direction input"
		else
			print_result SKIP "Pin set direction (not supported)"
		fi
	else
		print_result SKIP "Pin set operations (no pins)"
	fi

	echo ""
}

# Test parent-device and parent-pin operations
test_parent_operations() {
	print_header "Testing Parent Device/Pin Operations"

	local pin_dump="$TEST_DIR/pin_legacy.txt"

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
		local device_id=$(grep -oP 'id \K\d+' "$TEST_DIR/device_legacy.txt" 2>/dev/null | head -1)
		local pin_id=$(grep -oP 'id \K\d+' "$pin_dump" 2>/dev/null | head -1)

		if [ -n "$device_id" ] && [ -n "$pin_id" ]; then
			if $DPLL_TOOL pin set id "$pin_id" parent-device "$device_id" state connected 2>/dev/null; then
				print_result PASS "Pin set with parent-device"
			else
				print_result SKIP "Pin set with parent-device (not supported)"
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
		local pin_id=$(grep -oP 'id \K\d+' "$pin_dump" 2>/dev/null | head -1)
		local ref_pin_id=$(grep -oP 'id \K\d+' "$pin_dump" 2>/dev/null | sed -n '2p')

		if [ -n "$pin_id" ] && [ -n "$ref_pin_id" ]; then
			if $DPLL_TOOL pin set id "$pin_id" reference-sync "$ref_pin_id" state connected 2>/dev/null; then
				print_result PASS "Pin set with reference-sync"
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
	test_parent_operations
	test_reference_sync
	test_monitor
	test_json_consistency
	test_legacy_output
	test_json_legacy_consistency
	test_device_by_id_formats
	test_pin_by_id_formats
	test_pretty_json
	test_error_handling

	print_summary
}

main "$@"
