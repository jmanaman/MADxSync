//
//  HubSyncService.swift
//  MADxSync
//
//  Silent 60-second polling service that pulls fresh data from Supabase.
//  Each channel (pending sources, treatment status, spatial layers, etc.)
//  is independent. If a pull succeeds, data swaps in atomically.
//  If it fails, nothing changes. The tech never knows.
//
//  RULES:
//  - Foreground only. Timer stops in background, restarts in foreground.
//  - No network checking. Just try and fail gracefully.
//  - No auth management. If token expired, 401 fails silently, auth refreshes on its own cycle.
//  - No user-facing errors. Console logging only.
//  - No retry logic. Constant 60-second interval, always.
//  - Each channel is atomic. Full response or no update.
//  - Non-blocking. Never touches FLO, GPS, map rendering, or treatment tools.
//  - Multi-tenant safe. All queries filter by AuthService.shared.districtId at runtime.
//

import Foundation
import Combine

final class HubSyncService: ObservableObject {
    
    static let shared = HubSyncService()
    
    // MARK: - Configuration
    
    /// Poll interval in seconds. 60s = gentle on Supabase, fresh enough for field ops.
    private let pollInterval: TimeInterval = 60.0
    
    /// Spatial refresh interval. 3600s = once per hour. Heavy pull, rarely changes.
    private let spatialRefreshInterval: TimeInterval = 300.0
    
    /// Last spatial refresh time
    private var lastSpatialRefresh: Date?
    
    /// Previous pending source IDs — used to detect promotions/deletions
    private var previousPendingSourceIds: Set<String> = []
    
    /// HTTP request timeout. Short so failed polls don't stack up.
    private let requestTimeout: TimeInterval = 15.0
    
    /// Supabase project credentials (same for all districts — project-level, not district-level)
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    // MARK: - State
    
    private var timer: Timer?
    private var isActive = false
    
    /// Per-channel lock to prevent overlapping pulls
    private var channelBusy: [String: Bool] = [:]
    
    /// Last successful sync time per channel (for debugging)
    private(set) var lastSyncTime: [String: Date] = [:]
    
    /// Consecutive failure count per channel (for logging throttle only, not backoff)
    private var failureCount: [String: Int] = [:]
    
    private init() {}
    
    // MARK: - Lifecycle (called from MADxSyncApp)
    
    /// Start polling. Call when app enters foreground and user is authenticated.
    func start() {
        guard !isActive else { return }
        isActive = true
        
        print("[HubSync] Started — polling every \(Int(pollInterval))s")
        
        // Fire immediately on start, then every 60 seconds
        pollNow()
        
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
    }
    
    /// Stop polling. Call when app enters background.
    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        print("[HubSync] Stopped")
    }
    
    // MARK: - Poll Cycle
    
    /// Kick off all channel pulls. Each is independent and non-blocking.
    private func pollNow() {
        // Gate on auth — if not authenticated, skip silently
        guard AuthService.shared.isAuthenticated else { return }
        guard AuthService.shared.districtId != nil else { return }
        
        Task { await pullPendingSources() }
        Task { await pullTreatmentStatus() }
        Task { await refreshSpatialIfDue() }
        Task { await pullSourceFinderPins() }
        Task { await pullServiceRequests() }
    }
    
    // MARK: - Channel: Spatial Layers (Hourly + Promotion Triggered)
    
    private func refreshSpatialIfDue() async {
        let channel = "spatialLayers"
        guard !isBusy(channel) else { return }
        
        // Only refresh if an hour has passed since last refresh
        if let last = lastSpatialRefresh, Date().timeIntervalSince(last) < spatialRefreshInterval {
            return
        }
        
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        do {
            await SpatialService.shared.loadAllLayers()
            lastSpatialRefresh = Date()
            recordSuccess(channel)
        } catch {
            recordFailure(channel, error: error)
        }
    }
    
    /// Called when pending sources disappear — likely promoted. Trigger immediate spatial refresh.
    private func triggerSpatialRefreshForPromotion() {
        print("[HubSync] Pending source removed — triggering spatial refresh (likely promoted)")
        Task {
            let channel = "spatialLayers"
            guard !isBusy(channel) else { return }
            setBusy(channel, true)
            defer { setBusy(channel, false) }
            
            await SpatialService.shared.loadAllLayers()
            lastSpatialRefresh = Date()
        }
    }
    
    // MARK: - Channel: Pending Sources
    
    private func pullPendingSources() async {
        let channel = "pendingSources"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        do {
            guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else { return }
            
            let urlString = "\(supabaseURL)/rest/v1/pending_sources?district_id=eq.\(districtId)&order=created_at.desc&select=*"
            guard let url = URL(string: urlString) else { return }
            
            let data = try await authenticatedGET(url: url)
            
            // Decode the full response — atomic: either all rows parse or we bail
            let remoteSources = try decodePendingSources(from: data)
            
            // Merge with local unsynced sources on the main thread
            await MainActor.run {
                let service = AddSourceService.shared
                let localUnsynced = service.sources.filter { !$0.syncedToSupabase }
                let remoteIds = Set(remoteSources.map { $0.id })
                
                // Build merged list: all remote + any local-only that aren't on the server yet
                var merged: [PendingSource] = remoteSources
                
                for local in localUnsynced where !remoteIds.contains(local.id) {
                    merged.append(local)
                }
                
                // Only swap if something actually changed (avoid unnecessary UI redraws)
                let currentIds = Set(service.sources.map { $0.id })
                let newIds = Set(merged.map { $0.id })
                let currentCount = service.sources.count
                let newCount = merged.count
                
                if currentIds != newIds || currentCount != newCount {
                    service.sources = merged
                    service.saveSourcesToDisk()
                    
                    // Detect if any pending sources disappeared (promoted or deleted by admin)
                    let disappeared = self.previousPendingSourceIds.subtracting(newIds)
                    if !disappeared.isEmpty && !self.previousPendingSourceIds.isEmpty {
                        self.triggerSpatialRefreshForPromotion()
                    }
                }
                
                self.previousPendingSourceIds = newIds
            }
            
            recordSuccess(channel)
            
        } catch {
            recordFailure(channel, error: error)
        }
    }
    
    /// Decode pending sources from Supabase JSON response.
    /// Uses JSONSerialization for flexibility with the geometry JSONB column.
    private func decodePendingSources(from data: Data) throws -> [PendingSource] {
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HubSyncError.invalidJSON
        }
        
        var sources: [PendingSource] = []
        
        for row in jsonArray {
            guard let id = row["id"] as? String,
                  let districtId = row["district_id"] as? String,
                  let sourceTypeStr = row["source_type"] as? String,
                  let geometryDict = row["geometry"] as? [String: Any],
                  let geoType = geometryDict["type"] as? String else {
                continue // Skip malformed rows, don't fail the whole batch
            }
            
            // Parse geometry coordinates
            let coordinates: [[Double]]
            switch geoType {
            case "Point":
                if let coords = geometryDict["coordinates"] as? [NSNumber] {
                    coordinates = [coords.map { $0.doubleValue }]
                } else if let coords = geometryDict["coordinates"] as? [Double] {
                    coordinates = [coords]
                } else {
                    continue
                }
            case "MultiPoint":
                if let coords = geometryDict["coordinates"] as? [[NSNumber]] {
                    coordinates = coords.map { $0.map { $0.doubleValue } }
                } else if let coords = geometryDict["coordinates"] as? [[Double]] {
                    coordinates = coords
                } else {
                    continue
                }
            default:
                // LineString, Polygon — shouldn't come from the app but handle gracefully
                if let coords = geometryDict["coordinates"] as? [[Double]] {
                    coordinates = coords
                } else {
                    continue
                }
            }
            
            let sourceType = AddSourceType(rawValue: sourceTypeStr) ?? .pointsite
            let condStr = row["condition"] as? String ?? "unknown"
            let condition = SourceCondition(rawValue: condStr) ?? .unknown
            
            let geometry = PendingSourceGeometry(
                type: geoType,
                coordinates: coordinates
            )
            
            var source = PendingSource(
                districtId: districtId,
                sourceType: sourceType,
                name: row["name"] as? String ?? "",
                sourceSubtype: row["source_subtype"] as? String ?? "",
                condition: condition,
                description: row["description"] as? String ?? "",
                geometry: geometry,
                createdBy: row["created_by"] as? String ?? "unknown"
            )
            
            // Override generated ID with server's ID
            source.id = id
            source.syncedToSupabase = true
            
            // Parse dates
            if let createdStr = row["created_at"] as? String {
                source.createdAt = parseISO8601(createdStr)
            }
            if let updatedStr = row["updated_at"] as? String {
                source.updatedAt = parseISO8601(updatedStr)
            }
            
            sources.append(source)
        }
        
        return sources
    }
    
    // MARK: - Channel: Treatment Status
    
    private func pullTreatmentStatus() async {
            let channel = "treatmentStatus"
            guard !isBusy(channel) else { return }
            setBusy(channel, true)
            defer { setBusy(channel, false) }
            
            await TreatmentStatusService.shared.syncFromHub()
            recordSuccess(channel)
        }
    
    // MARK: - Channel: Source Finder Pins
    
    private func pullSourceFinderPins() async {
        let channel = "sourceFinderPins"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        await SourceFinderService.shared.pullFromHub()
        recordSuccess(channel)
    }
    
    // MARK: - Channel: Service Requests
    
    private func pullServiceRequests() async {
        let channel = "serviceRequests"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        await ServiceRequestService.shared.pullFromHub()
        recordSuccess(channel)
    }
    
    // MARK: - Authenticated GET
    
    /// Perform a GET request with the current Supabase auth token.
    /// Returns raw Data on success. Throws on any failure — caller catches silently.
    private func authenticatedGET(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        
        // Supabase REST API headers
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        
        // Auth token — pulled fresh each request so it picks up refreshed tokens
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HubSyncError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw HubSyncError.httpError(httpResponse.statusCode)
        }
        
        return data
    }
    
    // MARK: - Channel Busy Lock
    
    private func isBusy(_ channel: String) -> Bool {
        return channelBusy[channel] ?? false
    }
    
    private func setBusy(_ channel: String, _ busy: Bool) {
        channelBusy[channel] = busy
    }
    
    // MARK: - Logging (silent, console only)
    
    private func recordSuccess(_ channel: String) {
        let prevFailures = failureCount[channel] ?? 0
        lastSyncTime[channel] = Date()
        failureCount[channel] = 0
        
        // Only log recovery (was failing, now succeeded) to keep console clean
        if prevFailures > 0 {
            print("[HubSync] \(channel): ✓ recovered after \(prevFailures) failures")
        }
    }
    
    private func recordFailure(_ channel: String, error: Error) {
        let count = (failureCount[channel] ?? 0) + 1
        failureCount[channel] = count
        
        // Log first failure and every 10th after that (avoid spam during long outages)
        if count == 1 || count % 10 == 0 {
            print("[HubSync] \(channel): failed (\(count)x) — \(error.localizedDescription)")
        }
    }
    
    // MARK: - ISO 8601 Date Parsing
    
    private func parseISO8601(_ string: String) -> Date {
        // Try standard format first
        if let date = ISO8601DateFormatter().date(from: string) {
            return date
        }
        // Try with fractional seconds (Supabase returns these)
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = frac.date(from: string) {
            return date
        }
        return Date()
    }
}

// MARK: - Error Type (internal only, never shown to user)

private enum HubSyncError: LocalizedError {
    case invalidResponse
    case invalidJSON
    case httpError(Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .invalidJSON: return "Invalid JSON"
        case .httpError(let code): return "HTTP \(code)"
        }
    }
}
