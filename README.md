# install-nova-nix

[![Test](https://github.com/Novavero-AI/install-nova-nix/actions/workflows/test.yml/badge.svg)](https://github.com/Novavero-AI/install-nova-nix/actions/workflows/test.yml)
[![Version](https://img.shields.io/github/v/tag/Novavero-AI/install-nova-nix?label=version&color=purple)](https://github.com/Novavero-AI/install-nova-nix/tags)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Install [nova-nix](https://github.com/Novavero-AI/nova-nix) in a GitHub Actions
workflow. The action downloads a release archive, checks it against the
release's published checksums, and adds it to `PATH`. No Haskell toolchain is
needed.

For what to do with nova-nix once it is installed, see
[its README](https://github.com/Novavero-AI/nova-nix#readme).

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
      - run: |
          nova-nix eval --strict --expr 'builtins.map (x: x * x) [ 1 2 3 ]'
        shell: bash
```

### Build a package

The archive ships the package recipes beside the executable, so a build needs
nothing checked out. The recipes target Windows, so the job runs on a Windows
runner:

```yaml
jobs:
  build:
    runs-on: windows-latest
    steps:
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
with the platform named, rather than as a download that happens to 404.

## What it installs

The archive unpacks to a single directory holding `bin/`, `share/` and
`pkgs/`, and only `bin/` goes on `PATH`.

- `bin/`: the `nova-nix` executable. The Windows build needs only the Windows
  system DLLs. The Linux build loads glibc, libm, zlib and GMP dynamically, and
  the macOS build loads system libraries from `/usr/lib`. This repository's
  tests run the executable on all three hosted runners.
- `share/`: the bundled `<nix/*>` search path, resolved relative to the
  executable, which is what lets an installed nova-nix build rather than only
  evaluate.
- `pkgs/`: the package recipes, reachable at
  `${{ steps.<id>.outputs.bin-dir }}/../pkgs`.

## How it works

A composite action: the steps run directly in your job, on your runner, with no
Node bundle to build or audit. It resolves the platform, downloads the matching
archive and the release's `SHA256SUMS`, verifies the archive against it,
unpacks it under `RUNNER_TEMP`, and appends `bin/` to `GITHUB_PATH`.

Verification happens before anything is unpacked, so a truncated or corrupted
download, or an archive that does not match its release's checksum, fails the
step before anything reaches `PATH`. The checksums come from the same release
as the archive, so this shows the download is intact, not who published it.

## License

[Apache-2.0](LICENSE). Copyright 2026 Novavero AI Inc. and contributors, see
[NOTICE](NOTICE).
