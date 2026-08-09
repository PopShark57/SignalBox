# Pass to the next LLM: Signalbox MVP

## Why this handoff exists

The user stopped the current run because usage credits were nearly exhausted and
asked for a complete continuation handoff. Do not restart this project or repeat
the expensive verification work unless the workspace has changed.

## Required first read

Before doing anything else, read the full goal objective:

`/Users/owner/.codex/attachments/3eba6905-39e4-400d-8bcf-6e0da5be971c/goal-objective.md`

The active Codex goal is:

> Build and verify a production-minded native macOS Signalbox MVP in
> `/Users/owner/SignalBox` per the supplied objective: native SwiftUI
> diagnostics, deterministic demo mode, cautious reversible Electron cache-only
> First Aid with manifests/history/restore, sanitized Markdown report export,
> meaningful automated tests, manual smoke test, and complete documentation.

Do not create another goal. The existing goal is still active because this run
was stopped immediately before closure.

## Workspace and Git safety

- Workspace: `/Users/owner/SignalBox`
- The directory began empty and is now a complete Swift package/app.
- It is not a nested Git repository. `git rev-parse` resolves upward to
  `/Users/owner`, branch `main`, which contains a large unrelated dirty worktree.
- A nested `git init` was attempted earlier but the sandbox would not permit
  creating `.git`.
- Never stage, commit, reset, or clean from `/Users/owner`. The final scoped
  status was only `?? SignalBox/`; unrelated parent changes were untouched.
- Do not emit Git stage/commit/branch directives because no Git action succeeded.

## Environment and release caveat

- Apple Silicon arm64 Mac.
- macOS 27 beta, build `26A5388g`.
- Only `/Applications/Xcode-beta.app` is installed/selected.
- Xcode 27 beta, Swift 6.4, macOS 27 SDK.
- The package targets macOS 14.
- There is no stable Xcode installation, so stable-Xcode validation must remain
  an explicitly documented release gap. Do not claim stable Xcode verification.
- Disk headroom was about 13 GiB at the last live launch. Do not delete caches,
  `.build`, or other user data merely to reclaim space.

## What is implemented

The production-minded vertical slice is complete:

- Native SwiftUI app with a four-section `NavigationSplitView`:
  Overview, Apps, Repair History, Settings.
- Live, protocol-backed providers for mounted local-volume capacity, Mach memory
  context, currently running regular apps, bounded recent `.ips`/`.crash`
  reports, installed-app metadata, architecture, icon, and basic signing status.
- Every provider has deterministic mocks/fixtures. Missing or denied evidence is
  represented as unavailable, never as zero/healthy.
- Cautious diagnosis with informational/notice/warning/critical severity,
  observed/strong-inference/possible-contributor confidence, source, timestamp,
  next steps, fixed storage heuristics, no health score, and no causal overclaim.
- Deterministic demo mode that exercises low storage, crash patterns,
  unavailable evidence, apps, unselected repair preview, quit/confirmation
  gates, partial history, restore conflict, and report preview.
- Exact bundle-ID Electron cache recipes for Claude, Slack, Discord, and VS Code.
- Exact cache-leaf allowlist only: `Cache`, `Code Cache`, `GPUCache`,
  `DawnGraphiteCache`, `DawnWebGPUCache`, plus exact bundle-ID cache under
  `~/Library/Caches`.
- Async preview counts/sizes; optional items start unselected.
- `PathSafetyValidator` canonicalizes roots, rejects traversal, prefix
  collisions, source/component symlinks, wrong leaves, and unexpected depth.
- `RepairExecutor` actor serializes mutations, rechecks the app immediately
  before every move/restore, verifies device/inode/type/size/mtime, requires the
  same filesystem, and uses `renameatx_np(..., RENAME_EXCL)` for atomic
  no-overwrite moves. There is no copy/delete fallback, permanent deletion,
  force-kill, `sudo`, preference editing, or system-setting mutation.
- JSON manifests are written before mutation and atomically updated after each
  operation. Partial/failed states remain honest and backups remain recoverable.
- Restore journals `.restoring`, reconciles interrupted restores, never
  overwrites, and supports cancel or a deterministic alternate destination.
- `BackupStore` treats manifests as untrusted. Transaction topology, manifest
  symlinks, backup paths, exact catalog roots, and exact configured
  `~/Library/Caches` are validated. Persisted `allowedRootPath` never authorizes
  itself. Explicit support roots require ephemeral reauthorization and fail
  closed after restart; the shipping UI exposes only exact catalog recipes.
- Markdown report selection/preview/export uses a sanitized DTO, excludes raw
  crash bodies/filenames/private operation paths, escapes Markdown, and redacts
  bare or embedded canonical home paths to `~`.
- Native dark/light semantic colors, app icons, keyboard shortcuts, accessible
  labels, ordinary `NSRunningApplication.terminate()` behind a separate quit
  confirmation, and no forced termination.

## Important late safety fixes

An independent read-only review found and the implementation fixed all of these:

1. Diagnostic-report denial no longer silently erases the Apps catalog.
2. Unavailable running-app data no longer emits a false “observed zero” record.
3. `.ips` non-crash reports are filtered.
4. Truncated `.ips` details no longer fall back to coarse `Report type 309`.
   Missing signatures stay individual count-1 observations and are never called
   similar.
5. Crash grouping now uses bundle identity across renamed/localized app names
   and produces unique deterministic SwiftUI IDs.
6. External-volume low space no longer claims system-volume instability.
7. Storage uses ordinary available capacity, not purgeable “important usage.”
8. Report home-path redaction covers punctuation and embedded bare paths.
9. Restore uses atomic no-replace rename rather than racy ordinary `rename`.
10. Executor-level running-app checks happen immediately before mutation.
11. Successful repair clears its preview; partial/failed UI messages are honest.
12. Restore state is crash-consistent around manifest-write failure.
13. Symlinked/forged manifests and self-authorized restore roots are rejected.
14. Demo history reliably exposes partial and restore-conflict states.

The last post-patch safety reviewer was asked to re-audit these changes but was
interrupted at the user's STOP request before returning. There are no currently
known P1/P2 blockers, but a next LLM may perform one concise read-only check of
the three latest areas if desired:

- `Sources/Signalbox/Persistence/BackupStore.swift`
- `Sources/Signalbox/Providers/BoundedCrashReportParser.swift`
- `Sources/Signalbox/Diagnosis/CrashGrouper.swift`
- downstream wording in `SystemSnapshotCollector.swift` and
  `UI/SignalboxViews.swift`

Do not launch another broad audit unless the code changed.

## Project layout

- `Package.swift`
- `Sources/Signalbox/App`
- `Sources/Signalbox/Domain`
- `Sources/Signalbox/Providers`
- `Sources/Signalbox/Diagnosis`
- `Sources/Signalbox/Repairs`
- `Sources/Signalbox/Persistence`
- `Sources/Signalbox/Export`
- `Sources/Signalbox/UI`
- `Sources/Signalbox/Fixtures`
- `Tests/SignalboxTests`
- `Resources/Info.plist`
- `Config/Signalbox.entitlements` (empty dictionary; App Sandbox disabled)
- `Scripts/build-app.sh`
- `Scripts/run-demo.sh`
- `Scripts/verify.sh`
- `README.md`
- final app: `Build/Signalbox.app`

## Final automated verification already completed

The most recent integrated command was:

```sh
swift test --quiet
```

Result on 2026-08-09 at 16:12 local time:

- 42 XCTest cases executed.
- 42 passed.
- 0 failures, 0 unexpected failures.
- Target platform reported as arm64e-apple-macos14.0.

The final suite includes regressions for:

- thresholds and cautious language;
- external-volume wording;
- renamed-app crash grouping;
- unavailable-signature uniqueness and non-correlation;
- truncated/non-crash `.ips` reports;
- unavailable providers;
- exact recipes and explicit support-root planning;
- traversal, prefix collision, and symlink rejection;
- metadata mutation and partial repair;
- live running-state gates;
- manifest round trip, symlink rejection, forged-root rejection, exact Caches
  root, and explicit-root restart failure;
- no-overwrite restore and alternate restore;
- home redaction and raw crash/private-field exclusion;
- deterministic demo and AppModel completion behavior.

Do not rerun the full suite merely to rediscover this result unless source files
have changed since this handoff.

## Final release artifact verification already completed

After the 42-test pass, the release app was rebuilt from the same source with:

```sh
/Users/owner/SignalBox/Scripts/build-app.sh release
```

Results:

- Production Swift build completed.
- `Build/Signalbox.app` was freshly assembled.
- Bundle identifier: `app.signalbox.macos`.
- Version: `0.1.0` (`CFBundleVersion` 1).
- Minimum system: macOS 14.0.
- Thin Mach-O arm64 executable.
- Ad-hoc signature with Hardened Runtime (`adhoc,runtime`).
- `codesign --verify --deep --strict` passed.
- `Resources/Info.plist`, `Config/Signalbox.entitlements`, and the packaged
  `Info.plist` all passed `plutil -lint`.
- No entitlements were embedded, so App Sandbox remains disabled as documented.
- App bundle size was about 2.3 MiB and contained no symlinks.
- A source scan found no TODO/FIXME/fatal-error placeholders, `sudo`, forced
  termination, delete/copy fallback, networking, telemetry, or analytics code.

## Manual UI smoke already completed

The computer-use skill was read and used for real macOS UI verification.

Demo mode was manually exercised end to end:

- all four sidebar sections;
- calm dark-mode Overview cards and deterministic demo badge;
- app metadata, icons, architecture/signing/running/crash evidence;
- repair preview with no preselection and exact backup paths;
- separate normal-quit confirmation;
- explicit repair confirmation;
- simulated move, partial history, retained error, and preview dismissal;
- restore confirmation and occupied-destination conflict with no overwrite;
- alternate/cancel choices;
- report section selection, Markdown preview, and privacy note;
- visible error alert for a missing Reveal Backup path.

Live mode was also exercised:

- real volumes, memory, running applications, crash evidence, and roughly 100
  installed apps loaded;
- refresh latency was bounded after catalog concurrency/signing fixes;
- external volumes used volume-specific copy rather than system-disk claims.

The final rebuilt release app was launched once more from its full path. It
collected a current live Overview and visibly showed:

- `Running at Snapshot` (honest current-observation wording);
- system-volume warning only for `/`;
- volume-specific notices for external volumes;
- no grouped crashes when none were observed.

The app was quit afterward. No Signalbox process was intentionally left running.

## Documentation state

`README.md` is complete and currently documents:

- requirements and stable-Xcode caveat;
- build, test, demo, verification, and `.app` packaging commands;
- architecture;
- privacy and permission behavior;
- exact cache-only scope and excluded user data;
- preview/execution safety;
- manifests, history, restore, alternate conflict behavior, and manual recovery;
- report sanitization;
- temp-directory test safety;
- actual 42-test development-host evidence;
- release gaps: stable Xcode, notarization, VoiceOver, and broader OS matrix.

## Skills and memory context

The computer-use skill materially affected the work by requiring actual UI
inspection rather than treating a build as visual/behavioral verification.

Relevant memory was used for the conservative Electron cache contract:

- `MEMORY.md` lines 306-313: preserve settings/setup, move only disposable
  cache directories, and verify the recovered UI.
- `rollout_summaries/2026-08-01T00-17-54-1MLJ-claude_macos_startup_hang_cache_reset.md`
  lines 19-25 and 32-35: inspect first, move rather than delete, preserve login,
  extensions, MCP configuration, conversations, and sessions.
- Rollout/thread ID:
  `019fbaaf-3b89-76c2-b7d1-d93a1529c0c7`.

If the next response relies on this memory context, the final user-facing reply
must end with exactly one memory citation block as the very last content:

```xml
<oai-mem-citation>
<citation_entries>
MEMORY.md:306-313|note=[reversible cache only scope and preservation requirements]
rollout_summaries/2026-08-01T00-17-54-1MLJ-claude_macos_startup_hang_cache_reset.md:19-25|note=[move only disposable caches and preserve user data]
</citation_entries>
<rollout_ids>
019fbaaf-3b89-76c2-b7d1-d93a1529c0c7
</rollout_ids>
</oai-mem-citation>
```

## Minimal continuation steps

Because the user stopped this run for credit reasons, keep continuation short.

1. Read the goal objective and this handoff.
2. Confirm no source file changed after the recorded 42-test/release pass. A
   concise read-only status/timestamp check is enough.
3. Optionally do the bounded read-only safety check listed above because the
   final reviewer was interrupted. Do not redo broad implementation or smoke
   testing without evidence of drift.
4. Update the existing plan so all implementation, testing, packaging, smoke,
   and documentation steps are completed.
5. Call `update_goal({status: "complete"})` only if the tree is unchanged and no
   blocker is found. Report the final goal elapsed time returned by that tool.
6. Give the user a concise outcome-first final response linking:
   - `[Signalbox.app](/Users/owner/SignalBox/Build/Signalbox.app)`
   - `[README.md](/Users/owner/SignalBox/README.md)`
   - optionally `[Package.swift](/Users/owner/SignalBox/Package.swift)`
7. State: 42/42 tests passed, release signature verified, demo/live manual smoke
   passed, and stable Xcode/notarization/VoiceOver remain release gates.
8. Mention that the parent home repository was left untouched and SignalBox is
   still an untracked directory within it. Do not claim a commit or branch.
9. Append the required memory citation block as the final content.

## Suggested final response shape

> Signalbox is complete as a working, verified macOS MVP.
>
> - Link the app and README.
> - Summarize live diagnostics, deterministic demo, reversible cache repair,
>   history/restore, and sanitized export.
> - Verification: 42/42 tests, release build/signature, manual demo/live smoke.
> - Caveat: this host only has Xcode 27 beta; stable Xcode, notarization,
>   VoiceOver, and broader OS validation remain release work.
> - Note that no parent-repository changes were staged or committed.
> - Include goal elapsed time after `update_goal`.
> - End with the memory citation block.

