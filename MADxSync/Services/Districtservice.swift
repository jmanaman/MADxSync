//
//  DistrictService.swift
//  MADxSync
//
//  Single source of truth for district configuration.
//  Pulls district info and lookup values from Supabase.
//  No hardcoded district-specific data in the app.
//
//  HARDENED: 2026-02-09 — File-based caching (matches SpatialService pattern),
//  offline support, network-aware fetching, retry logic.
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

// MARK: - Cached District Data (single file for atomic read/write)

private struct DistrictCache: Codable {
    let district: District
    let lookupValues: [LookupValue]
    let cachedAt: Date
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
    @Published var isUsingCache: Bool = false
    
    // Lookup values by category
    @Published var zones: [String] = []
    @Published var habitats: [String] = []
    @Published var drainTypes: [String] = []
    @Published var priorities: [String] = []
    
    // MARK: - Configuration
    
    private let districtIdKey = "current_district_id"
    private let defaultDistrictId = "2f05ab6e-dacb-4af5-b5d2-0156aa8b58ce"
    
    // Supabase config
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    // Cache
    private let cacheDir: URL
    private let cacheFilename = "district_cache.json"
    
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
    
    /// District name for display — never returns "Loading..." if cache exists
    var districtName: String {
        currentDistrict?.name ?? (isLoading ? "Loading..." : "Unknown District")
    }
    
    // MARK: - Init
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheDir = docs.appendingPathComponent("district_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        // Load from cache immediately on init — so district name is available instantly
        loadFromCache()
    }
    
    // MARK: - Load District Data
    
    /// Load district info and all lookup values.
    /// Uses cache if offline, fetches from network if available.
    func loadDistrict() async {
        guard !isLoading else { return }
        
        isLoading = true
        errorMessage = nil
        
        // Check network before attempting fetch
        let network = NetworkMonitor.shared
        
        if !network.hasInternet {
            // No internet — use cache if available
            if isLoaded {
                print("[DistrictService] No internet — using cached data")
                isUsingCache = true
                isLoading = false
                return
            } else {
                // Try loading from cache
                loadFromCache()
                if isLoaded {
                    print("[DistrictService] No internet — loaded from disk cache")
                    isUsingCache = true
                    isLoading = false
                    return
                } else {
                    errorMessage = "No internet and no cached district data"
                    isLoading = false
                    return
                }
            }
        }
        
        do {
            // Load district info
            try await fetchDistrictInfo()
            
            // Load all lookup values
            try await fetchLookupValues()
            
            isLoaded = true
            isUsingCache = false
            
            // Save to cache on successful fetch
            saveToCache()
            
            print("[DistrictService] ✓ Loaded district: \(districtName)")
            print("[DistrictService]   Zones: \(zones)")
            print("[DistrictService]   Habitats: \(habitats)")
            print("[DistrictService]   Drain Types: \(drainTypes)")
            print("[DistrictService]   Priorities: \(priorities)")
            
        } catch {
            errorMessage = error.localizedDescription
            print("[DistrictService] ✗ Error loading district: \(error)")
            
            // Fall back to cache on network failure
            if !isLoaded {
                loadFromCache()
                if isLoaded {
                    print("[DistrictService] Fell back to cached data after fetch error")
                    isUsingCache = true
                    errorMessage = nil  // Clear error — cache has data
                }
            }
        }
        
        isLoading = false
    }
    
    // MARK: - Fetch District Info
    
    private func fetchDistrictInfo() async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/districts?id=eq.\(districtId)&select=*") else {
            throw DistrictError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DistrictError.fetchFailed
        }
        
        // Handle 401 — attempt token refresh
        if httpResponse.statusCode == 401 {
            let refreshed = await AuthService.shared.handleUnauthorized()
            if refreshed {
                // Retry with new token
                try await fetchDistrictInfo()
                return
            }
            throw DistrictError.fetchFailed
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
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
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DistrictError.fetchFailed
        }
        
        // Handle 401
        if httpResponse.statusCode == 401 {
            let refreshed = await AuthService.shared.handleUnauthorized()
            if refreshed {
                try await fetchLookupValues()
                return
            }
            throw DistrictError.fetchFailed
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw DistrictError.fetchFailed
        }
        
        let values = try JSONDecoder().decode([LookupValue].self, from: data)
        
        // Sort into categories
        zones = values.filter { $0.category == "zone" }.map { $0.value }
        habitats = values.filter { $0.category == "habitat" }.map { $0.value }
        drainTypes = values.filter { $0.category == "drain_type" }.map { $0.value }
        priorities = values.filter { $0.category == "priority" }.map { $0.value }
    }
    
    // MARK: - Caching (matches SpatialService pattern)
    
    private func saveToCache() {
        guard let district = currentDistrict else { return }
        
        // Reconstruct lookup values from categorized arrays for cache
        // We store the raw district + lookup values, not the categorized arrays
        let allLookups = buildLookupValuesForCache()
        
        let cache = DistrictCache(
            district: district,
            lookupValues: allLookups,
            cachedAt: Date()
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        if let data = try? encoder.encode(cache) {
            let cacheFile = cacheDir.appendingPathComponent(cacheFilename)
            try? data.write(to: cacheFile, options: .atomic)
            print("[DistrictService] Saved to cache")
        }
    }
    
    private func loadFromCache() {
        let cacheFile = cacheDir.appendingPathComponent(cacheFilename)
        
        guard let data = try? Data(contentsOf: cacheFile) else { return }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let cache = try? decoder.decode(DistrictCache.self, from: data) else {
            print("[DistrictService] Cache decode failed — clearing stale cache")
            clearCache()
            return
        }
        
        currentDistrict = cache.district
        
        // Restore categorized arrays from cached lookup values
        let values = cache.lookupValues
        zones = values.filter { $0.category == "zone" }.map { $0.value }
        habitats = values.filter { $0.category == "habitat" }.map { $0.value }
        drainTypes = values.filter { $0.category == "drain_type" }.map { $0.value }
        priorities = values.filter { $0.category == "priority" }.map { $0.value }
        
        isLoaded = true
        
        let age = cacheAge
        print("[DistrictService] Loaded from cache: \(cache.district.name) (cached \(age ?? "unknown") ago)")
    }
    
    /// Build a flat array of LookupValue for caching from the categorized string arrays.
    /// Since we only store the value strings, we reconstruct minimal LookupValue objects.
    private func buildLookupValuesForCache() -> [LookupValue] {
        var result: [LookupValue] = []
        let did = districtId
        
        for (i, z) in zones.enumerated() {
            result.append(LookupValue(id: "cache_zone_\(i)", district_id: did, category: "zone", value: z, display_order: i, active: true))
        }
        for (i, h) in habitats.enumerated() {
            result.append(LookupValue(id: "cache_habitat_\(i)", district_id: did, category: "habitat", value: h, display_order: i, active: true))
        }
        for (i, d) in drainTypes.enumerated() {
            result.append(LookupValue(id: "cache_drain_\(i)", district_id: did, category: "drain_type", value: d, display_order: i, active: true))
        }
        for (i, p) in priorities.enumerated() {
            result.append(LookupValue(id: "cache_priority_\(i)", district_id: did, category: "priority", value: p, display_order: i, active: true))
        }
        
        return result
    }
    
    // MARK: - Cache Management
    
    func clearCache() {
        let cacheFile = cacheDir.appendingPathComponent(cacheFilename)
        try? FileManager.default.removeItem(at: cacheFile)
        print("[DistrictService] Cache cleared")
    }
    
    var cacheAge: String? {
        let cacheFile = cacheDir.appendingPathComponent(cacheFilename)
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(DistrictCache.self, from: data) else { return nil }
        
        let interval = Date().timeIntervalSince(cache.cachedAt)
        
        if interval < 60 { return "Just now" }
        else if interval < 3600 { return "\(Int(interval / 60))m" }
        else if interval < 86400 { return "\(Int(interval / 3600))h" }
        else { return "\(Int(interval / 86400))d" }
    }
    
    // MARK: - Refresh
    
    /// Force refresh district data from network
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
