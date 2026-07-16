#include <stdio.h>
#include <stdlib.h>
typedef struct { long x, y; } Node;
int main(void) {
  int batches = 2000, per = 5000;
  long total = 0;
  for (int b = 0; b < batches; b++) {
    Node **batch = malloc(sizeof(Node *) * per);
    for (int k = 0; k < per; k++) {
      Node *p = malloc(sizeof(Node));
      p->x = b + k;
      p->y = k + 1;
      batch[k] = p;
    }
    for (int k = 0; k < per; k++) total += batch[k]->x + batch[k]->y;
    for (int k = 0; k < per; k++) free(batch[k]);
    free(batch);
  }
  printf("%ld\n", total);
  return 0;
}
