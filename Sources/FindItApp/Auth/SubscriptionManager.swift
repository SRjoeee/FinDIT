import Foundation
import Supabase

/// Subscription state management
///
/// Polls `check-subscription` Edge Function for current plan/status.
/// Caches state in UserDefaults for offline startup.
/// Provides `isCloudEnabled` for IndexingManager decision-making.
@Observable
@MainActor
final class SubscriptionManager {

    // MARK: - Types

    enum Plan: String, Codable, Sendable {
        case free, trial, pro
    }

    enum SubStatus: String, Codable, Sendable {
        case active, trialing, past_due, canceled, expired
    }

    struct SubscriptionInfo: Codable, Sendable {
        let plan: Plan
        let status: SubStatus
        let trialEndsAt: Date?
        let currentPeriodEnd: Date?
        let monthlyUsageUsd: Double?
        let limitUsd: Double?
        let cloudEnabled: Bool

        static let anonymous = SubscriptionInfo(
            plan: .free, status: .active,
            trialEndsAt: nil, currentPeriodEnd: nil,
            monthlyUsageUsd: nil, limitUsd: nil,
            cloudEnabled: false
        )
    }

    // MARK: - State

    private(set) var currentInfo: SubscriptionInfo = .anonymous

    /// Whether cloud features are available right now
    var isCloudEnabled: Bool { currentInfo.cloudEnabled }

    /// Current plan for UI display
    var currentPlan: Plan { currentInfo.plan }

    /// Days remaining in trial (nil if not trial)
    var trialDaysRemaining: Int? {
        guard currentInfo.plan == .trial,
              let end = currentInfo.trialEndsAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0
        return max(0, days)
    }

    /// Formatted usage string (e.g. "$0.23 / $1.00")
    var usageText: String? {
        guard let usage = currentInfo.monthlyUsageUsd,
              let limit = currentInfo.limitUsd else { return nil }
        return String(format: "$%.2f / $%.2f", usage, limit)
    }

    /// Whether the user has a past_due status (payment failed)
    var isPastDue: Bool { currentInfo.status == .past_due }

    // MARK: - Dependencies

    weak var authManager: AuthManager?

    // MARK: - Refresh

    /// Fetch latest subscription state from Supabase
    func refresh() async {
        guard let auth = authManager, auth.isAuthenticated else {
            currentInfo = .anonymous
            return
        }

        do {
            let response: CheckSubscriptionResponse = try await auth.client.functions
                .invoke("check-subscription")

            let info = SubscriptionInfo(
                plan: Plan(rawValue: response.plan) ?? .free,
                status: SubStatus(rawValue: response.status) ?? .active,
                trialEndsAt: response.trial_ends_at.flatMap { ISO8601DateFormatter().date(from: $0) },
                currentPeriodEnd: response.current_period_end.flatMap { ISO8601DateFormatter().date(from: $0) },
                monthlyUsageUsd: response.usage?.monthly_usd,
                limitUsd: response.usage?.limit_usd,
                cloudEnabled: response.cloud_enabled
            )

            currentInfo = info
            cacheInfo(info)
            print("[Sub] Refreshed: plan=\(info.plan), cloud=\(info.cloudEnabled)")
        } catch {
            print("[Sub] Refresh failed: \(error.localizedDescription)")
            // Keep cached state
        }
    }

    // MARK: - Cache

    private static let cacheKey = "FindIt.SubscriptionCache"

    /// Load cached subscription state for offline startup
    func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let info = try? JSONDecoder().decode(SubscriptionInfo.self, from: data) else {
            return
        }

        // Local trial expiry check (don't trust stale cache)
        if info.plan == .trial, let end = info.trialEndsAt, Date() > end {
            currentInfo = SubscriptionInfo(
                plan: .free, status: .expired,
                trialEndsAt: end, currentPeriodEnd: nil,
                monthlyUsageUsd: nil, limitUsd: nil,
                cloudEnabled: false
            )
        } else {
            currentInfo = info
        }
    }

    private func cacheInfo(_ info: SubscriptionInfo) {
        if let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    /// Clear cache (on sign out)
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        currentInfo = .anonymous
    }

    // MARK: - Stripe

    /// Create Stripe Checkout URL for Pro upgrade
    /// Server uses hardcoded success/cancel URLs (no URL scheme needed)
    func checkoutURL() async throws -> URL {
        guard let auth = authManager else { throw SubscriptionError.notAuthenticated }

        let response: CheckoutResponse = try await auth.client.functions
            .invoke("create-checkout")

        guard let url = URL(string: response.checkout_url) else {
            throw SubscriptionError.invalidURL
        }
        return url
    }

    /// Get Stripe Billing Portal URL
    /// Server uses hardcoded return URL (no URL scheme needed)
    func billingPortalURL() async throws -> URL {
        guard let auth = authManager else { throw SubscriptionError.notAuthenticated }

        let response: PortalResponse = try await auth.client.functions
            .invoke("manage-billing")

        guard let url = URL(string: response.portal_url) else {
            throw SubscriptionError.invalidURL
        }
        return url
    }

    // MARK: - Errors

    enum SubscriptionError: LocalizedError {
        case notAuthenticated
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not authenticated"
            case .invalidURL: return "Invalid URL from server"
            }
        }
    }
}

// MARK: - API Response Types

private struct CheckSubscriptionResponse: Decodable {
    let plan: String
    let status: String
    let trial_ends_at: String?
    let current_period_end: String?
    let usage: UsageInfo?
    let cloud_enabled: Bool

    struct UsageInfo: Decodable {
        let monthly_usd: Double
        let limit_usd: Double
    }
}

private struct CheckoutResponse: Decodable {
    let checkout_url: String
}

private struct PortalResponse: Decodable {
    let portal_url: String
}
