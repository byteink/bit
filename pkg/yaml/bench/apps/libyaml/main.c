// libyaml's side of pkg/yaml's parse-throughput comparison (#6049).
//
// Reads the fixture named by argv[1], loads EVERY document of the stream into
// a libyaml node tree first (yaml_parser_load, the document API - the same
// whole-stream-in-memory shape as pkg/yaml's yamlParseAll and yaml.v3's
// []*yaml.Node), then walks them and prints "docs=<N> nodes=<N> crc=<u32>",
// encoded by ../canon/canon.h exactly as ../bit/main.bit encodes it. An alias
// is the anchored node's own id in a libyaml document, so walking it expands
// the alias the way every other side does. run.sh times the whole process.
#include <yaml.h>

#include "../canon/canon.h"

static long long walk(yaml_document_t *d, yaml_node_t *n, canon_buf *b) {
  long long count = 1;
  switch (n->type) {
    case YAML_MAPPING_NODE: {
      yaml_node_pair_t *p = n->data.mapping.pairs.start, *end = n->data.mapping.pairs.top;
      canon_num(b, 'M', (uint64_t)(end - p), 0, ';');
      for (; p < end; p++) {
        count += walk(d, yaml_document_get_node(d, p->key), b);
        count += walk(d, yaml_document_get_node(d, p->value), b);
      }
      return count;
    }
    case YAML_SEQUENCE_NODE: {
      yaml_node_item_t *it = n->data.sequence.items.start, *end = n->data.sequence.items.top;
      canon_num(b, 'Q', (uint64_t)(end - it), 0, ';');
      for (; it < end; it++) count += walk(d, yaml_document_get_node(d, *it), b);
      return count;
    }
    case YAML_SCALAR_NODE:
      canon_scalar(b, (const char *)n->data.scalar.value, n->data.scalar.length,
                   n->data.scalar.style == YAML_PLAIN_SCALAR_STYLE);
      return count;
    default:
      canon_fatal("unexpected libyaml node type", "", 0);
      return 0;
  }
}

static unsigned char *read_file(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  if (!f) canon_fatal("open", path, strlen(path));
  if (fseek(f, 0, SEEK_END) != 0) canon_fatal("seek", path, strlen(path));
  long size = ftell(f);
  if (size < 0 || fseek(f, 0, SEEK_SET) != 0) canon_fatal("size", path, strlen(path));
  unsigned char *src = (unsigned char *)malloc((size_t)size + 1);
  if (!src || fread(src, 1, (size_t)size, f) != (size_t)size) canon_fatal("read", path, strlen(path));
  fclose(f);
  *n = (size_t)size;
  return src;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: libyamlbench <path-to-yaml-file>\n");
    return 2;
  }
  size_t n;
  unsigned char *src = read_file(argv[1], &n);

  yaml_parser_t parser;
  if (!yaml_parser_initialize(&parser)) canon_fatal("parser init", "", 0);
  yaml_parser_set_input_string(&parser, src, n);

  size_t ndocs = 0, cap = 64;
  yaml_document_t *docs = (yaml_document_t *)malloc(cap * sizeof *docs);
  for (;;) {
    if (ndocs == cap) {
      cap *= 2;
      docs = (yaml_document_t *)realloc(docs, cap * sizeof *docs);
    }
    if (!docs) canon_fatal("out of memory", "", 0);
    if (!yaml_parser_load(&parser, &docs[ndocs])) {
      canon_fatal("parse", parser.problem ? parser.problem : "?", parser.problem ? strlen(parser.problem) : 1);
    }
    if (!yaml_document_get_root_node(&docs[ndocs])) {
      yaml_document_delete(&docs[ndocs]);
      break;
    }
    ndocs++;
  }

  canon_buf b = {0};
  long long nodes = 0;
  for (size_t i = 0; i < ndocs; i++) nodes += walk(&docs[i], yaml_document_get_root_node(&docs[i]), &b);
  printf("docs=%zu nodes=%lld crc=%u\n", ndocs, nodes, canon_crc32c((const unsigned char *)b.p, b.len));
  return 0;
}
