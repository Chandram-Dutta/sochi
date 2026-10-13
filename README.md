# sochi

Build, run and edit Xcode projects without opening Xcode. sochi drives Apple's own tools (`xcodebuild`,
`devicectl`, Xcode's templates and capability catalog), so it stays in step with whichever Xcode you have selected.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Chandram-Dutta/sochi/main/install.sh | bash
```

or with Homebrew:

```sh
brew tap Chandram-Dutta/sochi https://github.com/Chandram-Dutta/sochi
brew install sochi            # or: brew install --HEAD sochi
```

Requires macOS with Xcode 16 or later selected (`xcode-select -p`).

## Use

```sh
sochi new Weather --org com.example          # a new project from Xcode's App template
cd Weather && sochi run                      # build, install and launch on your connected iPhone

sochi add capability push-notifications      # capabilities from Apple's catalog (sochi capabilities --all)
sochi add target widget-extension Forecast   # targets from Xcode's own templates (sochi templates)
sochi entitlements set com.apple.developer.healthkit true

sochi migrate                                # convert groups to synchronized folders (verified by building)
sochi migrate --move-files                   # also give virtual groups real folders
```

`sochi --help` and `sochi <command> -h` list everything. `sochi doctor` checks your setup.

## Develop

```sh
swift build && swift test
scripts/release.sh 0.1.0            # build, tag, update the Homebrew formula
scripts/release.sh 0.1.0 --publish  # …and push and create the GitHub release
```
