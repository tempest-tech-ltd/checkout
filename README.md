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

    # Common (reference) git repository path under GITHUB_WORKSPACE
    # Default:
    common-path: ${repository}.git

    # Relative path under GITHUB_WORKSPACE to place the repository
    # Default:
    path: null

    # A branch, tag or SHA to checkout
    # Default (if path is not null):
    ref: ${{ github.ref_name }}

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
fails without recreating anything.

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

## Checkout multiple repos and Push commits
Should just work as expected.
