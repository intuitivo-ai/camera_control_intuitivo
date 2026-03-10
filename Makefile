ERL_CFLAGS ?= -I$(ERL_EI_INCLUDE_DIR)
ERL_LDFLAGS ?= -L$(ERL_EI_LIBDIR) -lei

# When cross-compiling for Nerves, pkg-config needs to search inside
# the target sysroot rather than the host system.
ifdef CROSSCOMPILE
NERVES_SDK_SYSROOT ?= $(shell $(CC) -print-sysroot 2>/dev/null)

ifneq ($(NERVES_SDK_SYSROOT),)
PKG_CONFIG_SYSROOT_DIR = $(NERVES_SDK_SYSROOT)
PKG_CONFIG_PATH = $(NERVES_SDK_SYSROOT)/usr/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_PATH
endif
endif

GST_CFLAGS = $(shell pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0 2>/dev/null)
GST_LDFLAGS = $(shell pkg-config --libs gstreamer-1.0 gstreamer-app-1.0 2>/dev/null)

# Fallback: if pkg-config didn't find GStreamer, try standard sysroot paths
ifeq ($(GST_CFLAGS),)
ifdef NERVES_SDK_SYSROOT
GST_CFLAGS = -I$(NERVES_SDK_SYSROOT)/usr/include/gstreamer-1.0 \
             -I$(NERVES_SDK_SYSROOT)/usr/include/glib-2.0 \
             -I$(NERVES_SDK_SYSROOT)/usr/lib/glib-2.0/include \
             -I$(NERVES_SDK_SYSROOT)/usr/lib/aarch64-linux-gnu/glib-2.0/include
GST_LDFLAGS = -lgstreamer-1.0 -lgstapp-1.0 -lgobject-2.0 -lglib-2.0
endif
endif

CFLAGS += -O3 -fPIC -Wall -Wextra -Wno-unused-parameter $(ERL_CFLAGS) $(GST_CFLAGS)
LDFLAGS += -shared $(ERL_LDFLAGS) $(GST_LDFLAGS)

ifeq ($(CROSSCOMPILE),)
ifeq ($(shell uname),Darwin)
	LDFLAGS += -undefined dynamic_lookup -flat_namespace
endif
endif

# Linux shared lib (not macOS dylib)
ifneq ($(CROSSCOMPILE),)
LDFLAGS := $(filter-out -dynamiclib,$(LDFLAGS))
endif

# MIX_APP_PATH is set by elixir_make and points to _build/<env>/lib/camera_control
# When building as a dependency, the .so must end up there so the runtime finds it.
PRIV_DIR = $(MIX_APP_PATH)/priv
SRC_DIR = c_src
NIF_SO = $(PRIV_DIR)/camera_nif.so

C_SRCS = $(wildcard $(SRC_DIR)/*.c)
OBJS = $(C_SRCS:.c=.o)

all: $(PRIV_DIR) $(NIF_SO)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(NIF_SO): $(OBJS)
	$(CC) $(OBJS) -o $@ $(LDFLAGS)

$(SRC_DIR)/%.o: $(SRC_DIR)/%.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(NIF_SO) $(OBJS)
