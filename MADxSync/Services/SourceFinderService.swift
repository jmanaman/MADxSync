//
//  SourceFinderService.swift
//  MADxSync
//
//  Manages Source Finder pins — pulls from Supabase (created by management in the HUB),
//  persists locally for offline access, and pushes status updates back when techs
//  mark pins as inspected/resolved.
//
//  Pattern: Pull-and-cache (reverse of AddSourceService which is push-from-app).
//  Integrates with HubSyncService's 60-second poll cycle.
//
//  RELIABILITY:
//  - Atomic disk writes (write to temp, rename)
//  - Graceful offline: serves cached data, queues updates for later
//  - No data loss on crash — pending updates persist to disk
//  - Silent failure — console logging only, never blocks UI
//

import Foundation
import Combine
import CoreLocation

@MainActor
final class SourceFinderService: ObservableObject {
    
    static let shared = SourceFinderService()
    
    // MARK: - Published State
    
    /// All active Source Finder pins (pending + inspected, not resolved/expired)
    @Published var pins: [SourceFinderPin] = []
    
    /// Pins that arrived since last banner display (triggers shout-out toast)
    @Published var newPinsForBanner: [SourceFinderPin] = []
    
    // MARK: - Configuration
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    private let requestTimeout: TimeInterval = 15.0
    
    // MARK: - Local Storage
    
    private let pinsFileURL: URL
    private let pendingUpdatesFileURL: URL
    private let shownBannerIdsFileURL: URL
    
    /// IDs of pins whose shout-out banner has already been shown
    private var shownBannerIds: Set<String> = []
    
    /// Queued status updates that haven't been pushed to Supabase yet
    private var pendingUpdates: [PendingStatusUpdate] = []
    
    // MARK: - Init
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        pinsFileURL = docs.appendingPathComponent("source_finder_pins.json")
        pendingUpdatesFileURL = docs.appendingPathComponent("source_finder_pending_updates.json")
        shownBannerIdsFileURL = docs.appendingPathComponent("source_finder_shown_banners.json")
        
        loadPinsFromDisk()
        loadPendingUpdatesFromDisk()
        loadShownBannerIds()
    }
    
    // MARK: - Pull from Supabase (called by HubSyncService)
    
    /// Fetch active Source Finder pins from Supabase. Called every 60s by HubSyncService.
    func pullFromHub() async {
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else {
            return }
        
        // 1. Try to push any queued status updates first
        await drainPendingUpdates()
        
        // 2. Pull fresh pins
        do {
            let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
            let urlString = "\(supabaseURL)/rest/v1/source_finder_pins?district_id=eq.\(districtId)&or=(status.eq.pending,and(status.eq.inspected,inspected_at.gte.\(today)))&order=created_at.desc&select=*"
            guard let url = URL(string: urlString) else { return }
            
            let data = try await authenticatedGET(url: url)
            
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                print("[SourceFinder] Invalid JSON response")
                return
            }
            
            let remotePins = jsonArray.compactMap { SourceFinderPin.fromJSON($0) }
            
            
            // 3. Detect new pins for banner (compare against what we've already shown)
            let newForBanner = remotePins.filter { pin in
                pin.isPending && !shownBannerIds.contains(pin.id) && pin.shoutOut != nil && !pin.shoutOut!.isEmpty
            }
            
            for pin in newForBanner {
                shownBannerIds.insert(pin.id)
            }
            if !newForBanner.isEmpty {
                saveShownBannerIds()
            }
            
            // 4. Atomic swap — preserve local hasBeenShownAsBanner state
            var updated = remotePins
            for i in updated.indices {
                if shownBannerIds.contains(updated[i].id) {
                    updated[i].hasBeenShownAsBanner = true
                }
            }
            
            pins = updated
            savePinsToDisk()
            
            // 5. Fire banner for new pins
            if !newForBanner.isEmpty {
                newPinsForBanner = newForBanner
                print("[SourceFinder] \(newForBanner.count) new pin(s) with shout-out — banner queued")
            }
            
        } catch {
            // Fail silently — cached pins remain available
            print("[SourceFinder] Pull failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Mark Pin as Inspected (Tech Action)
    
    /// Tech has visited and inspected the source. Updates status and queues sync.
    func markInspected(pinId: String, findings: String?, recommendPermanent: Bool) {
        // 1. Update local state immediately (optimistic)
        if let index = pins.firstIndex(where: { $0.id == pinId }) {
            pins[index].status = "inspected"
            pins[index].inspectedBy = AuthService.shared.currentUser?.email
                ?? TruckService.shared.selectedTruckName
                ?? "tech"
            pins[index].inspectedAt = Date()
            pins[index].techFindings = findings
            pins[index].recommendedPermanent = recommendPermanent
            
            // Calculate expiry if not recommending permanent
            if !recommendPermanent {
                let days = pins[index].pushOffDays
                pins[index].expiresAt = Calendar.current.date(byAdding: .day, value: days, to: Date())
            }
            
            savePinsToDisk()
        }
        
        // 2. Queue the update for Supabase
        let update = PendingStatusUpdate(
            pinId: pinId,
            status: "inspected",
            inspectedBy: AuthService.shared.currentUser?.email
                ?? TruckService.shared.selectedTruckName
                ?? "tech",
            inspectedAt: Date(),
            techFindings: findings,
            recommendedPermanent: recommendPermanent,
            expiresAt: recommendPermanent ? nil : Calendar.current.date(byAdding: .day, value: 7, to: Date())
        )
        pendingUpdates.append(update)
        savePendingUpdatesToDisk()
        
        // 3. Try to push immediately
        Task { await drainPendingUpdates() }
        
        print("[SourceFinder] Pin \(pinId.prefix(8)) marked inspected (recommend permanent: \(recommendPermanent))")
    }
    
    // MARK: - Mark Banner as Shown
    
    
    /// Clear all shown banner IDs (for new session, testing, etc.)
    func clearBannerHistory() {
        shownBannerIds.removeAll()
        saveShownBannerIds()
    }
    
    // MARK: - Push Pending Updates to Supabase
    
    /// Attempt to push all queued status updates. Called on each sync cycle
    /// and immediately after a tech marks a pin.
    private func drainPendingUpdates() async {
        guard !pendingUpdates.isEmpty else { return }
        
        var remaining: [PendingStatusUpdate] = []
        
        for update in pendingUpdates {
            do {
                try await pushStatusUpdate(update)
            } catch {
                // Keep for retry on next cycle
                remaining.append(update)
                print("[SourceFinder] Update push failed for \(update.pinId.prefix(8)): \(error.localizedDescription)")
            }
        }
        
        pendingUpdates = remaining
        savePendingUpdatesToDisk()
    }
    
    /// Push a single status update to Supabase via PATCH
    private func pushStatusUpdate(_ update: PendingStatusUpdate) async throws {
        let urlString = "\(supabaseURL)/rest/v1/source_finder_pins?id=eq.\(update.pinId)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        var body: [String: Any] = [
            "status": update.status,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        
        if let by = update.inspectedBy { body["inspected_by"] = by }
        if let at = update.inspectedAt { body["inspected_at"] = ISO8601DateFormatter().string(from: at) }
        if let findings = update.techFindings { body["tech_findings"] = findings }
        body["recommended_permanent"] = update.recommendedPermanent
        if let expires = update.expiresAt { body["expires_at"] = ISO8601DateFormatter().string(from: expires) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
    }
    
    // MARK: - Authenticated GET (matches HubSyncService pattern)
    
    private func authenticatedGET(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        
        return data
    }
    
    // MARK: - Disk Persistence (Atomic Writes)
    
    private func savePinsToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(pins)
            try atomicWrite(data: data, to: pinsFileURL)
        } catch {
            print("[SourceFinder] ⚠️ Failed to save pins: \(error)")
        }
    }
    
    private func loadPinsFromDisk() {
        do {
            let data = try Data(contentsOf: pinsFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            pins = try decoder.decode([SourceFinderPin].self, from: data)
            print("[SourceFinder] Loaded \(pins.count) cached pins from disk")
        } catch {
            pins = []
        }
    }
    
    private func savePendingUpdatesToDisk() {
        do {
            let data = try JSONEncoder().encode(pendingUpdates)
            try atomicWrite(data: data, to: pendingUpdatesFileURL)
        } catch {
            print("[SourceFinder] ⚠️ Failed to save pending updates: \(error)")
        }
    }
    
    private func loadPendingUpdatesFromDisk() {
        do {
            let data = try Data(contentsOf: pendingUpdatesFileURL)
            pendingUpdates = try JSONDecoder().decode([PendingStatusUpdate].self, from: data)
            if !pendingUpdates.isEmpty {
                print("[SourceFinder] \(pendingUpdates.count) pending update(s) queued from last session")
            }
        } catch {
            pendingUpdates = []
        }
    }
    
    private func saveShownBannerIds() {
        do {
            let data = try JSONEncoder().encode(Array(shownBannerIds))
            try atomicWrite(data: data, to: shownBannerIdsFileURL)
        } catch {
            print("[SourceFinder] ⚠️ Failed to save banner IDs: \(error)")
        }
    }
    
    private func loadShownBannerIds() {
        do {
            let data = try Data(contentsOf: shownBannerIdsFileURL)
            let ids = try JSONDecoder().decode([String].self, from: data)
            shownBannerIds = Set(ids)
        } catch {
            shownBannerIds = []
        }
    }
    
    /// Write to temp file first, then atomic rename — no data loss on crash
    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: tempURL, options: .atomic)
        
        // Remove existing file if present, then rename temp
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tempURL, to: url)
    }
    
    // MARK: - Convenience
    
    /// Count of pending (unserviced) pins — used for badges
    var pendingCount: Int {
        pins.filter { $0.isPending }.count
    }
    
    /// All pending pins sorted by priority (urgent first)
    var pendingPinsSorted: [SourceFinderPin] {
        pins.filter { $0.isPending }.sorted { lhs, rhs in
            let priorityOrder = ["urgent": 0, "normal": 1, "low": 2]
            return (priorityOrder[lhs.priority] ?? 1) < (priorityOrder[rhs.priority] ?? 1)
        }
    }
}

// MARK: - Pending Status Update (queued for Supabase push)

struct PendingStatusUpdate: Codable {
    let pinId: String
    let status: String
    let inspectedBy: String?
    let inspectedAt: Date?
    let techFindings: String?
    let recommendedPermanent: Bool
    let expiresAt: Date?
}
