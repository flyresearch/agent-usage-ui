---
status: active
id: offline-agent-usage
kind: canonical
scope: repository
read_when: changing the isolated local collector UI
last_verified: 2026-10-19
sources: ["offline-ui/Package.swift", "offline-ui/Sources/UsageCore/Snapshot.swift", "offline-ui/Sources/UsageCore/Fleet.swift", "offline-ui/Sources/UsageCore/Collector.swift", "offline-ui/Sources/AgentUsage/App.swift", "offline-ui/Sources/AgentUsage/DashboardView.swift", "offline-ui/scripts/bundle.sh", "Makefile", "offline-ui/Sources/UsageCore/CoverageDiagnostics.swift", "offline-ui/Sources/UsageCore/ConfigurationEditor.swift", "Sources/Syrtis/FleetCoverageView.swift", "Sources/Syrtis/FleetConnectionSettings.swift"]
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
does not initialize the updater or use the live source. No online quota calls
are supplied by this data source.

Original graph and model DTOs are projected from validated normalized rows.
Date-unallocated rows are excluded from daily/monthly charts and preserved in
all-time model totals, with a separate explanatory label. Missing or changed
host configurations cannot become a zero-use graph. Known tokens remain exact;
Int64-incompatible values fail projection. Cost/message fields required by the
legacy DTO are internal placeholders: offline presentation marks those metrics
unavailable, uses token rankings, and hides unsupported hourly/session/quota
lenses. Machine selection is applied before projection.

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
Daily and Monthly. View hiding now applies to supported fleet lenses; Quota
remains unavailable. Source/client/host filtering occurs before hourly or role
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
features, which still have no fleet data source.
