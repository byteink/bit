// Matches matrix.bit exactly: same data, same i-k-j loop order, same 6
// trials, and the same three buffers allocated once outside the trial loop
// with c re-zeroed inside it (#4056 -- the Bit side allocated inside the loop
// and the memory row compared different programs).
#include <stdio.h>
#include <stdlib.h>

// See bench/cases/alloc/alloc.c's copy: -DBENCH_ALLOC_STATS builds a counting
// copy that prints this run's malloc count on stderr for bench/run.sh's
// cross-language comparison (#3934). The timed binary is built without it and
// is byte-for-byte the program below. Added by #4056: without it this case's
// allocation row printed "—" for Go and C.
#ifdef BENCH_ALLOC_STATS
static long nmalloc = 0;
#define malloc(n) (nmalloc++, malloc(n))
#define REPORT_ALLOCS() fprintf(stderr, "[allocs] %ld\n", nmalloc)
#else
#define REPORT_ALLOCS() ((void)0)
#endif

int main(void) {
  long n = 512, trials = 6;
  long grandSum = 0, grandTrace = 0, lastFirst = 0, lastLast = 0;
  double *a = malloc(sizeof(double) * n * n);
  double *b = malloc(sizeof(double) * n * n);
  double *c = malloc(sizeof(double) * n * n);

  for (long t = 0; t < trials; t++) {
    for (long i = 0; i < n * n; i++) c[i] = 0.0;

    for (long i = 0; i < n; i++) {
      for (long j = 0; j < n; j++) {
        a[i * n + j] = (double)((i + j + t) % 13);
        b[i * n + j] = (double)((i * 2 + j * 3 + t) % 17);
      }
    }

    for (long i = 0; i < n; i++) {
      for (long k = 0; k < n; k++) {
        double aik = a[i * n + k];
        for (long j = 0; j < n; j++) {
          c[i * n + j] += aik * b[k * n + j];
        }
      }
    }

    double sum = 0.0, trace = 0.0;
    for (long i = 0; i < n * n; i++) sum += c[i];
    for (long d = 0; d < n; d++) trace += c[d * n + d];

    grandSum += (long)sum;
    grandTrace += (long)trace;
    lastFirst = (long)c[0];
    lastLast = (long)c[n * n - 1];
  }

  printf("%ld %ld %ld %ld\n", grandSum, grandTrace, lastFirst, lastLast);
  REPORT_ALLOCS();
  free(a);
  free(b);
  free(c);
  return 0;
}
