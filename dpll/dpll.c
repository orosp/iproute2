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
	       "where  OBJECT := { device }\n"
	       "       OPTIONS := { -V[ersion] | -j[son] | -p[retty] }\n");
}

static int cmd_device(struct dpll *dpll);

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

static int cmd_device(struct dpll *dpll)
{
	if (dpll_argv_match(dpll, "help") || dpll_no_arg(dpll)) {
		cmd_device_help();
		return 0;
	} else if (dpll_argv_match(dpll, "show")) {
		dpll_arg_inc(dpll);
		return cmd_device_show(dpll);
	}

	pr_err("Command \"%s\" not found\n", dpll_argv(dpll) ? dpll_argv(dpll) : "");
	return -ENOENT;
}
