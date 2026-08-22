# install-nova-nix

Install a released [nova-nix](https://github.com/Novavero-AI/nova-nix) and put
it on `PATH`. No Haskell toolchain, nothing to build, nothing to configure.

```yaml
- uses: Novavero-AI/install-nova-nix@v1
- run: nova-nix eval --expr '1 + 2'
```

Evaluation stops at weak head normal form, so a scalar prints as itself while a
list or attrset prints its elements as thunks. `--strict` forces them:

```console
$ nova-nix eval --expr 'builtins.map (x: x * x) [ 1 2 3 4 5 ]'
[ <thunk> <thunk> <thunk> <thunk> <thunk> ]

$ nova-nix eval --strict --expr 'builtins.map (x: x * x) [ 1 2 3 4 5 ]'
[ 1 4 9 16 25 ]
```

Pin a version rather than tracking the newest release:

```yaml
- uses: Novavero-AI/install-nova-nix@v1
  with:
    version: 0.7.0.0
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `version` | `latest` | The version to install, with or without a leading `v`. `latest` tracks the most recent release. |

## Outputs

| Output | Description |
| --- | --- |
| `bin-dir` | The directory added to `PATH`, holding the executable. |
| `archive` | The release asset that was installed. |

## What lands on the runner

The release archive unpacks to `bin/` beside `share/` and `pkgs/`, and only
`bin/` goes on `PATH`. `share/` is how `<nix/*>` resolves without anything set,
so an installed nova-nix can build and not only evaluate. `pkgs/` carries the
Windows recipes, reachable at `${{ steps.<id>.outputs.bin-dir }}/../pkgs`:

```yaml
- uses: Novavero-AI/install-nova-nix@v1
  id: nova
- run: nova-nix build "${BIN}/../pkgs/windows/hello.nix"
  env:
    BIN: ${{ steps.nova.outputs.bin-dir }}
```

## Supported runners

| Runner | Archive |
| --- | --- |
| `ubuntu-latest` | `nova-nix-linux-x64.tar.gz` |
| `macos-latest` | `nova-nix-macos-arm64.tar.gz` |
| `windows-latest` | `nova-nix-windows-x64.zip` |

nova-nix publishes one archive per platform, built on the runner image GitHub
calls latest for it, so those three are what exists. Anything else fails with
the combination named rather than with a 404 that reads as a broken release.

## Verification

Every download is checked against the `SHA256SUMS` published with the release
before it is unpacked, so a truncated transfer or a substituted archive fails
the step instead of landing on `PATH`.

## Licence

Apache-2.0, the same as nova-nix. See [LICENSE](LICENSE).
