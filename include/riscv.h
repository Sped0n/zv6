#include "include/types.h"

#ifndef __ASSEMBLER__

static inline uint64 r_sp() {
  uint64 x;
  asm volatile("mv %0, sp" : "=r"(x));
  return x;
}

#endif // __ASSEMBLER__

#define PGSIZE 4096 // bytes per page

// one beyond the highest possible virtual address.
// MAXVA is actually one bit less than the max allowed by
// Sv39, to avoid having to sign-extend virtual addresses
// that have the high bit set.
#define MAXVA (1L << (9 + 9 + 9 + 12 - 1))
