//
//  SpatialService.swift
//  MADxSync
//
//  Fetches spatial data from Supabase with local caching
//
//  HARDENED: 2026-02-09 — Network guard on loadAllLayers, skips when offline.
//

import Foundation
import Combine

@MainActor
class SpatialService: ObservableObject {
    static let shared = SpatialService()
    
    // MARK: - Published Data
    @Published var boundaries: [DistrictBoundary] = []
    @Published var fields: [FieldPolygon] = []
    @Published var polylines: [SpatialPolyline] = []
    @Published var pointSites: [PointSite] = []
    @Published var stormDrains: [StormDrain] = []
    
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var lastSync: Date?
    
    // MARK: - Configuration
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    private var districtId: String {
        AuthService.shared.districtId ?? ""
    }
    
    // MARK: - Cache Keys
    private let cacheKeyBoundaries = "spatial_boundaries"
    private let cacheKeyFields = "spatial_fields"
    private let cacheKeyPolylines = "spatial_polylines"
    private let cacheKeyPointSites = "spatial_pointsites"
    private let cacheKeyStormDrains = "spatial_stormdrains"
    private let cacheKeyLastSync = "spatial_last_sync"
    private let cacheDir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheDir = docs.appendingPathComponent("spatial_cache", isDirectory: true)
        
        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        migrateFromUserDefaults()
        loadFromCache()
    }
    
    // MARK: - Load All Layers
    
    func loadAllLayers() async {
        // Network guard — don't fire doomed requests when offline.
        // Cached data is already loaded in init(), so the map still has features.
        guard NetworkMonitor.shared.hasInternet else {
            print("[SpatialService] Load skipped — no internet, using cached data (\(totalFeatures) features)")
            return
        }
        
        isLoading = true
        lastError = nil
        
        async let b = fetchBoundaries()
        async let f = fetchFields()
        async let p = fetchPolylines()
        async let ps = fetchPointSites()
        async let sd = fetchStormDrains()
        
        let results = await (b, f, p, ps, sd)
        
        // Check for errors
        let errors = [results.0.1, results.1.1, results.2.1, results.3.1, results.4.1].compactMap { $0 }
        if !errors.isEmpty {
            lastError = errors.first
        }
        
        // Update data
        if !results.0.0.isEmpty { boundaries = results.0.0 }
        if !results.1.0.isEmpty { fields = results.1.0 }
        if !results.2.0.isEmpty { polylines = results.2.0 }
        if !results.3.0.isEmpty { pointSites = results.3.0 }
        if !results.4.0.isEmpty { stormDrains = results.4.0 }
        
        lastSync = Date()
        saveToCache()
        
        isLoading = false
        
        print("[SpatialService] Loaded: \(boundaries.count) boundaries, \(fields.count) fields, \(polylines.count) polylines, \(pointSites.count) point sites, \(stormDrains.count) storm drains")
    }
    
    // MARK: - Individual Fetch Methods
    
    func fetchBoundaries() async -> ([DistrictBoundary], String?) {
        await fetchFromSupabase(
            table: "district_boundaries",
            type: [DistrictBoundary].self
        )
    }
    
    func fetchFields() async -> ([FieldPolygon], String?) {
        await fetchFromSupabase(
            table: "field_polygons",
            type: [FieldPolygon].self
        )
    }
    
    func fetchPolylines() async -> ([SpatialPolyline], String?) {
        await fetchFromSupabase(
            table: "polylines",
            type: [SpatialPolyline].self
        )
    }
    
    func fetchPointSites() async -> ([PointSite], String?) {
        await fetchFromSupabase(
            table: "point_sites",
            type: [PointSite].self
        )
    }
    
    func fetchStormDrains() async -> ([StormDrain], String?) {
        await fetchFromSupabase(
            table: "storm_drains",
            type: [StormDrain].self
        )
    }
    
    // MARK: - Generic Supabase Fetch
    
    private func fetchFromSupabase<T: Decodable>(table: String, type: T.Type) async -> (T, String?) where T: Collection {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/\(table)?district_id=eq.\(districtId)&select=*") else {
            return ([] as! T, "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return ([] as! T, "No response")
            }
            
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("[SpatialService] Error fetching \(table): \(httpResponse.statusCode) - \(body)")
                return ([] as! T, "HTTP \(httpResponse.statusCode)")
            }
            
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(type, from: data)
            return (decoded, nil)
            
        } catch {
            print("[SpatialService] Fetch error for \(table): \(error)")
            return ([] as! T, error.localizedDescription)
        }
    }
    
    /// One-time migration: move spatial cache from UserDefaults to file storage
    private func migrateFromUserDefaults() {
        // Check if legacy data exists
        guard UserDefaults.standard.data(forKey: cacheKeyBoundaries) != nil else {
            return  // Nothing to migrate
        }
        
        print("[SpatialService] Migrating cache from UserDefaults to file storage...")
        
        let migrations: [(String, String)] = [
            (cacheKeyBoundaries, "boundaries.json"),
            (cacheKeyFields, "fields.json"),
            (cacheKeyPolylines, "polylines.json"),
            (cacheKeyPointSites, "pointsites.json"),
            (cacheKeyStormDrains, "stormdrains.json")
        ]
        
        for (key, filename) in migrations {
            if let data = UserDefaults.standard.data(forKey: key) {
                try? data.write(to: cacheDir.appendingPathComponent(filename), options: .atomic)
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        
        print("[SpatialService] ✓ Migrated spatial cache to file storage")
    }
    
    // MARK: - Caching
    
    private func saveToCache() {
        let encoder = JSONEncoder()
        
        func writeCache<T: Encodable>(_ items: T, filename: String) {
            if let data = try? encoder.encode(items) {
                try? data.write(to: cacheDir.appendingPathComponent(filename), options: .atomic)
            }
        }
        
        writeCache(boundaries, filename: "boundaries.json")
        writeCache(fields, filename: "fields.json")
        writeCache(polylines, filename: "polylines.json")
        writeCache(pointSites, filename: "pointsites.json")
        writeCache(stormDrains, filename: "stormdrains.json")
        
        // lastSync is tiny — fine in UserDefaults
        if let lastSync = lastSync {
            UserDefaults.standard.set(lastSync, forKey: cacheKeyLastSync)
        }
        
        print("[SpatialService] Saved to cache")
    }
    
    private func loadFromCache() {
        let decoder = JSONDecoder()
        
        func readCache<T: Decodable>(_ type: T.Type, filename: String) -> T? {
            guard let data = try? Data(contentsOf: cacheDir.appendingPathComponent(filename)) else { return nil }
            return try? decoder.decode(type, from: data)
        }
        
        boundaries = readCache([DistrictBoundary].self, filename: "boundaries.json") ?? []
        fields = readCache([FieldPolygon].self, filename: "fields.json") ?? []
        polylines = readCache([SpatialPolyline].self, filename: "polylines.json") ?? []
        pointSites = readCache([PointSite].self, filename: "pointsites.json") ?? []
        stormDrains = readCache([StormDrain].self, filename: "stormdrains.json") ?? []
        
        if let date = UserDefaults.standard.object(forKey: cacheKeyLastSync) as? Date {
            lastSync = date
        }
        
        print("[SpatialService] Loaded from cache: \(boundaries.count) boundaries, \(fields.count) fields, \(polylines.count) polylines, \(pointSites.count) point sites, \(stormDrains.count) storm drains")
    }
    
    // MARK: - Clear Cache
    
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: cacheKeyLastSync)
        
        boundaries = []
        fields = []
        polylines = []
        pointSites = []
        stormDrains = []
        lastSync = nil
        
        print("[SpatialService] Cache cleared")
    }
    
    // MARK: - Status
    
    var totalFeatures: Int {
        boundaries.count + fields.count + polylines.count + pointSites.count + stormDrains.count
    }
    
    var hasData: Bool {
        totalFeatures > 0
    }
    
    var cacheAge: String? {
        guard let lastSync = lastSync else { return nil }
        
        let interval = Date().timeIntervalSince(lastSync)
        
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}
