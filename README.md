# Signalbox

Signalbox is a native macOS diagnostic and First Aid utility built around a simple promise: show understandable evidence, label uncertainty honestly, and make only narrow, reversible changes after explicit confirmation.

The app has five sections:

- **Overview** — a timestamped snapshot of the host description, local-volume capacity, memory context, recent diagnostic reports grouped by family, what changed since the previous collection, patterns that recur across collections, running applications, and unavailable evidence sources.
- **History** — every collection Signalbox has recorded, a counted description of how system-volume capacity moved across them, a comparison between any two collections, and a CSV export.
- **Apps** — searchable application metadata, matching report evidence, and audited First Aid recipes.
- **Repair History** — manifests for completed or incomplete backup transactions, with per-item state and paths, conflict-safe restore, Finder reveal, and copyable manual-recovery steps.
- **Settings** — deterministic demo mode, snapshot-timeline controls, and a sanitized Markdown report preview/export/copy flow.

There is no health score, telemetry, account, cloud service, network requirement, malware scanner, generic cleaner, privileged helper, or permanent cleanup action.

## Diagnostic report families

`.ips` is a shared container: macOS writes crashes, hangs, resource-limit notices, and a long tail of analytics reports into the same format. Signalbox names the family before admitting a report, and **never merges families** — a hang is not evidence of a crash, and a resource-limit notice is a usage observation rather than a failure.

Classification is deliberately conservative and lives in one small table (`Providers/DiagnosticReportFamilyCatalog.swift`):

- Self-describing payload evidence outranks the numeric `bug_type`. A payload carrying `resourceException` is a resource-limit report; one carrying `exception` or `termination` is a crash.
- Otherwise a short allowlist of `bug_type` values is consulted. `309` is verified against real crash reports written by macOS; the rest are a reviewable allowlist.
- **A report matching no rule is discarded, never guessed at.**

Each family gets its own Overview card and its own report section, with its own count. Nothing is totalled across families.

## Snapshot timeline

Signalbox records a reduced summary of each live collection under `~/Library/Application Support/Signalbox/Timeline/snapshots.json` so it can answer the question a single snapshot cannot: *has this happened before?*

- **Recorded:** volume capacity, memory totals, grouped report signatures, the names of unavailable evidence sources, and finding counts by severity.
- **Never recorded:** which applications were open, report contents, file names, or free-form provider messages. The `SnapshotSummary` type enforces this — whole snapshots are never persisted.
- The archive is capped at 60 collections; the oldest fall off. Signalbox is a diagnostic tool, not a monitoring agent.
- Demo snapshots are never written, at both the call site and inside the store.
- An archive written by a newer Signalbox is reported and **left untouched**, never overwritten.
- **Settings → Forget Snapshot History** deletes only this file. Backups and repair manifests are unaffected.

Three things are derived from it:

- **Since Your Last Snapshot** — elapsed time, system-volume capacity change, change in reports visible in the collection window, and evidence sources that became unavailable or recovered. A capacity reading missing from either collection is reported as *not comparable*, never as a zero change.
- **Recurring Across Snapshots** — report patterns seen in more than one collection. Counts are **not summed across collections**, because each collection re-reads the same rolling window of report files; adding them would manufacture a large, false total. Signalbox reports how many separate collections saw the pattern and the largest single-collection count. Reports whose signature could not be read are never correlated at all.
- **System-volume capacity across collections** — see below.

## History

Everything above was derived from the archive; none of it showed the archive. **History** is the record itself: every collection Signalbox has made, newest first, with the capacity, grouped report counts, finding counts, and unavailable sources it stored for each.

It shows only what `SnapshotSummary` holds. There is no list of which applications were open on a given day, because that was never recorded — and a history screen is the most tempting place to start recording it.

### Capacity across collections

Signalbox counts how the system volume's available capacity *moved* between consecutive collections: how many intervals fell, rose, or were unchanged, plus the first, latest, lowest, and highest readings.

It is deliberately a count of movements, never a rate and never a projection. Collections are triggered by hand, so the gaps between them are arbitrary; "fell in four of five intervals" says nothing about how fast, and nothing about what happens next. A GB-per-day figure derived from unevenly spaced, user-triggered samples would be exactly the kind of confident-sounding number this application exists to avoid, and the sentence saying so travels with the numbers into the exported report.

An interval whose two collections did not both read the system volume is counted as **not comparable**, and never folded into "unchanged". The bar strip draws such a collection as an outline rather than as a zero-height bar, for the same reason.

### Comparing any two collections

Overview compares the two most recent collections. History compares any two, using the same analysis and the same wording. The pair is ordered by collection time rather than by the order they were clicked, so a comparison never reverses its sign because of click order.

### CSV export

**History → Export CSV** writes one row per recorded collection: collection time, system-volume capacity, memory totals, report counts, unavailable source names, and finding counts by severity. It carries the same privacy boundary as the Markdown report — no report signatures, no record of which applications were open, no report contents, no file names — and home-directory paths are still written as `~`.

Two details are load-bearing:

- A value that was never read is an **empty cell**, never `0`. A spreadsheet will happily plot a zero; it cannot plot "macOS refused access", and a run of false zeroes is invented evidence.
- Text cells are quoted per RFC 4180 *and* defused against spreadsheet formula evaluation: a leading `=`, `+`, `-`, `@`, tab, or carriage return is prefixed with an apostrophe. A volume name is chosen by whoever mounts the disk, so a volume called `=HYPERLINK(…)` must still open as a name. Numeric columns are written directly and never routed through that escaper, so a legitimate negative number cannot acquire a stray apostrophe.

## Host description

Every snapshot carries the first-line context that makes other evidence interpretable: macOS version and build, hardware model identifier, machine architecture, and physical memory. The architecture is read so that a translated process cannot mislabel an Apple silicon Mac as Intel.

Signalbox deliberately never reads the serial number, hardware UUID, host name, computer name, or user name. None of them help explain a crash, and all of them would make an exported report unshareable.

## Requirements

- Apple Silicon or Intel Mac running macOS 14 or later.
- A current stable Xcode and macOS SDK are recommended for release validation.
- No third-party runtime or package dependencies.

This checkout was developed on an Apple Silicon host whose only installed Xcode was **Xcode 27 beta** with Swift 6.4 and the macOS 27 SDK. The package targets macOS 14, but a stable-Xcode build could not be verified on that host and remains a release gate.

## Build, test, and run

From the repository root:

```sh
swift build
swift test
```

Run the complete local verification pass, including property-list validation,
tests, application-bundle assembly, and signature verification:

```sh
chmod +x Scripts/verify.sh
Scripts/verify.sh
```

Run directly in deterministic demo mode:

```sh
swift run Signalbox --demo
```

Create a signed local application bundle using Swift Package Manager and Apple's `codesign` tool:

```sh
chmod +x Scripts/build-app.sh Scripts/run-demo.sh
Scripts/build-app.sh release
open Build/Signalbox.app --args --demo
```

`Scripts/build-app.sh` creates `Build/Signalbox.app`, applies an ad-hoc Hardened Runtime signature, verifies it, and leaves App Sandbox disabled. A real distribution build should use the developer's signing identity and notarization workflow.

## Application icon

The icon is a railway signal head: a dark housing carrying three aspects, of which exactly one is lit. It names the application, and it matches what the application does — report one honest aspect from the evidence actually available, rather than a score summed across everything.

`Resources/AppIcon.icns` is committed, so an ordinary build needs nothing extra. It is generated from `Design/GenerateAppIcon.swift`, which draws the artwork with Core Graphics and no third-party dependency, so the icon is reproducible from source rather than an opaque binary. Sizes at or below 64px are drawn from a heavier variant — larger lenses, more contrast, no glow — because a soft glow becomes grey mud once a lamp is three pixels wide.

Regenerate it only when the design changes:

```sh
chmod +x Scripts/build-icon.sh
Scripts/build-icon.sh
```

`Scripts/verify.sh` fails if the packaged bundle is missing the `.icns` file named by `CFBundleIconFile`, because a bundle missing its icon falls back to the generic application icon silently.

## Architecture

Signalbox keeps collection, interpretation, repair execution, persistence, export, and presentation separate:

```text
Sources/Signalbox/
  App/          dependency composition and app state
  Domain/       evidence, findings, application, plan, manifest, and timeline types
  Providers/    live and deterministic mock system-data providers, report-family catalog
  Diagnosis/    thresholds, report grouping, timeline analysis, and cautious correlation language
  Repairs/      recipe planning, path safety, preview, execution, and restore
  Persistence/  atomic JSON manifest storage, repair history, and the snapshot timeline
  Export/       structured Markdown, timeline CSV, manual-recovery steps, and home-path redaction
  UI/           native SwiftUI screens, shared presentation primitives, and confirmation workflows
  Fixtures/     deterministic demo data
```

System providers are protocol-backed so live implementations can be replaced with deterministic mocks. Missing or permission-denied data is represented as unavailable evidence, not as an empty healthy result. The UI never moves files directly; all mutation is serialized through the repair executor.

Every writer in `Export/` takes structured domain models and returns text. None of them reads the file system, so the privacy boundary is a property of their inputs rather than a rule each one has to remember. Shared presentation primitives — the card, the byte and date formatting, the severity colours, and the delta description — live in `UI/SignalboxComponents.swift` so that two screens cannot describe the same value two different ways.

## Live evidence and permissions

Signalbox operates with ordinary user privileges and never requests administrator access. The MVP intentionally has App Sandbox disabled because it needs user-approved access to diagnostic reports and explicitly resolved application cache folders.

Live collection uses Apple frameworks and bounded local reads for:

- Available and total capacity on mounted local volumes.
- Current Mach memory statistics, presented as context rather than proof of exhaustion.
- Applications running at collection time.
- Recent accessible `.ips` and `.crash` reports, reduced to structured metadata and a recurring signature.
- Bundle version, architecture, and code-signing information when discoverable.

macOS privacy controls may prevent access to some diagnostic reports or application folders. Signalbox reports the affected evidence source and reason. If the user wants that evidence, they can grant access in **System Settings → Privacy & Security** and refresh; the app does not nag, bypass, or silently reinterpret a denial.

## Reversible Electron cache First Aid

The sole MVP repair family is an audited cache-only experiment for supported Electron-style applications. A recipe may propose only these disposable Application Support children:

- `Cache`
- `Code Cache`
- `GPUCache`
- `DawnGraphiteCache`
- `DawnWebGPUCache`

It may also propose the exact bundle-identifier folder under `~/Library/Caches`. Signalbox never guesses an Application Support path from a fuzzy application-name match. The shipping MVP offers only exact bundled recipes. Its planner can accept a folder chosen explicitly by a future integration, but such a path is never inferred from the app's display name.

The following are never included: preferences, cookies, Local Storage, IndexedDB, login data, extensions, application databases, saved sessions, Keychain data, user-created content, or the application bundle.

Before execution, Signalbox:

1. Shows why the recipe was suggested and calls it a safe experiment, not a guaranteed fix.
2. Lists every path, existence state, file count, approximate size, and exact backup location.
3. Leaves every operation unselected until the user opts in.
4. Requires explicit confirmation and verifies that the target app is closed.
5. Canonicalizes allowed roots, rejects traversal and symlinks, captures filesystem identity metadata, and revalidates it immediately before each move.

Execution creates a transaction under:

```text
~/Library/Application Support/Signalbox/Backups/<transaction UUID>/
```

Each same-volume move is a filesystem rename. Signalbox never falls back to copy-and-delete or permanent deletion. `manifest.json` records the original and backup paths, device/inode/size/modification metadata, counts, per-operation state, errors, target app/version, Signalbox version, and overall transaction state. Partial work is recorded honestly and already-moved items remain recoverable.

Manifest paths are treated as untrusted input when history is loaded. Signalbox
re-derives exact catalog roots from the target bundle identifier and requires the
configured `~/Library/Caches` root for bundle caches. Explicit support-root
authorization is intentionally session-only and must be re-established after
relaunch before such a manifest can be loaded.

## Restore and manual recovery

Restore also requires the target app to be closed. Signalbox never overwrites a cache that the application has recreated. If an original path exists, restore stops at a conflict and offers cancellation or an alternate restore location.

A conflict is detected before anything is moved, so declining it leaves the transaction exactly as it was. Signalbox does not downgrade a completed transaction to "restore partial", and does not append an error, merely because you opened the restore dialog and backed out. The conflict is a fact about the filesystem right now and is re-derived on every attempt.

Normal recovery:

1. Open **Repair History**.
2. Select the transaction and make sure the target application is closed.
3. Choose **Restore** and review any conflict before continuing.

Manual recovery remains possible because every transaction is a normal folder with a readable `manifest.json`. For each moved operation, confirm that the manifest's original path does not exist, then move the corresponding backup item to that exact original path. If either path is unclear or the destination exists, leave both untouched and use Signalbox's alternate-folder option. Backups are never expired automatically; their disk usage remains visible in Repair History.

Repair History shows that same information per item rather than only as a total. **Recorded operations** expands to every item in the transaction with its state, its original path, where its backup currently is, where it was restored to if that differed, and any recorded error — so a partial transaction can say *which* items are still in the backup folder, not just how many.

**Copy Recovery Steps** writes the procedure above as plain text with this transaction's own paths already filled in, which is otherwise a translation the reader has to perform while something is already broken. Three rules hold whatever the manifest says:

- Every step is a **move**. No step ever says to delete, clear, or empty anything, and a test enforces that no generated step contains such a word.
- An item is only offered as recoverable when the backup should still hold it. An interrupted restore (`restoring`) and a blocked one (`restoreConflict`) both count, because in each the item was last recorded in the backup; a failed or skipped operation is described as never having moved.
- Every move is conditional on the destination not existing. If the application has recreated the cache, the step says to stop and leave both copies alone — the same decision Signalbox's own restore makes.

The steps are derived from the manifest, not from reading the disk, and they say so.

## Report privacy

Markdown reports are generated from structured diagnostic models, not raw report bodies. The exporter:

- Replaces the current home-directory prefix with `~`.
- Includes only selected host, diagnostic, timeline, application, unavailable-source, and repair-history sections.
- Excludes unrelated filenames and sensitive report content.
- Excludes report signatures. The timeline's internal correlation key is built from a signature, so the exporter is handed a separate `ReportTimelineSection` value that does not contain one.
- Writes only after the user reviews the preview and chooses a destination.

**Copy to Clipboard** copies exactly the sanitized text shown in the preview; there is no second, richer representation that could leak more.

Signalbox does not transmit reports or any other data.

## Test safety

Automated filesystem tests use unique temporary directories. They do not inspect or modify the developer's real `~/Library` folders — including the real snapshot timeline, which is only ever exercised through an injected directory.

The suite covers storage thresholds, report grouping and language, report-family classification and discarding, mocks, recipe matching, root/traversal/symlink enforcement, metadata revalidation, manifest round trips, partial transactions, restore success, restore conflicts, declined conflicts leaving the manifest unchanged, timeline persistence/bounding/schema rejection, timeline delta and recurrence analysis, host-context collection and non-identification, and home-path redaction.

It also covers the History section's logic: comparing two chosen collections in either order, capacity movements counted per interval, an unread volume producing a *not comparable* interval rather than an *unchanged* one, CSV rows keeping unread values empty rather than zero, CSV cells surviving an attacker-chosen volume name as text rather than as a formula, no report signature reaching either exported file, the capacity trend exporting as counted observations with its caveat attached, and manual-recovery steps that never contain a deletion instruction.

`Scripts/verify.sh` additionally fails the build on any compiler warning, greps `Sources` for prohibited constructs (networking, privilege escalation, forced termination, permanent deletion), lints the packaged `Info.plist`, rejects a bundle containing a symbolic link, and confirms the bundle carries the icon its `Info.plist` names.

Before release, also smoke-test both live and `--demo` modes on a supported macOS installation with a stable Xcode toolchain, keyboard navigation, VoiceOver, light mode, and dark mode.

## Verification on the development host

On 9 August 2026, `Scripts/verify.sh` passed end to end on Xcode 27 beta
(Swift 6.4, macOS 27 SDK, target arm64e-apple-macos14.0): a warning-free build,
**72 tests with no failures**, no prohibited constructs, a release
`Signalbox.app` assembled for Apple Silicon and ad-hoc signed with Hardened
Runtime, an accepted strict signature check, a linted packaged `Info.plist`, and
no symbolic links in the bundle. The signed release bundle was launched in
`--demo` mode, stayed running, and quit cleanly.

### Not yet verified: the History, CSV, and recovery-steps work

That result describes the tree as it stood on 9 August 2026. The History
section, the capacity-trend analysis, the timeline CSV export, the per-item
repair-history detail, and the manual-recovery steps were written afterwards in
an environment with **no macOS toolchain**, so they have not been compiled, and
their tests have not been run. The recorded test count therefore does not
describe them.

`Scripts/verify.sh` on a macOS host is the gate for this work — a warning-free
build first, then the suite — followed by the usual `--demo` and live
smoke-tests. Treat the new code as unverified until that has happened; the
claims in this README about how it behaves are claims about what the code says,
not about an observed run.

### Defects found and fixed in this pass

The tree was also put through an adversarial review across six dimensions
(repair safety, diagnosis honesty, export privacy, concurrency, UI state, and
provider parsing), with every candidate finding independently re-verified before
being accepted. These were confirmed and fixed:

1. **The test target did not compile.** `CrashGroup` had gained an
   `applicationIdentity` parameter that `ReportExporterTests` was never updated
   for, so `swift test` failed to build and the previously recorded 42-test
   result no longer described the tree.
2. **"Restore to Alternate" silently did nothing.** `.alert(item:)` writes nil
   back through its binding while dismissing, before the enqueued `Task` runs,
   so the handler's `guard restoreConflict != nil` always failed. The conflict
   is now passed by value.
3. **A declined restore conflict mutated the manifest.** Detecting a conflict
   persisted `.restorePartial` and appended an error *before* the user was
   asked, so cancelling downgraded a completed transaction and each reopened
   dialog grew the error list. Nothing had been moved. The conflict is now
   reported without being recorded.
4. **A fully restored `.partial` transaction could never reach `.restored`.**
   The final state counted operations that failed during the original *repair*
   — which were never moved and have no backup — so the user was told "some
   items could not be restored" about an already-empty backup directory.
5. **Markdown code spans could be escaped from.** A backslash does not escape a
   backtick inside a CommonMark code span, so a mounted volume named
   ``Setup`<img src=x onerror=…>`` closed the span early, truncated the path
   that was supposed to be the evidence, and put live HTML into a report meant
   to be pasted elsewhere. Code spans are now delimited by a longer backtick run.
6. **A slow refresh could overwrite a newer one.** Two `@Published` writes in
   `refresh()` followed `await`s without re-checking the refresh generation, so
   a superseded live refresh could publish real backup manifests into an
   interface already showing the Demo Data badge — and route their Restore
   button to the demo client.
7. **An interrupted restore was never reconciled at history load**, despite the
   executor's own comments promising it, leaving an item counted as occupying
   backup space until the user happened to start another restore.
8. **Reconciliation mislabelled a successful restore as failed.** It demanded
   full metadata equality, but a restored cache's size and modification time
   change the moment the app reopens it. It now compares device and inode, which
   a rename preserves.
9. **One invalid byte discarded an entire legacy `.crash` report** while the
   provider still reported success — incomplete evidence presented as complete.
   Decoding is now lenient, and the replacement characters are sanitized away.
10. **A permission-denied report open was not recognized.** `FileHandle` reports
    it as Cocoa error 513 with POSIX `EACCES` only as an underlying error, so an
    unreadable report was skipped as if it did not exist instead of being
    escalated to unavailable evidence.
11. **Switching demo mode left the previous mode's data on screen** during the
    reload, and the report exporter reported "no sections were selected" when
    the snapshot had in fact been selected but not yet collected.

Every one of these has a regression test naming the false claim it used to make.

### Known limitations

- `LiveBundleInspector` uses `Bundle(url:)`, whose `CFBundle` instances are
  cached process-wide. An application updated while Signalbox is running keeps
  reporting its previous name and version until Signalbox is relaunched.
  Refreshing does not clear it.
- The hang and resource-limit `bug_type` values are a conservative allowlist,
  not an exhaustive one. Only `309` (crash) is verified against reports written
  by macOS on this host. An unrecognized family is discarded, so the failure
  mode is a missing report rather than a mislabelled one.

### Caveats, unchanged

This is development-host evidence, not distribution certification. Stable-Xcode
validation, notarization, VoiceOver, and a broader macOS compatibility matrix
remain release gates.

The interface was **not** visually re-verified in this pass: screen recording is
not permitted for the shell that ran the build, so no screenshot could be taken.
The launch checks above are process-level only — they establish that the signed
release bundle starts, completes a real collection, and quits cleanly in both
`--demo` and live modes, not that any particular view renders correctly. The new
Overview cards, the Apps search field, and the Settings timeline controls have
been exercised only through unit tests and the type checker.
