#include <stdio.h>

// See bench/cases/alloc/alloc.c's copy: -DBENCH_ALLOC_STATS builds a
// counting copy that prints this run's malloc count on stderr for
// bench/run.sh's cross-language comparison (#3934). This case allocates
// nothing, so the count is 0. The timed binary is built without the define
// and is byte-for-byte the program below.
#ifdef BENCH_ALLOC_STATS
static long nmalloc = 0;
#define REPORT_ALLOCS() fprintf(stderr, "[allocs] %ld\n", nmalloc)
#else
#define REPORT_ALLOCS() ((void)0)
#endif

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
  REPORT_ALLOCS();
  return 0;
}
