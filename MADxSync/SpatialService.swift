//
//  SpatialService.swift
//  MADxSync
//
//  Fetches spatial data from Supabase with local caching
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
    private let districtId = "tulare_mad"
    
    // MARK: - Cache Keys
    private let cacheKeyBoundaries = "spatial_boundaries"
    private let cacheKeyFields = "spatial_fields"
    private let cacheKeyPolylines = "spatial_polylines"
    private let cacheKeyPointSites = "spatial_pointsites"
    private let cacheKeyStormDrains = "spatial_stormdrains"
    private let cacheKeyLastSync = "spatial_last_sync"
    
    init() {
        loadFromCache()
    }
    
    // MARK: - Load All Layers
    
    func loadAllLayers() async {
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
    
    // MARK: - Caching
    
    private func saveToCache() {
        let encoder = JSONEncoder()
        
        if let data = try? encoder.encode(boundaries) {
            UserDefaults.standard.set(data, forKey: cacheKeyBoundaries)
        }
        if let data = try? encoder.encode(fields) {
            UserDefaults.standard.set(data, forKey: cacheKeyFields)
        }
        if let data = try? encoder.encode(polylines) {
            UserDefaults.standard.set(data, forKey: cacheKeyPolylines)
        }
        if let data = try? encoder.encode(pointSites) {
            UserDefaults.standard.set(data, forKey: cacheKeyPointSites)
        }
        if let data = try? encoder.encode(stormDrains) {
            UserDefaults.standard.set(data, forKey: cacheKeyStormDrains)
        }
        if let lastSync = lastSync {
            UserDefaults.standard.set(lastSync, forKey: cacheKeyLastSync)
        }
        
        print("[SpatialService] Saved to cache")
    }
    
    private func loadFromCache() {
        let decoder = JSONDecoder()
        
        if let data = UserDefaults.standard.data(forKey: cacheKeyBoundaries),
           let decoded = try? decoder.decode([DistrictBoundary].self, from: data) {
            boundaries = decoded
        }
        if let data = UserDefaults.standard.data(forKey: cacheKeyFields),
           let decoded = try? decoder.decode([FieldPolygon].self, from: data) {
            fields = decoded
        }
        if let data = UserDefaults.standard.data(forKey: cacheKeyPolylines),
           let decoded = try? decoder.decode([SpatialPolyline].self, from: data) {
            polylines = decoded
        }
        if let data = UserDefaults.standard.data(forKey: cacheKeyPointSites),
           let decoded = try? decoder.decode([PointSite].self, from: data) {
            pointSites = decoded
        }
        if let data = UserDefaults.standard.data(forKey: cacheKeyStormDrains),
           let decoded = try? decoder.decode([StormDrain].self, from: data) {
            stormDrains = decoded
        }
        if let date = UserDefaults.standard.object(forKey: cacheKeyLastSync) as? Date {
            lastSync = date
        }
        
        print("[SpatialService] Loaded from cache: \(boundaries.count) boundaries, \(fields.count) fields, \(polylines.count) polylines, \(pointSites.count) point sites, \(stormDrains.count) storm drains")
    }
    
    // MARK: - Clear Cache
    
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKeyBoundaries)
        UserDefaults.standard.removeObject(forKey: cacheKeyFields)
        UserDefaults.standard.removeObject(forKey: cacheKeyPolylines)
        UserDefaults.standard.removeObject(forKey: cacheKeyPointSites)
        UserDefaults.standard.removeObject(forKey: cacheKeyStormDrains)
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
