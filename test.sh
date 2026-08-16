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
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok   - $1"; }
bad()   { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1 (want '$2', got '$3')"; }
rc_is() { [ "$2" = "$RC" ] && ok "$1 (rc=$RC)" || bad "$1 (want rc=$2, got rc=$RC)"; }
has()   { echo "$OUT" | grep -q "$2" && ok "$1" || bad "$1 (output lacks '$2')"; }
hasnt() { echo "$OUT" | grep -q "$2" && bad "$1 (output has '$2')" || ok "$1"; }

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

echo "# checkout under $SH ($("$SH" -c 'echo $0') / git $(git --version | awk '{print $3}'))"

# --- the happy paths ----------------------------------------------------
RUN "$W" "${ARGS[@]}";                       rc_is "fresh clone" 0
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
is  "  restores the url" "$T/origin.git" "$(git -C "$W/ref.git" config --get remote.origin.url)"
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
[ "$1" = fetch ] && [ -f "$FAIL_FETCH" ] && { echo "fatal: simulated fetch failure" >&2; exit 128; }
exec git_real "$@"
EOF
chmod +x "$T/fakebin/git"
ln -sf "$(command -v git)" "$T/fakebin/git_real"
git -C "$W/src" config --unset remote.origin.url
touch "$T/nofetch"
OUT=$(cd "$W" && PATH="$T/fakebin:$PATH" FAIL_FETCH=$T/nofetch "$SH" "$SCRIPT" "${ARGS[@]}" 2>&1); RC=$?
[ "$RC" != 0 ] && ok "a recovery whose fetch fails reports failure" || bad "a recovery whose fetch fails reports failure (rc=$RC)"
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
hasnt "a target dir resolving to the root is refused" "RM -rf /tmp/../.git"
has  "  and says so" "refusing to recover unsafe target dir"

# --- the token must not reach an xtrace log ----------------------------
rm -rf "$W/src5"
OUT=$(cd "$W" && GITHUB_TOKEN=ghs_SUPERSECRETTOKENVALUE "$SH" "$SCRIPT" --debug \
    --repo "https://127.0.0.1:1/x.git" --ref-dir ref5.git 2>&1 || true)
hasnt "the token stays out of the debug trace" "SUPERSECRETTOKENVALUE"
hasnt "  and so does its base64" "$(printf 'x-access-token:ghs_SUPERSECRETTOKENVALUE' | base64 | tr -d '\n' | cut -c1-24)"

echo
echo "$PASS passed, $FAIL failed"
rm -rf "$T"
exit $FAIL
