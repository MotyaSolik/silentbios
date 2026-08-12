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

**That `DL` rejection then immediately broke real GRUB booting entirely**
- a properly `grub-install`'d disk, freshly rebuilt with no install
errors, started printing `GRUB loadingRead Error` on *this project's*
BIOS even with a single disk attached (`DL=0x80` only, no `-hdb`,
no phantom-drive complexity involved at all). Reproduced first in this
sandbox against the known-good `grub_test.iso` (confirmed working at the
previous commit, broken at this one) before touching any code - bisecting
commit by commit isolated it to exactly the `DL` rejection commit, which
was suspicious on its own since that check only rejects `DL>=0x82` and a
single-disk boot never uses those values. Root cause turned out to be one
commit further back, just newly *exposed*: `int13h_read_sectors` reuses
`DX` as a plain scratch register for ATA port addresses (`mov dx, 0x1F6`,
`mov dx, 0x1F0`, etc.) throughout the sector loop and never restored it
before returning, so the caller got back whatever port address was last
loaded into `DX` (`0x1F0`) instead of its own `DL` (drive number) - a
real BIOS's `AH=0x02` never touches `DL`/`DH` on output, only `AH`/`CF`.
Confirmed with a temporary serial dump logging every `int13h` call's
`AH`/`DL`/`AL`/`CH`/`CL`/`DH` (removed after, never committed): GRUB's
`boot.img` reads `diskboot.img` (1 sector, `DL=0x80` - correct) and gets
back a *technically successful* read, but the very next call - GRUB's
own `diskboot.img` reading the rest of `core.img` - went out with
`DL=0xF0`, the low byte of `0x1F0` left over in `DX` from the previous
call's ATA transfer loop. Before the `DL` rejection commit, that garbage
`DL` silently aliased back to master and (usually) still returned
plausible-looking data, masking the bug; after it, the same garbage `DL`
correctly got refused, turning a silent latent bug into a visible one.
Fixed by giving `int13h_read_sectors` the same treatment `int13h_reset`
already had (`push dx` at entry, `pop dx` right before `ret` in the
shared `.exit:` path) so the caller's original `DL`/`DH` survive the
function's internal port-address reuse of `DX`. Verified against the
same `grub_test.iso` (now reaches the real GNU GRUB boot menu instead of
`Read Error`) and the full existing regression disk (still clean) before
calling it fixed. Lesson: a passing single-disk-shaped regression test
doesn't rule out a bug that's been there all along and only *looked*
harmless because nothing was checking its output strictly enough yet -
tightening one check can unmask an older, unrelated one.

**Another real-hardware-only gap, found via GRUB's `multiboot` command
booting a user's own hobby OS kernel**: the kernel has its own PS/2
keyboard driver (not going through `int 16h` at all - `multiboot` hands
control to a 32-bit protected-mode kernel directly, so BIOS real-mode
services are out of the picture from that point on) that stopped
receiving any input under this BIOS, while working fine chainloaded from
a real one. First guess, before seeing any of the kernel's actual source:
the driver probably hooks the *default* IRQ1 vector without doing its own
8259 PIC remap, relying on the BIOS having already done it - a common
simplification in early-stage hobby OSes. This project never had any PIC
remap at all (no code anywhere touched ports `0x20`/`0x21`/`0xA0`/`0xA1`),
so that looked like a solid lead, and it's true that a real PC/AT BIOS
always reprograms the PIC during POST (`ICW1`-`ICW4`, master IRQ0-7 ->
`INT 0x08`-`0x0F`, slave IRQ8-15 -> `INT 0x70`-`0x77`). Added `pic_init`
(called early in `start:`) doing that standard sequence, mask left as
IRQ0/1/2 unmasked - verified the existing test disk and GRUB's own menu
still passed, but **the user's kernel still got no input**. Turned out the
guess was only half right: once the user shared the actual source
(`idt.c`), it showed the kernel does its own complete PIC remap
(`pic_remap()`, master offset `0x20` - so IRQ1 lands on vector 33, exactly
matching its own `idt_set_gate(33, keyboard_handler_asm, ...)`), making
this project's PIC state irrelevant either way. Real bug, found by reading
the kernel's actual `keyboard.c`: it drives the keyboard entirely by
IRQ (`inb(0x60)` inside the handler, `outb(0x20, 0x20)` EOI at the end -
no polling fallback anywhere), which only ever fires if the keyboard
*controller itself* is told to raise IRQ1 on data-ready - a separate
concern from the PIC being able to relay it. That's bit 0 of the 8042
Controller Configuration Byte (read via command `0x20`, written via
command `0x60` on port `0x64`), and this project's own keyboard access
is 100% polling (`kbd_service` and the POST self-test both just check
status port bit 0 / bit 1 directly), so nothing here had ever needed that
bit set - `post_keyboard_test` sent the `0xAA` self-test command and
stopped there. Fixed by reading the Configuration Byte right after a
successful self-test, setting bit 0 (IRQ1 enable) and explicitly clearing
bit 6 (Set 2 -> Set 1 hardware translation - must stay off, this project's
whole keyboard stack depends on receiving raw Set 2, see the gotcha
elsewhere in this file) before writing it back - a read-modify-write
rather than a hardcoded byte, so whatever the platform's other bits
(mouse clock, system flag) already were is preserved. Every wait loop in
that sequence times out and gives up silently rather than reporting
failure - the self-test already proved the controller works, so a stuck
Configuration Byte handshake isn't worth downgrading `Keyboard controller
self-test: OK` over. Verified the existing test disk and GRUB's menu both
still pass. Lesson twofold: don't stop at the first "this looks like a
real BIOS gap" explanation just because it's plausible and fixes nothing
that was already passing - read the other side's actual source once it's
available, since a working PIC remap can fully mask a completely
different missing piece one layer down; and a driver written
polling-only can go a long time without anyone noticing it never
enabled the one bit that only matters for IRQ-driven access.

**Still not the whole story - user's kernel got closer but still no
input after the 8042 fix, sending straight back to instrumented testing
rather than guessing again.** Built a standalone multiboot ELF test
kernel (32-bit, own tiny IDT, own `pic_remap`-style ICW sequence
matching the user's `idt.c` exactly, an IRQ1 handler that increments a
counter drawn to the screen) to check, from outside this project's own
code entirely, whether a hardware IRQ1 ever reaches a CPU booted under
this BIOS at all. It didn't - counter stayed at zero through repeated
keypresses, with the PIC and 8042 both provably correctly configured by
that point. Root cause: on any CPU with a Local APIC (which is
effectively every CPU this BIOS will ever run on, including QEMU's),
legacy PIC interrupts don't go to the CPU core directly - they're routed
through the Local APIC's LINT0 pin, and per the Intel SDM that pin's LVT
entry resets to *masked*. A real BIOS always programs it (delivery
mode=ExtINT, unmasked) during POST; this project never had. Confirmed by
adding exactly that one register write (`0xFEE00350 <- 0x700`) to the
standalone test kernel - interrupts started arriving immediately, no
other change. That register isn't reachable from 16-bit real mode
(beyond conventional addressing), so fixing it in this project means a
real->protected->real mode round-trip during POST, done carefully and
reverted immediately after the one write.

**That round-trip is where this stalled, and stayed stalled.** Every
variant tried - a plain far `jmp` immediately after clearing `CR0.PE`
(the textbook-correct, SDM-documented pattern), the same with an
explicit `dword`/`word` operand-size override, a `retf`-based return
with the target pushed manually, global instead of local labels for the
jump targets (in case of some NASM local-label/bits-directive
interaction), reloading `SS` before the transition (in case of a null
selector during a fault), and - to rule out a silently swallowed
exception entirely - a full 256-entry IDT built at runtime *in RAM*
(0x1000, not ROM - writing new gate values into ROM at runtime silently
no-ops, same "ROM is not RAM" gotcha as everywhere else in this project,
and the first version of this diagnostic fell into exactly that trap)
with every vector pointing at a handler that prints and hangs, so any
fault at all would be visible - none of it reached the checkpoint placed
immediately after the return jump. No exception fires (the all-vectors
IDT never caught anything), no reset happens (`-no-reboot` plus
`-d guest_errors` logged nothing, and a 10-second serial capture never
repeated the POST banner the way earlier, unrelated bugs did when they
actually triple-faulted), and the raw bytes at the jump target were
independently verified correct via a hex dump of the assembled ROM. A
GDB-remote session against QEMU's `-gdb` stub was the last thing tried
and didn't produce a clean answer in the time spent on it. Given all of
that - the entry into protected mode demonstrably works (later
checkpoints inside the 32-bit block all fire, including the LAPIC write
itself), and it's specifically the return leg that never completes for
a reason none of the standard failure modes (wrong operand size, stale
segment cache, swallowed fault, bad label math) explain - reverted the
whole attempt rather than ship a mode switch this early in POST that
isn't fully understood. A bug there risks the entire boot sequence for
every user of this BIOS, not just IRQ-driven input for one kernel; that
trade isn't worth it without a clean root cause. `pic_init` and the
8042 IRQ1-enable fix both stayed (they're correct, real BIOS behavior,
and harmless even though insufficient on their own).

**Picked back up in a later session, asked explicitly to try again "a
different way" rather than debug the same round-trip further** - and a
different way turned out to exist: "unreal mode". The broken attempt's
whole problem was the return leg of a `CS`-changing far `jmp`/`retf`
back to real mode; unreal mode sidesteps that by never changing `CS` in
the first place. Enter protected mode, load *only* `ES` with a flat
(`0`-`4GB`) descriptor from a 2-entry GDT (null + one data descriptor -
no code descriptor needed at all, since nothing ever jumps through it),
drop `CR0.PE` back to 0, `jmp $+2` (a near jump - flushes the prefetch
queue same as the SDM-mandated far jump would, but never touches `CS`,
so there's no descriptor to reload and nothing to get wrong). `CS` keeps
its original real-mode cache the entire time, untouched and never
invalidated, so there's no return leg to fail. Wrote the LVT LINT0
value through `ES` with an explicit `a32` address-size override (needed
to encode a 32-bit displacement while still assembling as 16-bit code).
Rebuilt, booted standalone under `-bios` with no test disk attached at
all: POST completed and printed its normal banner - the mode switch
itself no longer hangs. Verified the actual write landed by reading
`0xFEE00350` back with the same technique from a small boot-sector
diagnostic chainloaded after POST: `0x00000700`, exactly the intended
value.

**Reading it back correct didn't mean it worked yet** - a dedicated
real-mode IRQ1 counter test (hook `IVT[0x09]`, `sti`, count on every
scancode byte) still read zero after keypresses. Root-caused by checking
the Local APIC's other half: the Spurious Interrupt Vector Register
(`0xFEE000F0`) has its own separate "software enable" bit (bit 8) that
gates the *entire* APIC, independent of any individual LVT entry's own
mask bit - LVT LINT0 can be perfectly unmasked and still deliver nothing
if this one is off, which it is by default (confirmed by reading it back
first: `0x000000FF`, enable bit clear). Added a second `a32` write next
to the LVT one (`0xFEE000F0 <- 0x1FF` - enable bit set, spurious vector
`0xFF`) using the exact same unreal-mode excursion. First combined test
of both writes together, run standalone as an isolated boot sector
(not yet wired into the BIOS's own POST), completed cleanly. Wired into
`lapic_unmask_lint0` and re-tested against the real-mode IRQ1 counter:
it hung again - but this time *inside the test disk*, right after
installing its `IVT[0x09]` handler and calling `sti`, never printing a
single line. Not a regression in the fix itself: IRQ0 (the PIT timer)
now genuinely fires on its own, continuously, needing no keypress at
all, and that test disk had only ever installed a handler for `IVT[0x09]`
- the very first automatic timer tick jumped into an untouched,
garbage `IVT[0x08]` slot and took the whole test down. Added a second,
trivial `IVT[0x08]` handler (read `AL`, `out 0x20,0x20`, `iret`) to the
test disk and re-ran: the counter finally moved, and kept moving,
correctly counting both the press and release event for every key.

That same "nothing ever handled the timer because it never fired before"
gap applies identically to any *loaded* real-mode code, including this
project's own `boot.asm`, which does a plain `sti` as completely
standard boot-sector practice - real BIOS is expected to have already
installed minimal `INT 0x08`/`INT 0x09` handlers by the time a boot
sector runs, and until this session, this one never had, because it
never needed to (nothing was arriving to handle). Fixed properly instead
of just in the throwaway test disk: `install_int08_vector` /
`install_int09_vector`, called right after `lapic_unmask_lint0` in
`start:`. `int08_isr` does what a real BIOS's timer tick handler
minimally does - increments the BDA tick counter at `0x0040:0x006C` -
then `EOI`s and returns; deliberately skips the midnight/day-rollover
flag real BIOS also tracks, since nothing in this project reads it back
(no `int 1ah` yet) and it would be complexity with no observable effect
today. `int09_isr` doesn't reimplement scan-code decoding at all - it
just calls the existing `kbd_service` (the same routine `int 16h`
already polls) directly, then `EOI`s. That works precisely because by
the time the ISR runs, a byte is already guaranteed to be waiting at
port `0x60` (that's *why* IRQ1 fired), so `kbd_service`'s own internal
"is there data yet" poll trivially succeeds on the first check - one
decode path now transparently serves both polling (`int 16h`) and
interrupt-driven callers, no duplicated logic. Re-ran the existing
regression disk and GRUB's own menu (both went through the codepath
that had just hung moments earlier, with real `sti` now genuinely live)
- both clean.

**Last mile: proving actual delivery into a protected-mode multiboot
kernel, the user's original scenario** - rebuilt the same kind of
32-bit multiboot test ELF used to originally diagnose the LVT0 gap (own
tiny IDT, own PIC remap matching the user's `idt.c`, an IRQ1 counter
drawn to the screen), booted it through GRUB under the now-fixed BIOS,
and it reset the whole machine the instant the menu entry was selected -
looked at first like the fix itself was unsafe under a real multiboot
handoff, not just this project's own boot sector. Bisected with the same
serial-checkpoint technique used throughout this whole investigation,
letter by letter through the kernel's own setup: PIC remap done, IDT
built, `lidt` done, `sti` done, all fine - the reset happened only once
the first interrupt actually tried to fire, never reaching a checkpoint
placed as the very first instruction inside the handler itself. Printed
the live `CS`/`SS`/`ESP` values right before enabling interrupts to stop
guessing: `CS=0x10`, not the `0x08` this quick test kernel's IDT-building
code had hardcoded for every gate's selector field. GRUB's multiboot GDT
layout simply isn't `0x08` for code in this GRUB version/build - the
kernel's exception/IRQ gates were pointing interrupt delivery at a
selector that didn't describe the running code segment at all, so the
CPU faulted trying to use it the moment any interrupt needed to enter
through the IDT. Fixed the *test kernel* (`mov word [gate+2], cs` instead
of a hardcoded `0x08`) - not this BIOS, which had no part in that bug -
and re-ran: no reset, and the on-screen counter read `0x0F` after five
keypresses, both press and release counted, confirmed via serial log
showing no repeated POST banner this time either. Lesson: a crash
immediately downstream of a change is not proof the change caused it -
the multiboot GDT-layout assumption this test kernel hardcoded had
simply never been exercised before, for the exact same reason the whole
LAPIC gap existed in the first place: no interrupt had ever survived
long enough to reach it.

The LAPIC LVT0 gap is fixed, verified at three levels now: real-mode
IRQ1 (dedicated counter test), this project's own regression disk and
GRUB's menu with real `sti` genuinely live, and a protected-mode
multiboot kernel receiving real IRQ1 events end to end.

**One more bug, found the moment real IRQ delivery started working and
the user tried their actual OS again**: input arrived, but every key
decoded to something else, consistently and specifically - `h` typed
`,`, `e` typed `j` - and every keystroke was duplicated. Not random
corruption: `,` and `j` are exactly what a *Scan Set 1* lookup table
produces when fed the *Scan Set 2* codes for `h` (`0x33`) and `e`
(`0x24`) - `kbd_us_set1[0x33]` is `,`, `kbd_us_set1[0x24]` is `j`,
confirmed by hand against the kernel's own `keyboard.c` before touching
any code. This project's 8042 fix (the IRQ1-enable one, earlier in this
file) had deliberately left hardware Set 2->Set 1 translation *off*
(Configuration Byte bit 6 cleared) specifically because this project's
own `kbd_service` decodes raw Set 2 itself and only translates to Set 1
in software, just for `int 16h`'s `AH` output - a deliberate, working
design choice right up until something started reading port `0x60`
directly instead of going through `int 16h`. The duplication had the
same root cause, once traced through: Set 2's release code is a
two-byte sequence (`0xF0` then the make code again), and the kernel's
`scode2char` was written for Set 1's convention (release = make code
with bit 7 set, one byte) - it silently ate the `0xF0` byte as an
unrecognized "release" of nothing in particular, then treated the
*next* byte (the repeated make code) as a brand new keypress, printing
the same (wrong) character a second time.

Real BIOS never has this problem because it always turns hardware
translation *on* and writes its own keyboard code against Set 1 from
the start - this project had instead chosen to decode Set 2 in software
and translate only at the `int 16h` boundary, which is internally
consistent but means anything bypassing `int 16h` (any real IRQ1
consumer, which - until this session - had never once actually
existed, for the same underlying reason IRQ1 itself never fired) sees
raw Set 2 and misreads it as Set 1. Fixed by switching this project
over to the same convention real BIOS uses instead of patching around
it: Configuration Byte bit 6 now gets *set* (hardware translation on),
and `kbd_service` was rewritten to consume Set 1 directly. This
actually simplified the decoder - Set 1's release code is a single byte
(make code | `0x80`), so the two-state F0-prefix state machine
(`RAM_BREAK_FLAG`) went away entirely, along with the `kbd_scan2to1`
software-translation table (no longer needed - the byte off the wire
*is* already Set 1, `AH` just gets it directly). `kbd_ascii_lo`/`_hi`
got rebuilt indexed by Set 1 codes instead of Set 2 (mechanically
derived from the old Set2->Set1 table, cross-checked against the
standard XT scancode layout). `setup_menu`'s own raw port-polling
(`KEY_UP`/`KEY_DOWN`/`KEY_ENTER`/`KEY_ESC`) got the same treatment -
Set 1 constants (`0x48`/`0x50`/`0x1C`/`0x01`), single-byte break
detection, `RAM_BREAK_FLAG` references dropped. Verified three ways:
an `int 16h`-driven typing test (`helloWorld123`, including a
shifted letter, came back character-for-character correct with no
duplicates), the setup menu's own arrow/Enter navigation, and - closest
to the original bug report - a multiboot test kernel dumping raw
scancode bytes to the screen for real keypresses, which read back
`23 A3 12 92 26 A6 26 A6 18 98` for `h-e-l-l-o`: exactly the Set 1
make/break pairs for each letter, byte for byte.

**Setup menu grew up, once the keyboard was trustworthy enough to build
more on top of it.** Asked for two things together: don't open setup on
every boot (real BIOS convention - press a hotkey during a short window,
Del by preference here, otherwise boot proceeds untouched), and add a
few more settings. `prompt_setup_key` does the hotkey wait: same
"E0 is just skipped, next byte processed normally" simplification this
project uses everywhere for extended keys applies here too, since Del's
dedicated key is `E0 53` in Set 1 and numpad Del (NumLock off) is bare
`0x53` - one check catches both without decoding the E0 sequence
specially. The wait itself is the same instruction-count busy-wait style
as every other timeout in this project (no real-time clock involved,
`IF` is still 0 this early), calibrated empirically rather than guessed:
an outer/inner nested loop, timed via a Python harness watching the
serial log's timestamps between "Press DEL" and "Booting" appearing -
`dx=20` measured at a blink-and-you-miss-it ~0.05s (too short to
actually react to), `dx=150` at 0.3s (still too short), `dx=1200` at a
comfortable ~2.8s. Three new menu items followed: **Boot device**
(Master/Slave, persisted in the same packed CMOS byte as Serial/VGA -
bit2), **Quiet boot** (bit3 - suppresses the POST banner/memory-test/
keyboard-test lines specifically on VGA via a new `print_vga_post`
wrapper that checks the toggle before falling through to `print_vga`;
serial is untouched, and failures are never suppressed, quiet or not),
and **System Information** (a read-only view - conventional/extended
memory, current boot drive, HDD/floppy CHS geometry - `int15h_ext_mem_kb`
and the `SPT_HDD`/`HPC_HDD`/`SPT_FLOPPY`/`HPC_FLOPPY` constants reused
directly rather than re-derived). Printing a *number* at an arbitrary
screen position (needed for the memory figures) didn't exist yet -
`print_dec_ax`'s digit-conversion loop got extracted into
`num_to_dec_buf` so both it and the new `vga_print_dec_at` share the
same division-by-10 logic instead of duplicating it.

Testing "Quiet boot" surfaced one more small gap: toggling it on, then
triggering a warm reset via the QEMU monitor's `system_reset` (chosen
specifically because it preserves in-memory CMOS within the same QEMU
process, unlike launching a fresh one - useful for testing persisted
settings without relying on real NVRAM backing) left stale text from
the *previous* boot's screen visible around the short "Press DEL..."
prompt. Root cause: `system_reset` resets the CPU, not the VGA card - a
real cold boot's video memory starts blank on its own, and the old,
*non-quiet* boot sequence printed enough text to overwrite any leftover
screen content by sheer volume, masking that nothing had ever explicitly
cleared the screen at POST's start. Fixed with one `vga_clear_screen`
call added right after the font loads, before the first thing POST ever
prints - unconditional, not gated by Quiet boot, since a clean screen at
boot is correct either way.

**Real bug, not a test artifact, found immediately by building this**:
`ata_read_mbr` had always addressed the ATA master unconditionally, no
matter what `DL` `boot_try_disk` was about to hand the loaded code right
after. Totally invisible before now, because the drive number was
hardcoded in both places and they could only ever agree. The moment
"Boot device" became a real setting, they could disagree: picking
"Slave" would read the *master's* MBR into memory, then jump into it
with `DL=0x81`, telling the loaded code it was booted from a drive it
was never actually read from. Caught immediately by the most basic
regression check (boot with "Slave" selected, only a master disk
attached) - correctly reported "No bootable disk found" instead of
silently booting the wrong physical disk under the wrong identity, which
made the mismatch obvious rather than something that would have
corrupted state quietly. Fixed by having `ata_read_mbr` read
`RAM_BOOT_DRIVE` for its own master/slave bit on port `0x1F6`, same as
`int13h_read_sectors` already does for loaded code's own disk reads.

**System Information grew a CPU model line, on request.** `CPUID` works
fine from 16-bit real mode - it's a plain instruction, not tied to
protected mode, and by this point in the project's history there's
already a working template for "briefly use 32-bit registers from real
mode" (the unreal-mode LAPIC fix). Detection first: flip bit 21 (ID) of
EFLAGS via `pushfd`/`popfd` and see if it actually toggles - the
standard, decades-old way to check CPUID exists at all, since 386/486
without it just won't let the bit change. Honest fallback chain, not a
guess, matching this project's existing philosophy (`AH=0x88`'s real
CMOS read, `AH=0x08`'s admittedly-fake geometry, both documented as such
rather than papered over): CPUID present but no extended brand string
(`EAX=0x80000000` returns less than `0x80000004`) falls back to the
12-byte vendor ID string (`EAX=0`, universally available whenever CPUID
exists at all); no CPUID at all prints "Unknown (no CPUID)" outright
rather than inventing a value. The brand string itself is 3 leaves
(`EAX=0x80000002/3/4`) of 16 bytes each, packed as `EAX:EBX:ECX:EDX` -
comes back space-padded on real CPUs (Intel pads brand strings to a
fixed width), so there's a trim pass shifting the string left to its
first non-space character before display. One easy-to-miss bug caught
before it ever got tested: initially wrote `mov si, RAM_CPU_BRAND` and
called `vga_print_at` directly, exactly like every other label on that
screen - except every *other* label lives in ROM (`CS`, which is also
`DS` for basically this entire project), while `RAM_CPU_BRAND` is, as
the name says, in RAM at segment `0`. `vga_print_at` reads through
`DS:SI` with no override, so without explicitly swapping `DS` to `0`
around that one call (`vga_print_dec_at` already had to solve the exact
same problem for the memory-KB figures on the same screen), it would
have silently printed 16 bytes of ROM starting at `0xF051C` instead of
the CPU name - not a crash, just quietly wrong output, the kind of bug
that's easy to ship if you don't specifically know to look for it after
copy-pasting a working pattern into a spot with different addressing
needs. Verified against actual QEMU output: `QEMU Virtual CPU version
2.5+`, trimmed and positioned correctly on the System Information
screen alongside everything else.

**`int 13h` grew `AH=0x41`/`0x42` (EDD extensions check + LBA extended
read), on request - and immediately relearned two lessons this project
had already paid for once.** Implementation itself: `int13h_read_sectors`
already had a working CHS-to-LBA path ending in a plain sector-transfer
loop over `cx:bx` (LBA), `bp` (count), `es:di` (buffer) - extracted that
tail into a shared `ata_lba_transfer`, so `AH=0x42` just needs to parse
the Disk Address Packet (`DS:SI`, standard 16-byte layout: count at
`+2`, buffer offset/segment at `+4`/`+6`, LBA low 32 bits at `+8`) into
those same three inputs and call the same core - no duplicated ATA PIO
logic. `AH=0x41` alone wouldn't have been enough to matter: a
well-behaved caller (GRUB included, confirmed by this project's own
earlier history of it correctly falling back to `AH=0x02` after `AH=0x41`
failed) checks for extended support *before* ever trying `AH=0x42`, so
skipping `AH=0x41` would have made the new `AH=0x42` code dead weight
that no real caller would ever reach.

First relearned lesson: `patch_stack_cf` - the shared helper every
`int 13h` function uses to set `CF` in the stacked `FLAGS` word before
`iret` - had always used `BH` as scratch space for reading and rewriting
that byte, silently discarding whatever was in `BX` on the way out. This
was invisible for every function implemented so far (`AH=0x00`/`0x02`/
`0x08`, plus `int 15h`'s `AH=0x88`) because none of them document `BX`
as part of their output - until `AH=0x41`, which by spec must hand back
`BX=0xAA55` on success. A dedicated test disk built specifically to
check for that value got a wrong-but-plausible-looking `BX` back twice
in a row, tracked down by capturing `CF`/`BX`/`AH` to a fixed memory
location immediately after the `int 13h` call - before any further code
(including this project's own `print_string`, which itself clobbers `BX`
setting the video attribute byte, the same well-known gotcha from
`stage2.asm`'s own history biting a debug script this time instead of
the BIOS itself) got a chance to touch the registers being inspected.
First pass at `BX=0xAA00` (high byte right, low byte zeroed) pointed
straight at `patch_stack_cf`'s `BH` scratch use; fixing that (switched
to `AX`, saved and restored around the patch so it's fully transparent)
surfaced a *second*, self-inflicted instance of the identical mistake -
`int13h_check_extensions`'s caller computed the `patch_stack_cf` signal
bit with `xor bl, bl`, still stepping on the low byte of the very
`BX=0xAA55` it had just set two lines earlier, just moved from inside
the function to its call site. Final fix needed a third register
entirely: push the real `BX` onto the stack right after
`int13h_check_extensions` returns, compute and use the signal bit freely
(`patch_stack_cf` is *always* going to discard `BL` - that's the
documented, correct behavior for every other function, not a bug to work
around generally), then pop the real `BX` back before `iret`.

Second relearned lesson, immediately after the first: GRUB regressed
straight back to its own `Read Error` the moment `AH=0x41` started
honestly advertising support - because that's exactly what let GRUB
actually start calling the new `AH=0x42` for real, instead of falling
back to the already-working `AH=0x02` it had used every time before.
Root cause was the *exact* bug this project had already found and fixed
once this session, in the exact same shape: `ata_lba_transfer` reuses
`DX` freely as the ATA port-address register, and `int13h_read_sectors_lba`
- unlike `int13h_read_sectors`, which has a `push dx`/`pop dx` specifically
because of that earlier bug - never saved the caller's `DL` around the
call. Writing the new function by adapting a working pattern carried over
the parts that were obviously relevant (DAP parsing, drivebit selection)
and silently dropped the one-line fix that wasn't visible anywhere in the
code being copied from, only in a comment explaining *why* it was there.
Fixed the same way as before: `push dx` at entry, `pop dx` before `ret`.
Both fixes verified together: the dedicated `AH=0x41`/`AH=0x42` test disk
(extensions check returns `BX=0xAA55`/`AH=0x01`/`CF=0` correctly now; a
1-sector `AH=0x42` read of the boot sector's own LBA 0 into a second
buffer byte-for-byte matches what's actually loaded at `0x7C00`), the
existing regression disk, and GRUB reaching its real menu again instead
of `Read Error`.

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