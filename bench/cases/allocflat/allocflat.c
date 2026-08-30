#include <stdio.h>
#include <stdlib.h>

// See bench/cases/alloc/alloc.c's copy: -DBENCH_ALLOC_STATS builds a
// counting copy that prints this run's malloc count on stderr for
// bench/run.sh's cross-language comparison (#3934). The timed binary is
// built without it.
#ifdef BENCH_ALLOC_STATS
static long nmalloc = 0;
#define malloc(n) (nmalloc++, malloc(n))
#define REPORT_ALLOCS() fprintf(stderr, "[allocs] %ld\n", nmalloc)
#else
#define REPORT_ALLOCS() ((void)0)
#endif

typedef struct { long x, y, id; } Node;

int main(void) {
  int batches = 2000, per = 5000;
  long total = 0;
  for (int b = 0; b < batches; b++) {
    Node *nodes = malloc(sizeof(Node) * per);
    for (int k = 0; k < per; k++) {
      nodes[k].x = b + k;
      nodes[k].y = k + 1;
      nodes[k].id = b;
    }
    for (int k = 0; k < per; k++) total += nodes[k].x + nodes[k].y + nodes[k].id;
    free(nodes);
  }
  printf("%ld\n", total);
  REPORT_ALLOCS();
  return 0;
}
