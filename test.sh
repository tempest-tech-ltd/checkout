#!/bin/bash
# Integration tests for git-checkout.sh, against real repositories.
#
#   ./test.sh            run under bash
#   SH=dash ./test.sh    run the script under dash (the agents run it on
#                        git-bash and on macOS, where bash is still 3.2)
set -u

SCRIPT=$(cd "$(dirname "$0")" && pwd)/git-checkout.sh
SH=${SH:-bash}
T=$(mktemp -d)
# Several cases here wait out the fetch retries. The defaults are what runs on
# an agent, not what a suite can afford.
: "${GIT_FETCH_RETRIES:=2}"
: "${GIT_FETCH_DELAY:=1}"
export GIT_FETCH_RETRIES GIT_FETCH_DELAY

PASS=0; FAIL=0; SKIP=0
ok()    { PASS=$((PASS+1)); echo "ok   - $1"; }
bad()   { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1 (want '$2', got '$3')"; }
rc_is() { [ "$2" = "$RC" ] && ok "$1 (rc=$RC)" || bad "$1 (want rc=$2, got rc=$RC)"; }
has()   { echo "$OUT" | grep -q "$2" && ok "$1" || bad "$1 (output lacks '$2')"; }
hasnt() { echo "$OUT" | grep -q "$2" && bad "$1 (output has '$2')" || ok "$1"; }
skip()  { SKIP=$((SKIP+1)); echo "skip - $1"; }
# git-bash hands git a windows spelling of a posix path and gives it back that
# way, so two strings can name one directory. Compare as directories.
abspath() { ( cd "$1" 2>/dev/null && { [ "${MSYSTEM:-}" ] && pwd -W || pwd -P; } ); }
is_path() {
	[ "$2" = "$3" ] && { ok "$1"; return; }
	A=$(abspath "$2"); B=$(abspath "$3")
	[ -n "$A" ] && [ "$A" = "$B" ] && ok "$1" || bad "$1 (want '$2', got '$3')"
}
objects() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

RUN() { local wd=$1; shift; OUT=$(cd "$wd" && "$SH" "$SCRIPT" "$@" 2>&1); RC=$?; }

# --- an origin with a couple of commits, and a work area ------------------
git -c init.defaultBranch=main init -q --bare "$T/origin.git"
git -c init.defaultBranch=main init -q "$T/seed"
cd "$T/seed"; git config user.email t@t; git config user.name t
echo one > a; mkdir sub; echo steady > sub/b
git add .; git commit -qm c1
echo two > a; git commit -qam c2
git push -q "$T/origin.git" main
cd /

# Moves origin/main on: the content of 'a' is the name of the commit.
advance() { ( cd "$T/seed" && echo "$1" > a && git commit -qam "$1" && git push -q "$T/origin.git" main ); }

W=$T/ws; mkdir -p "$W"
ARGS=(--repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref main)
HEAL="SELF-HEAL"
TARGET_HEAL="SELF-HEAL: target git-dir"

echo "# checkout under $SH ($("$SH" -c 'echo $0') / git $(git --version | awk '{print $3}'))"

# --- the happy paths ------------------------------------------------------
RUN "$W" "${ARGS[@]}";                        rc_is "fresh clone" 0
is  "  checks out the ref" two "$(cat "$W/src/a")"
[ -s "$W/src/.git/objects/info/alternates" ] && ok "  borrows from the reference store" || bad "  borrows from the reference store"
hasnt "  and heals nothing" "$HEAL"

RUN "$W" "${ARGS[@]}";                        rc_is "update of a healthy checkout" 0
hasnt "  heals nothing either" "$HEAL"

RUN "$W" --repo "$T/origin.git" --ref-dir ref.git
rc_is "the reference store on its own" 0
hasnt "  and still nothing to heal" "$HEAL"

# --- the contract: tracked content always ends up at the ref --------------
echo LOCAL-EDIT > "$W/src/a"
RUN "$W" "${ARGS[@]}";                        rc_is "a modified tracked file" 0
is  "  is reset to the ref" two "$(cat "$W/src/a")"

advance three
echo DIRTY > "$W/src/sub/b"
RUN "$W" "${ARGS[@]}";                        rc_is "a tracked file the new commit does not touch" 0
is  "  is restored all the same" steady "$(cat "$W/src/sub/b")"
is  "  and the ref is checked out" three "$(cat "$W/src/a")"
is  "  leaving the tree clean" "" "$(git -C "$W/src" status --porcelain --untracked-files=no)"

mkdir -p "$W/src/out/devel"; echo CACHE > "$W/src/out/devel/artifact.o"
RUN "$W" "${ARGS[@]}";                        rc_is "an unrelated untracked file" 0
is  "  survives without --clean" CACHE "$(cat "$W/src/out/devel/artifact.o")"

RUN "$W" "${ARGS[@]}" --clean;                rc_is "the same file with --clean" 0
[ -e "$W/src/out/devel/artifact.o" ] && bad "  is removed" || ok "  is removed"

printf 'out/\n' > "$W/src/.gitignore-probe"; mkdir -p "$W/src/out"; echo IGNORED > "$W/src/out/ignored.o"
RUN "$W" "${ARGS[@]}";                        rc_is "an ignored file" 0
is  "  survives without --clean" IGNORED "$(cat "$W/src/out/ignored.o")"
RUN "$W" "${ARGS[@]}" --clean;                rc_is "and with --clean" 0
[ -e "$W/src/out/ignored.o" ] && bad "  it is removed" || ok "  it is removed"
rm -f "$W/src/.gitignore-probe"

is  "the branch is set up to push" origin "$(git -C "$W/src" config branch.main.remote)"
is  "  at the ref it was checked out from" refs/heads/main "$(git -C "$W/src" config branch.main.merge)"

# --- a checkout with nothing to check out from ---------------------------
rm -rf "$W/src2"; mkdir -p "$W/src2"
echo STALE > "$W/src2/a"; echo KEEPME > "$W/src2/marker"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src2 --target-ref main
rc_is "a work tree that was never a repository" 0
is  "  overwrites an untracked file on a tracked path" three "$(cat "$W/src2/a")"
is  "  and keeps one that is in nobody's way" KEEPME "$(cat "$W/src2/marker")"
hasnt "  without calling it a repair" "$HEAL"

# --- damage the action is expected to heal on its own --------------------
mkdir -p "$W/src/out"; echo CACHE > "$W/src/out/artifact.o"
git -C "$W/src" config --unset remote.origin.url
RUN "$W" "${ARGS[@]}";                        rc_is "a target whose remote url is gone" 0
has "  is rebuilt" "$TARGET_HEAL"
is  "  keeping the build cache" CACHE "$(cat "$W/src/out/artifact.o")"
is  "  and the ref is checked out" three "$(cat "$W/src/a")"

rm "$W/src/.git/config"
RUN "$W" "${ARGS[@]}";                        rc_is "a target with no config at all" 0
has "  is rebuilt too" "$TARGET_HEAL"

rm -rf "$W/src/.git"
RUN "$W" "${ARGS[@]}";                        rc_is "a work tree whose .git is gone" 0
is  "  is checked out again" three "$(cat "$W/src/a")"
is  "  the build cache outlives that as well" CACHE "$(cat "$W/src/out/artifact.o")"

head -c 300 /dev/urandom > "$W/src/.git/index"
RUN "$W" "${ARGS[@]}";                        rc_is "a corrupt index" 0
has "  is rebuilt" "$TARGET_HEAL"
is  "  leaving the tree clean" "" "$(git -C "$W/src" status --porcelain --untracked-files=no)"

head -c 300 /dev/urandom > "$W/src/.git/index"
RUN "$W" "${ARGS[@]}" --clean;                rc_is "a corrupt index with --clean" 0
is  "  still honours clean" "" "$(git -C "$W/src" status --porcelain --ignored)"

rm -rf "$W/src3"; git -c init.defaultBranch=main init -q "$W/src3"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src3 --target-ref main
rc_is "a target that was init'd but never fetched" 0
is  "  is checked out" three "$(cat "$W/src3/a")"

rm -rf "$W/src4"; mkdir -p "$W/src4"; echo "gitdir: $W/src/.git" > "$W/src4/.git"
S_HEAD=$(git -C "$W/src" rev-parse HEAD)
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src4 --target-ref main
rc_is "a target whose .git names another checkout" 0
[ -d "$W/src4/.git" ] && ok "  gets a git dir of its own" || bad "  gets a git dir of its own"
is  "  and the ref's content" three "$(cat "$W/src4/a")"
is  "  the other checkout keeps its HEAD" "$S_HEAD" "$(git -C "$W/src" rev-parse HEAD)"

touch "$W/src/.git/index.lock" "$W/src/.git/config.lock" "$W/src/.git/refs/remotes/origin/main.lock"
advance four
RUN "$W" "${ARGS[@]}";                        rc_is "a stale lock in the target" 0
is  "  does not stop the update" four "$(cat "$W/src/a")"
hasnt "  nor costs a rebuild" "$TARGET_HEAL"

touch "$W/ref.git/config.lock" "$W/ref.git/refs/remotes/origin/main.lock"
advance five
RUN "$W" "${ARGS[@]}";                        rc_is "a stale lock in the store" 0
is  "  does not stop the update either" five "$(cat "$W/src/a")"
hasnt "  and heals nothing" "$HEAL"

# --- the reference store is repaired in place before it is replaced ------
OBJ_BEFORE=$(objects "$W/ref.git/objects")
rm "$W/ref.git/HEAD"
RUN "$W" "${ARGS[@]}";                        rc_is "a store with no HEAD" 0
hasnt "  is repaired where it stands" "$HEAL"
OBJ_AFTER=$(objects "$W/ref.git/objects")
[ "$OBJ_AFTER" -ge "$OBJ_BEFORE" ] && ok "  keeping its objects ($OBJ_BEFORE -> $OBJ_AFTER)" \
    || bad "  keeping its objects ($OBJ_BEFORE -> $OBJ_AFTER)"
is  "  and targets still read through it" five "$(git -C "$W/src" show HEAD:a)"

git -C "$W/ref.git" config --unset remote.origin.url
git -C "$W/ref.git" config --unset-all remote.origin.fetch
RUN "$W" "${ARGS[@]}";                        rc_is "a store stripped of its url and refspecs" 0
is_path "  gets the url back" "$T/origin.git" "$(git -C "$W/ref.git" config --get remote.origin.url)"
git -C "$W/ref.git" config --get-all remote.origin.fetch | grep -q 'refs/heads' \
    && ok "  and the heads refspec" || bad "  and the heads refspec"
hasnt "  with nothing deleted" "$HEAL"

rm -rf "$W/refC.git"
RUN "$W" --repo "$T/origin.git" --ref-dir refC.git;  rc_is "prep: a store to break" 0
rm -rf "$W/refC.git/objects"; echo junk > "$W/refC.git/objects"
RUN "$W" --repo "$T/origin.git" --ref-dir refC.git
rc_is "a store whose object store is not a directory" 0
has "  is recloned" "$HEAL: store reclone"
[ -d "$W/refC.git/objects" ] && ok "  and comes back whole" || bad "  and comes back whole"
is_path "  with our origin" "$T/origin.git" "$(git -C "$W/refC.git" config --get remote.origin.url)"

# --- an origin that does not answer deletes nothing ----------------------
OBJ_BEFORE=$(objects "$W/ref.git/objects")
mv "$T/origin.git" "$T/origin-away.git"
RUN "$W" "${ARGS[@]}"
rc_is "an origin that does not answer" 1
has "  says so" "not answering"
hasnt "  and heals nothing" "$HEAL"
is  "  the store keeps its objects" "$OBJ_BEFORE" "$(objects "$W/ref.git/objects")"
is  "  the checkout is left as it was" five "$(cat "$W/src/a")"
[ -d "$W/src/.git" ] && ok "  with its git dir" || bad "  with its git dir"
mv "$T/origin-away.git" "$T/origin.git"
RUN "$W" "${ARGS[@]}";                        rc_is "  and the next run works again" 0

# --- a target the store can no longer answer for -------------------------
# What a store that was recloned leaves behind: the target still names the
# commit it was left on, the store no longer has it, and fetch, clean and
# checkout all fail in a target whose store is healthy.
rm -rf "$W/refD.git" "$W/srcD"
( cd "$T/seed" && git checkout -qb vanish && echo v > a && git commit -qam v &&
  git push -q "$T/origin.git" vanish && git checkout -q main )
RUN "$W" --repo "$T/origin.git" --ref-dir refD.git --target-dir srcD --target-ref vanish
rc_is "prep: a target sitting on a branch" 0
echo KEEPME > "$W/srcD/untracked-probe"
git -C "$T/seed" push -q "$T/origin.git" --delete vanish
find "$W/refD.git/objects" -type f -delete
RUN "$W" --repo "$T/origin.git" --ref-dir refD.git --target-dir srcD --target-ref main
rc_is "a target whose commit the store cannot supply any more" 0
has "  fails on the object it cannot read" "bad object"
has "  and rebuilds the target git dir in the same run" "$TARGET_HEAL"
is  "  the ref is checked out" five "$(cat "$W/srcD/a")"
is  "  and the work tree is kept" KEEPME "$(cat "$W/srcD/untracked-probe" 2>/dev/null)"

# --- caller mistakes are not damage --------------------------------------
git -C "$W/src" checkout -q -b local-work 2>/dev/null
echo wip > "$W/src/wip"; git -C "$W/src" add wip
git -C "$W/src" -c user.email=t@t -c user.name=t commit -qm wip
git -C "$W/src" checkout -q main
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref no-such-ref
rc_is "an unknown ref fails" 1
has "  and says why" "target ref does not exist"
hasnt "  without rebuilding anything" "$HEAL"
git -C "$W/src" show-ref --verify --quiet refs/heads/local-work \
    && ok "  leaving local branches alone" || bad "  leaving local branches alone"

echo KEEPME > "$W/src/untracked-probe"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref no-such-ref --clean
rc_is "an unknown ref is refused before --clean runs" 1
is  "  so untracked content outruns it" KEEPME "$(cat "$W/src/untracked-probe" 2>/dev/null)"
rm -f "$W/src/untracked-probe"

RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-ref main
rc_is "--target-ref without --target-dir fails" 1
has "  before touching anything" "requires --target-dir"

# --- a branch deleted upstream must not fall back to the local one -------
( cd "$T/seed" && git checkout -qb gone && echo g > a && git commit -qam g &&
  git push -q "$T/origin.git" gone && git checkout -q main )
rm -rf "$W/srcG"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcG --target-ref gone
rc_is "a branch that exists on the remote" 0
git -C "$T/seed" push -q "$T/origin.git" --delete gone
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcG --target-ref main
rc_is "prep: the deletion reaches the target" 0
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcG --target-ref gone
rc_is "a branch deleted from the remote fails" 1
has "  saying it does not exist" "target ref does not exist"
is  "  rather than building the stale local one" five "$(cat "$W/srcG/a")"
hasnt "  and heals nothing" "$HEAL"

# --- tags and commit ids -------------------------------------------------
( cd "$T/seed" && git tag -a -m annotated v1 && git push -q "$T/origin.git" refs/tags/v1 )
rm -rf "$W/srcT"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcT --target-ref v1
rc_is "an annotated tag" 0
is  "  lands on the commit it points at" "$(git -C "$T/seed" rev-parse v1^{commit})" "$(git -C "$W/srcT" rev-parse HEAD)"

SHA_MAIN=$(git -C "$T/seed" rev-parse main)
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcT --target-ref "$SHA_MAIN"
rc_is "a commit id" 0
is  "  lands on that commit" "$SHA_MAIN" "$(git -C "$W/srcT" rev-parse HEAD)"

# --- a wrong repository is a caller mistake, never repaired -------------
git -c init.defaultBranch=main init -q --bare "$T/other.git"
( cd "$T/seed" && git push -q "$T/other.git" main )
RUN "$W" --repo "$T/other.git" --ref-dir ref.git
rc_is "a store belonging to another repository is refused" 1
has "  and says so" "belongs to"
is_path "  keeping its origin" "$T/origin.git" "$(git -C "$W/ref.git" config --get remote.origin.url)"

rm -rf "$W/refO.git"
RUN "$W" --repo "$T/other.git" --ref-dir refO.git --target-dir src --target-ref main
rc_is "a target belonging to another repository is refused" 1
has "  and says so" "belongs to"
is_path "  keeping its origin" "$T/origin.git" "$(git -C "$W/src" config --get remote.origin.url)"
is  "  and its content" five "$(cat "$W/src/a")"

# --- a directory that was never a store ---------------------------------
mkdir -p "$W/data"; echo PRECIOUS > "$W/data/artifact.bin"
RUN "$W" --repo "$T/origin.git" --ref-dir data
rc_is "a data directory passed as the store" 1
has "  and says what it is not" "not a repository store"
is  "  its content survives" PRECIOUS "$(cat "$W/data/artifact.bin" 2>/dev/null)"

rm -rf "$W/wt"; git -c init.defaultBranch=main init -q "$W/wt"
RUN "$W" --repo "$T/origin.git" --ref-dir wt
rc_is "a work tree passed as the store is refused too" 1

rm -rf "$W/refR"; mkdir -p "$W/refR/refs"
RUN "$W" --repo "$T/origin.git" --ref-dir refR
rc_is "half a store is repaired rather than refused" 0
[ -d "$W/refR/objects" ] && ok "  and gets its objects" || bad "  and gets its objects"

# --- paths this script refuses to work on -------------------------------
for ROOT in / //; do
    RUN "$W" --repo "$T/origin.git" --ref-dir "$ROOT"
    rc_is "the store may not be '$ROOT'" 1
    has "  and says why" "unsafe repository directory"
    RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir "$ROOT" --target-ref main
    rc_is "the target may not be '$ROOT'" 1
done

mkdir -p "$T/base/keep"; echo PRECIOUS > "$T/base/keep/artifact.bin"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir "$T/base/keep/new/.." --target-ref main --clean
rc_is "a new path with '..' is refused" 1
is  "  the dir it would have landed on is untouched" PRECIOUS "$(cat "$T/base/keep/artifact.bin" 2>/dev/null)"
[ -d "$T/base/keep/.git" ] && bad "  and was not initialized" || ok "  and was not initialized"

mkdir -p "$T/base2/keep"; echo PRECIOUS > "$T/base2/keep/artifact.bin"
RUN "$W" --repo "$T/origin.git" --ref-dir "$T/base2/keep/new/.."
rc_is "the same for the store" 1
is  "  its neighbour is untouched too" PRECIOUS "$(cat "$T/base2/keep/artifact.bin" 2>/dev/null)"

RUN "$W" --repo "$T/origin.git" --ref-dir same --target-dir same --target-ref main
rc_is "one dir for both is refused" 1
RUN "$W" --repo "$T/origin.git" --ref-dir nest --target-dir nest/inside --target-ref main
rc_is "a target inside the store is refused" 1
RUN "$W" --repo "$T/origin.git" --ref-dir nest2/ref.git --target-dir nest2 --target-ref main
rc_is "a store inside the target is refused" 1

# --- paths with spaces, twice -------------------------------------------
SP="$T/ws two"; mkdir -p "$SP"
SARGS=(--repo "$T/origin.git" --ref-dir "ref cache.git" --target-dir "src dir" --target-ref main)
RUN "$SP" "${SARGS[@]}";                      rc_is "a path with a space, first run" 0
RUN "$SP" "${SARGS[@]}";                      rc_is "a path with a space, second run" 0
is  "  checks out the ref" five "$(cat "$SP/src dir/a")"

# --- a refspec left behind by hand must not steer the fetch -------------
# A negative refspec survives an --add and quietly stops the branch from being
# updated: origin/main stays where it was, HEAD matches it, and the run reports
# success over an older commit.
git -C "$W/src" config --add remote.origin.fetch '^refs/heads/main'
advance six
RUN "$W" "${ARGS[@]}";                        rc_is "a negative refspec in the target" 0
is  "  does not keep the checkout behind" six "$(cat "$W/src/a")"
is  "  and the refspecs are ours again" 3 "$(git -C "$W/src" config --get-all remote.origin.fetch | wc -l | tr -d ' ')"

git -C "$W/ref.git" config --add remote.origin.fetch '^refs/heads/main'
advance seven
RUN "$W" "${ARGS[@]}";                        rc_is "a negative refspec in the store" 0
is  "  does not hold the store back either" seven "$(cat "$W/src/a")"
is  "  with our refspecs restored there too" 3 "$(git -C "$W/ref.git" config --get-all remote.origin.fetch | wc -l | tr -d ' ')"

# --- the token: kept where the next step needs it, nowhere else ---------
# The store and the target are fetched over https so the token applies, and
# the machine's own config sends that url at the local origin. Nothing here
# reaches the network.
printf '[url "%s"]\n\tinsteadOf = https://example.invalid/repo.git\n' "$T/origin.git" > "$T/gitconfig"
rm -rf "$W/refK.git" "$W/srcK"
git init -q --bare "$W/refK.git"
git config --file "$W/refK.git/config" http.extraHeader "Authorization: basic LEFTBEHIND"
OUT=$(cd "$W" && GIT_CONFIG_GLOBAL="$T/gitconfig" GITHUB_TOKEN=ghs_TOKENVALUE "$SH" "$SCRIPT" \
    --repo https://example.invalid/repo.git --ref-dir refK.git --target-dir srcK --target-ref main 2>&1); RC=$?
rc_is "a run with a token" 0
WANT_HDR="Authorization: basic $(printf '%s' 'x-access-token:ghs_TOKENVALUE' | base64 | tr -d '\n')"
is  "  leaves it in the target config, for the steps that push" "$WANT_HDR" \
    "$(git config --file "$W/srcK/.git/config" --get http.extraHeader)"
is  "  and nothing in the store, which every job shares" "" \
    "$(git config --file "$W/refK.git/config" --get http.extraHeader || true)"
hasnt "  with the token itself kept out of the output" TOKENVALUE

# --- a checkout the next steps can push from ----------------------------
( cd "$T/seed" && git checkout -qb pushable && echo p > a && git commit -qam p &&
  git push -q "$T/origin.git" pushable && git checkout -q main )
rm -rf "$W/srcP"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcP --target-ref pushable
rc_is "a branch checkout" 0
is  "  sets the branch's remote" origin "$(git -C "$W/srcP" config branch.pushable.remote)"
is  "  and what it merges with" refs/heads/pushable "$(git -C "$W/srcP" config branch.pushable.merge)"
echo pushed > "$W/srcP/pushed-file"
git -C "$W/srcP" add pushed-file
git -C "$W/srcP" -c user.email=t@t -c user.name=t commit -qm pushed
if git -C "$W/srcP" push -q 2>/dev/null; then ok "  and a bare 'git push' reaches origin"; else bad "  and a bare 'git push' reaches origin"; fi
is  "  which now has the commit" "$(git -C "$W/srcP" rev-parse HEAD)" "$(git -C "$T/origin.git" rev-parse pushable)"

# --- usage ---------------------------------------------------------------
RUN "$W";                                     rc_is "no arguments at all" 1
has "  prints the usage" "Usage:"
RUN "$W" --ref-dir ref.git;                   rc_is "no repository" 1
has "  says which one is missing" "repo not defined"
RUN "$W" --repo "$T/origin.git" --target-dir src --target-ref main
rc_is "a target with no store" 1
has "  says that too" "reference dir required"

echo
if [ "$SKIP" -gt 0 ]; then
    echo "$PASS passed, $FAIL failed, $SKIP skipped"
else
    echo "$PASS passed, $FAIL failed"
fi
rm -rf "$T"
# Not $FAIL itself: exit codes wrap at 256, so 256 failures would read as 0.
exit $((FAIL > 0))
