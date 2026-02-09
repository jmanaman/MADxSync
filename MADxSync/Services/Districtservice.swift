//
//  DistrictService.swift
//  MADxSync
//
//  Single source of truth for district configuration.
//  Pulls district info and lookup values from Supabase.
//  No hardcoded district-specific data in the app.
//

import Foundation
import Combine

// MARK: - District Model

struct District: Codable {
    let id: String
    let name: String
    let subtitle: String?
    let headquarters: String?
    let address: String?
    let phone: String?
    let email: String?
    let website: String?
    let logo_base64: String?
    let primary_color: String?
    let created_at: String?
}

// MARK: - Lookup Value Model

struct LookupValue: Codable, Identifiable {
    let id: String
    let district_id: String
    let category: String
    let value: String
    let display_order: Int?
    let active: Bool?
}

// MARK: - District Service

@MainActor
class DistrictService: ObservableObject {
    
    static let shared = DistrictService()
    
    // MARK: - Published State
    
    @Published var currentDistrict: District?
    @Published var isLoaded: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // Lookup values by category
    @Published var zones: [String] = []
    @Published var habitats: [String] = []
    @Published var drainTypes: [String] = []
    @Published var priorities: [String] = []
    
    // MARK: - Configuration
    
    // For now, district ID is stored locally.
    // Future: This could come from user login, app config, or device assignment.
    private let districtIdKey = "current_district_id"
    
    // Default to Tulare MAD for initial setup
    // This should be set during onboarding or device provisioning
    private let defaultDistrictId = "2f05ab6e-dacb-4af5-b5d2-0156aa8b58ce"
    
    // Supabase config
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    // MARK: - Computed Properties
    
    /// Current district ID - comes from authenticated user
    var districtId: String {
        if let authDistrictId = AuthService.shared.districtId {
            return authDistrictId
        }
        // Fallback for testing only - should not happen in production
        print("[DistrictService] WARNING: No authenticated user, using fallback district_id")
        return UserDefaults.standard.string(forKey: districtIdKey) ?? defaultDistrictId
    }
    
    /// District name for display
    var districtName: String {
        currentDistrict?.name ?? "Loading..."
    }
    
    // MARK: - Init
    
    private init() {}
    
    // MARK: - Load District Data
    
    /// Load district info and all lookup values
    func loadDistrict() async {
        guard !isLoading else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // Load district info
            try await fetchDistrictInfo()
            
            // Load all lookup values
            try await fetchLookupValues()
            
            isLoaded = true
            print("[DistrictService] ✓ Loaded district: \(districtName)")
            print("[DistrictService]   Zones: \(zones)")
            print("[DistrictService]   Habitats: \(habitats)")
            print("[DistrictService]   Drain Types: \(drainTypes)")
            print("[DistrictService]   Priorities: \(priorities)")
            
        } catch {
            errorMessage = error.localizedDescription
            print("[DistrictService] ✗ Error loading district: \(error)")
        }
        
        isLoading = false
    }
    
    // MARK: - Fetch District Info
    
    private func fetchDistrictInfo() async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/districts?id=eq.\(districtId)&select=*") else {
            throw DistrictError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DistrictError.fetchFailed
        }
        
        let districts = try JSONDecoder().decode([District].self, from: data)
        
        guard let district = districts.first else {
            throw DistrictError.districtNotFound
        }
        
        currentDistrict = district
    }
    
    // MARK: - Fetch Lookup Values
    
    private func fetchLookupValues() async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/lookup_values?district_id=eq.\(districtId)&active=eq.true&select=*&order=display_order") else {
            throw DistrictError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DistrictError.fetchFailed
        }
        
        let values = try JSONDecoder().decode([LookupValue].self, from: data)
        
        // Sort into categories
        zones = values.filter { $0.category == "zone" }.map { $0.value }
        habitats = values.filter { $0.category == "habitat" }.map { $0.value }
        drainTypes = values.filter { $0.category == "drain_type" }.map { $0.value }
        priorities = values.filter { $0.category == "priority" }.map { $0.value }
    }
    
    // MARK: - Refresh
    
    /// Force refresh district data
    func refresh() async {
        isLoaded = false
        await loadDistrict()
    }
}

// MARK: - Errors

enum DistrictError: Error, LocalizedError {
    case invalidURL
    case fetchFailed
    case districtNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .fetchFailed: return "Failed to fetch district data"
        case .districtNotFound: return "District not found"
        }
    }
}
