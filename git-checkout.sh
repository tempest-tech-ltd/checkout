#!/bin/bash

set -e

usage() {
	echo Usage: `basename $0` "[--repo GITHUB_REPO] [--ref-dir DIR] [--target-dir DIR] [--target-ref GIT_REF] [--clean] [--debug]"
	exit 1
}

set_git_cfg() {
	if [[ $URL == https://* ]] && [[ $GITHUB_TOKEN ]]; then
		local CREDS=$(echo -n "x-access-token:$GITHUB_TOKEN" | base64)
		git config http.extraHeader "Authorization: basic $CREDS"
	fi
}

guess_repo() {
	local GURL=$(git config --get remote.origin.url)
	local GREPO=${GURL#git@github.com:}
	GREPO=${GREPO#https://github.com/}
	if [ "$REPO" != "$GREPO" ]; then
		[[ $REPO ]] && echo "Error: repo mismatch $REPO vs $GREPO ($URL vs $GURL)" && exit 1
		REPO=$GREPO
		URL=$GURL
	fi
	set_git_cfg
}

clone_ref_repo() {
	[ -z "$URL" ] && echo Error: repo not defined && usage
	[ -z "$REF_DIR" ] && echo Error: reference dir required to clone && usage
	mkdir -p "$REF_DIR"
	pushd "$REF_DIR"
	git init --bare
	git remote add origin "$URL"
	set_git_cfg
	git fetch --prune --prune-tags --tags
	popd > /dev/null
}

update_ref_repo() {
	[ -z "$REF_DIR" ] && echo Error: reference dir required to update && usage
	pushd "$REF_DIR"
	guess_repo
	git fetch --prune --prune-tags --tags
	popd > /dev/null
}

clone_target_repo() {
	[ -z "$URL" ] && echo Error: repo not defined && usage
	[ -z "$REF_DIR" ] && echo Error: reference dir required to clone && usage
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to clone && usage
	ABS_REF_DIR=$(realpath "$REF_DIR")
	mkdir -p "$TARGET_DIR"
	pushd "$TARGET_DIR"
	git init
	git remote add origin "$URL"
	set_git_cfg
	echo "$ABS_REF_DIR"/objects > .git/objects/info/alternates
	git fetch --prune --prune-tags --tags
	popd > /dev/null
}

update_target_repo() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to update && usage
	[[ $REF_DIR ]] && ABS_REF_DIR=$(realpath "$REF_DIR")
	pushd "$TARGET_DIR"
	guess_repo
	if [ -s .git/objects/info/alternates ]; then
		GREF_DIR=$(dirname `cat .git/objects/info/alternates`)
		if [ "$ABS_REF_DIR" != "$GREF_DIR" ]; then
			[[ $REF_DIR ]] && echo Error: ref-dir mismatch $ABS_REF_DIR vs $GREF_DIR && exit 1
			REF_DIR=$GREF_DIR
			update_ref_repo
		fi
	fi
	git fetch --prune --prune-tags --tags
	popd > /dev/null
}

clean() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to clean && usage
	pushd "$TARGET_DIR"
	git clean -dffx
	git reset --hard HEAD
	git submodule deinit --force --all
	[[ $(git status --porcelain) ]] && echo Clean failed && exit 1
	popd > /dev/null
}

checkout() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to checkout && usage
	[ -z "$TARGET_REF" ] && echo Error: target ref required to checkout && usage
	pushd "$TARGET_DIR"
	if [[ $(git branch --remotes --list origin/$TARGET_REF) ]]; then
		git checkout -B $TARGET_REF origin/$TARGET_REF
	else
		git checkout $TARGET_REF
	fi
	popd > /dev/null
}


[ $# -eq 0 ] && usage

REPO=
REF_DIR=
TARGET_DIR=
TARGET_REF=
CLEAN=
while [[ $# -gt 0 ]]; do
	case "$1" in
		--repo)
			[ -z "$2" ] && echo Error: --repo requires an argument && usage
			REPO=$2
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

if [[ $REPO ]]; then
	[[ ! $REPO == *.git ]] && REPO=$REPO.git
	if [[ $GITHUB_TOKEN ]]; then
		URL=https://github.com/$REPO
	else
		URL=git@github.com:$REPO
	fi
else

if [ -z "$REF_DIR" ]; then
	:
elif [ -d "$REF_DIR" ]; then
	update_ref_repo
else
	clone_ref_repo
fi

if [ -z "$TARGET_DIR" ]; then
	:
elif [ -d "$TARGET_DIR" ]; then
	update_target_repo
else
	clone_target_repo
fi

[[ $CLEAN ]] && clean

[[ $TARGET_REF ]] && checkout

exit 0
