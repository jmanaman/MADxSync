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
        noteText: String? = nil
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
        
        return payload
    }
    
    /// Generate payload for Supabase source_notes table (field notes)
    func toSourceNotePayload(truckId: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "district_id": "2f05ab6e-dacb-4af5-b5d2-0156aa8b58ce",
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
/// In-memory store for markers with local persistence and Supabase sync
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
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("pending_markers.json")
        loadMarkers()
        
        // Clean up synced markers from previous days on launch
        clearSyncedFromPreviousDays()
        
        // Schedule midnight cleanup
        scheduleMidnightCleanup()
    }
    
    // MARK: - Add Marker
    func addMarker(_ marker: FieldMarker) {
        markers.append(marker)
        updatePendingCount()
        saveMarkers()
        NotificationCenter.default.post(name: .markerAdded, object: marker)
        
        // Auto-sync to Supabase
        Task {
            await syncToSupabase()
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
    
    // MARK: - Sync to Supabase
    func syncToSupabase() async {
        let unsyncedMarkers = markers.filter { !$0.syncedToSupabase }
        
        guard !unsyncedMarkers.isEmpty else { return }
        
        isSyncing = true
        lastSyncError = nil
        
        for marker in unsyncedMarkers {
            do {
                try await uploadMarker(marker)
                markSyncedToSupabase(marker.id)
                print("[MarkerStore] ✓ Synced \(marker.markerType.lowercased()) \(marker.id)")
            } catch {
                print("[MarkerStore] ✗ Failed to sync marker: \(error)")
                lastSyncError = error.localizedDescription
            }
        }
        
        isSyncing = false
        updatePendingCount()
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
        
        // Log what we're sending
        if let jsonDebug = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let jsonString = String(data: jsonDebug, encoding: .utf8) {
            print("[MarkerStore] 📝 Uploading note to source_notes:")
            print(jsonString)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MarkerSyncError.noResponse
        }
        
        // Log response details for debugging
        print("[MarkerStore] 📝 source_notes response: \(httpResponse.statusCode)")
        if let responseBody = String(data: data, encoding: .utf8), !responseBody.isEmpty {
            print("[MarkerStore] 📝 Response body: \(responseBody)")
        }
        
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 409 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "no body"
            print("[MarkerStore] ✗ Note upload FAILED: \(httpResponse.statusCode) — \(errorBody)")
            throw MarkerSyncError.uploadFailed(statusCode: httpResponse.statusCode)
        }
    }
    
    // MARK: - Remove Synced Markers (manual - for overnight work)
    /// Clears only markers that have been synced to Supabase. Safe to call anytime.
    func clearSyncedMarkers() {
        let beforeCount = markers.count
        markers.removeAll { $0.syncedToSupabase }
        let cleared = beforeCount - markers.count
        updatePendingCount()
        saveMarkers()
        print("[MarkerStore] Cleared \(cleared) synced markers, \(markers.count) unsynced remain")
    }
    
    // MARK: - Midnight Auto-Clear
    /// Called on app launch and periodically - clears synced markers from previous days
    func clearSyncedFromPreviousDays() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        let beforeCount = markers.count
        markers.removeAll { marker in
            // Only remove if synced AND from a previous day
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
    
    // MARK: - Persistence
    private func updatePendingCount() {
        pendingSyncCount = markers.filter { !$0.syncedToSupabase }.count
    }
    
    private func saveMarkers() {
        do {
            let data = try JSONEncoder().encode(markers)
            try data.write(to: fileURL)
        } catch {
            print("[MarkerStore] Failed to save markers: \(error)")
        }
    }
    
    private func loadMarkers() {
        do {
            let data = try Data(contentsOf: fileURL)
            markers = try JSONDecoder().decode([FieldMarker].self, from: data)
            updatePendingCount()
        } catch {
            markers = []
        }
    }
}

// MARK: - Sync Errors
enum MarkerSyncError: Error {
    case invalidURL
    case noResponse
    case uploadFailed(statusCode: Int)
}
