/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * dpll-mnl.c	DPLL tool using libmnl
 *
 * Authors:	TBD
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
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

	if (dpll_argc(dpll) == 0)
		return NULL;

	ret = *dpll->argv;
	dpll_arg_inc(dpll);
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

static void __attribute__((format(printf, 1, 2)))
pr_err(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

static void __attribute__((format(printf, 1, 2)))
pr_out(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
}

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
	} else if (dpll_argv_match(dpll, "device")) {
		dpll_arg_inc(dpll);
		return cmd_device(dpll);
	} else if (dpll_argv_match(dpll, "pin")) {
		dpll_arg_inc(dpll);
		return cmd_pin(dpll);
	} else if (dpll_argv_match(dpll, "monitor")) {
		dpll_arg_inc(dpll);
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
		return "ffo-too-high";
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
static void dpll_device_print_attrs(struct nlattr **tb)
{
	if (tb[DPLL_A_ID])
		print_uint(PRINT_ANY, "id", "device id %u",
			   mnl_attr_get_u32(tb[DPLL_A_ID]));
	print_string(PRINT_FP, NULL, ":\n", NULL);

	if (tb[DPLL_A_MODULE_NAME])
		print_string(PRINT_ANY, "module-name",
			     "  module-name: %s\n",
			     mnl_attr_get_str(tb[DPLL_A_MODULE_NAME]));

	if (tb[DPLL_A_MODE])
		print_string(PRINT_ANY, "mode",
			     "  mode: %s\n",
			     dpll_mode_name(mnl_attr_get_u32(tb[DPLL_A_MODE])));

	if (tb[DPLL_A_CLOCK_ID]) {
		if (is_json_context())
			print_u64(PRINT_JSON, "clock-id", NULL,
				  mnl_attr_get_u64(tb[DPLL_A_CLOCK_ID]));
		else
			print_0xhex(PRINT_FP, "clock-id",
				    "  clock-id: 0x%llx\n",
				    mnl_attr_get_u64(tb[DPLL_A_CLOCK_ID]));
	}

	if (tb[DPLL_A_TYPE])
		print_string(PRINT_ANY, "type",
			     "  type: %s\n",
			     dpll_type_name(mnl_attr_get_u32(tb[DPLL_A_TYPE])));

	if (tb[DPLL_A_LOCK_STATUS])
		print_string(PRINT_ANY, "lock-status",
			     "  lock-status: %s\n",
			     dpll_lock_status_name(mnl_attr_get_u32(tb[DPLL_A_LOCK_STATUS])));

	if (tb[DPLL_A_LOCK_STATUS_ERROR])
		print_string(PRINT_ANY, "lock-status-error",
			     "  lock-status-error: %s\n",
			     dpll_lock_status_error_name(mnl_attr_get_u32(tb[DPLL_A_LOCK_STATUS_ERROR])));

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

	/* Handle mode-supported - spec defines as type: u32, multi-attr: true */
	if (tb[DPLL_A_MODE_SUPPORTED]) {
		__u32 mode = mnl_attr_get_u32(tb[DPLL_A_MODE_SUPPORTED]);

		if (is_json_context()) {
			open_json_array(PRINT_JSON, "mode-supported");
			print_string(PRINT_JSON, NULL, NULL, dpll_mode_name(mode));
			close_json_array(PRINT_JSON, NULL);
		} else {
			pr_out("  mode-supported: %s\n", dpll_mode_name(mode));
		}
	}
}

/* Callback for device get (single) */
static int cmd_device_show_cb(const struct nlmsghdr *nlh, void *data)
{
	struct nlattr *tb[DPLL_A_MAX + 1] = {};
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);

	mnl_attr_parse(nlh, sizeof(*genl), attr_cb, tb);
	dpll_device_print_attrs(tb);

	return MNL_CB_OK;
}

/* Callback for device dump (multiple) - wraps each device in object */
static int cmd_device_show_dump_cb(const struct nlmsghdr *nlh, void *data)
{
	struct nlattr *tb[DPLL_A_MAX + 1] = {};
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);

	mnl_attr_parse(nlh, sizeof(*genl), attr_cb, tb);

	open_json_object(NULL);
	dpll_device_print_attrs(tb);
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
			char *str;

			dpll_arg_inc(dpll);
			str = dpll_argv_next(dpll);
			if (!str) {
				pr_err("id requires an argument\n");
				return -EINVAL;
			}
			if (get_u32(&id, str, 0)) {
				pr_err("invalid id: %s\n", str);
				return -EINVAL;
			}
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
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("id requires an argument\n");
				return -EINVAL;
			}
			if (get_u32(&id, dpll_argv(dpll), 0)) {
				pr_err("invalid id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u32(nlh, DPLL_A_ID, id);
			has_id = true;
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "phase-offset-monitor")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("phase-offset-monitor requires an argument\n");
				return -EINVAL;
			}
			if (dpll_argv_match(dpll, "true") || dpll_argv_match(dpll, "1")) {
				mnl_attr_put_u8(nlh, DPLL_A_PHASE_OFFSET_MONITOR, 1);
			} else if (dpll_argv_match(dpll, "false") || dpll_argv_match(dpll, "0")) {
				mnl_attr_put_u8(nlh, DPLL_A_PHASE_OFFSET_MONITOR, 0);
			} else {
				pr_err("invalid phase-offset-monitor value: %s (use true/false)\n",
				       dpll_argv(dpll));
				return -EINVAL;
			}
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "phase-offset-avg-factor")) {
			__u32 phase_avg_factor;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("phase-offset-avg-factor requires an argument\n");
				return -EINVAL;
			}
			if (get_u32(&phase_avg_factor, dpll_argv(dpll), 0)) {
				pr_err("invalid phase-offset-avg-factor: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u32(nlh, DPLL_A_PHASE_OFFSET_AVG_FACTOR, phase_avg_factor);
			dpll_arg_inc(dpll);
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
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("module-name requires an argument\n");
				return -EINVAL;
			}
			mnl_attr_put_strz(nlh, DPLL_A_MODULE_NAME, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "clock-id")) {
			__u64 clock_id;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("clock-id requires an argument\n");
				return -EINVAL;
			}
			if (get_u64(&clock_id, dpll_argv(dpll), 0)) {
				pr_err("invalid clock-id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u64(nlh, DPLL_A_CLOCK_ID, clock_id);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "type")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("type requires an argument\n");
				return -EINVAL;
			}
			if (dpll_argv_match(dpll, "pps")) {
				mnl_attr_put_u32(nlh, DPLL_A_TYPE, DPLL_TYPE_PPS);
			} else if (dpll_argv_match(dpll, "eec")) {
				mnl_attr_put_u32(nlh, DPLL_A_TYPE, DPLL_TYPE_EEC);
			} else {
				pr_err("invalid type: %s (use pps/eec)\n", dpll_argv(dpll));
				return -EINVAL;
			}
			dpll_arg_inc(dpll);
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
	} else if (dpll_argv_match(dpll, "show")) {
		dpll_arg_inc(dpll);
		return cmd_device_show(dpll);
	} else if (dpll_argv_match(dpll, "set")) {
		dpll_arg_inc(dpll);
		return cmd_device_set(dpll);
	} else if (dpll_argv_match(dpll, "id-get")) {
		dpll_arg_inc(dpll);
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
	pr_err("                               [ direction { input | output } ]\n");
	pr_err("                               [ prio PRIO ]\n");
	pr_err("                               [ state { connected | disconnected | selectable } ]\n");
	pr_err("                               [ parent-device DEVICE_ID [ direction DIR ]\n");
	pr_err("                                                          [ prio PRIO ]\n");
	pr_err("                                                          [ state STATE ] ]\n");
	pr_err("                               [ parent-pin PIN_ID [ state STATE ] ]\n");
	pr_err("                               [ phase-adjust ADJUST ]\n");
	pr_err("                               [ esync-frequency FREQ ]\n");
	pr_err("                               [ reference-sync PIN_ID [ state STATE ] ]\n");
	pr_err("       dpll pin id-get [ module-name NAME ] [ clock-id ID ]\n");
	pr_err("                        [ board-label LABEL ] [ panel-label LABEL ]\n");
	pr_err("                        [ package-label LABEL ] [ type TYPE ]\n");
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
	struct nlattr *attr;

	if (tb[DPLL_A_PIN_ID])
		print_uint(PRINT_ANY, "id", "pin id %u",
			   mnl_attr_get_u32(tb[DPLL_A_PIN_ID]));
	print_string(PRINT_FP, NULL, ":\n", NULL);

	if (tb[DPLL_A_PIN_MODULE_NAME])
		print_string(PRINT_ANY, "module-name",
			     "  module-name: %s\n",
			     mnl_attr_get_str(tb[DPLL_A_PIN_MODULE_NAME]));

	if (tb[DPLL_A_PIN_CLOCK_ID]) {
		if (is_json_context())
			print_u64(PRINT_JSON, "clock-id", NULL,
				  mnl_attr_get_u64(tb[DPLL_A_PIN_CLOCK_ID]));
		else
			print_0xhex(PRINT_FP, "clock-id",
				    "  clock-id: 0x%llx\n",
				    mnl_attr_get_u64(tb[DPLL_A_PIN_CLOCK_ID]));
	}

	if (tb[DPLL_A_PIN_BOARD_LABEL])
		print_string(PRINT_ANY, "board-label",
			     "  board-label: %s\n",
			     mnl_attr_get_str(tb[DPLL_A_PIN_BOARD_LABEL]));

	if (tb[DPLL_A_PIN_PANEL_LABEL])
		print_string(PRINT_ANY, "panel-label",
			     "  panel-label: %s\n",
			     mnl_attr_get_str(tb[DPLL_A_PIN_PANEL_LABEL]));

	if (tb[DPLL_A_PIN_PACKAGE_LABEL])
		print_string(PRINT_ANY, "package-label",
			     "  package-label: %s\n",
			     mnl_attr_get_str(tb[DPLL_A_PIN_PACKAGE_LABEL]));

	if (tb[DPLL_A_PIN_TYPE])
		print_string(PRINT_ANY, "type",
			     "  type: %s\n",
			     dpll_pin_type_name(mnl_attr_get_u32(tb[DPLL_A_PIN_TYPE])));

	if (tb[DPLL_A_PIN_FREQUENCY])
		print_lluint(PRINT_ANY, "frequency",
			     "  frequency: %llu Hz\n",
			     mnl_attr_get_u64(tb[DPLL_A_PIN_FREQUENCY]));

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
			mnl_attr_parse_nested(ctx->entries[i], attr_pin_cb, tb_freq);

			open_json_object(NULL);
			if (!is_json_context())
				pr_out("    ");

			if (tb_freq[DPLL_A_PIN_FREQUENCY_MIN])
				print_lluint(PRINT_ANY, "frequency-min", "%llu",
					     mnl_attr_get_u64(tb_freq[DPLL_A_PIN_FREQUENCY_MIN]));
			if (!is_json_context())
				pr_out("-");
			if (tb_freq[DPLL_A_PIN_FREQUENCY_MAX])
				print_lluint(PRINT_ANY, "frequency-max", "%llu",
					     mnl_attr_get_u64(tb_freq[DPLL_A_PIN_FREQUENCY_MAX]));
			if (!is_json_context())
				pr_out(" Hz\n");

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

	/* Print phase adjust range and current value */
	if (tb[DPLL_A_PIN_PHASE_ADJUST_MIN])
		print_int(PRINT_ANY, "phase-adjust-min",
			  "  phase-adjust-min: %d\n",
			  mnl_attr_get_u32(tb[DPLL_A_PIN_PHASE_ADJUST_MIN]));

	if (tb[DPLL_A_PIN_PHASE_ADJUST_MAX])
		print_int(PRINT_ANY, "phase-adjust-max",
			  "  phase-adjust-max: %d\n",
			  mnl_attr_get_u32(tb[DPLL_A_PIN_PHASE_ADJUST_MAX]));

	if (tb[DPLL_A_PIN_PHASE_ADJUST])
		print_int(PRINT_ANY, "phase-adjust",
			  "  phase-adjust: %d\n",
			  mnl_attr_get_u32(tb[DPLL_A_PIN_PHASE_ADJUST]));

	/* Print fractional frequency offset */
	if (tb[DPLL_A_PIN_FRACTIONAL_FREQUENCY_OFFSET])
		print_lluint(PRINT_ANY, "fractional_frequency_offset",
			     "  fractional-frequency-offset: %lld ppb\n",
			     (long long)mnl_attr_get_u64(tb[DPLL_A_PIN_FRACTIONAL_FREQUENCY_OFFSET]));

	/* Print esync frequency and related attributes */
	if (tb[DPLL_A_PIN_ESYNC_FREQUENCY])
		print_lluint(PRINT_ANY, "esync_frequency",
			     "  esync-frequency: %llu Hz\n",
			     mnl_attr_get_u64(tb[DPLL_A_PIN_ESYNC_FREQUENCY]));

	if (tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED]) {
		struct multi_attr_ctx *ctx = (struct multi_attr_ctx *)tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED];
		int i;

		open_json_array(PRINT_JSON, "esync-frequency-supported");
		if (!is_json_context())
			pr_out("  esync-frequency-supported:\n");

		/* Iterate through all collected esync-frequency-supported entries */
		for (i = 0; i < ctx->count; i++) {
			struct nlattr *tb_freq[DPLL_A_PIN_MAX + 1] = {};
			mnl_attr_parse_nested(ctx->entries[i], attr_pin_cb, tb_freq);

			open_json_object(NULL);
			if (!is_json_context())
				pr_out("    ");

			if (tb_freq[DPLL_A_PIN_FREQUENCY_MIN])
				print_lluint(PRINT_ANY, "frequency-min", "%llu",
					     mnl_attr_get_u64(tb_freq[DPLL_A_PIN_FREQUENCY_MIN]));
			if (!is_json_context())
				pr_out("-");
			if (tb_freq[DPLL_A_PIN_FREQUENCY_MAX])
				print_lluint(PRINT_ANY, "frequency-max", "%llu",
					     mnl_attr_get_u64(tb_freq[DPLL_A_PIN_FREQUENCY_MAX]));
			if (!is_json_context())
				pr_out(" Hz\n");

			close_json_object();
		}
		close_json_array(PRINT_JSON, NULL);
	}

	if (tb[DPLL_A_PIN_ESYNC_PULSE])
		print_uint(PRINT_ANY, "esync_pulse",
			   "  esync-pulse: %u\n",
			   mnl_attr_get_u32(tb[DPLL_A_PIN_ESYNC_PULSE]));

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

			if (tb_parent[DPLL_A_PIN_PARENT_ID])
				print_uint(PRINT_ANY, "parent-id",
					   "id %u",
					   mnl_attr_get_u32(tb_parent[DPLL_A_PIN_PARENT_ID]));
			if (tb_parent[DPLL_A_PIN_DIRECTION])
				print_string(PRINT_ANY, "direction",
					     " direction %s",
					     dpll_pin_direction_name(mnl_attr_get_u32(tb_parent[DPLL_A_PIN_DIRECTION])));
			if (tb_parent[DPLL_A_PIN_PRIO])
				print_uint(PRINT_ANY, "prio",
					   " prio %u",
					   mnl_attr_get_u32(tb_parent[DPLL_A_PIN_PRIO]));
			if (tb_parent[DPLL_A_PIN_STATE])
				print_string(PRINT_ANY, "state",
					     " state %s",
					     dpll_pin_state_name(mnl_attr_get_u32(tb_parent[DPLL_A_PIN_STATE])));
			if (tb_parent[DPLL_A_PIN_PHASE_OFFSET])
				print_lluint(PRINT_ANY, "phase-offset",
					     " phase-offset %lld",
					     mnl_attr_get_u64(tb_parent[DPLL_A_PIN_PHASE_OFFSET]));

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

			if (tb_parent[DPLL_A_PIN_PARENT_ID])
				print_uint(PRINT_ANY, "parent-id",
					   "id %u",
					   mnl_attr_get_u32(tb_parent[DPLL_A_PIN_PARENT_ID]));
			if (tb_parent[DPLL_A_PIN_STATE])
				print_string(PRINT_ANY, "state",
					     " state %s",
					     dpll_pin_state_name(mnl_attr_get_u32(tb_parent[DPLL_A_PIN_STATE])));

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

			if (tb_ref[DPLL_A_PIN_ID])
				print_uint(PRINT_ANY, "id",
					   "pin %u",
					   mnl_attr_get_u32(tb_ref[DPLL_A_PIN_ID]));
			if (tb_ref[DPLL_A_PIN_STATE])
				print_string(PRINT_ANY, "state",
					     " state %s",
					     dpll_pin_state_name(mnl_attr_get_u32(tb_ref[DPLL_A_PIN_STATE])));

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
	tb[DPLL_A_PIN_PARENT_DEVICE] = parent_dev_ctx.count > 0 ? (struct nlattr *)&parent_dev_ctx : NULL;
	tb[DPLL_A_PIN_PARENT_PIN] = parent_pin_ctx.count > 0 ? (struct nlattr *)&parent_pin_ctx : NULL;
	tb[DPLL_A_PIN_REFERENCE_SYNC] = ref_sync_ctx.count > 0 ? (struct nlattr *)&ref_sync_ctx : NULL;
	tb[DPLL_A_PIN_FREQUENCY_SUPPORTED] = freq_supp_ctx.count > 0 ? (struct nlattr *)&freq_supp_ctx : NULL;
	tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED] = esync_freq_supp_ctx.count > 0 ? (struct nlattr *)&esync_freq_supp_ctx : NULL;

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
	tb[DPLL_A_PIN_PARENT_DEVICE] = parent_dev_ctx.count > 0 ? (struct nlattr *)&parent_dev_ctx : NULL;
	tb[DPLL_A_PIN_PARENT_PIN] = parent_pin_ctx.count > 0 ? (struct nlattr *)&parent_pin_ctx : NULL;
	tb[DPLL_A_PIN_REFERENCE_SYNC] = ref_sync_ctx.count > 0 ? (struct nlattr *)&ref_sync_ctx : NULL;
	tb[DPLL_A_PIN_FREQUENCY_SUPPORTED] = freq_supp_ctx.count > 0 ? (struct nlattr *)&freq_supp_ctx : NULL;
	tb[DPLL_A_PIN_ESYNC_FREQUENCY_SUPPORTED] = esync_freq_supp_ctx.count > 0 ? (struct nlattr *)&esync_freq_supp_ctx : NULL;

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
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("id requires an argument\n");
				return -EINVAL;
			}
			if (get_u32(&pin_id, dpll_argv(dpll), 0)) {
				pr_err("invalid pin id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			has_pin_id = true;
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "device")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("device requires an argument\n");
				return -EINVAL;
			}
			if (get_u32(&device_id, dpll_argv(dpll), 0)) {
				pr_err("invalid device id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			has_device_id = true;
			dpll_arg_inc(dpll);
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
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("id requires an argument\n");
				return -EINVAL;
			}
			if (get_u32(&id, dpll_argv(dpll), 0)) {
				pr_err("invalid pin id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u32(nlh, DPLL_A_PIN_ID, id);
			has_id = true;
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "frequency")) {
			__u64 freq;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("frequency requires an argument\n");
				return -EINVAL;
			}
			if (get_u64(&freq, dpll_argv(dpll), 0)) {
				pr_err("invalid frequency: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u64(nlh, DPLL_A_PIN_FREQUENCY, freq);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "prio")) {
			__u32 prio;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("prio requires an argument\n");
				return -EINVAL;
			}
			if (get_u32(&prio, dpll_argv(dpll), 0)) {
				pr_err("invalid prio: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u32(nlh, DPLL_A_PIN_PRIO, prio);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "direction")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("direction requires an argument\n");
				return -EINVAL;
			}
			if (dpll_argv_match(dpll, "input")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_DIRECTION, DPLL_PIN_DIRECTION_INPUT);
			} else if (dpll_argv_match(dpll, "output")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_DIRECTION, DPLL_PIN_DIRECTION_OUTPUT);
			} else {
				pr_err("invalid direction: %s (use input/output)\n",
				       dpll_argv(dpll));
				return -EINVAL;
			}
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "state")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("state requires an argument\n");
				return -EINVAL;
			}
			if (dpll_argv_match(dpll, "connected")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE, DPLL_PIN_STATE_CONNECTED);
			} else if (dpll_argv_match(dpll, "disconnected")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE, DPLL_PIN_STATE_DISCONNECTED);
			} else if (dpll_argv_match(dpll, "selectable")) {
				mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE, DPLL_PIN_STATE_SELECTABLE);
			} else {
				pr_err("invalid state: %s (use connected/disconnected/selectable)\n",
				       dpll_argv(dpll));
				return -EINVAL;
			}
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "phase-adjust")) {
			__s32 phase_adjust;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("phase-adjust requires an argument\n");
				return -EINVAL;
			}
			if (get_s32(&phase_adjust, dpll_argv(dpll), 0)) {
				pr_err("invalid phase-adjust: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u32(nlh, DPLL_A_PIN_PHASE_ADJUST, phase_adjust);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "esync-frequency")) {
			__u64 esync_freq;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("esync-frequency requires an argument\n");
				return -EINVAL;
			}
			if (get_u64(&esync_freq, dpll_argv(dpll), 0)) {
				pr_err("invalid esync-frequency: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u64(nlh, DPLL_A_PIN_ESYNC_FREQUENCY, esync_freq);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "parent-device")) {
			struct nlattr *nest;
			__u32 parent_id;

			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("parent-device requires device id\n");
				return -EINVAL;
			}

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
					dpll_arg_inc(dpll);
					if (dpll_argc(dpll) == 0) {
						pr_err("direction requires an argument\n");
						return -EINVAL;
					}
					if (dpll_argv_match(dpll, "input")) {
						mnl_attr_put_u32(nlh, DPLL_A_PIN_DIRECTION,
								 DPLL_PIN_DIRECTION_INPUT);
					} else if (dpll_argv_match(dpll, "output")) {
						mnl_attr_put_u32(nlh, DPLL_A_PIN_DIRECTION,
								 DPLL_PIN_DIRECTION_OUTPUT);
					} else {
						pr_err("invalid direction: %s\n", dpll_argv(dpll));
						return -EINVAL;
					}
					dpll_arg_inc(dpll);
				} else if (dpll_argv_match(dpll, "prio")) {
					__u32 prio;
					dpll_arg_inc(dpll);
					if (dpll_argc(dpll) == 0) {
						pr_err("prio requires an argument\n");
						return -EINVAL;
					}
					if (get_u32(&prio, dpll_argv(dpll), 0)) {
						pr_err("invalid prio: %s\n", dpll_argv(dpll));
						return -EINVAL;
					}
					mnl_attr_put_u32(nlh, DPLL_A_PIN_PRIO, prio);
					dpll_arg_inc(dpll);
				} else if (dpll_argv_match(dpll, "state")) {
					dpll_arg_inc(dpll);
					if (dpll_argc(dpll) == 0) {
						pr_err("state requires an argument\n");
						return -EINVAL;
					}
					if (dpll_argv_match(dpll, "connected")) {
						mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
								 DPLL_PIN_STATE_CONNECTED);
					} else if (dpll_argv_match(dpll, "disconnected")) {
						mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
								 DPLL_PIN_STATE_DISCONNECTED);
					} else if (dpll_argv_match(dpll, "selectable")) {
						mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
								 DPLL_PIN_STATE_SELECTABLE);
					} else {
						pr_err("invalid state: %s\n", dpll_argv(dpll));
						return -EINVAL;
					}
					dpll_arg_inc(dpll);
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
			if (dpll_argc(dpll) == 0) {
				pr_err("parent-pin requires pin id\n");
				return -EINVAL;
			}

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
				dpll_arg_inc(dpll);
				if (dpll_argc(dpll) == 0) {
					pr_err("state requires an argument\n");
					return -EINVAL;
				}
				if (dpll_argv_match(dpll, "connected")) {
					mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
							 DPLL_PIN_STATE_CONNECTED);
				} else if (dpll_argv_match(dpll, "disconnected")) {
					mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
							 DPLL_PIN_STATE_DISCONNECTED);
				} else if (dpll_argv_match(dpll, "selectable")) {
					mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
							 DPLL_PIN_STATE_SELECTABLE);
				} else {
					pr_err("invalid state: %s\n", dpll_argv(dpll));
					return -EINVAL;
				}
				dpll_arg_inc(dpll);
			}

			mnl_attr_nest_end(nlh, nest);
		} else if (dpll_argv_match(dpll, "reference-sync")) {
			struct nlattr *nest;
			__u32 ref_pin_id;

			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("reference-sync requires pin id\n");
				return -EINVAL;
			}

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
				dpll_arg_inc(dpll);
				if (dpll_argc(dpll) == 0) {
					pr_err("state requires an argument\n");
					return -EINVAL;
				}
				if (dpll_argv_match(dpll, "connected")) {
					mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
							 DPLL_PIN_STATE_CONNECTED);
				} else if (dpll_argv_match(dpll, "disconnected")) {
					mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
							 DPLL_PIN_STATE_DISCONNECTED);
				} else if (dpll_argv_match(dpll, "selectable")) {
					mnl_attr_put_u32(nlh, DPLL_A_PIN_STATE,
							 DPLL_PIN_STATE_SELECTABLE);
				} else {
					pr_err("invalid state: %s\n", dpll_argv(dpll));
					return -EINVAL;
				}
				dpll_arg_inc(dpll);
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
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("module-name requires an argument\n");
				return -EINVAL;
			}
			mnl_attr_put_strz(nlh, DPLL_A_PIN_MODULE_NAME, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "clock-id")) {
			__u64 clock_id;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("clock-id requires an argument\n");
				return -EINVAL;
			}
			if (get_u64(&clock_id, dpll_argv(dpll), 0)) {
				pr_err("invalid clock-id: %s\n", dpll_argv(dpll));
				return -EINVAL;
			}
			mnl_attr_put_u64(nlh, DPLL_A_PIN_CLOCK_ID, clock_id);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "board-label")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("board-label requires an argument\n");
				return -EINVAL;
			}
			mnl_attr_put_strz(nlh, DPLL_A_PIN_BOARD_LABEL, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "panel-label")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("panel-label requires an argument\n");
				return -EINVAL;
			}
			mnl_attr_put_strz(nlh, DPLL_A_PIN_PANEL_LABEL, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "package-label")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("package-label requires an argument\n");
				return -EINVAL;
			}
			mnl_attr_put_strz(nlh, DPLL_A_PIN_PACKAGE_LABEL, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "type")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("type requires an argument\n");
				return -EINVAL;
			}
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
	} else if (dpll_argv_match(dpll, "show")) {
		dpll_arg_inc(dpll);
		return cmd_pin_show(dpll);
	} else if (dpll_argv_match(dpll, "set")) {
		dpll_arg_inc(dpll);
		return cmd_pin_set(dpll);
	} else if (dpll_argv_match(dpll, "id-get")) {
		dpll_arg_inc(dpll);
		return cmd_pin_id_get(dpll);
	}

	pr_err("Command \"%s\" not found\n", dpll_argv(dpll) ? dpll_argv(dpll) : "");
	return -ENOENT;
}

/* Monitor command - notification handling */
static int cmd_monitor_cb(const struct nlmsghdr *nlh, void *data)
{
	struct genlmsghdr *genl = mnl_nlmsg_get_payload(nlh);

	switch (genl->cmd) {
	case DPLL_CMD_DEVICE_CREATE_NTF:
	case DPLL_CMD_DEVICE_CHANGE_NTF:
	case DPLL_CMD_DEVICE_DELETE_NTF: {
		struct nlattr *tb[DPLL_A_MAX + 1] = {};
		mnl_attr_parse(nlh, sizeof(*genl), attr_cb, tb);
		dpll_device_print_attrs(tb);
		break;
	}
	case DPLL_CMD_PIN_CREATE_NTF:
	case DPLL_CMD_PIN_CHANGE_NTF:
	case DPLL_CMD_PIN_DELETE_NTF: {
		struct nlattr *tb[DPLL_A_PIN_MAX + 1] = {};
		mnl_attr_parse(nlh, sizeof(*genl), attr_pin_cb, tb);
		dpll_pin_print_attrs(tb);
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
		pr_err("Failed to subscribe to monitor group\n");
		return ret;
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
			pr_err("Failed to receive notifications\n");
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
