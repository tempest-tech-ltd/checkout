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

# Every git command below has to mean the same thing on any machine, so the
# environment does not get to redirect them: not the repo, work tree, index or
# object store; not a second store to read besides the one chosen here; not a
# prefix on every ref lookup; not a config file for the writes below, nor
# config injected wholesale into every command - in either form, since the
# packed one is read after the keyed one and would win over what this script
# sets there. GIT_CONFIG_COUNT is what git reads the keys up to, and the
# three indices below are the ones this run writes itself.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_PARAMETERS \
	GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
	GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2

# A replacement ref is the same redirection one level down: it swaps the tree
# behind a commit while its id - the one every check here compares - stays the
# requested one. The refs are left in place, they are just not applied.
GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_REPLACE_OBJECTS

RC_DAMAGE=1     # local metadata are broken - repairable
RC_INVALID=2    # the caller asked for something impossible - not repairable

usage() {
	echo Usage: `basename $0` "[--repo REPO_URL] [--ref-dir DIR] [--target-dir DIR] [--target-ref GIT_REF] [--clean] [--debug]"
	echo "Exit: 0 ok, $RC_DAMAGE unfinished - damage a repair did not fix, or a fetch that kept failing, $RC_INVALID invalid invocation"
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

# Hooks are code a repo carries, and they run inside the commands this script
# gives it: post-checkout inside the checkout, and reference-transaction
# inside anything that writes a ref - every fetch and every ref update here.
# Picking commands to protect one at a time leaves the rest, so the two keys
# go into the environment, where every git command below reads them and where
# they beat the repo's own config. hooksPath names this script: a hook is
# looked for inside it, and a file holds none. A path that merely does not
# exist would do only until something creates it.
HOOKS_OFF=$(abs_path "$(dirname "$0")")/$(basename "$0")
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0=core.fsmonitor
GIT_CONFIG_VALUE_0=false
GIT_CONFIG_KEY_1=core.hooksPath
GIT_CONFIG_VALUE_1=$HOOKS_OFF
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1

# The object store a repo keeps its objects in, as an absolute path.
objects_dir() {
	OD=$(git -C "$1" rev-parse --git-path objects 2>/dev/null) || return 1
	case "$OD" in
		/* | ?:[/\\]* ) echo "$OD" ;;
		* ) echo "$(abs_path "$1")/$OD" ;;
	esac
}

# --- validation: never changes anything -----------------------------------

# Whether two spellings name the same repository. They can differ without
# disagreeing: git-bash converts a path handed to git into its Windows form,
# so the url the caller wrote and the one git stored or expanded name one
# directory in two ways. Only paths are compared that way - a url resolves to
# nothing, and two different ones must never come out equal by both resolving
# to nothing.
same_repo() {
	[ "$1" = "$2" ] && return 0
	SR_A=$(abs_path "$1")
	[ -n "$SR_A" ] && [ "$SR_A" = "$(abs_path "$2")" ]
}

# Turns a caller's path into the one path the rest of the run uses. A '..' in
# a path that does not exist yet cannot be resolved, and means something else
# once the dirs above it appear - 'base/keep/new/..' becomes 'base/keep', a
# directory that belongs to someone else and is about to be git init'd and
# cleaned. Such a path is refused; an existing one is resolved and checked for
# being a filesystem root. Absolute paths outside the workspace stay allowed:
# on Windows the default workspace is too deep for a chromium checkout, so
# ours live elsewhere. Prints the canonical path.
prepare_dir() {
	case "$1" in
		"" | / | // ) echo "Error: unsafe repository directory: '$1'" >&2; return $RC_INVALID ;;
	esac
	if [ ! -d "$1" ]; then
		case "$1" in
			.. | ../* | */.. | */../* )
				echo "Error: '..' is not allowed in a path that does not exist yet: '$1'" >&2
				return $RC_INVALID ;;
		esac
	fi
	mkdir -p -- "$1" 2>/dev/null || { echo "Error: cannot create directory: '$1'" >&2; return $RC_DAMAGE; }
	DIR_ABS=$(abs_path "$1")
	case "$DIR_ABS" in
		"" | / | // | ?:[/\\] | ?:[/\\][/\\] )
			echo "Error: unsafe repository directory: '$1' resolves to '$DIR_ABS'" >&2
			return $RC_INVALID ;;
	esac
	printf '%s\n' "$DIR_ABS"
}

# Neither dir may contain the other: a shared store inside a work tree is
# removed by clean as untracked, and a target inside the store is walked by
# the lock sweep.
check_disjoint() {
	[ "$1" = "$2" ] && { echo "Error: reference and target dirs are the same: '$1'" >&2; return $RC_INVALID; }
	case "$2" in "$1"/* ) echo "Error: target dir '$2' is inside reference dir '$1'" >&2; return $RC_INVALID ;; esac
	case "$1" in "$2"/* ) echo "Error: reference dir '$1' is inside target dir '$2'" >&2; return $RC_INVALID ;; esac
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
	[ -f "$1/config" ] || return $RC_DAMAGE
	CFG=$1/config
	# --get returns the last value while fetch uses the first, so more than
	# one url means the check and the fetch could disagree.
	COUNT=$(git config --includes --file "$CFG" --get-all remote.origin.url 2>/dev/null | sort -u | wc -l)
	CURRENT=$(git config --includes --file "$CFG" --get-all remote.origin.url 2>/dev/null | head -1)
	[ -z "$CURRENT" ] && return $RC_DAMAGE
	if [ "$COUNT" -gt 1 ]; then
		echo "Error: $1 has more than one distinct origin url" >&2
		return $RC_INVALID
	fi
	[ -z "$URL" ] && URL=$CURRENT && return 0
	same_repo "$CURRENT" "$URL" && return 0
	echo "Error: $1 belongs to $CURRENT, not to $URL" >&2
	return $RC_INVALID
}

# RC_INVALID when the repo belongs to a different remote: rebinding it would
# point every checkout sharing this store at another project.
check_identity() {
	COUNT=$(git -C "$1" config --local --get-all remote.origin.url 2>/dev/null | sort -u | wc -l)
	CURRENT=$(git -C "$1" config --local --get-all remote.origin.url 2>/dev/null | head -1)
	[ -z "$CURRENT" ] && return $RC_DAMAGE
	if [ "$COUNT" -gt 1 ]; then
		echo "Error: $1 has more than one distinct origin url" >&2
		return $RC_INVALID
	fi
	[ -z "$URL" ] && URL=$CURRENT && return 0
	same_repo "$CURRENT" "$URL" && return 0
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
	# Compared as directories, not as strings: an older version of this
	# script wrote the logical path, so a store reached through a symlink
	# spells the same directory differently and a healthy checkout would
	# otherwise be refused for good.
	[ "$(abs_path "$BORROWED")" = "$(abs_path "$EXPECTED")" ] && return 0
	# Damage, not a caller mistake: recreating a target's .git never rebinds
	# the shared store - that firewall is the reference dir's identity check.
	echo "Warning: $1 borrows objects from $BORROWED, not from $EXPECTED" >&2
	return $RC_DAMAGE
}

# --- configuration --------------------------------------------------------

# Kept in the config for anyone reading the repo by hand; the fetch passes its
# own refspecs and does not consult these. origin is the action's to define,
# not a set to append to. An extra fetch
# refspec is enough to break a run in a way nothing else notices: a negative
# one ('^refs/heads/main') keeps the branch out of the fetch, so the remote
# ref stays behind and the checkout - and the HEAD check, reading that same
# ref - both pass on an old commit.
set_origin() {
	git -C "$1" config --unset-all remote.origin.url 2>/dev/null || true
	git -C "$1" config --unset-all remote.origin.fetch 2>/dev/null || true
	git -C "$1" config --add remote.origin.url "$URL" || return $RC_DAMAGE
	set_refspecs "$1"
}

# The stored refspecs are for whoever opens the repo by hand later; the fetch
# below passes its own on the command line and never reads these. They are kept
# equal to it so a manual fetch does the same thing.
# Replacement refs are the action's to remove, the way origin's config is:
# no refspec carries them, so --prune cannot see one, and a replacement left
# in a reused checkout outlives the run. Not applying them - which is what
# GIT_NO_REPLACE_OBJECTS does - only covers this script; every git command
# the job runs afterwards would still read the tree it was pointed at. The
# reference dir keeps its own: nothing is checked out there, and refs do not
# travel through alternates.
clear_replace_refs() {
	git -C "$1" for-each-ref --format='delete %(refname)' refs/replace 2>/dev/null \
		| git -C "$1" update-ref --stdin 2>/dev/null
	# update-ref can be refused - a reference-transaction hook is enough -
	# and a refusal that went unnoticed would leave exactly what this is
	# here to remove.
	[ -z "$(git -C "$1" for-each-ref --format='%(refname)' refs/replace 2>/dev/null)" ] && return 0
	echo "Warning: $1 keeps replacement refs that could not be removed" >&2
	return $RC_DAMAGE
}

set_refspecs() {
	git -C "$1" config --unset-all remote.origin.fetch 2>/dev/null || true
	git -C "$1" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' || return $RC_DAMAGE
	git -C "$1" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*' || return $RC_DAMAGE
	git -C "$1" config --add remote.origin.fetch '+refs/pull/*/head:refs/remotes/origin/pull/*/head' || return $RC_DAMAGE
	git -C "$1" config --add remote.origin.fetch '+refs/pull/*/merge:refs/remotes/origin/pull/*/merge' || return $RC_DAMAGE
}

# Puts the environment back to the two keys the whole run uses.
drop_token() {
	GIT_CONFIG_COUNT=2
	export GIT_CONFIG_COUNT
	unset GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2
}

# Tags come through a refspec of their own rather than --tags: git only prunes
# tags it fetched by refspec, and --prune-tags is ignored outright once
# refspecs are given on the command line - a tag deleted upstream would live on
# and still be checked out.
#
# The url and the refspecs are given on the command line, so the fetch cannot
# be steered by configuration this script does not own: a negative refspec or
# a second url reaching the repo through include.path would otherwise decide
# what gets fetched, and a checkout of an old commit would look like success.
#
# The credential goes to this one command through the environment - not into a
# config file, which the reference dir would keep for every later step, and not
# into argv, which is readable from any process listing. xtrace is off around
# the token and its encoding, which a runner is not obliged to mask.
fetch_repo() {
	DIR=$1; shift
	# git rewrites the url it is handed through url.<base>.insteadOf, so the
	# repo the caller named and the one the fetch reaches can differ while
	# every identity check still passes: the store keeps the name of one repo
	# and the objects of another. The rewrite is refused rather than followed,
	# since it usually comes from the machine's own config and nothing here
	# could repair it. Asked in the same dir the fetch runs in, which is what
	# decides the answer.
	EFFECTIVE=$(git -C "$DIR" ls-remote --get-url "$URL") || return $RC_DAMAGE
	if ! same_repo "$EFFECTIVE" "$URL"; then
		echo "Error: git config rewrites '$URL' to '$EFFECTIVE' - remove the url.*.insteadOf entry" >&2
		return $RC_INVALID
	fi
	XTRACE=
	case $- in *x*) XTRACE=1; set +x ;; esac
	if [ "$URL" = "https://${URL#https://}" ] && [ "$GITHUB_TOKEN" ]; then
		GIT_CONFIG_COUNT=3
		GIT_CONFIG_KEY_2=http.extraHeader
		GIT_CONFIG_VALUE_2="Authorization: basic $(printf '%s' "x-access-token:$GITHUB_TOKEN" | base64 | tr -d '\n')"
		export GIT_CONFIG_COUNT GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2
	fi
	# Anything an older version of this script persisted.
	git -C "$DIR" config --unset-all http.extraHeader 2>/dev/null || true
	[ "$XTRACE" ] && set -x

	retries=${GIT_FETCH_RETRIES:-5}
	delay=${GIT_FETCH_DELAY:-2}
	while :; do
		git -C "$DIR" "$@" "$URL" \
			'+refs/heads/*:refs/remotes/origin/*' \
			'+refs/tags/*:refs/tags/*' \
			'+refs/pull/*/head:refs/remotes/origin/pull/*/head' \
			'+refs/pull/*/merge:refs/remotes/origin/pull/*/merge' && { drop_token; return 0; }
		retries=$((retries - 1))
		if [ "$retries" -le 0 ]; then
			drop_token
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
	# Also the repair path for a store that already holds objects, so it
	# carries what the update path carries: a fetch here must not start an
	# auto-gc over a store the whole machine borrows from.
	fetch_repo "$1" -c gc.auto=0 fetch --prune --force
}

# 'git init --bare' over a damaged bare repo leaves its objects alone, so the
# repair is the create path minus the destruction. The store is never
# deleted: every target borrowing from it would lose its objects.
ensure_ref_repo() {
	[ -z "$REF_EXISTED" ] && { create_ref_repo "$1"; return $?; }
	# A worktree is not a reference repo: alternates would name a directory
	# that does not exist, and the cache would silently do nothing.
	if [ -e "$1/.git" ]; then
		echo "Error: $1 is a work tree, not a bare repository" >&2
		return $RC_INVALID
	fi
	# Identity first, so a repo too damaged to open cannot be rebound.
	RC=0; check_stored_identity "$1" || RC=$?
	[ "$RC" -eq "$RC_INVALID" ] && return $RC
	# A config git cannot parse kills every command including the init that
	# would repair it. Salvage origin's url by hand to keep the no-rebind
	# guarantee, then move the file aside so the repair can run at all.
	if [ -f "$1/config" ] && ! git config --includes --file "$1/config" --list >/dev/null 2>&1; then
		if grep -qiE '^[[:space:]]*\[include' "$1/config"; then
			echo "Error: $1 has an unreadable config with includes; its identity cannot be established" >&2
			return $RC_INVALID
		fi
		# Section and variable names are case-insensitive to git, the
		# subsection name is not.
		SALVAGED=$(awk '
			/^[[:space:]]*\[/ { in_origin = ($0 ~ /^[[:space:]]*\[[Rr][Ee][Mm][Oo][Tt][Ee][[:space:]]+"origin"\]/) }
			in_origin && /^[[:space:]]*[Uu][Rr][Ll][[:space:]]*=/ {
				sub(/^[[:space:]]*[Uu][Rr][Ll][[:space:]]*=[[:space:]]*/, ""); print; exit
			}' "$1/config")
		# A url that disagrees means the store belongs to someone else and
		# must not be rebound. Nothing readable at all is a different thing:
		# there is no identity to protect, only a dir to repair.
		if [ "$SALVAGED" ] && [ "$SALVAGED" != "$URL" ]; then
			echo "Error: $1 has an unreadable config; its origin reads '$SALVAGED', not '$URL'" >&2
			return $RC_INVALID
		fi
		echo "Warning: $1 has an unreadable config, moving it aside" >&2
		mv -- "$1/config" "$1/config.broken" || return $RC_DAMAGE
	fi
	# Then the locks, before anything else touches the repo: a config.lock
	# left by a killed process makes even 'git init --bare' fail, and the
	# repair below would be unable to run for good. The dir is the gitdir
	# here, so this works on a repo git can no longer open.
	find "$1" -name '*.lock' -type f -exec rm -f -- {} + 2>/dev/null
	if is_bare_repo "$1"; then
		RC=0; check_identity "$1" || RC=$?
		[ "$RC" -eq "$RC_INVALID" ] && return $RC
		if [ "$RC" -eq 0 ]; then
			set_refspecs "$1" || return $?
			RC=0; fetch_repo "$1" -c gc.auto=0 fetch --prune --force || RC=$?
			[ "$RC" -eq 0 ] && return 0
			# A refused invocation is not something a repair answers, and
			# announcing one before refusing reads as if it had happened.
			[ "$RC" -eq "$RC_INVALID" ] && return $RC
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
	fetch_repo "$1" fetch --prune --force
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
			echo "Error: refusing to recover unsafe target dir: '$1'" >&2
			return $RC_INVALID ;;
	esac
	# Linked work trees keep their administrative files under this .git and
	# nowhere else: deleting it leaves each of them with 'not a git
	# repository'. They are not this run's to rebuild, so it stops instead.
	# Only through a .git of the target's own: a symlink would find the
	# registrations of the checkout it points at, and unlinking harms none
	# of them. An entry whose gitdir names nothing that exists describes a
	# work tree that is already gone - git keeps the entry, and a --clean
	# that removed a work tree living inside the target leaves one - so
	# there is nothing there to protect.
	if [ -d "$TARGET_ABS/.git" ] && [ ! -L "$TARGET_ABS/.git" ]; then
		for WT in "$TARGET_ABS"/.git/worktrees/*/; do
			[ -f "${WT}gitdir" ] || continue
			LINKED=$(cat -- "${WT}gitdir" 2>/dev/null)
			[ -n "$LINKED" ] && [ -e "$LINKED" ] || continue
			echo "Error: $1 has linked work trees registered; recreating its .git would break them" >&2
			return $RC_INVALID
		done
	fi
	# Without a ref nothing reconciles the working tree afterwards: the files
	# would be left untracked beside a new .git, and a clean would then throw
	# them away - both on a run that reports success.
	if [ -z "$TARGET_REF" ]; then
		echo "Error: $1 needs recovery, which requires --target-ref to put its working tree back" >&2
		return $RC_INVALID
	fi
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

	# -uall: a local status.showUntrackedFiles=no would otherwise mute the
	# verdict, though not the clean itself.
	STATUS=$(git -C "$1" status --porcelain -uall --ignored) || return $RC_DAMAGE
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
			# rev-parse resolves refs before object ids, and this script
			# creates a local branch for every branch it builds - so an
			# all-hex branch name deleted upstream would resolve to that
			# leftover. The object id has to match what was asked for.
			case "$2" in
				"" | *[!0-9a-fA-F]* ) ;;
				* ) LOWER=$(printf '%s' "$2" | tr 'A-F' 'a-f')
					FULL=$(git -C "$1" rev-parse --verify --quiet "$LOWER^{commit}" 2>/dev/null)
					case "$FULL" in
						"$LOWER"* ) echo "$FULL"; return 0 ;;
					esac ;;
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
	echo "Error: HEAD is $HAVE, expected $WANT for $2" >&2
	return $RC_DAMAGE
}

# Everything done to a target that already exists, in order, so the
# dispatcher can retry the lot after a repair instead of restating the rule
# at every step.
# core.worktree points git's idea of the work tree somewhere else, and every
# command here would follow it: clean would wipe that other directory and the
# checkout would write there, while the dir the caller named keeps its old
# content and HEAD still matches. Recreating .git drops the setting.
# The other half of the same rule: a .git that is a file - the gitfile a
# linked worktree or a submodule uses - keeps the metadata in another
# checkout. Index, HEAD, the lock sweep and the fetch would all be that
# repo's while the files land here, so the caller's dir comes out right and
# the other one is left with a moved HEAD over an old work tree, at exit 0.
# Checked before anything is touched, and repairable: recovery deletes the
# gitfile, not the repo it names.
check_target_layout() {
	# Before -d, which follows the link, as does every path comparison
	# below: a .git symlinked into another checkout answers all of them
	# with that checkout's own answers.
	[ -L "$1/.git" ] && { echo "Warning: $1 reaches its .git through a symlink" >&2; return $RC_DAMAGE; }
	[ -d "$1/.git" ] || { echo "Warning: $1 has no .git directory of its own" >&2; return $RC_DAMAGE; }
	GD=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return $RC_DAMAGE
	GD=$(abs_path "$GD")
	[ "$GD" = "$(abs_path "$1/.git")" ] || { echo "Warning: $1 keeps its metadata in $GD" >&2; return $RC_DAMAGE; }
	COMMON=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return $RC_DAMAGE
	case "$COMMON" in
		/* | ?:[/\\]* ) COMMON=$(abs_path "$COMMON") ;;
		* ) COMMON=$(abs_path "$1/$COMMON") ;;
	esac
	[ "$COMMON" = "$GD" ] || { echo "Warning: $1 shares the git dir $COMMON" >&2; return $RC_DAMAGE; }
	return 0
}

check_worktree_root() {
	TOP=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return $RC_DAMAGE
	[ "$(abs_path "$TOP")" = "$1" ] && return 0
	echo "Warning: $1 uses a different work tree: $TOP" >&2
	return $RC_DAMAGE
}

# A tracked file marked skip-worktree is left alone by clean, reset and a
# forced checkout alike, so the run would report success over content that is
# not the ref's. Sparse checkout works through the same bit. Recreating .git
# clears both, and the objects come back from the reference store.
has_skip_worktree() {
	git -C "$1" ls-files -t 2>/dev/null | grep -q '^S '
}

target_steps() {
	check_target_layout "$1" || return $?
	check_worktree_root "$1" || return $?
	clear_stale_locks "$1"
	has_skip_worktree "$1" && { echo "Warning: $1 has files marked skip-worktree" >&2; return $RC_DAMAGE; }
	set_refspecs "$1" || return $?
	fetch_repo "$1" fetch --prune --force --recurse-submodules=no || return $?
	if [ "$CLEAN" ]; then
		clean "$1" || return $?
	fi
	if [ "$TARGET_REF" ]; then
		checkout "$1" "$TARGET_REF" || return $?
		# A sparse checkout with nothing currently excluded leaves no trace
		# before the fetch, and only marks paths the new commit adds. The
		# invariant is that a finished target holds none of them at all.
		has_skip_worktree "$1" && { echo "Warning: the checkout left files marked skip-worktree in $1" >&2; return $RC_DAMAGE; }
	fi
	clear_replace_refs "$1" || return $?
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

# Recorded before prepare_dir, which creates the dir in order to resolve it.
TARGET_EXISTED=
REF_EXISTED=
[ "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ] && TARGET_EXISTED=1
[ "$REF_DIR" ] && [ -d "$REF_DIR" ] && REF_EXISTED=1

# From here on both are canonical: every git, find and rm below gets the path
# that was actually checked, not the string the caller wrote.
if [ "$REF_DIR" ]; then
	REF_DIR=$(prepare_dir "$REF_DIR") || exit $?
fi
if [ "$TARGET_DIR" ]; then
	TARGET_DIR=$(prepare_dir "$TARGET_DIR") || exit $?
fi
if [ "$REF_DIR" ] && [ "$TARGET_DIR" ]; then
	check_disjoint "$REF_DIR" "$TARGET_DIR" || exit $?
fi

if [ "$REF_DIR" ]; then
	ensure_ref_repo "$REF_DIR" || exit $?
fi

[ -z "$TARGET_DIR" ] && exit 0

# A target that is not a usable repo is rebuilt before anything else; only
# then are the steps tried, and only a repairable failure earns one repair
# and one retry. An invalid invocation stops here rather than being answered
# by deleting metadata.
if [ -z "$TARGET_EXISTED" ]; then
	create_target_repo "$TARGET_DIR" || exit $?
elif ! is_repo "$TARGET_DIR" .git; then
	echo "Warning: $TARGET_DIR is not a valid git repo"
	recover_target_repo "$TARGET_DIR" || exit $?
else
	# A check that reports damage earns a repair; one that reports an
	# invalid invocation stops the run. The layout comes first: identity
	# and alternates read through whatever .git resolves to, so a target
	# borrowing another checkout's metadata would be judged - and refused
	# as someone else's repository - on that checkout's answers, when all
	# it needs is its own .git.
	RC=0
	check_target_layout "$TARGET_DIR" || RC=$?
	if [ "$RC" -eq 0 ]; then
		check_identity "$TARGET_DIR" || RC=$?
		# A target naming another repository is damage, not a refusal: the
		# no-rebind rule protects a store other checkouts borrow from, and
		# a target lends nothing. All it costs is a working tree the
		# checkout would replace anyway. The reference dir keeps the rule.
		[ "$RC" -eq "$RC_INVALID" ] && RC=$RC_DAMAGE
		# check_alternates says what is wrong itself; this one is the only
		# diagnosis a missing origin gets.
		[ "$RC" -ne 0 ] && echo "Warning: $TARGET_DIR has no usable origin"
		[ "$RC" -eq 0 ] && { check_alternates "$TARGET_DIR" || RC=$?; }
	fi
	if [ "$RC" -eq "$RC_INVALID" ]; then
		exit $RC
	elif [ "$RC" -ne 0 ]; then
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
