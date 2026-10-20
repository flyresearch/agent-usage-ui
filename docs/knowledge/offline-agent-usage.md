---
status: active
id: offline-agent-usage
kind: canonical
scope: repository
read_when: changing the isolated local collector UI
last_verified: 2026-10-20
sources: ["offline-ui/Package.swift", "offline-ui/Sources/UsageCore/Snapshot.swift", "offline-ui/Sources/UsageCore/Fleet.swift", "offline-ui/Sources/UsageCore/Collector.swift", "offline-ui/Sources/AgentUsage/App.swift", "offline-ui/Sources/AgentUsage/DashboardView.swift", "offline-ui/scripts/bundle.sh", "Makefile", "offline-ui/Sources/UsageCore/CoverageDiagnostics.swift", "offline-ui/Sources/UsageCore/ConfigurationEditor.swift", "Sources/Syrtis/FleetCoverageView.swift", "Sources/Syrtis/FleetConnectionSettings.swift", "Sources/Syrtis/FleetLiveViews.swift", "offline-ui/Sources/UsageCore/CodexQuota.swift", "offline-ui/Sources/UsageCore/AgyQuota.swift", "offline-ui/Sources/UsageCore/RecentActivity.swift", "offline-ui/Sources/UsageCore/ClaudeQuota.swift", "scripts/claude-statusline-bridge.py", "scripts/test_claude_statusline_bridge.py", "offline-ui/Sources/UsageCore/NativeQuotaHistory.swift", "offline-ui/Tests/UsageCoreTests/QuotaHistoryChecks.swift", "Sources/Syrtis/FleetQuotaPolicy.swift", "Sources/Syrtis/QuotaSelectionPolicy.swift", "Sources/Syrtis/TrayIcons.swift", "Sources/Syrtis/UpdaterService.swift", "Sources/Syrtis/ClientTray.swift", "Sources/Syrtis/FleetRuntime.swift"]
---

# Offline agent-usage consumer

This local fork adds a separate native app target under offline-ui. The reviewed
base is upstream Syrtis v2.7.0, commit 15a8fe46e65816ce1eaac0c6e25dbcf9c0d4e040.
The existing MIT attribution is retained. This is work toward the first usable
multi-host version, not a completed release or an upstream integration.

## Correction: adapt the original Syrtis application

The independent `offline-ui` executable was a transition implementation, not the
intended final UI. The active integration now builds the original `Syrtis`
target and adapts its existing `StatusItemController`, `PopoverView`,
`DashboardModel`, cards, charts, client tabs and settings. The earlier sections
below describe the retained transition build; their no-FFI/no-Sparkle-linkage
statement does not describe the original-target bundle.

`FleetUsageDataSource` implements the existing `UsageDataSource` protocol using
the already-tested `UsageCore` collector process/decoder. `FleetRuntime` is an
explicit offline startup lane, before provider/account migration, updater,
Keychain, Cursor sync, Antigravity capture and Discord startup. The app keeps its
independent bundle identity and app-owned collector settings/store. The original
target still links the upstream Rust static library and Sparkle; the fleet lane
does not initialize the updater or use the live source. Optional native Codex and Antigravity quota reads are supplied by the isolated bridge described
below; legacy GUI provider initialization remains bypassed.

Original graph and model DTOs are projected from validated normalized rows.
Date-unallocated rows are excluded from daily/monthly charts and preserved in
all-time model totals, with a separate explanatory label. Missing or changed
host configurations cannot become a zero-use graph. Known tokens remain exact;
Int64-incompatible values fail projection. Cost/message fields required by the
legacy DTO are internal placeholders: offline presentation marks those metrics
unavailable and uses token rankings. Later extensions below add hourly and
controlled-role analysis, recent rate and optional native Codex quota. Machine selection is applied before projection.

Build and check the original target with `make fleet-ui-check`; assemble the
local application using `make fleet-ui-app COLLECTOR_BINARY=ABSOLUTE_BINARY
COLLECTOR_SOURCE=ABSOLUTE_SOURCE`. The output is `.build/fleet/Agent Usage.app`.
It has an ad-hoc local signature, not a distribution signature. Eight synthetic
projection checks call the production adapter, and the original unbundled
Syrtis selftest passes. The user confirmed original-popover opening, readable model presentation, and
working machine/Agent filtering plus model/daily views. This is manual runtime
evidence; the automation interface could not target the popover. The user then identified the missing message/cost metrics; the metered-call
and versioned pricing extension below addresses those fields with explicit
coverage and estimation assumptions.

SDK 27 also exports a State macro whose plugin is absent from Command Line
Tools. `SyrtisState` explicitly aliases the established SwiftUI property wrapper;
existing view state and rendering code are retained rather than rewritten.

## Boundary

The separate Swift package has no external package dependencies. It does not
link TokenBarCore, CTB, provider/account initialization, Keychain access, Discord
or Sparkle. Existing upstream app entrypoints and C ABI remain unchanged. The
new consumer reads only explicitly selected collector output: no session parser
or raw-history scan is implemented in Swift.

Bundle identity is org.flyresearch.agentusage. App settings and state use the
independent AgentUsageOffline application-support directory. Existing Syrtis
settings, caches and installation are not modified. The local bundle embeds an
explicitly supplied collector executable; signing is ad hoc for local testing,
not a notarized distribution.

## Data flow

A background task runs the configured collector without a shell and with a
minimal environment. Output is bounded and decoded as a versioned snapshot.
Rows and totals are checked before display. UI filters select normalized rows
before reducing totals; they never subtract contributions from mixed totals or
interpret raw agent records. Date-unallocated rows remain distinct from daily
charts. A failed refresh retains the previous snapshot and marks it stale.

The current UI has overview, daily, model, source and host views. It accepts
single-host snapshots or a validated fleet envelope, with host/agent/model/date
filters applied before aggregation. Missing and changed-configuration hosts have
no current total; stale hosts retain their last-good contribution. Cross-day
intervals remain explicitly unallocated. Host/source diagnostic pages show full
host snapshots rather than pretending that model/date filters change source
health. Automatic refresh defaults to five minutes; readonly fleet state is
rechecked each minute between collections. Both process operations run off the
main actor. The process reader uses nonblocking IO, a monotonic deadline and
bounded output, and kills only its own direct child on timeout/error. It does
not claim that terminating SSH immediately terminates a remote process.

Native four-host collection (including Windows PowerShell SSH), filtering, remote lock-conflict recovery and restore
have been exercised. A MenuBarExtra entry has been implemented; the user confirmed reopening through that menu, and the reopened native panel was inspected. The planned trial is running and has not completed. Do not treat a working local window as completion of the broader
first-release goal.

## Checks

    make offline-check
    make offline-build
    make offline-app COLLECTOR_BINARY=PATH_TO_BUILT_COLLECTOR COLLECTOR_SOURCE=PATH_TO_COLLECTOR_SOURCE

UsageCoreCheck is a standalone synthetic test executable exercising the actual
snapshot decoder and selection/reduction code; it does not require XCTest.
Native rendering and real local refresh have been exercised, including the
unknown/partial coverage display and agent filtering. Holding the collector configuration lock has also been used to verify that a failed refresh retains the displayed snapshot, marks it stale, and recovers after the conflict is released. Private settings, usage
values, screenshots and source paths are not part of the public test material.

Hermes interval rows are decoded and checked for valid bounds and day assignment.
Main, auxiliary and residual rows retain distinct identities; date selection
excludes unallocated intervals without removing them from the all-date total.
The standalone harness has seventeen passing checks, including malformed intervals, fleet state consistency, pre-aggregation filters and real process timeout/output bounds.

OpenClaw backend and opaque provider fields are retained in row identity, so
separate transport/provider rows do not collide in SwiftUI. Runtime-only usage
and missing dedicated backend logs have explicit source diagnostic labels.

The local bundle includes upstream UI and collector license notices. The builder
requires the collector source directory alongside the explicit binary for this
purpose. Runtime linkage inspection shows system Swift/Foundation/AppKit/Charts
frameworks and no upstream provider FFI or Sparkle libraries. SSH may use existing
SSH identities; the no-credential claim applies to model-provider login paths.

Fleet configuration errors clear the current UI projection instead of showing
an old configuration as current. Last-good data remains in the store. The
configuration-error process mapping is covered by the standalone harness.

Failed-source identifiers are validated as controlled labels and shown in host
and source views. The last-good source counts remain visible with a current
failure marker. An isolated synthetic UI fixture verified failure, retained
total and recovery without changing the real four-host store. Core failure
metadata is additive; the app-owned store schema migration is owned by the
collector. A paired app/state backup was retained privately before upgrading.

Local mode binds saved output to the current collector `config-id` result and
validates output before atomic publication. This avoids showing old-scope data
after a configuration change. A separate UI refresh lock spans collection,
identity validation and publication. The real-collector integration gate is
`make offline-integration COLLECTOR_BINARY=ABSOLUTE_BINARY_PATH`; it runs the
seventeen standalone checks plus the actual Rust CLI binding/retention check.
A normal `offline-check` run explicitly reports that integration was not
requested when no collector binary was supplied.

## Menu-bar usage panel

The offline target now follows Syrtis's popover structure: header actions,
Agent tabs, view switch, scrollable usage cards and footer controls. It uses
SwiftUI MenuBarExtra window presentation, sharing the existing DashboardStore;
no provider quota, credential or updater startup paths are imported.

The status item shows today's known tokens in the contract timezone. The panel
has independent today / seven-day / thirty-day / all-time and host / Agent
selection, token buckets, daily bars, model rankings and host health. Failed or
excluded hosts retain their explicit state; unavailable totals remain absent.
Unallocated dates are excluded from bounded periods and explained separately.
Reopening retains the current panel selection during the app lifetime. The main
dashboard filters do not change the status-item total or panel selection.

MenuSummary is exercised by synthetic checks for timezone boundaries, period
bounds, pre-aggregation selection, missing versus zero and stale retention.
The real-collector integration run passes 20 checks. The user confirmed the actual menu-bar popover opens with a correct layout and
working seven-day, Agent, model and host switches. The automation interface
could only target the dashboard, so this rendering/interaction evidence is
manual confirmation rather than an automated popover check.

## Metered calls and offline pricing

The original-target adapter now passes deduplicated metered response/API-call
counts and versioned directory-price estimates into the existing Syrtis graph
and model DTOs. Daily/monthly views label counts as metered, not all conversation
messages. The scope header shows count completeness, estimate USD, priced-token
coverage and catalog version. Cost fields are estimates, including the chart's
price mode. Model rows without a usable price continue to show unavailable.

The detailed contract and public source links are in
[pricing-estimates.md](../pricing-estimates.md). The catalog is bundled with
UsageCore; no provider or pricing network call is added at runtime. Synthetic
core checks cover exact decimal arithmetic, unknown models, missing cache-write
rates, old snapshots, partial counts and overflow; original-target checks also
verify that the legacy Syrtis DTO receives counts and estimated amounts.

## Runtime collector rebinding regression

Computer Use inspection found that the running app still referenced the
transition bundle's older collector: it preserved snapshot parser metadata but
reserialized rows without the additive count field. Direct checks with the new
CLI therefore did not prove the app's actual invocation path. The private
connection was corrected and the configured-runtime report was rechecked.

`LocalCollector.reboundSettings` now follows the currently running app's bundled
collector only when the previous path belongs to an app with the owned bundle
identifier and the expected executable layout. Explicit custom CLI paths and
other bundles are preserved. A synthetic filesystem regression exercises both
upgrade and non-upgrade paths. Missing count coverage displays unavailable,
including the all-unknown case, and no-current-data must not render zero totals.

Computer Use subsequently targeted the original popover by its full app path,
read the accessibility tree and captured the actual rendered view. It switched
from all Agents to Claude, then to one host, and exercised daily and model
views: the metered count and estimated amount agreed across header and daily
row, model names were readable, and restoring all-host/all-Agent selection
restored the aggregate scope. These are direct UI checks after correcting the
runtime collector binding, superseding the earlier manual-only limitation.
The permanent rebinding regression brings the Swift core run to 23 checks.

## Fleet application branding

The fleet build uses Agent Usage as its visible name in the popover, settings
window and status-item accessibility/tooltip. Its original bar-chart artwork
replaces the upstream sediment logo in the fleet header and application icon.
The default fleet status icon uses the same mark; explicit user-selected icon
styles remain supported. The normal upstream runtime keeps its Syrtis branding.

The artwork generator is `scripts/draw-agent-usage-icon.swift`; retained final
assets are `Sources/Syrtis/Resources/agent-usage-mark.pdf` and `agent-usage.icns`.
Generate preview iconsets under `.build` and use iconutil for ICNS assembly.
About copy identifies Agent Usage as a modified Syrtis UI fork and retains the
upstream and third-party attribution. Brand changes do not remove licenses or
claim independent authorship of the upstream interface.

## WorkBuddy collector support

The snapshot decoder accepts the `workbuddy` agent label. The original target
registers WorkBuddy in `ClientRegistry`; its existing dynamic client filters,
graph and model projections consume normalized collector rows. The transition
menu also includes the agent. Synthetic checks exercise decoding, filtering,
metered counts and original-target projection. This change does not enable a
source in private configurations or replace an installed application.

## Source coverage and graphical configuration

The original fleet header now separates collection freshness from source
coverage. Its expandable diagnostics include sources with no metered rows,
identify retained last-good data and failed sources, and exclude snapshots from
obsolete configurations. Diagnostic scope is explicitly all sources/dates for
the selected host, independent of chart client/year filters. Informational
mirror/dedup counters are not warnings; unrecognized counters are conservative
gaps. A complete report means no known gap, not proof of complete history.

The original General settings page supports creating/importing a private
configuration or restoring a connection backup, adding/removing local or SSH hosts, selecting local transcript
folders or databases, and editing model aliases. Remote source files remain
remote-owned: the UI registers their existing paths and reads `config-id` over
SSH with batch mode and strict host-key checking. POSIX paths are quoted and
PowerShell commands are UTF-16LE encoded. No provider credentials are read.

Save creates a private immutable candidate configuration directory, validates
local paths and duplicates, obtains configuration identities, and runs actual
collection into an isolated test store. Remote collectors may reuse their
existing cache; their source configurations are never written. A partial
historical coverage result is allowed, but any failed host blocks publication.
The former source configurations and live statistics store are untouched by
validation. Imported and generated candidate configuration bytes are checked again before
publication. Malformed optional fields fail import instead of silently falling
back to defaults. A failed import preserves the prior draft and concurrency
baseline.
A compare-and-swap check under an editor lock fences concurrent connection edits;
a private rollback connection is written before atomically replacing the
app-owned connection file. The app then refreshes using the new connection and
reports refresh failure separately from save failure. Publication returns its
exact connection bytes for a post-save readback; a newer connection cannot be
adopted as the old draft's concurrency baseline. Prior configuration
revisions and rollback connections are retained, not automatically deleted.

Synthetic checks cover empty/unmetered sources, stale and excluded hosts,
unknown diagnostic fields, path overlap, unsupported imports and SSH quoting.
The real collector integration checks candidate collection, atomic publication,
external-edit conflicts, private file modes and failed-trial retention. These
checks do not claim native rendering or live remote-machine qualification.

## Offline analysis lenses

Hourly, Stats and Agents are enabled in fleet mode alongside Overview, Models,
Daily and Monthly. View hiding applies to supported fleet lenses. The optional native quota
extension described below also enables Quota. Source/client/host filtering occurs before hourly or role
aggregation. Switching host clears the lazy-analysis caches and supersedes
in-flight reports so a previous host's hours/roles cannot remain selected.

`UsageRow` accepts optional collector p2b-8 `hour` and `execution_role`. The hour
must be 0–23 and accompany an event-timestamp day; role is restricted to main or
subagent. Older collectors, interval summaries and conflicting event times have
unknown hours. Hourly shows timeline and 24-hour profile plus unallocated-hour
Token coverage, in Asia/Singapore. It never divides a day across hours.

Agents groups explicit main/subagent roles and a separate unknown category,
ranked by tokens. It does not expose private subagent names or turn counts.
Stats ranks favorite model/busiest day by tokens, labels prices as directory
estimates and hides subscription attribution. Unknown prices remain unavailable;
known metered calls are not relabelled as all messages or conversation turns.
The WorkBuddy disc uses a generic SF Symbol, not claimed official artwork; agy
uses the existing Antigravity CLI name and icon alias.

Synthetic collector regressions cover timezone boundaries, streaming/replay
conflicts, cache reuse and old snapshots. Swift production projection checks
cover same-hour mixed clients, hidden clients, old rows, year/host filters and
controlled role totals. These checks do not qualify real-time trace or quota
features. Recent rate and native CLI quota are qualified separately below.

## Recent rate and optional native CLI quota

Connection settings now carry optional `liveMetrics`, `codexQuotaEnabled` and
`codexExecutable`, `agyQuotaEnabled` and `agyExecutable`. Defaults are disabled. Live mode overrides the configured normal collection interval
(five minutes by default) with thirty seconds; all consumers share the existing in-flight
collection, and failed automatic attempts also respect the cadence. A full
collector snapshot carries a bounded recent-activity report. Ten-minute observed
Token totals divided by ten produce tokens/min; they include input/cache/output
and are not model-generation throughput. Hidden clients are filtered before the
rate sum, and the selected host is applied before projection. Unsupported or old
collectors remain missing/partial, not zero. Samples older than 75 seconds are
unavailable; a recent retained last-good sample is labelled partial.

Codex quota is a separate opt-in UI bridge to the official local app-server.
Only initialize/initialized, account/read with refreshToken=false, and
account/rateLimits/read are sent. No thread/turn, login/logout, reset redemption,
credit purchase or notification methods are invoked. App/MCP/plugin startup is
disabled in this child; analytics are disabled. The native CLI owns existing
login state and any necessary native credential renewal. This app does not read
credentials, persist account responses or initialize the upstream GUI provider
stack. The collector itself still makes no provider requests.

Responses are bounded and validated; account metadata is compared before and
after the limits query, then discarded without logging. Only generated window
labels, percentages, durations and reset times reach the UI. Multi-bucket limits
are preferred over their legacy single-bucket mirror. Errors, unsupported auth,
expired data and resets that have passed do not become zero balances. Requests
are coalesced and limited to one per minute automatically (manual retries have a
ten-second floor). Feature/path changes fence old in-flight responses; failures
clear the old quota. Native process teardown first closes stdin gracefully and
then uses a bounded exact-child termination fallback.

The Quota lens and overview card display the local CLI's current account,
independent of fleet host selection. Quota remaining in the menu bar is the most
constrained selected window, not an additive balance across models or machines.
The source supplies sanitized quota DTOs to the existing indicator/gauge, with
persistent quota caching still disabled. Other providers beyond Codex, Antigravity and the Claude status-line bridge have no
configured supported quota connector and direct users to the original product.

Official protocol: [Codex App Server](https://learn.chatgpt.com/docs/app-server).
The native bridge is independently implemented and tested with synthetic RPC
servers. `AGENT_USAGE_TEST_CODEX` explicitly opts the standalone check harness
into a native read-only smoke test; ordinary tests never query real accounts.

Antigravity uses the official CLI `-p /usage --output-format json` command,
introduced as a no-turn read-only print command in CLI 1.1.11. The bridge checks
the native version before querying, and rejects responses with any model turn or
consumed token. It requires structured quota buckets, validates remaining
fractions and reset times, coalesces mirrored bucket IDs, and marks missing
fractions partial. Provider names/account text are not displayed or persisted.
The process runs in a temporary directory with bounded output and timeout.
`AGENT_USAGE_TEST_AGY` opts into a native smoke test. Official references:
[usage command](https://www.antigravity.google/docs/cli/commands/usage) and
[CLI changelog](https://www.antigravity.google/docs/changelog?tab=cli).

Both provider states and configuration generations are independent. The menu-bar
remaining percentage follows the selected native quota window; each provider has separate
window cards. Direct Claude OAuth and undocumented WorkBuddy probes remain unconnected.


## Claude Code subscription quota via statusLine

The official [status-line interface](https://code.claude.com/docs/en/statusline#rate-limit-usage)
provides Pro/Max five-hour and seven-day usage percentages and reset times after
the session's first API response. Each window can be absent. This integration
receives those fields locally; it does not read credentials, start a model turn,
read transcripts, or call a private provider endpoint.

Install the independently implemented bridge with explicit private locations:

```sh
python3 scripts/claude-statusline-bridge.py --install \
  --settings "$CLAUDE_SETTINGS" --directory "$PRIVATE_BRIDGE_DIR"
```

The settings parent must exist. The installer backs up the original settings,
preserves other fields and status-line options, and forwards the original
command with its stdin, stdout, stderr, working directory, environment and exit
status. Reinstalling is idempotent; a changed status-line configuration is refused.
The script and forwarding configuration stay in the private bridge directory.
Only sanitized window data is published in `quota.json`; a private bounded
replay index contains hashes, never session IDs or raw status-line payloads.

Enable `claudeQuotaEnabled` and select that `quota.json` through the connection
settings (`claudeQuotaSnapshot`). The UI reads it approximately every ten seconds, independently
of historical collection. The card explicitly describes the latest observed
Claude session; no account identity is inferred and no quotas are summed.
It is unavailable before the first usable callback and after 90 seconds without
a new observation. Passed reset times also invalidate remaining percentages.
Unchanged timer callbacks, including alternating callbacks from different
sessions, do not renew freshness. A change in native cumulative API duration or
quota fields establishes a new observation; this is not independent polling of
the provider. Invalid or missing quota data never becomes a zero balance.

The bridge preserves up to 4096 session fingerprints and fails closed beyond that
bound. To reset this private replay index, stop Claude sessions first and remove
`replay.json` and `quota.json` together. To remove the integration, restore only
`statusLine` from the private `forward.json` original object (remove the field if
it was absent), preserving unrelated settings changes, and disable the UI toggle.
Do not restore the entire settings backup over newer unrelated preferences.

Verification uses `python3 scripts/test_claude_statusline_bridge.py`, the Swift
UsageCore checks and fleet projection checks. Synthetic payloads stay in temporary
directories and are never injected into the real status-line bridge. Live
acceptance requires an actual Claude callback; installation alone is not evidence
of a current subscription quota.


## Mouse-friendly client tabs

Fleet source selection is a separate, labelled panel above the analysis lenses.
The fixed All Agents action replaces the ambiguous source-level Overview label.
Clients occupy a three-column grid with equal 34-point-high hit targets, stable
icon and checkmark positions, and separate hover/pressed/selected states. A
checkmark and border communicate selection in addition to accent color.
Antigravity uses a compact visible label and retains its full accessible label
and tooltip. Command-number shortcuts retain their existing order.

Right-clicking a client offers move-before/move-after actions in the shared tab
order, preserving hidden clients through the existing reorder implementation.
The fleet panel has no horizontal scrolling or drag gesture competing with clicks.

`Syrtis --fleet-offline --fleet-source-preview OUTPUT_DIRECTORY` renders the
production selector at the actual popover width, using synthetic client IDs in
light/dark appearances and all/single selection states. This does not start the
fleet runtime or read account data. Rendered artifacts remain outside Git.

## Native quota observation history

The isolated quota bridges now keep a separate local seven-day observation
archive, capped at 10,000 points per provider. The quota card offers 24-hour and
seven-day views plus a stable window selector. It records only generated window
labels/keys, observation time, percentage, duration/reset metadata and random
segment IDs. Account comparison hashes remain in memory and are never archived;
credentials, account objects and raw CLI responses are not stored. This does not
enable the legacy GUI quota cache or its provider initialization.

Codex checks the native account before and after each query. Its stable window
keys derive from the protocol bucket key rather than a changing list position.
A segment additionally requires known reset and duration. Account changes,
missing windows, reset/duration changes, percentage decreases, failed queries,
clock regression, gaps over five minutes and app restarts break continuity.
A historical segment is not claimed to belong to the currently signed-in account.
Claude and Antigravity do not yet provide verified account continuity through
these bridges, so their history is shown as independent observations, without
lines or pace forecasts. Repeated callbacks with the same capture time add no
points. The existing subscription account/host separation is unchanged.

Trend calculations require at least three fresh, contiguous samples of the same
segment spanning at least five minutes, and use at most the latest thirty
minutes. They report observed net percentage-point change per hour, not token
throughput or authoritative consumption. Exhaustion is a conditional linear
estimate, shown only if it falls before the current reset; flat observations
produce no exhaustion estimate. No history is backfilled. Sparse or unverifiable
samples display an explanation instead of a made-up rate. Charts limit rendering
to roughly 720 sampled points per window; calculations retain all observations.

The archive lives under the app's private support directory. Atomic mode-0600
writes and an exclusive single-writer lock prevent partial writes and competing
instances from overwriting history. Corrupt/locked/unwritable history is surfaced
separately from current quota availability and is not silently overwritten.
Synthetic tests cover boundaries, identity/reset changes, replay, retention,
window-key stability, restart, locking and permissions. Real-query smoke checks
validate bridge decoding; they cannot replace observing enough live samples to
qualify a trend.

`Syrtis --fleet-offline --fleet-quota-history-preview OUTPUT_DIRECTORY` renders
the production history chart using synthetic interrupted-series data in light
and dark appearances. It does not query providers or write the real archive.

## Syrtis 2.9 alignment audit

Reviewed upstream release tags `v2.8.0` (`a209487`) and `v2.9.0` (`ed3fae7`)
against the fork's v2.7 baseline. This is selective alignment, not a merge of the
upstream provider stack or a claim of complete product parity.

| Upstream change | Fleet disposition |
|---|---|
| DeepSeek Harness source in 2.8 | Pending independent collector adapter and fixtures; adding an icon alone would not collect its usage. No source configuration is changed by this audit. |
| Window-card refresh spinner and unread-tail handling in 2.8 | That upstream window-usage/attribution view is not the fleet quota card. Fleet shows its own loading, stale and missing-sample states. The upstream fix is not transplanted into an unused path. |
| Gauge H/D/W/M window letters and preference in 2.9 | Adopted from reviewed MIT upstream commits `91c82d1`, `35ba81e`, `497981a`, retaining LICENSE attribution. Letter mapping, monospace rendering, preference, localizations and upstream regression checks are included. |
| Native quota selection/freshness | Fleet enables the source/window picker, aligns its remaining-percent title with the same selected window as the gauge, and expires readings after 90 seconds or a passed reset. Native bridge polling remains coalesced and rate-limited; tray consumers re-read about every ten seconds. |

The fleet DTO explicitly carries known provider/contract durations while marking
legacy backend history/account binding unavailable. It does not claim that the
independent observation archive is the upstream account-attributed history store.
Unknown duration produces no letter. Fleet quota polling also bypasses the legacy
Antigravity capture/binding initializer, including shared dashboard call sites.

Remaining differences include DSH collection, full named-agent/session detail,
account management and subscription attribution, cross-restart account-bound
trend history, additional quota providers, individual client menu-bar items and
auto-update distribution. They are not hidden behind a percentage-complete claim.
Native window click-through acceptance remains separate from pure projection,
selftest and offscreen rendering checks; Computer Use has reported timeouts and a ScreenCaptureKit capture failure.

Primary release references: [2.8.0](https://github.com/Nanako0129/syrtis/releases/tag/v2.8.0)
and [2.9.0](https://github.com/Nanako0129/syrtis/releases/tag/v2.9.0).


## Full Syrtis replacement program

### Product decision — 2026-10-20

The target is now a complete daily-use replacement for Syrtis, not a reduced
fleet dashboard or a first-usable MVP. Preserve reasonable user capabilities,
including optional integrations, while keeping the independent bundle, local
collector, provenance and explicit partial-coverage behavior. A safer mechanism
may replace an upstream mechanism; it must still deliver the user capability.
Hiding a feature, exposing an unsupported placeholder, or having an unused
upstream implementation in the repository does not constitute replacement.

The first fixed comparison baseline is upstream Syrtis v2.9.0 (`ed3fae7`).
Review later releases as explicit baseline updates rather than moving the finish
line silently. Existing v2.7 fork behavior, v2.8/v2.9 additions, settings pages,
context menus, keyboard shortcuts and background behavior are all in scope.
The earlier first-usable ledger remains historical evidence, not the completion
criterion for this replacement program.

### Capability ledger

Status below is intentionally conservative. "Partial" includes implemented
behavior whose semantics, data coverage or real interaction proof is incomplete.
No row is waived merely because this installation has not used it yet.

| ID | Capability to retain | Present state / gap | Acceptance evidence |
|---|---|---|---|
| R01 | All upstream supported usage sources | Partial: six source families in the independent collector; DSH and remaining adapters pending | One row per upstream source with format/revision, actual adapter tests and qualification status; icon/registry presence is not parser support |
| R02 | Source discovery, additional roots, import/sync workflows | Partial: explicit local/SSH configuration works; upstream discovery and import paths need classification | Bounded discovery, preview/selection, overlap rejection, errors and source-specific import checks |
| R03 | Tokens, metered calls, models, costs and date attribution | Partial: known totals and estimates implemented; original counts/attribution may differ | Reconciliation fixtures and real-source comparisons; distinguish estimates, billed spend, unknown counts and missing dates |
| R04 | Overview, models, daily/monthly/hourly, Stats and Agents lenses | Partial: all tabs exist; some data dimensions are narrower | Every metric/filter/drilldown mapped to a real data path; no placeholder values presented as measured values |
| R05 | Bar, heatmap, 3D, breakdown and tooltip interactions | Reused UI; complete current-build interaction acceptance pending | Light/dark rendering, mouse/trackpad/keyboard, resize and empty/partial cases |
| R06 | Named agent/session detail and live trace grouping | Partial: main/subagent/unknown and ten-minute aggregate rates | Real per-event identity/dimensions when available, bounded trace, no inferred names or generation-speed claims |
| R07 | All menu-bar title modes, icons, animation, color, window letters | Implemented/reused; final interaction and resource checks pending | All modes, stale transitions, source selection consistency, idle/active CPU checks |
| R08 | Independent per-client menu-bar items | Runtime and settings connected; current-build interaction acceptance pending | Add/remove/select windows, persistence, missing/expired sources, no duplicate polling |
| R09 | Native quota cards and provider-specific balances | Partial: Codex, Claude and Antigravity bridges | Per-provider availability matrix, allowed native/API/export mechanism, refresh/reset/error behavior and optional setup |
| R10 | Multi-account management and explicit account selection | Pending beyond native current-account/session observations | Add/select/remove without mixing histories; native login handoff; account change during refresh and restart tests |
| R11 | Quota history, cycles, consumption pace and forecasts | Partial: bounded seven-day observations; verified in-process Codex trends | Account/window binding, continuity across restart when trustworthy, cycle history, uncertainty and reset/backfill boundaries |
| R12 | Subscription attribution and quota-window local usage | Pending | Explicit confirmed mapping, unassigned bucket, reversible reassignment, concurrent mapping changes and no double counting |
| R13 | Limits/card/window visibility, ordering and source filters | Partial: source/lens controls work; some fleet settings hidden | Every retained control affects the corresponding producer/view and persists correctly |
| R14 | Login startup and application lifecycle | Entry restored and updater gate separated; actual login-cycle acceptance pending | Actual login registration, launch, quit/restart, duplicate-instance behavior and permission failure paths |
| R15 | Refresh settings and background collection | Configurable normal cadence and live override implemented; wake/long-run checks pending | User-facing interval controls, manual refresh, sleep/wake, failure cooldown and quota/history status consistency |
| R16 | Language, appearance, popover size and accessibility | Language selector restored; full fleet-specific translations and interaction checks remain | Language selection/restart, full copy coverage, contrast, focus order, VoiceOver, shortcuts and small displays |
| R17 | Optional Discord presence | Not started/exposed in fleet mode | Preserve as an explicit opt-in feature with preview, scope/privacy controls and working disable; do not enable or publish merely for testing |
| R18 | About, version, licenses, diagnostics and help | Partial | Correct product identity/build/version, retained MIT attribution, sanitized actionable diagnostics and working help links |
| R19 | Installation, own update channel, signing and rollback | Local ad-hoc deployment only | Independent signed/notarized release path and update feed; upgrade/rollback preserves data and never installs upstream Syrtis over this app |
| R20 | Preference/history migration and uninstall | Partial private backups; no complete migration flow | Previewed reversible migration, separate identities/stores, stable installed path, cleanup choices and original app retained until cutover |
| R21 | Fleet aggregation, coverage diagnostics and graphical config | Added capability, must not regress | Four-host fresh/stale/offline recovery, WAL visibility, config fencing, correct totals and private rollback |
| R22 | Reliable daily operation and complete interaction acceptance | Partial; Computer Use capture currently blocked | Current-build manual or automated evidence for each critical flow, multi-day operation and recovery, not just process/build success |

R01/R09 must be expanded into per-source/per-provider rows before claiming full
coverage. Start from the pinned upstream scanner/provider implementations and
compare them to ClientRegistry, rather than treating every registry icon as an
implemented integration. An uninstalled source stays "not qualified"; synthetic
fixtures alone do not establish live acceptance.

### Delivery sequence

1. **Everyday settings and desktop behavior (R07/R08/R13–R16).** Restore the
   fleet general settings surface, login startup, language and refresh controls;
   then enable independent client menu-bar items and remaining visibility controls.
   Reuse existing services after verifying the independent bundle identity and
   fleet data path. Do not expose a toggle whose runtime is still disconnected.
2. **Accounting and account scope (R03/R06/R09–R12).** Add explicit account/profile
   identity and reversible subscription attribution, then window-local usage and
   durable account-bound history. Native login/API/export paths remain separate
   from local session collection. Unknown scope must stay unassigned.
3. **Source/provider completeness (R01/R02/R09).** Inventory every upstream
   adapter and quota provider, land DSH and remaining sources in reviewed batches,
   and test parsing/dedup/WAL/import behavior on their supported platforms. Usage
   collection and balance querying are separate acceptance items.
4. **Optional integration and distribution (R17–R20).** Restore optional presence,
   diagnostics/help, migration and an independent update/release workflow. Signing
   credentials or provider access needed later are concrete external dependencies,
   not reasons to leave unrelated work unfinished.
5. **Replacement acceptance (R04/R05/R21/R22 plus all previous rows).** Run the
   full desktop test matrix, verify the new build as the primary daily app for at
   least seven days with the four-host fleet, and exercise offline/restart/wake/
   account-switch/update/rollback scenarios. Extend observation after material
   fixes rather than counting an older build's trial as current acceptance.

Each batch records implementation, regression evidence, native validation and
remaining limitations separately. Upstream maintenance continues via pinned,
license-reviewed selective ports rather than a broad merge of credential and
update initializers.

### What "reasonable" means

The default is retention: an upstream user-facing capability remains in the
ledger, including optional appearance and integration features. Lack of current
use, implementation difficulty or absence of an official endpoint does not
silently remove it. Where an interface is unavailable, record the blocked
capability and investigate supported alternatives; it is not complete until a
working equivalent or an explicitly agreed exception exists.

Implementation details are not mandatory to preserve: copying another app's
credentials, using its update feed, silently initializing network services,
presenting missing data as zero, or guessing subscription/account attribution
must not become dependencies of replacement. Replace those mechanisms while
preserving the legitimate outcome. No blanket compliance claim is implied by
calling a mechanism "native"; verify each interface's supported use separately.

### Completion / cutover gate

- Every reasonable capability has an accountable ledger row and passes its
  defined checks, or has a specific user-agreed exception; no percentage-complete
  proxy or hidden menu is accepted as proof.
- No routine user workflow requires keeping Syrtis running to fill a missing
  function. Original Syrtis may remain installed for rollback until explicit cutover.
- No unexplained loss/double count across source, host, account, time and model
  dimensions; partial coverage remains visible rather than manufactured away.
- Data/credentials/private operational configuration stay outside Git and
  diagnostics; optional outbound integrations remain off until deliberately enabled.
- Installation, update, preference/history preservation and rollback are proven.
- The actual current build passes desktop interaction and seven-day operation
  acceptance. Automated capture failure is an outstanding validation item, not a pass.


## Replacement batch 1 — desktop settings and individual items

Fleet General now includes login startup and language settings alongside the
existing connection editor. Login startup availability is based on the current
application bundle, independently of Sparkle/update eligibility. Only an explicit
user toggle registers/unregisters the current app with SMAppService. State is
read back after mutations; approval-required, unavailable and failed operations
are visible rather than assumed successful. The system login-items settings can
be opened from the page. This batch does not turn login startup on automatically.

The existing language preference/AppleLanguages override and own-bundle relaunch
are reused; restart copy names Agent Usage and has English/Simplified/Traditional
Chinese resources. Full translation of all earlier fleet-specific copy remains
an R16 item. Quota history acquisition retries a busy archive at ten-second
intervals so the new process can acquire the writer lock after the old process
exits during a language relaunch; failed/corrupt archives are never overwritten.

Connection settings add optional `refreshIntervalSeconds`, supporting 60, 300,
900, 1800 and 3600 seconds. Old configurations retain the 300-second default.
Live metrics use a 30-second override; disabling live metrics restores the saved
normal cadence. Automatic collection can be disabled independently of native
quota refresh. Changes use the existing validated save/backup workflow. Runtime
scheduling consumes this same setting, including failure cooldown. A background
collection loop keeps statistics active even when the main title shows quota.

Individual items settings now drive the existing ClientTray/StatusItemController
reconciliation path. Enabled clients retain independent window selections and
routes; hidden clients are suppressed. It currently offers the quota-capable
clients with available assets/data (Codex, Claude and agy), not fabricated balance
items for providers lacking quotas. Missing/expired quota yields unavailable,
not zero, and does not misclassify an explicit window as deleted merely because
its provider snapshot is temporarily absent. Presence comes from a global fleet projection, independent of the open
panel's machine filter. Preference changes and quota publications reapply cached
presentations without starting separate provider queries for each item.

Checks cover refresh-setting compatibility/persistence/validation, isolated
language preferences, bundle-only login-service eligibility, actual asset-backed
client rows, explicit window selection, hidden clients and unavailable quotas.
`Syrtis --fleet-desktop-check` reads the current bundle/login-service state without
registering a login item. Desktop click-through, user-chosen login registration,
actual login-cycle launch and language-restart interaction remain separate native
acceptance items; restoring their controls is not proof those user actions ran.

Batch verification: 49 UsageCore checks (including collector integration), 31
fleet projection/desktop checks, and the original application selftest pass.
The packaged read-only desktop check recognizes the app bundle but reports the
login service as unavailable on the current test machine. No registration was
attempted, so this proves neither a successful login launch nor a registration
failure. Login-cycle acceptance remains open. Computer Use still times out.
