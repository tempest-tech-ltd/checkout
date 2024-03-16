#!/bin/bash

set -e

CHROMIUM_ORIG_HTTPS_URL=https://chromium.googlesource.com/chromium/src.git
CHROMIUM_GITHUB_HTTPS_URL=https://github.com/chromium/chromium.git
CHROMIUM_GITHUB_SSH_URL=git@github.com:chromium/chromium.git
TEMPEST_HTTPS_URL=https://github.com/tempest-tech-ltd/Core.git
TEMPEST_SSH_URL=git@github.com:tempest-tech-ltd/Core.git

usage() {
	echo Usage: `basename $0` "[--project chromium|tempest] [--ref-dir DIR] [--target-dir DIR] [--target-ref GIT_REF] [--clean] [--debug]"
	exit 1
}

set_git_cfg() {
	if [ "$URL" == "$TEMPEST_HTTPS_URL" ] && [[ $GITHUB_TOKEN ]]; then
		local CREDS=$(echo -n "x-access-token:$GITHUB_TOKEN" | base64)
		git config http.extraHeader "Authorization: basic $CREDS"
	else
		git config --unset http.extraHeader
	fi
}

guess_project() {
	local GPROJECT=
	local GURL=$(git config --get remote.origin.url)
	if [ "$GURL" == "$CHROMIUM_ORIG_HTTPS_URL" ] || \
	   [ "$GURL" == "$CHROMIUM_GITHUB_HTTPS_URL" ] || \
	   [ "$GURL" == "$CHROMIUM_GITHUB_SSH_URL" ]; then
		GPROJECT=chromium
	elif [ "$GURL" == "$TEMPEST_HTTPS_URL" ] || \
	     [ "$GURL" == "$TEMPEST_SSH_URL" ]; then
		GPROJECT=tempest
	else
		echo Error: unknown project $GURL
		exit 1
	fi

	if [ -z "$PROJECT" ]; then
		PROJECT=$GPROJECT
	else
		[ "$PROJECT" != "$GPROJECT" ] && echo "Error: project mismatch $PROJECT vs $GPROJECT ($URL vs $GURL)" && exit 1
	fi

	URL=$GURL
	set_git_cfg
}

clone_ref_repo() {
	[ -z "$URL" ] && echo Error: project not defined && usage
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
	pushd "$REF_DIR"
	guess_project
	git fetch --prune --prune-tags --tags
	popd > /dev/null
}

clone_target_repo() {
	[ -z "$URL" ] && echo Error: project not defined && usage
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
	ABS_REF_DIR=
	[[ $REF_DIR ]] && ABS_REF_DIR=$(realpath "$REF_DIR")
	pushd "$TARGET_DIR"
	guess_project
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

PROJECT=
REF_DIR=
TARGET_DIR=
TARGET_REF=
CLEAN=
while [[ $# -gt 0 ]]; do
	case $1 in
		--project)
			[ -z "$2" ] && echo Error: --project requires an argument && usage
			PROJECT=$2
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

URL=
case "$PROJECT" in
	chromium)
		URL=$CHROMIUM_ORIG_HTTPS_URL
		;;
	tempest)
		if [[ $GITHUB_TOKEN ]]; then
			URL=$TEMPEST_HTTPS_URL
		else
			URL=$TEMPEST_SSH_URL
		fi
		;;
	"")
		;;
	*)
		usage
		;;
esac

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
