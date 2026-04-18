.section .init
.global main

/* set stack pointer to top of 48 KB BRAM */
lui sp, %hi(48*1024)
addi sp, sp, %lo(48*1024)

/* call main */
jal ra, main

/* halt: infinite loop */
1:
    ebreak
    j 1b