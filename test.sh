#!/bin/bash
# Integration tests for git-checkout.sh, against real repositories.
#
#   ./test.sh            run under bash
#   SH=dash ./test.sh    run the script under dash (the agents run it on
#                        git-bash and on macOS, where bash is 3.2)
set -u

SCRIPT=$(cd "$(dirname "$0")" && pwd)/git-checkout.sh
SH=${SH:-bash}
T=$(mktemp -d)
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

RUN() { local wd=$1; shift; OUT=$(cd "$wd" && "$SH" "$SCRIPT" "$@" 2>&1); RC=$?; }

# --- an origin with three commits, and a ref/target pair to work on ------
git -c init.defaultBranch=main init -q --bare "$T/origin.git"
git -c init.defaultBranch=main init -q "$T/seed"
cd "$T/seed"; git config user.email t@t; git config user.name t
echo one > a; mkdir sub; echo s > sub/b
git add .; git commit -qm c1; SHA_C1=$(git rev-parse HEAD)
echo two > a; echo NEW > newfile; git add .; git commit -qm c2
git push -q "$T/origin.git" main
cd /

W=$T/ws; mkdir -p "$W"
ARGS=(--repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref main)
RECOVER="Warning: recovering"
REPAIR="reinitializing it in place"

# Where ln -s only copies - git-bash without winsymlinks:nativestrict - the
# blocks that depend on real symlinks would pass without testing anything.
if ln -s . "$T/symprobe" 2>/dev/null && [ -L "$T/symprobe" ]; then HAVE_SYMLINK=1; else HAVE_SYMLINK=; fi
# Without native symlinks MSYS ln copies, so the probe may be a directory.
rm -rf "$T/symprobe"

echo "# checkout under $SH ($("$SH" -c 'echo $0') / git $(git --version | awk '{print $3}')${HAVE_SYMLINK:+, symlinks})"

# --- the happy paths ----------------------------------------------------
RUN "$W" "${ARGS[@]}";                       rc_is "fresh clone" 0
hasnt "  is not reported as a repair" "$REPAIR"
is  "  checks out the ref" two "$(cat "$W/src/a")"
[ -s "$W/src/.git/objects/info/alternates" ] && ok "  borrows from the reference store" || bad "  no alternates"

RUN "$W" "${ARGS[@]}";                       rc_is "update of a healthy checkout" 0
hasnt "  says nothing about recovery" "Warning"

# --- the contract: tracked content always ends up at the ref -------------
echo LOCAL-EDIT > "$W/src/a"
RUN "$W" "${ARGS[@]}";                       rc_is "modified tracked file" 0
is  "  is reset to the ref" two "$(cat "$W/src/a")"
is  "  leaves the tree clean" "" "$(git -C "$W/src" status --porcelain --untracked-files=no)"

mkdir -p "$W/src/out/devel"; echo CACHE > "$W/src/out/devel/artifact.o"
RUN "$W" "${ARGS[@]}";                       rc_is "unrelated untracked file" 0
is  "  survives without --clean" CACHE "$(cat "$W/src/out/devel/artifact.o")"

RUN "$W" "${ARGS[@]}" --clean;               rc_is "the same file with --clean" 0
[ -e "$W/src/out/devel/artifact.o" ] && bad "  is removed" || ok "  is removed"

# --- damage the action is expected to heal on its own -------------------
mkdir -p "$W/src/out/devel"; echo CACHE > "$W/src/out/devel/artifact.o"
git -C "$W/src" config --unset remote.origin.url
RUN "$W" "${ARGS[@]}";                       rc_is "a repo whose remote url is gone" 0
has "  is recovered" "$RECOVER"
is  "  keeps the build cache" CACHE "$(cat "$W/src/out/devel/artifact.o")"

rm "$W/src/.git/config"
RUN "$W" "${ARGS[@]}";                       rc_is "a repo with no config at all" 0

rm -rf "$W/src/.git"
RUN "$W" "${ARGS[@]}";                       rc_is "a work tree with no .git" 0
is  "  is checked out again" two "$(cat "$W/src/a")"

head -c 300 /dev/urandom > "$W/src/.git/index"
RUN "$W" "${ARGS[@]}";                       rc_is "a corrupt index" 0
has "  is recovered" "$RECOVER"
is  "  leaves the tree clean" "" "$(git -C "$W/src" status --porcelain --untracked-files=no)"

head -c 300 /dev/urandom > "$W/src/.git/index"
RUN "$W" "${ARGS[@]}" --clean;               rc_is "a corrupt index with --clean" 0
is  "  still honours clean" "" "$(git -C "$W/src" status --porcelain --ignored)"

rm -rf "$W/src2"; git -c init.defaultBranch=main init -q "$W/src2"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src2 --target-ref main
rc_is "a repo that was init'd but never fetched" 0

# --- reference dir: repaired in place, never deleted --------------------
RUN "$W" "${ARGS[@]}"
OBJ_BEFORE=$(find "$W/ref.git/objects" -type f | wc -l)
rm "$W/ref.git/HEAD"
RUN "$W" "${ARGS[@]}";                       rc_is "a damaged reference dir" 0
has "  is repaired in place" "$REPAIR"
OBJ_AFTER=$(find "$W/ref.git/objects" -type f | wc -l)
[ "$OBJ_AFTER" -ge "$OBJ_BEFORE" ] && ok "  keeps its object store ($OBJ_BEFORE -> $OBJ_AFTER)" \
    || bad "  lost objects ($OBJ_BEFORE -> $OBJ_AFTER)"
is  "  leaves targets able to read through alternates" two "$(git -C "$W/src" show HEAD:a)"

git -C "$W/ref.git" config --unset remote.origin.url
git -C "$W/ref.git" config --unset-all remote.origin.fetch
RUN "$W" "${ARGS[@]}";                       rc_is "a reference remote stripped of url and refspecs" 0
is_path "  restores the url" "$T/origin.git" "$(git -C "$W/ref.git" config --get remote.origin.url)"
git -C "$W/ref.git" config --get-all remote.origin.fetch | grep -q 'refs/heads' \
    && ok "  restores the heads refspec" || bad "  restores the heads refspec"

RUN "$W" "${ARGS[@]}"
hasnt "healthy dirs are not touched" "$RECOVER"
hasnt "  nor reported as damaged" "$REPAIR"

# --- caller mistakes are not damage ------------------------------------
git -C "$W/src" checkout -q -b local-work 2>/dev/null
echo wip > "$W/src/wip"; git -C "$W/src" add wip; git -C "$W/src" commit -qm wip
git -C "$W/src" checkout -q main
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref no-such-ref
[ "$RC" != 0 ] && ok "an unknown ref fails" || bad "an unknown ref fails (rc=$RC)"
hasnt "  without recreating .git" "$RECOVER"
git -C "$W/src" show-ref --verify --quiet refs/heads/local-work \
    && ok "  leaving local branches alone" || bad "  leaving local branches alone"

RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-ref main
[ "$RC" != 0 ] && ok "--target-ref without --target-dir fails" || bad "--target-ref without --target-dir fails"
has "  before touching anything" "requires --target-dir"

# --- failures inside recovery must not read as success ------------------
mkdir -p "$T/fakebin"
cat > "$T/fakebin/git" <<'EOF'
#!/bin/sh
case " $* " in *" fetch "*) [ -f "$FAIL_FETCH" ] && { echo "fatal: simulated fetch failure" >&2; exit 128; } ;; esac
exec git_real "$@"
EOF
chmod +x "$T/fakebin/git"
ln -sf "$(command -v git)" "$T/fakebin/git_real"
git -C "$W/src" config --unset remote.origin.url
touch "$T/nofetch"
OBJ_REF=$(find "$W/ref.git/objects" -type f | wc -l)
OUT=$(cd "$W" && PATH="$T/fakebin:$PATH" FAIL_FETCH=$T/nofetch GIT_FETCH_RETRIES=1 "$SH" "$SCRIPT" "${ARGS[@]}" 2>&1); RC=$?
rc_is "a fetch that keeps failing stops the run" 3
hasnt "  and deletes nothing" "from scratch"
[ "$(find "$W/ref.git/objects" -type f | wc -l)" -ge "$OBJ_REF" ] \
    && ok "  the store keeps its objects" || bad "  the store keeps its objects"
rm -f "$T/nofetch"

# --- damage that only shows up when git writes -------------------------
cd "$T/seed"; echo four > a; git commit -qam c4; git push -q "$T/origin.git" main; cd /
touch "$W/src/.git/refs/remotes/origin/main.lock"
RUN "$W" "${ARGS[@]}";                       rc_is "a stale ref lock in the target" 0
is  "  does not stop the update" four "$(cat "$W/src/a")"

cd "$T/seed"; echo five > a; git commit -qam c5; git push -q "$T/origin.git" main; cd /
touch "$W/ref.git/refs/remotes/origin/main.lock"
RUN "$W" "${ARGS[@]}";                       rc_is "a stale ref lock in the reference dir" 0
is  "  does not stop the update either" five "$(cat "$W/src/a")"

# --- a deleted remote branch must not fall back to the local one -------
cd "$T/seed"; git checkout -qb gone; echo g > a; git commit -qam g
git push -q "$T/origin.git" gone; git checkout -q main; cd /
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref gone
rc_is "a branch that exists on the remote" 0
git -C "$T/seed" push -q "$T/origin.git" --delete gone
RUN "$W" "${ARGS[@]}"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref gone
[ "$RC" != 0 ] && ok "a branch deleted from the remote fails" || bad "a branch deleted from the remote fails (rc=$RC)"
is  "  rather than building the stale local one" five "$(cat "$W/src/a")"

# --- a destructive path is resolved before it is acted on --------------
rm -rf "$T/fakerm"; mkdir -p "$T/fakerm"
printf '#!/bin/sh\necho "RM $*" >&2\n' > "$T/fakerm/rm"; chmod +x "$T/fakerm/rm"
OUT=$(cd "$W" && PATH="$T/fakerm:$PATH" "$SH" "$SCRIPT" --repo "$T/origin.git" \
    --ref-dir ref.git --target-dir /tmp/.. --target-ref main 2>&1); RC=$?
# Asked the way the script asks: on git-bash /tmp/.. is the MSYS root in
# windows spelling, an ordinary directory, and there is nothing to refuse -
# so there the run proceeds and removing things is what it should do.
case "$(abspath /tmp/..)" in
    / | // | ?:[/\\] | ?:[/\\][/\\] )
        hasnt "a target dir resolving to the root is refused" "RM "
        has   "  and says so" "unsafe repository directory" ;;
    * ) skip "a target dir resolving to the root ('..' reaches no root here)" ;;
esac

# --- a wrong repository is a caller mistake, never repaired ------------
git -c init.defaultBranch=main init -q --bare "$T/other.git"
RUN "$W" --repo "$T/other.git" --ref-dir ref.git
[ "$RC" != 0 ] && ok "a reference dir belonging to another repo is refused" || bad "a reference dir belonging to another repo is refused (rc=$RC)"
is_path "  and keeps its origin" "$T/origin.git" "$(git -C "$W/ref.git" config --get remote.origin.url)"

# --- paths with spaces, twice ------------------------------------------
SP="$T/ws two"; mkdir -p "$SP"
SARGS=(--repo "$T/origin.git" --ref-dir "ref cache.git" --target-dir "src dir" --target-ref main)
RUN "$SP" "${SARGS[@]}";                     rc_is "a path with a space, first run" 0
RUN "$SP" "${SARGS[@]}";                     rc_is "a path with a space, second run" 0
is  "  checks out the ref" five "$(cat "$SP/src dir/a")"

# --- a stale HEAD must not pass for success ----------------------------
cd "$T/seed"; echo six > a; git commit -qam c6; git push -q "$T/origin.git" main; cd /
git -C "$W/src" config --unset-all remote.origin.fetch
cat > "$T/fakebin/git" <<'EOF'
#!/bin/sh
case " $* " in
  *" --add remote.origin.fetch +refs/heads/"*) echo "simulated config failure" >&2; exit 1 ;;
esac
exec git_real "$@"
EOF
OUT=$(cd "$W" && PATH="$T/fakebin:$PATH" "$SH" "$SCRIPT" "${ARGS[@]}" 2>&1); RC=$?
# Either it fails, or it repaired itself - but it must never report success
# while HEAD sits on an older commit than the ref it was asked for.
if [ "$RC" != 0 ]; then
    ok "a heads refspec that cannot be restored does not pass silently"
else
    WANT=$(git -C "$T/seed" rev-parse HEAD)
    HAVE=$(git -C "$W/src" rev-parse HEAD)
    [ "$WANT" = "$HAVE" ] && ok "a heads refspec that cannot be restored does not pass silently" \
        || bad "a heads refspec that cannot be restored does not pass silently (stale HEAD)"
fi
printf '#!/bin/sh\ncase " $* " in *" fetch "*) [ -f "$FAIL_FETCH" ] && { echo "fatal: simulated fetch failure" >&2; exit 128; } ;; esac\nexec git_real "$@"\n' > "$T/fakebin/git"
RUN "$W" "${ARGS[@]}"

# --- repair must never rebind a store to another repository ------------
git -c init.defaultBranch=main init -q --bare "$T/foreign.git"
rm -rf "$W/refX.git"
RUN "$W" --repo "$T/origin.git" --ref-dir refX.git;   rc_is "prep: a second reference dir" 0
rm "$W/refX.git/HEAD"
RUN "$W" --repo "$T/foreign.git" --ref-dir refX.git
[ "$RC" != 0 ] && ok "a damaged reference dir is not rebound to another repo" || bad "a damaged reference dir is not rebound to another repo (rc=$RC)"
is_path "  and keeps its origin" "$T/origin.git" "$(git config --file "$W/refX.git/config" --get remote.origin.url)"

rm -rf "$W/wt"; git -c init.defaultBranch=main init -q "$W/wt"
RUN "$W" --repo "$T/origin.git" --ref-dir wt
[ "$RC" != 0 ] && ok "a work tree passed as the reference dir is refused" || bad "a work tree passed as the reference dir is refused (rc=$RC)"

# --- filesystem roots are refused before anything is touched -----------
rm -rf "$T/fakerm2"; mkdir -p "$T/fakerm2"
printf '#!/bin/sh\necho "RM $*" >&2\n' > "$T/fakerm2/rm"; chmod +x "$T/fakerm2/rm"
for ROOT in / //; do
    OUT=$(cd "$W" && PATH="$T/fakerm2:$PATH" "$SH" "$SCRIPT" --repo "$T/origin.git" \
        --ref-dir ref.git --target-dir "$ROOT" --target-ref main 2>&1); RC=$?
    hasnt "target dir '$ROOT' touches nothing" "RM "
    has  "  and is refused" "unsafe repository directory"
    OUT=$(cd "$W" && "$SH" "$SCRIPT" --repo "$T/origin.git" --ref-dir "$ROOT" 2>&1); RC=$?
    has  "reference dir '$ROOT' is refused" "unsafe repository directory"
done

# --- a tag and a branch may share a name -------------------------------
cd "$T/seed"; git checkout -q main; echo tagged > a; git commit -qam tagcommit
git tag shared; git push -q "$T/origin.git" refs/tags/shared
echo branched > a; git commit -qam branchcommit
git push -q "$T/origin.git" HEAD:refs/heads/shared; git checkout -q main; cd /
rm -rf "$W/srcT"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcT --target-ref refs/tags/shared
rc_is "a full tag ref" 0
is  "  checks out the tag, not the branch" tagged "$(cat "$W/srcT/a")"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcT --target-ref refs/heads/shared
rc_is "a full branch ref" 0
is  "  checks out the branch" branched "$(cat "$W/srcT/a")"

# --- a target that stopped sharing the object store --------------------
rm -rf "$W/srcA"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcA --target-ref main
rc_is "prep: a target with alternates" 0
rm "$W/srcA/.git/objects/info/alternates"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcA --target-ref main
rc_is "a target that lost its alternates" 0
[ -s "$W/srcA/.git/objects/info/alternates" ] && ok "  borrows from the store again" || bad "  borrows from the store again"

# --- a caller mistake must say why -------------------------------------
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref no-such-ref-at-all
has "an unknown ref explains itself" "target ref does not exist"

# --- a new path whose '..' would land on someone else's dir ------------
mkdir -p "$T/base/keep"; echo PRECIOUS > "$T/base/keep/artifact.bin"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir "$T/base/keep/new/.." --target-ref main --clean
[ "$RC" != 0 ] && ok "a new path with '..' is refused" || bad "a new path with '..' is refused (rc=$RC)"
is  "  the neighbouring dir is untouched" PRECIOUS "$(cat "$T/base/keep/artifact.bin" 2>/dev/null)"
[ -d "$T/base/keep/.git" ] && bad "  and was not initialized" || ok "  and was not initialized"

mkdir -p "$T/base2/keep"; echo PRECIOUS > "$T/base2/keep/artifact.bin"
RUN "$W" --repo "$T/origin.git" --ref-dir "$T/base2/keep/new/.."
[ "$RC" != 0 ] && ok "the same for the reference dir" || bad "the same for the reference dir (rc=$RC)"
is  "  its neighbour is untouched too" PRECIOUS "$(cat "$T/base2/keep/artifact.bin" 2>/dev/null)"

# --- reference and target may not contain each other -------------------
RUN "$W" --repo "$T/origin.git" --ref-dir same --target-dir same --target-ref main
[ "$RC" != 0 ] && ok "the same dir for both is refused" || bad "the same dir for both is refused (rc=$RC)"
RUN "$W" --repo "$T/origin.git" --ref-dir nest --target-dir nest/inside --target-ref main
[ "$RC" != 0 ] && ok "a target inside the reference dir is refused" || bad "a target inside the reference dir is refused (rc=$RC)"
RUN "$W" --repo "$T/origin.git" --ref-dir nest2/ref.git --target-dir nest2 --target-ref main
[ "$RC" != 0 ] && ok "a reference dir inside the target is refused" || bad "a reference dir inside the target is refused (rc=$RC)"

# --- origin belongs to the action --------------------------------------
git -c init.defaultBranch=main init -q --bare "$T/second.git"
git -C "$W/src" config --add remote.origin.url "$T/second.git"
RUN "$W" "${ARGS[@]}"
if [ "$RC" != 0 ]; then
    ok "a second origin url is not silently used"
else
    is_path "a second origin url is normalized away" "$T/origin.git" "$(git -C "$W/src" config --get-all remote.origin.url | tr '\n' ' ' | sed 's/ $//')"
fi

git -C "$W/src" config --unset-all remote.origin.url
git -C "$W/src" config --add remote.origin.url "$T/origin.git"
RUN "$W" "${ARGS[@]}";                       rc_is "prep: back to a single origin" 0
cd "$T/seed"; echo seven > a; git commit -qam c7; git push -q "$T/origin.git" main; cd /
git -C "$W/src" config --add remote.origin.fetch '^refs/heads/main'
RUN "$W" "${ARGS[@]}";                       rc_is "a negative refspec added by hand" 0
is  "  does not keep the checkout behind" seven "$(cat "$W/src/a")"

git -C "$W/src" config --add remote.origin.fetch 'this is not a refspec'
RUN "$W" "${ARGS[@]}";                       rc_is "a malformed refspec added by hand" 0
is  "  and the config is back to ours" 4 "$(git -C "$W/src" config --get-all remote.origin.fetch | wc -l | tr -d ' ')"

# --- an alternates file written by an older version --------------------
if [ "$HAVE_SYMLINK" ]; then
	rm -rf "$T/sym"; mkdir -p "$T/sym/real"; ln -s real "$T/sym/link"
	( cd "$T/sym/link" && "$SH" "$SCRIPT" --repo "$T/origin.git" --ref-dir r.git --target-dir s --target-ref main ) >/dev/null 2>&1
	printf '%s\n' "$T/sym/link/r.git/objects" > "$T/sym/real/s/.git/objects/info/alternates"
	OUT=$(cd "$T/sym/link" && "$SH" "$SCRIPT" --repo "$T/origin.git" --ref-dir r.git --target-dir s --target-ref main 2>&1); RC=$?
	rc_is "an alternates path that differs only by a symlink" 0
	hasnt "  is not treated as belonging elsewhere" "borrows objects from"
else
	skip "an alternates path that differs only by a symlink (no symlinks here)"
fi

# --- an all-hex branch name deleted upstream ---------------------------
cd "$T/seed"; git checkout -q main; echo hexy > a; git commit -qam hexy
git push -q "$T/origin.git" HEAD:refs/heads/cafe; git checkout -q main; cd /
rm -rf "$W/srcH"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcH --target-ref cafe
rc_is "prep: a hex-named branch" 0
git -C "$T/seed" push -q "$T/origin.git" --delete cafe
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcH --target-ref main
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcH --target-ref cafe
[ "$RC" != 0 ] && ok "a hex-named branch deleted upstream fails" || bad "a hex-named branch deleted upstream fails (rc=$RC)"

# --- a commit id still works -------------------------------------------
SHA_MAIN=$(git -C "$T/seed" rev-parse HEAD)
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcH --target-ref "$SHA_MAIN"
rc_is "a full commit id" 0
is  "  lands on that commit" "$SHA_MAIN" "$(git -C "$W/srcH" rev-parse HEAD)"

RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcU \
	--target-ref "$(printf '%s' "$SHA_MAIN" | tr 'a-f' 'A-F')"
rc_is "a commit id in upper case" 0
is  "  lands on that commit" "$SHA_MAIN" "$(git -C "$W/srcU" rev-parse HEAD)"

# --- skip-worktree and sparse checkout ---------------------------------
RUN "$W" "${ARGS[@]}"
git -C "$W/src" update-index --skip-worktree a
echo LOCAL > "$W/src/a"
RUN "$W" "${ARGS[@]}";                       rc_is "a tracked file marked skip-worktree" 0
is  "  comes back at the ref's content" seven "$(cat "$W/src/a")"

git -C "$W/src" sparse-checkout init --cone >/dev/null 2>&1
git -C "$W/src" sparse-checkout set sub >/dev/null 2>&1
RUN "$W" "${ARGS[@]}";                       rc_is "a sparse checkout" 0
[ -f "$W/src/a" ] && ok "  restores every tracked file" || bad "  restores every tracked file"

# --- configuration reaching the repo through include.path --------------
printf '[remote "origin"]\n\tfetch = ^refs/heads/main\n' > "$T/extra-config"
git -C "$W/src" config include.path "$T/extra-config"
cd "$T/seed"; echo eight > a; git commit -qam c8; git push -q "$T/origin.git" main; cd /
RUN "$W" "${ARGS[@]}";                       rc_is "an included negative refspec" 0
is  "  does not hold the checkout back" eight "$(cat "$W/src/a")"
git -C "$W/src" config --unset include.path

# --- a reference config git cannot parse -------------------------------
rm -rf "$W/refBad"
RUN "$W" --repo "$T/origin.git" --ref-dir refBad;  rc_is "prep: a reference dir" 0
printf '[' > "$W/refBad/config"
RUN "$W" --repo "$T/origin.git" --ref-dir refBad
rc_is "an unreadable reference config is repaired" 0
is_path "  and the origin is ours" "$T/origin.git" "$(git -C "$W/refBad" config --get remote.origin.url)"

printf '[remote "origin"]\n\turl = %s\n[' "$T/second.git" > "$W/refBad/config"
RUN "$W" --repo "$T/origin.git" --ref-dir refBad
[ "$RC" != 0 ] && ok "an unreadable config naming another repo is refused" || bad "an unreadable config naming another repo is refused (rc=$RC)"

# --- a tag deleted upstream ---------------------------------------------
cd "$T/seed"; git checkout -q main; git tag doomed; git push -q "$T/origin.git" refs/tags/doomed; cd /
rm -rf "$W/srcT2"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcT2 --target-ref refs/tags/doomed
rc_is "prep: a tag" 0
git -C "$T/seed" push -q "$T/origin.git" --delete refs/tags/doomed
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcT2 --target-ref main
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcT2 --target-ref refs/tags/doomed
[ "$RC" != 0 ] && ok "a tag deleted upstream fails" || bad "a tag deleted upstream fails (rc=$RC)"

# --- a work tree pointed somewhere else ---------------------------------
mkdir -p "$T/elsewhere"; echo SENTINEL > "$T/elsewhere/artifact"
RUN "$W" "${ARGS[@]}"
git -C "$W/src" config core.worktree "$T/elsewhere"
RUN "$W" "${ARGS[@]}" --clean;               rc_is "a redirected core.worktree" 0
is  "  leaves the other directory alone" SENTINEL "$(cat "$T/elsewhere/artifact" 2>/dev/null)"
is  "  and checks out where it was told" eight "$(cat "$W/src/a")"

# --- sparse checkout that only bites on the new commit ------------------
rm -rf "$W/srcS"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcS --target-ref main
rc_is "prep: a target to make sparse" 0
git -C "$W/srcS" sparse-checkout init --cone >/dev/null 2>&1
git -C "$W/srcS" sparse-checkout set sub >/dev/null 2>&1
git -C "$W/srcS" checkout -q -- . 2>/dev/null || true
cd "$T/seed"; mkdir -p outside; echo out > outside/b; git add outside; git commit -qm outside
git push -q "$T/origin.git" main; cd /
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcS --target-ref main
rc_is "a sparse checkout that only excludes the new commit's files" 0
[ -f "$W/srcS/outside/b" ] && ok "  brings the new file in anyway" || bad "  brings the new file in anyway"

# --- an unreadable config whose identity is not origin's ----------------
rm -rf "$W/refB2"
RUN "$W" --repo "$T/origin.git" --ref-dir refB2;  rc_is "prep: a reference dir" 0
printf '[remote "backup"]\n\turl = %s\n[\n[remote "origin"]\n\turl = %s\n' "$T/origin.git" "$T/second.git" > "$W/refB2/config"
RUN "$W" --repo "$T/origin.git" --ref-dir refB2
[ "$RC" != 0 ] && ok "an unreadable config is judged by origin, not the first url" || bad "an unreadable config is judged by origin, not the first url (rc=$RC)"

printf '[include]\n\tpath = /nowhere\n[\n' > "$W/refB2/config"
RUN "$W" --repo "$T/origin.git" --ref-dir refB2
[ "$RC" != 0 ] && ok "an unreadable config with includes is refused" || bad "an unreadable config with includes is refused (rc=$RC)"

# --- a url the machine's config rewrites --------------------------------
# The other repo has to be a usable one: a rewrite onto an empty repo fails
# on its own, and would let this pass without the check being there at all.
git -c init.defaultBranch=main init -q --bare "$T/rewritten.git"
cd "$T/seed"; git checkout -q -b rewritten; echo REWRITTEN > a; git commit -qam rw
git push -q "$T/rewritten.git" rewritten:main; git checkout -q main; cd /
git -C "$W/src" config "url.$T/rewritten.git.insteadOf" "$T/origin.git"
RUN "$W" "${ARGS[@]}"
[ "$RC" != 0 ] && ok "a rewritten repository url is refused" || bad "a rewritten repository url is refused (rc=$RC)"
has "  and says what it was rewritten to" "rewrites"
is  "  the checkout is left as it was" eight "$(cat "$W/src/a")"
git -C "$W/src" config --unset "url.$T/rewritten.git.insteadOf"

git -C "$W/ref.git" config "url.$T/rewritten.git.insteadOf" "$T/origin.git"
RUN "$W" "${ARGS[@]}"
[ "$RC" != 0 ] && ok "the same for the reference dir" || bad "the same for the reference dir (rc=$RC)"
hasnt "  without announcing a repair first" "$REPAIR"
git -C "$W/ref.git" config --unset "url.$T/rewritten.git.insteadOf"
RUN "$W" "${ARGS[@]}";                       rc_is "  and works again once it is gone" 0

# --- a .git file pointing at another checkout ---------------------------
rm -rf "$W/srcG" "$W/srcG2"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcG --target-ref main
rc_is "prep: a healthy target to borrow from" 0
mkdir -p "$W/srcG2"; echo "gitdir: $W/srcG/.git" > "$W/srcG2/.git"; echo OLD > "$W/srcG2/a"
G_HEAD=$(git -C "$W/srcG" rev-parse HEAD)
cd "$T/seed"; echo nine > a; git commit -qam c9; git push -q "$T/origin.git" main; cd /
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcG2 --target-ref main
rc_is "a target whose .git names another repo" 0
[ -d "$W/srcG2/.git" ] && ok "  gets a git dir of its own" || bad "  gets a git dir of its own"
is  "  and the ref's content" nine "$(cat "$W/srcG2/a")"
is  "  the other checkout keeps its HEAD" "$G_HEAD" "$(git -C "$W/srcG" rev-parse HEAD)"
is  "  and its work tree" "" "$(git -C "$W/srcG" status --porcelain)"

# --- a .git symlinked into another checkout -----------------------------
if [ "$HAVE_SYMLINK" ]; then
	rm -rf "$W/srcG3"
	mkdir -p "$W/srcG3"; ln -s "$W/srcG/.git" "$W/srcG3/.git"; echo OLD > "$W/srcG3/a"
	G_HEAD=$(git -C "$W/srcG" rev-parse HEAD)
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcG3 --target-ref main
	rc_is "a target whose .git is a symlink" 0
	[ -L "$W/srcG3/.git" ] && bad "  gets a git dir of its own" || ok "  gets a git dir of its own"
	is  "  and the ref's content" nine "$(cat "$W/srcG3/a")"
	is  "  the other checkout keeps its HEAD" "$G_HEAD" "$(git -C "$W/srcG" rev-parse HEAD)"
	is  "  and its work tree" "" "$(git -C "$W/srcG" status --porcelain)"
else
	skip "a target whose .git is a symlink (no symlinks here)"
fi

# --- a .git file naming a checkout of another repository ----------------
rm -rf "$W/srcO" "$W/srcO2" "$W/refO"
RUN "$W" --repo "$T/rewritten.git" --ref-dir refO --target-dir srcO --target-ref main
rc_is "prep: a checkout of another repository" 0
O_HEAD=$(git -C "$W/srcO" rev-parse HEAD)
mkdir -p "$W/srcO2"; echo "gitdir: $W/srcO/.git" > "$W/srcO2/.git"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcO2 --target-ref main
rc_is "a .git naming another repository's checkout is repaired, not refused" 0
is  "  and gets the ref's content" nine "$(cat "$W/srcO2/a")"
is  "  the other repository's checkout keeps its HEAD" "$O_HEAD" "$(git -C "$W/srcO" rev-parse HEAD)"
is  "  and its work tree" "" "$(git -C "$W/srcO" status --porcelain)"
is  "  and its content" REWRITTEN "$(cat "$W/srcO/a")"

# --- a replacement ref in a reused target -------------------------------
rm -rf "$W/srcR"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcR --target-ref main
rc_is "prep: a target to plant a replacement in" 0
R_NEW=$(git -C "$W/srcR" rev-parse HEAD)
R_OLD=$(git -C "$W/srcR" rev-parse HEAD~1)
git -C "$W/srcR" replace "$R_OLD" "$R_NEW" >/dev/null 2>&1
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcR --target-ref "$R_OLD"
rc_is "a commit with a replacement ref" 0
is  "  checks out the commit that was asked for" eight "$(cat "$W/srcR/a")"
is  "  and does not leave the replacement behind" "" "$(git -C "$W/srcR" for-each-ref --format='%(refname)' refs/replace)"

# --- a hook and a dangling .git symlink ---------------------------------
RUN "$W" "${ARGS[@]}"
printf '#!/bin/sh\necho HOOKED > "$(git rev-parse --show-toplevel)/a"\n' > "$W/src/.git/hooks/post-checkout"
chmod +x "$W/src/.git/hooks/post-checkout"
RUN "$W" "${ARGS[@]}";                       rc_is "a post-checkout hook in a reused target" 0
is  "  does not get to rewrite the tree" nine "$(cat "$W/src/a")"
rm -f "$W/src/.git/hooks/post-checkout"

# reference-transaction runs inside every ref update - the fetch, and the
# removal of replacement refs after the checkout.
printf '#!/bin/sh\n[ "$1" = committed ] || exit 0\necho HOOKED > "$(git rev-parse --show-toplevel)/a"\n' > "$W/src/.git/hooks/reference-transaction"
chmod +x "$W/src/.git/hooks/reference-transaction"
cd "$T/seed"; echo ten > a; git commit -qam c10; git push -q "$T/origin.git" main; cd /
RUN "$W" "${ARGS[@]}";                       rc_is "a reference-transaction hook" 0
is  "  does not get to rewrite the tree" ten "$(cat "$W/src/a")"
rm -f "$W/src/.git/hooks/reference-transaction"

# a hooksPath of the repo's own choosing must not win either
mkdir -p "$W/ownhooks"
printf '#!/bin/sh\necho HOOKED > "$(git rev-parse --show-toplevel)/a"\n' > "$W/ownhooks/post-checkout"
chmod +x "$W/ownhooks/post-checkout"
git -C "$W/src" config core.hooksPath "$W/ownhooks"
RUN "$W" "${ARGS[@]}";                       rc_is "a hooksPath the repo points elsewhere" 0
is  "  does not get to rewrite the tree either" ten "$(cat "$W/src/a")"
git -C "$W/src" config --unset core.hooksPath

if [ "$HAVE_SYMLINK" ]; then
	rm -rf "$W/srcD"; mkdir -p "$W/srcD"; ln -s "$W/no-such-dir/.git" "$W/srcD/.git"
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcD --target-ref main
	rc_is "a dangling .git symlink" 0
	[ -L "$W/srcD/.git" ] && bad "  is replaced by a real git dir" || ok "  is replaced by a real git dir"
	is  "  and the ref is checked out" ten "$(cat "$W/srcD/a")"
else
	skip "a dangling .git symlink (no symlinks here)"
fi

# --- a main work tree that linked work trees hang off --------------------
rm -rf "$W/srcW" "$W/linked"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcW --target-ref main
rc_is "prep: a target to attach a work tree to" 0
git -C "$W/srcW" worktree add -q -b wt "$W/linked" >/dev/null 2>&1
git -C "$W/srcW" config --unset remote.origin.url
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcW --target-ref main
[ "$RC" != 0 ] && ok "a main work tree with linked ones is not rebuilt" || bad "a main work tree with linked ones is not rebuilt (rc=$RC)"
has "  and says why" "linked work trees"
[ -d "$W/srcW/.git/worktrees/linked" ] && ok "  the linked work tree still has its metadata" || bad "  the linked work tree still has its metadata"
is_path "  and still resolves" "$W/srcW/.git/worktrees/linked" "$(git -C "$W/linked" rev-parse --absolute-git-dir 2>&1)"

# --- a target that names another repository ------------------------------
rm -rf "$W/srcB"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcB --target-ref main
rc_is "prep: a target of one repository" 0
RUN "$W" --repo "$T/rewritten.git" --ref-dir refO --target-dir srcB --target-ref main
rc_is "a target pointed at another repository is rebuilt" 0
is  "  and holds the other repository's content" REWRITTEN "$(cat "$W/srcB/a")"
is_path "  with its origin" "$T/rewritten.git" "$(git -C "$W/srcB" config --get remote.origin.url)"

# --- the reference dir keeps the rule the target does not ----------------
RUN "$W" --repo "$T/rewritten.git" --ref-dir ref.git
[ "$RC" != 0 ] && ok "a reference dir of another repository is still refused" || bad "a reference dir of another repository is still refused (rc=$RC)"

# --- repairing a reference dir must not start an auto-gc -----------------
rm -rf "$T/gitlog" "$T/fakegit"; mkdir -p "$T/fakegit"
printf '#!/bin/sh\necho "$*" >> "$GITLOG"\nexec git_real "$@"\n' > "$T/fakegit/git"
chmod +x "$T/fakegit/git"; ln -sf "$(command -v git)" "$T/fakegit/git_real"
rm "$W/ref.git/HEAD"
OUT=$(cd "$W" && PATH="$T/fakegit:$PATH" GITLOG="$T/gitlog" "$SH" "$SCRIPT" "${ARGS[@]}" 2>&1); RC=$?
rc_is "a reference dir repaired in place" 0
grep -q '^-C .*ref\.git .*gc\.auto=0 fetch' "$T/gitlog" \
    && ok "  fetches with auto-gc off" || bad "  fetches with auto-gc off"

# --- a registration left behind by a work tree that is gone --------------
rm -rf "$W/srcW2" "$W/linked2"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcW2 --target-ref main
rc_is "prep: another target to attach a work tree to" 0
git -C "$W/srcW2" worktree add -q -b wt2 "$W/linked2" >/dev/null 2>&1
rm -rf "$W/linked2"
git -C "$W/srcW2" config --unset remote.origin.url
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcW2 --target-ref main
rc_is "a registration whose work tree is gone does not block recovery" 0
is  "  and the ref is checked out" ten "$(cat "$W/srcW2/a")"

# --- a work tree inside the target, which --clean removes ----------------
rm -rf "$W/srcW3"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcW3 --target-ref main
rc_is "prep: a target to put a work tree inside" 0
git -C "$W/srcW3" worktree add -q -b wt3 "$W/srcW3/inside" >/dev/null 2>&1
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcW3 --target-ref main --clean
rc_is "a work tree inside the target is cleaned away" 0
git -C "$W/srcW3" config --unset remote.origin.url
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcW3 --target-ref main
rc_is "  and what it registered does not block the next recovery" 0

# --- a .git symlink into a checkout that has work trees of its own -------
if [ "$HAVE_SYMLINK" ]; then
	rm -rf "$W/srcW4"; mkdir -p "$W/srcW4"
	ln -s "$W/srcW/.git" "$W/srcW4/.git"
	W_HEAD=$(git -C "$W/srcW" rev-parse HEAD)
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcW4 --target-ref main
	rc_is "a .git symlink into a checkout with work trees is repaired" 0
	[ -L "$W/srcW4/.git" ] && bad "  the target gets one of its own" || ok "  the target gets one of its own"
	is  "  the donor keeps its HEAD" "$W_HEAD" "$(git -C "$W/srcW" rev-parse HEAD)"
	[ -d "$W/srcW/.git/worktrees/linked" ] && ok "  and its registrations" || bad "  and its registrations"
else
	skip "a .git symlink into a checkout with work trees (no symlinks here)"
fi

# --- recovery needs a ref to put the working tree back -------------------
rm -rf "$W/srcN"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcN --target-ref main
rc_is "prep: a target to damage" 0
echo KEEPME > "$W/srcN/untracked-artifact"
git -C "$W/srcN" config --unset remote.origin.url
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcN --clean
[ "$RC" != 0 ] && ok "recovery without a target ref is refused" || bad "recovery without a target ref is refused (rc=$RC)"
is  "  and the working tree is left alone" KEEPME "$(cat "$W/srcN/untracked-artifact" 2>/dev/null)"

# --- the last rung: debris git itself cannot delete ----------------------
# Where an unwritable directory does not block deletion - running as root,
# or git-bash, whose chmod does not bite - the rung under test never fires.
mkdir -p "$T/wprobe/d"; echo x > "$T/wprobe/d/f"; chmod a-w "$T/wprobe/d"
if rm "$T/wprobe/d/f" 2>/dev/null; then HAVE_PERM=; else HAVE_PERM=1; fi
chmod -R u+rwX "$T/wprobe" 2>/dev/null; rm -rf "$T/wprobe"
if [ "$HAVE_PERM" ]; then
	rm -rf "$W/srcZ"
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcZ --target-ref main
	rc_is "prep: a target to obstruct" 0
	mkdir -p "$W/srcZ/debris"; echo junk > "$W/srcZ/debris/f"; chmod a-w "$W/srcZ/debris"
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcZ --target-ref main --clean
	rc_is "an unwritable directory a clean cannot remove" 0
	has "  escalates to a full reclone" "deleting the checkout"
	[ -e "$W/srcZ/debris" ] && bad "  which removes the debris" || ok "  which removes the debris"
	is  "  and checks out the ref" ten "$(cat "$W/srcZ/a")"
	is  "  the rebuild ran once" 1 "$(echo "$OUT" | grep -c "Warning: recovering")"
	is  "  and the reclone ran once" 1 "$(echo "$OUT" | grep -c "from scratch")"
	[ -e "$W/srcZ.gone" ] && bad "  leaving no trash behind" || ok "  leaving no trash behind"
else
	skip "an unwritable directory a clean cannot remove (deletion is not blocked here)"
fi

# --- a directory that was never a checkout is not the action's to delete --
if [ "$HAVE_PERM" ]; then
	rm -rf "$T/precious"; mkdir -p "$T/precious/debris"
	echo PRECIOUS > "$T/precious/debris/f"; chmod a-w "$T/precious/debris"
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir "$T/precious" --target-ref main --clean
	[ "$RC" != 0 ] && ok "a data dir that cannot be cleaned fails" || bad "a data dir that cannot be cleaned fails (rc=$RC)"
	has "  refusing the reclone for a dir that was never a checkout" "never identified"
	is  "  and its content survives" PRECIOUS "$(cat "$T/precious/debris/f" 2>/dev/null)"
	chmod -R u+rwX "$T/precious" 2>/dev/null; rm -rf "$T/precious"
else
	skip "a data dir that cannot be cleaned (deletion is not blocked here)"
fi

# --- the same for a reference dir that was never a store ------------------
rm -rf "$T/preciousR"; mkdir -p "$T/preciousR"
echo PRECIOUS > "$T/preciousR/artifact.bin"; echo junk > "$T/preciousR/objects"
RUN "$W" --repo "$T/origin.git" --ref-dir "$T/preciousR"
[ "$RC" != 0 ] && ok "a data dir that cannot become a store fails" || bad "a data dir that cannot become a store fails (rc=$RC)"
has "  refusing the reclone for a dir that was never a store" "never identified"
is  "  and its content survives" PRECIOUS "$(cat "$T/preciousR/artifact.bin" 2>/dev/null)"
rm -rf "$T/preciousR"

# --- a checkout that lost its url still bears the action's signature ------
if [ "$HAVE_PERM" ]; then
	rm -rf "$W/srcL"
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcL --target-ref main
	rc_is "prep: a checkout to tear the url out of" 0
	git -C "$W/srcL" config --unset remote.origin.url
	mkdir -p "$W/srcL/debris"; echo junk > "$W/srcL/debris/f"; chmod a-w "$W/srcL/debris"
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcL --target-ref main --clean
	rc_is "a target with no url but our alternates self-heals" 0
	has "  through the full reclone" "deleting the checkout"
	[ -e "$W/srcL/debris" ] && bad "  which removes the debris" || ok "  which removes the debris"
	is  "  and checks out the ref" ten "$(cat "$W/srcL/a")"
else
	skip "a target with no url but our alternates (deletion is not blocked here)"
fi

# --- a contradicting url earns the repair, never the delete ---------------
if [ "$HAVE_PERM" ]; then
	rm -rf "$W/srcM"
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcM --target-ref main
	rc_is "prep: a checkout to point at another repository" 0
	git -C "$W/srcM" config remote.origin.url "$T/second.git"
	mkdir -p "$W/srcM/debris"; echo junk > "$W/srcM/debris/f"; chmod a-w "$W/srcM/debris"
	RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcM --target-ref main --clean
	[ "$RC" != 0 ] && ok "a target naming another repository is never deleted" || bad "a target naming another repository is never deleted (rc=$RC)"
	has "  and says why" "never identified"
	is  "  its undeletable content survives" junk "$(cat "$W/srcM/debris/f" 2>/dev/null)"
	chmod -R u+rwX "$W/srcM" 2>/dev/null; rm -rf "$W/srcM"
else
	skip "a contradicting url is never deleted (deletion is not blocked here)"
fi

# --- the last rung never fires for a mistake ------------------------------
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir src --target-ref no-such-ref
[ "$RC" != 0 ] && ok "an unknown ref still fails" || bad "an unknown ref still fails (rc=$RC)"
hasnt "  without reaching the full reclone" "cloning from scratch"
[ -d "$W/src/.git" ] && ok "  and the checkout is still there" || bad "  and the checkout is still there"

# --- an outage: nothing is deleted while the remote is down ---------------
rm -rf "$W/srcY" "$W/refY.git"
RUN "$W" --repo "$T/origin.git" --ref-dir refY.git --target-dir srcY --target-ref main
rc_is "prep: a checkout with a store of its own" 0
echo KEEPME > "$W/srcY/untracked-artifact"
rm -rf "$W/srcY/.git"
mv "$T/origin.git" "$T/origin-away.git"
OUT=$(cd "$W" && GIT_FETCH_RETRIES=1 "$SH" "$SCRIPT" --repo "$T/origin.git" \
    --ref-dir refY.git --target-dir srcY --target-ref main 2>&1); RC=$?
rc_is "an unreachable remote fails the run with the fetch code" 3
hasnt "  deleting nothing" "from scratch"
[ -d "$W/refY.git/objects" ] && ok "  the store is kept" || bad "  the store is kept"
is  "  and the working tree too" KEEPME "$(cat "$W/srcY/untracked-artifact" 2>/dev/null)"
mv "$T/origin-away.git" "$T/origin.git"
RUN "$W" --repo "$T/origin.git" --ref-dir refY.git --target-dir srcY --target-ref main
rc_is "  and the run heals once the remote returns" 0

# --- the same when only the target's own fetch is failing -----------------
rm -rf "$T/fakenet"; mkdir -p "$T/fakenet"
cat > "$T/fakenet/git" <<'EOF'
#!/bin/sh
case " $* " in
	*" ls-remote --get-url "*) ;;
	*" ls-remote "*) echo "fatal: simulated outage" >&2; exit 128 ;;
	*" fetch "*) case " $* " in *"$FAIL_DIR"*) echo "fatal: simulated outage" >&2; exit 128 ;; esac ;;
esac
exec git_real "$@"
EOF
chmod +x "$T/fakenet/git"; ln -sf "$(command -v git)" "$T/fakenet/git_real"
rm -rf "$W/srcX"
RUN "$W" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcX --target-ref main
rc_is "prep: a healthy target" 0
echo KEEPME > "$W/srcX/untracked-artifact"
OUT=$(cd "$W" && PATH="$T/fakenet:$PATH" FAIL_DIR=srcX GIT_FETCH_RETRIES=1 "$SH" "$SCRIPT" \
    --repo "$T/origin.git" --ref-dir ref.git --target-dir srcX --target-ref main 2>&1); RC=$?
rc_is "a target that cannot fetch fails with the fetch code" 3
hasnt "  without spending the working tree" "from scratch"
is  "  which is kept" KEEPME "$(cat "$W/srcX/untracked-artifact" 2>/dev/null)"
[ -d "$W/srcX" ] && ok "  and the directory itself" || bad "  and the directory itself"

# --- a store too broken for the in-place repair ---------------------------
rm -rf "$W/refZ.git"
RUN "$W" --repo "$T/origin.git" --ref-dir refZ.git;  rc_is "prep: a store" 0
rm -rf "$W/refZ.git/objects"; echo junk > "$W/refZ.git/objects"
RUN "$W" --repo "$T/origin.git" --ref-dir refZ.git
rc_is "a store whose object dir is a file" 0
has "  is recloned from scratch" "recloning it from scratch"
git -C "$W/refZ.git" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null \
    && ok "  and serves refs again" || bad "  and serves refs again"
[ -e "$W/refZ.git.gone" ] && bad "  leaving no trash behind" || ok "  leaving no trash behind"
rm -rf "$W/srcV"
RUN "$W" --repo "$T/origin.git" --ref-dir refZ.git --target-dir srcV --target-ref main
rc_is "  and a checkout borrowing from it works" 0

# --- a broken store is kept while the remote is down ----------------------
rm -rf "$W/refP.git"
RUN "$W" --repo "$T/origin.git" --ref-dir refP.git; rc_is "prep: a store to break offline" 0
rm -rf "$W/refP.git/objects"; echo junk > "$W/refP.git/objects"
mv "$T/origin.git" "$T/origin-away.git"
OUT=$(cd "$W" && GIT_FETCH_RETRIES=1 "$SH" "$SCRIPT" --repo "$T/origin.git" --ref-dir refP.git 2>&1); RC=$?
[ "$RC" != 0 ] && ok "a broken store during an outage fails" || bad "a broken store during an outage fails (rc=$RC)"
has "  saying the remote is not answering" "not answering"
[ -f "$W/refP.git/objects" ] && ok "  and is kept for when it returns" || bad "  and is kept for when it returns"
mv "$T/origin-away.git" "$T/origin.git"
RUN "$W" --repo "$T/origin.git" --ref-dir refP.git
rc_is "  then heals by the reclone once it answers" 0
has "  announcing it" "recloning it from scratch"

# --- even then, a store of another repository is refused ------------------
rm -rf "$W/refZ2.git"
RUN "$W" --repo "$T/origin.git" --ref-dir refZ2.git; rc_is "prep: another store" 0
rm -rf "$W/refZ2.git/objects"; echo junk > "$W/refZ2.git/objects"
RUN "$W" --repo "$T/foreign.git" --ref-dir refZ2.git
[ "$RC" != 0 ] && ok "a broken store of another repository is still refused" || bad "a broken store of another repository is still refused (rc=$RC)"
[ -f "$W/refZ2.git/objects" ] && ok "  and left untouched" || bad "  and left untouched"

# --- an unreadable config whose section names are upper case ------------
rm -rf "$W/refB3"
RUN "$W" --repo "$T/origin.git" --ref-dir refB3;  rc_is "prep: a reference dir" 0
printf '[REMOTE "origin"]\n\tURL = %s\n[\n' "$T/second.git" > "$W/refB3/config"
RUN "$W" --repo "$T/origin.git" --ref-dir refB3
[ "$RC" != 0 ] && ok "an unreadable config is read case-insensitively" || bad "an unreadable config is read case-insensitively (rc=$RC)"

# --- an inherited git environment ---------------------------------------
rm -rf "$W/srcE" "$W/decoy"
mkdir -p "$W/decoy"
mkdir -p "$W/evilhooks"
printf '#!/bin/sh\necho HOOKED > "$(git rev-parse --show-toplevel)/a"\n' > "$W/evilhooks/post-checkout"
chmod +x "$W/evilhooks/post-checkout"
OUT=$(cd "$W" && GIT_NAMESPACE=ns GIT_ALTERNATE_OBJECT_DIRECTORIES="$W/decoy" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.fetch GIT_CONFIG_VALUE_0='^refs/heads/main' \
    GIT_CONFIG_PARAMETERS="'core.hooksPath'='$W/evilhooks'" \
    GIT_WORK_TREE="$W/decoy" GIT_CONFIG="$T/extra-config" \
    "$SH" "$SCRIPT" --repo "$T/origin.git" --ref-dir ref.git --target-dir srcE --target-ref main 2>&1); RC=$?
rc_is "a run under an inherited git environment" 0
is  "  checks out where it was told" ten "$(cat "$W/srcE/a" 2>/dev/null)"
[ -e "$W/decoy/a" ] && bad "  and nowhere else" || ok "  and nowhere else"

# --- the token must not be left in any config --------------------------
rm -rf "$W/src6" "$W/ref6.git"
OUT=$(cd "$W" && GITHUB_TOKEN=ghs_TOKENVALUE "$SH" "$SCRIPT" --repo "$T/origin.git" \
    --ref-dir ref6.git --target-dir src6 --target-ref main 2>&1); RC=$?
rc_is "a run with a token" 0
is  "  leaves nothing in the reference config" "" "$(git -C "$W/ref6.git" config --get-all http.extraHeader || true)"
is  "  nor in the target config" "" "$(git -C "$W/src6" config --get-all http.extraHeader || true)"

# --- the token must not reach an xtrace log ----------------------------
rm -rf "$W/src5"
OUT=$(cd "$W" && GITHUB_TOKEN=ghs_SUPERSECRETTOKENVALUE "$SH" "$SCRIPT" --debug \
    --repo "https://127.0.0.1:1/x.git" --ref-dir ref5.git 2>&1 || true)
hasnt "the token stays out of the debug trace" "SUPERSECRETTOKENVALUE"
hasnt "  and so does its base64" "$(printf 'x-access-token:ghs_SUPERSECRETTOKENVALUE' | base64 | tr -d '\n' | cut -c1-24)"

# --- nor on the repair ladder of a reused https store --------------------
rm -rf "$W/refT.git"; mkdir -p "$W/refT.git"; git -C "$W/refT.git" init -q --bare
git -C "$W/refT.git" config remote.origin.url "https://127.0.0.1:1/x.git"
OUT=$(cd "$W" && GITHUB_TOKEN=ghs_SUPERSECRETTOKENVALUE GIT_FETCH_RETRIES=1 "$SH" "$SCRIPT" --debug \
    --repo "https://127.0.0.1:1/x" --ref-dir refT.git 2>&1); RC=$?
rc_is "an unreachable https remote fails with the fetch code" 3
[ -f "$W/refT.git/HEAD" ] && ok "  and the store is kept" || bad "  and the store is kept"
hasnt "  with the token kept out of the trace" "SUPERSECRETTOKENVALUE"
hasnt "  and its base64 too" "$(printf 'x-access-token:ghs_SUPERSECRETTOKENVALUE' | base64 | tr -d '\n' | cut -c1-24)"

echo
if [ "$SKIP" -gt 0 ]; then
    echo "$PASS passed, $FAIL failed, $SKIP skipped"
else
    echo "$PASS passed, $FAIL failed"
fi
rm -rf "$T"
exit $FAIL
