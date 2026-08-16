#!/bin/sh

set -e

usage() {
	echo Usage: `basename $0` "[--repo REPO_URL] [--ref-dir DIR] [--target-dir DIR] [--target-ref GIT_REF] [--clean] [--debug]"
	exit 1
}

abs_path() {
	if [ "$MSYSTEM" ]; then
		cd "$1" && pwd -W
	else
		cd "$1" && pwd
	fi
}

gitm() {
	local retries=5
	local delay=2
	local count=0
	while [ $count -lt $retries ]; do
		if git "$@"; then
			return 0
		fi
		echo "Git command failed. Retrying in ${delay}s..."
		sleep $delay
		count=$((count + 1))
		delay=$((delay * 2))
	done
	return 1
}

# Validated apart: only a work tree can be checked out, and alternates must
# name the reference repo's object store. Not plain 'rev-parse --git-dir',
# which discovers a repo in a parent dir and calls a broken checkout valid.
has_origin_url() {
	[ "$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)" ]
}

is_valid_ref_repo() {
	git -C "$1" rev-parse --resolve-git-dir . >/dev/null 2>&1 || return 1
	[ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null)" = true ] || return 1
	has_origin_url "$1"
}

is_valid_target_repo() {
	git -C "$1" rev-parse --resolve-git-dir .git >/dev/null 2>&1 || return 1
	has_origin_url "$1"
}

# Stale *.lock files are what an interrupted git leaves behind, and every
# later fetch then fails on them. They belong to no live process here: the
# runner gives a checkout dir to one job at a time.
clear_stale_locks() {
	GIT_DIR_PATH=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
	find "$GIT_DIR_PATH" -name '*.lock' -type f -exec rm -f -- {} + 2>/dev/null || true
}

add_refspec() {
	local spec="$1"
	if ! git config --get-all remote.origin.fetch | grep -Fqx "$spec"; then
		git config --add remote.origin.fetch "$spec"
	fi
}

set_git_cfg() {
	# Suppressed before the token is even tested: the caller runs this
	# script with --debug, so an xtrace would print the token itself, and
	# masking a value derived from a secret is not something the runner can
	# be relied on to do.
	XTRACE=
	case $- in *x*) XTRACE=1; set +x ;; esac
	RC=0
	if [ "$URL" = "https://${URL#https://}" ] && [ "$GITHUB_TOKEN" ]; then
		CREDS=$(echo -n "x-access-token:$GITHUB_TOKEN" | base64 | tr -d '\n') || RC=1
		git config http.extraHeader "Authorization: basic $CREDS" || RC=1
		CREDS=
	else
		# Never leave a previous run's credential behind for the next one.
		git config --unset-all http.extraHeader 2>/dev/null || true
	fi
	[ "$XTRACE" ] && set -x
	[ "$RC" -eq 0 ] || return 1
	# The heads refspec is normally created by 'git remote add'. Add it here
	# too: repairing a repo whose remote section survived without its url
	# takes the set-url path, which creates no refspec at all, and the store
	# would then fetch pull refs and no branches.
	add_refspec '+refs/heads/*:refs/remotes/origin/*' || return 1
	add_refspec '+refs/pull/*/head:refs/remotes/origin/pull/*/head' || return 1
	add_refspec '+refs/pull/*/merge:refs/remotes/origin/pull/*/merge' || return 1
}

guess_repo() {
	GURL=$(git config --get remote.origin.url || true)
	[ -z "$GURL" ] && echo "Error: remote.origin.url is missing in $PWD" && exit 1
	if [ "$URL" != "$GURL" ]; then
		[ "$URL" ] && echo "Error: repo mismatch $URL vs $GURL" && exit 1
		URL=$GURL
	fi
	set_git_cfg
}

# Doubles as the in-place repair of a damaged reference dir: 'git init
# --bare' leaves the object store alone, and that store must never be
# deleted - other checkouts borrow from it through alternates. Steps are
# checked explicitly because set -e does not apply inside an AND-OR list.
clone_ref_repo() (
	[ -z "$URL" ] && echo Error: repo not defined && usage
	[ -z "$REF_DIR" ] && echo Error: reference dir required to clone && usage
	mkdir -p "$REF_DIR" || exit 1
	cd "$REF_DIR" || exit 1
	git init --bare || exit 1
	git remote add origin "$URL" || git remote set-url origin "$URL" || exit 1
	set_git_cfg || exit 1
	gitm fetch --prune --prune-tags --tags --force || exit 1
)

update_ref_repo() (
	[ -z "$REF_DIR" ] && echo Error: reference dir required to update && usage
	clear_stale_locks "$REF_DIR"
	cd "$REF_DIR" || exit 1
	guess_repo || exit 1
	gitm -c gc.auto=0 fetch --prune --prune-tags --tags --force || exit 1
)

clone_target_repo() (
	[ -z "$URL" ] && echo Error: repo not defined && usage
	[ -z "$REF_DIR" ] && echo Error: reference dir required to clone && usage
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to clone && usage
	ABS_REF_DIR=$(abs_path "$REF_DIR") || exit 1
	mkdir -p "$TARGET_DIR" || exit 1
	cd "$TARGET_DIR" || exit 1
	git init || exit 1
	git remote add origin "$URL" || git remote set-url origin "$URL" || exit 1
	set_git_cfg || exit 1
	REF_OBJECTS=$(git -C "$ABS_REF_DIR" rev-parse --git-path objects) || exit 1
	case "$REF_OBJECTS" in /*) ;; *) REF_OBJECTS=$ABS_REF_DIR/$REF_OBJECTS ;; esac
	echo "$REF_OBJECTS" > "$(git rev-parse --git-path objects/info/alternates)" || exit 1
	gitm fetch --prune --prune-tags --tags --force || exit 1
)

update_target_repo() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to update && usage
	[ "$REF_DIR" ] && ABS_REF_DIR=$(abs_path "$REF_DIR")
	clear_stale_locks "$TARGET_DIR"
	SAVPWD=$PWD
	cd "$TARGET_DIR" || return 1
	guess_repo
	if [ -s .git/objects/info/alternates ]; then
		GREF_DIR=$(dirname `cat .git/objects/info/alternates`)
		if [ "$ABS_REF_DIR" != "$GREF_DIR" ]; then
			[ "$REF_DIR" ] && echo Error: ref-dir mismatch $ABS_REF_DIR vs $GREF_DIR && exit 1
			REF_DIR=$GREF_DIR
			update_ref_repo
		fi
	fi
	gitm fetch --prune --prune-tags --tags --force --recurse-submodules=no || { cd "$SAVPWD"; return 1; }
	cd "$SAVPWD"
}

# Reports failure instead of aborting, so a repo damaged past cleaning can
# be recovered rather than wedged for good. A subshell, because an exit
# inside an ordinary function would end the script. Steps are best effort;
# the final status is the verdict.
clean() (
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to clean && usage
	cd "$TARGET_DIR" || exit 1

	git merge --abort  >/dev/null 2>&1 || true
	git rebase --abort >/dev/null 2>&1 || true
	git cherry-pick --abort >/dev/null 2>&1 || true
	git revert --abort >/dev/null 2>&1 || true
	git am --abort >/dev/null 2>&1 || true
	git bisect reset >/dev/null 2>&1 || true

	if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
		git read-tree --empty || exit 1
	fi
	git clean -dffx || exit 1
	if git rev-parse --verify HEAD >/dev/null 2>&1; then
		git reset --hard HEAD || exit 1
	fi

	git submodule foreach 'cd "$toplevel" && rm -fr -- "$sm_path"' || exit 1
	cat <<EOF
	Note: The next command may produce error and warning messages due to
	the nature of submodule deinitialization.
	This is expected behavior and _usually_ does not indicate a problem.
EOF
	git submodule deinit --force --all || true
	rm -fr -- .git/modules || exit 1

	STATUS=$(git status --porcelain --ignored) || exit 1
	[ "$STATUS" ] && echo Clean failed && exit 1
	exit 0
)

# Recreate .git and refetch, keeping the working tree: its untracked
# content is worth hours on a chromium-sized checkout, and the forced
# checkout reconciles every tracked path anyway. Runs once per invocation,
# so an unrecoverable dir fails instead of looping.
recover_target_repo() {
	# Resolve before deleting: the guard has to see the path the rm will act
	# on, not the string the caller wrote. '/tmp/..' and a symlink to / both
	# name the root while looking harmless.
	TARGET_ABS=$(cd "$TARGET_DIR" 2>/dev/null && pwd -P) || TARGET_ABS=
	case "$TARGET_ABS" in
		"" | / ) echo "Error: refusing to recover unsafe target dir: '$TARGET_DIR'" && return 1 ;;
	esac
	[ "$RECOVERED" ] && return 1
	RECOVERED="recovered"
	echo "Warning: recovering $TARGET_DIR - reinitializing its .git (working tree files are kept and reconciled by the checkout)"
	rm -rf -- "$TARGET_ABS/.git" || return 1
	clone_target_repo
}

# Always forced: a plain checkout can report success while leaving tracked
# files modified, and this action promises the requested ref. --force keeps
# untracked content that is not in the way, which is what makes clean:false
# worth having; wiping the rest is clean's job.
# An unknown ref is a caller mistake, not damage - exit 2 skips recovery.
checkout() (
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to checkout && usage
	[ -z "$TARGET_REF" ] && echo Error: target ref required to checkout && usage
	cd "$TARGET_DIR" || exit 1
	# Only the three shapes the action documents. A bare name must not fall
	# through to refs/heads/: a local branch outlives the remote one that
	# created it, and checking that out would quietly build a deleted branch.
	HEX=no
	case "$TARGET_REF" in
		"" | *[!0-9a-fA-F]* ) ;;
		* ) HEX=yes ;;
	esac
	if git show-ref --verify --quiet "refs/remotes/origin/$TARGET_REF"; then
		git checkout --force -B "$TARGET_REF" "refs/remotes/origin/$TARGET_REF"
	elif git show-ref --verify --quiet "refs/tags/$TARGET_REF"; then
		git checkout --force "refs/tags/$TARGET_REF"
	elif [ "$HEX" = yes ] && git rev-parse --verify --quiet "$TARGET_REF^{commit}" >/dev/null 2>&1; then
		git checkout --force "$TARGET_REF"
	else
		echo "Error: target ref does not exist: $TARGET_REF"
		exit 2
	fi
)


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

# Validate before anything can touch the filesystem: a target ref with no
# target dir used to reach the recovery path, where the rm expanded to the
# root of the filesystem.
if [ "$TARGET_REF" ] && [ -z "$TARGET_DIR" ]; then
	echo "Error: --target-ref requires --target-dir"
	usage
fi

# A failed update is treated as damage worth repairing once: local damage
# often surfaces only when git writes, well past any probe. If the network
# was the real cause, the retry fails too and the run stops.
if [ -z "$REF_DIR" ]; then
	:
elif [ -d "$REF_DIR" ] && is_valid_ref_repo "$REF_DIR"; then
	update_ref_repo || { echo "Warning: $REF_DIR could not be updated, reinitializing it in place (existing objects are kept)"; clone_ref_repo; }
else
	[ -d "$REF_DIR" ] && echo "Warning: $REF_DIR is not a valid bare git repo, reinitializing it in place (existing objects are kept)"
	clone_ref_repo
fi

if [ -z "$TARGET_DIR" ]; then
	:
elif [ ! -d "$TARGET_DIR" ]; then
	clone_target_repo
elif is_valid_target_repo "$TARGET_DIR"; then
	update_target_repo || recover_target_repo
else
	echo "Warning: $TARGET_DIR is not a valid git repo"
	recover_target_repo
fi

# Same rule for both: try, and if the repo turns out to be damaged past
# that step, recover once and retry. Recovery is spent at most once, so the
# failure then propagates instead of looping.
if [ "$TARGET_DIR" ] && [ "$CLEAN" ]; then
	clean || { recover_target_repo && clean; }
fi

if [ "$TARGET_REF" ]; then
	CO=0
	checkout || CO=$?
	if [ "$CO" -ne 0 ]; then
		if [ "$CO" -eq 2 ]; then
			exit 2
		fi
		recover_target_repo && checkout
	fi
fi

exit 0
