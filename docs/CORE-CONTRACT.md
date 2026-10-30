# IslandCore / Hook bridge contract (2026-10-30)

This document describes the current local code contract. `IslandCore` owns shared models, normalization, reduction, navigation identities and the Unix socket protocol. UI, provider installation and pet parsing stay in their respective modules. Provider event names and app names never replace task titles.

## Sources and permission handling

`ProviderID` contains `qoder`, `codex`, `claude`, `zcode`, `dsh`, `codebuddy`, `workbuddy` and `generic`.

| Source | Current permission / question behavior |
| --- | --- |
| Qoder CN / IDE | Observe lifecycle, tools and permission waits; return to Qoder for decisions. `HookOutput` never emits a Qoder allow or deny. |
| Codex | The helper correlates each transport request. The app requires transcript metadata proving that this exact session and turn use user review. Automatic or unverified review falls back immediately. Fully previewable simple Bash may allow once; supported complex requests may deny or return to source. |
| Claude Code | Correlated PermissionRequest hooks may allow fully previewable Bash / web search once, or deny. Other questions return to Claude; no transcript reading for this adapter. |
| ZCode | Simple Bash with a stable request identity may allow or deny. Source-side prompts that do not dispatch a Hook remain in ZCode. |
| DSH / CodeBuddy CN / WorkBuddy | Observe supported task/tool lifecycle events; questions and permissions stay in the source. |
| Generic JSON | Display normalized activity, without a general permission or question reply contract. |

The normalizer alone is not the final authorization boundary. In raw Codex events without a usable correlation ID, `PermissionRequest` becomes `permissionObserved`: metadata may update, but phase, unread state and current interactions are preserved. The native helper may first add a transport-bound ID; the app still checks the exact turn reviewer before exposing an actionable approval.

`HookOutput.response(for:event:)` emits permission JSON only for supported Codex / Claude / ZCode approval events, a non-expired request, an allowed response capability and a matching app reply. Failures never become allow or deny. No code in this bridge executes the displayed command.

## Models and identities

- `SourceApplicationID` identifies verified desktop, IDE and terminal hosts. Unknown origins remain explicit. `SessionIdentity.key` length-prefixes source, host, session ID and thread ID; Qoder, Claude and Buddy variants also include their origin identity. A title is never a key.
- `SessionPhase` contains `idle`, `running`, `waitingApproval`, `waitingQuestion`, `completed`, `failed` and `interrupted`.
- `IslandSession` carries source/origin, host, session/thread/turn IDs, title, project directory, detail, update time, unread state and optional approval/question. `hasPendingApproval`, `hasPendingQuestion` and `isVisibleOnIsland` derive live visibility.
- `ApprovalRequest` carries the request ID, tool, command, project directory, summary, optional preview label, independent `canApprove` / `canDeny` flags, creation time and expiry.
- `QuestionRequest` carries the request ID, prompt, options, `canAnswer`, expiry and optional `responseItemIDs` for multi-item asynchronous question completion. Current real Hook question adapters set `canAnswer` false.
- `NormalizedHookEvent` carries event/source/origin/session identity, optional thread/turn/interaction IDs, timestamp, kind and optional title/project/detail/approval/question. Subagent terminal hooks do not finish the main task.

`HookEventKind` contains `started`, `sessionResumed`, `activity`, `permissionObserved`, `permissionPrompted`, `approvalRequested`, `questionRequested`, `turnStopped`, `sessionEnded`, `completed`, `failed`, `interrupted`, `approvalResolved` and `questionResolved`.

## Reducer and UI attention

`HookNormalizer.normalize(rawJSON:provider:sourceApplication:)` normalizes an event. `SessionReducer.apply(_:)` rejects stale and duplicate events. Pending approvals are correlated by session and request ID; `pendingApprovalIDs(sessionKey:)` exposes queued identities, and `resolveApproval` affects only the matching request.

Stop is an ended turn awaiting review, not inferred success. SessionEnd ends lifecycle without inventing unread completion. `expireRequests(at:)` and `expireApproval` invalidate controls without reviving old state. `markRead` updates unread state. `dismissSession(sessionKey:force:)` can hide running work when explicitly forced, while preserving association for later activity; live interactive requests remain protected. Observation-only permission notices follow their provider dismissal policy.

`AttentionRevealTracker.ingest(_:)` returns `Announcement`, with `hasNewAnnouncement` and `attentionSessionIDs`. It tracks phase, unread and current request IDs; an unchanged snapshot does not announce again. The UI uses the attention set for an automatic focused reveal and retains the full task list for manual expansion.

## Wire protocol

- `JSONValue` preserves raw JSON. `BridgeEnvelope` contains version 1, unique transport `requestID`, provider, optional verified origin, raw JSON, operation (`event`, `ping`, `status`) and an optional deadline. `rawJSON` is a throwing getter.
- `BridgeReply` contains disposition (`acknowledged`, `allow`, `deny`, `fallback`, `status`), optional message and request ID. Provider-specific Hook JSON remains the helper's responsibility.
- `BridgePaths.defaultSocketPath` is under the current user's `Library/Application Support/LingChongDao/run/bridge.sock`. Directory permissions are 0700 and socket permissions 0600. Frames are newline-delimited JSON, limited to 1 MiB; the server limits active connections to 128 and approval waits to at most 110 seconds.
- `IslandSocketServer.start(handler:onConnectionClosed:)` receives asynchronous handlers. The UI marshals model state onto MainActor. Timeout, disconnect and stop expire the corresponding waiter; a late allow is discarded.
- `IslandSocketClient.send(_:timeout:)` is blocking and must run away from the UI main thread. Invalid paths, foreign ownership and unsafe existing endpoints are rejected. The endpoint is a same-user trust boundary, not authentication against other processes running under the same account.

## Helper and safe demonstrations

`lingchongdao-hook` reads raw Hook JSON from stdin. `--provider` accepts all eight provider IDs; `--socket PATH`, `--timeout SECONDS`, `--ping`, `--status`, `--send-fixture FILE` and `--diagnose-origin` support local integration and diagnosis. Standard output contains only Hook-compatible JSON; diagnostics use standard error. Errors print `{}` and return the source to its normal handling.

`--send-fixture` does not bypass production reviewer, identity or expiry checks. The raw approval examples intentionally contain no real transcript or active turn context, so they are not interactive Codex approval demos. Use the workbench's interaction preview for UI demonstrations, or isolated verification fixtures for transport/reviewer tests. Privacy and cleanup details are in [PRIVACY.md](../PRIVACY.md).
