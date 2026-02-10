//
//  AuthService.swift
//  MADxSync
//
//  Handles Supabase authentication for multi-tenant SaaS.
//  Login authenticates the DISTRICT (via district_users table).
//  Truck selection is handled separately by TruckService / truck picker.
//
//  ARCHITECTURE:
//  - district_users table links auth accounts to districts
//  - trucks table holds truck inventory per district
//  - Login gives you district_id -> truck picker shows trucks in that district
//  - Tech picks their truck, can switch anytime in Settings
//
//  BULLETPROOFED: 2026-02-07
//  HARDENED: 2026-02-09 — Network-aware token refresh, no sign-out on network blips,
//  retry with exponential backoff, differentiates network errors from real 401s.
//

import Foundation
import Combine

// MARK: - Authenticated User Model

struct AuthenticatedUser: Codable {
    let authUserId: String
    let email: String
    let districtId: String
    let districtName: String?
    let role: String?
    let userName: String?
    
    func save() {
        if let encoded = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(encoded, forKey: "authenticated_user")
        }
    }
    
    static func load() -> AuthenticatedUser? {
        guard let data = UserDefaults.standard.data(forKey: "authenticated_user"),
              let user = try? JSONDecoder().decode(AuthenticatedUser.self, from: data) else {
            return nil
        }
        return user
    }
    
    static func clear() {
        UserDefaults.standard.removeObject(forKey: "authenticated_user")
        UserDefaults.standard.removeObject(forKey: "supabase_access_token")
        UserDefaults.standard.removeObject(forKey: "supabase_refresh_token")
    }
}

// MARK: - Auth Session Response

struct SupabaseAuthResponse: Codable {
    let access_token: String
    let refresh_token: String
    let user: SupabaseUser
}

struct SupabaseUser: Codable {
    let id: String
    let email: String?
}

// MARK: - Auth Service

@MainActor
class AuthService: ObservableObject {
    
    static let shared = AuthService()
    
    @Published var currentUser: AuthenticatedUser?
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    /// Indicates token refresh is failing — UI can show a warning
    @Published var tokenRefreshFailing: Bool = false
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    var districtId: String? { currentUser?.districtId }
    var accessToken: String? { UserDefaults.standard.string(forKey: "supabase_access_token") }
    
    private var refreshTimer: Timer?
    
    /// Tracks consecutive refresh failures for exponential backoff
    private var consecutiveRefreshFailures: Int = 0
    private let maxBackoffMinutes: Double = 15
    
    /// Prevents concurrent refresh attempts
    private var isRefreshing: Bool = false
    
    private init() {
        if let user = AuthenticatedUser.load() {
            self.currentUser = user
            self.isAuthenticated = true
            print("[AuthService] Restored session for \(user.userName ?? user.email) - district: \(user.districtId)")
            
            // Start auto-refresh immediately on session restore
            startTokenRefreshTimer()
            
            // Refresh token right now in case it expired while app was closed
            Task {
                await refreshAccessTokenSafe()
            }
        }
    }
    
    // MARK: - Sign In
    
    func signIn(email: String, password: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        
        do {
            // Step 1: Authenticate with Supabase Auth
            print("[AuthService] Step 1: Authenticating...")
            let authResponse = try await authenticateWithSupabase(email: email, password: password)
            print("[AuthService] Step 1 SUCCESS")
            
            // Store tokens
            UserDefaults.standard.set(authResponse.access_token, forKey: "supabase_access_token")
            UserDefaults.standard.set(authResponse.refresh_token, forKey: "supabase_refresh_token")
            
            // Step 2: Get district from district_users table (REQUIRED)
            print("[AuthService] Step 2: Fetching district assignment...")
            guard let districtUser = try await fetchDistrictUser(authResponse.user.id) else {
                errorMessage = "No district assigned to this account"
                isLoading = false
                return false
            }
            print("[AuthService] Step 2 SUCCESS - district_id: \(districtUser.districtId)")
            
            // Step 3: Fetch district name (OPTIONAL - nice to have)
            print("[AuthService] Step 3: Fetching district name...")
            var districtName: String? = nil
            do {
                districtName = try await fetchDistrictName(districtUser.districtId)
                print("[AuthService] Step 3 SUCCESS - \(districtName ?? "nil")")
            } catch {
                print("[AuthService] Step 3 FAILED (non-fatal): \(error)")
            }
            
            // Step 4: Create authenticated user
            let user = AuthenticatedUser(
                authUserId: authResponse.user.id,
                email: email,
                districtId: districtUser.districtId,
                districtName: districtName,
                role: districtUser.role,
                userName: districtUser.name
            )
            
            user.save()
            currentUser = user
            isAuthenticated = true
            isLoading = false
            consecutiveRefreshFailures = 0
            tokenRefreshFailing = false
            
            print("[AuthService] ✓ Signed in as \(districtUser.name ?? email) for \(districtName ?? "Unknown District")")
            
            // Start auto-refresh timer
            startTokenRefreshTimer()
            
            return true
            
        } catch let error as AuthError {
            errorMessage = error.message
            isLoading = false
            print("[AuthService] ✗ Sign in failed: \(error.message)")
            return false
        } catch {
            errorMessage = "An unexpected error occurred: \(error.localizedDescription)"
            isLoading = false
            print("[AuthService] ✗ Sign in failed: \(error)")
            return false
        }
    }
    
    // MARK: - Sign Out
    
    func signOut() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        consecutiveRefreshFailures = 0
        tokenRefreshFailing = false
        isRefreshing = false
        AuthenticatedUser.clear()
        currentUser = nil
        isAuthenticated = false
        print("[AuthService] Signed out")
    }
    
    // MARK: - Token Refresh (SAFE — network-aware, no sign-out on blips)
    
    /// Safe token refresh that checks network state and never signs out on transient errors.
    /// This is the method that should be called from lifecycle events and timers.
    func refreshAccessTokenSafe() async {
        // Don't attempt refresh if we know we're offline
        let network = NetworkMonitor.shared
        if !network.hasInternet {
            print("[AuthService] Skipping token refresh — no internet (connected=\(network.isConnected), FLO=\(network.isFLOWiFi))")
            return
        }
        
        // Don't attempt during network transitions — wait for stable state.
        // BUT: don't skip on app launch when NetworkMonitor just delivered its initial state.
        // The initial state delivery sets lastChangeDate, which would falsely trigger isTransitioning.
        // A real transition requires at least two path updates (initial + change).
        if network.hasReceivedInitialUpdate && network.isTransitioning(withinSeconds: 3.0) {
            // Extra safety: only skip if the transition is very recent (within 1.5s),
            // not just within the 3s window. This prevents stalling on launch.
            let timeSinceChange = Date().timeIntervalSince(network.lastChangeDate)
            if timeSinceChange < 1.5 {
                print("[AuthService] Skipping token refresh — network transitioning (\(String(format: "%.1f", timeSinceChange))s ago), will retry next cycle")
                return
            }
        }
        
        // Prevent concurrent refresh attempts
        guard !isRefreshing else {
            print("[AuthService] Refresh already in progress — skipping")
            return
        }
        
        isRefreshing = true
        defer { isRefreshing = false }
        
        guard let refreshToken = UserDefaults.standard.string(forKey: "supabase_refresh_token") else {
            print("[AuthService] No refresh token available — user must sign in again")
            return
        }
        
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10  // Don't wait forever
        
        let body = ["refresh_token": refreshToken]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[AuthService] Token refresh: no HTTP response")
                handleRefreshFailure(isNetworkError: true)
                return
            }
            
            // CRITICAL FIX: Only sign out on a CONFIRMED server rejection.
            // A real expired refresh token returns 400 with a specific error body.
            // A network blip during transition can also return 400/401 transiently.
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                // Parse the response body to confirm it's a real token rejection
                let isRealRejection = isConfirmedTokenRejection(data: data, statusCode: httpResponse.statusCode)
                
                if isRealRejection {
                    // The server explicitly told us the refresh token is invalid/expired.
                    // This is the ONLY case where we sign out automatically.
                    consecutiveRefreshFailures += 1
                    
                    // Require 2 consecutive confirmed rejections before signing out.
                    // This protects against a single transient server hiccup.
                    if consecutiveRefreshFailures >= 2 {
                        print("[AuthService] ⚠️ Refresh token confirmed expired (\(consecutiveRefreshFailures) consecutive failures) — signing out")
                        signOut()
                    } else {
                        print("[AuthService] ⚠️ Refresh token possibly expired (attempt \(consecutiveRefreshFailures)/2) — will retry")
                        tokenRefreshFailing = true
                        scheduleRetryRefresh()
                    }
                } else {
                    // Got a 400/401 but the body doesn't confirm token expiry.
                    // Treat as transient server error.
                    print("[AuthService] Token refresh got \(httpResponse.statusCode) but not a confirmed rejection — treating as transient")
                    handleRefreshFailure(isNetworkError: false)
                }
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                print("[AuthService] Token refresh failed: HTTP \(httpResponse.statusCode)")
                handleRefreshFailure(isNetworkError: false)
                return
            }
            
            let authResponse = try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
            
            // Store new tokens
            UserDefaults.standard.set(authResponse.access_token, forKey: "supabase_access_token")
            UserDefaults.standard.set(authResponse.refresh_token, forKey: "supabase_refresh_token")
            
            // Reset failure tracking on success
            consecutiveRefreshFailures = 0
            tokenRefreshFailing = false
            
            print("[AuthService] ✓ Token refreshed successfully")
            
        } catch is URLError {
            // Network-level error (timeout, DNS, connection refused, etc.)
            // This is DEFINITELY not a token rejection — never sign out here
            print("[AuthService] Token refresh network error — will retry (NOT signing out)")
            handleRefreshFailure(isNetworkError: true)
        } catch {
            print("[AuthService] Token refresh error: \(error) — will retry (NOT signing out)")
            handleRefreshFailure(isNetworkError: true)
        }
    }
    
    /// Legacy method — redirects to safe version.
    /// Kept for backward compatibility with any code calling the old method.
    func refreshAccessToken() async {
        await refreshAccessTokenSafe()
    }
    
    // MARK: - Refresh Failure Handling
    
    /// Determines if a 400/401 response is a CONFIRMED token rejection from Supabase,
    /// not just a transient server error during a network transition.
    private func isConfirmedTokenRejection(data: Data, statusCode: Int) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Can't parse response body — not a confirmed rejection
            return false
        }
        
        // Supabase returns specific error messages for expired/invalid refresh tokens:
        // - "Invalid Refresh Token: Already Used" (token replay)
        // - "Invalid Refresh Token: Expired" (token TTL exceeded)
        // - "invalid_grant" error code
        if let errorDesc = json["error_description"] as? String {
            let desc = errorDesc.lowercased()
            if desc.contains("invalid refresh token") || desc.contains("token is expired") {
                return true
            }
        }
        
        if let error = json["error"] as? String {
            if error == "invalid_grant" {
                return true
            }
        }
        
        if let msg = json["msg"] as? String {
            let m = msg.lowercased()
            if m.contains("invalid refresh token") || m.contains("token is expired") {
                return true
            }
        }
        
        // Got a 400/401 but no recognizable token-rejection message.
        // Could be a transient server issue. Don't treat as confirmed.
        return false
    }
    
    /// Handle a refresh failure — increment counter, schedule retry if needed
    private func handleRefreshFailure(isNetworkError: Bool) {
        if isNetworkError {
            // Network errors don't count toward the "confirmed rejection" counter.
            // But we still want to show the user something is wrong after a while.
            tokenRefreshFailing = true
        }
        scheduleRetryRefresh()
    }
    
    /// Schedule a retry with exponential backoff: 1 min, 2 min, 4 min, 8 min, 15 min cap
    private func scheduleRetryRefresh() {
        let backoffMinutes = min(pow(2.0, Double(consecutiveRefreshFailures)), maxBackoffMinutes)
        let delaySec = backoffMinutes * 60
        print("[AuthService] Scheduling retry refresh in \(backoffMinutes) min")
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            // Only retry if still authenticated and not already refreshing
            if isAuthenticated && !isRefreshing {
                await refreshAccessTokenSafe()
            }
        }
    }
    
    /// Starts a timer that refreshes the token every 45 minutes
    private func startTokenRefreshTimer() {
        refreshTimer?.invalidate()
        
        // Refresh every 45 minutes (tokens expire at 60 min)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 45 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAccessTokenSafe()
            }
        }
        
        print("[AuthService] Token refresh timer started (every 45 min)")
    }
    
    /// Call this from any service that gets a 401 response.
    /// Attempts one refresh, returns true if successful.
    func handleUnauthorized() async -> Bool {
        print("[AuthService] ⚠️ Got 401 — attempting token refresh...")
        await refreshAccessTokenSafe()
        
        // Check if we still have a valid token
        if accessToken != nil && isAuthenticated {
            print("[AuthService] ✓ Token refreshed — retry your request")
            return true
        } else {
            print("[AuthService] ✗ Token refresh failed — user must sign in again")
            return false
        }
    }
    
    // MARK: - Supabase Auth Request
    
    private func authenticateWithSupabase(email: String, password: String) async throws -> SupabaseAuthResponse {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=password") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.noResponse
        }
        
        if httpResponse.statusCode == 400 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = errorJson["error_description"] as? String ?? errorJson["msg"] as? String {
                throw AuthError.invalidCredentials(errorMsg)
            }
            throw AuthError.invalidCredentials("Invalid email or password")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AuthError.serverError(httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
    }
    
    // MARK: - Fetch District User
    
    private func fetchDistrictUser(_ authUserId: String) async throws -> (districtId: String, role: String?, name: String?)? {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/district_users?auth_user_id=eq.\(authUserId)&select=*") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[AuthService] district_users fetch failed with status: \(statusCode)")
            throw AuthError.fetchFailed
        }
        
        if let jsonString = String(data: data, encoding: .utf8) {
            print("[AuthService] district_users response: \(jsonString)")
        }
        
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let userJson = jsonArray.first else {
            print("[AuthService] No district_users record for auth_user_id: \(authUserId)")
            return nil
        }
        
        guard let districtId = userJson["district_id"] as? String else {
            print("[AuthService] district_users record missing district_id")
            throw AuthError.fetchFailed
        }
        
        let role = userJson["role"] as? String
        let name = userJson["name"] as? String
        
        return (districtId: districtId, role: role, name: name)
    }
    
    // MARK: - Fetch District Name
    
    private func fetchDistrictName(_ districtId: String) async throws -> String? {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/districts?id=eq.\(districtId)&select=id,name") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let jsonString = String(data: data, encoding: .utf8) {
            print("[AuthService] District response: \(jsonString)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AuthError.fetchFailed
        }
        
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let districtJson = jsonArray.first,
              let name = districtJson["name"] as? String else {
            return nil
        }
        
        return name
    }
}

// MARK: - Auth Errors

enum AuthError: Error {
    case invalidURL
    case noResponse
    case invalidCredentials(String)
    case serverError(Int)
    case fetchFailed
    case noTruckAssigned
    
    var message: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noResponse:
            return "No response from server"
        case .invalidCredentials(let msg):
            return msg
        case .serverError(let code):
            return "Server error (\(code))"
        case .fetchFailed:
            return "Failed to fetch account data"
        case .noTruckAssigned:
            return "No truck assigned to this account"
        }
    }
}
