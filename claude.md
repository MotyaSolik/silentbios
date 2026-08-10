# SilentBIOS — project context for Claude Code

This is a from-scratch x86 BIOS written in 16-bit real-mode NASM assembly.
No base BIOS, no video BIOS, no option ROMs underneath — every piece of
hardware (VGA, keyboard controller, ATA disk, CMOS/RTC) is programmed
directly at the port level. The finished image is exactly 64 KB and drops
in as a legacy BIOS ROM (reset vector at the end jumps to the entry point).

## Files in this repo

- `bios.asm` — the BIOS source (main file, ~1300+ lines)
- `font.bin` — 8×16 bitmap font (256 chars × 16 bytes), pulled in via
  `incbin "font.bin"` at assembly time. Must sit next to `bios.asm`.
- `boot.asm` / `boot.bin` — a tiny test MBR (512 bytes, ends in `0x55AA`)
  used to verify disk boot and the `int 10h` handler. Not part of the BIOS
  itself, just a verification tool.
- `Makefile` — build automation (inspect it, don't assume targets)
- `README.md` / `README_ru.md` — project docs (EN/RU), already edited by
  hand — check these for the canonical feature list before writing new ones.

## Build

```
nasm -f bin bios.asm -o bios.bin
```
(or whatever the Makefile wraps this as — check it first).

## Testing methodology — READ THIS BEFORE CHANGING CODE

Every feature in this project was built by actually running it in
`qemu-system-i386` and checking real output — not just "it assembles."
Please keep doing that. Specifically:

- **Serial output**: `qemu-system-i386 -bios bios.bin -serial stdio -display none -no-reboot`
  is the fast sanity check for POST/boot messages.
- **VGA/visual verification**: use `-display none -monitor unix:/tmp/q.sock,server,nowait`
  and drive it from a Python script that connects to the monitor socket,
  sends commands (`screendump /path/out.ppm`, `sendkey <key>`,
  `system_reset`), then convert the `.ppm` to `.png` (PIL) and actually look
  at it. Don't assume a feature works from code review alone — screenshot it.
- **Keyboard testing**: use monitor `sendkey up`/`down`/`ret`/`esc` etc.
  Note: this BIOS's keyboard controller emits **Scan Code Set 2**, not Set 1
  (confirmed empirically, not from docs) — arrow keys come in as `E0 72`
  (down) / `E0 75` (up), Enter as `0x5A`, Esc as `0x76`, and the "key
  release" byte (`F0 xx`) ends in the *same* byte as the press code, so a
  break-flag is needed to avoid double-firing.
- **Background QEMU + sandbox gotcha**: if you're running in a sandboxed
  tool environment, background processes (even with `nohup`) can get reaped
  between separate tool invocations. Do the full sequence — start QEMU,
  send keys, screendump, and (if needed) reconnect after `system_reset` —
  all inside **one** shell invocation/script, not split across multiple
  tool calls.
- **`-no-reboot` gotcha**: this flag makes QEMU *exit* on a CPU-triggered
  reset instead of actually resetting — don't use it when testing
  `system_reset` / CMOS-persistence-across-reset behavior, only for
  one-shot POST checks.
- **Testing disk boot**: `qemu-system-i386 -bios bios.bin -hda boot.bin ...`
  — remember the BIOS always goes through the setup menu first (waits for
  Esc) before attempting to read the MBR, so `sendkey esc` is needed to
  reach the boot-attempt code path in an automated test.

## Architecture notes / non-obvious gotchas

- **ROM is not RAM.** `CS`/`DS` point at the BIOS image itself (Flash on
  real hardware — read-only in practice). *Every* piece of mutable state
  (VGA cursor, number-formatting buffer, toggle flags, menu selection,
  keyboard break-flag, etc.) lives in real RAM: the free area right after
  the IVT (`0x000`–`0x3FF`) and BDA (`0x400`–`0x4FF`), starting at `0x500`,
  addressed via `ss:` (SS is permanently `0x0000`). If you add a new
  variable that gets *written*, it must go there, defined as an `equ`
  offset — never as a `db`/`dw` label inside the code/data section (that's
  ROM and writes to it silently vanish).
- **No video BIOS underneath us** — entering 80×25 text mode, loading the
  font into Character Generator RAM (video plane 2), and programming the
  DAC palette are all done by hand, register by register. The Attribute
  Controller's internal palette registers must map straight to DAC indices
  0x00–0x0F (not the classic EGA 0x38–0x3F offset trick) because the DAC
  loading loop only programs entries 0–15.
- **`mul` clobbers all of DX`, not just the high word conceptually — if you
  need a value out of DX/DL before a `mul`/`div`, extract it *first*. (This
  exact bug caused the setup menu to render at column 0 regardless of the
  requested column, early in the project.)
- **There's no `int 13h` to call** — disk access (`ata_read_mbr`) talks to
  the primary ATA controller ports (`0x1F0`–`0x1F7`) directly, PIO mode,
  LBA28, no interrupts.
- **`int 10h` register-preservation convention**: the ISR only saves
  `ds/es/si/di/bp` — NOT `ax/bx/cx/dx`, because "get" functions (cursor
  position, video mode) must return their result through those registers
  to the caller. If you add more int 10h functions, decide per-function
  whether it needs to preserve incoming ax/bx/cx/dx (a "set"-style call,
  push/pop them internally) or return through them (a "get"-style call,
  leave them alone).

## Current feature status

See `README.md` for the full list (COM1 serial, VGA text mode + font,
POST diagnostics, Scan-Set-2 keyboard + setup menu, CMOS/NVRAM persistence,
disk boot via raw ATA PIO, `int 10h` AH=0x0E/0x00/0x02/0x03/0x0F).

`int 10h` `AH=0x00` (set mode 3 only), `AH=0x02`/`0x03` (cursor, including
the real hardware CRTC cursor via ports `0x3D4`/`0x3D5`), and `AH=0x0F`
(get mode) are implemented and verified end-to-end in QEMU via a test in
`boot.asm` (set mode 3 + clear, set cursor to row 5/col 10, print via
AH=0x0E, read cursor back via AH=0x03 and print it, read mode+columns back
via AH=0x0F and print those) — checked against a VGA screenshot, cursor
math confirmed exactly. `RAM_VIDEO_MODE` (`0x050F`) holds the current mode
for the get-mode call to report.

## Style/conventions to keep

- Comments in the source are in Russian; keep new ones consistent with that
  unless told otherwise.
- Keep functions self-contained where possible (push/pop their own scratch
  registers) unless there's a specific calling-convention reason not to
  (see the int 10h note above).
- Don't add features "for looks" — this project deliberately skipped a
  signed debug-key/HWID-unlock scheme because it's open source and gating
  features behind an embedded secret doesn't hold up once the ROM can be
  disassembled. Keep that reasoning in mind if similar ideas come up.