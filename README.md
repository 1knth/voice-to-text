# Whisper

A small, early macOS menu-bar dictation app written in Swift. It captures speech through a configurable keyboard shortcut, transcribes it locally with `whisper-cli`, and copies the result or attempts to paste it into the focused app. It is a personal prototype, not a finished or broadly tested app.

## Run it locally

### Requirements

- A Mac running macOS 13 or later, with Xcode Command Line Tools (including Swift and `xcrun`) and CMake. The Whisper engine and model are separate downloads; this repository does not include them, and inference runs locally without downloading anything.

There are no Swift package dependencies. Build the app with:

```sh
bash scripts/build-app.sh
open dist/Whisper.app
```

To run the core tests:

```sh
swift test --scratch-path .build
```

### Get `whisper-cli` and the English model

I use the upstream [whisper.cpp](https://github.com/ggml-org/whisper.cpp) project. Its documented CMake build produces `whisper-cli`, and its model download script provides the `tiny.en` model this app expects. On macOS, install Apple's Command Line Tools and CMake first (for example, install CMake from its official distribution or a package manager you trust), then run the upstream commands:

```sh
git clone https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp
sh ./models/download-ggml-model.sh tiny.en
cmake -B build
cmake --build build -j --config Release
```

The expected files are `whisper.cpp/build/bin/whisper-cli` and `whisper.cpp/models/ggml-tiny.en.bin`. Keep the checkout and build directory in place while using the app, or update the paths if you move them. See upstream's [build and model instructions](https://github.com/ggml-org/whisper.cpp#quick-start) for current details. Review the upstream source, build configuration, downloaded model provenance, and anything your package manager installs before building or running it; these commands fetch and build third-party code and model data. I have not independently tested this setup on other Macs.

### Configure local inference

The checked-in `Resources/ApprovedInference.json` is an unapproved template, not a working machine configuration. Before dictation can run, review the inference executable, model, and every native library/backend they use. Fill in the template's schema-1 fields with `approvedForLocalTesting: true`, the absolute `cliPath` and `modelPath`, and an `artifacts` entry for each reviewed executable/model/library containing its absolute `path` and SHA-256 `sha256`. Include dependency `aliases` (each link's `path` and resolved target in `resolvesTo`) and `backendSearchDirectories` where needed. For example, `shasum -a 256 /absolute/path/to/file` prints a file's hash; it does not establish that the file is safe. Inspect the built executable's linked libraries and backend files, and pin all required files before approving. Rebuild the app after editing the template so the manifest is copied into its bundle:

```sh
bash scripts/build-app.sh
```

In Settings, select those same executable and model paths. The app verifies the manifest and hashes before each inference; a missing approval, changed file, or unapproved backend blocks execution. Do not approve files you have not reviewed, and do not copy another machine's paths or approval blindly. This hash-pinning is not a sandbox or a complete security audit.

Grant Microphone permission to record and Accessibility permission for the global shortcut and paste behavior. Start in **Copy to clipboard** mode; automatic paste is best-effort and should only be tried in a disposable text field. The default shortcut is Option–D. The app does not press Enter.

Temporary audio and transcript files are stored in private per-user temporary job folders and removed after processing when possible. A crash can leave temporary files until a later cleanup; deletion is not secure erasure. The app is not self-contained: it relies on the separately configured inference files.

## What I've tested

I've only used this on my own Mac. On this machine, I verified the arm64 build with Swift 6.1.2 on macOS 15.7.7, and the core tests have passed. I have not tested it on another Mac, on Intel, or across other macOS versions. Passing core tests and building the app do not establish that live microphone capture, permissions, focus handling, the visual interface, or automatic paste work reliably for other people; those need interactive testing.

## Project status

This is an early prototype. Do not use automatic delivery in sensitive destinations without testing it yourself. See the source and tests for implementation details.
