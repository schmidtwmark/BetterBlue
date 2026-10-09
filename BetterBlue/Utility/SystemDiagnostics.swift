//
//  SystemDiagnostics.swift
//  BetterBlue
//
//  Keeps the reports MetricKit hands the app after the fact: hang, crash
//  and CPU/disk diagnostics, and the daily metrics with their count of
//  each way the app was terminated.
//
//  Some terminations leave TestFlight no crash log to attach. A freeze
//  that ends with the system killing the app is one (testers on build 65
//  describe exactly that: the sheet freezes when raised, then "BetterBlue
//  crashed"). MetricKit still reports the hang — with the main thread's
//  call stack — and counts the kill by cause (memory limit, watchdog…) on
//  a later launch. Saved here, testers can share them from Settings ›
//  Sync Diagnostics.
//

import Foundation
import MetricKit

final class SystemDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = SystemDiagnostics()

    /// Reports kept, newest first; older ones are deleted.
    private let maxReports = 30

    /// In the app's own Caches, not the App Group container: writing a
    /// report must never hold a lock in the shared container (0xdead10cc).
    private let directory: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SystemDiagnostics", isDirectory: true)

    private override init() {}

    /// Subscribes, and saves whatever MetricKit already delivered in the
    /// last day (a report that arrived before the subscriber was added).
    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        save(manager.pastDiagnosticPayloads.map { ("diagnostics", $0.timeStampEnd, $0.jsonRepresentation()) })
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads.map { ("diagnostics", $0.timeStampEnd, $0.jsonRepresentation()) })
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        save(payloads.map { ("metrics", $0.timeStampEnd, $0.jsonRepresentation()) })
    }

    /// Saved reports, newest first.
    var reportURLs: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func save(_ reports: [(kind: String, end: Date, json: Data)]) {
        guard !reports.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        for report in reports {
            // Named by period end, so a report delivered twice (live and
            // again as a past payload) overwrites itself.
            let stamp = formatter.string(from: report.end).replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("\(stamp)-\(report.kind).json")
            try? report.json.write(to: url, options: .atomic)
        }
        for url in reportURLs.dropFirst(maxReports) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
