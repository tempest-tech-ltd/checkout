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
	GURL=$(git config --get remote.origin.url)
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
	git remote add origin "$URL"
	set_git_cfg
	git fetch --prune --prune-tags --tags --force
	cd - > /dev/null
}

update_ref_repo() {
	[ -z "$REF_DIR" ] && echo Error: reference dir required to update && usage
	cd "$REF_DIR"
	guess_repo
	git -c gc.auto=0 fetch --prune --prune-tags --tags --force
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
	git fetch --prune --prune-tags --tags --force
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
	git fetch --prune --prune-tags --tags --force
	cd "$SAVPWD"
}

clean() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to clean && usage
	cd "$TARGET_DIR"
	if git status 2>&1 | grep -q 'No commits yet'; then
		cd - > /dev/null
		return
	fi
	git clean -dffx
	git reset --hard HEAD
	cat <<EOF
	Note: The next command may produce error and warning messages due to
	the nature of submodule deinitialization.
	This is expected behavior and _usually_ does not indicate a problem.
EOF
	git submodule deinit --force --all
	rm -fr .git/modules
	[ "$(git status --porcelain)" ] && echo Clean failed && exit 1
	cd - > /dev/null
}

checkout() {
	[ -z "$TARGET_DIR" ] && echo Error: target dir required to checkout && usage
	[ -z "$TARGET_REF" ] && echo Error: target ref required to checkout && usage
	cd "$TARGET_DIR"
	if [ "$(git branch --remotes --list origin/$TARGET_REF)" ]; then
		git checkout -B $TARGET_REF origin/$TARGET_REF
	else
		git checkout $TARGET_REF
	fi
	cd - > /dev/null
}


[ $# -eq 0 ] && usage

URL=
REF_DIR=
TARGET_DIR=
TARGET_REF=
CLEAN=
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
	[ "$CLEAN" ] && clean
else
	clone_target_repo
fi

[ "$TARGET_REF" ] && checkout

exit 0
