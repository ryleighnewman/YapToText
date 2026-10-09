# Security Policy

## Supported versions

Security fixes go into the latest release only. Update to it from the Mac App Store, or with
`brew upgrade --cask yaptotext` for the Homebrew copy.

| Version | Supported |
| ------- | --------- |
| 1.5.3   | Yes       |
| 1.5.2 and earlier | No |

## Reporting a vulnerability

Please report security issues privately, not in a public issue.

1. Open the [Security tab](https://github.com/ryleighnewman/YapToText/security) of this repository.
2. Choose **Report a vulnerability** and describe the issue, the version, your macOS version, and the steps to reproduce it.

If you cannot use GitHub, reach out through [ryleighnewman.com](https://ryleighnewman.com).

You can expect a first reply within 7 days. Confirmed issues are fixed in the next release, and
the report is credited in the release notes unless you would rather stay anonymous.

## Scope

YapToText runs in the App Sandbox and transcribes on device. It makes no network calls in normal
use; the only exception is a model download you start yourself from the AI Models page (see
[PRIVACY.md](../PRIVACY.md)). Reports that are most useful include anything that sends audio or text
off the Mac, inserts text somewhere it was not meant to go, loads a tampered model file, or
escapes the sandbox.
