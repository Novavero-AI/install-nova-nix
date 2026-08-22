# install-nova-nix

Install a released [nova-nix](https://github.com/Novavero-AI/nova-nix) and put
it on `PATH`. No Haskell toolchain, nothing to build, nothing to configure.

```yaml
steps:
  - uses: Novavero-AI/install-nova-nix@v1
  - run: nova-nix eval --expr '1 + 2'
```

Track the newest release, or pin one:

```yaml
  - uses: Novavero-AI/install-nova-nix@v1
    with:
      version: 0.7.0.0
```

## Runners

| Runner | Archive |
| --- | --- |
| `ubuntu-latest` | `nova-nix-linux-x64.tar.gz` |
| `macos-latest` | `nova-nix-macos-arm64.tar.gz` |
| `windows-latest` | `nova-nix-windows-x64.zip` |

nova-nix publishes one archive per platform, built on the runner image GitHub
calls latest for it, so those three are what exists. Any other combination
fails with the platform named, rather than as a download that happens to 404.

## Inputs and outputs

| Input | Default | |
| --- | --- | --- |
| `version` | `latest` | The version to install, with or without a leading `v`. |

| Output | |
| --- | --- |
| `bin-dir` | The directory added to `PATH`, holding the executable. |
| `archive` | The release asset that was installed. |

## What lands on the runner

The archive unpacks to `bin/` beside `share/` and `pkgs/`, and only `bin/`
goes on `PATH`.

`share/` is how the `<nix/*>` search path resolves with nothing configured,
which is the difference between an installed nova-nix that can build and one
that can only evaluate. `pkgs/` carries the package recipes, so the build
from nova-nix's own README runs against what this action installed. They
target Windows, so this one wants `windows-latest`:

```yaml
  - uses: Novavero-AI/install-nova-nix@v1
    id: nova
  - run: nova-nix build "$BIN/../pkgs/windows/hello.nix"
    shell: bash
    env:
      BIN: ${{ steps.nova.outputs.bin-dir }}
```

## Verification

Every download is checked against the `SHA256SUMS` published with the release
before anything is unpacked, so a truncated transfer or a substituted archive
fails the step instead of landing on `PATH`.

## Evaluating

Evaluation stops at weak head normal form. A scalar prints as itself, but a
list or attr set prints only as far as its elements have been forced, which is
not far. `--strict` forces the whole result.

```console
$ nova-nix eval --expr 'builtins.map (x: x * x) [ 1 2 3 4 5 ]'
[ <thunk> <thunk> <thunk> <thunk> <thunk> ]

$ nova-nix eval --strict --expr 'builtins.map (x: x * x) [ 1 2 3 4 5 ]'
[ 1 4 9 16 25 ]
```

## Licence

Apache-2.0, the same as nova-nix. See [LICENSE](LICENSE).
