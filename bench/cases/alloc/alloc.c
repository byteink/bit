#include <stdio.h>
#include <stdlib.h>
typedef struct { long x, y; } Node;
int main(void) {
  long n = 20000000, sum = 0;
  for (long i = 0; i < n; i++) {
    Node *p = malloc(sizeof(Node));
    p->x = i; p->y = i + 1;
    sum += p->x + p->y;
    free(p);
  }
  printf("%ld\n", sum);
  return 0;
}
