import Foundation
import Supabase
import AuthenticationServices
import FindItCore

/// Supabase Auth session management
///
/// Handles sign-in (Apple ID, Email), session restoration, and sign-out.
/// Uses Supabase Swift SDK for auth operations.
/// The OpenRouter API key is stored in macOS Keychain via `CloudKeyManager`.
@Observable
@MainActor
final class AuthManager {

    // MARK: - State

    enum AuthState: Sendable {
        case unknown       // Not yet checked
        case anonymous     // No session
        case authenticated(userId: String, email: String?)
    }

    /// Result of sign-up when email confirmation is required
    enum SignUpResult: Sendable {
        case authenticated  // Session created immediately (confirmations off)
        case confirmationPending  // Need to verify email first
    }

    private(set) var authState: AuthState = .unknown

    /// Whether auth state has been determined
    var isReady: Bool {
        if case .unknown = authState { return false }
        return true
    }

    /// Current user ID (nil if anonymous)
    var currentUserId: String? {
        if case .authenticated(let userId, _) = authState { return userId }
        return nil
    }

    /// Current user email
    var currentEmail: String? {
        if case .authenticated(_, let email) = authState { return email }
        return nil
    }

    var isAuthenticated: Bool { currentUserId != nil }

    // MARK: - Supabase Client

    let client: SupabaseClient

    init() {
        client = SupabaseClient(
            supabaseURL: URL(string: "https://xbuyfrzfmyzrioqhnmov.supabase.co")!,
            supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhidXlmcnpmbXl6cmlvcWhubW92Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA5OTUyNTksImV4cCI6MjA4NjU3MTI1OX0.x5YYnRMMvEm51qqWJ7TRp4TRP-EyWQyyLotqIFCxbuM"
        )
    }

    // MARK: - Session Restore

    /// Restore session from Keychain (call on app launch)
    func restoreSession() async {
        do {
            let session = try await client.auth.session
            authState = .authenticated(
                userId: session.user.id.uuidString,
                email: session.user.email
            )
            print("[Auth] Session restored: \(session.user.id)")
        } catch {
            authState = .anonymous
            print("[Auth] No session: \(error.localizedDescription)")
        }
    }

    // MARK: - Auth State Listener

    /// Listen for auth state changes (token refresh failures, sign-outs, etc.)
    func startListening() {
        Task { [weak self] in
            guard let self else { return }
            for await (event, session) in self.client.auth.authStateChanges {
                await MainActor.run {
                    switch event {
                    case .signedIn:
                        if let session {
                            self.authState = .authenticated(
                                userId: session.user.id.uuidString,
                                email: session.user.email
                            )
                        }
                    case .signedOut:
                        self.authState = .anonymous
                    default:
                        break
                    }
                }
            }
        }
    }

    // MARK: - Email Sign-In

    /// Sign in with email and password
    func signInWithEmail(email: String, password: String) async throws {
        let session = try await client.auth.signIn(
            email: email,
            password: password
        )
        let userId = session.user.id.uuidString
        authState = .authenticated(userId: userId, email: session.user.email)
        print("[Auth] Email sign-in: \(userId)")
        await provisionCloudKeyIfNeeded(userId: userId)
    }

    /// Sign up with email and password
    @discardableResult
    func signUpWithEmail(email: String, password: String) async throws -> SignUpResult {
        let result = try await client.auth.signUp(
            email: email,
            password: password
        )
        guard let session = result.session else {
            // Needs email confirmation — no session yet
            print("[Auth] Sign-up: email confirmation required")
            return .confirmationPending
        }
        let userId = session.user.id.uuidString
        authState = .authenticated(userId: userId, email: session.user.email)
        print("[Auth] Email sign-up: \(userId)")

        // New user → create trial + provision OR key
        await initializeNewUser(userId: userId)
        return .authenticated
    }

    // MARK: - Password Reset

    /// Send password reset email
    func resetPassword(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email)
        print("[Auth] Password reset email sent to: \(email)")
    }

    // MARK: - Apple Sign-In

    /// Sign in with Apple ID token
    func signInWithApple(idToken: String, nonce: String) async throws {
        let session = try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        let userId = session.user.id.uuidString
        authState = .authenticated(userId: userId, email: session.user.email)
        print("[Auth] Apple sign-in: \(userId)")
        await provisionCloudKeyIfNeeded(userId: userId)
    }

    // MARK: - Sign Out

    func signOut() async throws {
        if let userId = currentUserId {
            CloudKeyManager.deleteKey(for: userId)
        }
        try await client.auth.signOut()
        authState = .anonymous
        print("[Auth] Signed out")
    }

    // MARK: - Cloud Key Provisioning

    /// For new users: call on-user-created to create trial + OR key
    private func initializeNewUser(userId: String) async {
        do {
            // Edge function now uses JWT to identify user — no payload needed
            let response: OnUserCreatedResponse = try await client.functions
                .invoke("on-user-created")

            if let key = response.openrouter_key, !key.isEmpty {
                try CloudKeyManager.storeKey(key, for: userId)
                print("[Auth] OR key provisioned for new user")
            }
        } catch {
            print("[Auth] Failed to initialize new user: \(error)")
            // get-cloud-key will retry on next app launch or sign-in
        }
    }

    /// For returning users: check if Keychain has key, if not get one
    private func provisionCloudKeyIfNeeded(userId: String) async {
        if CloudKeyManager.hasKey(for: userId) { return }

        do {
            let response: GetCloudKeyResponse = try await client.functions
                .invoke("get-cloud-key")

            if let key = response.openrouter_key, !key.isEmpty {
                try CloudKeyManager.storeKey(key, for: userId)
                print("[Auth] OR key re-provisioned")
            }
        } catch {
            print("[Auth] Failed to provision cloud key: \(error)")
        }
    }
}

// MARK: - Response Types

private struct OnUserCreatedResponse: Decodable {
    let openrouter_key: String?
    let plan: String?
    let trial_ends_at: String?
}

struct GetCloudKeyResponse: Decodable {
    let openrouter_key: String?
    let plan: String?
}
