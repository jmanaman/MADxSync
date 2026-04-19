//
//  HubSyncService.swift
//  MADxSync
//
//  Silent polling service that pulls fresh data from Supabase.
//  Each channel (pending sources, treatment status, spatial layers, etc.)
//  is independent. If a pull succeeds, data swaps in atomically.
//  If it fails, nothing changes. The tech never knows.
//
//  EGRESS OPTIMIZATION (2026-03-17):
//  - Channels are split into FAST (60s) and SLOW (300s) tiers
//  - treatment_status uses conditional fetching (updated_at > lastSync)
//  - equipment + positions load ONCE on start, never poll
//  - Source notes + working notes on slow (5 min) cycle
//  - Activity-aware: goes DARK after 5 min of no interaction (foreground idle)
//  - Full catch-up fetch on wake from dark/background
//
//  RULES:
//  - Foreground only. Timer stops in background, restarts in foreground.
//  - No network checking. Just try and fail gracefully.
//  - No auth management. If token expired, 401 fails silently, auth refreshes on its own cycle.
//  - No user-facing errors. Console logging only.
//  - No retry logic. Constant interval, always.
//  - Each channel is atomic. Full response or no update.
//  - Non-blocking. Never touches FLO, GPS, map rendering, or treatment tools.
//  - Multi-tenant safe. All queries filter by AuthService.shared.districtId at runtime.
//

import Foundation
import Combine

// HARDENED: 2026-04 — Added @MainActor isolation.
// Timer callbacks fire on the main RunLoop and mutate internal state (channelBusy, isDark,
// lastUserActivity, failureCount). Without @MainActor, the Task {} blocks spawned by
// timer callbacks could race on these dictionaries. @MainActor ensures all property
// access is serialized on the main actor, matching the Timer's execution context.
@MainActor
final class HubSyncService: ObservableObject {
    
    static let shared = HubSyncService()
    
    // MARK: - Configuration
    
    /// Fast poll interval: operationally time-sensitive channels
    private let fastInterval: TimeInterval = 60.0
    
    /// Slow poll interval: channels that change infrequently
    private let slowInterval: TimeInterval = 300.0
    
    /// Spatial refresh interval. 3600s = once per hour. Heavy pull, rarely changes.
    private let spatialRefreshInterval: TimeInterval = 3600.0
    
    /// Idle timeout: if no user interaction for this long, stop polling
    private let idleTimeout: TimeInterval = 300.0  // 5 minutes
    
    /// Last spatial refresh time
    private var lastSpatialRefresh: Date?
    
    /// Previous pending source IDs — used to detect promotions/deletions
    private var previousPendingSourceIds: Set<String> = []
    
    /// HTTP request timeout. Short so failed polls don't stack up.
    private let requestTimeout: TimeInterval = 15.0
    
    /// Supabase project credentials (same for all districts — project-level, not district-level)
    private let supabaseURL = SupabaseConfig.url
    private let supabaseKey = SupabaseConfig.publishableKey
    
    // MARK: - State
    
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var isActive = false
    
    /// Activity tracking — last user interaction time
    private var lastUserActivity: Date = Date()
    private var isDark = false
    
    /// Per-channel lock to prevent overlapping pulls
    private var channelBusy: [String: Bool] = [:]
    
    /// Last successful sync time per channel (for debugging)
    private(set) var lastSyncTime: [String: Date] = [:]
    
    /// Consecutive failure count per channel (for logging throttle only, not backoff)
    private var failureCount: [String: Int] = [:]
    
    /// Last treatment_status sync timestamp — for conditional fetching
    private var lastTreatmentStatusSync: String?
    
    /// Last marker_history sync timestamp — for conditional fetching
    private var lastMarkerHistorySync: String?
    
    /// Whether the one-time loads (equipment, positions) have completed
    private var oneTimeLoadsComplete = false
    
    private init() {}
    
    // MARK: - Lifecycle (called from MADxSyncApp)
    
    /// Start polling. Call when app enters foreground and user is authenticated.
    func start() {
        guard !isActive else { return }
        isActive = true
        isDark = false
        lastUserActivity = Date()
        
        print("[HubSync] Started — fast=\(Int(fastInterval))s, slow=\(Int(slowInterval))s")
        
        // One-time loads on first start
        if !oneTimeLoadsComplete {
            Task {
                await pullEquipmentList()
                await pullPositionList()
                oneTimeLoadsComplete = true
                print("[HubSync] One-time loads complete (equipment + positions)")
            }
        }
        
        // Full catch-up fetch on start (coming from background or first launch)
        lastTreatmentStatusSync = nil  // Force full treatment_status pull on wake
        lastMarkerHistorySync = nil    // Force full marker_history pull on wake
        pollFastChannels()
        pollSlowChannels()
        
        // Start timers
        // Timer callbacks fire on the main RunLoop. Since HubSyncService is @MainActor,
        // we need to hop to MainActor explicitly from the closure.
        fastTimer = Timer.scheduledTimer(withTimeInterval: fastInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fastTick()
            }
        }
        
        slowTimer = Timer.scheduledTimer(withTimeInterval: slowInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.slowTick()
            }
        }
    }
    
    /// Stop polling. Call when app enters background.
    func stop() {
        guard isActive else { return }
        isActive = false
        fastTimer?.invalidate()
        fastTimer = nil
        slowTimer?.invalidate()
        slowTimer = nil
        print("[HubSync] Stopped")
    }
    
    /// Call this from UI interaction handlers to signal user activity.
    /// Prevents idle-dark mode while tech is actively using the app.
    func reportUserActivity() {
        lastUserActivity = Date()
        
        // Wake from dark mode — immediate catch-up
        if isDark {
            isDark = false
            lastTreatmentStatusSync = nil  // Force full pull on wake
            lastMarkerHistorySync = nil    // Force full marker_history pull on wake
            print("[HubSync] Waking from idle-dark — catch-up fetch")
            pollFastChannels()
            pollSlowChannels()
        }
    }
    
    // MARK: - Timer Ticks
    
    private func fastTick() {
        // Check for idle timeout
        let idleTime = Date().timeIntervalSince(lastUserActivity)
        if idleTime >= idleTimeout {
            if !isDark {
                isDark = true
                print("[HubSync] No interaction for \(Int(idleTime))s — going dark (zero polling)")
            }
            return  // Skip this tick entirely
        }
        
        isDark = false
        pollFastChannels()
    }
    
    private func slowTick() {
        if isDark { return }  // Skip when dark
        pollSlowChannels()
    }
    
    // MARK: - Poll Cycles
    
    /// Fast channels: operationally time-sensitive (60s)
    private func pollFastChannels() {
        guard AuthService.shared.isAuthenticated else { return }
        guard AuthService.shared.districtId != nil else { return }
        
        Task { await pullPendingSources() }
        Task { await pullTreatmentStatus() }
        Task { await pullMarkerHistory() }
        Task { await refreshSpatialIfDue() }
        Task { await pullSourceFinderPins() }
        Task { await pullServiceRequests() }
    }
    
    /// Slow channels: change infrequently (300s)
    private func pollSlowChannels() {
        guard AuthService.shared.isAuthenticated else { return }
        guard AuthService.shared.districtId != nil else { return }
        
        Task { await pullWorkingNotes() }
        Task { await pullSourceNotes() }
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
    
    // MARK: - Channel: Treatment Status (CONDITIONAL FETCH)
    
    private func pullTreatmentStatus() async {
        let channel = "treatmentStatus"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        // If we have a last sync time, do conditional fetch (delta only)
        // Otherwise do a full pull (first load or wake from dark)
        if let lastSync = lastTreatmentStatusSync {
            await TreatmentStatusService.shared.syncFromHub(since: lastSync)
        } else {
            await TreatmentStatusService.shared.syncFromHub(since: nil)
        }
        
        // Update the sync timestamp for next conditional fetch
        lastTreatmentStatusSync = ISO8601DateFormatter().string(from: Date())
        recordSuccess(channel)
    }
    
    // MARK: - Channel: Marker History (CONDITIONAL FETCH)
    
    private func pullMarkerHistory() async {
        let channel = "markerHistory"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        // If we have a last sync time, do conditional fetch (delta only)
        // Otherwise do a full pull (first load or wake from dark)
        if let lastSync = lastMarkerHistorySync {
            await MarkerHistoryService.shared.syncFromHub(since: lastSync)
        } else {
            await MarkerHistoryService.shared.syncFromHub(since: nil)
        }
        
        // Update the sync timestamp for next conditional fetch
        lastMarkerHistorySync = ISO8601DateFormatter().string(from: Date())
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
    
    // MARK: - Channel: Working Notes (SLOW — 5 min cycle)
    
    private func pullWorkingNotes() async {
        let channel = "workingNotes"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        await WorkingNotesService.shared.pullFromHub()
        recordSuccess(channel)
    }
    
    // MARK: - Channel: Source Notes (SLOW — 5 min cycle)
    
    private func pullSourceNotes() async {
        let channel = "sourceNotes"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        await SourceNotesService.shared.pullFromHub()
        recordSuccess(channel)
    }
    
    // MARK: - One-Time Loads: Equipment + Positions
    // These change ~monthly. Load once on app start, never poll.
    // User can force-refresh by restarting app.
    
    private func pullEquipmentList() async {
        let channel = "equipmentList"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        await EquipmentService.shared.fetchEquipment()
        recordSuccess(channel)
    }
    
    private func pullPositionList() async {
        let channel = "positionList"
        guard !isBusy(channel) else { return }
        setBusy(channel, true)
        defer { setBusy(channel, false) }
        
        await PositionService.shared.fetchPositions()
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
