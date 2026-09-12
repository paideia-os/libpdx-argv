/* tools/tests-link.ld — libpdx-argv.ENH-007 (Closes #14)
 *
 * Linker script for the smoke ELF built by tools/run-tests.sh.
 * Mirrors mkfs.pdxfs/link.ld (paideia-os #1976): ENTRY(_start),
 * .text at 0x00400000, .data at 0x00600000, .bss contiguous with
 * .data (no fixed-address gap — see the R31.M2-1595 comment in
 * paideia-os src/user/true.ld for why a gap widens the data PT_LOAD
 * across the hole).
 *
 * Both paideia-os and Linux user-space accept this exact layout, so
 * the emitted ELF is host-runnable directly (Linux) and OS-runnable
 * once the paideia-os satellite loader picks it up.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x00400000;

    .text : ALIGN(4K) {
        KEEP(*(.text._start))
        *(.text .text.*)
    } :text

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
    } :text

    . = 0x00600000;

    .data : ALIGN(4K) {
        *(.data .data.*)
    } :data

    .bss (NOLOAD) : ALIGN(4K) {
        *(COMMON)
        *(.bss .bss.*)
        . = ALIGN(4K);
    } :data

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame*)
        *(.note.*)
    }
}
