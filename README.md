# hew

hew builds and installs software from source.  Run `hew install PKGs...`.  The PKG tells hew where to get the source (i.e. `github:marler8997/msi`).

Install hew on Linux/macOS with:

```sh
sh -c "$(curl -fSL https://gethew.github.io/sh)"
```

Install hew on Windows:

```sh
powershell -c "irm https://gethew.github.io/ps1 | iex"
```

Those install commands download a small script which in turn downloads a prebuilt hew binary and executes `hew install github:hew-org/hew`.

# Package Format

```
PKG = github:OWNER/REPO[,VERSION]
    | gitlab:OWNER/REPO[,VERSION]
    | path:PATH

VERSION = (omitted)    # in this priority tries latest release, tag or commit on the default branch
        | rev=REVSPEC  # specific tag/commit
        | tip          # latest commit on default branch
```

### Examples:

```sh
hew install github:marler8997/msi
hew install github:marler8997/msi,rev=v1.0
hew install github:marler8997/msi,rev=a8033245765dc3ec94cfe0d6f4f9d7725700c5b9
hew install github:marler8997/msi,tip
```

# Why install from source?

**For users:** pre-built binaries target the lowest common denominator. Building from source lets the compiler optimize for your specific CPU, OS, and architecture.

**For developers:** your source code *is* your distribution. No release workflows, no storing pre-built assets, no wrangling a matrix of OS/arch combinations. Push your code and your users can install it.
