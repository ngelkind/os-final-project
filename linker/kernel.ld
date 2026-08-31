/* AArch64 kernel, QEMU virt board */

ENTRY(entry_point)

SECTIONS
{
    /* RAM base 0x40000000 + 0x80000 load offset used by -kernel */
    . = 0x40080000;

    .text : {
        *(.text*)
    }

    .rodata : {
        *(.rodata*)
    }

    .data : {
        *(.data*)
    }

    /* NOBITS - zeroed by the startup code, not by a loader */
    .bss : {
        . = ALIGN(16);
        bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(16);
        bss_end = .;
    }

    /* NOLOAD keeps the reservation out of the raw binary */
    .stack (NOLOAD) : {
        . = ALIGN(16);      /* SP must be 16-byte aligned on AArch64 */
        . += 16K;
        stack_top = .;      /* stack grows down */
    }
}