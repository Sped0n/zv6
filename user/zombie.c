// Create a zombie process that
// must be reparented at exit.

#include "include/stat.h"
#include "include/types.h"
#include "user/user.h"

int main(void) {
  if (fork() > 0)
    sleep(5); // Let child exit before parent.
  exit(0);
}
