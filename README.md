# checkout@v2
Fast and simple GitHub action to checkout large Git repos using --reference

It also saves space significantly.

Note: requires git version >= 2.35

# Usage
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    # GitHub repository name (with owner) or direct Git repository URL
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
caches; it is not a way to carry local edits across a run.

# Recovery

A checkout dir left damaged by an interrupted run - killed runner, full disk -
is repaired rather than thrown away, with nothing to opt into. A dir that is
no longer a usable repo, and a clean that cannot complete (a corrupt index,
for instance), both lead to the same treatment: `.git` is recreated and
refetched, then the checkout runs again. The working tree is kept throughout,
since the checkout reconciles every tracked path against freshly fetched
objects anyway.

A reference dir is repaired in place, never deleted: other checkouts borrow
objects from its store through alternates, and removing it would break every
one of them.

A ref that does not exist is treated as a caller mistake, not as damage - it
fails without recreating anything. So does a reference dir belonging to another
repository: repair never rebinds a store that other checkouts borrow from.

Because pull refs are fetched into `refs/remotes/origin/pull/*`, a branch
literally named `pull/<n>/merge` would collide with the pull request ref of the
same number and git would refuse the fetch. Such branch names are not supported.

A reference dir must not be updated by two runs at once. Lock files left behind
by an interrupted git are removed, which assumes the run owns that directory
for its duration.

# Scenarios

## Typical checkout
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    path: ${{ github.ref_name }}/src
```

## Checkout another branch, preserving build artifacts
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    path: abranch-src
    ref: abranch
    clean: false
```

## Fetch or update reference (common) git directory only
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

## Fetch or update reference (common) git directory only of a public project
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    repository: chromium/chromium
```

## Checkout from a direct Git URL
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    repository: https://git.example.com/my-repo.git
    path: my-repo-src
```

## Checkout multiple repos
Should just work as expected. The token is used for fetching only and is not
left in any repository config, so pushing needs credentials of its own.
