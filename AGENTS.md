# Duet Agent Guide

## Project boundaries

Duet is a personal Apple Silicon macOS 15+ app for using ChatGPT and Claude in a compact native workspace. Read `PRODUCT.md` for product direction and `README.md` for user-facing installation and usage guidance.

- Keep the project independent of Xcode project files and Swift Package Manager.
- Target `arm64-apple-macos15.0`.
- Notarization, App Store distribution, and Intel Mac support are out of scope.
- Keep the user-facing app and bundle name as `Duet`. Preserve the existing internal bundle identifier so saved sessions and preferences survive renames.

## Structure and commands

- Keep Swift source in `Sources/`, bundle resources in `Resources/`, and tests and fixtures in `Tests/`.
- Build with `./build.sh`. It closes a running Duet instance, compiles using the local `swiftc` toolchain, assembles and ad-hoc signs `dist/Duet.app`, then launches the fresh build.
- Test with `./test.sh`.
- Before handing off a release, verify the app bundle metadata and ad-hoc signature, then smoke-test the built app when practical.

## App behavior

- Load ChatGPT at `https://www.chatgpt.com` and Claude at `https://claude.ai` in persistent WebKit website-data stores so sessions normally survive relaunches.
- Default to one active provider; split view is on demand. Release inactive web views in single-pane mode to reduce memory while retaining website session data.
- Quick Prompt is available globally with Control–Option–Space and from Tools → Quick Prompt. It sends to ChatGPT, Claude, or Both, always starts a fresh conversation for each selected provider, and brings the workspace forward for continued interaction.
- The shared native prompt drawer is text-only, collapsed by default, stays open until explicitly closed, and provides Send to Current and Send to Both.
- Sending fills each provider's composer, waits for its reactive send control, then invokes it. Show independent provider statuses and never auto-retry an ambiguous submission.
- Keep response viewing, history, attachments, and provider-specific features in the provider pages. Do not scrape or merge provider responses.
- Support provider-managed sign-in, passkeys, and 2FA. Open provider-created popup windows in the default browser rather than managing custom popup windows inside Duet. Never collect or store user credentials.
- Provide independent website-data resets for ChatGPT and Claude.
- Keep provider URLs, selectors, readiness checks, and injection logic behind provider-specific adapters so provider markup changes are isolated.
- Preserve correct split-view web-view ownership: a dismantled single-pane host must not remove a `WKWebView` that was moved into a replacement split-pane host.

## Verification focus

Maintain coverage for provider configuration, dispatch states, generated injection scripts, prompt escaping, local HTML fixtures, and split-pane host lifecycle. For behavior changes, manually validate provider login, session persistence, single/split transitions, prompt drawer behavior, Send to Current, Send to Both, and independent website-data resets when relevant. For Quick Prompt changes, also verify the global shortcut and Tools menu entry, fresh-conversation navigation for each destination, split-pane mounting before sending to Both, and bringing back a hidden or minimized workspace.
