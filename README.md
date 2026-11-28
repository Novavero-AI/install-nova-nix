# install-nova-nix

[![Test](https://github.com/Novavero-AI/install-nova-nix/actions/workflows/test.yml/badge.svg)](https://github.com/Novavero-AI/install-nova-nix/actions/workflows/test.yml)
[![Version](https://img.shields.io/github/v/tag/Novavero-AI/install-nova-nix?label=version&color=purple)](https://github.com/Novavero-AI/install-nova-nix/tags)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Install [nova-nix](https://github.com/Novavero-AI/nova-nix) on a machine, or in
a GitHub Actions workflow. Both download a release archive, check it against
the release's published checksums, put it on `PATH` and set up the store. No
Haskell toolchain is needed.

For what to do with nova-nix once it is installed, see
[its README](https://github.com/Novavero-AI/nova-nix#readme).

## On a machine

Linux and macOS:

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/Novavero-AI/install-nova-nix/v1/install.sh | sh
```

Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/Novavero-AI/install-nova-nix/v1/install.ps1 | iex
```

Run it as yourself, not with `sudo`: it asks for your password when a step
needs root. Then open a new terminal:

```console
$ nova-nix eval --expr '1 + 2'
3
```

nova-nix is installed in `~/.nova-nix`, or `%LOCALAPPDATA%\Programs\nova-nix`
on Windows. Its `bin/` goes on `PATH` through `~/.profile`, the bash startup
files you have, `~/.zshenv` when zsh is installed and fish's `conf.d` when fish
is, or through your user `Path` on Windows. Ahead of it goes `~/.nix-profile/bin`,
or `%USERPROFILE%\.nix-profile\bin` on Windows, where nova-nix's default profile
keeps the programs of the packages added to it, so they come first on `PATH`.

### The store

The installer sets up the store where nova-nix looks for it, so no command
needs `--store`:

- **Linux**: `/nix`, created with `sudo` and owned by you.
- **macOS**: `/nix`, on a case-sensitive APFS volume of its own named
  `nova-nix Store`, created with `sudo` on the disk `/` is on.
  `/etc/synthetic.conf` makes the mount point, and a LaunchDaemon mounts the
  volume there at boot with the options `/etc/fstab` gives it, as upstream
  Nix's installer does. The volume is not encrypted, even when FileVault is
  on.
- **Windows**: `C:\nix`, created so that only you, SYSTEM and Administrators
  can change it. nova-nix makes symbolic links, which Windows allows only in
  Developer Mode (Settings, For developers) or an elevated shell, and the
  installer says so when neither is on.

Every run, install and uninstall alike, first checks that the store is yours.
On Linux and macOS, `/nix` and everything in its store must be yours and
writable by no one else, and `/nix` must not be a link. On Linux a `/nix` of
root's that holds nothing at all is given to you; on macOS, so is the root of
a store volume this installer recorded, when it is root's and holds only
entries macOS makes there itself, which are left as they are. On Windows, `C:\nix` and everything
in it must belong to you, SYSTEM or Administrators and grant no other account
a change, whether directly or inherited from `C:\`; read and execute for
Users is fine, and so is the right nova-nix gives its build accounts' local
group, `nixbld`, to create entries in `C:\nix\store` and nothing else, by an
entry on that directory alone. A store that is not, or whose owner cannot be read, is left
alone, and the installer stops before changing anything. A `C:\nix` that
nova-nix made itself still carries the drive root's grant of modify to every
signed-in user, so it is refused too: move it aside, and the installer makes
a new one.

Where upstream Nix already manages `/nix/store`, the installer leaves it alone,
and nova-nix needs a store of its own through `--store`.

### Versions, upgrades and removal

Arguments go after `sh -s --`, or after the script block on Windows:

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/Novavero-AI/install-nova-nix/v1/install.sh | sh -s -- --version 0.10.0.0
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Novavero-AI/install-nova-nix/v1/install.ps1))) -Version 0.10.0.0
```

| `install.sh` | `install.ps1` | Does |
| --- | --- | --- |
| `--version VERSION` | `-Version VERSION` | Installs this release rather than the latest. |
| `--from DIR` | `-From DIR` | Installs the archive in `DIR`, checked against `DIR`'s `SHA256SUMS`, rather than downloading it. |
| `--store-only` | `-StoreOnly` | Sets up the store and installs nothing. |
| `--uninstall` | `-Uninstall` | Removes nova-nix and the `PATH` entries the installer added. The store stays. |
| `--remove-store` | `-RemoveStore` | With uninstall, removes the store and what the installer set up for it. |

Run the installer again to upgrade: it replaces the install with the release
it names.

`--remove-store` removes the store only once the check above finds it yours,
and refuses a store, or a directory holding it, that is a link. On macOS it
deletes only the volume its own records name, never one it has no record of,
such as one with the same name on another disk.

## In GitHub Actions

```yaml
steps:
  - uses: Novavero-AI/install-nova-nix@v1
  - run: nova-nix eval --expr '1 + 2'
```

The action puts nova-nix's `bin/` on `PATH`, with the default profile's
`.nix-profile/bin` in the home ahead of it, as the installer does. It sets up
[the store](#the-store) as the installer does on a machine, with the same
checks, so a command needs `--store` only where upstream Nix manages
`/nix/store`. On Linux and macOS that needs `sudo` without a password,
as GitHub's hosted runners have, unless `/nix` is already yours.

### Inputs

| Name | Description | Required | Default |
| --- | --- | --- | --- |
| `version` | Version to install, with or without a leading `v` (for example `0.10.0.0`). `latest` installs the most recent release. | No | `latest` |

### Outputs

| Name | Description |
| --- | --- |
| `bin-dir` | Directory added to `PATH`, containing the `nova-nix` executable. |
| `archive` | Name of the release asset that was installed. |

### Pin a version

```yaml
- uses: Novavero-AI/install-nova-nix@v1
  with:
    version: 0.10.0.0
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
runner. The public cache holds the closure nova-nix's main branch last built,
so naming it downloads what it holds and builds only what it lacks.

```yaml
jobs:
  build:
    runs-on: windows-latest
    steps:
      - uses: Novavero-AI/install-nova-nix@v1
        id: nova
      - run: >-
          nova-nix build "$BIN/../pkgs/windows/hello.nix"
          --substituter https://cache.novavero.ai
          --trusted-key cache.novavero.ai-1:9gQ7tLWMM+2tdC9H5sKMJltDIPfD7X2GWlZe8Aa8hHQ=
        shell: bash
        env:
          BIN: ${{ steps.nova.outputs.bin-dir }}
```

### How it works

A composite action: the steps run directly in your job, on your runner, with no
Node bundle to build or audit. It resolves the platform, downloads the matching
archive and the release's `SHA256SUMS`, verifies the archive against it,
unpacks it under `RUNNER_TEMP`, and appends `bin/` to `GITHUB_PATH`, then the
profile's `bin/`, which a later line puts ahead on `PATH`. Then it
sets up the store with the installer at the same ref, `install.sh --store-only`,
or `install.ps1 -StoreOnly` on Windows.

## Platform support

| Platform | Runner | Archive |
| --- | --- | --- |
| Linux x64 | `ubuntu-latest` | `nova-nix-linux-x64.tar.gz` |
| macOS arm64 | `macos-latest` | `nova-nix-macos-arm64.tar.gz` |
| Windows x64 | `windows-latest` | `nova-nix-windows-x64.zip` |

nova-nix publishes one archive per platform, built on the runner image GitHub
calls latest for it, so those three are all that exist. On any other platform
the installers and the action fail with an error naming it, rather than with a
404 from the download. The exception is Windows on Arm, where `install.ps1`
installs the x64 archive, which Windows 11 runs under emulation; Windows 10 on
Arm cannot run it.

## What it installs

The archive unpacks to a single directory holding `bin/`, `share/`, `pkgs/` and
nova-nix's LICENSE, NOTICE and README.md, and only `bin/` goes on `PATH`.

- `bin/`: the `nova-nix` executable. The Windows build needs only the Windows
  system DLLs. The Linux build loads glibc 2.38 or newer, libm, zlib and GMP
  dynamically, and the macOS build, which needs macOS 26 or newer, loads only
  libraries macOS ships, from `/usr/lib` and `/System/Library/Frameworks`.
  This repository's tests run the executable on all three hosted runners.
- `share/`: the bundled `<nix/*>` search path, resolved relative to the
  executable, which is what lets an installed nova-nix build rather than only
  evaluate.
- `pkgs/`: the package recipes, beside `bin/`; in the action, that is
  `${{ steps.<id>.outputs.bin-dir }}/../pkgs`.

## Checksums

The archive is checked against its release's `SHA256SUMS` before anything is
unpacked, so a truncated or corrupted download, or an archive that does not
match its release's checksum, is refused before anything changes. The checksums
come from the same release as the archive, so this shows the download is
intact, not who published it. The installers read the latest release's version
once and download both files from that release. The action's `latest` can fail
when a release is published between its two downloads; pin `version` for a
reproducible install.

## License

[Apache-2.0](LICENSE). Copyright 2026 Novavero AI Inc. and contributors; see
[NOTICE](NOTICE).
