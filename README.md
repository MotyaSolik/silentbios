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
  (`font.bin`), pulled in at assembly time via `incbin`. Output past the
  last row scrolls the screen up a line rather than running off the
  visible buffer.
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
  CRTC cursor via ports `0x3D4`/`0x3D5`), `AH=0x0F` (get video mode), and
  `AH=0x09` (write character+attribute without moving the cursor — added
  because GRUB uses it to draw its menu's colored border; without it GRUB
  ran fine but drew nothing).
- **A real `int 16h` handler** (keyboard services), decoding the same raw
  Scan Set 2 polling used by the setup menu into ASCII, with Shift support.
  `AH=0x00` reads a character (blocking), `AH=0x01` checks for one without
  consuming it (non-blocking, reports through `ZF`). Numpad, function keys,
  and other non-ASCII keys are silently ignored. The scan code returned in
  `AH` is translated to Scan Set 1 — the set `int 16h` is specified to
  return regardless of what the controller actually speaks — found
  necessary when GRUB, tested on real hardware by a user, typed letters
  fine (it trusts `AL`) but Enter did nothing (it recognizes special keys
  by `AH`, and got a raw Set 2 byte matching nothing in its Set 1 table).
- **A real `int 13h` handler** (disk services), so loaded bootloaders/OSes
  can read more than just the MBR without talking to the ATA controller
  themselves. `AH=0x00` (reset), `AH=0x02` (read sectors, CHS — translated
  to LBA28 against an assumed geometry, since there's no `IDENTIFY
  DEVICE`), `AH=0x08` (get drive parameters). The assumed geometry depends
  on the drive number: `DL<0x80` (floppy) gets `18 sectors/track, 2 heads`
  (standard 1.44 MB), `DL>=0x80` (HDD) gets `63 sectors/track, 16 heads` —
  found empirically by trying to boot a real FreeDOS floppy image and
  watching, via a temporary serial log of every `int 13h` call, exactly
  which CHS values its boot sector requested. Reports errors honestly: an
  unsupported function returns `CF=1`/`AH=1` rather than silently claiming
  success, since for disk I/O that's more dangerous than for video/keyboard.
- **`int 12h`** (conventional memory size) and **`int 15h` `AH=0x88`**
  (extended memory size). `int 12h` reports whatever `post_memory_test`
  actually measured at POST (0–640 KB). `int 15h` `AH=0x88` reads the
  answer straight out of the standard PC/AT CMOS bytes `0x17`/`0x18`
  (extended memory in KB), which the platform — real hardware or QEMU —
  fills in itself; this project doesn't probe memory above 1 MB on its
  own (no A20 gate/unreal-mode support). Other `int 15h` functions return
  `CF=1`/`AH=0x86` ("unsupported function"), matching real BIOS behavior
  for the same case.

## It boots GRUB

A real GRUB install — proper MBR partition table, FAT32 partition,
`grub-install --target=i386-pc` — boots to GRUB's actual colored menu on
this BIOS, on real hardware, not just in QEMU. (An earlier attempt with a
`grub-mkrescue` ISO9660 image only reached the `grub rescue>` fallback
shell with an "unknown filesystem" error — a quirk of feeding a CD-layout
image in as a raw disk, not a BIOS limitation; a properly-partitioned
disk image doesn't hit it.)

Four fixes got it here, every one found by trying it and reading the
exact failure instead of guessing: `int 13h`'s floppy/HDD geometry
split, `int 10h AH=0x09` for GRUB's menu border, real `int 15h AH=0x88`
numbers instead of an honest zero, and — found only once a real user
tried it on real hardware — translating the keyboard's Scan Set 2 codes
to Scan Set 1 before returning them in `int 16h`'s `AH`. That last one
mattered because GRUB trusts `AL` (ASCII) for regular typing but `AH`
(scan code) to recognize special keys like Enter; letters worked long
before Enter did.

A fifth gap showed up chasing this further: `int 13h` always talked to
the primary channel's *master* drive, no matter what `DL` asked for, so
GRUB — which probes many possible BIOS drive numbers while looking for
its own disk — saw the same physical disk echoed back under a dozen
different names, and a second attached disk (`-hdb` in QEMU) was
unreachable no matter which drive number addressed it. `int 13h AH=0x02`
now sets the drive-select bit in port `0x1F6` based on `DL` (`0x80` /
`DL<0x80` → master, `0x81` → slave — the primary channel's other drive,
matching QEMU's `-hda`/`-hdb`). Verified with two attached disks carrying
different known content at LBA 0 and reading both by `DL`.

That alone didn't stop GRUB's `ls` from listing a dozen-plus phantom
drives, though — every `int 13h` function still answered *success* for
any `DL`, master/slave or not, so drive numbers we don't support looked
just as "present" as the two real ones. `int13h_isr` now checks `DL`
before dispatching to any function at all: only `DL<0x82` (floppy,
master, or slave) get a real answer; anything else — a secondary ATA
channel this project doesn't implement — honestly returns `CF=1` (drive
not present), the same way real BIOSes signal "no such drive" during
enumeration.

## Layout

| File | Purpose |
|---|---|
| `bios.asm` | BIOS source |
| `font.bin` | 8×16 bitmap font (256 chars × 16 bytes), pulled in via `incbin` |
| `sbios.bin` | Prebuilt image, 65536 bytes |
| `boot.asm` / `boot.bin` | Test disk image, stage 1: the MBR sector. A minimal loader — prints a line, then reads `stage2.bin` off the disk via `int 13h` `AH=0x02` and jumps to it. Not part of the BIOS itself. |
| `stage2.asm` / `stage2.bin` | Test disk image, stage 2: a human-readable, narrated walkthrough of `int 10h`/`int 16h`/`int 13h` (loaded by stage 1, doesn't fit in one sector). `boot.bin` embeds it via `incbin` plus 2 more data sectors — run `make run` and read the screen. |
| `disklayout.inc` | Shared sector-layout constants (`%include`d by both `boot.asm` and `stage2.asm`) so the two files' sector numbers can't drift apart. |
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

After Esc, `make run` boots the test disk, which prints a plain-language,
step-by-step narration of every `int 10h`/`int 16h`/`int 13h` call it
makes (`stage2.asm`) — type a few keys when it asks, and read the `-> OK`
lines to see what's actually being exercised.

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
- **The BIOS's own boot code can't call `int 13h`** — it's the thing
  *providing* that service, not consuming it, so its own MBR read
  (`ata_read_mbr`) still talks to the ATA controller ports directly.
  Loaded code (a bootloader, a second stage, an OS) *can* call `int 13h`,
  same as it would on real hardware.
- **`int 16h` `AH=0x01` and `int 13h` (`AH=0x00`/`0x02`/`0x08`) return
  their result through a flag** (`ZF` / `CF`) — but `iret` restores `FLAGS`
  from what the CPU pushed onto the stack when the interrupt was invoked,
  not from the live flags register. So the ISR patches that stacked
  `FLAGS` word directly right before `iret` (a small shared helper,
  `patch_stack_cf`, does this for all three `int 13h` functions). Get the
  polarity backwards here and everything *looks* like it's working
  (characters/data decode correctly) while the caller's `jz`/`jnz`/`jc`
  reads the opposite of reality — this exact bug shipped once for `int
  16h` and was only caught by dumping raw register/flag values over
  serial, not by reading the code. `int 13h` was designed with that
  lesson in mind and verified the same way before trusting a screenshot.
- **Unsupported `int 13h` functions report `CF=1`/`AH=1` explicitly**,
  unlike `int 10h`/`int 16h`'s silent no-op for anything unrecognized.
  For video/keyboard, silently doing nothing is the safer default; for
  disk I/O, silently claiming success when nothing happened is worse than
  an honest error — the caller might act on data that was never read.
- **Text past the last row used to just vanish.** `vga_char_out`'s newline
  handler only ever computed the *next* row's offset — nothing stopped it
  from computing a position past row 24 and writing there anyway, off the
  visible 4000-byte text buffer. Harmless while every screen fit in 25
  lines (POST, the setup menu); surfaced as soon as a longer test program
  printed more than that — the display appeared to hang, but the CPU kept
  running fine (confirmed with a serial checkpoint trail showing execution
  sailing straight through to completion while the screen stayed frozen).
  Fixed with a `vga_scroll_up` that the write path calls once the cursor
  would cross row 25: copy rows 1–24 up into 0–23, blank the new row 24.

## Known limitations

- The `int 10h` handler supports `AH=0x0E`, `AH=0x00` (mode `0x03` only —
  other mode numbers are silently ignored), `AH=0x02`/`0x03`, `AH=0x0F`,
  and `AH=0x09`. Other video functions — notably VESA/VBE (`AH=0x4F`,
  needed for linear-framebuffer graphics modes) — are silently ignored,
  which rules out any GUI-mode OS (tried KolibriOS reasoning through this
  before even attempting it: it needs VBE for its framebuffer, a much
  bigger gap than anything text-mode DOS/GRUB hit).
- The `int 16h` handler only supports `AH=0x00`/`0x01`, and only produces
  ASCII for the main alphanumeric block (no numpad, function keys, or other
  non-ASCII keys). Extended (`E0`-prefixed) keys are skipped rather than
  decoded, which means an extended key can alias a numpad key with the same
  trailing scan code — accepted as a simplification, not fixed.
- The `int 13h` handler supports `AH=0x00`/`0x02`/`0x08` only, translates
  CHS to LBA against an assumed (not queried) geometry picked from the
  drive number alone (`18/2` for `DL<0x80`, `63/16` for `DL>=0x80`), and
  doesn't implement `IDENTIFY DEVICE` — `AH=0x08` always reports a generic
  maximum-cylinder value regardless of the actual disk image size. Sectors
  are read one at a time (no true multi-sector burst transfer), which is
  simpler and more robust but slower.
- A real FreeDOS floppy boots noticeably further with the `int 13h`
  geometry fix (its boot sector's own reads now land on the right
  sectors) but still doesn't reach a working prompt — and, confirmed via
  a temporary call-log, it's not because of `int 12h`/`int 15h` either:
  FreeDOS never calls them at all. Whatever it does after its last
  `int 13h` read is its own internal logic, not a missing BIOS service;
  pinning that down would mean disassembling FreeDOS itself. GRUB (see
  above) turned out to be the more useful test case — its error messages
  named the exact missing piece each time, instead of a silent hang.
- Disk boot (the BIOS's own MBR load) only reads LBA sector 0 — no
  partition table parsing.
- The keyboard is read by polling, not IRQ/PIC-driven — fine for a setup
  menu, not enough for a real multitasking OS.
- A signed "debug key" / HWID-unlock scheme was considered and deliberately
  left out: the project is open source, and gating features behind an
  embedded secret doesn't hold up once the ROM can be disassembled — anyone
  can just pull the check out.

## License

MIT — see [LICENSE](LICENSE).