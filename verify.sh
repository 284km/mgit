#!/bin/sh
# verify.sh — mgit against git itself.
#
#   MERE=/path/to/mere-checkout sh verify.sh [--poison]
#   MGIT_BIG=/path/to/a/real/repo MERE=... sh verify.sh    also the whole of
#                                                           a real repository
#
# The fixture is a repository built here with git: a merge (so first-parent is
# a real question), an annotated and a lightweight tag, an executable, a
# symlink, nested directories, and a file rewritten a little in each commit so
# that `git gc` stores most of its versions as deltas -- then more commits
# after the gc, so the store is packs AND loose objects. What is checked:
#
#   every object   `mgit cat-file --batch-all-objects` == `git cat-file
#                  --batch-all-objects --batch`, byte for byte
#   every id       each object's content hashes to its id (verify-ids), and a
#                  loose object swapped for another's is reported
#   refs           rev-parse of HEAD, a branch, both tags, an id
#   history        log --first-parent == git's, rev-list --all == git's (as a set)
#   trees          ls-tree -r of HEAD and of the annotated tag; cat-file -t -s -p
#                  of a commit, a tree, a blob and a tag
#
# Both deps are imported from .mere_modules/ (mgz, msha): `mere install`, or
# symlinks to checkouts.
#
# --poison drops the "+1 per continuation" from the offset-delta varint, which
# only matters for a base more than 127 bytes back -- the object comparison
# must catch it.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -n "${MERE:-}" ] || { echo "usage: MERE=/path/to/mere-checkout sh verify.sh" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "verify: $M not found (dune build?)" >&2; exit 2; }
command -v git >/dev/null || { echo "verify: git not found -- it is the oracle" >&2; exit 2; }
[ -e "$DIR/.mere_modules/mgz/inflate.mere" ] && [ -e "$DIR/.mere_modules/msha/sha1.mere" ] \
  || { echo "verify: .mere_modules/mgz and .mere_modules/msha are needed (mere install)" >&2; exit 2; }
CC="${CC:-cc}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- the fixture ------------------------------------------------------------
R="$TMP/repo"
mkdir -p "$R" && cd "$R" || exit 2
g() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
g init -q -b main .
python3 - <<'PY'
import random
random.seed(7)
lines = [f"line {i}: " + "".join(random.choice("abcdefgh ") for _ in range(60)) for i in range(4000)]
open("big.txt", "w").write("\n".join(lines) + "\n")
PY
mkdir -p a/b/c && echo nested > a/b/c/deep.txt && printf '#!/bin/sh\necho hi\n' > run.sh && chmod +x run.sh
ln -s a/b/c/deep.txt link
g add -A && g commit -qm "first"
i=1
while [ $i -le 12 ]; do
  python3 - "$i" <<'PY'
import sys
i = int(sys.argv[1])
ls = open("big.txt").read().split("\n")
for k in range(i * 37 % 4000, len(ls), 400):
    ls[k] = ls[k] + f" edit{i}"
open("big.txt", "w").write("\n".join(ls))
PY
  echo "$i" > "a/n$i.txt"
  g add -A && g commit -qm "edit $i"
  i=$((i + 1))
done
g tag light
g tag -a -m "an annotated tag" v1
g checkout -qb side && echo side > side.txt && g add -A && g commit -qm "side"
g checkout -q main && echo main > main.txt && g add -A && g commit -qm "main moves"
g merge -q --no-edit side
g gc -q --aggressive
echo after-gc >> big.txt && g add -A && g commit -qm "after gc: loose again"
cd "$DIR" || exit 2
packed=$(cd "$R" && git count-objects -v | awk '/^in-pack/{print $2}')
loose=$(cd "$R" && git count-objects -v | awk '/^count/{print $2}')
deltas=$(cd "$R" && git verify-pack -v .git/objects/pack/*.idx | awk 'NF >= 7 && $2 ~ /blob|tree|commit|tag/ {d++} END {print d+0}')

build() {  # $1 = source dir, $2 = binary
  "$M" -c "$1/mgit.mere" > "$TMP/mgit.c" 2>"$TMP/err" || { echo "FAIL verify: mere -c"; head -8 "$TMP/err"; return 1; }
  "$CC" -O2 -w "$TMP/mgit.c" -o "$2" || { echo "FAIL verify: cc"; return 1; }
}

run_checks() {  # $1 = mgit binary, $2 = repo
  B="$1"; REPO="$2"; bad=0
  same() {  # $1 = what, $2 = mgit args, $3 = git args
    "$B" -C "$REPO" $2 > "$TMP/m" 2>&1
    (cd "$REPO" && git $3 > "$TMP/g" 2>&1)
    cmp -s "$TMP/m" "$TMP/g" || { echo "FAIL $1"; diff "$TMP/m" "$TMP/g" | head -3; bad=$((bad + 1)); }
  }
  "$B" -C "$REPO" cat-file --batch-all-objects > "$TMP/m.all" 2>"$TMP/m.err"
  (cd "$REPO" && git cat-file --batch-all-objects --batch > "$TMP/g.all")
  cmp -s "$TMP/m.all" "$TMP/g.all" || { echo "FAIL every object: the batch differs"; cmp "$TMP/m.all" "$TMP/g.all" | head -1; head -2 "$TMP/m.err"; bad=$((bad + 1)); }
  "$B" -C "$REPO" verify-ids > "$TMP/v" 2>&1 || { echo "FAIL every id: $(tail -1 "$TMP/v")"; bad=$((bad + 1)); }
  for r in HEAD main side light v1 "$(cd "$REPO" && git rev-parse HEAD~2)"; do
    same "rev-parse $r" "rev-parse $r" "rev-parse $r"
  done
  same "log --first-parent" "log --first-parent" "log --first-parent --format=%H"
  "$B" -C "$REPO" rev-list --all | sort > "$TMP/m"; (cd "$REPO" && git rev-list --all | sort) > "$TMP/g"
  cmp -s "$TMP/m" "$TMP/g" || { echo "FAIL rev-list --all"; bad=$((bad + 1)); }
  same "ls-tree -r HEAD" "ls-tree -r HEAD" "ls-tree -r HEAD"
  same "ls-tree -r v1" "ls-tree -r v1" "ls-tree -r v1"
  tree=$(cd "$REPO" && git rev-parse 'HEAD^{tree}'); blob=$(cd "$REPO" && git rev-parse HEAD:big.txt); tag=$(cd "$REPO" && git rev-parse v1)
  for o in HEAD "$tree" "$blob" "$tag"; do
    for f in -t -s -p; do same "cat-file $f $o" "cat-file $f $o" "cat-file $f $o"; done
  done
  [ $bad -eq 0 ] || { echo "verify: $bad problem(s)"; return 1; }
}

build "$DIR" "$TMP/mgit" || exit 1

if [ "${1:-}" = "--poison" ]; then
  mkdir -p "$TMP/p"; cp "$DIR"/*.mere "$TMP/p/"; ln -s "$DIR/.mere_modules" "$TMP/p/.mere_modules"
  python3 - "$TMP/p/store.mere" <<'PY' || { echo "FAIL poison: fragment not found"; exit 1; }
import sys
p = sys.argv[1]; s = open(p).read()
a = "if c < 128 then (acc2, q + 1) else ofs (q + 1) (acc2 + 1) in"
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, "if c < 128 then (acc2, q + 1) else ofs (q + 1) acc2 in"))
PY
  build "$TMP/p" "$TMP/pmgit" || exit 1
  if run_checks "$TMP/pmgit" "$R" > "$TMP/poison.log" 2>&1; then echo "FAIL poison: an offset varint without its +1 passed"; exit 1; fi
  grep -q "^FAIL every object" "$TMP/poison.log" || { echo "FAIL poison: CAUGHT FOR THE WRONG REASON"; head -3 "$TMP/poison.log"; exit 1; }
  echo "ok | poison caught (the offset-delta varint without its +1)"; exit 0
fi

run_checks "$TMP/mgit" "$R" || exit 1
n=$(grep -c '^[0-9a-f]\{40\} ' "$TMP/g.all")
echo "ok | fixture: $n objects ($packed packed, $deltas of them deltas; $loose loose) -- batch, ids, refs, history, trees"

# a loose object swapped for another's must be reported by verify-ids
cp -R "$R" "$TMP/bad"
a=$(cd "$TMP/bad" && git rev-parse HEAD); b=$(cd "$TMP/bad" && git rev-parse 'HEAD^{tree}')
for x in "$a" "$b"; do [ -f "$TMP/bad/.git/objects/$(echo $x | cut -c1-2)/$(echo $x | cut -c3-)" ] || { echo "FAIL verify: fixture HEAD is not loose"; exit 1; }; done
chmod u+w "$TMP/bad/.git/objects/$(echo $a | cut -c1-2)/$(echo $a | cut -c3-)"
cp "$TMP/bad/.git/objects/$(echo $b | cut -c1-2)/$(echo $b | cut -c3-)" "$TMP/bad/.git/objects/$(echo $a | cut -c1-2)/$(echo $a | cut -c3-)"
if "$TMP/mgit" -C "$TMP/bad" verify-ids > "$TMP/v" 2>&1; then echo "FAIL every id: a swapped object was not reported"; exit 1; fi
grep -q "^mismatch $a" "$TMP/v" || { echo "FAIL every id: reported, but not $a"; exit 1; }
echo "ok | a loose object swapped for another's is reported by verify-ids"

if [ -n "${MGIT_BIG:-}" ]; then
  run_checks "$TMP/mgit" "$MGIT_BIG" || exit 1
  echo "ok | $MGIT_BIG: $(grep -c '^[0-9a-f]\{40\} ' "$TMP/g.all") objects, everything above"
fi
echo "verify: ok"
