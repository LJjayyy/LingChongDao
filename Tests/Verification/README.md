# Standalone verification

Run `./scripts/verify.sh` or `swift run lingchongdao-verify` from the project root. This executable verifies the public core and connection APIs without XCTest, so it also works with the macOS Command Line Tools installation. It exits with status 1 if any check fails.

The checks cover the same behavior as the XCTest suites plus request replay, running-card dismissal, frame rejection, changed-helper and unowned-helper boundaries. Socket checks use random private temporary paths. Installation checks use isolated homes under `/private/tmp`, disable CLI version execution, and never edit the real Codex/Qoder configuration or trust state.

The XCTest suites remain available with a full Xcode toolchain. The standalone runner does not require `@testable` imports and can be built in release configuration.

The application and expired-request scripts compile `Tests/VerificationSupport/CodexReviewFixture.swift` alongside their checks. It writes only synthetic session/turn reviewer records to private temporary JSONL files and removes them after the run. These fixtures exercise Codex's normal reviewer check without reading real transcripts or weakening production approval rules. Qoder checks remain observation-only and resolve their notices through source progress.
