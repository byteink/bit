#include <stdio.h>
static long collatz(long n) {
  long steps = 0;
  while (n != 1) {
    n = (n % 2 == 0) ? n / 2 : 3 * n + 1;
    steps++;
  }
  return steps;
}
int main(void) {
  long best = 0;
  for (long i = 1; i < 1000000; i++) {
    long s = collatz(i);
    if (s > best) best = s;
  }
  printf("%ld\n", best);
  return 0;
}
