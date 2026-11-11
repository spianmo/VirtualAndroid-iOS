/* Bare-metal layout for -M virt (RAM at 0x40000000). */
ENTRY(_start)
SECTIONS
{
    . = 0x40080000;
    .text : { KEEP(*(.text.boot)) *(.text*) }
    .rodata : ALIGN(16) { *(.rodata*) }
    .data : ALIGN(16) { *(.data*) }
    .bss (NOLOAD) : ALIGN(16) { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(16); __bss_end = .; }
    . = ALIGN(4096);
    __pt_l1 = .;            /* level-1 translation table, 4 KB */
    . += 4096;
    . = ALIGN(16);
    . += 0x10000;
    __stack_top = .;
}
