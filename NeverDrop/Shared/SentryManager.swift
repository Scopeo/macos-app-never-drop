import Foundation
import Sentry

enum SentryManager {

    private static let dsn = "https://11a2f6d0999b1cf441af0e4600c4d5fe@o4510959770075136.ingest.de.sentry.io/4511047873724496"

    private static var isRunning = false

    static func start(settings: AppSettings) {
        guard settings.analyticsConsent, !isRunning else { return }

        SentrySDK.start { (options: Sentry.Options) in
            options.dsn = dsn
            options.environment = "production"
            options.enableAutoSessionTracking = true
            options.enableAutoPerformanceTracing = true
            options.tracesSampleRate = 1.0
            options.debug = true

            options.beforeSend = { event in
                scrubPII(event)
                return event
            }
        }

        setBusinessContext(settings: settings)
        isRunning = true
    }

    static func stop() {
        guard isRunning else { return }
        SentrySDK.close()
        isRunning = false
    }

    static func startIfConsented(settings: AppSettings) {
        if settings.analyticsConsent {
            start(settings: settings)
        }
    }

    static func updateBusinessContext(settings: AppSettings) {
        guard isRunning else { return }
        setBusinessContext(settings: settings)
    }

    // MARK: - Business context

    private static func setBusinessContext(settings: AppSettings) {
        SentrySDK.configureScope { scope in
            scope.setContext(value: [
                "transcriptionProvider": settings.transcriptionProvider.rawValue,
                "selectedLanguage": settings.selectedLanguage ?? "auto",
            ], key: "business")
        }
    }

    // MARK: - PII scrubbing

    private static let homeDir = FileManager.default.homeDirectoryForCurrentUser.path()

    private static func scrubPII(_ event: Event) {
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: scrubString(message))
        }

        if let breadcrumbs = event.breadcrumbs {
            for crumb in breadcrumbs {
                if let msg = crumb.message {
                    crumb.message = scrubString(msg)
                }
            }
        }
    }

    private static func scrubString(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: homeDir, with: "~/")
        let apiKeyPattern = #"(sk-[A-Za-z0-9]{20,}|[A-Fa-f0-9]{32,})"#
        if let regex = try? NSRegularExpression(pattern: apiKeyPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "[REDACTED]"
            )
        }
        return result
    }
}
