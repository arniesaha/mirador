import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

enum DisplaySelection {
    static let displayNameEnvironmentKey = "MIRADOR_DISPLAY_NAME"

    static func configuredDisplayName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let raw = environment[displayNameEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    static func selectedCGDisplayID(environment: [String: String] = ProcessInfo.processInfo.environment) -> CGDirectDisplayID {
        guard let requestedName = configuredDisplayName(environment: environment),
              let displayID = displayID(named: requestedName) else {
            return CGMainDisplayID()
        }
        return displayID
    }

    static func displayName(for displayID: CGDirectDisplayID) -> String? {
        #if canImport(AppKit)
        return NSScreen.screens.first { screen in
            screen.displayID == displayID
        }?.localizedName
        #else
        return nil
        #endif
    }

    static func displayID(named requestedName: String) -> CGDirectDisplayID? {
        #if canImport(AppKit)
        return NSScreen.screens.first { screen in
            screen.localizedName.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }?.displayID
        #else
        return nil
        #endif
    }

    #if canImport(ScreenCaptureKit)
    static func selectDisplay(from displays: [SCDisplay], environment: [String: String] = ProcessInfo.processInfo.environment) -> SCDisplay? {
        if let requestedName = configuredDisplayName(environment: environment) {
            if let display = displays.first(where: { display in
                displayName(for: display.displayID)?.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                return display
            }
            return nil
        }

        let mainDisplayID = CGMainDisplayID()
        return displays.first(where: { $0.displayID == mainDisplayID }) ?? displays.max { lhs, rhs in
            (lhs.width * lhs.height) < (rhs.width * rhs.height)
        }
    }
    #endif
}

#if canImport(AppKit)
private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
#endif
