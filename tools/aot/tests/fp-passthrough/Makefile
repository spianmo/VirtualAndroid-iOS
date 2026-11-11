# Bare-metal passthrough differential test (see run.sh).
NDK ?= $(HOME)/Library/Android/sdk/ndk/29.0.13113456/toolchains/llvm/prebuilt/darwin-x86_64/bin
OUT ?= .
CC = $(NDK)/clang --target=aarch64-none-elf
CFLAGS = -O2 -ffreestanding -fno-builtin -nostdlib -mgeneral-regs-only -mstrict-align \
         -fno-stack-protector -Wall $(EXTRA)
ASFLAGS = -march=armv8.2-a+crypto+crc

$(OUT)/pttest.elf: start.S ops.S pttest.c link.ld
	$(CC) $(ASFLAGS) -c start.S -o $(OUT)/start.o
	$(CC) $(ASFLAGS) -c ops.S -o $(OUT)/ops.o
	$(CC) $(CFLAGS) -c pttest.c -o $(OUT)/pttest.o
	$(NDK)/ld.lld -T link.ld -o $@ $(OUT)/start.o $(OUT)/ops.o $(OUT)/pttest.o
