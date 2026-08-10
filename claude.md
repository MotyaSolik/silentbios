# SilentBIOS — project context for Claude Code

This is a from-scratch x86 BIOS written in 16-bit real-mode NASM assembly.
No base BIOS, no video BIOS, no option ROMs underneath — every piece of
hardware (VGA, keyboard controller, ATA disk, CMOS/RTC) is programmed
directly at the port level. The finished image is exactly 64 KB and drops
in as a legacy BIOS ROM (reset vector at the end jumps to the entry point).

## Files in this repo

- `bios.asm` — the BIOS source (main file, ~2000+ lines)
- `font.bin` — 8×16 bitmap font (256 chars × 16 bytes), pulled in via
  `incbin "font.bin"` at assembly time. Must sit next to `bios.asm`.
- `boot.asm` / `boot.bin` — a 3-sector test disk image (MBR sector, 512
  bytes, ends in `0x55AA`, tight on space — check remaining slack before
  adding more test code to it; plus 2 appended data sectors with a known
  text pattern, used by the `int 13h` read test) used to verify disk boot
  and the `int 10h`/`int 16h`/`int 13h` handlers. Not part of the BIOS
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
- **The BIOS's own boot code can't call `int 13h`** — disk access from
  inside the BIOS itself (`ata_read_mbr`) still talks to the primary ATA
  controller ports (`0x1F0`–`0x1F7`) directly, PIO mode, LBA28, no
  interrupts. That's a separate code path from the `int 13h` *handler*
  (which loaded code calls) — the BIOS can't consume the service it's the
  one providing.
- **`int 10h`/`int 16h`/`int 13h` register-preservation convention**: all
  three ISRs only save `ds/es/si/di/bp` — NOT `ax/bx/cx/dx`, because "get"
  functions (cursor position, video mode, read-key, disk params) must
  return their result through those registers to the caller. If you add
  more functions, decide per-function whether it needs to preserve
  incoming ax/bx/cx/dx (a "set"-style call, push/pop them internally) or
  return through them (a "get"-style call, leave them alone).
- **Returning a flag (not just registers) from a software interrupt**:
  `int 16h` `AH=0x01` and `int 13h` (`AH=0x00`/`0x02`/`0x08`) have to
  communicate their result through a flag (`ZF` / `CF`), but `iret`
  restores `FLAGS` from what the CPU pushed onto the stack at `int` time,
  not from the live flags register — so the ISR must patch that stacked
  `FLAGS` word directly right before `iret` (see `int16h_isr` `.fn_01`
  inline, and the shared `patch_stack_cf` helper `int13h_isr` calls after
  each function — same trick, factored out since three functions needed
  it; note the extra stack slot from `call`ing it means the FLAGS offset
  from `bp` is different from the inline version. Both use `vga_set_hw_
  cursor`-style stack math: `push bp` / `mov bp, sp` to get an addressable
  frame, since `sp` itself can't be used as a base register in 16-bit
  addressing). **Get the polarity backwards and it's a silent bug**:
  characters/data still decode correctly (that part doesn't touch flags),
  but the caller's `jz`/`jnz`/`jc` sees the opposite of reality. This
  exact bug shipped once for `int 16h` - the "found a key" screenshot even
  looked plausible at a glance - and was only caught by a temporary serial
  hex-dump test that printed raw `ZF`/`AL`/`AH`/`RAM_KBD_PENDING` on every
  poll iteration, not by re-reading the code. `int 13h`'s `patch_stack_cf`
  was verified the same way (dump CF/AL/AH over serial for a success case,
  an induced-error case, and a multi-sector read) *before* trusting a
  screenshot, and came out correct on the first pass. If a future
  flag-returning function acts weird, reach for that kind of dump before
  re-deriving the stack offsets by hand again.

## Current feature status

See `README.md` for the full list (COM1 serial, VGA text mode + font,
POST diagnostics, Scan-Set-2 keyboard + setup menu, CMOS/NVRAM persistence,
disk boot via raw ATA PIO, `int 10h` AH=0x0E/0x00/0x02/0x03/0x0F, `int 16h`
AH=0x00/0x01, `int 13h` AH=0x00/0x02/0x08).

`int 10h` `AH=0x00` (set mode 3 only), `AH=0x02`/`0x03` (cursor, including
the real hardware CRTC cursor via ports `0x3D4`/`0x3D5`), and `AH=0x0F`
(get mode) are implemented and verified end-to-end in QEMU via a test in
`boot.asm` (set mode 3 + clear, set cursor to row 5/col 10, print via
AH=0x0E, read cursor back via AH=0x03 and print it, read mode+columns back
via AH=0x0F and print those) — checked against a VGA screenshot, cursor
math confirmed exactly. `RAM_VIDEO_MODE` (`0x050F`) holds the current mode
for the get-mode call to report.

`int 16h` `AH=0x00` (blocking read) and `AH=0x01` (non-blocking check, peek
- doesn't consume) are implemented and verified in QEMU, including Shift
and the peek/consume distinction (`boot.asm`'s `K00`/`K01` sections, driven
via monitor `sendkey`/`sendkey shift-x`). RAM state: `RAM_KBD_SHIFT`
(`0x0510`), `RAM_KBD_PENDING`/`_CHAR`/`_SCAN` (`0x0511`-`0x0513`) hold a
single-slot decoded-key buffer filled by `kbd_service`, which advances the
same E0/F0 state machine as `setup_menu` one raw byte at a time (non-
blocking). Only the main alphanumeric block has ASCII mappings
(`kbd_ascii_lo`/`kbd_ascii_hi`, indices `0x00`-`MAX_SCAN`); numpad/function
keys and extended (E0-prefixed) keys are silently unmapped, same philosophy
as `int10h_isr`'s `.unsupported` path.

`int 13h` `AH=0x00` (reset), `AH=0x02` (read sectors, CHS→LBA), and
`AH=0x08` (get params) are implemented and verified: first via a dedicated
serial hex-dump test (CF/AL/AH/CH/CL/DH/DL for a success case, a
multi-sector read across a sector boundary, and an induced "unsupported
function" error) to catch a `patch_stack_cf` polarity bug *before* it
could hide behind a plausible-looking screenshot (see the gotcha above) -
none was found, everything was correct on the first pass this time - then
end-to-end in `boot.asm` (`13/08`/`13/02` sections) with a VGA screenshot.
CHS→LBA uses a fixed, unqueried `SPT=63`/`HPC=16` geometry (`equ`s in
`bios.asm`) since there's no `IDENTIFY DEVICE`; sectors are read one at a
time, looping the same wait-BSY/wait-DRQ/transfer-256-words protocol as
`ata_read_mbr` rather than relying on the controller to deliver a
multi-sector burst without re-checking DRQ. Unsupported functions
explicitly set `CF=1`/`AH=1` (unlike `int10h`/`int16h`'s silent no-op) -
for disk I/O, silently claiming success when nothing happened is worse
than an honest error.

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