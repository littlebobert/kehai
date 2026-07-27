# Kehai

Mac utility for returning to interrupted work. See every current window, grouped intelligently by task instead of by app.

## Build and run

```bash
./Scripts/reset-build-run.sh
```

## Required permissions

- **Screen & System Audio Recording** — shows window thumbnails.
- **Accessibility** — opens the selected window.
- **Automation → Safari** *(optional)* — shows and activates individual Safari tabs.

An OpenAI API key is required to generate task groups.

## Release

After committing and pushing a clean working tree, publish the next patch release with:

```bash
./Scripts/deploy-github-release.sh --notes "Describe the user-facing change."
```

The command increments the patch version and build number, compiles the app and test bundle, signs and notarizes the app, creates the GitHub release, updates the Sparkle feed and landing-page changelog/download link, deploys the website, and verifies the public artifact. Pass an explicit version such as `0.2.0` before `--notes` when needed. Use `--dry-run` to validate release preflight without changing anything. Set `RUN_HOSTED_TESTS=1` to execute XCTest as well; it is opt-in because the Xcode 27 beta test host can hang before XCTest starts.

## Known limitations

- DRM, secure, and protected windows can appear blank.
- macOS can prevent a third-party utility from crossing some full-screen or Space boundaries perfectly.
