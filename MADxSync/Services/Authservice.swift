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
//  - Login gives you district_id → truck picker shows trucks in that district
//  - Tech picks their truck, can switch anytime in Settings
//
//  BULLETPROOFED: 2026-02-06
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
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    var districtId: String? { currentUser?.districtId }
    var accessToken: String? { UserDefaults.standard.string(forKey: "supabase_access_token") }
    
    private init() {
        if let user = AuthenticatedUser.load() {
            self.currentUser = user
            self.isAuthenticated = true
            print("[AuthService] Restored session for \(user.userName ?? user.email) - district: \(user.districtId)")
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
            
            // Step 3: Fetch district name (OPTIONAL — nice to have)
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
            
            print("[AuthService] ✓ Signed in as \(districtUser.name ?? email) for \(districtName ?? "Unknown District")")
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
        AuthenticatedUser.clear()
        currentUser = nil
        isAuthenticated = false
        print("[AuthService] Signed out")
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
    // Queries district_users table to find which district this auth user belongs to
    
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
