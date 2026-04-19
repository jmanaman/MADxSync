//
//  MarkerHistoryService.swift
//  MADxSync
//
//  Pulls treatment marker history from Supabase app_markers table, caches locally.
//  Powers the "Treatment History" section in the feature popup (mirrors Hub parity).
//
//  ARCHITECTURE:
//  - Mirrors TreatmentStatusService pattern exactly: disk cache, delta sync,
//    token-refresh 401 handling, network guard.
//  - Pull window: 90 days rolling, limit 2000 rows. First load is a full fetch;
//    subsequent syncs pull only markers newer than lastMarkerSync.
//  - In-memory filter by feature_id at popup-open time — matches Hub's in-memory
//    filter pattern from layers.js::findTreatmentHistory.
//  - UNDO rows and their targets are filtered out at load time (matches Hub
//    api.js::getAppMarkers undo-filter logic).
//
//  SAFETY:
//  - Read-only from this app's perspective. Does not write to app_markers
//    (marker writes continue to go through FieldMarkerModel as before).
//  - Does not mutate any schema. Purely additive feature.
//  - Graceful degradation: any fetch failure leaves existing cache intact;
//    popup renders normally with whatever history is cached, or nothing if empty.
//

import Foundation
import Combine

// MARK: - App Marker Model
// Maps 1:1 to the app_markers table columns we care about for history display.
// All optional fields match the SQL schema exactly — any missing column on
// older markers is handled as nil without breaking decode.

struct AppMarker: Codable, Identifiable {
    let id: String
    let timestamp_iso: String
    let truck_id: String?
    let user_name: String?
    let marker_type: String          // TREATMENT, SPOT_TREAT, OBSERVED, LARVAE, PUPAE, DIP, NOTE, UNDO, etc.
    let family: String?
    let status: String?              // TREATED, OBSERVED
    let chemical: String?
    let dose_value: Double?
    let dose_unit: String?
    let larvae_level: String?
    let pupae_present: Bool?
    let notes: String?
    let feature_id: String?
    let feature_type: String?
    let application_method: String?
    let products_json: String?
    let lat: Double
    let lon: Double

    // UNDO fields — used to filter out undone markers
    let undo_target_timestamp: String?

    // Stable identity for lists
    var stableId: String { id }
}

// MARK: - Product entry (parsed from products_json or flat fields)

struct MarkerProduct: Codable {
    let chemical: String
    let dose_value: Double?
    let dose_unit: String?
}

// MARK: - Service

@MainActor
class MarkerHistoryService: ObservableObject {
    static let shared = MarkerHistoryService()

    // MARK: - Published State

    /// All cached markers, newest first. Popup filters this in-memory by feature_id.
    @Published var markers: [AppMarker] = []
    @Published var isLoading = false
    @Published var lastSync: Date?
    @Published var lastError: String?

    // MARK: - Configuration

    /// How far back to pull markers. 90 days ~= 12 cycles at a 7-day cadence —
    /// enough to show meaningful history without bloating the cache on phones.
    private let historyWindowDays: Int = 90

    /// Safety cap on a single fetch. At typical marker rates this is ~6 seasons
    /// of data for a mid-sized district — we should never hit it in practice.
    private let fetchLimit: Int = 2000

    private let supabaseURL = SupabaseConfig.url
    private let supabaseKey = SupabaseConfig.publishableKey

    // Cache
    private let cacheKeyLastSync = "marker_history_last_sync"
    private let cacheDir: URL

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheDir = docs.appendingPathComponent("marker_history_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadFromCache()
    }

    // MARK: - Public: History Lookup

    /// Return up to `limit` markers matching this feature_id, newest first.
    /// Matches Hub behavior in layers.js::findTreatmentHistory: filters to
    /// treatment-family markers only, excludes notes and breadcrumb events.
    func historyForFeature(_ featureId: String, limit: Int = 10) -> [AppMarker] {
        let allowedTypes: Set<String> = [
            "TREATMENT", "SPOT_TREAT", "OBSERVED", "LARVAE", "PUPAE", "DIP"
        ]

        let matches = markers.filter { m in
            guard allowedTypes.contains(m.marker_type) else { return false }
            return m.feature_id == featureId
        }

        // Already newest-first from storage, but belt-and-suspenders:
        let sorted = matches.sorted { ($0.timestamp_iso) > ($1.timestamp_iso) }
        return Array(sorted.prefix(limit))
    }

    /// Parse products from a marker. Mirrors utils.js::parseProducts priority order:
    ///   1. products_json (multi-product)
    ///   2. flat chemical + dose_value + dose_unit (single product)
    ///   3. empty
    func productsForMarker(_ m: AppMarker) -> [MarkerProduct] {
        if let json = m.products_json, let data = json.data(using: .utf8) {
            if let parsed = try? JSONDecoder().decode([MarkerProduct].self, from: data), !parsed.isEmpty {
                return parsed
            }
        }
        if let chem = m.chemical, !chem.isEmpty {
            return [MarkerProduct(chemical: chem, dose_value: m.dose_value, dose_unit: m.dose_unit)]
        }
        return []
    }

    // MARK: - Sync from Supabase

    /// Pull markers from Supabase into the local cache.
    /// - If `since` is nil: full window pull (historyWindowDays back).
    /// - If `since` is an ISO timestamp: conditional pull (only newer markers).
    func syncFromHub(since: String? = nil, retryCount: Int = 0) async {
        // Network guard — don't fire a doomed request when offline
        guard NetworkMonitor.shared.hasInternet else {
            print("[MarkerHistory] Sync skipped — no internet, using cached data (\(markers.count) markers)")
            isLoading = false
            return
        }

        isLoading = true
        lastError = nil

        guard let districtId = AuthService.shared.districtId else {
            lastError = "No district ID"
            isLoading = false
            return
        }

        // Build URL — multi-tenant isolation via district_id=eq.X (defense in depth alongside RLS)
        var urlString = "\(supabaseURL)/rest/v1/app_markers?district_id=eq.\(districtId)"
        urlString += "&order=timestamp_iso.desc"
        urlString += "&limit=\(fetchLimit)"

        if let since = since {
            // Delta pull: only markers newer than last sync
            let encoded = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? since
            urlString += "&timestamp_iso=gt.\(encoded)"
        } else {
            // Full pull: last N days
            let windowStart = Date().addingTimeInterval(-Double(historyWindowDays) * 86400)
            let formatter = ISO8601DateFormatter()
            let iso = formatter.string(from: windowStart)
            let encoded = iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso
            urlString += "&timestamp_iso=gte.\(encoded)"
        }

        guard let url = URL(string: urlString) else {
            lastError = "Invalid URL"
            isLoading = false
            return
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
                lastError = "No response"
                isLoading = false
                return
            }

            // 401 — attempt token refresh, retry once
            if httpResponse.statusCode == 401 {
                if retryCount < 1 {
                    let refreshed = await AuthService.shared.handleUnauthorized()
                    if refreshed {
                        isLoading = false
                        await syncFromHub(since: since, retryCount: retryCount + 1)
                        return
                    }
                } else {
                    print("[MarkerHistory] ⚠️ 401 persists after token refresh — not retrying")
                }
                lastError = "Authentication failed"
                isLoading = false
                return
            }

            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                lastError = "HTTP \(httpResponse.statusCode)"
                print("[MarkerHistory] Error: \(httpResponse.statusCode) - \(body)")
                isLoading = false
                return
            }

            let decoder = JSONDecoder()
            let fetched: [AppMarker]
            do {
                fetched = try decoder.decode([AppMarker].self, from: data)
            } catch {
                // Decode failure: log and leave cache untouched (graceful degradation)
                lastError = "Decode error: \(error.localizedDescription)"
                print("[MarkerHistory] Decode failed: \(error)")
                isLoading = false
                return
            }

            let isConditional = since != nil

            if isConditional {
                if fetched.isEmpty {
                    // Nothing new — keep existing cache, just advance timestamp
                    lastSync = Date()
                    UserDefaults.standard.set(lastSync, forKey: cacheKeyLastSync)
                    isLoading = false
                    return
                }
                // Delta merge: dedupe on id, sort, drop anything older than window
                mergeMarkers(fetched)
                print("[MarkerHistory] Delta sync: +\(fetched.count) markers (total \(markers.count))")
            } else {
                // Full replace
                markers = filterAndSort(fetched)
                print("[MarkerHistory] Full sync: \(markers.count) markers (after undo filter)")
            }

            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: cacheKeyLastSync)
            saveToCache()

        } catch {
            // Network-level failure: leave cache intact
            lastError = error.localizedDescription
            print("[MarkerHistory] Sync error: \(error)")
        }

        isLoading = false
    }

    // MARK: - Merge & Filter Helpers

    /// Merge new markers into existing cache: dedupe on id, re-apply UNDO filter,
    /// drop anything outside the rolling window, re-sort newest first.
    private func mergeMarkers(_ incoming: [AppMarker]) {
        var byId: [String: AppMarker] = [:]
        for m in markers { byId[m.id] = m }
        for m in incoming { byId[m.id] = m }

        let combined = Array(byId.values)
        markers = filterAndSort(combined)
    }

    /// Apply UNDO filter + window trim + sort newest-first.
    /// Mirrors Hub api.js::getAppMarkers undo-filter logic:
    ///   - exclude rows with marker_type == UNDO
    ///   - exclude rows whose timestamp matches an UNDO's undo_target_timestamp
    private func filterAndSort(_ input: [AppMarker]) -> [AppMarker] {
        // Normalize ISO timestamps to millis for comparison (matches Hub logic)
        func normalize(_ ts: String?) -> Int64? {
            guard let ts = ts else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: ts) { return Int64(d.timeIntervalSince1970 * 1000) }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            if let d = f2.date(from: ts) { return Int64(d.timeIntervalSince1970 * 1000) }
            return nil
        }

        var undoTargets = Set<Int64>()
        var undoRecordIds = Set<String>()
        for m in input where m.marker_type == "UNDO" {
            undoRecordIds.insert(m.id)
            if let tsMillis = normalize(m.undo_target_timestamp) {
                undoTargets.insert(tsMillis)
            }
        }

        // Window cutoff — drop anything older than historyWindowDays
        let cutoff = Date().addingTimeInterval(-Double(historyWindowDays) * 86400)
        let cutoffMillis = Int64(cutoff.timeIntervalSince1970 * 1000)

        let filtered = input.filter { m in
            if undoRecordIds.contains(m.id) { return false }
            if let tsMillis = normalize(m.timestamp_iso) {
                if undoTargets.contains(tsMillis) { return false }
                if tsMillis < cutoffMillis { return false }
            }
            return true
        }

        return filtered.sorted { $0.timestamp_iso > $1.timestamp_iso }
    }

    // MARK: - Cache Persistence

    private func saveToCache() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(markers) {
            try? data.write(to: cacheDir.appendingPathComponent("markers.json"), options: .atomic)
        }
    }

    private func loadFromCache() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("markers.json")),
           let cached = try? decoder.decode([AppMarker].self, from: data) {
            // Re-filter on load in case the window advanced while app was closed
            markers = filterAndSort(cached)
        }
        if let date = UserDefaults.standard.object(forKey: cacheKeyLastSync) as? Date {
            lastSync = date
        }
        print("[MarkerHistory] Loaded from cache: \(markers.count) markers")
    }

    // MARK: - Utilities for Popup Display

    /// Resolve a truck_id (compound identifier like "T14-POS01" or legacy UUID)
    /// into a human-readable equipment name. Mirrors Hub ui.js::resolveEquipmentName.
    static func resolveEquipmentName(_ truckId: String?) -> String {
        guard let truckId = truckId, !truckId.isEmpty else { return "Unknown" }

        // Compound identifier format: "CODE-POS" or just "CODE"
        let parts = truckId.split(separator: "-", maxSplits: 1).map(String.init)
        let equipmentCode = parts.first ?? truckId

        // Look up by short_code in EquipmentService
        if let eq = EquipmentService.shared.equipment.first(where: { $0.shortCode == equipmentCode }) {
            return eq.displayName
        }
        // Fallback: show the code itself
        return equipmentCode
    }

    /// Resolve the operator portion of a compound identifier into a readable name.
    /// Returns nil if there's no operator portion (legacy UUID or equipment-only).
    static func resolveOperatorName(_ truckId: String?) -> String? {
        guard let truckId = truckId, truckId.contains("-") else { return nil }
        let parts = truckId.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let positionCode = parts[1]

        if let pos = PositionService.shared.positions.first(where: { $0.shortCode == positionCode }) {
            return pos.displayLabel
        }
        return positionCode
    }

    /// Format a timestamp for history display (matches Hub formatDate).
    static func formatHistoryDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? {
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: iso)
        }()
        guard let date = date else { return iso }

        let df = DateFormatter()
        df.dateFormat = "MMM d, h:mm a"
        return df.string(from: date)
    }

    /// Classify a marker into a display type + color (mirrors Hub logic in layers.js).
    /// Returns (typeLabel, hexColor).
    static func classifyMarker(_ m: AppMarker) -> (String, String) {
        switch m.marker_type {
        case "TREATMENT", "SPOT_TREAT":
            return ("Treated", "#4CAF50")
        case "OBSERVED":
            return ("Observed", "#FFA726")
        case "PUPAE":
            return ("Pupae", "#06b6d4")
        case "LARVAE":
            // Standalone "pupae-only" case vs normal inspection
            if (m.larvae_level ?? "none") == "none" && (m.pupae_present ?? false) {
                return ("Pupae", "#06b6d4")
            }
            return ("Inspection", "#42a5f5")
        case "DIP":
            return ("Dip", "#42a5f5")
        default:
            return (m.marker_type, "#888888")
        }
    }
}
