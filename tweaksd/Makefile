CC = zig cc
TARGET = arm-linux-musleabi
VERSION := $(shell cat ../VERSION 2>/dev/null || echo 0.0.0)
CFLAGS = -target $(TARGET) -Os -Wall -Wextra -DNDEBUG -DVERSION=\"$(VERSION)\"
LDFLAGS = -target $(TARGET) -static

SRCS = main.c httpd.c tweaks.c dump.c usb.c log.c jsmn.c
OBJS = $(SRCS:.c=.o)
BIN = tweaksd

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(BIN)

.PHONY: all clean
