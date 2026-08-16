#!/bin/sh
#
# Checkout a git repo, borrowing objects from a shared reference repo.
#
# Two states are told apart throughout, because they call for opposite
# answers: a repo whose metadata are damaged gets repaired, while a wrong
# invocation - a reference dir belonging to another repository, a ref that
# does not exist - gets refused. Conflating them once let a stale build pass
# for a good one, and let one job rebind the cache every other job reads.
#
# Functions never exit; they return one of the codes below and leave the
# decision to the dispatcher at the bottom. set -e is deliberately not used:
# it does not apply inside a function called from an AND-OR list, which is
# where all of these are called from.

RC_DAMAGE=1     # local metadata are broken - repairable
RC_INVALID=2    # the caller asked for something impossible - not repairable

usage() {
	echo Usage: `basename $0` "[--repo REPO_URL] [--ref-dir DIR] [--target-dir DIR] [--target-ref GIT_REF] [--clean] [--debug]"
	exit $RC_INVALID
}

# Absolute and symlink-free, for a dir that exists; empty otherwise.
abs_path() {
	if [ "$MSYSTEM" ]; then
		( cd "$1" 2>/dev/null && pwd -W )
	else
		( cd "$1" 2>/dev/null && pwd -P )
	fi
}

# The object store a repo keeps its objects in, as an absolute path.
objects_dir() {
	OD=$(git -C "$1" rev-parse --git-path objects 2>/dev/null) || return 1
	case "$OD" in
		/* | ?:[/\\]* ) echo "$OD" ;;
		* ) echo "$(abs_path "$1")/$OD" ;;
	esac
}

# --- validation: never changes anything -----------------------------------

# A filesystem root is never a repository dir, and every path here ends up
# under an rm or a git init. Checked once, before anything is touched, and
# for both dirs - not as a property of one recovery function. Absolute paths
# outside the workspace stay allowed: on Windows the default workspace is
# too deep for a chromium checkout, so ours live elsewhere on purpose.
check_safe_dir() {
	[ -d "$1" ] || return 0
	DIR_ABS=$(abs_path "$1")
	case "$DIR_ABS" in
		"" | / | // | ?:[/\\] | ?:[/\\][/\\] )
			echo "Error: unsafe repository directory: '$1'" >&2
			return $RC_INVALID ;;
	esac
	return 0
}

# The two dirs are checked apart: only a work tree can be checked out, and
# alternates must name the reference repo's own object store.
is_repo() {
	git -C "$1" rev-parse --resolve-git-dir "$2" >/dev/null 2>&1
}

is_bare_repo() {
	is_repo "$1" . && [ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null)" = true ]
}

# Reads the config file directly, so a repo too damaged for git to open still
# gets its identity checked. Repair must never be a way to rebind a store
# that other checkouts borrow objects from.
check_stored_identity() {
	[ -f "$1/config" ] || [ -f "$1/.git/config" ] || return $RC_DAMAGE
	CFG=$1/config
	[ -f "$CFG" ] || CFG=$1/.git/config
	CURRENT=$(git config --file "$CFG" --get remote.origin.url 2>/dev/null || true)
	[ -z "$CURRENT" ] && return $RC_DAMAGE
	[ -z "$URL" ] && URL=$CURRENT && return 0
	[ "$CURRENT" = "$URL" ] && return 0
	echo "Error: $1 belongs to $CURRENT, not to $URL" >&2
	return $RC_INVALID
}

# RC_INVALID when the repo belongs to a different remote: rebinding it would
# point every checkout sharing this store at another project.
check_identity() {
	CURRENT=$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)
	[ -z "$CURRENT" ] && return $RC_DAMAGE
	[ -z "$URL" ] && URL=$CURRENT && return 0
	[ "$CURRENT" = "$URL" ] && return 0
	echo "Error: $1 belongs to $CURRENT, not to $URL" >&2
	return $RC_INVALID
}

# Compares the store the target borrows from with the one it was told to use.
# Rebuilding a repo root out of the alternates entry - what this used to do -
# broke on any path holding a space.
check_alternates() {
	[ -z "$REF_DIR" ] && return 0
	ALT=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)/objects/info/alternates
	# Without it the target silently stops sharing the object store and
	# refetches everything into itself - correct content, but none of the
	# disk and time this action exists for.
	[ -s "$ALT" ] || return $RC_DAMAGE
	BORROWED=$(cat "$ALT") || return $RC_DAMAGE
	EXPECTED=$(objects_dir "$REF_DIR") || return $RC_DAMAGE
	[ "$BORROWED" = "$EXPECTED" ] && return 0
	echo "Error: $1 borrows objects from $BORROWED, not from $EXPECTED" >&2
	return $RC_INVALID
}

# --- configuration --------------------------------------------------------

add_refspec() {
	git -C "$1" config --get-all remote.origin.fetch 2>/dev/null | grep -Fqx "$2" && return 0
	git -C "$1" config --add remote.origin.fetch "$2"
}

# The heads refspec is normally 'git remote add's doing; set it here too, so
# a repo repaired through set-url does not end up fetching pull refs and no
# branches.
set_refspecs() {
	add_refspec "$1" '+refs/heads/*:refs/remotes/origin/*' || return $RC_DAMAGE
	add_refspec "$1" '+refs/pull/*/head:refs/remotes/origin/pull/*/head' || return $RC_DAMAGE
	add_refspec "$1" '+refs/pull/*/merge:refs/remotes/origin/pull/*/merge' || return $RC_DAMAGE
}

set_origin() {
	git -C "$1" remote add origin "$URL" 2>/dev/null ||
		git -C "$1" remote set-url origin "$URL" || return $RC_DAMAGE
	set_refspecs "$1"
}

# The credential goes to the one fetch that needs it and is never written to
# a config file: the reference dir outlives the job, and a token left in it
# stays readable by every later step. xtrace is off around the token and its
# encoding, which a runner is not obliged to mask.
fetch_repo() {
	DIR=$1; shift
	XTRACE=
	case $- in *x*) XTRACE=1; set +x ;; esac
	AUTH=
	if [ "$URL" = "https://${URL#https://}" ] && [ "$GITHUB_TOKEN" ]; then
		AUTH="http.extraHeader=Authorization: basic $(echo -n "x-access-token:$GITHUB_TOKEN" | base64 | tr -d '\n')"
	fi
	# Anything an older version of this script persisted.
	git -C "$DIR" config --unset-all http.extraHeader 2>/dev/null || true

	retries=5
	delay=2
	while :; do
		if [ "$AUTH" ]; then
			git -C "$DIR" -c "$AUTH" "$@" && { [ "$XTRACE" ] && set -x; return 0; }
		else
			git -C "$DIR" "$@" && { [ "$XTRACE" ] && set -x; return 0; }
		fi
		retries=$((retries - 1))
		if [ "$retries" -le 0 ]; then
			[ "$XTRACE" ] && set -x
			return $RC_DAMAGE
		fi
		echo "Git command failed. Retrying in ${delay}s..."
		sleep $delay
		delay=$((delay * 2))
	done
}

# Locks left by a killed git; every later write fails on them. The runner
# hands a checkout to one job at a time, which is what makes this safe - see
# the note in the README before sharing a reference dir between jobs.
clear_stale_locks() {
	GD=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
	find "$GD" -name '*.lock' -type f -exec rm -f -- {} + 2>/dev/null
	return 0
}

# --- reference dir --------------------------------------------------------

create_ref_repo() {
	[ -z "$URL" ] && echo "Error: repo not defined" && return $RC_INVALID
	mkdir -p "$1" || return $RC_DAMAGE
	git -C "$1" init --bare || return $RC_DAMAGE
	set_origin "$1" || return $RC_DAMAGE
	fetch_repo "$1" fetch --prune --prune-tags --tags --force
}

# 'git init --bare' over a damaged bare repo leaves its objects alone, so the
# repair is the create path minus the destruction. The store is never
# deleted: every target borrowing from it would lose its objects.
ensure_ref_repo() {
	[ -d "$1" ] || { create_ref_repo "$1"; return $?; }
	# A worktree is not a reference repo: alternates would name a directory
	# that does not exist, and the cache would silently do nothing.
	if [ -e "$1/.git" ]; then
		echo "Error: $1 is a work tree, not a bare repository" >&2
		return $RC_INVALID
	fi
	# Identity first, so a repo too damaged to open cannot be rebound.
	RC=0; check_stored_identity "$1" || RC=$?
	[ "$RC" -eq "$RC_INVALID" ] && return $RC
	if is_bare_repo "$1"; then
		RC=0; check_identity "$1" || RC=$?
		[ "$RC" -eq "$RC_INVALID" ] && return $RC
		if [ "$RC" -eq 0 ]; then
			clear_stale_locks "$1"
			set_refspecs "$1" || return $?
			fetch_repo "$1" -c gc.auto=0 fetch --prune --prune-tags --tags --force && return 0
			echo "Warning: $1 could not be updated, reinitializing it in place (existing objects are kept)"
		else
			# Fetching without an origin url succeeds and does nothing at
			# all, so this has to be repaired rather than updated.
			echo "Warning: $1 has no usable origin, reinitializing it in place (existing objects are kept)"
		fi
	else
		echo "Warning: $1 is not a valid bare git repo, reinitializing it in place (existing objects are kept)"
	fi
	create_ref_repo "$1"
}

# --- target dir -----------------------------------------------------------

create_target_repo() {
	[ -z "$URL" ] && echo "Error: repo not defined" && return $RC_INVALID
	[ -z "$REF_DIR" ] && echo "Error: reference dir required to clone" && return $RC_INVALID
	REF_OBJECTS=$(objects_dir "$REF_DIR") || return $RC_DAMAGE
	mkdir -p "$1" || return $RC_DAMAGE
	git -C "$1" init || return $RC_DAMAGE
	set_origin "$1" || return $RC_DAMAGE
	GD=$(git -C "$1" rev-parse --absolute-git-dir) || return $RC_DAMAGE
	echo "$REF_OBJECTS" > "$GD/objects/info/alternates" || return $RC_DAMAGE
	fetch_repo "$1" fetch --prune --prune-tags --tags --force
}

# Recreates .git and refetches, keeping the working tree: its untracked
# content is worth hours on a chromium-sized checkout, and the forced
# checkout reconciles every tracked path anyway. Runs once per invocation.
recover_target_repo() {
	[ "$RECOVERED" ] && return $RC_DAMAGE
	# Resolve before deleting: '/tmp/..' and a symlink to / both name the
	# root while looking harmless.
	TARGET_ABS=$(abs_path "$1")
	case "$TARGET_ABS" in
		"" | / | ?:[/\\] )
			echo "Error: refusing to recover unsafe target dir: '$1'"
			return $RC_INVALID ;;
	esac
	RECOVERED="recovered"
	echo "Warning: recovering $1 - reinitializing its .git (working tree files are kept and reconciled by the checkout)"
	rm -rf -- "$TARGET_ABS/.git" || return $RC_DAMAGE
	create_target_repo "$1"
}

# --- work-tree operations -------------------------------------------------

# Wipes everything that is not tracked content, build output included. The
# final status is the verdict; the steps before it are best effort.
clean() {
	git -C "$1" merge --abort  >/dev/null 2>&1 || true
	git -C "$1" rebase --abort >/dev/null 2>&1 || true
	git -C "$1" cherry-pick --abort >/dev/null 2>&1 || true
	git -C "$1" revert --abort >/dev/null 2>&1 || true
	git -C "$1" am --abort >/dev/null 2>&1 || true
	git -C "$1" bisect reset >/dev/null 2>&1 || true

	if ! git -C "$1" rev-parse --verify HEAD >/dev/null 2>&1; then
		git -C "$1" read-tree --empty || return $RC_DAMAGE
	fi
	git -C "$1" clean -dffx || return $RC_DAMAGE
	if git -C "$1" rev-parse --verify HEAD >/dev/null 2>&1; then
		git -C "$1" reset --hard HEAD || return $RC_DAMAGE
	fi

	git -C "$1" submodule foreach 'cd "$toplevel" && rm -fr -- "$sm_path"' || return $RC_DAMAGE
	cat <<EOF
	Note: The next command may produce error and warning messages due to
	the nature of submodule deinitialization.
	This is expected behavior and _usually_ does not indicate a problem.
EOF
	git -C "$1" submodule deinit --force --all || true
	GD=$(git -C "$1" rev-parse --absolute-git-dir) || return $RC_DAMAGE
	rm -fr -- "$GD/modules" || return $RC_DAMAGE

	STATUS=$(git -C "$1" status --porcelain --ignored) || return $RC_DAMAGE
	[ -z "$STATUS" ] && return 0
	echo "Clean failed"
	return $RC_DAMAGE
}

# A full ref keeps its type end to end: refs/tags/x and refs/heads/x are
# different things that share a name, and guessing between them once built a
# branch for a tag workflow. A bare name is still accepted for callers who
# pass one, and must not fall through to refs/heads/ - a local branch outlives
# the remote one that created it, and checking that out would quietly build a
# deleted branch.
resolve_ref() {
	case "$2" in
		refs/heads/* )
			git -C "$1" show-ref --verify --quiet "refs/remotes/origin/${2#refs/heads/}" &&
				{ echo "refs/remotes/origin/${2#refs/heads/}"; return 0; } ;;
		refs/tags/* )
			git -C "$1" show-ref --verify --quiet "$2" && { echo "$2"; return 0; } ;;
		refs/pull/* )
			git -C "$1" show-ref --verify --quiet "refs/remotes/origin/${2#refs/}" &&
				{ echo "refs/remotes/origin/${2#refs/}"; return 0; } ;;
		* )
			if git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$2"; then
				echo "refs/remotes/origin/$2"
				return 0
			fi
			if git -C "$1" show-ref --verify --quiet "refs/tags/$2"; then
				echo "refs/tags/$2"
				return 0
			fi
			case "$2" in
				"" | *[!0-9a-fA-F]* ) ;;
				* ) if git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1; then
					echo "$2"
					return 0
				fi ;;
			esac ;;
	esac
	echo "Error: target ref does not exist: $2" >&2
	return $RC_INVALID
}

# Always forced: a plain checkout can report success while leaving tracked
# files modified, and this action promises the requested ref. --force keeps
# untracked content that is not in the way, which is what makes clean:false
# worth having; wiping the rest is clean's job.
checkout() {
	RESOLVED=$(resolve_ref "$1" "$2") || return $?
	case "$RESOLVED" in
		refs/remotes/origin/* )
			BRANCH=${RESOLVED#refs/remotes/origin/}
			git -C "$1" checkout --force -B "$BRANCH" "$RESOLVED" || return $RC_DAMAGE ;;
		* )
			git -C "$1" checkout --force "$RESOLVED" || return $RC_DAMAGE ;;
	esac
	# A checkout that returns zero has still gone wrong if HEAD is not what
	# was asked for: a refspec lost along the way leaves the remote ref
	# behind, and the build would quietly be of an older commit.
	WANT=$(git -C "$1" rev-parse "$RESOLVED^{commit}") || return $RC_DAMAGE
	HAVE=$(git -C "$1" rev-parse HEAD) || return $RC_DAMAGE
	[ "$WANT" = "$HAVE" ] && return 0
	echo "Error: HEAD is $HAVE, expected $WANT for $2"
	return $RC_DAMAGE
}

# Everything done to a target that already exists, in order, so the
# dispatcher can retry the lot after a repair instead of restating the rule
# at every step.
target_steps() {
	clear_stale_locks "$1"
	set_refspecs "$1" || return $?
	fetch_repo "$1" fetch --prune --prune-tags --tags --force --recurse-submodules=no || return $?
	if [ "$CLEAN" ]; then
		clean "$1" || return $?
	fi
	if [ "$TARGET_REF" ]; then
		checkout "$1" "$TARGET_REF" || return $?
	fi
	return 0
}


[ $# -eq 0 ] && usage

URL=
REF_DIR=
TARGET_DIR=
TARGET_REF=
CLEAN=
RECOVERED=
while [ $# -gt 0 ]; do
	case "$1" in
		--repo)
			[ -z "$2" ] && echo Error: --repo requires an argument && usage
			URL=$2
			shift 2
			;;
		--ref-dir)
			[ -z "$2" ] && echo Error: --ref-dir requires an argument && usage
			REF_DIR=$2
			shift 2
			;;
		--target-dir)
			[ -z "$2" ] && echo Error: --target-dir requires an argument && usage
			TARGET_DIR=$2
			shift 2
			;;
		--target-ref)
			[ -z "$2" ] && echo Error: --target-ref requires an argument && usage
			TARGET_REF=$2
			shift 2
			;;
		--clean)
			CLEAN="clean"
			shift
			;;
		--debug)
			set -x
			shift
			;;
		-h|--help)
			usage
			;;
		*)
			echo Error: Unknown option: $1
			usage
			;;
	esac
done

[ "$URL" ] && [ "$URL" = "${URL%.git}" ] && URL=$URL.git

if [ "$TARGET_REF" ] && [ -z "$TARGET_DIR" ]; then
	echo "Error: --target-ref requires --target-dir"
	usage
fi

if [ "$REF_DIR" ]; then
	check_safe_dir "$REF_DIR" || exit $?
fi
[ "$TARGET_DIR" ] && { check_safe_dir "$TARGET_DIR" || exit $?; }

if [ "$REF_DIR" ]; then
	ensure_ref_repo "$REF_DIR" || exit $?
fi

[ -z "$TARGET_DIR" ] && exit 0

# A target that is not a usable repo is rebuilt before anything else; only
# then are the steps tried, and only a repairable failure earns one repair
# and one retry. An invalid invocation stops here rather than being answered
# by deleting metadata.
if [ ! -d "$TARGET_DIR" ]; then
	create_target_repo "$TARGET_DIR" || exit $?
elif ! is_repo "$TARGET_DIR" .git; then
	echo "Warning: $TARGET_DIR is not a valid git repo"
	recover_target_repo "$TARGET_DIR" || exit $?
else
	# A check that reports damage earns a repair; one that reports an
	# invalid invocation stops the run.
	RC=0
	check_identity "$TARGET_DIR" || RC=$?
	[ "$RC" -eq 0 ] && { check_alternates "$TARGET_DIR" || RC=$?; }
	if [ "$RC" -eq "$RC_INVALID" ]; then
		exit $RC
	elif [ "$RC" -ne 0 ]; then
		echo "Warning: $TARGET_DIR has no usable origin"
		recover_target_repo "$TARGET_DIR" || exit $?
	fi
fi

RC=0
target_steps "$TARGET_DIR" || RC=$?
if [ "$RC" -eq "$RC_DAMAGE" ]; then
	recover_target_repo "$TARGET_DIR" || exit $?
	target_steps "$TARGET_DIR" || exit $?
elif [ "$RC" -ne 0 ]; then
	exit $RC
fi

exit 0
