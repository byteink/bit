// scripts/regex-oracle/main.go — the Go half of #2057's differential
// fuzzer (epic #2025). Runs entirely inside the throwaway Docker container
// scripts/regex-difffuzz.sh drives; never installed on the host.
//
// A pure ORACLE, not a generator: this program does zero randomness. It
// reads the corpus tools/fuzz/regexdifffuzz.bit already generated
// (patterns.hex, subjects.hex — both host-written, both plain text, hex
// so a subject's raw or malformed UTF-8 bytes round-trip with no escaping
// question) and answers each pattern/subject pair with Go's own regexp,
// in the identical line format that Bit's own run produces
// (bit-results.tsv), so the orchestrator can diff the two directly:
//
//	IDX  KIND  COMPILEOK  MATCHED  SUBMATCH  FINDALL  REPLACEHEX  SPLITHEX
//
// SUBMATCH is "s:e,s:e,..." for group 0 (whole match) through the pattern's
// last group, "-1:-1" for a group that did not participate, using Go's own
// FindStringSubmatchIndex — the same leftmost-first convention std/regex's
// own header claims (stdlib/regex/regex.bit:1-20). FINDALL is every
// non-overlapping match's "s:e" pair from FindAllStringIndex(-1). Both are
// literal "-" when the pattern never compiled or never matched, so every
// pattern contributes exactly len(subjects-for-that-pattern) result lines
// on both sides regardless of outcome — a fixed line count keeps the
// orchestrator's diff a plain line-for-line comparison, never a counted
// one.
//
// REPLACEHEX is ReplaceAllString(subject, template) hex-encoded (the output
// can contain raw UTF-8 or, from a mutated pattern, garbage bytes — hex
// removes any escaping question). The template mirrors what the Bit side
// built from the SAME pattern's own group count (regexdifffuzz.bit's
// replaceTemplate): "${0}" with no groups, "${1}" with exactly one, else
// "${1}|${2}". SPLITHEX is Split(subject, -1)'s pieces, each hex-encoded,
// comma-joined.
//
// Known-divergent patterns (e.g. Bit's `(?<name>...)` spelling, which Go's
// regexp/syntax does not accept) still get a COMPILEOK line here — this
// program does not consult regex-known-divergent.txt at all. Skipping a
// flagged pattern's comparison is the ORCHESTRATOR's job
// (scripts/regex-difffuzz.sh), precisely so this oracle stays exactly what
// its name says: it only ever answers "what does Go's regexp say", never
// "should this disagreement count".
package main

import (
	"bufio"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// One pattern's compiled state — a nil Regexp with compileOK=false when
// regexp.Compile rejected the pattern, exactly the shape a fallible
// `compile()` on the Bit side hits its own catch arm for.
type compiled struct {
	re  *regexp.Regexp
	ok  bool
	pat string
}

func main() {
	in := flag.String("in", "", "directory holding patterns.hex and subjects.hex")
	out := flag.String("out", "", "path to write go-results.tsv")
	flag.Parse()
	if *in == "" || *out == "" {
		log.Fatal("usage: regex-oracle --in DIR --out FILE")
	}

	patterns, err := loadPatterns(*in + "/patterns.hex")
	if err != nil {
		log.Fatalf("regex-oracle: patterns.hex: %v", err)
	}

	outFile, err := os.Create(*out)
	if err != nil {
		log.Fatalf("regex-oracle: create %s: %v", *out, err)
	}
	defer outFile.Close()
	w := bufio.NewWriter(outFile)
	defer w.Flush()

	compiledByIdx := compileAll(patterns)

	if err := processSubjects(*in+"/subjects.hex", compiledByIdx, w); err != nil {
		log.Fatalf("regex-oracle: subjects.hex: %v", err)
	}
}

// patterns.hex: IDX \t DIVERGENT(0/1) \t HEXPATTERN — DIVERGENT is unused
// here (see header: the orchestrator consults it, not this oracle).
func loadPatterns(path string) (map[int]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[int]string{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		cols := strings.Split(sc.Text(), "\t")
		if len(cols) != 3 {
			return nil, fmt.Errorf("malformed line: %q", sc.Text())
		}
		idx, err := strconv.Atoi(cols[0])
		if err != nil {
			return nil, err
		}
		raw, err := hex.DecodeString(cols[2])
		if err != nil {
			return nil, err
		}
		out[idx] = string(raw)
	}
	return out, sc.Err()
}

func compileAll(patterns map[int]string) map[int]compiled {
	out := make(map[int]compiled, len(patterns))
	for idx, pat := range patterns {
		re, err := regexp.Compile(pat)
		out[idx] = compiled{re: re, ok: err == nil, pat: pat}
	}
	return out
}

// subjects.hex: IDX \t KIND \t HEXSUBJECT. Streams rather than loading the
// whole corpus, since --count 10000 * 5 subjects can be a large file.
func processSubjects(path string, byIdx map[int]compiled, w *bufio.Writer) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		cols := strings.Split(sc.Text(), "\t")
		if len(cols) != 3 {
			return fmt.Errorf("malformed line: %q", sc.Text())
		}
		idx, err := strconv.Atoi(cols[0])
		if err != nil {
			return err
		}
		kind := cols[1]
		raw, err := hex.DecodeString(cols[2])
		if err != nil {
			return err
		}
		c, known := byIdx[idx]
		if !known {
			return fmt.Errorf("subject references unknown pattern idx %d", idx)
		}
		fmt.Fprintln(w, resultLine(idx, kind, c, string(raw)))
	}
	return sc.Err()
}

func resultLine(idx int, kind string, c compiled, subject string) string {
	if !c.ok {
		return fmt.Sprintf("%d\t%s\t0\t-\t-\t-\t-\t-", idx, kind)
	}
	loc := c.re.FindStringSubmatchIndex(subject)
	matched := 0
	submatch := "-"
	if loc != nil {
		matched = 1
		submatch = submatchCsv(loc)
	}
	findAll := findAllCsv(c.re, subject)
	repl := hex.EncodeToString([]byte(c.re.ReplaceAllString(subject, replaceTemplate(c.re))))
	split := splitHexCsv(c.re, subject)
	return fmt.Sprintf("%d\t%s\t1\t%d\t%s\t%s\t%s\t%s", idx, kind, matched, submatch, findAll, repl, split)
}

// "s:e,s:e,..." for group 0 (whole match) through the last group, "-1:-1"
// for a group `loc` marks unset (Go writes -1 for those slots itself).
func submatchCsv(loc []int) string {
	var b strings.Builder
	for i := 0; i < len(loc); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, "%d:%d", loc[i], loc[i+1])
	}
	return b.String()
}

func findAllCsv(re *regexp.Regexp, subject string) string {
	locs := re.FindAllStringIndex(subject, -1)
	if len(locs) == 0 {
		return "-"
	}
	var b strings.Builder
	for i, l := range locs {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, "%d:%d", l[0], l[1])
	}
	return b.String()
}

// Mirrors tools/fuzz/regexdifffuzz.bit's replaceTemplate exactly: the
// group-count-driven template both sides feed to their own replaceAll, so
// the two engines are asked the identical question.
func replaceTemplate(re *regexp.Regexp) string {
	groups := re.NumSubexp()
	if groups >= 2 {
		return "<${1}|${2}>"
	}
	if groups == 1 {
		return "<${1}>"
	}
	return "<${0}>"
}

func splitHexCsv(re *regexp.Regexp, subject string) string {
	pieces := re.Split(subject, -1)
	var b strings.Builder
	for i, p := range pieces {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(hex.EncodeToString([]byte(p)))
	}
	if len(pieces) == 0 {
		return "-"
	}
	return b.String()
}
