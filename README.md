# sochi

Build, run and edit Xcode projects without opening Xcode.

sochi drives Apple's own tools — `xcodebuild`, `devicectl`, and the templates, capability catalog and build
specifications inside your selected Xcode — rather than keeping its own copies, so it stays in step with whichever
Xcode you use. Every project edit is shown as a diff, written atomically, verified, and rolled back if anything
doesn't check out.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Chandram-Dutta/sochi/main/install.sh | bash
```

The script installs the latest release to `~/.sochi/bin` and adds it to your `PATH`. Set `SOCHI_VERSION=v0.1.0` to
pick a release, `SOCHI_INSTALL` to install elsewhere, or `SOCHI_NO_MODIFY_PATH=1` to leave your shell files alone.

Or with Homebrew, tapping this repository directly:

```sh
brew tap Chandram-Dutta/sochi https://github.com/Chandram-Dutta/sochi
brew install sochi            # latest release
brew install --HEAD sochi     # build from main
```

sochi needs macOS with Xcode 16 or later selected (`xcode-select -p`). Run `sochi doctor` to check your setup.

## Use

```sh
sochi new Weather --org com.example          # a new project from Xcode's App template
cd Weather && sochi run                      # build, install and launch on your connected iPhone

sochi add capability push-notifications      # capabilities from Apple's catalog (see: sochi capabilities --all)
sochi add target widget-extension Forecast   # targets from Xcode's own templates (see: sochi templates)
sochi entitlements set com.apple.developer.healthkit true

sochi migrate                                # convert groups to synchronized folders, verified by building
sochi migrate --move-files                   # also give virtual groups real folders
```

`sochi --help` lists every command; `sochi <command> -h` explains one, with examples.

## Develop

```sh
swift build
swift test
scripts/build-release.sh 0.1.0   # try a release build locally (universal binary in dist/)
```

The tests read data from the installed Xcode and compare sochi's output with projects Xcode 27 created itself
(`Fixtures/Golden`).

## Releasing

Releases are made and tracked on GitHub: draft a release with a tag such as `v0.1.0` and publish it. The
[release workflow](.github/workflows/release.yml) then builds the universal binary for that tag, attaches it and its
checksum to the release, and points the Homebrew formula at it. The install script and Homebrew always fetch from
GitHub Releases.

## License

Apache License 2.0. See [LICENSE](LICENSE).
