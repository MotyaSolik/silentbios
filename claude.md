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
- `boot.asm` — test disk, **stage 1**: the MBR sector (512 bytes, ends in
  `0x55AA`, tight on space, though it barely does anything now - see
  below). Prints one line, reads `stage2.bin` via `int 13h` `AH=0x02`,
  jumps to it. `incbin "stage2.bin"` pads the rest of the file out to
  `STAGE2_SECTORS` sectors, followed by 2 more sectors of known test data
  (`disklayout.inc` has the exact sector numbers - keep both files
  `%include`ing it rather than hardcoding sector numbers in two places).
- `stage2.asm` / `stage2.bin` — test disk, **stage 2**: a verbose,
  human-narrated walkthrough of `int 10h`/`int 16h`/`int 13h`, loaded at
  `0x9000` by stage 1. This is where new interactive/manual tests belong -
  it's not sector-size-constrained the way `boot.asm` is (just bump
  `STAGE2_SECTORS` in `disklayout.inc` if it outgrows the reserved space -
  `nasm` will fail loudly with a negative `times` if it does). Existed
  because a human asked to actually *watch* the tests run and understand
  the output at a glance, not just decode compact machine-checkable labels
  like `K00:hI1` - see the git history for what that looked like before.
- `disklayout.inc` — `STAGE2_SECTORS` / `DATA_SECTOR` `equ`s, `%include`d
  by both `boot.asm` and `stage2.asm` so their sector numbers can't drift
  out of sync with each other.
- `Makefile` — build automation (inspect it, don't assume targets;
  `stage2.bin` must be built before `boot.bin`, which `incbin`s it - the
  Makefile already encodes that dependency, don't reorder it).
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
- **"The screen stopped updating" is not the same as "execution stopped."**
  When a screenshot shows the same frame no matter how long you wait,
  don't assume a hang/deadlock and start staring at the last `int` call
  before the freeze - that's what the VGA-scroll bug looked like, and the
  real cause (writes past row 24, off the visible 4000-byte text buffer)
  was nowhere near where the "hang" appeared to be. Bisect for real: drop
  a tiny serial-only checkpoint helper (wait-for-THRE, write one fixed
  byte, no other state touched) at several points in the suspect code and
  read the trail back - if the markers all fire in order, the CPU isn't
  stuck, the *display* is lying to you.

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
- **The `print_string` helper in `boot.asm`/`stage2.asm` clobbers `BX`, not
  just `AX`** — it unconditionally does `xor bh,bh` / `mov bl,0x07` at its
  own top (leftover from modeling a real BIOS teletype call convention).
  If you stash a value in `BX` to survive a `print_string` call in between
  reading it and printing it, it's gone - use `CX` or `DX` instead (neither
  is touched by `print_string`, `print_char_al`, or `print_dec_al`). This
  bit twice while writing `stage2.asm`: once as silently-wrong displayed
  numbers (`mode=0 cols=7` instead of `3`/`80`), once as a comparison
  (`cmp bl,1`) that could never see the value it was supposed to see,
  because `print_string` reset `bl` to `0x07` between the capture and the
  check. Same root cause as the `mul`-clobbers-`DX` note above: know
  exactly what a helper you're calling leaves alone before relying on it.
- **`vga_char_out` scrolls now — it didn't used to.** Before this was
  added, output that crossed row 24 just kept computing further offsets
  and writing there, silently past the visible 4000-byte text buffer; see
  the testing-methodology note above about how that surfaced ("hang" that
  wasn't one). If you're touching cursor/newline logic, `vga_scroll_up` is
  what makes the `.check_scroll` label after the newline math not
  optional - don't route new newline-producing paths around it.
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
  return through them (a "get"-style call, leave them alone). `int12h_isr`
  takes this to its logical extreme: it's `mov ax,[ss:RAM_MEM_KB]` /
  `iret` and nothing else, no register saves at all, since real `int 12h`
  has no `AH` dispatch and no other registers to preserve. `int15h_isr`
  follows the normal 3-ISR pattern despite only having one real function
  (`AH=0x88`) plus a `patch_stack_cf`-based "unsupported" fallback.
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
disk boot via raw ATA PIO, `int 10h` AH=0x0E/0x00/0x02/0x03/0x0F/0x09,
`int 16h` AH=0x00/0x01, `int 13h` AH=0x00/0x02/0x08, `int 12h`, `int 15h`
AH=0x88 - the last three added specifically to get GRUB booting, see
below).

`int 10h` `AH=0x00` (set mode 3 only), `AH=0x02`/`0x03` (cursor, including
the real hardware CRTC cursor via ports `0x3D4`/`0x3D5`), and `AH=0x0F`
(get mode) are implemented and verified end-to-end in QEMU — cursor math
confirmed exactly against a VGA screenshot. `RAM_VIDEO_MODE` (`0x050F`)
holds the current mode for the get-mode call to report.

`int 16h` `AH=0x00` (blocking read) and `AH=0x01` (non-blocking check, peek
- doesn't consume) are implemented and verified in QEMU, including Shift
and the peek/consume distinction, driven via monitor `sendkey`/`sendkey
shift-x`. RAM state: `RAM_KBD_SHIFT` (`0x0510`), `RAM_KBD_PENDING`/`_CHAR`/
`_SCAN` (`0x0511`-`0x0513`) hold a single-slot decoded-key buffer filled by
`kbd_service`, which advances the same E0/F0 state machine as `setup_menu`
one raw byte at a time (non-blocking). Only the main alphanumeric block has
ASCII mappings (`kbd_ascii_lo`/`kbd_ascii_hi`, indices `0x00`-`MAX_SCAN`);
numpad/function keys and extended (E0-prefixed) keys are silently
unmapped, same philosophy as `int10h_isr`'s `.unsupported` path.

`int 13h` `AH=0x00` (reset), `AH=0x02` (read sectors, CHS→LBA), and
`AH=0x08` (get params) are implemented and verified: first via a dedicated
serial hex-dump test (CF/AL/AH/CH/CL/DH/DL for a success case, a
multi-sector read across a sector boundary, and an induced "unsupported
function" error) to catch a `patch_stack_cf` polarity bug *before* it
could hide behind a plausible-looking screenshot (see the gotcha above) -
none was found, everything was correct on the first pass this time. CHS→
LBA uses an unqueried geometry picked by drive number (`int13h_read_
sectors`/`int13h_get_params` both check `DL`) since there's no `IDENTIFY
DEVICE`: `DL<0x80` → `SPT_FLOPPY=18`/`HPC_FLOPPY=2` (standard 1.44 MB),
`DL>=0x80` → `SPT_HDD=63`/`HPC_HDD=16`. The values are stashed in RAM
(`RAM_GEOM_SPT`/`RAM_GEOM_HPC`, `0x0514`/`0x0515` - transient scratch, not
persistent state, just a workaround for running out of registers mid-
calculation) rather than a register, since the LBA math already uses
ax/bx/cx/dx/si/di/bp for other things. Sectors are read one at a time,
looping the same wait-BSY/wait-DRQ/transfer-256-words protocol as
`ata_read_mbr` rather than relying on the controller to deliver a
multi-sector burst without re-checking DRQ. Unsupported functions
explicitly set `CF=1`/`AH=1` (unlike `int10h`/`int16h`'s silent no-op) -
for disk I/O, silently claiming success when nothing happened is worse
than an honest error.

**The floppy/HDD geometry split above was found empirically, not
guessed**: downloaded a real FreeDOS 1.4 boot floppy image (confirmed
valid by booting it under plain QEMU's own BIOS first, to rule out a bad
download before blaming our code) and tried it under this project's
`-bios`. It hung with a blank screen after the initial MBR jump - the
usual "did it actually hang, or is it just not drawing anything"
ambiguity from the `int16h` gotcha, so the fix was the same: add a
temporary `dbg13_dump` call at the top of `int13h_isr` that serial-logs
every `AH`/`AL`/`CH`/`CL`/`DH`/`DL` it receives (removed again after -
this was diagnostic only, never committed). That showed FreeDOS's own
boot sector calling `AH=0x02` with `DL=0x00` and CHS values implying an
18-sectors/2-heads disk, while `int13h_read_sectors` was translating
that CHS via the hard-disk `63/16` constants - reading real, valid,
CF=0 data from the *wrong* LBA. After the DL-based fix, the same log
showed it walking through far more of the disk (119 `int 13h` calls
across multiple cylinders vs. ~22 before, looping) before going quiet -
real progress, confirmed by a regression run against the existing HDD-
geometry test disk to make sure `DL=0x80` behavior didn't change. It
still doesn't reach a working `A:\>` prompt, though - something past the
boot sector needs *something*. `int 15h` memory detection was the prime
suspect, so it got implemented next: `int 12h` (returns `RAM_MEM_KB`,
now populated by `post_memory_test`) and `int 15h` `AH=0x88` (honestly
returns `AX=0` - extended memory above 1 MB was never tested, so
claiming a number would be worse than admitting it's unverified; other
`int 15h` functions return `CF=1`/`AH=0x86`, matching real BIOS
behavior for "unsupported"). Both were verified independently first
(a small dedicated test disk checking `int12h`'s AX and `int15h`
`AH=0x88`/`AH=0x00`'s CF+AX+AH - correct on the first pass) before even
touching FreeDOS again. Then, re-running FreeDOS with a call-logger on
all three interrupts (`int12h`/`int13h`/`int15h`) showed it **never
calls `int 12h` or `int 15h` at all** - it makes the same ~119 `int 13h`
calls as before and goes quiet. So the geometry fix was real progress,
but memory detection wasn't the blocker; whatever runs after that last
disk read is FreeDOS's own logic, not a missing BIOS service, and
diagnosing further would mean disassembling FreeDOS itself rather than
extending this project - a genuinely different, bigger task, so this is
where the FreeDOS experiment stopped (for now) - **but see the GRUB
section right below, which succeeded** and turned out to be the more
productive test case, precisely because it names its missing dependency
instead of silently hanging.

**GRUB boots to an interactive `grub rescue>` prompt on this BIOS.**
Tried on a hunch that a portable, text-mode-first bootloader designed to
run on decades of inconsistent real BIOSes would be a better test case
than a full OS - it was. Unlike FreeDOS, GRUB *degrades gracefully* and
*prints specific error messages* instead of hanging silently, which
turned this from "guess and instrument our own ISR" into "read the
error, fix the exact thing it names" three times in a row:

1. Built a test image: `grub-mkrescue --output=grub_test.iso <dir with
   boot/grub/grub.cfg>` (needs `xorriso`; the resulting ISO is isohybrid
   - bootable via `-hda` directly, not just `-cdrom`). Verified it boots
   under plain QEMU's own BIOS first (rules out a bad build). First try
   under this project's `-bios`: printed `GRUB loading..` (proof its
   boot.img actually ran our `int 10h`/`int 13h`) then went visually
   quiet. `int13h_isr`/`int12h_isr`/`int15h_isr` all get a shared
   temporary `dbg_tagX` logger (removed after, never committed) for this
   kind of investigation - same trick as the FreeDOS one, generalized to
   log any/all of the three at once with a one-letter tag per interrupt.
2. The log showed GRUB probing `int13h AH=0x41` (check LBA extensions)
   first - we don't support it, so it correctly got `CF=1` and GRUB fell
   back to CHS (`AH=0x02`), exactly per spec, no fix needed there. Then
   217,158 `int16h AH=0x01` polls and nothing else - not a hang, GRUB was
   sitting at its menu/timeout loop the whole time, just not drawing
   anything. Cross-referencing the `int10h` log: 137 calls to `AH=0x09`
   (write char+attribute at cursor, no cursor move - used for colored
   menu borders/boxes) that we silently no-op'd. Added
   `int10h_write_char_attr` (`AH=0x09`) - straightforward, no flag
   return needed, just writes `CX` copies of `AL`/`BL` starting at
   `RAM_VGA_POS` without touching it.
3. Next run got much further and printed an actual GRUB kernel error:
   `kern/mm.c:grub_memalign:552: out of memory`. GRUB's heap allocator
   sizes itself from `int15h AH=0x88` (extended memory) - which
   previously returned an honest `0`, starving it. Rather than
   implementing A20-gate + real probing above 1 MB, checked whether the
   platform already exposes the answer: wrote a one-off test disk that
   reads CMOS offsets `0x17`/`0x18`/`0x30`/`0x31`/`0x34`/`0x35` directly
   and prints them. `0x34`/`0x35` (memory above 16 MB, in 64 KB units)
   came back as exactly QEMU's default 128 MB RAM - confirming the
   platform *does* populate the standard PC/AT CMOS memory-size fields,
   the same way real firmware does, and a from-scratch BIOS can just
   read them instead of probing. `int15h_ext_mem_kb` now reads CMOS
   `0x17` (low byte) + `0x18` (high byte) directly via the existing
   `cmos_read_byte` - the standard field for "KB above 1 MB", naturally
   saturating at `0xFFFF` (~64 MB), which matches `AH=0x88`'s own
   historical ceiling anyway.
4. Next run: `error: kern/fs.c:grub_fs_probe:122: unknown filesystem`
   (repeated per device probed), then `Entering rescue mode...` and a
   live `grub rescue>` prompt - typed characters echo back in real time
   via `sendkey`. The filesystem error is expected and unrelated to the
   BIOS: the test image is an ISO9660 layout (built for El Torito CD
   boot) being fed in as a raw `-hda` disk, so GRUB's own filesystem
   drivers correctly don't recognize what's on it. The BIOS layer -
   `int10h`/`int13h`/`int15h`/`int16h` all exercised together by real,
   unmodified GRUB code - worked end to end.

Each of the three fixes above was found by literally reading what GRUB
printed, not by guessing - the same "don't assume, verify" discipline as
the rest of this project, just pointed at someone else's code for once.

**Fixed on the same GRUB test, but only surfaced once a real user tried
it on real hardware**: with a properly `grub-install`'d disk (real MBR
partition table + FAT32, built with actual root/loop-mount - this sandbox
has no raw block device access, `cat /dev/sda3` is `Permission denied`
here, so that build had to happen on the user's own machine), GRUB
reached its real menu, confirming the ISO9660 `grub rescue>` case above
really was just a test-image artifact. But then: typing letters at the
`grub>` prompt worked, and **Enter did nothing** - reproducibly, with
window focus confirmed. A dedicated test (below) proved `int16h` itself
returns the right values (`AL=0x0D`/`AH=0x5A` for Enter, exactly
correct), so the bug had to be in what GRUB does with a *correct*
response. The answer: `int 16h` is specified to always return **Scan Set
1** in `AH`, regardless of what the keyboard controller actually speaks -
that's the whole point of the BIOS abstraction layer. This project's
`kbd_service` decodes genuine Scan Set 2 (see the empirical-scan-code
gotcha elsewhere in this file) but was passing that raw Set 2 byte
straight through into `AH` instead of translating it. GRUB trusts `AL`
(ASCII) for ordinary typing - which is why letters worked - but
recognizes special keys like Enter by matching `AH` against its own Set
1 table; a raw Set 2 `0x5A` matches nothing there, so Enter silently did
nothing while every other key looked fine. Fix: `kbd_scan2to1`, a table
in the same `0x00`-`MAX_SCAN` index space as `kbd_ascii_lo`/`kbd_ascii_hi`
(same file, right after them), applied in `kbd_service`'s `.have_char`
right before storing `RAM_KBD_PENDING_SCAN` - `bx` is still the original
Set 2 index at that point, so it's a direct second lookup, no rework of
the decode logic itself. Verified with a tiny dedicated test disk
(`dbgenter.asm`-style: read a key, print `AL`/`AH` in hex, loop) against
several keys including Shift+letter (confirms shift changes `AL` only,
never the scan code, matching real keyboards) before trusting the fix.
If a future bug looks like "some keys work, an unrelated-seeming one
doesn't, and the failure is specific to code that inspects the *raw*
value not the ASCII" - check whether it's another `AH` vs `AL` /
Set-1-vs-what-we-actually-decode mismatch before looking anywhere else.

**One more gap found chasing the same GRUB session**: with Enter fixed,
`ls` at the `grub>` prompt listed a *huge* number of drives (`hd4`
through `hd14`+, plus `(cd)`) instead of the one or two actually
attached. Cause: `int13h_read_sectors` always addressed the primary
channel's *master* drive - `DL` was read for geometry (floppy vs HDD)
but never used to select master vs slave in the drive/head register
(port `0x1F6`). GRUB enumerates by probing many possible BIOS drive
numbers; every probe landed on the same physical `-hda`, so it looked
like a dozen identical disks, and a genuinely different attached disk
(`-hdb`) was completely unreachable regardless of which `DL` addressed
it. Fix: `RAM_GEOM_DRIVEBIT` (`0x0518`, same "transient scratch, not
persistent state" pattern as `RAM_GEOM_SPT`/`_HPC` - computed once near
the top of `int13h_read_sectors` while `DL` is still intact, since the
LBA math's `mul` clobbers it later) holds `0x10` (slave) or `0`
(master), OR'd into the `0x1F6` write in `.sector_loop`. Only `DL=0x81`
(the primary channel's other drive, matching QEMU's `-hdb`) maps to
slave; higher drive numbers would need a secondary ATA channel
(`0x170`-`0x177`) this project doesn't implement, so they quietly fall
back to master rather than erroring - same philosophy as everywhere else
unsupported input is silently treated as "closest reasonable thing."

**Caught its own bug while writing the fix, before it ever reached
testing**: the first version computed the drivebit into `al` right
before the existing `push ax` that preserves the caller's requested
sector count (also in `al`) - clobbering the real input before it got
saved, silently breaking every multi-sector read (`stage2.bin` stopped
loading entirely - `boot.asm` hung at "loading stage 2" with zero further
progress). Caught by running the existing regression test immediately
after the change, per this project's own rule of testing every change,
not just the new code path. Fixed by computing the drivebit into `bl`
instead (`bx` is free at that point - its only job so far was `mov di,
bx` to capture the destination buffer offset) so it never touches the
register the very next instruction needs intact.

**That drivebit fix alone wasn't enough** - `ls` in GRUB still listed a
dozen-plus phantom drives after it. Root cause: every `int 13h` function
answered success (`CF=0`) for literally any `DL`, master/slave or not -
the drivebit fix made `DL=0x81` reach a genuinely different physical
disk, but `DL=0x82`, `0x83`, ... still "worked" too, just silently
aliased back to master. GRUB's drive enumeration relies on *some*
function - likely `AH=0x08` or `AH=0x41` - returning `CF=1` for a
nonexistent drive to know when to stop probing; we never did. Fixed by
checking `DL` once, in `int13h_isr`, before dispatching to any function
at all (`cmp dl, 0x82` / `jb .drive_ok`, else fall into the exact same
`CF=1`/`AH=1` tail already used for unsupported `AH` functions) - only
`DL<0x82` (floppy geometry, master, or slave - everything this project's
single ATA channel can actually reach) gets a real answer. Verified with
a small test disk calling `AH=0x08` for `DL=0x80/0x81/0x82/0xFF` and
checking `CF`: first two succeed, last two correctly fail.

The test disk (`boot.asm`+`stage2.asm`) is a real two-stage loader now,
not one packed sector: stage 1 reads stage 2 via `int 13h` `AH=0x02` and
jumps to it, which is both a demonstration of that call and the reason
`stage2.asm` can afford verbose, narrated output instead of compact
machine-checkable labels. All three interrupts get exercised end-to-end
this way with a VGA screenshot, plus live `sendkey`/`sendkey shift-x`
keyboard input for the `int 16h` section. `vga_char_out` gained scrolling
(`vga_scroll_up`) specifically because this longer test overran 25 rows -
see the gotchas above for both that and the `print_string`-clobbers-`BX`
bug that showed up while writing it.

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