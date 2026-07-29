import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
@Observable
final class PermissionManager {
    private enum AttemptKey {
        static let screenCapture = "permissionAttempted.screenCapture"
        static let accessibility = "permissionAttempted.accessibility"
        static let safariAutomationGranted = "permission.safariAutomationGranted"
    }

    var screenCaptureGranted = false
    var accessibilityGranted = false
    var screenCaptureAttempted = UserDefaults.standard.bool(forKey: AttemptKey.screenCapture)
    var accessibilityAttempted = UserDefaults.standard.bool(forKey: AttemptKey.accessibility)
    var safariAutomationStatus = UserDefaults.standard.bool(forKey: AttemptKey.safariAutomationGranted) ? "Granted" : "Optional"
    var safariAutomationError: String?

    var hasCorePermissions: Bool {
        screenCaptureGranted && accessibilityGranted
    }

    func refresh() {
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestScreenCapture() {
        screenCaptureAttempted = true
        UserDefaults.standard.set(true, forKey: AttemptKey.screenCapture)
        screenCaptureGranted = CGRequestScreenCaptureAccess()
    }

    func requestAccessibility() {
        accessibilityAttempted = true
        UserDefaults.standard.set(true, forKey: AttemptKey.accessibility)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func checkSafari(using service: SafariTabService) {
        safariAutomationStatus = "Requesting"
        safariAutomationError = nil
        Task {
            do {
                try await service.requestAutomationAccess()
                safariAutomationStatus = "Granted"
                UserDefaults.standard.set(true, forKey: AttemptKey.safariAutomationGranted)
            } catch {
                safariAutomationStatus = "Needs permission"
                UserDefaults.standard.set(false, forKey: AttemptKey.safariAutomationGranted)
                safariAutomationError = error.localizedDescription
            }
        }
    }

    func openScreenCaptureSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openAutomationSettings() {
        openPrivacyPane("Privacy_Automation")
    }

    private func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
