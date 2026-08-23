#!/bin/sh
#
# Checkout a git repo, borrowing objects from a shared reference repo.
#
# Three states are told apart throughout, because they call for different
# answers: a repo whose metadata are damaged gets repaired; a wrong
# invocation - a reference dir belonging to another repository, a ref that
# does not exist - gets refused; a fetch that merely kept failing gets a
# code of its own, because at chromium scale a dying pack transfer is
# routine and no local action fixes it. Conflating them once let a stale
# build pass for a good one, and let one job rebind the cache every other
# job reads.
#
# Repair escalates the way a human would: in place first, then a rebuild
# that keeps what is expensive, then deleting the repo and cloning from
# nothing. The last rung is earned, not defaulted to: only damage diagnosed
# in the repo itself climbs there, only for a repo whose identity was
# positively established, and only with the remote answering a probe. A
# failing fetch never costs a working tree or a store's objects; the most
# it buys - and only with the remote answering - is the .git rebuild, since
# broken refs are one way a fetch fails. What fsck then implicates in a
# store is damage, not a failing fetch. Every rung is tried once; an
# invalid invocation stops the climb wherever it shows.
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
	GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2 \
	GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_GRAFT_FILE GIT_ATTR_SOURCE

# The runner exports the token to the whole step. It leaves the environment
# here - before any option is parsed, any trace enabled or any git command
# run - so no child of any git command, a smudge filter included, can read
# it; it survives only as unexported shell state for grant_token. set +a
# first: an inherited allexport would silently re-export the copy. And the
# destination is unset before the assignment: a CHECKOUT_TOKEN inherited
# from the environment carries its export attribute through set +a, and a
# plain assignment would hand the secret to every child under the new name.
set +a
unset CHECKOUT_TOKEN
CHECKOUT_TOKEN=${GITHUB_TOKEN-}
unset GITHUB_TOKEN

# A replacement ref is the same redirection one level down: it swaps the tree
# behind a commit while its id - the one every check here compares - stays the
# requested one. The refs are left in place, they are just not applied.
GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_REPLACE_OBJECTS

RC_DAMAGE=1     # unfinished - damage, or a repair this run would not risk
RC_INVALID=2    # the caller asked for something impossible - not repairable
RC_FETCH=3      # the fetch kept failing - nothing local left to repair

usage() {
	echo Usage: `basename $0` "[--repo REPO_URL] [--ref-dir DIR] [--target-dir DIR] [--target-ref GIT_REF] [--clean] [--debug]"
	echo "Exit: 0 ok, $RC_DAMAGE unfinished - damage a repair did not fix, $RC_INVALID invalid invocation, $RC_FETCH a fetch that kept failing"
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

# Whether an https url smuggles credentials in its authority. Only the
# authority is inspected - an '@' later in the path is somebody's name.
url_has_userinfo() {
	case "$1" in
		https://* )
			UHU=${1#https://}
			UHU=${UHU%%/*}
			case "$UHU" in *@* ) return 0 ;; esac ;;
	esac
	return 1
}

# A url as diagnostics may show it: without the query string and with the
# authority userinfo masked - the two places a secret rides by mistake. The
# full value stays in use internally.
shown() {
	SHW=${1%%\?*}
	case "$SHW" in
		*://*@* )
			SHW_SCHEME=${SHW%%://*}
			SHW_REST=${SHW#*://}
			SHW_AUTH=${SHW_REST%%/*}
			case "$SHW_AUTH" in
				*@* ) SHW=$SHW_SCHEME://***@${SHW_AUTH##*@}${SHW_REST#"$SHW_AUTH"} ;;
			esac ;;
	esac
	printf '%s\n' "$SHW"
}

# $1 if it is a whole number, $2 otherwise. The retry and maintenance knobs
# come from the environment, and a stray value must not be able to crash
# shell arithmetic - dash aborts the script on it - or silently disable a
# gate.
int_or() {
	case "$1" in
		'' | *[!0-9]* ) printf '%s\n' "$2" ;;
		* ) printf '%s\n' "$1" ;;
	esac
}

# The object store a repo keeps its objects in, as an absolute path.
objects_dir() {
	OD=$(git -C "$1" rev-parse --git-path objects 2>/dev/null) || return 1
	case "$OD" in
		/* | ?:[/\\]* ) echo "$OD" ;;
		* ) echo "$(abs_path "$1")/$OD" ;;
	esac
}

# --- paths and identity ----------------------------------------------------

# Whether two spellings name the same repository. They can differ without
# disagreeing: git-bash converts a path handed to git into its Windows form,
# so the url the caller wrote and the one git stored or expanded name one
# directory in two ways. Only paths are compared that way - a url resolves to
# nothing, and two different ones must never come out equal by both resolving
# to nothing.
same_repo() {
	[ "$1" = "$2" ] && return 0
	SR_A=$(abs_path "$1")
	[ -n "$SR_A" ] && [ "$SR_A" = "$(abs_path "$2")" ] && return 0
	# Resolving needs the directory to exist, and on git-bash the two
	# spellings of one path diverge even then: the url git stored is the
	# windows form of the posix path the caller wrote. Once the remote goes
	# missing the resolution above cannot reconcile them, and an outage
	# would read as a different repository. cygpath translates by the mount
	# table without touching the filesystem; distinct paths stay distinct,
	# so nothing new comes out equal.
	if [ "$MSYSTEM" ] && command -v cygpath >/dev/null 2>&1; then
		SR_A=$(cygpath -m -- "$1" 2>/dev/null)
		[ -n "$SR_A" ] && [ "$SR_A" = "$(cygpath -m -- "$2" 2>/dev/null)" ] && return 0
	fi
	return 1
}

# A filesystem root - /, //, a drive, a UNC server or share root - or nothing
# at all. The one list both path guards (prepare_dir, deletable_dir) share:
# the two copies it replaced had already drifted apart once.
is_fs_root() {
	case "$1" in
		"" | / | // | ?:[/\\] | ?:[/\\][/\\] ) return 0 ;;
		//*/*/* ) return 1 ;;
		//* ) return 0 ;;
	esac
	return 1
}

# Turns a caller's path into the one path the rest of the run uses. A '..' in
# a path that does not exist yet cannot be resolved, and means something else
# once the dirs above it appear - 'base/keep/new/..' becomes 'base/keep', a
# directory that belongs to someone else and is about to be git init'd and
# cleaned. Such a path is refused; a filesystem root is refused both as
# written and as resolved. Absolute paths outside the workspace stay allowed:
# on Windows the default workspace is too deep for a chromium checkout, so
# ours live elsewhere. Prints the canonical path.
prepare_dir() {
	if is_fs_root "$1"; then
		echo "Error: unsafe repository directory: '$1'" >&2
		return $RC_INVALID
	fi
	if [ ! -d "$1" ]; then
		# Both separators: Win32 collapses '\..' the same way, and the
		# action supports Windows paths.
		case "$1" in
			.. | ../* | */.. | */../* | \
			..\\* | *\\.. | *\\..\\* | */..\\* | *\\../* )
				echo "Error: '..' is not allowed in a path that does not exist yet: '$1'" >&2
				return $RC_INVALID ;;
		esac
	fi
	mkdir -p -- "$1" 2>/dev/null || { echo "Error: cannot create directory: '$1'" >&2; return $RC_DAMAGE; }
	DIR_ABS=$(abs_path "$1")
	if is_fs_root "$DIR_ABS"; then
		echo "Error: unsafe repository directory: '$1' resolves to '$DIR_ABS'" >&2
		return $RC_INVALID
	fi
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

# The path a repair is about to delete, resolved fresh at that moment rather
# than trusted from earlier in the run: '/tmp/..' and a symlink to / both name
# the root while looking harmless. Prints the resolved path; fails on a
# filesystem root or a path that resolves to nothing.
deletable_dir() {
	DEL=$(abs_path "$1")
	is_fs_root "$DEL" && return 1
	printf '%s\n' "$DEL"
}

# Whether $2, relative to $1, is a usable git dir ('.git' for a target, '.'
# for a bare store); a gitfile pointing at one also answers yes.
is_repo() {
	git -C "$1" rev-parse --resolve-git-dir "$2" >/dev/null 2>&1
}

is_bare_repo() {
	is_repo "$1" . && [ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null)" = true ]
}

# Reads the config file directly, so a repo too damaged for git to open still
# gets its identity checked. Repair must never be a way to rebind a store
# that other checkouts borrow objects from. The config-file twin of
# check_identity below - keep the two in step. Both run with xtrace off: a
# stored url is disk content nobody validated, and under --debug the trace
# would print it - credentials and all - before any check could refuse it.
check_stored_identity() {
	CSI_XT=; case $- in *x*) CSI_XT=1; set +x ;; esac
	CSI_RC=0; _stored_identity "$1" || CSI_RC=$?
	[ "$CSI_XT" ] && set -x
	return $CSI_RC
}
_stored_identity() {
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
	# --repo omitted: adopt the stored url - unless it carries credentials,
	# which must neither be echoed nor spread into every later command.
	# grant_token never grants the token for an adopted url either way.
	if [ -z "$URL" ]; then
		if url_has_userinfo "$CURRENT"; then
			echo "Error: the stored origin of $1 carries credentials; refusing to adopt it" >&2
			return $RC_INVALID
		fi
		URL=$CURRENT
		return 0
	fi
	same_repo "$CURRENT" "$URL" && return 0
	echo "Error: $1 belongs to $(shown "$CURRENT"), not to $(shown "$URL")" >&2
	return $RC_INVALID
}

# RC_INVALID when the repo belongs to a different remote: rebinding it would
# point every checkout sharing this store at another project. The open-repo
# twin of check_stored_identity above, with the same xtrace discipline.
check_identity() {
	CI_XT=; case $- in *x*) CI_XT=1; set +x ;; esac
	CI_RC=0; _open_identity "$1" || CI_RC=$?
	[ "$CI_XT" ] && set -x
	return $CI_RC
}
_open_identity() {
	COUNT=$(git -C "$1" config --local --get-all remote.origin.url 2>/dev/null | sort -u | wc -l)
	CURRENT=$(git -C "$1" config --local --get-all remote.origin.url 2>/dev/null | head -1)
	[ -z "$CURRENT" ] && return $RC_DAMAGE
	if [ "$COUNT" -gt 1 ]; then
		echo "Error: $1 has more than one distinct origin url" >&2
		return $RC_INVALID
	fi
	if [ -z "$URL" ]; then
		if url_has_userinfo "$CURRENT"; then
			echo "Error: the stored origin of $1 carries credentials; refusing to adopt it" >&2
			return $RC_INVALID
		fi
		URL=$CURRENT
		return 0
	fi
	same_repo "$CURRENT" "$URL" && return 0
	echo "Error: $1 belongs to $(shown "$CURRENT"), not to $(shown "$URL")" >&2
	return $RC_INVALID
}

# Whether the alternates file at $1 names REF_DIR's own object store.
# Compared as directories, not as strings: an older version of this script
# wrote the logical path, so a store reached through a symlink spells the
# same directory differently and a healthy checkout would otherwise be
# refused for good. Both sides must actually resolve - two paths that
# resolve to nothing are unknown, not equal.
alternates_match() {
	[ "$REF_DIR" ] || return 1
	[ -s "$1" ] || return 1
	BORROWED=$(cat "$1" 2>/dev/null) || return 1
	EXPECTED=$(objects_dir "$REF_DIR") || return 1
	AM_A=$(abs_path "$BORROWED")
	[ -n "$AM_A" ] && [ "$AM_A" = "$(abs_path "$EXPECTED")" ]
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
	alternates_match "$ALT" && return 0
	# Damage, not a caller mistake: recreating a target's .git never rebinds
	# the shared store - that firewall is the reference dir's identity check.
	echo "Warning: $1 borrows objects from $BORROWED, not from $EXPECTED" >&2
	return $RC_DAMAGE
}

# --- configuration --------------------------------------------------------

# origin is the action's to define, not a set to append to. An extra fetch
# refspec left in place breaks a run in a way nothing else notices: a negative
# one ('^refs/heads/main') keeps the branch out of the fetch, so the remote
# ref stays behind and the checkout - and the HEAD check, reading that same
# ref - both pass on an old commit.
set_origin() {
	git -C "$1" config --unset-all remote.origin.url 2>/dev/null || true
	git -C "$1" config --unset-all remote.origin.fetch 2>/dev/null || true
	git -C "$1" config --add remote.origin.url "$URL" || return $RC_DAMAGE
	set_refspecs "$1"
}

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

# The stored refspecs are for whoever opens the repo by hand later; the fetch
# below passes its own on the command line and never reads these. They are
# kept equal to it so a manual fetch does the same thing.
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

# The credential goes to the command that needs it through the environment -
# not into a config file, which the reference dir would keep for every later
# step, and not into argv, which is readable from any process listing. xtrace
# is off around the token and its encoding, which a runner is not obliged to
# mask. drop_token puts the environment back. Granted only for a url the
# caller named: a url adopted from a repo's own config would otherwise pick
# the host the token is sent to.
grant_token() {
	XTRACE=
	case $- in *x*) XTRACE=1; set +x ;; esac
	if [ "$URL_FROM_CALLER" ] && [ "$URL" = "https://${URL#https://}" ] && [ "$CHECKOUT_TOKEN" ]; then
		GIT_CONFIG_COUNT=3
		GIT_CONFIG_KEY_2=http.extraHeader
		GIT_CONFIG_VALUE_2="Authorization: basic $(printf '%s' "x-access-token:$CHECKOUT_TOKEN" | base64 | tr -d '\n')"
		export GIT_CONFIG_COUNT GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2
	fi
	[ "$XTRACE" ] && set -x
	return 0
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
fetch_repo() {
	DIR=$1; shift
	# git rewrites the url it is handed through url.<base>.insteadOf, so the
	# repo the caller named and the one the fetch reaches can differ while
	# every identity check still passes: the store keeps the name of one repo
	# and the objects of another. The rewrite is refused rather than followed,
	# since it usually comes from the machine's own config and nothing here
	# could repair it. Asked in the same dir the fetch runs in, which is what
	# decides the answer.
	# Read and judged with xtrace off: a rewrite is machine configuration
	# nobody validated, and it can splice credentials into the effective
	# url - the trace would print them before shown() could mask anything.
	FR_XT=; case $- in *x*) FR_XT=1; set +x ;; esac
	FR_ACT=ok
	EFFECTIVE=$(git -C "$DIR" ls-remote --get-url "$URL") || FR_ACT=unreadable
	if [ "$FR_ACT" = ok ] && ! same_repo "$EFFECTIVE" "$URL"; then
		FR_ACT=rewritten
		FR_SHOWN=$(shown "$EFFECTIVE")
		FR_URL_SHOWN=$(shown "$URL")
	fi
	[ "$FR_XT" ] && set -x
	case "$FR_ACT" in
		unreadable ) return $RC_DAMAGE ;;
		rewritten )
			echo "Error: git config rewrites '$FR_URL_SHOWN' to '$FR_SHOWN' - remove the url.*.insteadOf entry" >&2
			return $RC_INVALID ;;
	esac
	grant_token
	# Anything an older version of this script persisted.
	git -C "$DIR" config --unset-all http.extraHeader 2>/dev/null || true

	retries=$(int_or "${GIT_FETCH_RETRIES:-}" 5)
	delay=$(int_or "${GIT_FETCH_DELAY:-}" 2)
	while :; do
		git -C "$DIR" "$@" "$URL" \
			'+refs/heads/*:refs/remotes/origin/*' \
			'+refs/tags/*:refs/tags/*' \
			'+refs/pull/*/head:refs/remotes/origin/pull/*/head' \
			'+refs/pull/*/merge:refs/remotes/origin/pull/*/merge' && { drop_token; return 0; }
		retries=$((retries - 1))
		if [ "$retries" -le 0 ]; then
			drop_token
			return $RC_FETCH
		fi
		echo "Git command failed. Retrying in ${delay}s..."
		sleep $delay
		delay=$((delay * 2))
	done
}

# Whether the remote answers at all - the last check before a repair deletes
# a repo, because deleting is pointless at the exact moment nothing can be
# fetched back. Asked from the same directory the fetch runs in, so a
# relative url resolves to the same place and a url rewrite is seen by the
# same config - a probe answered by a different remote than the fetch's is
# no evidence. The rewrite check runs before the token is granted, so the
# credential is never sent to a host a rewrite chose.
probe_remote() {
	# The same xtrace discipline as fetch_repo's rewrite check: the
	# effective url is unvalidated machine configuration.
	PR_XT=; case $- in *x*) PR_XT=1; set +x ;; esac
	PR_OK=
	PROBE_EFFECTIVE=$(git -C "$1" ls-remote --get-url "$URL" 2>/dev/null) \
		&& same_repo "$PROBE_EFFECTIVE" "$URL" && PR_OK=1
	[ "$PR_XT" ] && set -x
	[ "$PR_OK" ] || return 1
	grant_token
	git -C "$1" ls-remote "$URL" HEAD >/dev/null 2>&1
	PROBE_RC=$?
	drop_token
	return $PROBE_RC
}

# Whether $1 is this mechanism's journal and nothing else: a real directory
# holding the file the transaction wrote when it opened - and, once the
# rename actually happened, the 'moved' flag written right after it. That
# flag is what binds a journal to its own trash: a journal opened by a
# transaction that died before renaming anything must never vouch for
# whatever appears at the trash name later. Anything shaped differently was
# not written here and is not this mechanism's to remove.
journal_ours() {
	[ -d "$1" ] || return 1
	[ -L "$1" ] && return 1
	[ -f "$1/origin" ] || return 1
	[ -L "$1/origin" ] && return 1
	case "$(find "$1" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" in
		1 ) ;;
		2 ) { [ -f "$1/moved" ] && [ ! -L "$1/moved" ]; } || return 1 ;;
		* ) return 1 ;;
	esac
	same_repo "$(cat "$1/origin" 2>/dev/null)" "$URL"
}

# Closes a journal journal_ours vouched for, without recursion: only the
# files the transaction wrote are removed, so anything unexpected that
# appeared since keeps the rmdir from destroying it.
close_journal() {
	rm -f -- "$1/origin" "$1/moved" 2>/dev/null
	rmdir -- "$1" 2>/dev/null || echo "Warning: could not close the journal $1" >&2
}

# Deletion by rename first: mv of a directory is atomic where rm -rf is not.
# An open handle - normal on git-bash - fails the whole rename and the repo
# stays untouched, instead of failing halfway through a delete. The clone
# then goes to the original path, the old content is removed only after the
# clone succeeded, and a failed clone puts the old content back. When the
# old content cannot be removed or put back, it stays at <dir>.gone - named
# in a warning - and the next run through this rung clears that leftover,
# announcing it: <dir>.gone belongs to this mechanism, nothing else may
# live there.
replace_repo() {
	TRASH=$1.gone
	JOURNAL=$1.gone-journal
	# Neither reserved path may touch anything this run works on: a store
	# or a target living at or under one of them would be cleared with it.
	case "$REF_DIR" in
		"$TRASH" | "$TRASH"/* | "$JOURNAL" | "$JOURNAL"/* )
			echo "Error: the reference dir is inside $TRASH or its journal" >&2
			return $RC_DAMAGE ;;
	esac
	case "$TARGET_DIR" in
		"$TRASH" | "$TRASH"/* | "$JOURNAL" | "$JOURNAL"/* )
			echo "Error: the target dir is inside $TRASH or its journal" >&2
			return $RC_DAMAGE ;;
	esac
	# No repair leaves a symlink behind at either name - mv moves a
	# directory and mkdir makes one - so a symlink is somebody else's, and
	# even reading through it is not ours to do.
	if [ -L "$TRASH" ] || [ -L "$JOURNAL" ]; then
		echo "Error: $TRASH or its journal is a symlink, which no repair leaves behind; move it away" >&2
		return $RC_DAMAGE
	fi
	if [ -e "$TRASH" ]; then
		# Cleared only after proving itself a leftover on two counts: the
		# journal this mechanism wrote beside it before the rename, and
		# the stored origin of the repo it is a copy of. Identity alone
		# would also match a same-origin backup somebody parked at this
		# name, and nothing inside the moved tree counts as proof - repo
		# content is not this mechanism's writing. Everything else is
		# refused and named so a human can move it away.
		if journal_ours "$JOURNAL" && [ -f "$JOURNAL/moved" ] \
			&& { check_stored_identity "$TRASH" 2>/dev/null \
				|| check_stored_identity "$TRASH/.git" 2>/dev/null; }; then
			echo "Warning: clearing $TRASH left behind by an earlier repair"
			chmod -R -- u+rwX "$TRASH" 2>/dev/null || true
			rm -rf -- "$TRASH" 2>/dev/null
		else
			echo "Error: $TRASH exists and is not an earlier repair's leftover; move it away" >&2
			return $RC_DAMAGE
		fi
	fi
	[ -e "$TRASH" ] && { echo "Error: cannot clear $TRASH" >&2; return $RC_DAMAGE; }
	# The journal opens the transaction before the rename, so a crash at
	# any later point leaves a pair the next run can prove and collect. A
	# journal alone is a crash before the rename - nothing moved, nothing
	# to collect - and it is closed, never recursively removed: anything
	# else squatting at the reserved name is refused, exactly like the
	# trash path itself.
	if [ -e "$JOURNAL" ]; then
		if journal_ours "$JOURNAL"; then
			close_journal "$JOURNAL"
		else
			echo "Error: $JOURNAL exists and is not this mechanism's journal; move it away" >&2
			return $RC_DAMAGE
		fi
	fi
	mkdir -- "$JOURNAL" || { echo "Error: cannot open the journal $JOURNAL" >&2; return $RC_DAMAGE; }
	printf '%s\n' "$URL" > "$JOURNAL/origin" || { close_journal "$JOURNAL"; return $RC_DAMAGE; }
	if ! mv -- "$1" "$TRASH"; then
		echo "Error: cannot move $1 aside" >&2
		close_journal "$JOURNAL"
		return $RC_DAMAGE
	fi
	# The rename is on record from this moment: only a journal that says
	# 'moved' may ever vouch for what sits at the trash name. Best effort -
	# if this write dies, the pair is refused later and a human unties it,
	# which errs on the safe side.
	: > "$JOURNAL/moved" 2>/dev/null || true
	REPL_RC=0; "$2" "$1" || REPL_RC=$?
	if [ "$REPL_RC" -eq 0 ]; then
		chmod -R -- u+rwX "$TRASH" 2>/dev/null || true
		rm -rf -- "$TRASH" 2>/dev/null || true
		if [ -e "$TRASH" ]; then
			echo "Warning: the old content is left at $TRASH" >&2
		else
			close_journal "$JOURNAL"
		fi
		return 0
	fi
	# The failed clone has to leave before the old content returns: mv onto
	# an existing directory nests instead of replacing, silently.
	rm -rf -- "$1" 2>/dev/null
	if [ -e "$1" ]; then
		echo "Error: cannot clear the failed clone at $1; the old content is at $TRASH" >&2
	elif mv -- "$TRASH" "$1"; then
		close_journal "$JOURNAL"
	else
		echo "Error: the old content is stranded at $TRASH" >&2
	fi
	return $REPL_RC
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
# repair is the create path minus the destruction. Deleting the store is kept
# for the last rung at the bottom: every target borrowing from it loses
# objects then, and buys them back through a rebuild of its own.
ensure_ref_repo() {
	[ -z "$REF_EXISTED" ] && { create_ref_repo "$1"; return $?; }
	# A worktree is not a reference repo: alternates would name a directory
	# that does not exist, and the cache would silently do nothing.
	if [ -e "$1/.git" ]; then
		echo "Error: $1 is a work tree, not a bare repository" >&2
		return $RC_INVALID
	fi
	# Identity first, so a repo too damaged to open cannot be rebound. A
	# match is also what later earns the right to delete: a dir that never
	# showed an origin of this repository may hold anything at all.
	RC=0; check_stored_identity "$1" || RC=$?
	[ "$RC" -eq "$RC_INVALID" ] && return $RC
	[ "$RC" -eq 0 ] && REF_IDENTIFIED="matched"
	# A dir that is not empty, shows no identity and has none of a bare
	# repo's bones was never a store of anything - repair has no business
	# sweeping its lock files, moving its 'config' aside or initializing
	# git among its content. An empty dir is fine to adopt, and so is a
	# recognizable store however damaged, identified or bare-shaped.
	if [ -z "$REF_IDENTIFIED" ] \
		&& [ "$(find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ] \
		&& ! { [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ]; }; then
		echo "Error: $1 is not empty and not a recognizable repository store" >&2
		return $RC_INVALID
	fi
	# A config git cannot parse kills every command including the init that
	# would repair it. Salvage origin's url by hand to keep the no-rebind
	# guarantee, then move the file aside so the repair can run at all.
	if [ -f "$1/config" ] && ! git config --includes --file "$1/config" --list >/dev/null 2>&1; then
		if grep -qiE '^[[:space:]]*\[include' "$1/config"; then
			echo "Error: $1 has an unreadable config with includes; its identity cannot be established" >&2
			return $RC_INVALID
		fi
		# Section and variable names are case-insensitive to git, the
		# subsection name is not. Read with xtrace off, like every other
		# url taken from disk: the trace would print it unredacted. A url
		# that disagrees means the store belongs to someone else and must
		# not be rebound; nothing readable at all is a different thing -
		# there is no identity to protect, only a dir to repair. A salvaged
		# match is still an identification - only the file around the url
		# is broken - so it earns what a readable match earns.
		SLV_XT=; case $- in *x*) SLV_XT=1; set +x ;; esac
		SALVAGED=$(awk '
			/^[[:space:]]*\[/ { in_origin = ($0 ~ /^[[:space:]]*\[[Rr][Ee][Mm][Oo][Tt][Ee][[:space:]]+"origin"\]/) }
			in_origin && /^[[:space:]]*[Uu][Rr][Ll][[:space:]]*=/ {
				sub(/^[[:space:]]*[Uu][Rr][Ll][[:space:]]*=[[:space:]]*/, ""); print; exit
			}' "$1/config")
		SLV_ACT=ok
		SLV_SHOWN=
		SLV_URL_SHOWN=
		if [ "$SALVAGED" ]; then
			# Credentials first, whatever the caller supplied: a value
			# like that is neither adopted nor compared nor echoed.
			if url_has_userinfo "$SALVAGED"; then
				SLV_ACT=creds
			elif [ -z "$URL" ]; then
				URL=$SALVAGED
				REF_IDENTIFIED="salvaged"
			elif ! same_repo "$SALVAGED" "$URL"; then
				SLV_ACT=mismatch
				SLV_SHOWN=$(shown "$SALVAGED")
				SLV_URL_SHOWN=$(shown "$URL")
			else
				REF_IDENTIFIED="salvaged"
			fi
		fi
		[ "$SLV_XT" ] && set -x
		case "$SLV_ACT" in
			creds )
				echo "Error: the salvaged origin of $1 carries credentials; refusing it" >&2
				return $RC_INVALID ;;
			mismatch )
				echo "Error: $1 has an unreadable config; its origin reads '$SLV_SHOWN', not '$SLV_URL_SHOWN'" >&2
				return $RC_INVALID ;;
		esac
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
	echo "SELF-HEAL: store rung=reinit dir=$1"
	RC=0; create_ref_repo "$1" || RC=$?
	case "$RC" in
		0 | "$RC_INVALID" ) return $RC ;;
	esac
	# The rung after the in-place repair - reached with the store's own
	# structure refusing the reinit (RC_DAMAGE), or with the fetch still
	# failing over a store that reinit found sound (RC_FETCH). The second
	# says nothing about the objects by itself: at this scale a dying pack
	# transfer is routine, and deleting cannot fix a transfer. Only fsck
	# implicating the objects - one pack a killed fetch left truncated fails
	# every fetch after it - turns that into damage worth the delete.
	if [ "$RC" -eq "$RC_FETCH" ]; then
		git -C "$1" fsck --connectivity-only >/dev/null 2>&1 && return $RC
		echo "Warning: $1 fails fsck - its objects are implicated" >&2
	fi
	# Deleting is earned by identity, not by damage: without an origin that
	# matched, this dir was never shown to be a store of $URL at all.
	if [ -z "$REF_IDENTIFIED" ]; then
		echo "Warning: not deleting $1 - it was never identified as a store of $(shown "$URL")" >&2
		return $RC
	fi
	STORE_ABS=$(deletable_dir "$1") || {
		echo "Error: refusing to delete unsafe reference dir: '$1'" >&2
		return $RC
	}
	# The last check: a remote that stopped answering is the one problem
	# deleting can never fix, so the store is kept for when it returns. A
	# target that borrowed objects the new store no longer holds is repaired
	# by its own ladder - usually the .git rebuild is enough, and a clone is
	# behind it.
	if ! probe_remote "$STORE_ABS"; then
		echo "Error: $(shown "$URL") is not answering; keeping $1 rather than deleting what could not be recloned" >&2
		return $RC
	fi
	echo "Warning: the repair was not enough, deleting the store $1 and recloning it from scratch"
	echo "SELF-HEAL: store rung=reclone dir=$1"
	replace_repo "$STORE_ABS" create_ref_repo
}

# gc never runs in the store: pruning would delete objects that checkouts
# borrowing through alternates still reference, and the store knows nothing
# about their refs (hence gc.auto=0 on every fetch). So daily fetches grow
# it without bound - loose objects from small fetches, one new pack per
# larger one. Repacking is the safe half of gc: objects are only ever moved
# into a pack, never deleted - --keep-unreachable keeps even what only a
# borrower still reaches. Gated, because the reachability walk behind a
# repack costs minutes on a large history, and the full consolidation also
# rewrites every pack. Raise the limits to leave the job to external
# maintenance. Best effort: a failed repack never fails the run.
compact_store() {
	GD=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
	PACKS=$(find "$GD/objects/pack" -name '*.pack' -type f 2>/dev/null | wc -l | tr -d ' ')
	LOOSE=$(find "$GD"/objects/[0-9a-f][0-9a-f] -type f 2>/dev/null | wc -l | tr -d ' ')
	PACK_LIMIT=$(int_or "${GIT_STORE_PACK_LIMIT:-}" 64)
	LOOSE_LIMIT=$(int_or "${GIT_STORE_LOOSE_LIMIT:-}" 512)
	if [ "$PACKS" -gt "$PACK_LIMIT" ]; then
		echo "Note: consolidating $PACKS packs in $1"
		git -C "$1" repack -a -d -k -q || true
	elif [ "$LOOSE" -gt "$LOOSE_LIMIT" ]; then
		echo "Note: packing $LOOSE loose objects in $1"
		git -C "$1" repack -d -q || true
		# The incremental pass packs only reachable loose objects, while the
		# counter above counts every one. Unreachable loose accumulate as a
		# matter of course - force-updated merge refs, deleted branches - and
		# once they alone exceed the limit, the gate would fire on every run
		# and pay the reachability walk each time, lowering nothing. Only the
		# -k form sweeps them into a pack; one stateless escalation converges
		# in a single step.
		LOOSE=$(find "$GD"/objects/[0-9a-f][0-9a-f] -type f 2>/dev/null | wc -l | tr -d ' ')
		if [ "$LOOSE" -gt "$LOOSE_LIMIT" ]; then
			echo "Note: consolidating to sweep $LOOSE unreachable loose objects in $1"
			git -C "$1" repack -a -d -k -q || true
		fi
	fi
	return 0
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
	fetch_repo "$1" fetch --prune --force --recurse-submodules=no
}

# Linked work trees keep their administrative files under this .git and
# nowhere else: deleting it leaves each of them with 'not a git repository'.
# They are not this run's to rebuild, so the repairs below stop instead.
# Only through a .git of the target's own: a symlink would find the
# registrations of the checkout it points at, and unlinking harms none of
# them. An entry whose gitdir names nothing that exists describes a work
# tree that is already gone - git keeps the entry, and a --clean that
# removed a work tree living inside the target leaves one - so there is
# nothing there to protect.
has_live_linked_worktrees() {
	[ -d "$1/.git" ] && [ ! -L "$1/.git" ] || return 1
	for WT in "$1"/.git/worktrees/*/; do
		[ -f "${WT}gitdir" ] || continue
		LINKED=$(cat -- "${WT}gitdir" 2>/dev/null)
		[ -n "$LINKED" ] && [ -e "$LINKED" ] || continue
		return 0
	done
	return 1
}

# Recreates .git and refetches, keeping the working tree: its untracked
# content is worth hours on a chromium-sized checkout, and the forced
# checkout reconciles every tracked path anyway. Runs once per invocation.
recover_target_repo() {
	[ "$RECOVERED" ] && return $RC_DAMAGE
	TARGET_ABS=$(deletable_dir "$1") || {
		echo "Error: refusing to recover unsafe target dir: '$1'" >&2
		return $RC_INVALID
	}
	if has_live_linked_worktrees "$TARGET_ABS"; then
		echo "Error: $1 has linked work trees registered; recreating its .git would break them" >&2
		return $RC_INVALID
	fi
	# Without a ref nothing reconciles the working tree afterwards: the files
	# would be left untracked beside a new .git, and a clean would then throw
	# them away - both on a run that reports success.
	if [ -z "$TARGET_REF" ]; then
		echo "Error: $1 needs recovery, which requires --target-ref to put its working tree back" >&2
		return $RC_INVALID
	fi
	# What the rebuild needs, checked before anything is deleted: finding
	# out after the rm would cost a usable .git and give nothing back.
	if [ -z "$REF_DIR" ]; then
		echo "Error: $1 cannot be recovered without a reference dir" >&2
		return $RC_INVALID
	fi
	RECOVERED="recovered"
	echo "Warning: recovering $1 - reinitializing its .git (working tree files are kept and reconciled by the checkout)"
	echo "SELF-HEAL: target rung=rebuild dir=$1"
	rm -rf -- "$TARGET_ABS/.git" || return $RC_DAMAGE
	create_target_repo "$1"
}

# The last rung of target repair, and what a human does when rebuilding .git
# was not enough: delete the checkout and clone from nothing. The suspects
# left by then live in the working tree, where debris git itself cannot
# delete fails a clean the same way on every retry - so this time the tree
# goes too, read-only debris being the usual way one becomes undeletable.
# The reference dir is never inside the target - see check_disjoint - so the
# store survives this. Deleting is earned by identity: only a dir that came
# into this run as this repository's checkout, or that this run created, is
# this run's to delete - anything else may hold content that was never the
# action's. The gates the rebuild has are re-checked (the ladder ran them
# already; here they guard the delete itself), and one is new: the remote
# has to answer, since a working tree must not be spent on an outage that
# deleting cannot fix.
nuke_target_repo() {
	if [ -z "$TARGET_TRUSTED" ]; then
		echo "Warning: not deleting $1 - it was never identified as a checkout of $(shown "$URL")" >&2
		return $RC_DAMAGE
	fi
	TARGET_ABS=$(deletable_dir "$1") || {
		echo "Error: refusing to delete unsafe target dir: '$1'" >&2
		return $RC_DAMAGE
	}
	if has_live_linked_worktrees "$TARGET_ABS"; then
		echo "Error: $1 has linked work trees registered; deleting it would break them" >&2
		return $RC_INVALID
	fi
	if [ -z "$TARGET_REF" ]; then
		echo "Error: $1 needs a full rebuild, which requires --target-ref to put a working tree back" >&2
		return $RC_INVALID
	fi
	# What the reclone needs, checked before anything is touched: finding
	# out after the delete would leave nothing behind and nothing back.
	if [ -z "$REF_DIR" ]; then
		echo "Error: $1 cannot be recloned without a reference dir" >&2
		return $RC_INVALID
	fi
	objects_dir "$REF_DIR" >/dev/null || {
		echo "Error: the reference dir $REF_DIR is unusable; keeping $1" >&2
		return $RC_DAMAGE
	}
	if ! probe_remote "$TARGET_ABS"; then
		echo "Error: $(shown "$URL") is not answering; keeping $1 rather than deleting what could not be recloned" >&2
		return $RC_DAMAGE
	fi
	echo "Warning: repairs were not enough, deleting the checkout $1 and cloning it from scratch"
	echo "SELF-HEAL: target rung=reclone dir=$1"
	replace_repo "$TARGET_ABS" create_target_repo
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
	cat <<-EOF
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

# The one classifier for what a resolved ref names. Prints the commit it
# peels to. A ref that exists but ends at a blob or a tree is the caller's
# mistake - no repair makes it checkoutable, and the ladder would spend a
# working tree learning so. A chain that cannot be walked - an annotated tag
# whose referent is gone - is damage a refetch may heal. cat-file on the ref
# would conflate the two: it proves only that the outermost object reads.
peel_commit() {
	PC=$(git -C "$1" rev-parse --verify --quiet "$2^{commit}")
	if [ -z "$PC" ]; then
		if git -C "$1" rev-parse --verify --quiet "$2^{}" >/dev/null 2>&1; then
			echo "Error: target ref does not point to a commit: $3" >&2
			return $RC_INVALID
		fi
		echo "Warning: $1 cannot read the object behind $2" >&2
		return $RC_DAMAGE
	fi
	printf '%s\n' "$PC"
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
# dir refname resolved commit. Resolution and classification happened in
# target_steps moments ago, with no fetch in between, and the commit id -
# not the mutable name - is what gets materialized: what was judged is what
# is checked out, literally. The branch case still creates the local branch
# the caller expects, pinned at the judged commit.
checkout() {
	case "$3" in
		refs/remotes/origin/* )
			BRANCH=${3#refs/remotes/origin/}
			git -C "$1" checkout --force -B "$BRANCH" "$4" || return $RC_DAMAGE ;;
		* )
			git -C "$1" checkout --force "$4" || return $RC_DAMAGE ;;
	esac
	# A checkout that returns zero has still gone wrong if HEAD is not what
	# was asked for: a refspec lost along the way leaves the remote ref
	# behind, and the build would quietly be of an older commit.
	HAVE=$(git -C "$1" rev-parse HEAD) || return $RC_DAMAGE
	[ "$4" = "$HAVE" ] && return 0
	echo "Error: HEAD is $HAVE, expected $4 for $2" >&2
	return $RC_DAMAGE
}

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
# not the ref's. Sparse checkout works through the same bit, and
# assume-unchanged fails the same way. -v, not -t: only -v lowercases the
# tag of an assume-unchanged entry; -t keeps showing it as a plain H.
# Recreating .git clears them all, and the objects come back from the
# reference store.
has_held_paths() {
	git -C "$1" ls-files -v 2>/dev/null | grep -q '^[[:lower:]S] '
}

# Everything done to a target that already exists, in order, so the
# dispatcher can retry the lot after a repair instead of restating the rule
# at every step.
target_steps() {
	check_target_layout "$1" || return $?
	check_worktree_root "$1" || return $?
	clear_stale_locks "$1"
	has_held_paths "$1" && { echo "Warning: $1 has paths held back by skip-worktree or assume-unchanged" >&2; return $RC_DAMAGE; }
	set_refspecs "$1" || return $?
	fetch_repo "$1" fetch --prune --force --recurse-submodules=no || return $?
	# The ref is judged once more here, after this fetch and before clean:
	# for a run without a reference store this is its first judgement, and
	# for every run it closes the window where the remote changed between
	# the store fetch and this one. From here to the checkout there is no
	# further fetch, so what this resolves is what gets checked out.
	STEP_REF=
	STEP_WANT=
	if [ "$TARGET_REF" ]; then
		STEP_REF=$(resolve_ref "$1" "$TARGET_REF") || return $?
		STEP_WANT=$(peel_commit "$1" "$STEP_REF" "$TARGET_REF") || return $?
	fi
	if [ "$CLEAN" ]; then
		clean "$1" || return $?
	fi
	if [ "$TARGET_REF" ]; then
		checkout "$1" "$TARGET_REF" "$STEP_REF" "$STEP_WANT" || return $?
		# A sparse checkout with nothing currently excluded leaves no trace
		# before the fetch, and only marks paths the new commit adds. The
		# invariant is that a finished target holds none of them at all.
		has_held_paths "$1" && { echo "Warning: the checkout left held-back paths in $1" >&2; return $RC_DAMAGE; }
	fi
	clear_replace_refs "$1" || return $?
	return 0
}


[ $# -eq 0 ] && usage

URL=
URL_FROM_CALLER=
DEBUG_TRACE=
REF_DIR=
TARGET_DIR=
TARGET_REF=
CLEAN=
RECOVERED=
REF_IDENTIFIED=
TARGET_TRUSTED=
while [ $# -gt 0 ]; do
	case "$1" in
		--repo)
			[ -z "$2" ] && echo Error: --repo requires an argument && usage
			URL=$2
			URL_FROM_CALLER=1
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
			# Enabled only after the url is judged: tracing the parse
			# would echo a credential smuggled in the url before the
			# refusal below could fire.
			DEBUG_TRACE=1
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

# Credentials belong in the token input: a url is logged by the debug trace,
# stored in every repo config and printed in diagnostics. Only the authority
# is inspected - an '@' later in the path is somebody's legitimate name.
if url_has_userinfo "$URL"; then
	echo "Error: credentials in the repository url are not supported - pass a token instead" >&2
	exit $RC_INVALID
fi

[ "$DEBUG_TRACE" ] && set -x

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
	compact_store "$REF_DIR"
fi

[ -z "$TARGET_DIR" ] && exit 0

# The requested ref is judged against the store before the target is touched:
# the store just fetched the same refspecs, so a name it cannot resolve does
# not exist upstream, and a ref that peels to a non-commit never will - while
# learning either after a repair or a clean would mean the invalid invocation
# had already cost something. Bare object ids answer to the same rule: the
# store keeps every object it ever fetched, so anything upstream ever served
# still resolves. A commit created only inside the target is not addressable
# when a store is in play - a target may need the very repair that would
# delete the object's sole copy, and metadata no layout check has judged yet
# must not authorize anything. (Without a store, the judgement inside
# target_steps still accepts a target-local id.) An object the store cannot
# read is not judged early: that is damage, the target ladder's to walk.
if [ "$TARGET_REF" ] && [ "$REF_DIR" ]; then
	EARLY=$(resolve_ref "$REF_DIR" "$TARGET_REF") || exit $?
	EARLY_RC=0
	peel_commit "$REF_DIR" "$EARLY" "$TARGET_REF" >/dev/null || EARLY_RC=$?
	[ "$EARLY_RC" -eq "$RC_INVALID" ] && exit $EARLY_RC
fi

# A target that is not a usable repo is rebuilt before anything else; only
# then are the steps tried. A repairable failure climbs a ladder: the steps
# once more after a .git rebuild that keeps the working tree, once more after
# the full reclone - each rung tried once. An invalid invocation stops the
# climb wherever it shows, rather than being answered by deleting metadata;
# a fetch that kept failing climbs no further than the rebuild, since the
# reclone would only run the same fetch over a working tree it just deleted.
RC=0
if [ -z "$TARGET_EXISTED" ]; then
	# A dir this run created holds nothing that is not this run's.
	TARGET_TRUSTED="fresh"
	create_target_repo "$TARGET_DIR" || exit $?
elif ! is_repo "$TARGET_DIR" .git; then
	echo "Warning: $TARGET_DIR is not a valid git repo"
	# Even a .git too broken for git to open can carry the action's
	# signature: alternates naming this run's store, which only this action
	# writes - a data dir has no .git at all, and another repository's
	# checkout borrows from elsewhere. Read from the file directly - the
	# layout checks need a repo that opens - but only through a real .git
	# directory of the target's own, never a symlink or a gitfile into
	# someone else's checkout.
	if [ -d "$TARGET_DIR/.git" ] && [ ! -L "$TARGET_DIR/.git" ] \
		&& alternates_match "$TARGET_DIR/.git/objects/info/alternates"; then
		TARGET_TRUSTED="alternates"
	fi
	recover_target_repo "$TARGET_DIR" || RC=$?
else
	# A check that reports damage earns a repair; one that reports an
	# invalid invocation stops the run. The layout comes first: identity
	# and alternates read through whatever .git resolves to, so a target
	# borrowing another checkout's metadata would be judged - and refused
	# as someone else's repository - on that checkout's answers, when all
	# it needs is its own .git.
	check_target_layout "$TARGET_DIR" || RC=$?
	if [ "$RC" -eq 0 ]; then
		check_identity "$TARGET_DIR" || RC=$?
		# A matching origin on a sound layout is what later earns the
		# delete rung; damage found after this point does not revoke it.
		[ "$RC" -eq 0 ] && TARGET_TRUSTED="matched"
		# The same alternates signature as on the unopenable-.git branch
		# above: a torn config that lost its url does not unmake the
		# checkout. One that names another repository outright is
		# RC_INVALID here - repaired below, never deleted. Without
		# --ref-dir there is no store to compare against, and
		# check_alternates would answer yes for free.
		if [ "$RC" -eq "$RC_DAMAGE" ] && [ "$REF_DIR" ] && check_alternates "$TARGET_DIR" 2>/dev/null; then
			TARGET_TRUSTED="alternates"
		fi
		# check_alternates and check_identity say what is wrong themselves;
		# this one is the only diagnosis a missing origin gets.
		[ "$RC" -eq "$RC_DAMAGE" ] && echo "Warning: $TARGET_DIR has no usable origin"
		# A target naming another repository is damage, not a refusal: the
		# no-rebind rule protects a store other checkouts borrow from, and
		# a target lends nothing. All it costs is a working tree the
		# checkout would replace anyway. The reference dir keeps the rule.
		[ "$RC" -eq "$RC_INVALID" ] && RC=$RC_DAMAGE
		[ "$RC" -eq 0 ] && { check_alternates "$TARGET_DIR" || RC=$?; }
	fi
	# Unreachable today - the checks above return 0 or RC_DAMAGE - and kept
	# so that a future check returning RC_INVALID stops here instead of
	# leaking into repair.
	if [ "$RC" -eq "$RC_INVALID" ]; then
		exit $RC
	elif [ "$RC" -ne 0 ]; then
		RC=0
		recover_target_repo "$TARGET_DIR" || RC=$?
	fi
fi
[ "$RC" -eq "$RC_INVALID" ] && exit $RC

# A rebuild that failed just above skips the steps: its .git is gone or its
# fetch is failing, and either way the answer is the next rung or the exit,
# not the steps.
if [ "$RC" -eq 0 ]; then
	target_steps "$TARGET_DIR" || RC=$?
	# The rebuild rung takes damage, and failing fetches only with the
	# remote answering: a fetch can be failing over broken refs, which a
	# fresh .git repairs, but during an outage the rebuild would spend the
	# target's refs and reflog on a fetch that cannot succeed. Whether the
	# rung is still available is decided here, not by the guard inside: a
	# recover spent before the steps must not turn the code that got us
	# here into something else.
	TRY_REBUILD=
	[ "$RC" -eq "$RC_DAMAGE" ] && TRY_REBUILD=1
	[ "$RC" -eq "$RC_FETCH" ] && probe_remote "$TARGET_DIR" && TRY_REBUILD=1
	if [ "$TRY_REBUILD" ] && [ -z "$RECOVERED" ]; then
		RC=0
		recover_target_repo "$TARGET_DIR" || RC=$?
		[ "$RC" -eq 0 ] && { target_steps "$TARGET_DIR" || RC=$?; }
	fi
fi
if [ "$RC" -eq "$RC_DAMAGE" ]; then
	nuke_target_repo "$TARGET_DIR" || exit $?
	target_steps "$TARGET_DIR" || exit $?
	RC=0
fi

exit $RC
