# checkout@v3
Fast and simple GitHub action to checkout large Git repos using --reference

It also saves space significantly.

Note: requires git version >= 2.35

# Usage
```yaml
- uses: tempest-tech-ltd/checkout@v3
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

    # Path to place the repository, relative to GITHUB_WORKSPACE or absolute
    # (an absolute path outside the workspace is supported)
    # Default:
    path: null

    # A branch, tag or SHA to checkout
    # Default (if path is not null):
    ref: ${{ github.ref_name }}

    # Whether to clean working directory or not
    # Default:
    clean: true
```

# What the action guarantees

When the step succeeds:

- `HEAD` is the commit the requested `ref` resolves to **on the remote**: a
  branch through `origin/<ref>`, a tag through `refs/tags/<ref>`, otherwise a
  commit id. A local branch of the same name is never used - a branch deleted
  upstream fails the step instead of being built from a leftover copy.
- Every tracked path matches that commit. The checkout is always forced, so
  modified tracked files are restored and an untracked file sitting on a
  tracked path is overwritten.
- With `clean: true` the working directory holds nothing else: untracked and
  ignored files, build output included, are removed. With `clean: false` they
  are left exactly as they were.
- The token stays in the checkout's `.git/config`, so the steps after this one
  can push (see below). It is never written into the common (reference) repo,
  which every job on the runner shares.

When the step fails the job is red and nothing about the directories is
promised. There is no third outcome: the action does not report success with a
tree that is not the ref.

`clean` is the only knob. Both directories are repaired in place when a run
finds them broken - a runner that ran out of disk mid-checkout leaves git dirs
that no `git` command can open, and the next run rebuilds what it has to
rather than waiting for someone to log in. The work tree is never deleted
wholesale, and the common repo only after the remote has answered.

# Scenarios

## Typical checkout
```yaml
- uses: tempest-tech-ltd/checkout@v3
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    path: ${{ github.ref_name }}/src
```

## Checkout another branch keeping changes
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

## Push commits from a later step
Nothing extra is needed. A branch checkout leaves the branch tracking
`origin`, and the token stays in the checkout's config, so a plain

```yaml
- shell: bash
  run: |
    git -C src commit -am 'update'
    git -C src push
```

works - as it does after `actions/checkout` with its default
`persist-credentials`. The token the push uses is the one passed to `token:`;
give the action a token that may write.

## Checkout multiple repos and Push commits
Should just work as expected.
