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

# The url and the refspecs every fetch below relies on, written into whatever
# config is there. 'git config' rather than 'git remote add', which fails on a
# remote section that exists without a url - a half-written config's own state.
# The list of refspecs is ours the way the url is: --replace-all drops whatever
# else the key held, because a negative one left behind by hand ('^refs/heads/
# main') survives an --add, keeps the fetch from updating that branch, and the
# run then reports success over a checkout of an older commit.
set_git_cfg() {
	git config --replace-all remote.origin.url "$URL"
	git config --replace-all remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
	add_refspec '+refs/pull/*/head:refs/remotes/origin/pull/*/head'
	add_refspec '+refs/pull/*/merge:refs/remotes/origin/pull/*/merge'
}

creds() {
	echo -n "x-access-token:$GITHUB_TOKEN" | base64 | tr -d '\n'
}

# The store gets the token through the environment, for the length of the
# fetch: it is shared by every job on the agent, and a credential written into
# its config would outlive the run that owned it. The target keeps one in its
# config on purpose - see init_target_repo.
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

# A filesystem root, or nothing at all: never a repository of ours.
is_fs_root() {
	case "$1" in
		"" | / | // | ?:[/\\] | ?:[/\\][/\\] ) return 0 ;;
	esac
	return 1
}

# Turns the caller's path into the one the rest of the run uses, in DIR_ABS.
# A '..' in a path that does not exist yet names something else once the dirs
# above it appear: 'base/keep/new/..' is 'base/keep', which belongs to someone
# else. Paths outside the workspace stay allowed - on Windows the default
# workspace is too deep for a large checkout, so ours live elsewhere.
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

# Whether two spellings name one repository. The stored url may lack the
# '.git' this script appends, and git-bash hands git the windows spelling of a
# posix path and stores it that way, so a local path can disagree with itself.
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

# A lock left behind by a job the machine killed stops every later write.
# Nothing here runs two gits over one repo, so a lock found now is stale.
clear_locks() {
	find "$1" -name '*.lock' -type f -delete 2>/dev/null || true
}

# The url a store carries decides whether it is ours to repair. Read out of
# the file, not through the repo, which in this state may not open at all.
# Unset, unreadable or several values read as ours; only another repository,
# plainly stated, is refused - a typo in a workflow, which no repair can fix.
check_ref_identity() {
	GURL=`git config --file "$REF_DIR/config" --get remote.origin.url 2>/dev/null` || GURL=
	[ "$GURL" ] || return 0
	same_repo "$GURL" "$URL" && return 0
	echo "Error: $REF_DIR belongs to $GURL, not $URL" && exit 1
}

# Everything a store needs, applied to whatever is there. 'init --bare' over a
# live store rewrites exactly the files that go missing when a disk fills up
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

# Whether the remote answers at all. Asked before a store is deleted: doing
# that is pointless at the very moment nothing can be fetched back, and during
# an outage the whole fleet would delete its stores and fail to clone again.
probe_remote() {
	git ls-remote --exit-code "$URL" HEAD >/dev/null 2>&1
}

ref_repo() {
	SAVED_PWD=$PWD
	if [ -d "$REF_DIR/objects" ] || [ -d "$REF_DIR/refs" ]; then
		check_ref_identity
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
	fi
	drop_token_env
	cd "$SAVED_PWD"
}

# T holds a checkout of another repository: its .git is not ours to recreate,
# and the caller means a directory other than the one they named.
check_target_identity() {
	[ -f .git/config ] || return 0
	GURL=`git config --file .git/config --get remote.origin.url 2>/dev/null` || GURL=
	[ "$GURL" ] || return 0
	same_repo "$GURL" "$URL" && return 0
	echo "Error: $TARGET_DIR belongs to $GURL, not $URL" && exit 1
}

# A .git this script can use, or a new one. Nothing in a target's .git is
# worth saving: HEAD, the branches and the index all come back from origin and
# the store, while the work tree - the expensive part - is never touched.
init_target_repo() {
	if [ -d .git ] && git rev-parse --resolve-git-dir .git >/dev/null 2>&1 &&
		[ "`git config --get remote.origin.url 2>/dev/null`" ]; then
		:
	else
		[ -e .git ] && echo "SELF-HEAL: target git-dir $TARGET_DIR"
		rm -rf .git
		REBUILT=1
	fi
	# Before init and the config writes below, which a stale config.lock
	# would stop.
	clear_locks .git
	git init
	set_git_cfg
	# Rewritten every run: the file goes with the .git that held it, and a
	# store the caller moved is the caller's decision, not a mismatch.
	echo "$REF_DIR"/objects > .git/objects/info/alternates
	# Unlike the store, the target keeps the token in its config: the steps
	# after this action push with it, the way actions/checkout leaves its
	# credentials behind.
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

	# Asked for, not assumed: a status that cannot be taken is not a clean
	# tree, and this is what the caller was promised.
	LEFT=`git status --porcelain --ignored` || return 1
	[ "$LEFT" ] && echo Clean failed && return 1
	return 0
}

# Only origin decides what a name means. A local branch left behind by an
# earlier run outlives the remote branch it came from, and 'git checkout X'
# would build that one - a branch deleted upstream would keep shipping.
resolve_ref() {
	if git show-ref --verify --quiet "refs/remotes/origin/$TARGET_REF"; then
		RESOLVED=refs/remotes/origin/$TARGET_REF
		return 0
	fi
	if git show-ref --verify --quiet "refs/tags/$TARGET_REF"; then
		RESOLVED=refs/tags/$TARGET_REF
		return 0
	fi
	# rev-parse answers with a ref before an object id, and this script
	# leaves a local branch behind for every branch it builds - so an id is
	# only looked up for a ref that cannot be a name at all.
	case "$TARGET_REF" in
		"" | *[!0-9a-fA-F]* ) ;;
		* ) RESOLVED=`git rev-parse --verify --quiet "$TARGET_REF^{commit}"` &&
			[ "$RESOLVED" ] && return 0 ;;
	esac
	echo "Error: target ref does not exist: $TARGET_REF" && exit 1
}

# Always forced: a plain checkout can return 0 with tracked files still
# modified, and this action promises a tree that matches the ref. -B keeps the
# two side effects the workflows after it depend on - a local branch of that
# name, and branch.X.remote/merge, which is what makes a bare 'git push' work.
checkout() {
	case "$RESOLVED" in
		refs/remotes/origin/* )
			git checkout --force -B "$TARGET_REF" "$RESOLVED" || return 1 ;;
		* )
			git checkout --force "$RESOLVED" || return 1 ;;
	esac
	# A checkout that returned 0 has still gone wrong if HEAD is not the
	# commit asked for: a refspec lost along the way leaves the remote ref
	# behind and the build would quietly be an older one. Peeled the way
	# the checkout peels it - an annotated tag is an object of its own.
	HAVE=`git rev-parse HEAD` || return 1
	WANT=`git rev-parse "$RESOLVED^{commit}"` || return 1
	[ "$HAVE" = "$WANT" ] && return 0
	echo "Error: HEAD is $HAVE, expected $WANT"
	return 1
}

target_steps() {
	gitm fetch --prune --prune-tags --tags --force --recurse-submodules=no || return 1
	# Before clean: a typo in a workflow's 'ref:' must not cost the caller
	# their build directory.
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
	# A .git that is a file or a symlink keeps its metadata in another
	# checkout, whose HEAD and index every command below would move while
	# the files land here. Only the link itself goes, never what it names.
	if [ -L .git ] || { [ -e .git ] && [ ! -d .git ]; }; then
		rm -f .git
	fi
	check_target_identity
	REBUILT=
	init_target_repo
	if ! target_steps; then
		# The one repeat inside a run, and the trigger is the failure
		# itself, not what git said about it. A target's .git holds
		# references only - HEAD, branches, the index - and reads the
		# objects behind them from the store; once the store has been
		# recloned they can point at nothing, and fetch, clean and
		# checkout all fail against a store that is perfectly healthy.
		# Every later run would fail the same way: the slot stays dead.
		[ "$REBUILT" ] && exit 1
		echo "SELF-HEAL: target git-dir $TARGET_DIR"
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
