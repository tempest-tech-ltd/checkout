#!/bin/sh

set -e

usage() {
	echo Usage: `basename $0` "[--repo REPO_URL] [--ref-dir DIR] [--target-dir DIR] [--target-ref GIT_REF] [--clean] [--force] [--debug]"
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

# Checkout that may retry with --force. A previous interrupted run can leave
# leftovers a plain checkout refuses to touch: partially written untracked
# files, or a worktree/index mismatch after a failed index write. --force
# discards only the conflicting paths; other untracked content is kept.
# Recovery of a broken repo implies --force for its first checkout: the
# leftovers there are not precious, a from-scratch clone would not have
# kept them at all.
gitc() {
	git checkout "$@" && return 0
	RC=$?
	[ -z "$FORCE" ] && [ -z "$RECOVERED" ] && exit $RC
	echo "Warning: checkout refused, retrying with --force (conflicting local changes will be discarded)"
	git checkout --force "$@"
}

# True if DIR itself is a usable git repo: a work tree or a bare repo with
# remote.origin.url set. Deliberately not plain 'rev-parse --git-dir': that
# would discover a repo in parent dirs and report a broken checkout as
# valid. Anything less is recovered by a fresh clone.
is_valid_repo() {
	if ! git -C "$1" rev-parse --resolve-git-dir .git >/dev/null 2>&1 &&
		! git -C "$1" rev-parse --resolve-git-dir . >/dev/null 2>&1; then
		return 1
	fi
	[ "$(git -C "$1" config --get remote.origin.url || true)" ]
}

add_refspec() {
	local spec="$1"
	if ! git config --get-all remote.origin.fetch | grep -Fqx "$spec"; then
		git config --add remote.origin.fetch "$spec"
	fi
}

set_git_cfg() {
	if [ "$URL" = "https://${URL#https://}" ] && [ "$GITHUB_TOKEN" ]; then
		CREDS=$(echo -n "x-access-token:$GITHUB_TOKEN" | base64 | tr -d '\n')
		git config http.extraHeader "Authorization: basic $CREDS"
	fi
	add_refspec '+refs/pull/*/head:refs/remotes/origin/pull/*/head'
	add_refspec '+refs/pull/*/merge:refs/remotes/origin/pull/*/merge'
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

clone_ref_repo() {
	[ -z "$URL" ] && echo Error: repo not defined && usage
	[ -z "$REF_DIR" ] && echo Error: reference dir required to clone && usage
	mkdir -p "$REF_DIR"
	cd "$REF_DIR"
	git init --bare
	git remote add origin "$URL" || git remote set-url origin "$URL"
	set_git_cfg
	gitm fetch --prune --prune-tags --tags --force
	cd - > /dev/null
}

update_ref_repo() {
	[ -z "$REF_DIR" ] && echo Error: reference dir required to update && usage
	cd "$REF_DIR"
	guess_repo
	gitm -c gc.auto=0 fetch --prune --prune-tags --tags --force
	cd - > /dev/null
}

clone_target_repo() {
	[ -z "$URL" ] && echo Error: repo not defined && usage
	[ -z "$REF_DIR" ] && echo Error: reference dir required to clone && usage
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to clone && usage
	ABS_REF_DIR=$(abs_path "$REF_DIR")
	mkdir -p "$TARGET_DIR"
	cd "$TARGET_DIR"
	git init
	git remote add origin "$URL"
	set_git_cfg
	echo "$ABS_REF_DIR"/objects > .git/objects/info/alternates
	gitm fetch --prune --prune-tags --tags --force
	cd - > /dev/null
}

update_target_repo() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to update && usage
	[ "$REF_DIR" ] && ABS_REF_DIR=$(abs_path "$REF_DIR")
	SAVPWD=$PWD
	cd "$TARGET_DIR"
	guess_repo
	if [ -s .git/objects/info/alternates ]; then
		GREF_DIR=$(dirname `cat .git/objects/info/alternates`)
		if [ "$ABS_REF_DIR" != "$GREF_DIR" ]; then
			[ "$REF_DIR" ] && echo Error: ref-dir mismatch $ABS_REF_DIR vs $GREF_DIR && exit 1
			REF_DIR=$GREF_DIR
			update_ref_repo
		fi
	fi
	gitm fetch --prune --prune-tags --tags --force --recurse-submodules=no
	cd "$SAVPWD"
}

clean() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to clean && usage
	cd "$TARGET_DIR"

	git merge --abort  >/dev/null 2>&1 || true
	git rebase --abort >/dev/null 2>&1 || true
	git cherry-pick --abort >/dev/null 2>&1 || true
	git revert --abort >/dev/null 2>&1 || true
	git am --abort >/dev/null 2>&1 || true
	git bisect reset >/dev/null 2>&1 || true

	if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
		git read-tree --empty
	fi
	git clean -dffx
	if git rev-parse --verify HEAD >/dev/null 2>&1; then
		git reset --hard HEAD
	fi

	git submodule foreach 'cd "$toplevel" && rm -fr -- "$sm_path"'
	cat <<EOF
	Note: The next command may produce error and warning messages due to
	the nature of submodule deinitialization.
	This is expected behavior and _usually_ does not indicate a problem.
EOF
	git submodule deinit --force --all
	rm -fr .git/modules

	[ "$(git status --porcelain --ignored)" ] && echo Clean failed && exit 1
	cd - > /dev/null
}

checkout() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to checkout && usage
	[ -z "$TARGET_REF" ] && echo Error: target ref required to checkout && usage
	cd "$TARGET_DIR"
	if [ "$(git branch --remotes --list origin/$TARGET_REF)" ]; then
		gitc -B $TARGET_REF origin/$TARGET_REF
	else
		gitc $TARGET_REF
	fi
	cd - > /dev/null
}


[ $# -eq 0 ] && usage

URL=
REF_DIR=
TARGET_DIR=
TARGET_REF=
CLEAN=
FORCE=
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
		--force)
			FORCE="force"
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

if [ -z "$REF_DIR" ]; then
	:
elif [ -d "$REF_DIR" ] && is_valid_repo "$REF_DIR"; then
	update_ref_repo
else
	[ -d "$REF_DIR" ] && echo "Warning: $REF_DIR is not a valid git repo, reinitializing it in place (existing objects are kept)"
	clone_ref_repo
fi

if [ -z "$TARGET_DIR" ]; then
	:
elif [ -d "$TARGET_DIR" ] && is_valid_repo "$TARGET_DIR"; then
	update_target_repo
	[ "$CLEAN" ] && clean
else
	if [ -d "$TARGET_DIR" ]; then
		echo "Warning: $TARGET_DIR is not a valid git repo, recloning in place (working tree files are kept and reconciled by the checkout)"
		rm -rf "$TARGET_DIR/.git"
		RECOVERED="recovered"
	fi
	clone_target_repo
	[ "$RECOVERED" ] && [ "$CLEAN" ] && clean
fi

if [ "$RECOVERED" ] && [ -z "$TARGET_REF" ] && [ -z "$CLEAN" ]; then
	echo "Warning: $TARGET_DIR was recovered but no --target-ref was given; its preserved files stay untracked until a checkout (--force) reconciles them"
fi

[ "$TARGET_REF" ] && checkout

exit 0
