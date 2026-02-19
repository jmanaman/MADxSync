import Foundation
import CoreLocation
import Combine
import UIKit

// MARK: - Chemical Data
/// All chemicals used in mosquito abatement operations
struct ChemicalData {
    
    /// Chemical categories
    enum Category: String, CaseIterable {
        case larvicide = "Larvicides"
        case adulticide = "Adulticides"
        case biocontrol = "Biocontrol"
    }
    
    /// A single chemical product
    struct Chemical: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let category: Category
    }
    
    /// All available chemicals grouped by category
    static let all: [Chemical] = [
        // Larvicides
        Chemical(name: "Agnique MMF", category: .larvicide),
        Chemical(name: "Altosid P35", category: .larvicide),
        Chemical(name: "Altosid SR-5", category: .larvicide),
        Chemical(name: "Altosid SR-20", category: .larvicide),
        Chemical(name: "Altosid WSP", category: .larvicide),
        Chemical(name: "BTI Sand", category: .larvicide),
        Chemical(name: "BVA 2 Larvicide Oil", category: .larvicide),
        Chemical(name: "Censor", category: .larvicide),
        Chemical(name: "CocoBear", category: .larvicide),
        Chemical(name: "Natular DT", category: .larvicide),
        Chemical(name: "Natular G30", category: .larvicide),
        Chemical(name: "Natular XRT", category: .larvicide),
        Chemical(name: "NyGuard IGR Concentrate", category: .larvicide),
        Chemical(name: "Pyronyl Oil Concentrate", category: .larvicide),
        Chemical(name: "Sumalarv 0.5G", category: .larvicide),
        Chemical(name: "VectoBac 12AS", category: .larvicide),
        Chemical(name: "VectoBac GS", category: .larvicide),
        Chemical(name: "VectoBac WDG", category: .larvicide),
        Chemical(name: "VectoMax FG", category: .larvicide),
        
        // Adulticides
        Chemical(name: "Aqua Duet", category: .adulticide),
        Chemical(name: "BIOMIST 4+12 ULV", category: .adulticide),
        Chemical(name: "Fyfanon ULV Mosquito", category: .adulticide),
        Chemical(name: "Kontrol 4-4", category: .adulticide),
        
        // Biocontrol
        Chemical(name: "Mosquitofish", category: .biocontrol),
    ]
    
    /// Chemicals organized by category for picker display
    static var byCategory: [(category: Category, chemicals: [Chemical])] {
        Category.allCases.map { category in
            (category, all.filter { $0.category == category })
        }
    }
}

// MARK: - Dose Units
/// All dose unit options for treatments
enum DoseUnit: String, CaseIterable, Identifiable {
    case flOz = "fl oz"
    case oz = "oz"
    case gal = "gal"
    case lb = "lb"
    case grams = "grams"
    case ml = "ml"
    case L = "L"
    case briq = "briq"
    case pouch = "pouch"
    case packet = "packet"
    case tablet = "tablet"
    case each = "each"
    
    var id: String { rawValue }
}

// MARK: - Treatment Family
/// Treatment location categories (determines diamond color)
enum TreatmentFamily: String, CaseIterable, Identifiable {
    case field = "FIELD"     // Yellow diamond
    case pool = "POOL"       // Blue diamond
    case drain = "DRAIN"     // Red diamond
    case trap = "TRAP"       // Purple diamond
    case misc = "MISC"       // White diamond
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .field: return "Field"
        case .pool: return "Pool"
        case .drain: return "Drain"
        case .trap: return "Trap"
        case .misc: return "Misc"
        }
    }
    
    /// Diamond color for map rendering
    var color: String {
        switch self {
        case .field: return "#ffca28"  // Yellow
        case .pool: return "#42a5f5"   // Blue
        case .drain: return "#ef5350"  // Red
        case .trap: return "#ab47bc"   // Purple
        case .misc: return "#eeeeee"   // White
        }
    }
}

// MARK: - Treatment Status
enum TreatmentStatus: String, CaseIterable, Identifiable {
    case treated = "TREATED"
    case observed = "OBSERVED"  // Green diamond - footprint only
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .treated: return "Treated"
        case .observed: return "Observed"
        }
    }
}

// MARK: - Larvae Level
/// Larvae count severity levels (determines dot color)
enum LarvaeLevel: String, CaseIterable, Identifiable {
    case none = "none"   // Green dot
    case few = "few"     // Blue dot
    case some = "some"   // Gold dot
    case many = "many"   // Rust dot
    
    var id: String { rawValue }
    
    var displayName: String { rawValue.capitalized }
    
    /// Dot color for map rendering
    var color: String {
        switch self {
        case .none: return "#2e8b57"  // Green
        case .few: return "#4682b4"   // Blue
        case .some: return "#d5a542"  // Gold
        case .many: return "#c86b52"  // Rust
        }
    }
}

// MARK: - Field Marker
/// A marker placed on the map representing a treatment, inspection, observation, or note
///
/// UPDATED: 2026-02-14 — Added featureId and featureType for polyline snap matching.
/// When a treatment diamond is dropped near a canal, the app snaps to the nearest
/// point on the line and stores the polyline's ID here. The HUB uses this for
/// direct feature matching instead of spatial proximity.
struct FieldMarker: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let lat: Double
    let lon: Double
    
    // Treatment data
    var family: String?          // FIELD, POOL, DRAIN, TRAP, MISC
    var status: String?          // TREATED, OBSERVED
    var chemical: String?
    var doseValue: Double?
    var doseUnit: String?
    var trapNumber: String?
    
    // Larvae data
    var larvae: String?          // none, few, some, many
    var pupaePresent: Bool
    
    // Notes
    var notes: String?
    
    // Note tool — field note destined for source_notes table
    var noteText: String?
    
    // Feature matching (polyline snap, polygon hit, point site snap)
    var featureId: String?       // ID of the spatial feature this marker was matched to
    var featureType: String?     // "field", "polyline", "pointsite", "stormdrain"
    
    // Sync tracking
    var syncedToFLO: Bool
    var syncedToSupabase: Bool
    
    init(
        lat: Double,
        lon: Double,
        family: String? = nil,
        status: String? = nil,
        chemical: String? = nil,
        doseValue: Double? = nil,
        doseUnit: String? = nil,
        trapNumber: String? = nil,
        larvae: String? = nil,
        pupaePresent: Bool = false,
        notes: String? = nil,
        noteText: String? = nil,
        featureId: String? = nil,
        featureType: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.lat = lat
        self.lon = lon
        self.family = family
        self.status = status
        self.chemical = chemical
        self.doseValue = doseValue
        self.doseUnit = doseUnit
        self.trapNumber = trapNumber
        self.larvae = larvae
        self.pupaePresent = pupaePresent
        self.notes = notes
        self.noteText = noteText
        self.featureId = featureId
        self.featureType = featureType
        self.syncedToFLO = false
        self.syncedToSupabase = false
    }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    
    /// ISO 8601 timestamp for sync
    var timestampISO: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: timestamp)
    }
    
    /// Marker type for database
    var markerType: String {
        if noteText != nil {
            return "NOTE"
        } else if family != nil {
            return "TREATMENT"
        } else if larvae != nil {
            return "LARVAE"
        }
        return "UNKNOWN"
    }
    
    /// Whether this marker is a field note (routes to source_notes)
    var isNote: Bool {
        noteText != nil
    }
    
    /// Generate payload for FLO's /viewer_log/add endpoint
    func toFLOPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "type": "FIELD_TREAT",
            "header": "",
            "sub": ""
        ]
        
        var payloadData: [String: Any] = [
            "lat": lat,
            "lon": lon
        ]
        
        if let family = family {
            payloadData["family"] = family
        }
        if let status = status {
            payloadData["status"] = status
        }
        if let chemical = chemical {
            payloadData["chem"] = chemical
        }
        if let doseValue = doseValue {
            payloadData["doseValue"] = doseValue
        }
        if let doseUnit = doseUnit {
            payloadData["doseUnit"] = doseUnit
        }
        if let trapNumber = trapNumber {
            payloadData["trapNumber"] = trapNumber
        }
        
        // If this is a larvae-only marker
        if let larvae = larvae, family == nil {
            payload["type"] = "FIELD_LARVA"
            payloadData["larva"] = larvae
            payloadData["pupae"] = pupaePresent ? 1 : 0
        }
        
        // If this is a note marker
        if let noteText = noteText {
            payload["type"] = "FIELD_NOTE"
            payloadData["note"] = noteText
        }
        
        payload["payload"] = payloadData
        return payload
    }
    
    /// Generate payload for Supabase app_markers table
    func toSupabasePayload(deviceId: String, truckId: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "device_id": deviceId,
            "district_id": AuthService.shared.districtId ?? "",
            "timestamp_iso": timestampISO,
            "lat": lat,
            "lon": lon,
            "marker_type": markerType,
            "pupae_present": pupaePresent
        ]
        
        // Optional truck (nil for foot patrol)
        if let truckId = truckId {
            payload["truck_id"] = truckId
        }
        
        // Treatment fields
        if let family = family { payload["family"] = family }
        if let status = status { payload["status"] = status }
        if let chemical = chemical { payload["chemical"] = chemical }
        if let doseValue = doseValue { payload["dose_value"] = doseValue }
        if let doseUnit = doseUnit { payload["dose_unit"] = doseUnit }
        if let trapNumber = trapNumber { payload["trap_number"] = trapNumber }
        
        // Larvae fields
        if let larvae = larvae { payload["larvae_level"] = larvae }
        
        // Notes
        if let notes = notes, !notes.isEmpty { payload["notes"] = notes }
        
        // Feature matching — allows HUB to match by ID instead of proximity
        if let featureId = featureId { payload["feature_id"] = featureId }
        if let featureType = featureType { payload["feature_type"] = featureType }
        
        return payload
    }
    
    /// Generate payload for Supabase source_notes table (field notes)
    func toSourceNotePayload(truckId: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "district_id": AuthService.shared.districtId ?? "",
            "note": noteText ?? "",
            "lat": lat,
            "lon": lon,
            "created_by": "app",
            "created_at": timestampISO
        ]
        
        if let truckId = truckId {
            payload["truck_id"] = truckId
        }
        
        // source_type and source_id left nil — Hub auto-attaches
        
        return payload
    }
    
    /// Generate CSV row matching FLO's viewer_log format
    func toCSVRow() -> String {
        var action = ""
        
        if let family = family {
            action = "FIELD_TREAT family=\(family)"
            if let status = status { action += " status=\(status)" }
            if let chemical = chemical { action += " chem=\(chemical)" }
            if let doseValue = doseValue { action += " doseValue=\(doseValue)" }
            if let doseUnit = doseUnit { action += " doseUnit=\(doseUnit)" }
            if let trapNumber = trapNumber { action += " trapNumber=\(trapNumber)" }
        } else if let larvae = larvae {
            action = "FIELD_LARVA larva=\(larvae) pupae=\(pupaePresent ? 1 : 0)"
        } else if let noteText = noteText {
            let safeNote = noteText.replacingOccurrences(of: ",", with: " ")
            action = "FIELD_NOTE note=\(safeNote)"
        }
        
        action += " lat=\(lat) lon=\(lon)"
        
        // Escape any commas in notes
        let safeNotes = (notes ?? "").replacingOccurrences(of: ",", with: " ")
        if !safeNotes.isEmpty {
            action += " notes=\(safeNotes)"
        }
        
        return "\(timestampISO),,\"\(action)\",0,0,0,0,,\(lat),\(lon)"
    }
}

// MARK: - Marker Store
/// Persistent store for field markers with network-aware store-and-forward sync.
///
/// STORE-AND-FORWARD ARCHITECTURE:
/// 1. Every addMarker() call persists to disk IMMEDIATELY (atomic write)
/// 2. If online → attempt Supabase sync right away
/// 3. If offline → markers queue on disk, auto-drain when connectivity returns
/// 4. App crash, iOS kill, battery death → markers survive on disk
/// 5. Unsynced markers are NEVER deleted by cleanup routines
///
/// HARDENED: 2026-02-09 — Network-aware sync, auto-retry on reconnect,
/// 401 token refresh handling, exponential backoff, atomic file writes.

extension Notification.Name {
    static let markerAdded = Notification.Name("markerAdded")
}

@MainActor
class MarkerStore: ObservableObject {
    static let shared = MarkerStore()
    
    @Published var markers: [FieldMarker] = []
    @Published var pendingSyncCount: Int = 0
    @Published var isSyncing: Bool = false
    @Published var lastSyncError: String?
    
    // Supabase config
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    // Device identifier (persists across app launches)
    private var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: "deviceId") {
            return existing
        }
        let newId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "deviceId")
        return newId
    }
    
    private let fileURL: URL
    
    /// Network reconnect observer
    private var networkObserver: Any?
    
    /// Backoff tracking for sync failures
    private var consecutiveSyncFailures: Int = 0
    private var isSyncBackingOff: Bool = false
    private let maxBackoffSeconds: Double = 300  // 5 minutes max
    
    /// Prevents overlapping sync cycles
    private var syncTask: Task<Void, Never>?
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("pending_markers.json")
        loadMarkers()
        
        // Clean up synced markers from previous days on launch
        clearSyncedFromPreviousDays()
        
        // Schedule midnight cleanup
        scheduleMidnightCleanup()
        
        // Listen for network restoration to auto-drain sync queue
        setupNetworkObserver()
        
        // If we have unsynced markers and internet is available, sync now
        if pendingSyncCount > 0 && NetworkMonitor.shared.hasInternet {
            print("[MarkerStore] Found \(pendingSyncCount) unsynced markers on launch — syncing")
            syncTask = Task { await syncToSupabase() }
        }
    }
    
    deinit {
        if let observer = networkObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        syncTask?.cancel()
    }
    
    // MARK: - Network Observer
    
    /// Listen for network state changes to auto-sync when connectivity returns
    private func setupNetworkObserver() {
        networkObserver = NotificationCenter.default.addObserver(
            forName: .networkStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let network = NetworkMonitor.shared
                
                // Only trigger sync when internet comes back AND we have unsynced markers
                if network.hasInternet && self.pendingSyncCount > 0 && !self.isSyncing {
                    print("[MarkerStore] Network restored — syncing \(self.pendingSyncCount) queued markers")
                    self.consecutiveSyncFailures = 0  // Reset backoff on fresh connectivity
                    self.isSyncBackingOff = false
                    self.syncTask?.cancel()
                    self.syncTask = Task { await self.syncToSupabase() }
                }
            }
        }
    }
    
    // MARK: - Add Marker
    
    /// Add a marker. Persists to disk IMMEDIATELY, then attempts sync.
    /// This is the critical path — disk write happens before sync attempt
    /// so the marker survives even if the app crashes during sync.
    func addMarker(_ marker: FieldMarker) {
        markers.append(marker)
        updatePendingCount()
        
        // CRITICAL: Persist to disk FIRST, before any network activity.
        // If the app crashes after this line, the marker is safe on disk.
        saveMarkers()
        
        // Notify map to add annotation
        NotificationCenter.default.post(name: .markerAdded, object: marker)
        
        // Attempt sync if online (non-blocking — marker is already saved)
        if NetworkMonitor.shared.hasInternet && !isSyncBackingOff {
            syncTask?.cancel()
            syncTask = Task { await syncToSupabase() }
        } else if !NetworkMonitor.shared.hasInternet {
            print("[MarkerStore] Offline — marker saved to disk, \(pendingSyncCount) queued for sync")
        }
    }
    
    // MARK: - Mark Synced
    
    func markSyncedToFLO(_ marker: FieldMarker) {
        if let index = markers.firstIndex(where: { $0.id == marker.id }) {
            markers[index].syncedToFLO = true
            saveMarkers()
        }
    }
    
    func markSyncedToSupabase(_ markerId: UUID) {
        if let index = markers.firstIndex(where: { $0.id == markerId }) {
            markers[index].syncedToSupabase = true
            updatePendingCount()
            saveMarkers()
        }
    }
    
    // MARK: - Sync to Supabase (Network-Aware with Backoff)
    
    /// Sync all unsynced markers to Supabase.
    /// Network-aware: skips if offline. Backs off on repeated failures.
    /// Handles 401 with token refresh and single retry.
    func syncToSupabase() async {
        // Guard: don't sync if offline
        guard NetworkMonitor.shared.hasInternet else {
            print("[MarkerStore] Sync skipped — no internet (\(pendingSyncCount) markers queued)")
            return
        }
        
        // Guard: don't overlap sync cycles
        guard !isSyncing else {
            return
        }
        
        // Guard: respect backoff
        guard !isSyncBackingOff else {
            return
        }
        
        let unsyncedMarkers = markers.filter { !$0.syncedToSupabase }
        guard !unsyncedMarkers.isEmpty else { return }
        
        isSyncing = true
        lastSyncError = nil
        
        var successCount = 0
        var failCount = 0
        
        for marker in unsyncedMarkers {
            // Check connectivity before each upload — network could drop mid-batch
            guard NetworkMonitor.shared.hasInternet else {
                print("[MarkerStore] Network lost during sync — pausing (\(successCount) synced, \(unsyncedMarkers.count - successCount) remaining)")
                break
            }
            
            // Check for task cancellation (new sync cycle started)
            guard !Task.isCancelled else { break }
            
            do {
                try await uploadMarkerWithRetry(marker)
                markSyncedToSupabase(marker.id)
                successCount += 1
                print("[MarkerStore] ✓ Synced \(marker.markerType.lowercased()) \(marker.id.uuidString.prefix(8))")
            } catch {
                failCount += 1
                print("[MarkerStore] ✗ Failed to sync marker \(marker.id.uuidString.prefix(8)): \(error)")
                lastSyncError = error.localizedDescription
                
                // Don't keep trying if we're getting errors — back off
                // The marker is safe on disk and will sync later
                break
            }
        }
        
        isSyncing = false
        updatePendingCount()
        
        if successCount > 0 {
            print("[MarkerStore] Sync batch complete: \(successCount) synced, \(pendingSyncCount) remaining")
        }
        
        // Handle failures with backoff
        if failCount > 0 {
            consecutiveSyncFailures += 1
            scheduleRetrySync()
        } else {
            consecutiveSyncFailures = 0
        }
    }
    
    // MARK: - Upload with 401 Retry
    
    /// Upload a single marker, handling 401 with token refresh and one retry.
    private func uploadMarkerWithRetry(_ marker: FieldMarker) async throws {
        do {
            try await uploadMarker(marker)
        } catch MarkerSyncError.uploadFailed(statusCode: 401) {
            // Token expired — refresh and retry once
            print("[MarkerStore] Got 401 — refreshing token and retrying")
            let refreshed = await AuthService.shared.handleUnauthorized()
            if refreshed {
                try await uploadMarker(marker)
            } else {
                throw MarkerSyncError.uploadFailed(statusCode: 401)
            }
        }
    }
    
    // MARK: - Backoff Retry
    
    /// Schedule a retry with exponential backoff: 5s, 10s, 20s, 40s, ... up to 5 min
    private func scheduleRetrySync() {
        let backoffSeconds = min(5.0 * pow(2.0, Double(consecutiveSyncFailures - 1)), maxBackoffSeconds)
        isSyncBackingOff = true
        
        print("[MarkerStore] Sync failed — retrying in \(Int(backoffSeconds))s (attempt \(consecutiveSyncFailures))")
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                isSyncBackingOff = false
                
                // Only retry if still have unsynced markers and internet
                if pendingSyncCount > 0 && NetworkMonitor.shared.hasInternet {
                    syncTask?.cancel()
                    syncTask = Task { await syncToSupabase() }
                }
            }
        }
    }
    
    // MARK: - Upload Single Marker
    
    private func uploadMarker(_ marker: FieldMarker) async throws {
        // Route notes to source_notes, everything else to app_markers
        if marker.isNote {
            try await uploadNote(marker)
        } else {
            try await uploadAppMarker(marker)
        }
    }
    
    /// Upload a treatment or larvae marker to app_markers
    private func uploadAppMarker(_ marker: FieldMarker) async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/app_markers") else {
            throw MarkerSyncError.invalidURL
        }
        
        let payload = marker.toSupabasePayload(deviceId: deviceId, truckId: TruckService.shared.selectedTruckId)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.httpBody = jsonData
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MarkerSyncError.noResponse
        }
        
        // 201 = created, 409 = duplicate (already exists, that's fine)
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 409 else {
            throw MarkerSyncError.uploadFailed(statusCode: httpResponse.statusCode)
        }
    }
    
    /// Upload a field note to source_notes
    private func uploadNote(_ marker: FieldMarker) async throws {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/source_notes") else {
            throw MarkerSyncError.invalidURL
        }
        
        let payload = marker.toSourceNotePayload(truckId: TruckService.shared.selectedTruckId)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MarkerSyncError.noResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 409 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "no body"
            print("[MarkerStore] ✗ Note upload failed: \(httpResponse.statusCode) — \(errorBody)")
            throw MarkerSyncError.uploadFailed(statusCode: httpResponse.statusCode)
        }
    }
    
    // MARK: - Remove Synced Markers (manual - for overnight work)
    
    /// Clears only markers that have been synced to Supabase. Safe to call anytime.
    /// UNSYNCED MARKERS ARE NEVER DELETED.
    func clearSyncedMarkers() {
        let beforeCount = markers.count
        markers.removeAll { $0.syncedToSupabase }
        let cleared = beforeCount - markers.count
        updatePendingCount()
        saveMarkers()
        print("[MarkerStore] Cleared \(cleared) synced markers, \(markers.count) unsynced remain")
    }
    
    // MARK: - Midnight Auto-Clear
    
    /// Called on app launch and at midnight — clears synced markers from previous days.
    /// CRITICAL: Only removes markers where syncedToSupabase == true AND timestamp is before today.
    /// Unsynced markers are NEVER touched, regardless of age.
    func clearSyncedFromPreviousDays() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        let beforeCount = markers.count
        markers.removeAll { marker in
            // SAFETY: Only remove if synced AND from a previous day
            guard marker.syncedToSupabase else { return false }
            let markerDay = calendar.startOfDay(for: marker.timestamp)
            return markerDay < today
        }
        let cleared = beforeCount - markers.count
        
        if cleared > 0 {
            updatePendingCount()
            saveMarkers()
            print("[MarkerStore] Auto-cleared \(cleared) synced markers from previous days")
        }
    }
    
    /// Schedule midnight cleanup check
    func scheduleMidnightCleanup() {
        // Calculate seconds until midnight
        let calendar = Calendar.current
        let now = Date()
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let midnight = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow) else {
            return
        }
        
        let secondsUntilMidnight = midnight.timeIntervalSince(now)
        
        // Schedule the cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsUntilMidnight) { [weak self] in
            self?.clearSyncedFromPreviousDays()
            // Reschedule for next midnight
            self?.scheduleMidnightCleanup()
        }
        
        print("[MarkerStore] Midnight cleanup scheduled in \(Int(secondsUntilMidnight / 3600))h \(Int((secondsUntilMidnight.truncatingRemainder(dividingBy: 3600)) / 60))m")
    }
    
    // MARK: - Undo Last
    
    func undoLast() {
        guard !markers.isEmpty else { return }
        markers.removeLast()
        updatePendingCount()
        saveMarkers()
    }
    
    // MARK: - Stats for UI
    
    var syncedCount: Int {
        markers.filter { $0.syncedToSupabase }.count
    }
    
    var unsyncedCount: Int {
        markers.filter { !$0.syncedToSupabase }.count
    }
    
    var todayCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return markers.filter { calendar.startOfDay(for: $0.timestamp) == today }.count
    }
    
    // MARK: - Persistence (Atomic Writes)
    
    private func updatePendingCount() {
        pendingSyncCount = markers.filter { !$0.syncedToSupabase }.count
    }
    
    /// Save markers to disk with atomic write.
    /// Atomic = write to temp file first, then rename. If the app crashes mid-write,
    /// the previous valid file remains intact. No data loss.
    private func saveMarkers() {
        do {
            let data = try JSONEncoder().encode(markers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[MarkerStore] ⚠️ Failed to save markers: \(error)")
        }
    }
    
    /// Load markers from disk on app launch.
    /// If the file is corrupted or missing, start with empty array.
    /// Markers are never lost unless the file system itself fails.
    private func loadMarkers() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            markers = []
            print("[MarkerStore] No marker file found — starting fresh")
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            markers = try JSONDecoder().decode([FieldMarker].self, from: data)
            updatePendingCount()
            print("[MarkerStore] Loaded \(markers.count) markers from disk (\(pendingSyncCount) unsynced)")
        } catch {
            // File exists but is corrupted — DON'T delete it.
            // Move it aside for debugging and start fresh.
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("pending_markers_corrupt_\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            markers = []
            print("[MarkerStore] ⚠️ Marker file corrupted — moved to backup, starting fresh. Error: \(error)")
        }
    }
}

// MARK: - Sync Errors

enum MarkerSyncError: Error {
    case invalidURL
    case noResponse
    case uploadFailed(statusCode: Int)
}
