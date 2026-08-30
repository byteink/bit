#include <stdio.h>
#include <stdlib.h>

// -DBENCH_ALLOC_STATS builds a counting copy that prints this run's malloc
// count on stderr, so bench/run.sh can compare it against the Bit and Go
// sides of the same case (#3934). The timed binary is built without it and
// is byte-for-byte the program below.
#ifdef BENCH_ALLOC_STATS
static long nmalloc = 0;
#define malloc(n) (nmalloc++, malloc(n))
#define REPORT_ALLOCS() fprintf(stderr, "[allocs] %ld\n", nmalloc)
#else
#define REPORT_ALLOCS() ((void)0)
#endif

typedef struct { long id; } Batch;
typedef struct { long x, y; Batch *owner; } Node;

int main(void) {
  int batches = 2000, per = 5000;
  long total = 0;
  for (int b = 0; b < batches; b++) {
    Batch *owner = malloc(sizeof(Batch));
    owner->id = b;
    Node **nodes = malloc(sizeof(Node *) * per);
    for (int k = 0; k < per; k++) {
      Node *p = malloc(sizeof(Node));
      p->x = b + k;
      p->y = k + 1;
      p->owner = owner;
      nodes[k] = p;
    }
    for (int k = 0; k < per; k++) total += nodes[k]->x + nodes[k]->y + nodes[k]->owner->id;
    for (int k = 0; k < per; k++) free(nodes[k]);
    free(nodes);
    free(owner);
  }
  printf("%ld\n", total);
  REPORT_ALLOCS();
  return 0;
}
