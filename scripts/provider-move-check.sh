#!/usr/bin/env bash
# provider-move-check.sh (#2549) — prove a runtime "provider move" (hoisting a
# function out of runtime/<mod>/{linux,darwin}/*.bit into the shared core
# runtime/<mod>/<mod>.bit, the refactor #2551-#2554 do) changed nothing a
# program can observe.
#
# Usage: bash scripts/provider-move-check.sh <root|net|thread|park>
#
# Step 1: BASE = `git merge-base HEAD main` — the commit the branch forked
#         from, reconstructed via `git archive` into scratch so cross-module
#         imports (root imports `../sched`, `../gc`, `../alloc`; picking those
#         apart by hand would silently drift as the import graph changes)
#         resolve exactly as they do for the working tree.
# Step 2: for the module's core directory plus its linux/ and darwin/
#         provider directories, `--emit-obj` each one at BASE and at the
#         working tree, for every (directory, target) pair
#         scripts/g2archive.sh's own PLATFORM_PAIRS list builds this module
#         for: core is compiled once per target (ISA differs even though the
#         source is platform-free), each provider only for the target(s) that
#         actually link it.
# Step 3: `cmp` each BASE/working-tree pair; print PASS/FAIL per pair.
# Step 4: declaration-set diff (#3537, replacing the retired line-multiset
#         arm — see the comment at that step for why: a raw line multiset
#         cannot pass for ANY real provider dedup, because collapsing N
#         identical copies into 1 shared declaration changes the line count
#         by construction, and the mandatory `export`/`import` plumbing
#         changes it again). This arm dumps every top-level declaration in
#         the module's core files plus both provider directories via
#         `bit --dump-ast` (comments/whitespace-free, so it normalizes for
#         free) and diffs the SET of declarations, after stripping the
#         `import_decl` plumbing and the mandatory `export` wrapper a moved
#         declaration gains. It still fails on a dropped declaration, a
#         changed body, or a declaration now duplicated where it wasn't
#         before (see the step's own comment for the exact invariant).
#
# Every FAIL prints an explanation; the script exits 1 if any check failed,
# 0 if every check passed. Nothing under runtime/ is ever written — BASE's
# source is read with `git archive` into $(mktemp -d), the working tree is
# read in place, and cmp's/perl's own scratch objects live in the same
# mktemp dir.
set -u

usage() {
  echo "usage: bash scripts/provider-move-check.sh <root|net|thread|park>" >&2
  exit 2
}

MODULE=${1:-}
case "$MODULE" in
  root | net | thread | park) ;;
  *) usage ;;
esac

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
BIT="$REPO_ROOT/bit-out/bin/bit"
if [ ! -x "$BIT" ]; then
  echo "provider-move-check: '$BIT' not found or not executable (build it first: ./make)" >&2
  exit 1
fi

BASE=$(git -C "$REPO_ROOT" merge-base HEAD main) || exit 1
echo "provider-move-check: module=$MODULE base=$BASE"

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# Reads one `bit --dump-ast` s-expression (the whole "(program ...)" form)
# from stdin, prints one NORMALIZED top-level declaration per output line as
# "<name>\t<form>". Drops import_decl (plumbing, not content); strips an
# outer (export ...) wrapper (a moved declaration crossing a module boundary
# must gain this — it is not a content change); strips a func_decl's
# trailing (attr_list ...) child (@nosplit/@symbol are linkage/codegen
# hints, not content — this repo's own dedup methodology,
# docs/development/provider-duplication.md, judges two copies the same
# "signature excluded", and an actual @symbol change that breaks an
# external caller is still caught by the --emit-obj build above).
AST_SPLIT_PL="$SCRATCH/ast-split.pl"
cat >"$AST_SPLIT_PL" <<'PERL_EOF'
use strict;
use warnings;

# Splits "(tag c1 c2 ...)" into (tag, c1, c2, ...), respecting nested
# parens and quoted strings, at depth-1 boundaries only.
sub split_children {
    my ($s) = @_;
    die "not a parenthesized form: $s\n" unless $s =~ /^\((.*)\)$/s;
    my $inner = $1;
    my @out;
    my $len = length($inner);
    my $i = 0;
    while ($i < $len) {
        while ($i < $len && substr($inner, $i, 1) eq ' ') { $i++; }
        last if $i >= $len;
        my $c = substr($inner, $i, 1);
        if ($c eq '(') {
            my $start = $i;
            my $depth = 0;
            my $in_str = 0;
            while ($i < $len) {
                my $ch = substr($inner, $i, 1);
                if ($in_str) {
                    if ($ch eq '\\') { $i += 2; next; }
                    $in_str = 0 if $ch eq '"';
                } elsif ($ch eq '"') {
                    $in_str = 1;
                } elsif ($ch eq '(') {
                    $depth++;
                } elsif ($ch eq ')') {
                    $depth--;
                }
                $i++;
                last if $depth == 0;
            }
            push @out, substr($inner, $start, $i - $start);
        } elsif ($c eq '"') {
            my $start = $i;
            $i++;
            while ($i < $len) {
                my $ch = substr($inner, $i, 1);
                if ($ch eq '\\') { $i += 2; next; }
                $i++;
                last if $ch eq '"';
            }
            push @out, substr($inner, $start, $i - $start);
        } else {
            my $start = $i;
            while ($i < $len && substr($inner, $i, 1) ne ' ') { $i++; }
            push @out, substr($inner, $start, $i - $start);
        }
    }
    return @out;
}

sub strip_attrs {
    my ($form) = @_;
    my @kids = split_children($form);
    return $form if @kids < 2;
    if ($kids[-1] =~ /^\(attr_list\b/) {
        pop @kids;
        return "(" . join(" ", @kids) . ")";
    }
    return $form;
}

my $text = do { local $/; <STDIN> };
$text =~ s/^\s+|\s+$//g;
exit 0 if $text eq '';

my @top = split_children($text);
shift @top; # the "program" tag itself

for my $form (@top) {
    next if $form =~ /^\(import_decl\b/;
    if ($form =~ /^\(export /) {
        my @k = split_children($form);
        $form = $k[1];
    }
    $form = strip_attrs($form);
    my $name = "?";
    if ($form =~ /\(binding\s+([A-Za-z_][A-Za-z0-9_]*)/) {
        $name = $1;
    } elsif ($form =~ /^\(([a-z_]+)\s+(?:_\s+)?([A-Za-z_][A-Za-z0-9_]*)/) {
        $name = $2;
    }
    print "$name\t$form\n";
}
PERL_EOF

# $1 = directory to scan (maxdepth 1, *.bit), $2 = file to APPEND normalized
# "<name>\t<form>" lines to. Sets DECLSET_DUMP_FAIL=1 and prints a FAIL line
# if `--dump-ast` itself fails on any file (a real parse error, not a move
# defect this arm can characterize further).
ast_decls() {
  local dir=$1 out=$2 f dump err rc
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    dump=$(mktemp "$SCRATCH/dump.XXXXXX") || exit 1
    err=$(mktemp "$SCRATCH/dumperr.XXXXXX") || exit 1
    "$BIT" --dump-ast "$f" >"$dump" 2>"$err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "FAIL declset $MODULE (--dump-ast failed on $f, rc=$rc)"
      sed 's/^/  /' "$err" >&2
      DECLSET_DUMP_FAIL=1
      continue
    fi
    perl "$AST_SPLIT_PL" <"$dump" >>"$out"
  done < <(find "$dir" -maxdepth 1 -name '*.bit')
}

BASE_RT="$SCRATCH/base/runtime"
mkdir -p "$SCRATCH/base"
if ! (cd "$REPO_ROOT" && git archive "$BASE" -- runtime) | tar -x -C "$SCRATCH/base"; then
  echo "provider-move-check: failed to reconstruct runtime/ at $BASE" >&2
  exit 1
fi
WORK_RT="$REPO_ROOT/runtime"

# --- Step 2/3 data table: (relative provider dir, "-" for the core dir
# itself) paired with every target that dir is actually built for, matching
# scripts/g2archive.sh's PLATFORM_PAIRS entries for this module. ---
PAIR_RELS=(- - - linux linux darwin)
PAIR_TARGETS=(x86_64-linux aarch64-linux aarch64-macos x86_64-linux aarch64-linux aarch64-macos)

FAIL=0
CMP_FAIL=0
i=0
while [ "$i" -lt "${#PAIR_RELS[@]}" ]; do
  rel=${PAIR_RELS[$i]}
  target=${PAIR_TARGETS[$i]}
  i=$((i + 1))
  if [ "$rel" = "-" ]; then
    base_dir="$BASE_RT/$MODULE"
    work_dir="$WORK_RT/$MODULE"
    label="$MODULE"
  else
    base_dir="$BASE_RT/$MODULE/$rel"
    work_dir="$WORK_RT/$MODULE/$rel"
    label="$MODULE/$rel"
  fi
  tag="${label//\//_}_${target}"

  if [ ! -d "$base_dir" ] || [ ! -d "$work_dir" ]; then
    echo "FAIL cmp $label @ $target (directory missing: base=$base_dir work=$work_dir)"
    FAIL=1
    CMP_FAIL=1
    continue
  fi

  base_obj="$SCRATCH/${tag}_base.o"
  work_obj="$SCRATCH/${tag}_work.o"
  base_err="$SCRATCH/${tag}_base.err"
  work_err="$SCRATCH/${tag}_work.err"

  "$BIT" build "$base_dir" --emit-obj --freestanding --target "$target" -o "$base_obj" >"$base_err" 2>&1
  base_rc=$?
  "$BIT" build "$work_dir" --emit-obj --freestanding --target "$target" -o "$work_obj" >"$work_err" 2>&1
  work_rc=$?

  if [ "$base_rc" -ne 0 ] || [ "$work_rc" -ne 0 ]; then
    echo "FAIL cmp $label @ $target (build failed: base_rc=$base_rc work_rc=$work_rc)"
    [ "$base_rc" -ne 0 ] && sed 's/^/  base: /' "$base_err" >&2
    [ "$work_rc" -ne 0 ] && sed 's/^/  work: /' "$work_err" >&2
    FAIL=1
    CMP_FAIL=1
    continue
  fi

  if cmp -s "$base_obj" "$work_obj"; then
    echo "PASS cmp $label @ $target"
  else
    echo "FAIL cmp $label @ $target ($(cmp "$base_obj" "$work_obj" 2>&1))"
    FAIL=1
    CMP_FAIL=1
  fi
done

# --- Step 4: declaration-set diff over the core dir plus both providers. ---
DECLSET_DUMP_FAIL=0
base_decls="$SCRATCH/${MODULE}_base_decls.txt"
work_decls="$SCRATCH/${MODULE}_work_decls.txt"
: >"$base_decls"
: >"$work_decls"
for rel in "" linux darwin; do
  if [ -z "$rel" ]; then
    bdir="$BASE_RT/$MODULE"
    wdir="$WORK_RT/$MODULE"
  else
    bdir="$BASE_RT/$MODULE/$rel"
    wdir="$WORK_RT/$MODULE/$rel"
  fi
  ast_decls "$bdir" "$base_decls"
  ast_decls "$wdir" "$work_decls"
done

DECLSET_PASS=1
if [ "$DECLSET_DUMP_FAIL" -eq 1 ]; then
  FAIL=1
  DECLSET_PASS=0
else
  # One AWK pass: count occurrences of each normalized "<name>\t<form>" line
  # on both sides, then apply the three-way invariant a correct provider
  # dedup must satisfy:
  #   - every distinct declaration in BASE must still exist in WORK
  #     (MISSING — catches a dropped declaration, and a body edit: an
  #     edited body no longer matches its old normalized form at all);
  #   - every distinct declaration in WORK must have existed in BASE
  #     (ADDED — catches an edited or fabricated body, the other half of
  #     the body-edit case above: the new text is "added" content);
  #   - no distinct declaration may occur MORE times in WORK than it did
  #     in BASE (DUPLICATED — a correct N-copies-to-1 dedup only ever
  #     REDUCES a form's count; an increase means the move left the
  #     original behind instead of deleting it). Two providers legitimately
  #     sharing an as-yet-undeduped duplicate is unaffected: it is counted
  #     equally on both sides and never flagged.
  diff_out="$SCRATCH/${MODULE}_declset_diff.txt"
  LC_ALL=C awk -F'\t' '
    FNR == NR { bc[$0]++; bn[$0] = $1; next }
    { wc[$0]++; wn[$0] = $1 }
    END {
      for (k in bc) if (!(k in wc)) print "MISSING\t" bn[k] "\t" k
      for (k in wc) if (!(k in bc)) print "ADDED\t" wn[k] "\t" k
      for (k in bc) if ((k in wc) && wc[k] > bc[k]) {
        print "DUPLICATED\t" bn[k] "\t" k " (was " bc[k] "x, now " wc[k] "x)"
      }
    }
  ' "$base_decls" "$work_decls" | LC_ALL=C sort >"$diff_out"

  if [ -s "$diff_out" ]; then
    FAIL=1
    DECLSET_PASS=0
    while IFS=$'\t' read -r kind name _; do
      case "$kind" in
        MISSING) echo "FAIL declset $MODULE: declaration dropped: $name" ;;
        ADDED) echo "FAIL declset $MODULE: declaration added or changed: $name" ;;
        DUPLICATED) echo "FAIL declset $MODULE: declaration left behind at the old site: $name" ;;
      esac
    done <"$diff_out"
  else
    echo "PASS declset $MODULE"
  fi
fi

# A cmp FAIL here does not by itself mean content changed: this compiler lays
# functions out in source-declaration order (verified #2549 by disassembling
# both sides of a pure reposition — the actual instructions were identical,
# only their file offsets moved), so ANY reordering, including a legitimate
# provider hoist, changes these raw object bytes. declset is the
# authoritative "no content was gained or lost" signal; read a cmp FAIL
# alongside a declset PASS as "repositioned, not changed".
if [ "$CMP_FAIL" -eq 1 ] && [ "$DECLSET_PASS" -eq 1 ]; then
  echo "NOTE: cmp FAILed but declset PASSed — the object's raw bytes moved" >&2
  echo "  (declaration order shifted where code sits in the section), but no" >&2
  echo "  declaration was gained, lost or altered. See this script's header." >&2
fi

exit "$FAIL"
