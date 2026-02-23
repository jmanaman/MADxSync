//
//  ServiceRequestService.swift
//  MADxSync
//
//  Manages Service Request pins — pulls from Supabase (created by management in the HUB),
//  persists locally for offline access, and pushes status updates back when techs
//  mark requests as inspected/resolved.
//
//  Pattern: Pull-and-cache (identical to SourceFinderService).
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
final class ServiceRequestService: ObservableObject {
    
    static let shared = ServiceRequestService()
    
    // MARK: - Published State
    
    /// All active Service Request pins (pending + inspected, not resolved/expired)
    @Published var requests: [ServiceRequestPin] = []
    
    /// Requests that arrived since last banner display (triggers shout-out toast)
    @Published var newRequestsForBanner: [ServiceRequestPin] = []
    
    // MARK: - Configuration
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    private let requestTimeout: TimeInterval = 15.0
    
    // MARK: - Local Storage
    
    private let requestsFileURL: URL
    private let pendingUpdatesFileURL: URL
    private let shownBannerIdsFileURL: URL
    
    /// IDs of requests whose shout-out banner has already been shown
    private var shownBannerIds: Set<String> = []
    
    /// Queued status updates that haven't been pushed to Supabase yet
    private var pendingUpdates: [SRPendingStatusUpdate] = []
    
    // MARK: - Init
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        requestsFileURL = docs.appendingPathComponent("service_requests.json")
        pendingUpdatesFileURL = docs.appendingPathComponent("service_requests_pending_updates.json")
        shownBannerIdsFileURL = docs.appendingPathComponent("service_requests_shown_banners.json")
        
        loadRequestsFromDisk()
        loadPendingUpdatesFromDisk()
        loadShownBannerIds()
    }
    
    // MARK: - Pull from Supabase (called by HubSyncService)
    
    /// Fetch active Service Requests from Supabase. Called every 60s by HubSyncService.
    func pullFromHub() async {
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else {
            return
        }
        
        // 1. Try to push any queued status updates first
        await drainPendingUpdates()
        
        // 2. Pull fresh requests
        do {
            let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
            let urlString = "\(supabaseURL)/rest/v1/service_requests?district_id=eq.\(districtId)&or=(status.eq.pending,and(status.eq.inspected,inspected_at.gte.\(today)))&order=created_at.desc&select=*"
            guard let url = URL(string: urlString) else { return }
            
            let data = try await authenticatedGET(url: url)
            
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                print("[ServiceRequests] Invalid JSON response")
                return
            }
            
            let remoteRequests = jsonArray.compactMap { ServiceRequestPin.fromJSON($0) }
            
            // 3. Detect new requests for banner (compare against what we've already shown)
            let newForBanner = remoteRequests.filter { req in
                req.isPending && !shownBannerIds.contains(req.id) && req.shoutOut != nil && !req.shoutOut!.isEmpty
            }
            
            for req in newForBanner {
                shownBannerIds.insert(req.id)
            }
            if !newForBanner.isEmpty {
                saveShownBannerIds()
            }
            
            // 4. Atomic swap — preserve local hasBeenShownAsBanner state
            var updated = remoteRequests
            for i in updated.indices {
                if shownBannerIds.contains(updated[i].id) {
                    updated[i].hasBeenShownAsBanner = true
                }
            }
            
            requests = updated
            saveRequestsToDisk()
            
            // 5. Fire banner for new requests
            if !newForBanner.isEmpty {
                newRequestsForBanner = newForBanner
                print("[ServiceRequests] \(newForBanner.count) new request(s) with shout-out — banner queued")
            }
            
        } catch {
            // Fail silently — cached requests remain available
            print("[ServiceRequests] Pull failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Mark Request as Inspected (Tech Action)
    
    /// Tech has visited and inspected the source. Updates status and queues sync.
    func markInspected(requestId: String, findings: String?, recommendPermanent: Bool) {
        // 1. Update local state immediately (optimistic)
        if let index = requests.firstIndex(where: { $0.id == requestId }) {
            requests[index].status = "inspected"
            requests[index].inspectedBy = AuthService.shared.currentUser?.email
                ?? TruckService.shared.selectedTruckName
                ?? "tech"
            requests[index].inspectedAt = Date()
            requests[index].techFindings = findings
            requests[index].recommendedPermanent = recommendPermanent
            
            // Calculate expiry if not recommending permanent
            if !recommendPermanent {
                let days = requests[index].pushOffDays
                requests[index].expiresAt = Calendar.current.date(byAdding: .day, value: days, to: Date())
            }
            
            saveRequestsToDisk()
        }
        
        // 2. Queue the update for Supabase
        let update = SRPendingStatusUpdate(
            requestId: requestId,
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
        
        print("[ServiceRequests] Request \(requestId.prefix(8)) marked inspected (recommend permanent: \(recommendPermanent))")
    }
    
    // MARK: - Mark Banner as Shown
    
    /// Clear all shown banner IDs (for new session, testing, etc.)
    func clearBannerHistory() {
        shownBannerIds.removeAll()
        saveShownBannerIds()
    }
    
    // MARK: - Push Pending Updates to Supabase
    
    /// Attempt to push all queued status updates. Called on each sync cycle
    /// and immediately after a tech marks a request.
    private func drainPendingUpdates() async {
        guard !pendingUpdates.isEmpty else { return }
        
        var remaining: [SRPendingStatusUpdate] = []
        
        for update in pendingUpdates {
            do {
                try await pushStatusUpdate(update)
            } catch {
                // Keep for retry on next cycle
                remaining.append(update)
                print("[ServiceRequests] Update push failed for \(update.requestId.prefix(8)): \(error.localizedDescription)")
            }
        }
        
        pendingUpdates = remaining
        savePendingUpdatesToDisk()
    }
    
    /// Push a single status update to Supabase via PATCH
    private func pushStatusUpdate(_ update: SRPendingStatusUpdate) async throws {
        let urlString = "\(supabaseURL)/rest/v1/service_requests?id=eq.\(update.requestId)"
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
    
    private func saveRequestsToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(requests)
            try atomicWrite(data: data, to: requestsFileURL)
        } catch {
            print("[ServiceRequests] ⚠️ Failed to save requests: \(error)")
        }
    }
    
    private func loadRequestsFromDisk() {
        do {
            let data = try Data(contentsOf: requestsFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            requests = try decoder.decode([ServiceRequestPin].self, from: data)
            print("[ServiceRequests] Loaded \(requests.count) cached requests from disk")
        } catch {
            requests = []
        }
    }
    
    private func savePendingUpdatesToDisk() {
        do {
            let data = try JSONEncoder().encode(pendingUpdates)
            try atomicWrite(data: data, to: pendingUpdatesFileURL)
        } catch {
            print("[ServiceRequests] ⚠️ Failed to save pending updates: \(error)")
        }
    }
    
    private func loadPendingUpdatesFromDisk() {
        do {
            let data = try Data(contentsOf: pendingUpdatesFileURL)
            pendingUpdates = try JSONDecoder().decode([SRPendingStatusUpdate].self, from: data)
            if !pendingUpdates.isEmpty {
                print("[ServiceRequests] \(pendingUpdates.count) pending update(s) queued from last session")
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
            print("[ServiceRequests] ⚠️ Failed to save banner IDs: \(error)")
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
        
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tempURL, to: url)
    }
    
    // MARK: - Convenience
    
    /// Count of pending (unserviced) requests — used for badges
    var pendingCount: Int {
        requests.filter { $0.isPending }.count
    }
    
    /// All pending requests sorted by priority (urgent first)
    var pendingRequestsSorted: [ServiceRequestPin] {
        requests.filter { $0.isPending }.sorted { lhs, rhs in
            let priorityOrder = ["urgent": 0, "normal": 1, "low": 2]
            return (priorityOrder[lhs.priority] ?? 1) < (priorityOrder[rhs.priority] ?? 1)
        }
    }
}

// MARK: - Pending Status Update (queued for Supabase push)

struct SRPendingStatusUpdate: Codable {
    let requestId: String
    let status: String
    let inspectedBy: String?
    let inspectedAt: Date?
    let techFindings: String?
    let recommendedPermanent: Bool
    let expiresAt: Date?
}
