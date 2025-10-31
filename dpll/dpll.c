/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * dpll-mnl.c	DPLL tool using libmnl
 *
 * Authors:	TBD
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <linux/dpll.h>
#include <linux/genetlink.h>
#include <libmnl/libmnl.h>

#include "../devlink/mnlg.h"
#include "mnl_utils.h"
#include "version.h"
#include "utils.h"
#include "json_print.h"

static volatile sig_atomic_t monitor_running = 1;

static void monitor_sig_handler(int signo __attribute__((unused)))
{
	monitor_running = 0;
}

struct dpll {
	struct mnlu_gen_socket nlg;
	int argc;
	char **argv;
	bool json_output;
};

static int dpll_argc(struct dpll *dpll)
{
	return dpll->argc;
}

static char *dpll_argv(struct dpll *dpll)
{
	if (dpll_argc(dpll) == 0)
		return NULL;
	return *dpll->argv;
}

static void dpll_arg_inc(struct dpll *dpll)
{
	if (dpll_argc(dpll) == 0)
		return;
	dpll->argc--;
	dpll->argv++;
}

static char *dpll_argv_next(struct dpll *dpll)
{
	char *ret;

	dpll_arg_inc(dpll);  /* Skip keyword */
	if (dpll_argc(dpll) == 0)
		return NULL;

	ret = *dpll->argv;   /* Get value */
	dpll_arg_inc(dpll);  /* Skip value */
	return ret;
}

static bool dpll_argv_match(struct dpll *dpll, const char *pattern)
{
	if (dpll_argc(dpll) == 0)
		return false;
	return strcmp(dpll_argv(dpll), pattern) == 0;
}

static bool dpll_no_arg(struct dpll *dpll)
{
	return dpll_argc(dpll) == 0;
}

#define pr_err(args...) fprintf(stderr, ##args)
#define pr_out(args...) fprintf(stdout, ##args)

/* Helper to parse pin state argument */
static int dpll_parse_state(struct dpll *dpll, __u32 *state)
{
	if (dpll_argv_match(dpll, "connected")) {
		*state = DPLL_PIN_STATE_CONNECTED;
	} else if (dpll_argv_match(dpll, "disconnected")) {
		*state = DPLL_PIN_STATE_DISCONNECTED;
	} else if (dpll_argv_match(dpll, "selectable")) {
		*state = DPLL_PIN_STATE_SELECTABLE;
	} else {
		pr_err("invalid state: %s (use connected/disconnected/selectable)\n",
		       dpll_argv(dpll));
		return -EINVAL;
	}
	return 0;
}

/* Helper to parse pin direction argument */
static int dpll_parse_direction(struct dpll *dpll, __u32 *direction)
{
	if (dpll_argv_match(dpll, "input")) {
		*direction = DPLL_PIN_DIRECTION_INPUT;
	} else if (dpll_argv_match(dpll, "output")) {
		*direction = DPLL_PIN_DIRECTION_OUTPUT;
	} else {
		pr_err("invalid direction: %s (use input/output)\n",
		       dpll_argv(dpll));
		return -EINVAL;
	}
	return 0;
}

/* Helper to check if next argument exists */
static int dpll_arg_required(struct dpll *dpll, const char *arg_name)
{
	if (dpll_argc(dpll) == 0) {
		pr_err("%s requires an argument\n", arg_name);
		return -EINVAL;
	}
	return 0;
}

/* Helper to match argument and increment pointer if matched */
static bool dpll_argv_match_inc(struct dpll *dpll, const char *pattern)
{
	if (!dpll_argv_match(dpll, pattern))
		return false;
	dpll_arg_inc(dpll);
	return true;
}

/* Macros for parsing and setting netlink attributes
 * These macros handle the complete parsing flow:
 * 1. Increment from keyword to value (dpll_arg_inc)
 * 2. Argument presence validation (dpll_arg_required)
 * 3. String-to-value conversion with error handling
 * 4. Netlink attribute addition
 * 5. Increment from value to next keyword (dpll_arg_inc)
 *
 * Usage:
 *   if (dpll_argv_match(dpll, "frequency")) {
 *       DPLL_PARSE_ATTR_U64(dpll, nlh, "frequency", DPLL_A_PIN_FREQUENCY);
 *   }
 */

/* Parse U32 argument into a variable */
#define DPLL_PARSE_U32(dpll, arg_name, var_ptr) \
	do { \
		char *__str = dpll_argv_next(dpll); \
		if (!__str) { \
			pr_err("%s requires an argument\n", arg_name); \
			return -EINVAL; \
		} \
		if (get_u32(var_ptr, __str, 0)) { \
			pr_err("invalid %s: %s\n", arg_name, __str); \
			return -EINVAL; \
		} \
	} while (0)

/* Parse U32 argument and add to netlink message */
#define DPLL_PARSE_ATTR_U32(dpll, nlh, arg_name, attr_id) \
	do { \
		__u32 __val; \
		DPLL_PARSE_U32(dpll, arg_name, &__val); \
		mnl_attr_put_u32(nlh, attr_id, __val); \
	} while (0)

#define DPLL_PARSE_ATTR_S32(dpll, nlh, arg_name, attr_id) \
	do { \
		__s32 __val; \
		char *__str = dpll_argv_next(dpll); \
		if (!__str) { \
			pr_err("%s requires an argument\n", arg_name); \
			return -EINVAL; \
		} \
		if (get_s32(&__val, __str, 0)) { \
			pr_err("invalid %s: %s\n", arg_name, __str); \
			return -EINVAL; \
		} \
		mnl_attr_put_u32(nlh, attr_id, __val); \
	} while (0)

#define DPLL_PARSE_ATTR_U64(dpll, nlh, arg_name, attr_id) \
	do { \
		__u64 __val; \
		char *__str = dpll_argv_next(dpll); \
		if (!__str) { \
			pr_err("%s requires an argument\n", arg_name); \
			return -EINVAL; \
		} \
		if (get_u64(&__val, __str, 0)) { \
			pr_err("invalid %s: %s\n", arg_name, __str); \
			return -EINVAL; \
		} \
		mnl_attr_put_u64(nlh, attr_id, __val); \
	} while (0)

#define DPLL_PARSE_ATTR_STR(dpll, nlh, arg_name, attr_id) \
	do { \
		char *__str = dpll_argv_next(dpll); \
		if (!__str) { \
			pr_err("%s requires an argument\n", arg_name); \
			return -EINVAL; \
		} \
		mnl_attr_put_strz(nlh, attr_id, __str); \
	} while (0)

#define DPLL_PARSE_ATTR_ENUM(dpll, nlh, arg_name, attr_id, parse_func) \
	do { \
		__u32 __val; \
		dpll_arg_inc(dpll); \
		if (dpll_arg_required(dpll, arg_name)) \
			return -EINVAL; \
		if (parse_func(dpll, &__val)) \
			return -EINVAL; \
		mnl_attr_put_u32(nlh, attr_id, __val); \
		dpll_arg_inc(dpll); \
	} while (0)

/* Macros for printing netlink attributes
 * These macros combine the common pattern of:
 * if (tb[ATTR]) print_xxx(PRINT_ANY, "name", "format", mnl_attr_get_xxx(tb[ATTR]));
 *
 * Generic versions with custom format string (_FMT suffix)
 * Simple versions auto-generate format string: "  name: %d\n"
 */

/* Generic versions with custom format */
#define DPLL_PR_INT_FMT(tb, attr_id, name, format_str) \
	do { \
		if (tb[attr_id]) \
			print_int(PRINT_ANY, name, format_str, \
				  mnl_attr_get_u32(tb[attr_id])); \
	} while (0)

#define DPLL_PR_UINT_FMT(tb, attr_id, name, format_str) \
	do { \
		if (tb[attr_id]) \
			print_uint(PRINT_ANY, name, format_str, \
				   mnl_attr_get_u32(tb[attr_id])); \
	} while (0)

#define DPLL_PR_U64_FMT(tb, attr_id, name, format_str) \
	do { \
		if (tb[attr_id]) \
			print_lluint(PRINT_ANY, name, format_str, \
				     mnl_attr_get_u64(tb[attr_id])); \
	} while (0)

#define DPLL_PR_S64_FMT(tb, attr_id, name, format_str) \
	do { \
		if (tb[attr_id]) \
			print_lluint(PRINT_ANY, name, format_str, \
				     (long long)mnl_attr_get_u64(tb[attr_id])); \
	} while (0)

#define DPLL_PR_STR_FMT(tb, attr_id, name, format_str) \
	do { \
		if (tb[attr_id]) \
			print_string(PRINT_ANY, name, format_str, \
				     mnl_attr_get_str(tb[attr_id])); \
	} while (0)

/* Simple versions with auto-generated format */
#define DPLL_PR_INT(tb, attr_id, name) \
	DPLL_PR_INT_FMT(tb, attr_id, name, "  " name ": %d\n")

#define DPLL_PR_UINT(tb, attr_id, name) \
	DPLL_PR_UINT_FMT(tb, attr_id, name, "  " name ": %u\n")

#define DPLL_PR_U64(tb, attr_id, name) \
	DPLL_PR_U64_FMT(tb, attr_id, name, "  " name ": %llu\n")

#define DPLL_PR_S64(tb, attr_id, name) \
	DPLL_PR_S64_FMT(tb, attr_id, name, "  " name ": %lld\n")

/* Helper to read signed int (can be s32 or s64 depending on value) */
static inline __s64 mnl_attr_get_sint(const struct nlattr *attr)
{
	if (mnl_attr_get_payload_len(attr) == sizeof(__s32)) {
		__s32 tmp;
		memcpy(&tmp, mnl_attr_get_payload(attr), sizeof(__s32));
		return tmp;
	} else {
		__s64 tmp;
		memcpy(&tmp, mnl_attr_get_payload(attr), sizeof(__s64));
		return tmp;
	}
}

#define DPLL_PR_SINT_FMT(tb, attr_id, name, format_str) \
	do { \
		if (tb[attr_id]) \
			print_s64(PRINT_ANY, name, format_str, \
				  mnl_attr_get_sint(tb[attr_id])); \
	} while (0)

#define DPLL_PR_SINT(tb, attr_id, name) \
	DPLL_PR_SINT_FMT(tb, attr_id, name, "  " name ": %lld\n")

#define DPLL_PR_STR(tb, attr_id, name) \
	DPLL_PR_STR_FMT(tb, attr_id, name, "  " name ": %s\n")

/* Macros for printing enum values converted to strings via name function */

/* Generic version with custom format */
#define DPLL_PR_ENUM_STR_FMT(tb, attr_id, name, format_str, name_func) \
	do { \
		if (tb[attr_id]) \
			print_string(PRINT_ANY, name, format_str, \
				     name_func(mnl_attr_get_u32(tb[attr_id]))); \
	} while (0)

/* Simple version with auto-generated format */
#define DPLL_PR_ENUM_STR(tb, attr_id, name, name_func) \
	DPLL_PR_ENUM_STR_FMT(tb, attr_id, name, "  " name ": %s\n", name_func)

/* Multi-attr enum printer - handles multiple occurrences of same attribute */
#define DPLL_PR_MULTI_ENUM_STR(nlh, attr_id, name, name_func) \
	do { \
		if (nlh) { \
			struct genlmsghdr *__genl = mnl_nlmsg_get_payload(nlh); \
			struct nlattr *__attr; \
			bool __first = true; \
			mnl_attr_for_each(__attr, nlh, sizeof(*__genl)) { \
				if (mnl_attr_get_type(__attr) == (attr_id)) { \
					__u32 __val = mnl_attr_get_u32(__attr); \
					if (__first) { \
						if (is_json_context()) { \
							open_json_array(PRINT_JSON, name); \
						} else { \
							pr_out("  " name ":"); \
						} \
						__first = false; \
					} \
					if (is_json_context()) { \
						print_string(PRINT_JSON, NULL, NULL, \
							     name_func(__val)); \
					} else { \
						pr_out(" %s", name_func(__val)); \
					} \
				} \
			} \
			if (!__first) { \
				if (is_json_context()) { \
					close_json_array(PRINT_JSON, NULL); \
				} else { \
					pr_out("\n"); \
				} \
			} \
		} \
	} while (0)

static void help(void)
{
	pr_err("Usage: dpll [ OPTIONS ] OBJECT { COMMAND | help }\n"
	       "       dpll [ -j[son] ] [ -p[retty] ]\n"
	       "where  OBJECT := { device | pin | monitor }\n"
	       "       OPTIONS := { -V[ersion] | -j[son] | -p[retty] }\n");
}

static int cmd_device(struct dpll *dpll);
static int cmd_pin(struct dpll *dpll);
static int cmd_monitor(struct dpll *dpll);

static int dpll_cmd(struct dpll *dpll, int argc, char **argv)
{
	dpll->argc = argc;
	dpll->argv = argv;

	if (dpll_argv_match(dpll, "help") || dpll_no_arg(dpll)) {
		help();
		return 0;
	} else if (dpll_argv_match_inc(dpll, "device")) {
		return cmd_device(dpll);
	} else if (dpll_argv_match_inc(dpll, "pin")) {
		return cmd_pin(dpll);
	} else if (dpll_argv_match_inc(dpll, "monitor")) {
		return cmd_monitor(dpll);
	}
	pr_err("Object \"%s\" not found\n", dpll_argv(dpll));
	return -ENOENT;
}

static int dpll_init(struct dpll *dpll)
{
	int err;

	err = mnlu_gen_socket_open(&dpll->nlg, "dpll", DPLL_FAMILY_VERSION);
	if (err) {
		pr_err("Failed to connect to DPLL Netlink (DPLL subsystem not available in kernel?)\n");
		return -1;
	}
	return 0;
}

static void dpll_fini(struct dpll *dpll)
{
	mnlu_gen_socket_close(&dpll->nlg);
}

static struct dpll *dpll_alloc(void)
{
	struct dpll *dpll;

	dpll = calloc(1, sizeof(*dpll));
	if (!dpll)
		return NULL;
	return dpll;
}

static void dpll_free(struct dpll *dpll)
{
	free(dpll);
}

int main(int argc, char **argv)
{
	static const struct option long_options[] = {
		{ "Version",	no_argument,		NULL, 'V' },
		{ "json",	no_argument,		NULL, 'j' },
		{ "pretty",	no_argument,		NULL, 'p' },
		{ NULL, 0, NULL, 0 }
	};
	const char *opt_short = "Vjp";
	struct dpll *dpll;
	int opt;
	int err;
	int ret;

	dpll = dpll_alloc();
	if (!dpll) {
		pr_err("Failed to allocate memory\n");
		return EXIT_FAILURE;
	}

	while ((opt = getopt_long(argc, argv, opt_short,
				  long_options, NULL)) >= 0) {
		switch (opt) {
		case 'V':
			printf("dpll utility, iproute2-%s\n", version);
			ret = EXIT_SUCCESS;
			goto dpll_free;
		case 'j':
			dpll->json_output = true;
			break;
		case 'p':
			pretty = true;
			break;
		default:
			pr_err("Unknown option.\n");
			help();
			ret = EXIT_FAILURE;
			goto dpll_free;
		}
	}

	argc -= optind;
	argv += optind;

	/* Initialize JSON context */
	new_json_obj_plain(dpll->json_output);
	if (dpll->json_output)
		open_json_object(NULL);

	/* Check if we need netlink (skip for help) */
	bool need_nl = true;
	if (argc > 0 && strcmp(argv[0], "help") == 0)
		need_nl = false;
	if (argc > 1 && strcmp(argv[1], "help") == 0)
		need_nl = false;

	if (need_nl) {
		err = dpll_init(dpll);
		if (err) {
			ret = EXIT_FAILURE;
			goto dpll_free;
		}
	}

	err = dpll_cmd(dpll, argc, argv);
	if (err) {
		ret = EXIT_FAILURE;
		goto dpll_fini;
	}

	ret = EXIT_SUCCESS;

dpll_fini:
	if (need_nl)
		dpll_fini(dpll);
	if (dpll->json_output)
		close_json_object();
	delete_json_obj_plain();
dpll_free:
	dpll_free(dpll);
	return ret;
}

/* Device command handlers */

static void cmd_device_help(void)
{
	pr_err("Usage: dpll device show [ id DEVICE_ID ]\n");
	pr_err("       dpll device set id DEVICE_ID [ phase-offset-monitor BOOL ]\n");
	pr_err("                                      [ phase-offset-avg-factor NUM ]\n");
	pr_err("       dpll device id-get [ module-name NAME ] [ clock-id ID ] [ type TYPE ]\n");
}

static const char *dpll_mode_name(__u32 mode)
{
	switch (mode) {
	case DPLL_MODE_MANUAL:
		return "manual";
	case DPLL_MODE_AUTOMATIC:
		return "automatic";
	default:
		return "unknown";
	}
}

static const char *dpll_lock_status_name(__u32 status)
{
	switch (status) {
	case DPLL_LOCK_STATUS_UNLOCKED:
		return "unlocked";
	case DPLL_LOCK_STATUS_LOCKED:
		return "locked";
	case DPLL_LOCK_STATUS_LOCKED_HO_ACQ:
		return "locked-ho-acq";
	case DPLL_LOCK_STATUS_HOLDOVER:
		return "holdover";
	default:
		return "unknown";
	}
}

static const char *dpll_type_name(__u32 type)
{
	switch (type) {
	case DPLL_TYPE_PPS:
		return "pps";
	case DPLL_TYPE_EEC:
		return "eec";
	default:
		return "unknown";
	}
}

static const char *dpll_lock_status_error_name(__u32 error)
{
	switch (error) {
	case DPLL_LOCK_STATUS_ERROR_NONE:
		return "none";
	case DPLL_LOCK_STATUS_ERROR_UNDEFINED:
		return "undefined";
	case DPLL_LOCK_STATUS_ERROR_MEDIA_DOWN:
		return "media-down";
	case DPLL_LOCK_STATUS_ERROR_FRACTIONAL_FREQUENCY_OFFSET_TOO_HIGH:
		return "fractional-frequency-offset-too-high";
	default:
		return "unknown";
	}
}

static const char *dpll_clock_quality_level_name(__u32 level)
{
	switch (level) {
	case DPLL_CLOCK_QUALITY_LEVEL_ITU_OPT1_PRC:
		return "itu-opt1-prc";
	case DPLL_CLOCK_QUALITY_LEVEL_ITU_OPT1_SSU_A:
		return "itu-opt1-ssu-a";
	case DPLL_CLOCK_QUALITY_LEVEL_ITU_OPT1_SSU_B:
		return "itu-opt1-ssu-b";
	case DPLL_CLOCK_QUALITY_LEVEL_ITU_OPT1_EEC1:
		return "itu-opt1-eec1";
	case DPLL_CLOCK_QUALITY_LEVEL_ITU_OPT1_PRTC:
		return "itu-opt1-prtc";
	case DPLL_CLOCK_QUALITY_LEVEL_ITU_OPT1_EPRTC:
		return "itu-opt1-eprtc";
	case DPLL_CLOCK_QUALITY_LEVEL_ITU_OPT1_EEEC:
		return "itu-opt1-eeec";
	case DPLL_CLOCK_QUALITY_LEVEL_ITU_OPT1_EPRC:
		return "itu-opt1-eprc";
	default:
		return "unknown";
	}
}

/* Netlink attribute parsing callbacks */
static int attr_cb(const struct nlattr *attr, void *data)
{
	const struct nlattr **tb = data;
	int type = mnl_attr_get_type(attr);

	if (mnl_attr_type_valid(attr, DPLL_A_MAX) < 0)
		return MNL_CB_OK;

	tb[type] = attr;
	return MNL_CB_OK;
}

static int attr_pin_cb(const struct nlattr *attr, void *data)
{
	const struct nlattr **tb = data;
	int type = mnl_attr_get_type(attr);

	if (mnl_attr_type_valid(attr, DPLL_A_PIN_MAX) < 0)
		return MNL_CB_OK;

	tb[type] = attr;
	return MNL_CB_OK;
}

/* Device printing from netlink attributes */
static void dpll_device_print_attrs(const struct nlmsghdr *nlh, struct nlattr **tb)
{
	DPLL_PR_UINT_FMT(tb, DPLL_A_ID, "id", "device id %u:\n");

	DPLL_PR_STR(tb, DPLL_A_MODULE_NAME, "module-name");

	DPLL_PR_ENUM_STR(tb, DPLL_A_MODE, "mode", dpll_mode_name);

	if (tb[DPLL_A_CLOCK_ID]) {
		if (is_json_context())
			print_u64(PRINT_JSON, "clock-id", NULL,
				  mnl_attr_get_u64(tb[DPLL_A_CLOCK_ID]));
		else
			print_0xhex(PRINT_FP, "clock-id",
				    "  clock-id: 0x%llx\n",
				    mnl_attr_get_u64(tb[DPLL_A_CLOCK_ID]));
	}

	DPLL_PR_ENUM_STR(tb, DPLL_A_TYPE, "type", dpll_type_name);

	DPLL_PR_ENUM_STR(tb, DPLL_A_LOCK_STATUS, "lock-status", dpll_lock_status_name);

	DPLL_PR_ENUM_STR(tb, DPLL_A_LOCK_STATUS_ERROR, "lock-status-error", dpll_lock_status_error_name);

	DPLL_PR_MULTI_ENUM_STR(nlh, DPLL_A_CLOCK_QUALITY_LEVEL, "clock-quality-level",
			       dpll_clock_quality_level_name);

	if (tb[DPLL_A_TEMP]) {
		__s32 temp = mnl_attr_get_u32(tb[DPLL_A_TEMP]);
		if (is_json_context()) {
			print_float(PRINT_JSON, "temperature", NULL,
				    temp / 1000.0);
		} else {
			int temp_int = temp / 1000;
			int temp_frac = abs(temp % 1000);
			pr_out("  temperature: %d.%03d C\n", temp_int, temp_frac);
		}
	}

	DPLL_PR_MULTI_ENUM_STR(nlh, DPLL_A_MODE_SUPPORTED, "mode-supported", dpll_mode_name);

	if (tb[DPLL_A_PHASE_OFFSET_MONITOR]) {
		__u32 value = mnl_attr_get_u32(tb[DPLL_A_PHASE_OFFSET_MONITOR]);
		print_string(PRINT_ANY, "phase-offset-monitor",
			     "  phase-offset-monitor: %s\n",
			     value ? "enable" : "disable");
	}

	DPLL_PR_UINT(tb, DPLL_A_PHASE_OFFSET_AVG_FACTOR, "phase-offset-avg-factor");
}

/* Callback for device get (single) */
static int cmd_device_show_cb(const struct nlmsghdr *nlh, void *data)
{
	struct nlattr *tb[DPLL_A_MAX + 1] = {};
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);

	mnl_attr_parse(nlh, sizeof(*genl), attr_cb, tb);
	dpll_device_print_attrs(nlh, tb);

	return MNL_CB_OK;
}

/* Callback for device dump (multiple) - wraps each device in object */
static int cmd_device_show_dump_cb(const struct nlmsghdr *nlh, void *data)
{
	struct nlattr *tb[DPLL_A_MAX + 1] = {};
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);

	mnl_attr_parse(nlh, sizeof(*genl), attr_cb, tb);

	open_json_object(NULL);
	dpll_device_print_attrs(nlh, tb);
	close_json_object();

	return MNL_CB_OK;
}

static int cmd_device_show_id(struct dpll *dpll, __u32 id)
{
	struct nlmsghdr *nlh;
	int err;

	nlh = mnlu_gen_socket_cmd_prepare(&dpll->nlg, DPLL_CMD_DEVICE_GET,
					   NLM_F_REQUEST | NLM_F_ACK);
	mnl_attr_put_u32(nlh, DPLL_A_ID, id);

	err = mnlu_gen_socket_sndrcv(&dpll->nlg, nlh, cmd_device_show_cb, NULL);
	if (err < 0) {
		pr_err("Failed to get device %u\n", id);
		return -1;
	}

	return 0;
}

static int cmd_device_show_dump(struct dpll *dpll)
{
	struct nlmsghdr *nlh;
	int err;

	nlh = mnlu_gen_socket_cmd_prepare(&dpll->nlg, DPLL_CMD_DEVICE_GET,
					   NLM_F_REQUEST | NLM_F_ACK | NLM_F_DUMP);

	/* Open JSON array for multiple devices */
	open_json_array(PRINT_JSON, "device");

	err = mnlu_gen_socket_sndrcv(&dpll->nlg, nlh, cmd_device_show_dump_cb, NULL);
	if (err < 0) {
		pr_err("Failed to dump devices\n");
		close_json_array(PRINT_JSON, NULL);
		return -1;
	}

	/* Close JSON array */
	close_json_array(PRINT_JSON, NULL);

	return 0;
}

static int cmd_device_show(struct dpll *dpll)
{
	__u32 id = 0;
	bool has_id = false;

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "id")) {
			DPLL_PARSE_U32(dpll, "id", &id);
			has_id = true;
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			return -EINVAL;
		}
	}

	if (has_id)
		return cmd_device_show_id(dpll, id);
	else
		return cmd_device_show_dump(dpll);
}

static int cmd_device_set(struct dpll *dpll)
{
	struct nlmsghdr *nlh;
	__u32 id = 0;
	bool has_id = false;
	int err;

	nlh = mnlu_gen_socket_cmd_prepare(&dpll->nlg, DPLL_CMD_DEVICE_SET,
					   NLM_F_REQUEST | NLM_F_ACK);

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "id")) {
			DPLL_PARSE_U32(dpll, "id", &id);
			mnl_attr_put_u32(nlh, DPLL_A_ID, id);
			has_id = true;
		} else if (dpll_argv_match(dpll, "phase-offset-monitor")) {
			char *str = dpll_argv_next(dpll);

			if (!str) {
				pr_err("phase-offset-monitor requires an argument\n");
				return -EINVAL;
			}
			if (strcmp(str, "true") == 0 || strcmp(str, "1") == 0) {
				mnl_attr_put_u32(nlh, DPLL_A_PHASE_OFFSET_MONITOR, 1);
			} else if (strcmp(str, "false") == 0 || strcmp(str, "0") == 0) {
				mnl_attr_put_u32(nlh, DPLL_A_PHASE_OFFSET_MONITOR, 0);
			} else {
				pr_err("invalid phase-offset-monitor value: %s (use true/false)\n", str);
				return -EINVAL;
			}
		} else if (dpll_argv_match(dpll, "phase-offset-avg-factor")) {
			DPLL_PARSE_ATTR_U32(dpll, nlh, "phase-offset-avg-factor",
					    DPLL_A_PHASE_OFFSET_AVG_FACTOR);
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			return -EINVAL;
		}
	}

	if (!has_id) {
		pr_err("device id is required\n");
		return -EINVAL;
	}

	err = mnlu_gen_socket_sndrcv(&dpll->nlg, nlh, NULL, NULL);
	if (err < 0) {
		pr_err("Failed to set device\n");
		return -1;
	}

	return 0;
}

static int cmd_device_id_get_cb(const struct nlmsghdr *nlh, void *data)
{
	struct nlattr *tb[DPLL_A_MAX + 1] = {};
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);

	mnl_attr_parse(nlh, sizeof(*genl), attr_cb, tb);

	if (tb[DPLL_A_ID]) {
		__u32 id = mnl_attr_get_u32(tb[DPLL_A_ID]);
		if (is_json_context()) {
			open_json_object(NULL);
			print_uint(PRINT_JSON, "id", NULL, id);
			close_json_object();
		} else {
			printf("%u\n", id);
		}
	}

	return MNL_CB_OK;
}

static int cmd_device_id_get(struct dpll *dpll)
{
	struct nlmsghdr *nlh;
	int err;

	nlh = mnlu_gen_socket_cmd_prepare(&dpll->nlg, DPLL_CMD_DEVICE_ID_GET,
					   NLM_F_REQUEST | NLM_F_ACK);

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "module-name")) {
			DPLL_PARSE_ATTR_STR(dpll, nlh, "module-name", DPLL_A_MODULE_NAME);
		} else if (dpll_argv_match(dpll, "clock-id")) {
			DPLL_PARSE_ATTR_U64(dpll, nlh, "clock-id", DPLL_A_CLOCK_ID);
		} else if (dpll_argv_match(dpll, "type")) {
			char *str = dpll_argv_next(dpll);

			if (!str) {
				pr_err("type requires an argument\n");
				return -EINVAL;
			}
			if (strcmp(str, "pps") == 0) {
				mnl_attr_put_u32(nlh, DPLL_A_TYPE, DPLL_TYPE_PPS);
			} else if (strcmp(str, "eec") == 0) {
				mnl_attr_put_u32(nlh, DPLL_A_TYPE, DPLL_TYPE_EEC);
			} else {
				pr_err("invalid type: %s (use pps/eec)\n", str);
				return -EINVAL;
			}
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			return -EINVAL;
		}
	}

	err = mnlu_gen_socket_sndrcv(&dpll->nlg, nlh, cmd_device_id_get_cb, NULL);
	if (err < 0) {
		pr_err("Failed to get device id\n");
		return -1;
	}

	return 0;
}

static int cmd_device(struct dpll *dpll)
{
	if (dpll_argv_match(dpll, "help") || dpll_no_arg(dpll)) {
		cmd_device_help();
		return 0;
	} else if (dpll_argv_match_inc(dpll, "show")) {
		return cmd_device_show(dpll);
	} else if (dpll_argv_match_inc(dpll, "set")) {
		return cmd_device_set(dpll);
	} else if (dpll_argv_match_inc(dpll, "id-get")) {
		return cmd_device_id_get(dpll);
	}

	pr_err("Command \"%s\" not found\n", dpll_argv(dpll) ? dpll_argv(dpll) : "");
	return -ENOENT;
}

/* Pin command handlers */

static void cmd_pin_help(void)
{
	pr_err("Usage: dpll pin show [ id PIN_ID ] [ device DEVICE_ID ]\n");
	pr_err("       dpll pin set id PIN_ID [ frequency FREQ ]\n");
	pr_err("                              [ phase-adjust ADJUST ]\n");
	pr_err("                              [ esync-frequency FREQ ]\n");
	pr_err("                              [ parent-device DEVICE_ID [ direction DIR ]\n");
	pr_err("                                                        [ prio PRIO ]\n");
	pr_err("                                                        [ state STATE ] ]\n");
	pr_err("                              [ parent-pin PIN_ID [ state STATE ] ]\n");
	pr_err("                              [ reference-sync PIN_ID [ state STATE ] ]\n");
	pr_err("       dpll pin id-get [ module-name NAME ] [ clock-id ID ]\n");
	pr_err("                       [ board-label LABEL ] [ panel-label LABEL ]\n");
	pr_err("                       [ package-label LABEL ] [ type TYPE ]\n");
}

static const char *dpll_pin_type_name(__u32 type)
{
	switch (type) {
	case DPLL_PIN_TYPE_MUX:
		return "mux";
	case DPLL_PIN_TYPE_EXT:
		return "ext";
	case DPLL_PIN_TYPE_SYNCE_ETH_PORT:
		return "synce-eth-port";
	case DPLL_PIN_TYPE_INT_OSCILLATOR:
		return "int-oscillator";
	case DPLL_PIN_TYPE_GNSS:
		return "gnss";
	default:
		return "unknown";
	}
}

static const char *dpll_pin_state_name(__u32 state)
{
	switch (state) {
	case DPLL_PIN_STATE_CONNECTED:
		return "connected";
	case DPLL_PIN_STATE_DISCONNECTED:
		return "disconnected";
	case DPLL_PIN_STATE_SELECTABLE:
		return "selectable";
	default:
		return "unknown";
	}
}

static const char *dpll_pin_direction_name(__u32 direction)
{
	switch (direction) {
	case DPLL_PIN_DIRECTION_INPUT:
		return "input";
	case DPLL_PIN_DIRECTION_OUTPUT:
		return "output";
	default:
		return "unknown";
	}
}

static void dpll_pin_capabilities_name(__u32 capabilities)
{
	if (capabilities & DPLL_PIN_CAPABILITIES_STATE_CAN_CHANGE)
		pr_out(" state-can-change");
	if (capabilities & DPLL_PIN_CAPABILITIES_PRIORITY_CAN_CHANGE)
		pr_out(" priority-can-change");
	if (capabilities & DPLL_PIN_CAPABILITIES_DIRECTION_CAN_CHANGE)
		pr_out(" direction-can-change");
}

/* Helper structures for multi-attr collection */
struct multi_attr_ctx {
	int count;
	struct nlattr **entries;  /* dynamically allocated */
};

/* Pin printing from netlink attributes */
static void dpll_pin_print_attrs(struct nlattr **tb)
{
	DPLL_PR_UINT_FMT(tb, DPLL_A_PIN_ID, "id", "pin id %u:\n");

	DPLL_PR_STR(tb, DPLL_A_PIN_MODULE_NAME, "module-name");

	if (tb[DPLL_A_PIN_CLOCK_ID]) {
		if (is_json_context())
			print_u64(PRINT_JSON, "clock-id", NULL,
				  mnl_attr_get_u64(tb[DPLL_A_PIN_CLOCK_ID]));
		else
			print_0xhex(PRINT_FP, "clock-id",
				    "  clock-id: 0x%llx\n",
				    mnl_attr_get_u64(tb[DPLL_A_PIN_CLOCK_ID]));
	}

	DPLL_PR_STR(tb, DPLL_A_PIN_BOARD_LABEL, "board-label");
	DPLL_PR_STR(tb, DPLL_A_PIN_PANEL_LABEL, "panel-label");
	DPLL_PR_STR(tb, DPLL_A_PIN_PACKAGE_LABEL, "package-label");

	DPLL_PR_ENUM_STR(tb, DPLL_A_PIN_TYPE, "type", dpll_pin_type_name);

	DPLL_PR_U64_FMT(tb, DPLL_A_PIN_FREQUENCY, "frequency",
			"  frequency: %llu Hz\n");

	/* Print frequency-supported ranges */
	if (tb[DPLL_A_PIN_FREQUENCY_SUPPORTED]) {
		struct multi_attr_ctx *ctx = (struct multi_attr_ctx *)tb[DPLL_A_PIN_FREQUENCY_SUPPORTED];
		int i;

		open_json_array(PRINT_JSON, "frequency-supported");
		if (!is_json_context())
			pr_out("  frequency-supported:\n");

		/* Iterate through all collected frequency-supported entries */
		for (i = 0; i < ctx->count; i++) {
			struct nlattr *tb_freq[DPLL_A_PIN_MAX + 1] = {};
			__u64 freq_min = 0, freq_max = 0;

			mnl_attr_parse_nested(ctx->entries[i], attr_pin_cb, tb_freq);

			if (tb_freq[DPLL_A_PIN_FREQUENCY_MIN])
				freq_min = mnl_attr_get_u64(tb_freq[DPLL_A_PIN_FREQUENCY_MIN]);
			if (tb_freq[DPLL_A_PIN_FREQUENCY_MAX])
				freq_max = mnl_attr_get_u64(tb_freq[DPLL_A_PIN_FREQUENCY_MAX]);

			open_json_object(NULL);

			/* JSON: always print both min and max */
			if (is_json_context()) {
				if (tb_freq[DPLL_A_PIN_FREQUENCY_MIN])
					print_lluint(PRINT_JSON, "frequency-min", NULL, freq_min);
				if (tb_freq[DPLL_A_PIN_FREQUENCY_MAX])
					print_lluint(PRINT_JSON, "frequency-max", NULL, freq_max);
			} else {
				/* Legacy: if min == max, print single value, else print range */
				pr_out("    ");
				if (freq_min == freq_max) {
					print_lluint(PRINT_FP, NULL, "%llu Hz\n", freq_min);
				} else {
					print_lluint(PRINT_FP, NULL, "%llu", freq_min);
					pr_out("-");
					print_lluint(PRINT_FP, NULL, "%llu Hz\n", freq_max);
				}
			}

			close_json_object();
		}
		close_json_array(PRINT_JSON, NULL);
	}

	/* Print capabilities */
	if (tb[DPLL_A_PIN_CAPABILITIES]) {
		__u32 caps = mnl_attr_get_u32(tb[DPLL_A_PIN_CAPABILITIES]);
		if (is_json_context()) {
			open_json_array(PRINT_JSON, "capabilities");
			if (caps & DPLL_PIN_CAPABILITIES_STATE_CAN_CHANGE)
				print_string(PRINT_JSON, NULL, NULL, "state-can-change");
			if (caps & DPLL_PIN_CAPABILITIES_PRIORITY_CAN_CHANGE)
				print_string(PRINT_JSON, NULL, NULL, "priority-can-change");
			if (caps & DPLL_PIN_CAPABILITIES_DIRECTION_CAN_CHANGE)
				print_string(PRINT_JSON, NULL, NULL, "direction-can-change");
			close_json_array(PRINT_JSON, NULL);
		} else {
			pr_out("  capabilities: 0x%x", caps);
			dpll_pin_capabilities_name(caps);
			pr_out("\n");
		}
	}

	/* Print phase adjust range, granularity and current value */
	DPLL_PR_INT(tb, DPLL_A_PIN_PHASE_ADJUST_MIN, "phase-adjust-min");
	DPLL_PR_INT(tb, DPLL_A_PIN_PHASE_ADJUST_MAX, "phase-adjust-max");
	DPLL_PR_INT(tb, DPLL_A_PIN_PHASE_ADJUST_GRAN, "phase-adjust-gran");
	DPLL_PR_INT(tb, DPLL_A_PIN_PHASE_ADJUST, "phase-adjust");

	/* Print fractional frequency offset */
	DPLL_PR_SINT(tb, DPLL_A_PIN_FRACTIONAL_FREQUENCY_OFFSET, "fractional-frequency-offset");

	/* Print esync frequency and related attributes */
	DPLL_PR_U64_FMT(tb, DPLL_A_PIN_ESYNC_FREQUENCY, "esync_frequency",
			"  esync-frequency: %llu Hz\n");

	if (tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED]) {
		struct multi_attr_ctx *ctx = (struct multi_attr_ctx *)tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED];
		int i;

		open_json_array(PRINT_JSON, "esync-frequency-supported");
		if (!is_json_context())
			pr_out("  esync-frequency-supported:\n");

		/* Iterate through all collected esync-frequency-supported entries */
		for (i = 0; i < ctx->count; i++) {
			struct nlattr *tb_freq[DPLL_A_PIN_MAX + 1] = {};
			__u64 freq_min = 0, freq_max = 0;

			mnl_attr_parse_nested(ctx->entries[i], attr_pin_cb, tb_freq);

			if (tb_freq[DPLL_A_PIN_FREQUENCY_MIN])
				freq_min = mnl_attr_get_u64(tb_freq[DPLL_A_PIN_FREQUENCY_MIN]);
			if (tb_freq[DPLL_A_PIN_FREQUENCY_MAX])
				freq_max = mnl_attr_get_u64(tb_freq[DPLL_A_PIN_FREQUENCY_MAX]);

			open_json_object(NULL);

			/* JSON: always print both min and max */
			if (is_json_context()) {
				if (tb_freq[DPLL_A_PIN_FREQUENCY_MIN])
					print_lluint(PRINT_JSON, "frequency-min", NULL, freq_min);
				if (tb_freq[DPLL_A_PIN_FREQUENCY_MAX])
					print_lluint(PRINT_JSON, "frequency-max", NULL, freq_max);
			} else {
				/* Legacy: if min == max, print single value, else print range */
				pr_out("    ");
				if (freq_min == freq_max) {
					print_lluint(PRINT_FP, NULL, "%llu Hz\n", freq_min);
				} else {
					print_lluint(PRINT_FP, NULL, "%llu", freq_min);
					pr_out("-");
					print_lluint(PRINT_FP, NULL, "%llu Hz\n", freq_max);
				}
			}

			close_json_object();
		}
		close_json_array(PRINT_JSON, NULL);
	}

	DPLL_PR_UINT_FMT(tb, DPLL_A_PIN_ESYNC_PULSE, "esync_pulse",
			 "  esync-pulse: %u\n");

	/* Print parent-device relationships */
	if (tb[DPLL_A_PIN_PARENT_DEVICE]) {
		struct multi_attr_ctx *ctx = (struct multi_attr_ctx *)tb[DPLL_A_PIN_PARENT_DEVICE];
		int i;

		open_json_array(PRINT_JSON, "parent-device");
		if (!is_json_context())
			pr_out("  parent-device:\n");

		/* Iterate through all collected parent-device entries */
		for (i = 0; i < ctx->count; i++) {
			struct nlattr *tb_parent[DPLL_A_PIN_MAX + 1] = {};
			mnl_attr_parse_nested(ctx->entries[i], attr_pin_cb, tb_parent);

			open_json_object(NULL);
			if (!is_json_context())
				pr_out("    ");

			DPLL_PR_UINT_FMT(tb_parent, DPLL_A_PIN_PARENT_ID, "parent-id",
					 "id %u");
			DPLL_PR_ENUM_STR_FMT(tb_parent, DPLL_A_PIN_DIRECTION, "direction",
					     " direction %s", dpll_pin_direction_name);
			DPLL_PR_UINT_FMT(tb_parent, DPLL_A_PIN_PRIO, "prio",
					 " prio %u");
			DPLL_PR_ENUM_STR_FMT(tb_parent, DPLL_A_PIN_STATE, "state",
					     " state %s", dpll_pin_state_name);
			if (tb_parent[DPLL_A_PIN_PHASE_OFFSET]) {
				struct nlattr *attr = tb_parent[DPLL_A_PIN_PHASE_OFFSET];
				__s64 phase_offset;

				memcpy(&phase_offset, mnl_attr_get_payload(attr), sizeof(__s64));
				print_s64(PRINT_ANY, "phase-offset",
					     " phase-offset %lld",
					     phase_offset);
			}

			if (!is_json_context())
				pr_out("\n");
			close_json_object();
		}
		close_json_array(PRINT_JSON, NULL);
	}

	/* Print parent-pin relationships */
	if (tb[DPLL_A_PIN_PARENT_PIN]) {
		struct multi_attr_ctx *ctx = (struct multi_attr_ctx *)tb[DPLL_A_PIN_PARENT_PIN];
		int i;

		open_json_array(PRINT_JSON, "parent-pin");
		if (!is_json_context())
			pr_out("  parent-pin:\n");

		for (i = 0; i < ctx->count; i++) {
			struct nlattr *tb_parent[DPLL_A_PIN_MAX + 1] = {};
			mnl_attr_parse_nested(ctx->entries[i], attr_pin_cb, tb_parent);

			open_json_object(NULL);
			if (!is_json_context())
				pr_out("    ");

			DPLL_PR_UINT_FMT(tb_parent, DPLL_A_PIN_PARENT_ID, "parent-id",
					 "id %u");
			DPLL_PR_ENUM_STR_FMT(tb_parent, DPLL_A_PIN_STATE, "state",
					     " state %s", dpll_pin_state_name);

			if (!is_json_context())
				pr_out("\n");
			close_json_object();
		}
		close_json_array(PRINT_JSON, NULL);
	}

	/* Print reference-sync capable pins */
	if (tb[DPLL_A_PIN_REFERENCE_SYNC]) {
		struct multi_attr_ctx *ctx = (struct multi_attr_ctx *)tb[DPLL_A_PIN_REFERENCE_SYNC];
		int i;

		open_json_array(PRINT_JSON, "reference-sync");
		if (!is_json_context())
			pr_out("  reference-sync:\n");

		for (i = 0; i < ctx->count; i++) {
			struct nlattr *tb_ref[DPLL_A_PIN_MAX + 1] = {};
			mnl_attr_parse_nested(ctx->entries[i], attr_pin_cb, tb_ref);

			open_json_object(NULL);
			if (!is_json_context())
				pr_out("    ");

			DPLL_PR_UINT_FMT(tb_ref, DPLL_A_PIN_ID, "id",
					 "pin %u");
			DPLL_PR_ENUM_STR_FMT(tb_ref, DPLL_A_PIN_STATE, "state",
					     " state %s", dpll_pin_state_name);

			if (!is_json_context())
				pr_out("\n");
			close_json_object();
		}
		close_json_array(PRINT_JSON, NULL);
	}
}

/* Count how many times a specific attribute type appears */
static int count_multi_attr_cb(const struct nlattr *attr, void *data)
{
	struct multi_attr_collector {
		int attr_type;
		int *count;
	} *collector = data;
	int type = mnl_attr_get_type(attr);

	if (type == collector->attr_type)
		(*collector->count)++;
	return MNL_CB_OK;
}

/* Helper to count specific multi-attr type occurrences */
static unsigned int multi_attr_count_get(const struct nlmsghdr *nlh,
					  struct genlmsghdr *genl,
					  int attr_type)
{
	struct {
		int attr_type;
		int *count;
	} collector;
	int count = 0;

	collector.attr_type = attr_type;
	collector.count = &count;
	mnl_attr_parse(nlh, sizeof(*genl), count_multi_attr_cb, &collector);
	return count;
}

/* Initialize multi-attr context with proper allocation */
static int multi_attr_ctx_init(struct multi_attr_ctx *ctx, unsigned int count)
{
	if (count == 0) {
		ctx->count = 0;
		ctx->entries = NULL;
		return 0;
	}

	ctx->entries = calloc(count, sizeof(struct nlattr *));
	if (!ctx->entries)
		return -ENOMEM;
	ctx->count = 0;
	return 0;
}

/* Free multi-attr context */
static void multi_attr_ctx_free(struct multi_attr_ctx *ctx)
{
	free(ctx->entries);
	ctx->entries = NULL;
	ctx->count = 0;
}

/* Generic helper to collect specific multi-attr type */
struct multi_attr_collector {
	int attr_type;
	struct multi_attr_ctx *ctx;
};

static int collect_multi_attr_cb(const struct nlattr *attr, void *data)
{
	struct multi_attr_collector *collector = data;
	int type = mnl_attr_get_type(attr);

	if (type == collector->attr_type) {
		collector->ctx->entries[collector->ctx->count++] = (struct nlattr *)attr;
	}
	return MNL_CB_OK;
}

/* Callback for pin get (single) */
static int cmd_pin_show_cb(const struct nlmsghdr *nlh, void *data)
{
	struct nlattr *tb[DPLL_A_PIN_MAX + 1] = {};
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);
	struct multi_attr_ctx parent_dev_ctx = {0}, parent_pin_ctx = {0}, ref_sync_ctx = {0};
	struct multi_attr_ctx freq_supp_ctx = {0}, esync_freq_supp_ctx = {0};
	struct multi_attr_collector collector;
	unsigned int count;
	int ret = MNL_CB_OK;

	/* First parse to get main attributes */
	mnl_attr_parse(nlh, sizeof(*genl), attr_pin_cb, tb);

	/* Pass 1: Count multi-attr occurrences and allocate */
	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_PARENT_DEVICE);
	if (count > 0 && multi_attr_ctx_init(&parent_dev_ctx, count) < 0)
		goto err_alloc;

	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_PARENT_PIN);
	if (count > 0 && multi_attr_ctx_init(&parent_pin_ctx, count) < 0)
		goto err_alloc;

	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_REFERENCE_SYNC);
	if (count > 0 && multi_attr_ctx_init(&ref_sync_ctx, count) < 0)
		goto err_alloc;

	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_FREQUENCY_SUPPORTED);
	if (count > 0 && multi_attr_ctx_init(&freq_supp_ctx, count) < 0)
		goto err_alloc;

	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED);
	if (count > 0 && multi_attr_ctx_init(&esync_freq_supp_ctx, count) < 0)
		goto err_alloc;

	/* Pass 2: Collect multi-attr entries */
	if (parent_dev_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_PARENT_DEVICE;
		collector.ctx = &parent_dev_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	if (parent_pin_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_PARENT_PIN;
		collector.ctx = &parent_pin_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	if (ref_sync_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_REFERENCE_SYNC;
		collector.ctx = &ref_sync_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	if (freq_supp_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_FREQUENCY_SUPPORTED;
		collector.ctx = &freq_supp_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	if (esync_freq_supp_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED;
		collector.ctx = &esync_freq_supp_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	/* Replace tb entries with contexts */
	tb[DPLL_A_PIN_PARENT_DEVICE] = parent_dev_ctx.count > 0 ?
		(struct nlattr *)&parent_dev_ctx : NULL;
	tb[DPLL_A_PIN_PARENT_PIN] = parent_pin_ctx.count > 0 ?
		(struct nlattr *)&parent_pin_ctx : NULL;
	tb[DPLL_A_PIN_REFERENCE_SYNC] = ref_sync_ctx.count > 0 ?
		(struct nlattr *)&ref_sync_ctx : NULL;
	tb[DPLL_A_PIN_FREQUENCY_SUPPORTED] = freq_supp_ctx.count > 0 ?
		(struct nlattr *)&freq_supp_ctx : NULL;
	tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED] =
		esync_freq_supp_ctx.count > 0 ?
		(struct nlattr *)&esync_freq_supp_ctx : NULL;

	dpll_pin_print_attrs(tb);

	goto cleanup;

err_alloc:
	fprintf(stderr, "Failed to allocate memory for multi-attr collection\n");
	ret = MNL_CB_ERROR;

cleanup:
	/* Free allocated memory */
	multi_attr_ctx_free(&parent_dev_ctx);
	multi_attr_ctx_free(&parent_pin_ctx);
	multi_attr_ctx_free(&ref_sync_ctx);
	multi_attr_ctx_free(&freq_supp_ctx);
	multi_attr_ctx_free(&esync_freq_supp_ctx);

	return ret;
}

/* Callback for pin dump (multiple) - wraps each pin in object */
static int cmd_pin_show_dump_cb(const struct nlmsghdr *nlh, void *data)
{
	struct nlattr *tb[DPLL_A_PIN_MAX + 1] = {};
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);
	struct multi_attr_ctx parent_dev_ctx = {0}, parent_pin_ctx = {0}, ref_sync_ctx = {0};
	struct multi_attr_ctx freq_supp_ctx = {0}, esync_freq_supp_ctx = {0};
	struct multi_attr_collector collector;
	unsigned int count;
	int ret = MNL_CB_OK;

	/* First parse to get main attributes */
	mnl_attr_parse(nlh, sizeof(*genl), attr_pin_cb, tb);

	/* Pass 1: Count multi-attr occurrences and allocate */
	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_PARENT_DEVICE);
	if (count > 0 && multi_attr_ctx_init(&parent_dev_ctx, count) < 0)
		goto err_alloc;

	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_PARENT_PIN);
	if (count > 0 && multi_attr_ctx_init(&parent_pin_ctx, count) < 0)
		goto err_alloc;

	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_REFERENCE_SYNC);
	if (count > 0 && multi_attr_ctx_init(&ref_sync_ctx, count) < 0)
		goto err_alloc;

	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_FREQUENCY_SUPPORTED);
	if (count > 0 && multi_attr_ctx_init(&freq_supp_ctx, count) < 0)
		goto err_alloc;

	count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED);
	if (count > 0 && multi_attr_ctx_init(&esync_freq_supp_ctx, count) < 0)
		goto err_alloc;

	/* Pass 2: Collect multi-attr entries */
	if (parent_dev_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_PARENT_DEVICE;
		collector.ctx = &parent_dev_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	if (parent_pin_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_PARENT_PIN;
		collector.ctx = &parent_pin_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	if (ref_sync_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_REFERENCE_SYNC;
		collector.ctx = &ref_sync_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	if (freq_supp_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_FREQUENCY_SUPPORTED;
		collector.ctx = &freq_supp_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	if (esync_freq_supp_ctx.entries) {
		collector.attr_type = DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED;
		collector.ctx = &esync_freq_supp_ctx;
		mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
	}

	/* Replace tb entries with contexts */
	tb[DPLL_A_PIN_PARENT_DEVICE] = parent_dev_ctx.count > 0 ?
		(struct nlattr *)&parent_dev_ctx : NULL;
	tb[DPLL_A_PIN_PARENT_PIN] = parent_pin_ctx.count > 0 ?
		(struct nlattr *)&parent_pin_ctx : NULL;
	tb[DPLL_A_PIN_REFERENCE_SYNC] = ref_sync_ctx.count > 0 ?
		(struct nlattr *)&ref_sync_ctx : NULL;
	tb[DPLL_A_PIN_FREQUENCY_SUPPORTED] = freq_supp_ctx.count > 0 ?
		(struct nlattr *)&freq_supp_ctx : NULL;
	tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED] =
		esync_freq_supp_ctx.count > 0 ?
		(struct nlattr *)&esync_freq_supp_ctx : NULL;

	open_json_object(NULL);
	dpll_pin_print_attrs(tb);
	close_json_object();

	goto cleanup;

err_alloc:
	fprintf(stderr, "Failed to allocate memory for multi-attr collection\n");
	ret = MNL_CB_ERROR;

cleanup:
	/* Free allocated memory */
	multi_attr_ctx_free(&parent_dev_ctx);
	multi_attr_ctx_free(&parent_pin_ctx);
	multi_attr_ctx_free(&ref_sync_ctx);
	multi_attr_ctx_free(&freq_supp_ctx);
	multi_attr_ctx_free(&esync_freq_supp_ctx);

	return ret;
}

static int cmd_pin_show_id(struct dpll *dpll, __u32 id)
{
	struct nlmsghdr *nlh;
	int err;

	nlh = mnlu_gen_socket_cmd_prepare(&dpll->nlg, DPLL_CMD_PIN_GET,
					   NLM_F_REQUEST | NLM_F_ACK);
	mnl_attr_put_u32(nlh, DPLL_A_PIN_ID, id);

	err = mnlu_gen_socket_sndrcv(&dpll->nlg, nlh, cmd_pin_show_cb, NULL);
	if (err < 0) {
		pr_err("Failed to get pin %u\n", id);
		return -1;
	}

	return 0;
}

static int cmd_pin_show_dump(struct dpll *dpll, bool has_device_id, __u32 device_id)
{
	struct nlmsghdr *nlh;
	int err;

	nlh = mnlu_gen_socket_cmd_prepare(&dpll->nlg, DPLL_CMD_PIN_GET,
					   NLM_F_REQUEST | NLM_F_ACK | NLM_F_DUMP);

	/* If device_id specified, filter pins by device */
	if (has_device_id)
		mnl_attr_put_u32(nlh, DPLL_A_ID, device_id);

	/* Open JSON array for multiple pins */
	open_json_array(PRINT_JSON, "pin");

	err = mnlu_gen_socket_sndrcv(&dpll->nlg, nlh, cmd_pin_show_dump_cb, NULL);
	if (err < 0) {
		pr_err("Failed to dump pins\n");
		close_json_array(PRINT_JSON, NULL);
		return -1;
	}

	/* Close JSON array */
	close_json_array(PRINT_JSON, NULL);

	return 0;
}

static int cmd_pin_show(struct dpll *dpll)
{
	__u32 pin_id = 0, device_id = 0;
	bool has_pin_id = false, has_device_id = false;

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "id")) {
			DPLL_PARSE_U32(dpll, "id", &pin_id);
			has_pin_id = true;
		} else if (dpll_argv_match(dpll, "device")) {
			DPLL_PARSE_U32(dpll, "device", &device_id);
			has_device_id = true;
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			return -EINVAL;
		}
	}

	/* If pin id specified, get that specific pin */
	if (has_pin_id)
		return cmd_pin_show_id(dpll, pin_id);
	else
		return cmd_pin_show_dump(dpll, has_device_id, device_id);
}

static int cmd_pin_set(struct dpll *dpll)
{
	struct nlmsghdr *nlh;
	__u32 id = 0;
	bool has_id = false;
	int err;

	nlh = mnlu_gen_socket_cmd_prepare(&dpll->nlg, DPLL_CMD_PIN_SET,
					   NLM_F_REQUEST | NLM_F_ACK);

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "id")) {
			DPLL_PARSE_U32(dpll, "id", &id);
			mnl_attr_put_u32(nlh, DPLL_A_PIN_ID, id);
			has_id = true;
		} else if (dpll_argv_match(dpll, "frequency")) {
			DPLL_PARSE_ATTR_U64(dpll, nlh, "frequency", DPLL_A_PIN_FREQUENCY);
		} else if (dpll_argv_match(dpll, "phase-adjust")) {
			DPLL_PARSE_ATTR_S32(dpll, nlh, "phase-adjust", DPLL_A_PIN_PHASE_ADJUST);
		} else if (dpll_argv_match(dpll, "esync-frequency")) {
			DPLL_PARSE_ATTR_U64(dpll, nlh, "esync-frequency", DPLL_A_PIN_ESYNC_FREQUENCY);
		} else if (dpll_argv_match(dpll, "parent-device")) {
			struct nlattr *nest;
			__u32 parent_id;

			dpll_arg_inc(dpll);
			if (dpll_arg_required(dpll, "parent-device"))
				return -EINVAL;

			/* Parse parent device id */
			if (get_u32(&parent_id, dpll_argv(dpll), 0)) {
				pr_err("invalid parent-device id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			dpll_arg_inc(dpll);

			/* Create nested attribute for parent device */
			nest = mnl_attr_nest_start(nlh, DPLL_A_PIN_PARENT_DEVICE);
			mnl_attr_put_u32(nlh, DPLL_A_PIN_PARENT_ID, parent_id);

			/* Parse optional parent-device attributes */
			while (dpll_argc(dpll) > 0) {
				if (dpll_argv_match(dpll, "direction")) {
					DPLL_PARSE_ATTR_ENUM(dpll, nlh, "direction",
							     DPLL_A_PIN_DIRECTION,
							     dpll_parse_direction);
				} else if (dpll_argv_match(dpll, "prio")) {
					DPLL_PARSE_ATTR_U32(dpll, nlh, "prio", DPLL_A_PIN_PRIO);
				} else if (dpll_argv_match(dpll, "state")) {
					DPLL_PARSE_ATTR_ENUM(dpll, nlh, "state",
							     DPLL_A_PIN_STATE,
							     dpll_parse_state);
				} else {
					/* Not a parent-device attribute, break to parse next option */
					break;
				}
			}

			mnl_attr_nest_end(nlh, nest);
		} else if (dpll_argv_match(dpll, "parent-pin")) {
			struct nlattr *nest;
			__u32 parent_id;

			dpll_arg_inc(dpll);
			if (dpll_arg_required(dpll, "parent-pin"))
				return -EINVAL;

			/* Parse parent pin id */
			if (get_u32(&parent_id, dpll_argv(dpll), 0)) {
				pr_err("invalid parent-pin id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			dpll_arg_inc(dpll);

			/* Create nested attribute for parent pin */
			nest = mnl_attr_nest_start(nlh, DPLL_A_PIN_PARENT_PIN);
			mnl_attr_put_u32(nlh, DPLL_A_PIN_PARENT_ID, parent_id);

			/* Parse optional parent-pin state */
			if (dpll_argc(dpll) > 0 && dpll_argv_match(dpll, "state")) {
				DPLL_PARSE_ATTR_ENUM(dpll, nlh, "state",
						     DPLL_A_PIN_STATE,
						     dpll_parse_state);
			}

			mnl_attr_nest_end(nlh, nest);
		} else if (dpll_argv_match(dpll, "reference-sync")) {
			struct nlattr *nest;
			__u32 ref_pin_id;

			dpll_arg_inc(dpll);
			if (dpll_arg_required(dpll, "reference-sync"))
				return -EINVAL;

			/* Parse reference-sync pin id */
			if (get_u32(&ref_pin_id, dpll_argv(dpll), 0)) {
				pr_err("invalid reference-sync pin id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			dpll_arg_inc(dpll);

			/* Create nested attribute for reference-sync */
			nest = mnl_attr_nest_start(nlh, DPLL_A_PIN_REFERENCE_SYNC);
			mnl_attr_put_u32(nlh, DPLL_A_PIN_ID, ref_pin_id);

			/* Parse optional reference-sync state */
			if (dpll_argc(dpll) > 0 && dpll_argv_match(dpll, "state")) {
				DPLL_PARSE_ATTR_ENUM(dpll, nlh, "state",
						     DPLL_A_PIN_STATE,
						     dpll_parse_state);
			}

			mnl_attr_nest_end(nlh, nest);
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			return -EINVAL;
		}
	}

	if (!has_id) {
		pr_err("pin id is required\n");
		return -EINVAL;
	}

	err = mnlu_gen_socket_sndrcv(&dpll->nlg, nlh, NULL, NULL);
	if (err < 0) {
		pr_err("Failed to set pin\n");
		return -1;
	}

	return 0;
}

static int cmd_pin_id_get_cb(const struct nlmsghdr *nlh, void *data)
{
	struct nlattr *tb[DPLL_A_PIN_MAX + 1] = {};
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);

	mnl_attr_parse(nlh, sizeof(*genl), attr_pin_cb, tb);

	if (tb[DPLL_A_PIN_ID]) {
		__u32 id = mnl_attr_get_u32(tb[DPLL_A_PIN_ID]);
		if (is_json_context()) {
			print_uint(PRINT_JSON, "id", NULL, id);
		} else {
			printf("%u\n", id);
		}
	}

	return MNL_CB_OK;
}

static int cmd_pin_id_get(struct dpll *dpll)
{
	struct nlmsghdr *nlh;
	int err;

	nlh = mnlu_gen_socket_cmd_prepare(&dpll->nlg, DPLL_CMD_PIN_ID_GET,
					   NLM_F_REQUEST | NLM_F_ACK);

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "module-name")) {
			DPLL_PARSE_ATTR_STR(dpll, nlh, "module-name", DPLL_A_PIN_MODULE_NAME);
		} else if (dpll_argv_match(dpll, "clock-id")) {
			DPLL_PARSE_ATTR_U64(dpll, nlh, "clock-id", DPLL_A_PIN_CLOCK_ID);
		} else if (dpll_argv_match(dpll, "board-label")) {
			DPLL_PARSE_ATTR_STR(dpll, nlh, "board-label", DPLL_A_PIN_BOARD_LABEL);
		} else if (dpll_argv_match(dpll, "panel-label")) {
			DPLL_PARSE_ATTR_STR(dpll, nlh, "panel-label", DPLL_A_PIN_PANEL_LABEL);
		} else if (dpll_argv_match(dpll, "package-label")) {
			DPLL_PARSE_ATTR_STR(dpll, nlh, "package-label", DPLL_A_PIN_PACKAGE_LABEL);
		} else if (dpll_argv_match(dpll, "type")) {
			dpll_arg_inc(dpll);
			if (dpll_arg_required(dpll, "type"))
				return -EINVAL;
			/* Parse pin type */
			if (dpll_argv_match(dpll, "mux")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_TYPE, DPLL_PIN_TYPE_MUX);
			} else if (dpll_argv_match(dpll, "ext")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_TYPE, DPLL_PIN_TYPE_EXT);
			} else if (dpll_argv_match(dpll, "synce-eth-port")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_TYPE, DPLL_PIN_TYPE_SYNCE_ETH_PORT);
			} else if (dpll_argv_match(dpll, "int-oscillator")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_TYPE, DPLL_PIN_TYPE_INT_OSCILLATOR);
			} else if (dpll_argv_match(dpll, "gnss")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_TYPE, DPLL_PIN_TYPE_GNSS);
			} else {
				pr_err("invalid type: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			dpll_arg_inc(dpll);
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			return -EINVAL;
		}
	}

	err = mnlu_gen_socket_sndrcv(&dpll->nlg, nlh, cmd_pin_id_get_cb, NULL);
	if (err < 0) {
		pr_err("Failed to get pin id\n");
		return -1;
	}

	return 0;
}

static int cmd_pin(struct dpll *dpll)
{
	if (dpll_argv_match(dpll, "help") || dpll_no_arg(dpll)) {
		cmd_pin_help();
		return 0;
	} else if (dpll_argv_match_inc(dpll, "show")) {
		return cmd_pin_show(dpll);
	} else if (dpll_argv_match_inc(dpll, "set")) {
		return cmd_pin_set(dpll);
	} else if (dpll_argv_match_inc(dpll, "id-get")) {
		return cmd_pin_id_get(dpll);
	}

	pr_err("Command \"%s\" not found\n", dpll_argv(dpll) ? dpll_argv(dpll) : "");
	return -ENOENT;
}

/* Monitor command - notification handling */
static int cmd_monitor_cb(const struct nlmsghdr *nlh, void *data)
{
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);
	const char *cmd_name = "UNKNOWN";

	switch (genl->cmd) {
	case DPLL_CMD_DEVICE_CREATE_NTF:
		cmd_name = "DEVICE_CREATE";
		/* fallthrough */
	case DPLL_CMD_DEVICE_CHANGE_NTF:
		if (genl->cmd == DPLL_CMD_DEVICE_CHANGE_NTF)
			cmd_name = "DEVICE_CHANGE";
		/* fallthrough */
	case DPLL_CMD_DEVICE_DELETE_NTF: {
		if (genl->cmd == DPLL_CMD_DEVICE_DELETE_NTF)
			cmd_name = "DEVICE_DELETE";
		struct nlattr *tb[DPLL_A_MAX + 1] = {};
		mnl_attr_parse(nlh, sizeof(*genl), attr_cb, tb);
		pr_out("[%s] ", cmd_name);
		dpll_device_print_attrs(nlh, tb);
		break;
	}
	case DPLL_CMD_PIN_CREATE_NTF:
		cmd_name = "PIN_CREATE";
		/* fallthrough */
	case DPLL_CMD_PIN_CHANGE_NTF:
		if (genl->cmd == DPLL_CMD_PIN_CHANGE_NTF)
			cmd_name = "PIN_CHANGE";
		/* fallthrough */
	case DPLL_CMD_PIN_DELETE_NTF: {
		if (genl->cmd == DPLL_CMD_PIN_DELETE_NTF)
			cmd_name = "PIN_DELETE";

		/* Multi-attr contexts for pin notifications */
		struct multi_attr_ctx parent_dev_ctx = {0};
		struct multi_attr_ctx parent_pin_ctx = {0};
		struct multi_attr_ctx ref_sync_ctx = {0};
		struct multi_attr_ctx freq_supp_ctx = {0};
		struct multi_attr_ctx esync_freq_supp_ctx = {0};
		struct multi_attr_collector collector = {0};
		struct nlattr *tb[DPLL_A_PIN_MAX + 1] = {};
		int count;
		int ret = MNL_CB_OK;

		/* Pass 1: Count multi-attr occurrences and allocate */
		count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_PARENT_DEVICE);
		if (count > 0 && multi_attr_ctx_init(&parent_dev_ctx, count) < 0)
			goto pin_ntf_err;

		count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_PARENT_PIN);
		if (count > 0 && multi_attr_ctx_init(&parent_pin_ctx, count) < 0)
			goto pin_ntf_err;

		count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_REFERENCE_SYNC);
		if (count > 0 && multi_attr_ctx_init(&ref_sync_ctx, count) < 0)
			goto pin_ntf_err;

		count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_FREQUENCY_SUPPORTED);
		if (count > 0 && multi_attr_ctx_init(&freq_supp_ctx, count) < 0)
			goto pin_ntf_err;

		count = multi_attr_count_get(nlh, genl, DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED);
		if (count > 0 && multi_attr_ctx_init(&esync_freq_supp_ctx, count) < 0)
			goto pin_ntf_err;

		/* Pass 2: Collect multi-attr entries */
		if (parent_dev_ctx.entries) {
			collector.attr_type = DPLL_A_PIN_PARENT_DEVICE;
			collector.ctx = &parent_dev_ctx;
			mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
		}

		if (parent_pin_ctx.entries) {
			collector.attr_type = DPLL_A_PIN_PARENT_PIN;
			collector.ctx = &parent_pin_ctx;
			mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
		}

		if (ref_sync_ctx.entries) {
			collector.attr_type = DPLL_A_PIN_REFERENCE_SYNC;
			collector.ctx = &ref_sync_ctx;
			mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
		}

		if (freq_supp_ctx.entries) {
			collector.attr_type = DPLL_A_PIN_FREQUENCY_SUPPORTED;
			collector.ctx = &freq_supp_ctx;
			mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
		}

		if (esync_freq_supp_ctx.entries) {
			collector.attr_type = DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED;
			collector.ctx = &esync_freq_supp_ctx;
			mnl_attr_parse(nlh, sizeof(*genl), collect_multi_attr_cb, &collector);
		}

		/* Pass 3: Parse remaining single attributes */
		mnl_attr_parse(nlh, sizeof(*genl), attr_pin_cb, tb);

		/* Replace tb entries with contexts */
		tb[DPLL_A_PIN_PARENT_DEVICE] = parent_dev_ctx.count > 0 ?
			(struct nlattr *)&parent_dev_ctx : NULL;
		tb[DPLL_A_PIN_PARENT_PIN] = parent_pin_ctx.count > 0 ?
			(struct nlattr *)&parent_pin_ctx : NULL;
		tb[DPLL_A_PIN_REFERENCE_SYNC] = ref_sync_ctx.count > 0 ?
			(struct nlattr *)&ref_sync_ctx : NULL;
		tb[DPLL_A_PIN_FREQUENCY_SUPPORTED] = freq_supp_ctx.count > 0 ?
			(struct nlattr *)&freq_supp_ctx : NULL;
		tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED] =
			esync_freq_supp_ctx.count > 0 ?
			(struct nlattr *)&esync_freq_supp_ctx : NULL;

		pr_out("[%s] ", cmd_name);
		dpll_pin_print_attrs(tb);
		goto pin_ntf_cleanup;

pin_ntf_err:
		pr_err("Failed to allocate memory for multi-attr processing\n");
		ret = MNL_CB_ERROR;

pin_ntf_cleanup:
		/* Free allocated memory */
		multi_attr_ctx_free(&parent_dev_ctx);
		multi_attr_ctx_free(&parent_pin_ctx);
		multi_attr_ctx_free(&ref_sync_ctx);
		multi_attr_ctx_free(&freq_supp_ctx);
		multi_attr_ctx_free(&esync_freq_supp_ctx);

		if (ret == MNL_CB_ERROR)
			return ret;
		break;
	}
	default:
		pr_err("Unknown notification command: %d\n", genl->cmd);
		break;
	}

	return MNL_CB_OK;
}

static int cmd_monitor(struct dpll *dpll)
{
	struct pollfd pfd;
	struct sigaction sa;
	int ret = 0;
	int fd;

	/* Subscribe to monitor multicast group */
	ret = mnlg_socket_group_add(&dpll->nlg, "monitor");
	if (ret) {
		pr_err("Failed to subscribe to monitor group: %s\n", strerror(errno));
		return ret;
	}

	if (!dpll->json_output) {
		pr_out("Monitoring DPLL events (Press Ctrl+C to stop)...\n");
	}

	/* Setup signal handler for graceful exit */
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = monitor_sig_handler;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	/* Get netlink socket fd for polling */
	fd = mnlg_socket_get_fd(&dpll->nlg);
	if (fd < 0) {
		pr_err("Failed to get netlink socket fd\n");
		return -1;
	}

	if (dpll->json_output) {
		open_json_array(PRINT_JSON, "monitor");
	}

	/* Setup poll structure */
	memset(&pfd, 0, sizeof(pfd));
	pfd.fd = fd;
	pfd.events = POLLIN;

	/* Enter notification loop */
	while (monitor_running) {
		ret = poll(&pfd, 1, 1000); /* 1 second timeout */
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			pr_err("poll() failed: %s\n", strerror(errno));
			ret = -errno;
			break;
		}

		if (ret == 0)
			continue; /* Timeout, check monitor_running flag */

		/* Data available, receive and process */
		ret = mnlu_gen_socket_recv_run(&dpll->nlg, cmd_monitor_cb, NULL);
		if (ret < 0) {
			/* Only print error if we're still supposed to be running.
			 * If monitor_running is false, we're shutting down gracefully. */
			if (monitor_running)
				pr_err("Failed to receive notifications: %s\n", strerror(errno));
			break;
		}
	}

	if (dpll->json_output) {
		close_json_array(PRINT_JSON, NULL);
	}

	/* Reset signal handlers */
	signal(SIGINT, SIG_DFL);
	signal(SIGTERM, SIG_DFL);

	return ret < 0 ? ret : 0;
}
