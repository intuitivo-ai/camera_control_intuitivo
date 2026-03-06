ERL_CFLAGS ?= -I$(ERL_EI_INCLUDE_DIR)
ERL_LDFLAGS ?= -L$(ERL_EI_LIBDIR) -lei

# GStreamer dependencies
GST_CFLAGS = $(shell pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0)
GST_LDFLAGS = $(shell pkg-config --libs gstreamer-1.0 gstreamer-app-1.0)

CFLAGS += -O3 -fPIC -Wall -Wextra -Wno-unused-parameter $(ERL_CFLAGS) $(GST_CFLAGS)
LDFLAGS += -shared -dynamiclib $(ERL_LDFLAGS) $(GST_LDFLAGS)

ifeq ($(CROSSCOMPILE),)
ifeq ($(shell uname),Darwin)
	LDFLAGS += -undefined dynamic_lookup -flat_namespace
endif
endif

PRIV_DIR = priv
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
