TARGET = sbios.bin

.PHONY: all run clean run_nhda

all: $(TARGET) boot.bin

$(TARGET): bios.asm
	nasm -f bin bios.asm -o $(TARGET)

boot.bin: boot.asm
	nasm -f bin boot.asm -o boot.bin


run: all
	qemu-system-i386 -bios sbios.bin -hda boot.bin -serial stdio

run_nhda: all
	qemu-system-i386 -bios sbios.bin -serial stdio

clean:
	rm -f $(TARGET)
	rm -f boot.bin
