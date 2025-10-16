/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * dpll.c	DPLL tool
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
#include <linux/dpll.h>

#include <ynl.h>
#include "dpll-user.h"
#include "version.h"
#include "utils.h"
#include "json_print.h"

struct dpll {
	struct ynl_sock *ys;
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

/* Indent management for plain text output */
#define INDENT_STR_STEP 2
#define INDENT_STR_MAXLEN 32
static int g_indent_level;
static char g_indent_str[INDENT_STR_MAXLEN + 1] = "";

static void __pr_out_indent_inc(void)
{
	if (g_indent_level + INDENT_STR_STEP > INDENT_STR_MAXLEN)
		return;
	g_indent_level += INDENT_STR_STEP;
	memset(g_indent_str, ' ', sizeof(g_indent_str));
	g_indent_str[g_indent_level] = '\0';
}

static void __pr_out_indent_dec(void)
{
	if (g_indent_level - INDENT_STR_STEP < 0)
		return;
	g_indent_level -= INDENT_STR_STEP;
	g_indent_str[g_indent_level] = '\0';
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

/* Array and object helpers for consistent formatting */
static void pr_out_array_start(struct dpll *dpll, const char *name)
{
	if (is_json_context()) {
		open_json_array(PRINT_JSON, name);
	} else {
		pr_out("%s  %s:\n", g_indent_str, name);
		__pr_out_indent_inc();
	}
}

static void pr_out_array_end(struct dpll *dpll __attribute__((unused)))
{
	if (is_json_context()) {
		close_json_array(PRINT_JSON, NULL);
	} else {
		__pr_out_indent_dec();
	}
}

static void pr_out_entry_start(struct dpll *dpll __attribute__((unused)))
{
	if (is_json_context())
		open_json_object(NULL);
}

static void pr_out_entry_end(struct dpll *dpll __attribute__((unused)))
{
	if (is_json_context())
		close_json_object();
	else
		pr_out("\n");
}

static void help(void)
{
	pr_err("Usage: dpll [ OPTIONS ] OBJECT { COMMAND | help }\n"
	       "       dpll [ -j[son] ] [ -p[retty] ]\n"
	       "where  OBJECT := { device | pin }\n"
	       "       OPTIONS := { -V[ersion] | -j[son] | -p[retty] }\n");
}

static int cmd_device(struct dpll *dpll);
static int cmd_pin(struct dpll *dpll);

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
	}
	pr_err("Object \"%s\" not found\n", dpll_argv(dpll));
	return -ENOENT;
}

static int dpll_init(struct dpll *dpll)
{
	dpll->ys = ynl_sock_create(&ynl_dpll_family, NULL);
	if (!dpll->ys) {
		pr_err("Failed to connect to DPLL Netlink (DPLL subsystem not available in kernel?)\n");
		return -1;
	}
	return 0;
}

static void dpll_fini(struct dpll *dpll)
{
	if (dpll->ys)
		ynl_sock_destroy(dpll->ys);
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

static void dpll_device_print(struct dpll_device_get_rsp *d)
{
	open_json_object(NULL);

	print_uint(PRINT_ANY, "id", "device id %u", d->id);
	print_string(PRINT_FP, NULL, ":\n", NULL);

	if (d->_len.module_name)
		print_string(PRINT_ANY, "module_name",
			     "  module-name: %s\n", d->module_name);

	if (d->_present.mode)
		print_string(PRINT_ANY, "mode",
			     "  mode: %s\n", dpll_mode_name(d->mode));

	if (d->_present.clock_id)
		print_0xhex(PRINT_ANY, "clock_id",
			    "  clock-id: 0x%llx\n", d->clock_id);

	if (d->_present.type)
		print_string(PRINT_ANY, "type",
			     "  type: %s\n", dpll_type_name(d->type));

	if (d->_present.lock_status)
		print_string(PRINT_ANY, "lock_status",
			     "  lock-status: %s\n", dpll_lock_status_name(d->lock_status));

	if (d->_present.lock_status_error)
		print_string(PRINT_ANY, "lock_status_error",
			     "  lock-status-error: %s\n",
			     dpll_lock_status_error_name(d->lock_status_error));

	if (d->_present.phase_offset_monitor)
		print_bool(PRINT_ANY, "phase_offset_monitor",
			   "  phase-offset-monitor: %s\n",
			   d->phase_offset_monitor);

	if (d->_present.phase_offset_avg_factor)
		print_uint(PRINT_ANY, "phase_offset_avg_factor",
			   "  phase-offset-avg-factor: %u\n",
			   d->phase_offset_avg_factor);

	if (d->_present.temp) {
		if (is_json_context()) {
			print_float(PRINT_JSON, "temperature", NULL,
				    d->temp / 1000.0);
		} else {
			int temp_int = d->temp / 1000;
			int temp_frac = abs(d->temp % 1000);
			pr_out("  temperature: %d.%03d C\n", temp_int, temp_frac);
		}
	}

	/* Print mode-supported array */
	if (d->_count.mode_supported > 0) {
		unsigned int i;
		if (is_json_context()) {
			open_json_array(PRINT_JSON, "mode_supported");
			for (i = 0; i < d->_count.mode_supported; i++) {
				print_string(PRINT_JSON, NULL, NULL,
					     dpll_mode_name(d->mode_supported[i]));
			}
			close_json_array(PRINT_JSON, NULL);
		} else {
			pr_out("  mode-supported:");
			for (i = 0; i < d->_count.mode_supported; i++) {
				pr_out(" %s", dpll_mode_name(d->mode_supported[i]));
			}
			pr_out("\n");
		}
	}

	close_json_object();
}

static int cmd_device_show_id(struct dpll *dpll, __u32 id)
{
	struct dpll_device_get_req *req;
	struct dpll_device_get_rsp *rsp;
	int ret = 0;

	req = dpll_device_get_req_alloc();
	if (!req)
		return -ENOMEM;

	dpll_device_get_req_set_id(req, id);

	rsp = dpll_device_get(dpll->ys, req);
	if (!rsp) {
		pr_err("Failed to get device %u: %s\n", id, dpll->ys->err.msg);
		ret = -1;
		goto out_free_req;
	}

	dpll_device_print(rsp);
	dpll_device_get_rsp_free(rsp);

out_free_req:
	dpll_device_get_req_free(req);
	return ret;
}

static int cmd_device_show_dump(struct dpll *dpll)
{
	struct dpll_device_get_list *devs;
	struct dpll_device_get_rsp *d;

	(void)d; /* used by ynl_dump_foreach macro */

	devs = dpll_device_get_dump(dpll->ys);
	if (!devs) {
		pr_err("Failed to dump devices: %s\n", dpll->ys->err.msg);
		return -1;
	}

	/* Open JSON array for multiple devices */
	open_json_array(PRINT_JSON, "device");

	/* Iterate through all devices - ynl_dump_foreach is a macro that's safe */
	ynl_dump_foreach(devs, d) {
		dpll_device_print(d);
	}

	/* Close JSON array */
	close_json_array(PRINT_JSON, NULL);

	/* Free the list - this is critical to avoid memory leaks */
	dpll_device_get_list_free(devs);
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
	struct dpll_device_set_req *req;
	__u32 id = 0, phase_avg_factor = 0;
	bool has_id = false;
	int ret = 0;

	req = dpll_device_set_req_alloc();
	if (!req)
		return -ENOMEM;

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "id")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("id requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_u32(&id, dpll_argv(dpll), 0)) {
				pr_err("invalid id: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_device_set_req_set_id(req, id);
			has_id = true;
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "phase-offset-monitor")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("phase-offset-monitor requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (dpll_argv_match(dpll, "true") || dpll_argv_match(dpll, "1")) {
				dpll_device_set_req_set_phase_offset_monitor(req, true);
			} else if (dpll_argv_match(dpll, "false") || dpll_argv_match(dpll, "0")) {
				dpll_device_set_req_set_phase_offset_monitor(req, false);
			} else {
				pr_err("invalid phase-offset-monitor value: %s (use true/false)\n",
				       dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "phase-offset-avg-factor")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("phase-offset-avg-factor requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_u32(&phase_avg_factor, dpll_argv(dpll), 0)) {
				pr_err("invalid phase-offset-avg-factor: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_device_set_req_set_phase_offset_avg_factor(req, phase_avg_factor);
			dpll_arg_inc(dpll);
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			ret = -EINVAL;
			goto out;
		}
	}

	if (!has_id) {
		pr_err("device id is required\n");
		ret = -EINVAL;
		goto out;
	}

	ret = dpll_device_set(dpll->ys, req);
	if (ret < 0) {
		pr_err("Failed to set device: %s\n", dpll->ys->err.msg);
		ret = -1;
	}

out:
	dpll_device_set_req_free(req);
	return ret;
}

static int cmd_device_id_get(struct dpll *dpll)
{
	struct dpll_device_id_get_req *req;
	struct dpll_device_id_get_rsp *rsp;
	int ret = 0;

	req = dpll_device_id_get_req_alloc();
	if (!req)
		return -ENOMEM;

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "module-name")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("module-name requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			dpll_device_id_get_req_set_module_name(req, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "clock-id")) {
			__u64 clock_id;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("clock-id requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_u64(&clock_id, dpll_argv(dpll), 0)) {
				pr_err("invalid clock-id: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_device_id_get_req_set_clock_id(req, clock_id);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "type")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("type requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (dpll_argv_match(dpll, "pps")) {
				dpll_device_id_get_req_set_type(req, DPLL_TYPE_PPS);
			} else if (dpll_argv_match(dpll, "eec")) {
				dpll_device_id_get_req_set_type(req, DPLL_TYPE_EEC);
			} else {
				pr_err("invalid type: %s (use pps/eec)\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_arg_inc(dpll);
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			ret = -EINVAL;
			goto out;
		}
	}

	rsp = dpll_device_id_get(dpll->ys, req);
	if (!rsp) {
		pr_err("Failed to get device id: %s\n", dpll->ys->err.msg);
		ret = -1;
		goto out;
	}

	/* Print result */
	if (is_json_context()) {
		open_json_object(NULL);
		print_uint(PRINT_JSON, "id", NULL, rsp->id);
		close_json_object();
	} else {
		printf("%u\n", rsp->id);
	}

	dpll_device_id_get_rsp_free(rsp);

out:
	dpll_device_id_get_req_free(req);
	return ret;
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
	if (capabilities & DPLL_PIN_CAPABILITIES_DIRECTION_CAN_CHANGE)
		pr_out(" direction-can-change");
	if (capabilities & DPLL_PIN_CAPABILITIES_PRIORITY_CAN_CHANGE)
		pr_out(" priority-can-change");
	if (capabilities & DPLL_PIN_CAPABILITIES_STATE_CAN_CHANGE)
		pr_out(" state-can-change");
}

static void dpll_pin_print(struct dpll_pin_get_rsp *p)
{
	unsigned int i;

	open_json_object(NULL);

	print_uint(PRINT_ANY, "id", "pin id %u", p->id);
	print_string(PRINT_FP, NULL, ":\n", NULL);

	if (p->_len.board_label)
		print_string(PRINT_ANY, "board_label",
			     "  board-label: %s\n", p->board_label);

	if (p->_len.panel_label)
		print_string(PRINT_ANY, "panel_label",
			     "  panel-label: %s\n", p->panel_label);

	if (p->_len.package_label)
		print_string(PRINT_ANY, "package_label",
			     "  package-label: %s\n", p->package_label);

	if (p->_present.type)
		print_string(PRINT_ANY, "type",
			     "  type: %s\n", dpll_pin_type_name(p->type));

	if (p->_present.frequency)
		print_lluint(PRINT_ANY, "frequency",
			     "  frequency: %llu Hz\n", p->frequency);

	/* Print frequency-supported ranges */
	if (p->_count.frequency_supported > 0) {
		pr_out_array_start(NULL, "frequency_supported");
		for (i = 0; i < p->_count.frequency_supported; i++) {
			pr_out_entry_start(NULL);
			if (!is_json_context())
				pr_out("%sfrequency-supported: ", g_indent_str);
			if (p->frequency_supported[i]._present.frequency_min)
				print_lluint(PRINT_ANY, "min", "%llu",
					     p->frequency_supported[i].frequency_min);
			if (!is_json_context())
				pr_out("-");
			if (p->frequency_supported[i]._present.frequency_max)
				print_lluint(PRINT_ANY, "max", "%llu",
					     p->frequency_supported[i].frequency_max);
			if (!is_json_context())
				pr_out(" Hz");
			pr_out_entry_end(NULL);
		}
		pr_out_array_end(NULL);
	}

	/* Print capabilities */
	if (p->_present.capabilities) {
		if (is_json_context()) {
			print_hex(PRINT_JSON, "capabilities", NULL, p->capabilities);
		} else {
			pr_out("  capabilities: 0x%x", p->capabilities);
			dpll_pin_capabilities_name(p->capabilities);
			pr_out("\n");
		}
	}

	/* Print phase adjust range and current value */
	if (p->_present.phase_adjust_min)
		print_int(PRINT_ANY, "phase_adjust_min",
			  "  phase-adjust-min: %d\n", p->phase_adjust_min);

	if (p->_present.phase_adjust_max)
		print_int(PRINT_ANY, "phase_adjust_max",
			  "  phase-adjust-max: %d\n", p->phase_adjust_max);

	if (p->_present.phase_adjust)
		print_int(PRINT_ANY, "phase_adjust",
			  "  phase-adjust: %d\n", p->phase_adjust);

	/* Print fractional frequency offset */
	if (p->_present.fractional_frequency_offset)
		print_lluint(PRINT_ANY, "fractional_frequency_offset",
			     "  fractional-frequency-offset: %lld ppb\n",
			     (long long)p->fractional_frequency_offset);

	/* Print esync frequency and related attributes */
	if (p->_present.esync_frequency)
		print_lluint(PRINT_ANY, "esync_frequency",
			     "  esync-frequency: %llu Hz\n", p->esync_frequency);

	if (p->_count.esync_frequency_supported > 0) {
		pr_out_array_start(NULL, "esync_frequency_supported");
		for (i = 0; i < p->_count.esync_frequency_supported; i++) {
			pr_out_entry_start(NULL);
			if (!is_json_context())
				pr_out("%sesync-frequency-supported: ", g_indent_str);
			if (p->esync_frequency_supported[i]._present.frequency_min)
				print_lluint(PRINT_ANY, "min", "%llu",
					     p->esync_frequency_supported[i].frequency_min);
			if (!is_json_context())
				pr_out("-");
			if (p->esync_frequency_supported[i]._present.frequency_max)
				print_lluint(PRINT_ANY, "max", "%llu",
					     p->esync_frequency_supported[i].frequency_max);
			if (!is_json_context())
				pr_out(" Hz");
			pr_out_entry_end(NULL);
		}
		pr_out_array_end(NULL);
	}

	if (p->_present.esync_pulse)
		print_uint(PRINT_ANY, "esync_pulse",
			   "  esync-pulse: %u\n", p->esync_pulse);

	/* Print parent-device relationships */
	if (p->_count.parent_device > 0) {
		pr_out_array_start(NULL, "parent_device");
		for (i = 0; i < p->_count.parent_device; i++) {
			pr_out_entry_start(NULL);
			if (!is_json_context())
				pr_out("%s", g_indent_str);
			if (p->parent_device[i]._present.parent_id)
				print_uint(PRINT_ANY, "parent_id",
					   "id %u", p->parent_device[i].parent_id);
			if (p->parent_device[i]._present.direction)
				print_string(PRINT_ANY, "direction",
					     " direction %s",
					     dpll_pin_direction_name(p->parent_device[i].direction));
			if (p->parent_device[i]._present.prio)
				print_uint(PRINT_ANY, "prio",
					   " prio %u", p->parent_device[i].prio);
			if (p->parent_device[i]._present.state)
				print_string(PRINT_ANY, "state",
					     " state %s",
					     dpll_pin_state_name(p->parent_device[i].state));
			if (p->parent_device[i]._present.phase_offset)
				print_lluint(PRINT_ANY, "phase_offset",
					     " phase-offset %lld",
					     p->parent_device[i].phase_offset);
			pr_out_entry_end(NULL);
		}
		pr_out_array_end(NULL);
	}

	/* Print parent-pin relationships */
	if (p->_count.parent_pin > 0) {
		pr_out_array_start(NULL, "parent_pin");
		for (i = 0; i < p->_count.parent_pin; i++) {
			pr_out_entry_start(NULL);
			if (!is_json_context())
				pr_out("%s", g_indent_str);
			if (p->parent_pin[i]._present.parent_id)
				print_uint(PRINT_ANY, "parent_id",
					   "id %u", p->parent_pin[i].parent_id);
			if (p->parent_pin[i]._present.state)
				print_string(PRINT_ANY, "state",
					     " state %s",
					     dpll_pin_state_name(p->parent_pin[i].state));
			pr_out_entry_end(NULL);
		}
		pr_out_array_end(NULL);
	}

	/* Print reference-sync capable pins */
	if (p->_count.reference_sync > 0) {
		pr_out_array_start(NULL, "reference_sync");
		for (i = 0; i < p->_count.reference_sync; i++) {
			pr_out_entry_start(NULL);
			if (!is_json_context())
				pr_out("%s", g_indent_str);
			if (p->reference_sync[i]._present.id)
				print_uint(PRINT_ANY, "id",
					   "pin %u", p->reference_sync[i].id);
			if (p->reference_sync[i]._present.state)
				print_string(PRINT_ANY, "state",
					     " state %s",
					     dpll_pin_state_name(p->reference_sync[i].state));
			pr_out_entry_end(NULL);
		}
		pr_out_array_end(NULL);
	}

	close_json_object();
}

static int cmd_pin_show_id(struct dpll *dpll, __u32 id)
{
	struct dpll_pin_get_req *req;
	struct dpll_pin_get_rsp *rsp;
	int ret = 0;

	req = dpll_pin_get_req_alloc();
	if (!req)
		return -ENOMEM;

	dpll_pin_get_req_set_id(req, id);

	rsp = dpll_pin_get(dpll->ys, req);
	if (!rsp) {
		pr_err("Failed to get pin %u: %s\n", id, dpll->ys->err.msg);
		ret = -1;
		goto out_free_req;
	}

	dpll_pin_print(rsp);
	dpll_pin_get_rsp_free(rsp);

out_free_req:
	dpll_pin_get_req_free(req);
	return ret;
}

static int cmd_pin_show_dump(struct dpll *dpll, bool has_device_id, __u32 device_id)
{
	struct dpll_pin_get_req_dump *req;
	struct dpll_pin_get_list *pins;
	struct dpll_pin_get_rsp *p;
	int ret = 0;

	(void)p; /* used by ynl_dump_foreach macro */

	req = dpll_pin_get_req_dump_alloc();
	if (!req)
		return -ENOMEM;

	/* If device_id specified, filter pins by device */
	if (has_device_id)
		dpll_pin_get_req_dump_set_id(req, device_id);

	pins = dpll_pin_get_dump(dpll->ys, req);
	if (!pins) {
		pr_err("Failed to dump pins: %s\n", dpll->ys->err.msg);
		ret = -1;
		goto out_free_req;
	}

	/* Open JSON array for multiple pins */
	open_json_array(PRINT_JSON, "pin");

	/* Iterate and print each pin - ynl_dump_foreach handles list traversal safely */
	ynl_dump_foreach(pins, p) {
		dpll_pin_print(p);
	}

	/* Close JSON array */
	close_json_array(PRINT_JSON, NULL);

	/* Critical: free the list to avoid memory leaks */
	dpll_pin_get_list_free(pins);

out_free_req:
	dpll_pin_get_req_dump_free(req);
	return ret;
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
	struct dpll_pin_set_req *req;
	struct dpll_reference_sync *ref_syncs = NULL;
	unsigned int n_ref_syncs = 0;
	struct dpll_pin_parent_device *parent_dev = NULL;
	__u32 id = 0;
	bool has_id = false;
	int ret = 0;

	req = dpll_pin_set_req_alloc();
	if (!req)
		return -ENOMEM;

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "id")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("id requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_u32(&id, dpll_argv(dpll), 0)) {
				pr_err("invalid pin id: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_set_req_set_id(req, id);
			has_id = true;
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "frequency")) {
			__u64 freq;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("frequency requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_u64(&freq, dpll_argv(dpll), 0)) {
				pr_err("invalid frequency: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_set_req_set_frequency(req, freq);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "prio")) {
			__u32 prio;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("prio requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_u32(&prio, dpll_argv(dpll), 0)) {
				pr_err("invalid prio: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_set_req_set_prio(req, prio);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "direction")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("direction requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (dpll_argv_match(dpll, "input")) {
				dpll_pin_set_req_set_direction(req, DPLL_PIN_DIRECTION_INPUT);
			} else if (dpll_argv_match(dpll, "output")) {
				dpll_pin_set_req_set_direction(req, DPLL_PIN_DIRECTION_OUTPUT);
			} else {
				pr_err("invalid direction: %s (use input/output)\n",
				       dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "state")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("state requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (dpll_argv_match(dpll, "connected")) {
				dpll_pin_set_req_set_state(req, DPLL_PIN_STATE_CONNECTED);
			} else if (dpll_argv_match(dpll, "disconnected")) {
				dpll_pin_set_req_set_state(req, DPLL_PIN_STATE_DISCONNECTED);
			} else if (dpll_argv_match(dpll, "selectable")) {
				dpll_pin_set_req_set_state(req, DPLL_PIN_STATE_SELECTABLE);
			} else {
				pr_err("invalid state: %s (use connected/disconnected/selectable)\n",
				       dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "phase-adjust")) {
			__s32 phase_adjust;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("phase-adjust requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_s32(&phase_adjust, dpll_argv(dpll), 0)) {
				pr_err("invalid phase-adjust: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_set_req_set_phase_adjust(req, phase_adjust);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "parent-device")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("parent-device requires device id\n");
				ret = -EINVAL;
				goto out;
			}

			/* Allocate single parent device element */
			parent_dev = calloc(1, sizeof(*parent_dev));
			if (!parent_dev) {
				ret = -ENOMEM;
				goto out;
			}

			/* Parse parent device id */
			if (get_u32(&parent_dev->parent_id, dpll_argv(dpll), 0)) {
				pr_err("invalid parent-device id: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			parent_dev->_present.parent_id = 1;
			dpll_arg_inc(dpll);

			/* Parse optional parent-device attributes */
			while (dpll_argc(dpll) > 0) {
				if (dpll_argv_match(dpll, "direction")) {
					dpll_arg_inc(dpll);
					if (dpll_argc(dpll) == 0) {
						pr_err("direction requires an argument\n");
						ret = -EINVAL;
						goto out;
					}
					if (dpll_argv_match(dpll, "input")) {
						parent_dev->direction = DPLL_PIN_DIRECTION_INPUT;
						parent_dev->_present.direction = 1;
					} else if (dpll_argv_match(dpll, "output")) {
						parent_dev->direction = DPLL_PIN_DIRECTION_OUTPUT;
						parent_dev->_present.direction = 1;
					} else {
						pr_err("invalid direction: %s (use input/output)\n",
						       dpll_argv(dpll));
						ret = -EINVAL;
						goto out;
					}
					dpll_arg_inc(dpll);
				} else if (dpll_argv_match(dpll, "prio")) {
					dpll_arg_inc(dpll);
					if (dpll_argc(dpll) == 0) {
						pr_err("prio requires an argument\n");
						ret = -EINVAL;
						goto out;
					}
					if (get_u32(&parent_dev->prio, dpll_argv(dpll), 0)) {
						pr_err("invalid prio: %s\n", dpll_argv(dpll));
						ret = -EINVAL;
						goto out;
					}
					parent_dev->_present.prio = 1;
					dpll_arg_inc(dpll);
				} else if (dpll_argv_match(dpll, "state")) {
					dpll_arg_inc(dpll);
					if (dpll_argc(dpll) == 0) {
						pr_err("state requires an argument\n");
						ret = -EINVAL;
						goto out;
					}
					if (dpll_argv_match(dpll, "connected")) {
						parent_dev->state = DPLL_PIN_STATE_CONNECTED;
						parent_dev->_present.state = 1;
					} else if (dpll_argv_match(dpll, "disconnected")) {
						parent_dev->state = DPLL_PIN_STATE_DISCONNECTED;
						parent_dev->_present.state = 1;
					} else if (dpll_argv_match(dpll, "selectable")) {
						parent_dev->state = DPLL_PIN_STATE_SELECTABLE;
						parent_dev->_present.state = 1;
					} else {
						pr_err("invalid state: %s (use connected/disconnected/selectable)\n",
						       dpll_argv(dpll));
						ret = -EINVAL;
						goto out;
					}
					dpll_arg_inc(dpll);
				} else {
					/* Not a parent-device attribute, break to parse next top-level option */
					break;
				}
			}
		} else if (dpll_argv_match(dpll, "esync-frequency")) {
			__u64 esync_freq;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("esync-frequency requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_u64(&esync_freq, dpll_argv(dpll), 0)) {
				pr_err("invalid esync-frequency: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_set_req_set_esync_frequency(req, esync_freq);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "reference-sync")) {
			struct dpll_reference_sync *new_ref_syncs;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("reference-sync requires pin id\n");
				ret = -EINVAL;
				goto out;
			}

			/* Reallocate array to add one more element */
			new_ref_syncs = realloc(ref_syncs,
						(n_ref_syncs + 1) * sizeof(*ref_syncs));
			if (!new_ref_syncs) {
				ret = -ENOMEM;
				goto out;
			}
			ref_syncs = new_ref_syncs;

			/* Initialize new element */
			memset(&ref_syncs[n_ref_syncs], 0, sizeof(ref_syncs[n_ref_syncs]));

			/* Parse reference-sync pin id */
			__u32 ref_pin_id;
			if (get_u32(&ref_pin_id, dpll_argv(dpll), 0)) {
				pr_err("invalid reference-sync pin id: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_reference_sync_set_id(&ref_syncs[n_ref_syncs], ref_pin_id);
			dpll_arg_inc(dpll);

			/* Parse optional reference-sync state */
			if (dpll_argc(dpll) > 0 && dpll_argv_match(dpll, "state")) {
				dpll_arg_inc(dpll);
				if (dpll_argc(dpll) == 0) {
					pr_err("state requires an argument\n");
					ret = -EINVAL;
					goto out;
				}
				if (dpll_argv_match(dpll, "connected")) {
					dpll_reference_sync_set_state(&ref_syncs[n_ref_syncs],
								      DPLL_PIN_STATE_CONNECTED);
				} else if (dpll_argv_match(dpll, "disconnected")) {
					dpll_reference_sync_set_state(&ref_syncs[n_ref_syncs],
								      DPLL_PIN_STATE_DISCONNECTED);
				} else if (dpll_argv_match(dpll, "selectable")) {
					dpll_reference_sync_set_state(&ref_syncs[n_ref_syncs],
								      DPLL_PIN_STATE_SELECTABLE);
				} else {
					pr_err("invalid state: %s\n", dpll_argv(dpll));
					ret = -EINVAL;
					goto out;
				}
				dpll_arg_inc(dpll);
			}

			/* Increment counter */
			n_ref_syncs++;
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			ret = -EINVAL;
			goto out;
		}
	}

	if (!has_id) {
		pr_err("pin id is required\n");
		ret = -EINVAL;
		goto out;
	}

	/* Set reference-sync array if any were specified */
	if (n_ref_syncs > 0)
		__dpll_pin_set_req_set_reference_sync(req, ref_syncs, n_ref_syncs);

	/* Set parent device if specified */
	if (parent_dev)
		__dpll_pin_set_req_set_parent_device(req, parent_dev, 1);

	ret = dpll_pin_set(dpll->ys, req);
	if (ret < 0) {
		pr_err("Failed to set pin: %s\n", dpll->ys->err.msg);
		ret = -1;
	}

out:
	free(ref_syncs);
	free(parent_dev);
	dpll_pin_set_req_free(req);
	return ret;
}

static int cmd_pin_id_get(struct dpll *dpll)
{
	struct dpll_pin_id_get_req *req;
	struct dpll_pin_id_get_rsp *rsp;
	int ret = 0;

	req = dpll_pin_id_get_req_alloc();
	if (!req)
		return -ENOMEM;

	/* Parse arguments */
	while (dpll_argc(dpll) > 0) {
		if (dpll_argv_match(dpll, "module-name")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("module-name requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_id_get_req_set_module_name(req, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "clock-id")) {
			__u64 clock_id;
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("clock-id requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			if (get_u64(&clock_id, dpll_argv(dpll), 0)) {
				pr_err("invalid clock-id: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_id_get_req_set_clock_id(req, clock_id);
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "board-label")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("board-label requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_id_get_req_set_board_label(req, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "panel-label")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("panel-label requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_id_get_req_set_panel_label(req, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "package-label")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("package-label requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			dpll_pin_id_get_req_set_package_label(req, dpll_argv(dpll));
			dpll_arg_inc(dpll);
		} else if (dpll_argv_match(dpll, "type")) {
			dpll_arg_inc(dpll);
			if (dpll_argc(dpll) == 0) {
				pr_err("type requires an argument\n");
				ret = -EINVAL;
				goto out;
			}
			/* Parse pin type */
			if (dpll_argv_match(dpll, "mux")) {
				dpll_pin_id_get_req_set_type(req, DPLL_PIN_TYPE_MUX);
			} else if (dpll_argv_match(dpll, "ext")) {
				dpll_pin_id_get_req_set_type(req, DPLL_PIN_TYPE_EXT);
			} else if (dpll_argv_match(dpll, "synce-eth-port")) {
				dpll_pin_id_get_req_set_type(req, DPLL_PIN_TYPE_SYNCE_ETH_PORT);
			} else if (dpll_argv_match(dpll, "int-oscillator")) {
				dpll_pin_id_get_req_set_type(req, DPLL_PIN_TYPE_INT_OSCILLATOR);
			} else if (dpll_argv_match(dpll, "gnss")) {
				dpll_pin_id_get_req_set_type(req, DPLL_PIN_TYPE_GNSS);
			} else {
				pr_err("invalid type: %s\n", dpll_argv(dpll));
				ret = -EINVAL;
				goto out;
			}
			dpll_arg_inc(dpll);
		} else {
			pr_err("unknown option: %s\n", dpll_argv(dpll));
			ret = -EINVAL;
			goto out;
		}
	}

	rsp = dpll_pin_id_get(dpll->ys, req);
	if (!rsp) {
		pr_err("Failed to get pin id: %s\n", dpll->ys->err.msg);
		ret = -1;
		goto out;
	}

	/* Print result */
	if (is_json_context()) {
		open_json_object(NULL);
		print_uint(PRINT_JSON, "id", NULL, rsp->id);
		close_json_object();
	} else {
		printf("%u\n", rsp->id);
	}

	dpll_pin_id_get_rsp_free(rsp);

out:
	dpll_pin_id_get_req_free(req);
	return ret;
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
