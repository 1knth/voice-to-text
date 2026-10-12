# Whisper

A small, early macOS menu-bar dictation app written in Swift. It captures speech while I hold a keyboard shortcut, transcribes it locally with `whisper-cli`, and copies the result or attempts to paste it into the focused app. It is a personal prototype, not a finished or broadly tested product.

## Run it locally

### Requirements

- A Mac running macOS 13 or later, with Xcode Command Line Tools (including Swift and `xcrun`).
- A separately obtained `whisper-cli` executable, its required native libraries/backends, and a Whisper model. These are not included in this repository; inference runs locally and does not download them.

There are no Swift package dependencies. Build the app with:

```sh
bash scripts/build-app.sh
open dist/Whisper.app
```

To run the core tests:

```sh
swift test --scratch-path .build
```

### Configure local inference

The checked-in `Resources/ApprovedInference.json` is an unapproved template, not a working machine configuration. Before dictation can run, review the inference executable, model, and native libraries/backends you intend to use. Set their absolute paths and SHA-256 hashes, dependency aliases, and backend search directories in that manifest; then rebuild the app so the manifest is copied into its bundle. The app verifies the pinned files before each inference. Do not approve files you have not reviewed, and do not copy another machine's paths or approval blindly. This hash-pinning is not a sandbox or a complete security audit.

In the app, use Settings to select the same executable and model paths. Grant Microphone permission to record and Accessibility permission for the global shortcut and paste behavior. Start in **Copy to clipboard** mode; automatic paste is best-effort and should only be tried in a disposable text field. The default shortcut is Option–D. The app does not press Enter.

Temporary audio and transcript files are stored in private per-user temporary job folders and removed after processing when possible. A crash can leave temporary files until a later cleanup; deletion is not secure erasure. The app is not self-contained: it relies on the separately configured inference files.

## What I've tested

I've only used this on my own Mac. On this machine, I verified the arm64 build with Swift 6.1.2 on macOS 15.7.7, and the core tests have passed. I have not tested it on another Mac, on Intel, or across other macOS versions. Passing core tests and building the app do not establish that live microphone capture, permissions, focus handling, the visual interface, or automatic paste work reliably for other people; those need interactive testing.

## Project status

This is an early prototype. It has no installer, notarization, or bundled inference engine/model. Do not use automatic delivery in sensitive destinations without testing it yourself. See the source and tests for implementation details.
