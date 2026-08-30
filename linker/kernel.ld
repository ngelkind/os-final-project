ENTRY(entry_point)

SECTIONS
{
    . = 0x40080000;


    .text : {
        *(.text)
    }

    .rodata : {
        *(.rodata*)
    }
        . = ALIGN(16);
        . += 16K;
        stack_top = .;
    . = ALIGN(16);
    bss_start = .;
        .bss : {
            *(.bss*)
            *(COMMON)
        }
    . =ALIGN(16);
        bss_end = .;
}