ERL_CFLAGS ?= -I$(ERL_EI_INCLUDE_DIR)
ERL_LDFLAGS ?= -L$(ERL_EI_LIBDIR) -lei

CFLAGS += -O3 -fPIC -Wall -Wextra -Wno-unused-parameter $(ERL_CFLAGS)
LDFLAGS += -shared $(ERL_LDFLAGS)

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
