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

    # Retry a checkout refused because of leftovers from an interrupted run,
    # discarding conflicting local changes and untracked files
    # (other untracked content is kept)
    # Default:
    force: false
```

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

## Unattended CI checkout into a reused working tree
Self-heals after an interrupted previous run (killed runner, full disk)
without the cost of a full clean:
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    path: ${{ github.ref_name }}/src
    clean: false
    force: true
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
