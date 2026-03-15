import AppKit
import Foundation
import Sentry

enum DetectionReportKind: String {
    case falsePositive = "detection.false_positive"
    case missedCall = "detection.missed_call"
}

@MainActor
final class DetectionReporter {

    private let eventLog: DetectionEventLog
    private let settings: AppSettings
    private let callDetectorState: () -> CallState

    init(eventLog: DetectionEventLog, settings: AppSettings, callDetectorState: @escaping () -> CallState) {
        self.eventLog = eventLog
        self.settings = settings
        self.callDetectorState = callDetectorState
    }

    func report(_ kind: DetectionReportKind) {
        guard settings.analyticsConsent else {
            showConsentNudge()
            return
        }

        let events = eventLog.snapshot()
        let devices = eventLog.deviceSnapshot()
        let detectorState = callDetectorState()

        let sentryEvent = Event(level: .info)
        sentryEvent.message = SentryMessage(formatted: kind.rawValue)
        sentryEvent.tags = ["report_kind": kind.rawValue]

        let recentEvents = events.suffix(50)
        sentryEvent.breadcrumbs = recentEvents.map { entry in
            let crumb = Breadcrumb(level: .info, category: "detection")
            crumb.type = entry.kind.rawValue
            crumb.message = entry.detail
            crumb.timestamp = entry.timestamp
            return crumb
        }

        let formatter = ISO8601DateFormatter()
        let fullLog = events.map { entry in
            [
                "timestamp": formatter.string(from: entry.timestamp),
                "kind": entry.kind.rawValue,
                "detail": entry.detail,
            ]
        }

        sentryEvent.context = [
            "detection_report": [
                "kind": kind.rawValue,
                "detectorState": detectorState.rawValue,
                "transcriptionProvider": settings.transcriptionProvider.rawValue,
                "selectedLanguage": settings.selectedLanguage ?? "auto",
            ],
            "audio_devices": ["devices": devices],
            "detection_event_log": ["events": fullLog, "count": events.count],
        ]

        SentrySDK.capture(event: sentryEvent)

        showConfirmation()
    }

    private func showConsentNudge() {
        let alert = NSAlert()
        alert.messageText = "Diagnostics Disabled"
        alert.informativeText = "Enable \"Send anonymous diagnostics\" in Settings to help us improve call detection."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        }
    }

    private func showConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Report Sent"
        alert.informativeText = "Thanks for helping improve detection!"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension Notification.Name {
    static let openSettingsRequested = Notification.Name("com.draftnrun.NeverDrop.openSettingsRequested")
}
