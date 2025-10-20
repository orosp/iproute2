# SPDX-License-Identifier: GPL-2.0
include ../config.mk

# iproute2 libraries (like devlink)
LIBNETLINK=../lib/libutil.a ../lib/libnetlink.a

TARGETS :=
ALLOBJS :=

# Check if YNL library is available
ifeq ($(HAVE_YNL),y)

# Path to kernel YNL library (KERNEL_SRC is set by configure)
YNL_DIR = $(KERNEL_SRC)/tools/net/ynl
YNL_GEN_DIR = $(YNL_DIR)/generated
YNL_LIB_DIR = $(YNL_DIR)/lib

DPLLOBJ = dpll.o
TARGETS += dpll
ALLOBJS += $(DPLLOBJ)
YNL_LDLIBS = $(YNL_LIB_DIR)/ynl.a $(YNL_GEN_DIR)/protos.a -lm

# Add YNL includes to CFLAGS for dpll.c
dpll.o: CFLAGS += -I../include -I../include/uapi -I$(YNL_LIB_DIR) -I$(YNL_GEN_DIR) -I$(KERNEL_SRC)/include/uapi

else
$(warning "YNL library not found, skipping dpll tool build")
$(warning "  Set KERNEL_SRC to point to kernel source tree or run ./configure")
endif

# Check if libmnl is available
ifeq ($(HAVE_MNL),y)

DPLLMNLOBJ = dpll-mnl.o ../devlink/mnlg.o
TARGETS += dpll-mnl
ALLOBJS += dpll-mnl.o

# libmnl flags
dpll-mnl.o: CFLAGS += -I../include -I../include/uapi

else
$(warning "libmnl not found, skipping dpll-mnl tool build")
endif

# Default CFLAGS for all objects
CFLAGS += -I../include -I../include/uapi

all: $(TARGETS) $(LIBS)

dpll: $(DPLLOBJ) $(LIBNETLINK)
	$(QUIET_LINK)$(CC) $^ $(LDFLAGS) $(LDLIBS) $(YNL_LDLIBS) -o $@

dpll-mnl: $(DPLLMNLOBJ) $(LIBNETLINK)
	$(QUIET_LINK)$(CC) $^ $(LDFLAGS) $(LDLIBS) -o $@

install: all
	for i in $(TARGETS); \
	do install -m 0755 $$i $(DESTDIR)$(SBINDIR); \
	done

clean:
	rm -f $(ALLOBJS) $(TARGETS) dpll-mnl
