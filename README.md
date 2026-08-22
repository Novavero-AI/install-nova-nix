# install-nova-nix

[![Test](https://github.com/Novavero-AI/install-nova-nix/actions/workflows/test.yml/badge.svg)](https://github.com/Novavero-AI/install-nova-nix/actions/workflows/test.yml)

Install [nova-nix](https://github.com/Novavero-AI/nova-nix) in a GitHub Actions
workflow. Downloads a released archive, verifies it against the published
checksums, and adds it to `PATH`. No Haskell toolchain required.

For what to do with it once installed, see
[nova-nix's README](https://github.com/Novavero-AI/nova-nix#readme).

## Usage

```yaml
steps:
  - uses: Novavero-AI/install-nova-nix@v1
  - run: nova-nix eval --expr '1 + 2'
```

## Inputs

| Name | Description | Required | Default |
| --- | --- | --- | --- |
| `version` | Version to install, with or without a leading `v` (for example `0.7.0.0`). `latest` installs the most recent release. | No | `latest` |

## Outputs

| Name | Description |
| --- | --- |
| `bin-dir` | Directory added to `PATH`, containing the `nova-nix` executable. |
| `archive` | Name of the release asset that was installed. |

## Examples

### Pin a version

```yaml
- uses: Novavero-AI/install-nova-nix@v1
  with:
    version: 0.7.0.0
```

### Every platform

```yaml
jobs:
  evaluate:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: Novavero-AI/install-nova-nix@v1
      - run: nova-nix eval --strict --expr 'builtins.map (x: x * x) [ 1 2 3 ]'
        shell: bash
```

### Build a package

The archive ships the package recipes beside the executable, so a build needs
nothing checked out. They target Windows:

```yaml
- uses: Novavero-AI/install-nova-nix@v1
  id: nova
- run: nova-nix build "$BIN/../pkgs/windows/hello.nix"
  shell: bash
  env:
    BIN: ${{ steps.nova.outputs.bin-dir }}
```

## Platform support

| Runner | Archive |
| --- | --- |
| `ubuntu-latest` | `nova-nix-linux-x64.tar.gz` |
| `macos-latest` | `nova-nix-macos-arm64.tar.gz` |
| `windows-latest` | `nova-nix-windows-x64.zip` |

nova-nix publishes one archive per platform, built on the runner image GitHub
calls latest for it, so those three are what exists. Any other runner fails
with the platform named rather than as a download that happens to 404.

## What it installs

The archive unpacks to `bin/` beside `share/` and `pkgs/`, and only `bin/`
goes on `PATH`.

- `bin/` - the `nova-nix` executable, statically linked against everything but
  the Windows system libraries.
- `share/` - the bundled `<nix/*>` search path, resolved relative to the
  executable, which is what lets an installed nova-nix build rather than only
  evaluate.
- `pkgs/` - the package recipes, reachable at `${{ steps.<id>.outputs.bin-dir }}/../pkgs`.

## How it works

A composite action: the steps run directly in your job, on your runner, with no
Node bundle to build or audit. It resolves the platform, downloads the matching
archive and the release's `SHA256SUMS`, verifies the archive against it, unpacks
under `RUNNER_TEMP`, and appends `bin/` to `GITHUB_PATH`.

Verification happens before anything is unpacked, so a truncated transfer or a
substituted archive fails the step rather than landing on `PATH`.

## License

[Apache-2.0](LICENSE)
