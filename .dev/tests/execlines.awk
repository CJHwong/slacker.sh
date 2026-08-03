# execlines.awk — which physical lines of a bash script can produce an xtrace
# record. This is the denominator for coverage.sh; getting it wrong is the
# difference between a real number and a demoralizing fake one.
#
# Two facts about bash drive the whole design:
#
#  1. Bash traces *commands*, not lines. A 20-line jq program in single quotes is
#     one command and emits one record. Counting its interior as 19 uncovered
#     lines would peg every action near 40% no matter how well tested it is.
#  2. Bash's line attribution across a multi-line construct is not uniform. A
#     multi-line simple command is reported at its *first* line, but an
#     `|| { …; return 1; }` arm spread over continuation lines gets reported
#     against an interior line.
#
# So this predicts the first line of each command, and additionally treats an
# operator-led continuation line as a command of its own. Quotes, backslash
# continuations, and heredoc bodies are tracked because no line-oriented filter
# can guess them. Modelling the interior more aggressively (predicting the end
# line instead) was measurably worse: it invented misses on argument-continuation
# lines like `--arg id "$fileid"` that bash never reports.
#
# Also skipped, because bash emits no record for them:
#   - blanks and comments
#   - pure block syntax (fi / done / esac / else / then / do / braces / ;;)
#   - case-pattern labels (`foo)` and `foo|bar)`)
#   - function definition headers (defining is not executing)
#
#   awk -f execlines.awk -v mode=count file   -> the count
#   awk -f execlines.awk -v mode=list  file   -> one executable line number per line
#
# coverage.sh unions this with the lines bash actually traced, so a miss here
# can only ever cost a little accuracy, never silently inflate the percentage.
# SLACKER_COV_AUDIT=1 prints the gap between prediction and observation.
BEGIN { in_s = 0; in_d = 0; cont = 0; hd = ""; n = 0 }
{
  line = $0

  # Heredoc body: part of the command that opened it, so nothing in it is
  # separately executable.
  if (hd != "") {
    t = line; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    if (t == hd) hd = ""
    next
  }

  continuation = (cont || in_s || in_d)

  if (continuation) {
    # A continued line still starts a *new* command when it opens with a pipeline
    # or list operator — `| jq …`, `|| { slacker_error …; return 1; }`. Those are
    # traced separately, and several are error arms no test may reach, so missing
    # them would understate the work left to do.
    t = line; sub(/^[ \t]+/, "", t)
    emit = (!in_s && !in_d && t ~ /^(\|\||&&|\|[^|])/) ? 1 : 0
  } else {
    t = line
    sub(/^[ \t]+/, "", t)
    emit = 1
    if (t == "" || substr(t, 1, 1) == "#")                                      emit = 0
    else if (t ~ /^(fi|done|esac|else|do|then|\{|\}|\)|;;|;&|fi;|done;)[ \t]*$/) emit = 0
    else if (t ~ /^\(?[^ \t()|]*(\|[^ \t()|]*)*\)[ \t]*$/ && t !~ /\(/)         emit = 0
    else if (t ~ /^function[ \t]/)                                              emit = 0
    else if (t ~ /^[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\([ \t]*\)[ \t]*\{?[ \t]*$/)   emit = 0
  }
  if (emit) { n++; if (mode == "list") print FNR }

  # --- lexical state for the next line ------------------------------------
  i = 1; L = length(line)
  while (i <= L) {
    c = substr(line, i, 1)
    if (in_s) {
      if (c == "'") in_s = 0
    } else if (in_d) {
      if (c == "\\") i++
      else if (c == "\"") in_d = 0
    } else {
      if (c == "\\") i++
      else if (c == "'") in_s = 1
      else if (c == "\"") in_d = 1
      else if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(]/)) break
      else if (c == "<" && substr(line, i, 2) == "<<") {
        j = i + 2
        if (substr(line, j, 1) == "-") j++
        if (substr(line, j, 1) == "<") { i = j; continue }   # <<< is a herestring
        q = substr(line, j, 1)
        if (q == "'" || q == "\"") { j++ } else { q = "" }
        w = ""
        while (j <= L) {
          c2 = substr(line, j, 1)
          if (q == "" && c2 !~ /[A-Za-z0-9_]/) break
          if (q != "" && c2 == q) { j++; break }
          w = w c2; j++
        }
        if (w != "") hd = w
        i = j; continue
      }
    }
    i++
  }
  cont = (in_s || in_d) ? 0 : (line ~ /\\$/)

}
END { if (mode != "list") print n + 0 }
