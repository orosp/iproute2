# SPDX-License-Identifier: GPL-2.0
include ../config.mk

# Check if YNL library is available
ifeq ($(HAVE_YNL),y)

# Path to kernel YNL library (KERNEL_SRC is set by configure)
YNL_DIR = $(KERNEL_SRC)/tools/net/ynl
YNL_GEN_DIR = $(YNL_DIR)/generated
YNL_LIB_DIR = $(YNL_DIR)/lib

# iproute2 libraries (like devlink)
LIBNETLINK=../lib/libutil.a ../lib/libnetlink.a

DPLLOBJ = dpll.o
TARGETS += dpll
LDLIBS += $(YNL_LIB_DIR)/ynl.a $(YNL_GEN_DIR)/protos.a -lm

# Add YNL includes to all CFLAGS
# Note: -I../include should come from parent Makefile, but we add it explicitly to be safe
CFLAGS += -I../include -I../include/uapi -I$(YNL_LIB_DIR) -I$(YNL_GEN_DIR) -I$(KERNEL_SRC)/include/uapi

else
$(warning "YNL library not found, skipping dpll tool build")
$(warning "  Set KERNEL_SRC to point to kernel source tree or run ./configure")
TARGETS :=
DPLLOBJ :=
endif

all: $(TARGETS) $(LIBS)

dpll: $(DPLLOBJ) $(LIBNETLINK)
	$(QUIET_LINK)$(CC) $^ $(LDFLAGS) $(LDLIBS) -o $@

install: all
	for i in $(TARGETS); \
	do install -m 0755 $$i $(DESTDIR)$(SBINDIR); \
	done

clean:
	rm -f $(DPLLOBJ) $(TARGETS)
