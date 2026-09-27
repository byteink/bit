// rapidyaml's side of pkg/yaml's parse-throughput comparison (#6049).
//
// Built twice by run.sh from this one file:
//   rapidyamlbench       ryml::parse_in_place - parses the file's own buffer,
//                        unescaping and folding scalars inside it (zero-copy);
//   rapidyamlarenabench  -DBENCH_ARENA: ryml::parse_in_arena - copies the
//                        source into the tree's arena first, the mode for a
//                        caller whose buffer is read-only.
// Both parse the whole stream into one Tree, expand aliases with
// Tree::resolve() (the library's own anchor/alias resolution), then walk
// every document and print "docs=<N> nodes=<N> crc=<u32>", encoded by
// ../canon/canon.h exactly as ../bit/main.bit encodes it. run.sh times the
// whole process.
#define RYML_SINGLE_HDR_DEFINE_NOW
#include "ryml.hpp"

#include "../canon/canon.h"

using ryml::csubstr;
using ryml::id_type;
using ryml::Tree;

static long long walk(Tree const &t, id_type id, canon_buf *b) {
  bool map = t.is_map(id);
  if (!map && !t.is_seq(id)) {
    csubstr v = t.val(id);
    canon_scalar(b, v.str, v.len, !t.is_val_quoted(id));
    return 1;
  }
  canon_num(b, map ? 'M' : 'Q', t.num_children(id), 0, ';');
  long long count = 1;
  for (id_type ch = t.first_child(id); ch != ryml::NONE; ch = t.next_sibling(ch)) {
    if (map) {
      csubstr k = t.key(ch);
      canon_scalar(b, k.str, k.len, !t.is_key_quoted(ch));
      count++;
    }
    count += walk(t, ch, b);
  }
  return count;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: rapidyamlbench <path-to-yaml-file>\n");
    return 2;
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) canon_fatal("open", argv[1], strlen(argv[1]));
  if (fseek(f, 0, SEEK_END) != 0) canon_fatal("seek", argv[1], strlen(argv[1]));
  long size = ftell(f);
  if (size < 0 || fseek(f, 0, SEEK_SET) != 0) canon_fatal("size", argv[1], strlen(argv[1]));
  char *src = (char *)malloc((size_t)size + 1);
  if (!src || fread(src, 1, (size_t)size, f) != (size_t)size) canon_fatal("read", argv[1], strlen(argv[1]));
  fclose(f);

#ifdef BENCH_ARENA
  Tree t = ryml::parse_in_arena(csubstr(src, (size_t)size));
#else
  Tree t = ryml::parse_in_place(ryml::substr(src, (size_t)size));
#endif
  t.resolve();

  canon_buf b = {};
  long long nodes = 0;
  size_t ndocs = 0;
  id_type root = t.root_id();
  if (t.is_stream(root)) {
    for (id_type d = t.first_child(root); d != ryml::NONE; d = t.next_sibling(d), ndocs++) nodes += walk(t, d, &b);
  } else {
    nodes = walk(t, root, &b);
    ndocs = 1;
  }
  printf("docs=%zu nodes=%lld crc=%u\n", ndocs, nodes, canon_crc32c((const unsigned char *)b.p, b.len));
  return 0;
}
