#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

// The C side of bench/cases/allocpar: allocpar.bit's program with pthreads
// where it has `spawn`, allocating per node exactly as alloc.c does. Worker
// count is the same literal in all three sources and is never read from the
// host's core count -- see allocpar.bit's header for why.
#define WORKERS 8
#define BATCHES_PER_WORKER 250
#define PER 5000

// -DBENCH_ALLOC_STATS builds a counting copy that prints this run's malloc
// count on stderr, as alloc.c does. ATOMIC here and a plain `nmalloc++` there:
// eight threads share this counter, and a lost increment would understate the
// one number bench/run.sh uses to prove the three sources still express the
// same data structure (#3934). The timed binary is built without the flag and
// is byte-for-byte the program below.
#ifdef BENCH_ALLOC_STATS
static long nmalloc = 0;
#define malloc(n) (__atomic_fetch_add(&nmalloc, 1, __ATOMIC_RELAXED), malloc(n))
#define REPORT_ALLOCS() fprintf(stderr, "[allocs] %ld\n", nmalloc)
#else
#define REPORT_ALLOCS() ((void)0)
#endif

typedef struct { long id; } Batch;
typedef struct { long x, y; Batch *owner; } Node;

typedef struct { int w; long total; } Worker;

static void *run(void *arg) {
  Worker *me = (Worker *)arg;
  long total = 0;
  int lo = me->w * BATCHES_PER_WORKER, hi = lo + BATCHES_PER_WORKER;
  for (int b = lo; b < hi; b++) {
    Batch *owner = malloc(sizeof(Batch));
    owner->id = b;
    Node **nodes = malloc(sizeof(Node *) * PER);
    for (int k = 0; k < PER; k++) {
      Node *p = malloc(sizeof(Node));
      p->x = b + k;
      p->y = k + 1;
      p->owner = owner;
      nodes[k] = p;
    }
    for (int k = 0; k < PER; k++) total += nodes[k]->x + nodes[k]->y + nodes[k]->owner->id;
    for (int k = 0; k < PER; k++) free(nodes[k]);
    free(nodes);
    free(owner);
  }
  me->total = total;
  return NULL;
}

int main(void) {
  pthread_t th[WORKERS];
  Worker w[WORKERS];
  for (int i = 0; i < WORKERS; i++) {
    w[i].w = i;
    w[i].total = 0;
    if (pthread_create(&th[i], NULL, run, &w[i]) != 0) return 1;
  }
  long total = 0;
  for (int i = 0; i < WORKERS; i++) {
    if (pthread_join(th[i], NULL) != 0) return 1;
    total += w[i].total;
  }
  printf("%ld\n", total);
  REPORT_ALLOCS();
  return 0;
}
