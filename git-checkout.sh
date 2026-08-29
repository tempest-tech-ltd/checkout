#!/bin/sh

# Off inside 'if ! f' and 'f || x': ref_steps and target_steps guard every
# command with '|| return 1'; clean is judged by its final git status.
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
	local retries=$FETCH_RETRIES
	local delay=$FETCH_DELAY
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

add_refspec() {
	local spec="$1"
	if ! git config --get-all remote.origin.fetch | grep -Fqx "$spec"; then
		git config --add remote.origin.fetch "$spec"
	fi
}

# 'git config', not 'git remote add': add fails on a remote section that has
# no url. --replace-all on the fetch list: a negative refspec someone left
# behind ('^refs/heads/main') survives --add and holds the checkout at an
# older commit with exit 0.
set_git_cfg() {
	git config --replace-all remote.origin.url "$URL"
	git config --replace-all remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
	add_refspec '+refs/pull/*/head:refs/remotes/origin/pull/*/head'
	add_refspec '+refs/pull/*/merge:refs/remotes/origin/pull/*/merge'
}

creds() {
	echo -n "x-access-token:$GITHUB_TOKEN" | base64 | tr -d '\n'
}

# The store is shared by every job on the runner, so its token lives in the
# environment for the fetch only; the target keeps one in its config (see
# init_target_repo).
grant_token_env() {
	if [ "$URL" = "https://${URL#https://}" ] && [ "$GITHUB_TOKEN" ]; then
		GIT_CONFIG_COUNT=1
		GIT_CONFIG_KEY_0=http.extraHeader
		GIT_CONFIG_VALUE_0="Authorization: basic `creds`"
		export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
	fi
}

drop_token_env() {
	GIT_CONFIG_COUNT=0
	export GIT_CONFIG_COUNT
	unset GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
}

is_fs_root() {
	case "$1" in
		"" | / | // | ?:[/\\] | ?:[/\\][/\\] ) return 0 ;;
	esac
	return 1
}

# A '..' in a path that does not exist yet resolves elsewhere once the dirs
# above it appear: 'base/keep/new/..' is 'base/keep', somebody else's.
prepare_dir() {
	is_fs_root "$1" && echo "Error: unsafe repository directory: '$1'" && exit 1
	if [ ! -d "$1" ]; then
		# Both separators: Win32 collapses '\..' the same way.
		case "$1" in
			.. | ../* | */.. | */../* | \
			..\\* | *\\.. | *\\..\\* | */..\\* | *\\../* )
				echo "Error: '..' is not allowed in a path that does not exist yet: '$1'" && exit 1 ;;
		esac
	fi
	mkdir -p "$1"
	DIR_ABS=`abs_path "$1"`
	is_fs_root "$DIR_ABS" && echo "Error: unsafe repository directory: '$1' resolves to '$DIR_ABS'" && exit 1
	return 0
}

# Neither dir may contain the other: a store inside a work tree is removed by
# clean as untracked, and a target inside the store is walked by the lock sweep.
check_disjoint() {
	[ "$REF_DIR" = "$TARGET_DIR" ] && echo "Error: reference and target dirs are the same: $REF_DIR" && exit 1
	case "$TARGET_DIR" in "$REF_DIR"/* ) echo "Error: target dir $TARGET_DIR is inside reference dir $REF_DIR" && exit 1 ;; esac
	case "$REF_DIR" in "$TARGET_DIR"/* ) echo "Error: reference dir $REF_DIR is inside target dir $TARGET_DIR" && exit 1 ;; esac
	return 0
}

# The stored url may lack the '.git' this script appends, and on git-bash git
# stores the windows spelling of a posix path - one directory, two strings.
same_repo() {
	SRA=${1%.git}
	SRB=${2%.git}
	[ "$SRA" = "$SRB" ] && return 0
	case "$SRA$SRB" in *://* ) return 1 ;; esac
	[ "$MSYSTEM" ] || return 1
	command -v cygpath >/dev/null 2>&1 || return 1
	SRA=`cygpath -m -- "$SRA" 2>/dev/null`
	[ "$SRA" ] && [ "$SRA" = "`cygpath -m -- "$SRB" 2>/dev/null`" ]
}

# Nothing here runs two gits over one repo, so any lock found is a dead job's.
clear_locks() {
	find "$1" -name '*.lock' -type f -delete 2>/dev/null || true
}

# Read from the file, not through git: the store may not open at all. Unset or
# unreadable counts as ours; of several values the last one is judged.
check_ref_identity() {
	GURL=`git config --file "$REF_DIR/config" --get remote.origin.url 2>/dev/null` || GURL=
	[ "$GURL" ] || return 0
	same_repo "$GURL" "$URL" && return 0
	echo "Error: $REF_DIR belongs to $GURL, not $URL" && exit 1
}

# 'init --bare' over a live store rewrites the files a full disk leaves torn
# and touches no object, so it runs every time rather than after a diagnosis.
ref_steps() {
	clear_locks .
	git init --bare || return 1
	set_git_cfg || return 1
	# A token an older version of this script left in the store.
	git config --unset-all http.extraHeader 2>/dev/null || true
	gitm -c gc.auto=0 fetch --prune --prune-tags --tags --force || return 1
	return 0
}

# Asked before a store is deleted: during an outage the whole fleet would
# otherwise delete its stores and fail to clone them back.
probe_remote() {
	git ls-remote --exit-code "$URL" HEAD >/dev/null 2>&1
}

ref_repo() {
	SAVED_PWD=$PWD
	REINIT=
	if [ -d "$REF_DIR/objects" ] || [ -d "$REF_DIR/refs" ]; then
		check_ref_identity
		[ "`git -C "$REF_DIR" rev-parse --is-bare-repository 2>/dev/null`" = true ] || REINIT=1
	elif [ "`find "$REF_DIR" -mindepth 1 -maxdepth 1`" ]; then
		echo "Error: not a repository store: $REF_DIR" && exit 1
	fi
	grant_token_env
	cd "$REF_DIR"
	if ! ref_steps; then
		cd "$SAVED_PWD"
		probe_remote || { echo "Error: $URL not answering; keeping $REF_DIR" && exit 1; }
		echo "SELF-HEAL: store reclone $REF_DIR"
		rm -rf "$REF_DIR"
		mkdir -p "$REF_DIR"
		cd "$REF_DIR"
		ref_steps || exit 1
	elif [ "$REINIT" ]; then
		echo "SELF-HEAL: store reinit $REF_DIR"
	fi
	drop_token_env
	cd "$SAVED_PWD"
}

# A checkout of another repository: its .git is not ours to recreate.
check_target_identity() {
	[ -f .git/config ] || return 0
	GURL=`git config --file .git/config --get remote.origin.url 2>/dev/null` || GURL=
	[ "$GURL" ] || return 0
	same_repo "$GURL" "$URL" && return 0
	echo "Error: $TARGET_DIR belongs to $GURL, not $URL" && exit 1
}

# Nothing in a target's .git is worth saving - HEAD, branches and index come
# back from origin and the store; the work tree is never touched.
init_target_repo() {
	if [ -d .git ] && git rev-parse --resolve-git-dir .git >/dev/null 2>&1 &&
		[ "`git config --get remote.origin.url 2>/dev/null`" ]; then
		:
	else
		# A dir with files but no .git is a repair, not a fresh clone.
		[ "`find . -mindepth 1 -maxdepth 1`" ] && echo "SELF-HEAL: target git-dir $TARGET_DIR"
		rm -rf .git
		REBUILT=1
	fi
	# A stale config.lock would stop init and the config writes below.
	clear_locks .git
	git init
	set_git_cfg
	# Rewritten every run: the file goes with the .git that held it, and a
	# store the caller moved is the caller's decision, not a mismatch.
	echo "$REF_DIR"/objects > .git/objects/info/alternates
	# Kept in the target's config so later steps can push, as actions/checkout
	# does with persist-credentials.
	if [ "$URL" = "https://${URL#https://}" ] && [ "$GITHUB_TOKEN" ]; then
		git config --replace-all http.extraHeader "Authorization: basic `creds`"
	fi
	return 0
}

clean() {
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

	LEFT=`git status --porcelain --ignored` || return 1
	[ "$LEFT" ] && echo Clean failed && return 1
	return 0
}

# Only origin says what a name means: 'git checkout X' would take a local
# branch left by an earlier run after X was deleted upstream.
resolve_ref() {
	if git show-ref --verify --quiet "refs/remotes/origin/$TARGET_REF"; then
		RESOLVED=refs/remotes/origin/$TARGET_REF
		return 0
	fi
	if git show-ref --verify --quiet "refs/tags/$TARGET_REF"; then
		RESOLVED=refs/tags/$TARGET_REF
		return 0
	fi
	# rev-parse resolves a ref before an object id, so an id is only looked up
	# for an all-hex name, where a leftover local branch is improbable.
	case "$TARGET_REF" in
		"" | *[!0-9a-fA-F]* ) ;;
		* ) RESOLVED=`git rev-parse --verify --quiet "$TARGET_REF^{commit}"` &&
			[ "$RESOLVED" ] && return 0 ;;
	esac
	echo "Error: target ref does not exist: $TARGET_REF" && exit 1
}

# Always --force: a plain checkout can return 0 with tracked files still
# modified. -B from origin/X, not from the commit id: that sets
# branch.X.remote/merge, which is what makes a bare 'git push' later work.
checkout() {
	case "$RESOLVED" in
		refs/remotes/origin/* )
			git checkout --force -B "$TARGET_REF" "$RESOLVED" || return 1 ;;
		* )
			git checkout --force "$RESOLVED" || return 1 ;;
	esac
	# A refspec lost along the way leaves the remote ref behind and the
	# checkout returns 0 on an older commit. Peeled: an annotated tag is an
	# object of its own.
	HAVE=`git rev-parse HEAD` || return 1
	WANT=`git rev-parse "$RESOLVED^{commit}"` || return 1
	[ "$HAVE" = "$WANT" ] && return 0
	echo "Error: HEAD is $HAVE, expected $WANT"
	return 1
}

target_steps() {
	gitm fetch --prune --prune-tags --tags --force --recurse-submodules=no || return 1
	# Before clean: a typo in 'ref:' must not cost the caller their build dir.
	[ "$TARGET_REF" ] && resolve_ref
	if [ "$CLEAN" ]; then
		clean || return 1
	fi
	[ "$TARGET_REF" ] && { checkout || return 1; }
	return 0
}

target_repo() {
	SAVED_PWD=$PWD
	cd "$TARGET_DIR"
	# A .git symlink resolves into another checkout, whose HEAD and index the
	# commands below would move; -d follows it. Only the link goes.
	[ -L .git ] && rm -f .git
	check_target_identity
	REBUILT=
	init_target_repo
	if ! target_steps; then
		# The one repeat: a target's .git is references into the store's
		# objects; after a store reclone they can point at nothing, and
		# fetch, clean and checkout fail against a healthy store - on this
		# run and on every next one.
		[ "$REBUILT" ] && exit 1
		rm -rf .git
		REBUILT=1
		init_target_repo
		target_steps || exit 1
	fi
	cd "$SAVED_PWD"
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

# Only the tests turn these down; a run in CI gets the defaults.
FETCH_RETRIES=5
FETCH_DELAY=2
case "$GIT_FETCH_RETRIES" in '' | *[!0-9]* ) ;; * ) FETCH_RETRIES=$GIT_FETCH_RETRIES ;; esac
case "$GIT_FETCH_DELAY" in '' | *[!0-9]* ) ;; * ) FETCH_DELAY=$GIT_FETCH_DELAY ;; esac

[ -z "$URL" ] && echo Error: repo not defined && usage
[ -z "$REF_DIR" ] && echo Error: reference dir required to clone && usage
[ "$TARGET_REF" ] && [ -z "$TARGET_DIR" ] && echo Error: --target-ref requires --target-dir && usage

prepare_dir "$REF_DIR"
REF_DIR=$DIR_ABS
if [ "$TARGET_DIR" ]; then
	prepare_dir "$TARGET_DIR"
	TARGET_DIR=$DIR_ABS
	check_disjoint
fi

ref_repo

[ "$TARGET_DIR" ] && target_repo

exit 0
