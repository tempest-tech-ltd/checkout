# checkout@v3
Fast and simple GitHub action to checkout large Git repos using --reference

It also saves space significantly.

Note: requires git version >= 2.35

# Usage
```yaml
- uses: tempest-tech-ltd/checkout@v3
  with:
    # GitHub repository name (with owner) or direct HTTPS Git repository URL
    # (other transports are not supported; credentials in the url are refused)
    # Examples: tempest-tech-ltd/checkout, https://git.example.com/repo.git
    # Default:
    repository: ${{ github.repository }}

    # A token to fetch the repository. Typically, you would use GITHUB_TOKEN explicitly
    # Default:
    token: null

    # Common (reference) git repository path, relative to GITHUB_WORKSPACE or
    # absolute. An absolute path outside the workspace is supported.
    # Default:
    common-path: ${repository}.git

    # Where to place the repository, relative to GITHUB_WORKSPACE or absolute.
    # An absolute path outside the workspace is supported - on Windows the
    # default workspace can be too deep for a large checkout.
    # Default:
    path: null

    # A branch, tag, full ref (refs/tags/v1) or SHA to checkout. Pass a full
    # ref when a branch and a tag share a name; a short name resolves to the
    # branch.
    # Default: the ref the workflow runs on
    ref: null

    # Whether to clean working directory or not
    # Default:
    clean: true
```

# What a checkout guarantees

After a successful run, `HEAD`, the index and every tracked file match the
requested ref. Local modifications to tracked files are always discarded -
this is a build step, not an interactive `git checkout`.

`clean` decides what happens to everything else:

| | tracked content | unrelated untracked / ignored | untracked in the way of the ref |
| --- | --- | --- | --- |
| `clean: false` | reset to the ref | kept | removed |
| `clean: true` | reset to the ref | removed | removed |

So `clean: false` is what lets a reused checkout keep its build output and
caches; it is not a way to carry local edits across a run. The one exception
is the reclone rung of recovery (below): a checkout so damaged that only
delete-and-reclone helps loses its untracked content whatever `clean` says.

# Recovery

A checkout dir left damaged by an interrupted run - killed runner, full disk -
is repaired rather than thrown away, with nothing to opt into. A dir that is
no longer a usable repo, and a clean that cannot complete (a corrupt index,
for instance), both lead to the same treatment: `.git` is recreated and
refetched, then the checkout runs again. The working tree is kept throughout,
since the checkout reconciles every tracked path against freshly fetched
objects anyway.

When even that was not enough, the last rung is what a human would do: delete
the checkout and clone from nothing. It also heals what no repair above it
can - debris git itself is unable to delete, such as read-only files left
behind by a build. On this rung untracked content goes too, whatever `clean`
says: that is the price of the reclone, paid once, and only on a checkout
nothing gentler could fix.

The last rung is earned, never defaulted to. It runs once; only for a
directory whose identity was positively established - it came into the run as
a checkout of the requested repository (by its origin url, or by alternates
pointing into this run's reference store, which is also how a `.git` too
broken to open is recognized), or the run created it - so a data directory a
typo pointed the action at is never deleted wholesale (its contents are still
subject to `clean` and the checkout, like any target's); never for an invalid
invocation (a mistyped ref, a wrong repository); only when the reclone has
what it needs (`--target-ref` and a usable reference dir - checked before
anything is deleted); and only after the remote answered a probe, since
deleting a working tree cannot fix an outage.

A fetch that merely kept failing - a dying pack transfer, a proxy, a full
disk - never costs a working tree or a store's objects, and ends the run with
an exit code of its own (3): at this size a failing transfer is routine, and
no deletion fixes it. With the remote answering it may still buy the `.git`
rebuild, since broken refs are one way a fetch fails - local branches and
reflog do not survive a rebuild; during an outage not even that runs.

The delete itself is a rename: the old content moves aside to `<dir>.gone`,
the clone goes to the original path, and a clone that fails puts the old
content back. Disk usage briefly peaks at old plus new. When the old content
can be neither removed nor restored, it stays at `<dir>.gone` - named in a
warning - and the next run through this rung clears that leftover only after
it proves to be one: a leftover is a copy of this very repository and
identifies itself by its stored origin. Anything else found at that name is
refused and has to be moved away by hand.

Every rung that fires announces itself on one machine-greppable line -
`SELF-HEAL: <store|target> rung=<reinit|rebuild|reclone> dir=<path>` - so a
fleet's logs can be swept for every repair that ran; a healthy run prints
none. A green job that self-heals every night is a problem these lines make
visible.

A reference dir is repaired in place, keeping its objects - other checkouts
borrow them through alternates. Deleting the store and recloning is its own
last rung, held to a stricter test: its structure refused even the
reinitialization, or `git fsck --connectivity-only` implicates its objects (a
pack truncated by a killed fetch, say) - because there an in-place repair
preserves exactly what is broken. That fsck finds missing and truncated
objects, not silent bitrot inside intact-looking ones; a store broken that
way keeps failing with exit 3 and needs a human. The same rules hold: never
for a store that belongs to another repository or that never showed an
identity, and never while the remote does not answer. A checkout that
borrowed objects the new store no longer holds is healed by its own ladder
when it next runs - usually the `.git` rebuild is enough.

A ref that does not exist is treated as a caller mistake, not as damage - it
fails without recreating anything. So does a reference dir belonging to another
repository: repair does not rebind a store that other checkouts borrow from. A
target naming another repository is rebuilt instead: it lends its objects to
nobody, and all a rebuild costs there is a working tree the checkout replaces
anyway.
One narrow exception, for stores that predate this: if the config is damaged
past reading and nothing can be recovered from it - no origin url, no include
that might carry one - there is no identity left to protect, and the store is
accepted for the repository that was asked for. The exception requires the dir
to still carry a bare repository's skeleton: a non-empty directory that shows
neither an identity nor that shape was never a store of anything, and is
refused before its lock files, its `config` or its content are touched.

A git configuration that rewrites the repository url - `url.<base>.insteadOf`,
in the machine's config or the checkout's own - is refused rather than followed.
Otherwise the store would keep the name of one repository and the objects of
another, with every check still passing.

The target owns its `.git`: a directory of its own, not a symlink and not a
gitfile pointing into another checkout, and not a git dir shared with one. A
target that shares metadata is rebuilt with its own, and the checkout it
borrowed from is left alone.

Replacement refs are removed from the target. `refs/replace/*` substitutes one
object for another in everything git reads, so one left in a reused checkout
would hand a different tree to the build steps that run after this action, on
a checkout that verified as correct. The reference dir keeps its own: nothing
is checked out there, and refs are not shared through alternates.

No hook of the repository's runs, and `core.fsmonitor` is ignored, for every
git command a run makes. A `post-checkout` hook runs inside the checkout and
before the verification that follows it; `reference-transaction` runs inside
anything that writes a ref, which includes the fetch - either can change
tracked files on a run that then reports success. The rest of the local config
is left alone: filters and `.git/info/attributes` shape the content of the
working tree by design, which is what git-lfs is.

A target with linked work trees registered under its `.git` is used as it is
but never rebuilt: their administrative files live there and nowhere else, so
recreating it would leave each of them without a repository. Recovery also
needs a ref to check out, since nothing else puts the working tree back.

Tags are mirrored from the remote, so a tag deleted upstream is deleted here,
and a tag created locally in the checkout does not survive the next run.

Pull request refs are fetched into `refs/remotes/origin/pull/*`, so branch
names that overlap that namespace - `pull/<n>/head`, `pull/<n>/merge` - would
map onto the same remote-tracking ref as the pull request of that number, and
git refuses to fetch both. Such branch names are not supported.

`origin` belongs to the action: its fetch refspecs are rewritten on every run
and its url whenever the repo is created or repaired, so extra or hand-edited
values there do not survive.

The store is also kept from growing without bound. gc never runs in it -
pruning would delete objects that checkouts still borrow - but repacking is
safe: objects are only moved into packs, never deleted (`--keep-unreachable`).
A run that finds more than `GIT_STORE_LOOSE_LIMIT` (512) loose objects packs
them - and when the leftovers alone still exceed the limit (unreachable loose,
which only the full rewrite sweeps), it escalates to that rewrite in the same
run rather than paying the walk again on every run after. One that finds more
than `GIT_STORE_PACK_LIMIT` (64) packs rewrites them into one, which takes a
while on a large store - raise the limits if a separate maintenance job should
own this instead. A failed repack never fails the run.

A reference dir must not be updated by two runs at once. Lock files left behind
by an interrupted git are removed, which assumes the run owns that directory
for its duration.

# Scenarios

## Typical checkout
```yaml
- uses: tempest-tech-ltd/checkout@v3
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    path: ${{ github.ref_name }}/src
```

## Checkout another branch, preserving build artifacts
```yaml
- uses: tempest-tech-ltd/checkout@v3
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    path: abranch-src
    ref: abranch
    clean: false
```

## Fetch or update reference (common) git directory only
```yaml
- uses: tempest-tech-ltd/checkout@v3
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

## Fetch or update reference (common) git directory only of a public project
```yaml
- uses: tempest-tech-ltd/checkout@v3
  with:
    repository: chromium/chromium
```

## Checkout from a direct Git URL
```yaml
- uses: tempest-tech-ltd/checkout@v3
  with:
    repository: https://git.example.com/my-repo.git
    path: my-repo-src
```

## Checkout multiple repos
Should just work as expected. The token is used for fetching only and is not
left in any repository config, so pushing needs credentials of its own.
