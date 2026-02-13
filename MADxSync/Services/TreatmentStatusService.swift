//
//  TreatmentStatusService.swift
//  MADxSync
//
//  Pulls treatment status from Supabase (written by Hub), caches locally.
//  Handles optimistic local updates when a tech treats a feature in the app.
//
//  The Hub computes all treatment status (point-in-polygon, TRS matching,
//  days-since calculations) and writes results to the treatment_status table.
//  This service just reads that table and mirrors what the Hub shows.
//
//  HARDENED: 2026-02-09 — Network guard on syncFromHub, skips when offline.
//

import Foundation
import Combine

// MARK: - Treatment Status Model

struct HubTreatmentStatus: Codable, Identifiable {
    let id: String?                // Supabase row ID (optional)
    let feature_id: String
    let feature_type: String       // "field", "polyline", "pointsite", "stormdrain"
    let color: String              // Hex color from Hub: #00ff88, #ffff00, #ffa500, #ff4444, #ff0000
    let days_since: Int?           // Days since last treatment, null = never
    let last_treated: String?      // ISO timestamp
    let last_treated_by: String?   // Technician or truck name
    let last_chemical: String?     // Chemical used
    let cycle_days: Int            // Treatment cycle (default 7)
    let status_text: String        // "Just Treated", "3 days ago", "OVERDUE", "Never Treated"
    let updated_at: String?        // When Hub last updated this row
}

// MARK: - Treatment Colors (matches Hub CONFIG.COLORS exactly)

struct TreatmentColors {
    static let fresh   = "#00ff88"   // Green - just treated
    static let recent  = "#ffff00"   // Yellow - approaching due
    static let aging   = "#ffa500"   // Orange - almost due
    static let overdue = "#ff4444"   // Red - overdue
    static let never   = "#ff0000"   // Red - never treated
    
    static let fillOpacity: Float = 0.5
}

// MARK: - Service

@MainActor
class TreatmentStatusService: ObservableObject {
    static let shared = TreatmentStatusService()
    
    // MARK: - Published State
    
    /// Status lookup: feature_id → HubTreatmentStatus
    @Published var statusByFeature: [String: HubTreatmentStatus] = [:]
    
    /// Local optimistic overrides (tech treated something, not yet synced to Hub)
    @Published var localOverrides: [String: LocalTreatment] = [:]
    
    /// Version counter - increments on every status change (local treatment, sync, etc.)
    /// Used by map coordinator to detect when overlays need rebuilding.
    @Published var statusVersion: Int = 0
    
    @Published var isLoading = false
    @Published var lastSync: Date?
    @Published var lastError: String?
    
    // MARK: - Configuration
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    // Cache keys
    private let cacheKeyStatus = "treatment_status_cache"
    private let cacheKeyOverrides = "treatment_local_overrides"
    private let cacheKeyLastSync = "treatment_last_sync"
    private let cacheDir: URL
    
    // MARK: - Pending Cycle Updates (offline queue)
    
    /// Queued cycle updates waiting for network
    private var pendingCycleUpdates: [PendingCycleUpdate] = []
    
    struct PendingCycleUpdate: Codable {
        let featureId: String
        let featureType: String
        let cycleDays: Int
        let queuedAt: Date
    }

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheDir = docs.appendingPathComponent("treatment_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        migrateFromUserDefaults()
        loadFromCache()
        loadPendingCycleUpdates()
    }
    
    // MARK: - Get Effective Color for a Feature
    
    /// Returns the display color for a feature, considering local overrides
    func colorForFeature(_ featureId: String) -> String {
        // Local override takes priority (optimistic update)
        if let local = localOverrides[featureId] {
            // Check if local override has aged out (Hub should have picked it up by now)
            let hoursSinceOverride = Date().timeIntervalSince(local.treatedAt) / 3600
            if hoursSinceOverride < 24 {
                // Still fresh local override - show as green
                return TreatmentColors.fresh
            } else {
                // Override is old, remove it and fall through to Hub status
                localOverrides.removeValue(forKey: featureId)
                saveOverridesToCache()
            }
        }
        
        // Hub status
        if let status = statusByFeature[featureId] {
            return status.color
        }
        
        // No status at all = never treated = red
        return TreatmentColors.never
    }
    
    /// Returns the full status info for a feature (for popup display)
    func statusForFeature(_ featureId: String) -> FeatureStatusInfo {
        // Local override
        if let local = localOverrides[featureId] {
            let hoursSince = Date().timeIntervalSince(local.treatedAt) / 3600
            if hoursSince < 24 {
                return FeatureStatusInfo(
                    color: TreatmentColors.fresh,
                    statusText: "Just Treated (pending sync)",
                    daysSince: 0,
                    lastTreated: local.treatedAt,
                    lastTreatedBy: local.technician,
                    lastChemical: local.chemical,
                    cycleDays: local.cycleDays,
                    isLocalOverride: true
                )
            }
        }
        
        // Hub status
        if let status = statusByFeature[featureId] {
            return FeatureStatusInfo(
                color: status.color,
                statusText: status.status_text,
                daysSince: status.days_since,
                lastTreated: status.last_treated.flatMap { ISO8601DateFormatter().date(from: $0) },
                lastTreatedBy: status.last_treated_by,
                lastChemical: status.last_chemical,
                cycleDays: status.cycle_days,
                isLocalOverride: false
            )
        }
        
        // Never treated
        return FeatureStatusInfo(
            color: TreatmentColors.never,
            statusText: "Never Treated",
            daysSince: nil,
            lastTreated: nil,
            lastTreatedBy: nil,
            lastChemical: nil,
            cycleDays: 7,
            isLocalOverride: false
        )
    }
    
    // MARK: - Optimistic Local Treatment
    
    /// Call when a tech treats a feature in the app.
    /// Immediately marks it green locally, queues sync to Hub.
    func markTreatedLocally(
        featureId: String,
        featureType: String,
        chemical: String?,
        technician: String? = nil,
        cycleDays: Int = 7
    ) {
        let treatment = LocalTreatment(
            featureId: featureId,
            featureType: featureType,
            treatedAt: Date(),
            chemical: chemical,
            technician: technician,
            cycleDays: cycleDays,
            syncedToHub: false
        )
        
        localOverrides[featureId] = treatment
        statusVersion += 1  // Trigger map overlay rebuild
        saveOverridesToCache()
        
        print("[TreatmentStatus] Local override: \(featureId) → green (v\(statusVersion))")
    }
    
    /// Revert a local treatment (undo accidental tap).
    /// Removes the local override so the feature returns to its Hub status (or red/never).
    func revertLocalTreatment(featureId: String) {
        guard localOverrides.removeValue(forKey: featureId) != nil else { return }
        statusVersion += 1  // Trigger map overlay rebuild
        saveOverridesToCache()
        
        print("[TreatmentStatus] Reverted local override: \(featureId) (v\(statusVersion))")
    }
    
    // MARK: - Sync from Supabase
    
    /// Pull treatment_status table from Supabase.
    /// HARDENED: Skips network request when offline — uses cached data instead.
    func syncFromHub() async {
        // Network guard — don't fire a doomed request when offline
        guard NetworkMonitor.shared.hasInternet else {
            print("[TreatmentStatus] Sync skipped — no internet, using cached data (\(statusByFeature.count) statuses)")
            isLoading = false
            return
        }
        
        isLoading = true
        lastError = nil
        
        guard let districtId = AuthService.shared.districtId,
              let url = URL(string: "\(supabaseURL)/rest/v1/treatment_status?district_id=eq.\(districtId)&select=*") else {
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
            
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 406 {
                // Table doesn't exist yet - that's OK, Hub hasn't been updated yet
                print("[HubTreatmentStatus] treatment_status table not found - Hub hasn't published yet")
                lastSync = Date()
                isLoading = false
                return
            }
            
            // Handle 401 — attempt token refresh
            if httpResponse.statusCode == 401 {
                let refreshed = await AuthService.shared.handleUnauthorized()
                if refreshed {
                    isLoading = false
                    await syncFromHub()  // Retry with fresh token
                    return
                }
                lastError = "Authentication failed"
                isLoading = false
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                lastError = "HTTP \(httpResponse.statusCode)"
                print("[HubTreatmentStatus] Error: \(httpResponse.statusCode) - \(body)")
                isLoading = false
                return
            }
            
            let decoder = JSONDecoder()
            let statuses = try decoder.decode([HubTreatmentStatus].self, from: data)
            
            // Build lookup dictionary
            var lookup: [String: HubTreatmentStatus] = [:]
            for status in statuses {
                lookup[status.feature_id] = status
            }
            
            statusByFeature = lookup
            lastSync = Date()
            saveToCache()
            
            // Clear local overrides that the Hub has now picked up
            cleanupOverrides()
            
            statusVersion += 1  // Trigger map overlay rebuild
            
            print("[TreatmentStatus] Synced \(statuses.count) feature statuses from Hub (v\(statusVersion))")
            
            // Push any pending cycle updates after successful sync
            await pushPendingCycleUpdates()
            
        } catch {
            lastError = error.localizedDescription
            print("[HubTreatmentStatus] Sync error: \(error)")
        }
        
        isLoading = false
    }
    
    // MARK: - Push Local Treatments to Supabase
    
    /// Push pending local treatments to viewer_logs so Hub can process them
    func pushLocalTreatments() async {
        // Network guard
        guard NetworkMonitor.shared.hasInternet else {
            print("[TreatmentStatus] Push skipped — no internet")
            return
        }
        
        let pending = localOverrides.values.filter { !$0.syncedToHub }
        guard !pending.isEmpty else { return }
        
        for treatment in pending {
            let success = await pushTreatmentToViewerLogs(treatment)
            if success {
                localOverrides[treatment.featureId]?.syncedToHub = true
            }
        }
        
        saveOverridesToCache()
        print("[HubTreatmentStatus] Pushed \(pending.count) local treatments to viewer_logs")
    }
    
    private func pushTreatmentToViewerLogs(_ treatment: LocalTreatment) async -> Bool {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/viewer_logs") else { return false }
        
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: treatment.treatedAt)
        
        let payload: [String: Any] = [
            "timestamp_iso": timestamp,
            "action": "FIELD_TREAT,family=FIELD,status=TREATED,chemical=\(treatment.chemical ?? "Unknown")",
            "header": treatment.featureId,
            "subheader": treatment.featureType,
            "lat": 0,  // Will be populated by Hub from feature geometry
            "lon": 0,
            "gallons": 0,
            "ounces": 0,
            "psi": 0,
            "mix": treatment.chemical ?? "",
            "relays": "",
            "truck_id": ""  // App doesn't have truck_id context
        ]
        
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 201
            }
            return false
        } catch {
            print("[HubTreatmentStatus] Push error: \(error)")
            return false
        }
    }
    
    // MARK: - Cleanup
    
    /// Remove local overrides where Hub status is now fresher
    private func cleanupOverrides() {
        var removed = 0
        for (featureId, local) in localOverrides {
            if let hubStatus = statusByFeature[featureId],
               let hubDate = hubStatus.last_treated,
               let hubTimestamp = ISO8601DateFormatter().date(from: hubDate) {
                // Hub has a treatment newer than or equal to our local one
                if hubTimestamp >= local.treatedAt {
                    localOverrides.removeValue(forKey: featureId)
                    removed += 1
                }
            }
        }
        if removed > 0 {
            saveOverridesToCache()
            print("[HubTreatmentStatus] Cleaned up \(removed) local overrides (Hub caught up)")
        }
    }
    
    // MARK: - Cache
    
    /// One-time migration: move treatment cache from UserDefaults to file storage
    private func migrateFromUserDefaults() {
        guard UserDefaults.standard.data(forKey: cacheKeyStatus) != nil else {
            return
        }
        
        print("[HubTreatmentStatus] Migrating cache from UserDefaults to file storage...")
        
        if let data = UserDefaults.standard.data(forKey: cacheKeyStatus) {
            try? data.write(to: cacheDir.appendingPathComponent("statuses.json"), options: .atomic)
            UserDefaults.standard.removeObject(forKey: cacheKeyStatus)
        }
        
        if let data = UserDefaults.standard.data(forKey: cacheKeyOverrides) {
            try? data.write(to: cacheDir.appendingPathComponent("overrides.json"), options: .atomic)
            UserDefaults.standard.removeObject(forKey: cacheKeyOverrides)
        }
        
        print("[HubTreatmentStatus] ✓ Migrated treatment cache to file storage")
    }
    
    private func saveToCache() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(Array(statusByFeature.values)) {
            try? data.write(to: cacheDir.appendingPathComponent("statuses.json"), options: .atomic)
        }
        if let date = lastSync {
            UserDefaults.standard.set(date, forKey: cacheKeyLastSync)
        }
    }
    
    private func saveOverridesToCache() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(localOverrides) {
            try? data.write(to: cacheDir.appendingPathComponent("overrides.json"), options: .atomic)
        }
    }
    
    private func loadFromCache() {
        let decoder = JSONDecoder()
        
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("statuses.json")),
           let statuses = try? decoder.decode([HubTreatmentStatus].self, from: data) {
            var lookup: [String: HubTreatmentStatus] = [:]
            for status in statuses {
                lookup[status.feature_id] = status
            }
            statusByFeature = lookup
        }
        
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("overrides.json")),
           let overrides = try? decoder.decode([String: LocalTreatment].self, from: data) {
            localOverrides = overrides
        }
        
        if let date = UserDefaults.standard.object(forKey: cacheKeyLastSync) as? Date {
            lastSync = date
        }
        
        print("[HubTreatmentStatus] Loaded from cache: \(statusByFeature.count) statuses, \(localOverrides.count) local overrides")
    }
    
    // MARK: - Cycle Days Update (Push-Off)

    /// Update the treatment cycle for a source.
    /// Writes to source_notes table (same table Hub reads).
    /// Optimistically updates local cache so map colors change immediately.
    func updateCycleDays(
        featureId: String,
        featureType: String,
        cycleDays: Int
    ) async -> Bool {
        // 1. Optimistic local update — map color changes immediately
        if var status = statusByFeature[featureId] {
            // Rebuild the status with new cycle_days
            let updated = HubTreatmentStatus(
                id: status.id,
                feature_id: status.feature_id,
                feature_type: status.feature_type,
                color: recalculateColor(daysSince: status.days_since, cycleDays: cycleDays),
                days_since: status.days_since,
                last_treated: status.last_treated,
                last_treated_by: status.last_treated_by,
                last_chemical: status.last_chemical,
                cycle_days: cycleDays,
                status_text: recalculateStatusText(daysSince: status.days_since, cycleDays: cycleDays),
                updated_at: ISO8601DateFormatter().string(from: Date())
            )
            statusByFeature[featureId] = updated
        } else {
            // Source has never been treated — only set the cycle, don't fake an observation.
            // Source stays red (Never Treated) until a real treatment/observed marker is dropped.
            // The cycle will activate once the first real treatment is logged.
            let newStatus = HubTreatmentStatus(
                id: nil,
                feature_id: featureId,
                feature_type: featureType,
                color: TreatmentColors.never,
                days_since: nil,
                last_treated: nil,
                last_treated_by: nil,
                last_chemical: nil,
                cycle_days: cycleDays,
                status_text: "Never Treated",
                updated_at: ISO8601DateFormatter().string(from: Date())
            )
            statusByFeature[featureId] = newStatus
        }
        
        statusVersion += 1  // Trigger map overlay rebuild
        saveToCache()
        
        print("[TreatmentStatus] Cycle updated: \(featureId) → \(cycleDays) days (v\(statusVersion))")
        
        // 2. Write to source_notes in Supabase (same table Hub reads)
        guard NetworkMonitor.shared.hasInternet else {
            print("[TreatmentStatus] Cycle update queued — no internet, saved locally")
            // Queue for later sync
            queueCycleUpdate(featureId: featureId, featureType: featureType, cycleDays: cycleDays)
            return true  // Local update succeeded
        }
        
        let success = await writeCycleDaysToSupabase(
            featureId: featureId,
            featureType: featureType,
            cycleDays: cycleDays
        )
        
        if !success {
            // Network write failed — queue for retry
            queueCycleUpdate(featureId: featureId, featureType: featureType, cycleDays: cycleDays)
            print("[TreatmentStatus] Supabase write failed — queued for retry")
        }
        
        return true  // Local update always succeeds
    }

    /// Write cycle days to source_notes table in Supabase.
    /// This is the same table the Hub reads via SourceNotes.getPushOffDays().
    private func writeCycleDaysToSupabase(
        featureId: String,
        featureType: String,
        cycleDays: Int
    ) async -> Bool {
        guard let districtId = AuthService.shared.districtId else { return false }
        
        // Map iOS feature types to Hub source_notes types
        let sourceType = mapFeatureTypeToSourceType(featureType)
        
        guard let url = URL(string: "\(supabaseURL)/rest/v1/source_notes") else { return false }
        
        let payload: [String: Any] = [
            "district_id": districtId,
            "source_type": sourceType,
            "source_id": featureId,
            "push_off_days": cycleDays,
            "created_by": "app"
        ]
        
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Upsert: update if exists, insert if new
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let success = httpResponse.statusCode == 200 || httpResponse.statusCode == 201
                if success {
                    print("[TreatmentStatus] ✓ Wrote cycle_days=\(cycleDays) for \(featureId) to source_notes")
                }
                return success
            }
            return false
        } catch {
            print("[TreatmentStatus] source_notes write error: \(error)")
            return false
        }
    }

    /// Map iOS feature_type strings to Hub source_notes source_type strings
    private func mapFeatureTypeToSourceType(_ featureType: String) -> String {
        switch featureType.lowercased() {
        case "field": return "polygon"
        case "polyline": return "polyline"
        case "pointsite": return "pointsite"
        case "stormdrain": return "pointsite"  // Storm drains use pointsite in source_notes
        default: return featureType
        }
    }

    // MARK: - Proportional Color Calculation (matches Hub)

    /// Recalculate color using proportional thresholds — MUST match Hub's Utils.getTreatmentColor
    private func recalculateColor(daysSince: Int?, cycleDays: Int) -> String {
        guard let days = daysSince else { return TreatmentColors.never }
        
        let cycle = max(cycleDays, 1)
        let greenEnd = Int(Double(cycle) * 0.60)
        let yellowEnd = Int(Double(cycle) * 0.80)
        
        if days <= greenEnd { return TreatmentColors.fresh }
        if days <= yellowEnd { return TreatmentColors.recent }
        if days <= cycle { return TreatmentColors.aging }
        return TreatmentColors.overdue
    }

    /// Recalculate status text — MUST match Hub's Utils.getTreatmentStatus
    private func recalculateStatusText(daysSince: Int?, cycleDays: Int) -> String {
        guard let days = daysSince else { return "Never Treated" }
        
        let cycle = max(cycleDays, 1)
        let greenEnd = Int(Double(cycle) * 0.60)
        let yellowEnd = Int(Double(cycle) * 0.80)
        let daysUntilDue = max(0, cycle - days)
        
        if days <= 1 { return "Just Treated" }
        if days <= greenEnd { return "\(days) days ago" }
        if days <= yellowEnd { return "\(days) days ago (due in \(daysUntilDue)d)" }
        if days <= cycle { return "\(days) days ago (due in \(daysUntilDue)d)" }
        let overdue = days - cycle
        return "OVERDUE by \(overdue)d (\(days)d ago)"
    }

    private func queueCycleUpdate(featureId: String, featureType: String, cycleDays: Int) {
        // Remove any existing pending update for this feature
        pendingCycleUpdates.removeAll { $0.featureId == featureId }
        
        pendingCycleUpdates.append(PendingCycleUpdate(
            featureId: featureId,
            featureType: featureType,
            cycleDays: cycleDays,
            queuedAt: Date()
        ))
        
        savePendingCycleUpdates()
    }

    /// Push any pending cycle updates to Supabase. Call this when network comes back.
    func pushPendingCycleUpdates() async {
        guard NetworkMonitor.shared.hasInternet else { return }
        guard !pendingCycleUpdates.isEmpty else { return }
        
        var remaining: [PendingCycleUpdate] = []
        
        for update in pendingCycleUpdates {
            let success = await writeCycleDaysToSupabase(
                featureId: update.featureId,
                featureType: update.featureType,
                cycleDays: update.cycleDays
            )
            if !success {
                remaining.append(update)
            }
        }
        
        pendingCycleUpdates = remaining
        savePendingCycleUpdates()
        
        if remaining.isEmpty {
            print("[TreatmentStatus] ✓ All pending cycle updates pushed")
        } else {
            print("[TreatmentStatus] \(remaining.count) cycle updates still pending")
        }
    }

    private func savePendingCycleUpdates() {
        if let data = try? JSONEncoder().encode(pendingCycleUpdates) {
            try? data.write(to: cacheDir.appendingPathComponent("pending_cycle_updates.json"), options: .atomic)
        }
    }

    private func loadPendingCycleUpdates() {
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("pending_cycle_updates.json")),
           let updates = try? JSONDecoder().decode([PendingCycleUpdate].self, from: data) {
            pendingCycleUpdates = updates
            if !updates.isEmpty {
                print("[TreatmentStatus] Loaded \(updates.count) pending cycle updates")
            }
        }
    }
}

// MARK: - Feature Status Info (for display)

struct FeatureStatusInfo {
    let color: String
    let statusText: String
    let daysSince: Int?
    let lastTreated: Date?
    let lastTreatedBy: String?
    let lastChemical: String?
    let cycleDays: Int
    let isLocalOverride: Bool
    
    var formattedLastTreated: String {
        guard let date = lastTreated else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Local Treatment (optimistic update, pending sync)

struct LocalTreatment: Codable {
    let featureId: String
    let featureType: String
    let treatedAt: Date
    let chemical: String?
    let technician: String?
    let cycleDays: Int
    var syncedToHub: Bool
}
