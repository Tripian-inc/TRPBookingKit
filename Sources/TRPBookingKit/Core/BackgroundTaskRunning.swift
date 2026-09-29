import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Keeps work alive while the app goes to the background, so a confirmation after a charge is not
/// cut off halfway.
public protocol BackgroundTaskRunning: Sendable {
    func run<T: Sendable>(named name: String, _ work: @Sendable () async throws -> T) async throws -> T
}

/// Runs the work as is; for tests and platforms without background tasks.
public struct ImmediateTaskRunner: BackgroundTaskRunning {
    public init() {}

    public func run<T: Sendable>(named name: String, _ work: @Sendable () async throws -> T) async throws -> T {
        try await work()
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Wraps the work in `UIApplication.beginBackgroundTask`.
public struct UIApplicationBackgroundTaskRunner: BackgroundTaskRunning {
    public init() {}

    public func run<T: Sendable>(named name: String, _ work: @Sendable () async throws -> T) async throws -> T {
        let identifier = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: nil) }
        defer {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(identifier) }
        }
        return try await work()
    }
}
#endif

extension BookingConfiguration {
    /// The runner the checkouts use by default on this platform.
    public static var defaultBackgroundTaskRunner: BackgroundTaskRunning {
        #if canImport(UIKit) && !os(watchOS)
        return UIApplicationBackgroundTaskRunner()
        #else
        return ImmediateTaskRunner()
        #endif
    }
}
