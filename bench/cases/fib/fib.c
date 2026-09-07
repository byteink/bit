#include <stdio.h>

// See bench/cases/alloc/alloc.c's copy: -DBENCH_ALLOC_STATS builds a counting
// copy that prints this run's malloc count on stderr for bench/run.sh's
// cross-language comparison (#3934). This case allocates nothing, so the
// count is 0. The timed binary is built without the define and is
// byte-for-byte the program below.
#ifdef BENCH_ALLOC_STATS
static long nmalloc = 0;
#define REPORT_ALLOCS() fprintf(stderr, "[allocs] %ld\n", nmalloc)
#else
#define REPORT_ALLOCS() ((void)0)
#endif

static long fib(long n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
int main(void) {
  printf("%ld\n", fib(40));
  REPORT_ALLOCS();
  return 0;
}
