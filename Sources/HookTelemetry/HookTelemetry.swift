/// Option B's slot: where an adapter for a crash-reporting SDK will live once one is chosen
/// (Sentry or TelemetryDeck). It would implement RelayCore's `CrashReporter`, start only
/// with the owner's consent and never when Crash reports is Off. Until then this target
/// links nothing, and adding an SDK brings the 5-day dependency gate and a SECURITY.md note.
public enum HookTelemetry {}
