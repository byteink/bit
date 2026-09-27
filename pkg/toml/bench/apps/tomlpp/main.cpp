// toml++'s side of pkg/toml/bench (#6048). Same two modes and the same
// canonical checksum as ../bit/main.bit (see its header for the format).
// The parsed table is never destroyed: every other side exits with its
// tree still live, so a destructor walk would be a cost only this side paid.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "toml.hpp"

static uint32_t crctab[256];

static void crcinit() {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0x82F63B78u : c >> 1;
    crctab[i] = c;
  }
}

static uint32_t fold(uint32_t h, std::string_view s) {
  uint32_t c = ~h;
  for (unsigned char b : s) c = crctab[(c ^ b) & 0xff] ^ (c >> 8);
  return ~c;
}

static std::string pad(long n, int w) {
  std::string s = std::to_string(n);
  while ((int)s.size() < w) s = "0" + s;
  return s;
}

static std::string cdate(const toml::date& d) {
  return pad(d.year, 4) + "-" + pad(d.month, 2) + "-" + pad(d.day, 2);
}

static std::string ctim(const toml::time& t) {
  return pad(t.hour, 2) + ":" + pad(t.minute, 2) + ":" + pad(t.second, 2) + "." + pad(t.nanosecond, 9);
}

static int64_t count(const toml::node& n) {
  int64_t total = 0;
  if (auto t = n.as_table()) {
    total = (int64_t)t->size();
    for (auto&& [k, v] : *t) total += count(v);
  } else if (auto a = n.as_array()) {
    for (auto&& v : *a) total += count(v);
  }
  return total;
}

static uint32_t hashvalue(uint32_t h, const toml::node& n);

static uint32_t hashtable(uint32_t h, const toml::table& t) {
  std::vector<std::pair<std::string_view, const toml::node*>> kv;
  kv.reserve(t.size());
  for (auto&& [k, v] : t) kv.emplace_back(k.str(), &v);
  std::sort(kv.begin(), kv.end(), [](auto& a, auto& b) { return a.first < b.first; });
  h = fold(h, "T" + std::to_string(kv.size()) + ":");
  for (auto& [k, v] : kv) {
    h = fold(h, "K" + std::to_string(k.size()) + ":");
    h = fold(fold(h, k), "=");
    h = hashvalue(h, *v);
  }
  return fold(h, "}");
}

static uint32_t hashvalue(uint32_t h, const toml::node& n) {
  if (auto t = n.as_table()) return hashtable(h, *t);
  if (auto a = n.as_array()) {
    h = fold(h, "A" + std::to_string(a->size()) + ":");
    for (auto&& v : *a) h = hashvalue(h, v);
    return fold(h, "]");
  }
  if (auto s = n.as_string()) {
    const std::string& v = s->get();
    return fold(fold(h, "S" + std::to_string(v.size()) + ":"), v);
  }
  if (auto i = n.as_integer()) return fold(h, "I" + std::to_string(i->get()) + ";");
  if (n.is_floating_point()) return fold(h, "F;");
  if (auto b = n.as_boolean()) return fold(h, b->get() ? "Bt;" : "Bf;");
  if (auto d = n.as_date()) return fold(h, "D" + cdate(d->get()) + ";");
  if (auto t = n.as_time()) return fold(h, "M" + ctim(t->get()) + ";");
  if (auto dt = n.as_date_time()) {
    const toml::date_time& v = dt->get();
    std::string base = cdate(v.date) + "T" + ctim(v.time);
    if (!v.offset) return fold(h, "N" + base + ";");
    int m = v.offset->minutes;
    std::string sign = m < 0 ? "-" : "+";
    m = m < 0 ? -m : m;
    return fold(h, "O" + base + sign + pad(m / 60, 2) + ":" + pad(m % 60, 2) + ";");
  }
  return h;
}

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: tomlppbench <parse|checksum> <file.toml>\n");
    return 1;
  }
  std::ifstream f(argv[2], std::ios::binary);
  if (!f) {
    std::fprintf(stderr, "cannot read %s\n", argv[2]);
    return 1;
  }
  std::ostringstream ss;
  ss << f.rdbuf();
  const std::string src = ss.str();
  toml::table* doc = nullptr;
  try {
    doc = new toml::table(toml::parse(std::string_view(src), std::string_view(argv[2])));
  } catch (const toml::parse_error& e) {
    std::fprintf(stderr, "%s\n", std::string(e.description()).c_str());
    return 1;
  }
  int64_t n = count(*doc);
  if (std::strcmp(argv[1], "checksum") == 0) {
    crcinit();
    std::printf("entries=%lld hash=%u\n", (long long)n, hashvalue(0, *doc));
    return 0;
  }
  std::printf("entries=%lld\n", (long long)n);
  return 0;
}
