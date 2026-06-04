// MARK: - DEBUG MCP Read/Search Latency Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        func debugMCPReadSearchCaptureBeginPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            guard let rawLabel = debugString(arguments, "label"),
                  let label = debugMCPReadSearchCaptureLabel(rawLabel)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "Missing required non-empty string argument `label`.")
            }

            let maxSamples: Int
            switch debugBoundedInt(arguments, "max_samples", defaultValue: 20000, range: 100 ... 100_000) {
            case let .value(parsed), let .defaulted(parsed):
                maxSamples = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_samples` must be an integer between 100 and 100000.")
            }

            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "capture": snapshot.payload()
                ])
            case let .busy(snapshot):
                return debugDiagnosticsError(
                    op: op,
                    code: "capture_busy",
                    message: "A read/search latency capture is already active with label `\(snapshot.label)`."
                )
            }
        }

        func debugMCPReadSearchCaptureSnapshotPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            let finish = debugBool(arguments, "finish") ?? true
            let includeTimeline = debugBool(arguments, "include_timeline") ?? true
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: finish)
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "capture": snapshot.payload(includeTimeline: includeTimeline)
            ])
        }

        private func debugMCPReadSearchCaptureLabel(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let replacement = UnicodeScalar("_")
            let scalars = trimmed.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? scalar : replacement
            }
            return String(String.UnicodeScalarView(scalars.prefix(64)))
        }
    }
#endif
