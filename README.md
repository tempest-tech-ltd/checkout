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

# Recovery

A checkout dir left damaged by an interrupted run - killed runner, full disk -
is repaired without being thrown away. A dir that is no longer a usable repo,
a clean that cannot complete, or a checkout refused by leftovers all lead to
the same treatment: the checkout is retried with `--force`, and failing that
`.git` is recreated and refetched. The working tree is kept throughout, since
the checkout that follows reconciles every tracked path anyway; only paths
that conflict with the target ref are discarded. A reference dir is repaired
in place so its object store - which other checkouts borrow through
alternates - is never deleted.

# Scenarios

## Typical checkout
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    path: ${{ github.ref_name }}/src
```

## Checkout another branch keeping changes
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
