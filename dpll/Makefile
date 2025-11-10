# SPDX-License-Identifier: GPL-2.0
include ../config.mk

# iproute2 libraries
LIBNETLINK=../lib/libutil.a ../lib/libnetlink.a

TARGETS :=
ALLOBJS :=

# Check if libmnl is available
ifeq ($(HAVE_MNL),y)

DPLLOBJ = dpll.o
DPLLLINKOBJ = dpll_link.o
TARGETS += dpll dpll_link
ALLOBJS += dpll.o dpll_link.o

# libmnl flags
dpll.o: CFLAGS += -I../include -I../include/uapi
dpll_link.o: CFLAGS += -I../include -I../include/uapi

else
$(warning "libmnl not found, skipping dpll tool build")
endif

# Default CFLAGS for all objects
CFLAGS += -I../include -I../include/uapi

all: $(TARGETS) $(LIBS)

dpll: $(DPLLOBJ) $(LIBNETLINK)
	$(QUIET_LINK)$(CC) $^ $(LDFLAGS) $(LDLIBS) -o $@

dpll_link: $(DPLLLINKOBJ)
	$(QUIET_LINK)$(CC) $^ $(LDFLAGS) $(LDLIBS) -lmnl -o $@

install: all
	for i in $(TARGETS); \
	do install -m 0755 $$i $(DESTDIR)$(SBINDIR); \
	done

clean:
	rm -f $(ALLOBJS) $(TARGETS)
