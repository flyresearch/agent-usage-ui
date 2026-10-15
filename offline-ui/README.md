# Agent Usage native UI (work in progress)

An isolated, local collector consumer inside a fork of Syrtis v2.7.0. It uses a
separate bundle ID and application-support directory and does not build the
upstream provider/FFI/Sparkle startup path. The upstream MIT license is retained.

Build the collector separately, then:

    swift run UsageCoreCheck
    scripts/bundle.sh PATH_TO_BUILT_COLLECTOR PATH_TO_COLLECTOR_SOURCE

The local app bundle is under .build. It is ad-hoc signed for testing, not a
notarized release. Select your private collector config on first launch; never
place real config, sessions, databases, or screenshots with private usage in this
repository. The app executes the embedded collector asynchronously without a
shell and retains last-good data on failure.

Overview, daily, models, sources and host states support both local snapshots and
fleet reports. Enable multi-host mode and select a private fleet configuration
to use on-demand local/SSH collection. Filters select host, agent, model and date
before aggregation; unallocated dates remain explicit. Automatic refresh defaults
to five minutes and can be disabled in connection settings. A readonly fleet
report updates stored freshness each minute between collections. The UI keeps
state in its own application-support directory; it does not reuse the CLI fleet
store unless explicitly wired in code.

The UI data/runner harness has seventeen actual-path checks, including malformed
fleet envelopes, stale/missing hosts, filtering, ignored termination signals,
inherited stdout and output-size bounds. A native four-host refresh, remote
failure/recovery and machine/model/date filtering have been exercised. The 24-hour trial and remaining operational qualification remain open; see the canonical knowledge document.
A working four-host window is not completion of the full first-release goal.

For the real collector integration check, set `AGENT_USAGE_TEST_COLLECTOR` to
the absolute built collector path when running `UsageCoreCheck`, or use the root
`offline-integration` Make target. Local mode requires a collector supporting
`config-id`; the bundled current collector provides it.
