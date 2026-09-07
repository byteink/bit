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

int main(void) {
  int w = 1500, h = 1500, maxIter = 500;
  long sum = 0;
  for (int py = 0; py < h; py++) {
    double y0 = (double)py / (double)h * 2.5 - 1.25;
    for (int px = 0; px < w; px++) {
      double x0 = (double)px / (double)w * 3.5 - 2.5;
      double x = 0.0, y = 0.0;
      int iter = 0;
      while (iter < maxIter) {
        double x2 = x * x, y2 = y * y;
        if (x2 + y2 > 4.0) break;
        y = 2.0 * x * y + y0;
        x = x2 - y2 + x0;
        iter++;
      }
      sum += iter;
    }
  }
  printf("%ld\n", sum);
  REPORT_ALLOCS();
  return 0;
}
