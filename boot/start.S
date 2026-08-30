.text
.global entry_point

//beg of assembly code
entry_point:

//disable all except one cpu cores
mrs x0, MPIDR_EL1
and x0, x0, #0xff //x0 = x0 and 0*56 then 1*8
cmp x0, #0
b.ne infinite_loop

//init stack (give it some space, 16kb currently)
ldr x5, =stack_top //dont understand what it means
mov sp, x5

//initialize all global non-init vars with zeroes
ldr x0, =bss_start
ldr x1, =bss_end
start_initializing:
cmp x0, x1
b.hs end_initializing
str xzr, [x0], #8// #8 is post increment. it's increment x0 on 8 to get to the next word in memory
b start_initializing
end_initializing:

//set the vector table into the cpu register
ldr x0, =vector_table
msr VBAR_EL1, x0

//go to the c++ code. start from main entry point
bl kernel_main

infinite_loop:
b infinite_loop