# SPDX-License-Identifier: GPL-2.0-only
CC      ?= cc
CFLAGS  ?= -O2 -g
CFLAGS  += -std=gnu11 -Wall \
           -Isrc/include -Isrc/compat -Isrc/frontends -Isrc/bridge -Isrc/board -Isrc/ts -Isrc/core -Isrc \
           $(shell pkg-config --cflags libusb-1.0)
LDLIBS  += $(shell pkg-config --libs libusb-1.0) -framework AudioToolbox

SRCS := $(wildcard src/cli/*.c) $(wildcard src/core/*.c) \
        src/ts/psi.c \
        src/bridge/dib0700.c \
        src/board/stk8096gp.c \
        src/frontends/dib8000.c src/frontends/dib0090.c src/frontends/dibx000_common.c \
        src/compat/compat.c src/compat/int_log.c
OBJS := $(SRCS:src/%.c=build/%.o)

manzanavision: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

# the vendored kernel files take their module name from the file name
build/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -DKBUILD_MODNAME='"$(notdir $*)"' -MMD -MP -c -o $@ $<

compile_commands.json: Makefile
	@printf '[\n' > $@; sep=''; for s in $(SRCS); do \
	  printf '%s{"directory":"%s","file":"%s","command":"%s %s -DKBUILD_MODNAME=\\"x\\" -c %s"}\n' \
	    "$$sep" "$(CURDIR)" "$$s" "$(CC)" "$(CFLAGS)" "$$s" >> $@; sep=','; done; printf ']\n' >> $@

clean:
	rm -rf build manzanavision

.PHONY: clean
-include $(OBJS:.o=.d)
