# SilentBIOS

vibecode shit by Claude

A minimal x86 BIOS written from scratch in 16-bit real-mode NASM assembly.
No base BIOS, no video BIOS, no option ROMs underneath it — every piece of
hardware it talks to (VGA, keyboard controller, ATA disk, CMOS/RTC) is
programmed directly at the port level. The finished image is exactly 64 KB
and drops in as a legacy BIOS ROM: the reset vector at the very end of the
file jumps to the entry point, exactly like on a real motherboard.

Every feature below was built and verified against `qemu-system-i386` at
each step — not just "it assembles," but checked against serial output and
VGA screenshots along the way.

## Features

- **COM1 serial output** (9600 8N1) — a video-independent diagnostic channel.
- **VGA text mode, 80×25**, brought up entirely by hand: Sequencer, CRTC,
  Graphics Controller, Attribute Controller, and DAC palette are all
  programmed directly, since there's no video BIOS/option ROM to do it for
  us. The 8×16 bitmap font is generated and shipped as a separate binary
  (`font.bin`), pulled in at assembly time via `incbin`.
- **POST diagnostics**: a conventional-memory test (0–640 KB, in 64 KB
  blocks) and an 8042 keyboard-controller self-test (command `0xAA`).
- **Interactive setup menu** — arrow keys / Enter / Esc, keyboard read by
  direct polling of ports `0x60`/`0x64` (Scan Code Set 2, with make/break
  byte filtering). The Serial/VGA output toggles are wired into the actual
  output routines, not just drawn on screen.
- **CMOS/NVRAM persistence** — toggle settings are saved to CMOS (ports
  `0x70`/`0x71`) and survive a hardware reset, just like on a real
  battery-backed motherboard.
- **Disk boot** — reads the MBR (LBA sector 0) straight off the primary ATA
  controller in PIO mode (ports `0x1F0`–`0x1F7`), checks for the `0x55AA`
  boot signature, and hands off control at `0000:7C00` with registers set up
  the way a real BIOS would (`DS=ES=SS=0`, `SP=0x7C00`, `DL=0x80`).
- **A real `int 10h` handler**, installed as an actual interrupt vector in
  the IVT. Loaded code/OS can just call `int 10h` the normal way instead of
  poking video memory/ports directly. Supported functions: `AH=0x0E`
  (teletype output), `AH=0x00` (set video mode — mode `0x03` only),
  `AH=0x02`/`0x03` (set/get cursor position, including the real hardware
  CRTC cursor via ports `0x3D4`/`0x3D5`), and `AH=0x0F` (get video mode).
- **A real `int 16h` handler** (keyboard services), decoding the same raw
  Scan Set 2 polling used by the setup menu into ASCII, with Shift support.
  `AH=0x00` reads a character (blocking), `AH=0x01` checks for one without
  consuming it (non-blocking, reports through `ZF`). Numpad, function keys,
  and other non-ASCII keys are silently ignored.

## Layout

| File | Purpose |
|---|---|
| `bios.asm` | BIOS source |
| `font.bin` | 8×16 bitmap font (256 chars × 16 bytes), pulled in via `incbin` |
| `sbios.bin` | Prebuilt image, 65536 bytes |
| `boot.asm` / `boot.bin` | A tiny test MBR used to verify disk boot and `int 10h` — not part of the BIOS itself, just a verification tool |
| `README_ru.md` | README on russian |

## Building

```bash
make
```

`font.bin` must sit next to `sbios.asm` — it's pulled in at build time via
`incbin`, no separate step needed.

## Running

```bash
# No disk attached: POST, VGA, setup menu, then boot attempt reports
# "No bootable disk found"
make run_nhda

# With the test boot sector attached
make run
```

In the setup menu: Up/Down navigates, Enter toggles the selected item (or
exits, on the Exit item), Esc exits setup and continues the normal boot
sequence (the disk MBR read).

## Design notes

A few non-obvious things worth knowing if you're going to read or extend the
source:

- **ROM is not RAM.** `CS`/`DS` point at the BIOS image itself, which on
  real hardware is Flash — readable, but writes to it don't behave like
  ordinary memory. Every piece of mutable state (VGA cursor, the number
  buffer, toggle flags, menu selection index, etc.) therefore lives in real
  RAM: the free area right after the IVT (`0x000`–`0x3FF`) and the BDA
  (`0x400`–`0x4FF`), starting at `0x500`, addressed via `ss:` (since `SS`
  always points at segment `0x0000`).
- **There's no video BIOS underneath us**, so entering 80×25 text mode,
  loading the font into Character Generator RAM (video memory plane 2), and
  programming the DAC palette are all done by hand, register by register.
- **The keyboard controller emits Scan Code Set 2**, not Set 1 — confirmed
  empirically, not assumed from documentation. The key-handling code
  accounts for that, plus the fact that a key's "release" code (`F0 xx`)
  ends in the same byte as its "press" code.
- **There's no `int 13h` to call** — we *are* the BIOS, so disk access
  (`ata_read_mbr`) talks to the ATA controller ports directly instead of
  going through a software interrupt.
- **`int 16h` `AH=0x01` returns its result through the `ZF` flag** — but
  `iret` restores `FLAGS` from what the CPU pushed onto the stack when
  `int 16h` was invoked, not from the live flags register. So the ISR
  patches that stacked `FLAGS` word directly (bit 6) right before `iret`.
  Get the polarity backwards here and everything *looks* like it's working
  (characters decode correctly) while the caller's `jz`/`jnz` reads the
  opposite of reality — this exact bug shipped once and was only caught by
  dumping raw register/flag values over serial, not by reading the code.

## Known limitations

- The `int 10h` handler supports `AH=0x0E`, `AH=0x00` (mode `0x03` only —
  other mode numbers are silently ignored), `AH=0x02`/`0x03`, and `AH=0x0F`.
  Other video functions are silently ignored.
- The `int 16h` handler only supports `AH=0x00`/`0x01`, and only produces
  ASCII for the main alphanumeric block (no numpad, function keys, or other
  non-ASCII keys). Extended (`E0`-prefixed) keys are skipped rather than
  decoded, which means an extended key can alias a numpad key with the same
  trailing scan code — accepted as a simplification, not fixed.
- Disk boot only reads LBA sector 0 (the MBR) — no partition table parsing.
- The keyboard is read by polling, not IRQ/PIC-driven — fine for a setup
  menu, not enough for a real multitasking OS.
- A signed "debug key" / HWID-unlock scheme was considered and deliberately
  left out: the project is open source, and gating features behind an
  embedded secret doesn't hold up once the ROM can be disassembled — anyone
  can just pull the check out.

## License

MIT — see [LICENSE](LICENSE).