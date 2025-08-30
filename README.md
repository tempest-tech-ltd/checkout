# checkout@v2
Fast and simple GitHub action to checkout large Git repos using --reference

It also saves space significantly.

Note: requires git version >= 2.35

# Usage
```yaml
- uses: tempest-tech-ltd/checkout@v2
  with:
    # GitHub full repository name (with owner). For example, tempest-tech-ltd/checkout
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

## Checkout multiple repos and Push commits
Should just work as expected.
