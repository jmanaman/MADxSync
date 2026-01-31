import Foundation
import Combine

/// FLOService handles all HTTP communication with the FLO ESP32 hardware
/// Base URL: http://192.168.4.1 (FLO WiFi AP)
///
/// Key endpoints:
/// - GET /identity → truck name, firmware
/// - GET /gps → position, satellites, speed
/// - GET /get_totals → gallons & chemical oz
/// - GET /get_relay_status → "1,0,0" for 3 relays
/// - GET /get_relay_names → custom relay names
/// - POST /cmd?data=RELAY=1,on → toggle relay
/// - POST /cmd?data=SWEEP_ENABLE → enable sweep
/// - GET /daylog/list → list CSV files for sync
/// - GET /daylog/download?name=X.csv → download specific file
class FLOService: ObservableObject {
    static let shared = FLOService()
    
    private let baseURL = "http://192.168.4.1"
    private let session: URLSession
    private var pollTimer: Timer?
    
    // MARK: - Published State
    @Published var isConnected = false
    @Published var truckName = ""
    @Published var firmwareVersion = ""
    
    // GPS
    @Published var gpsLat: Double = 0
    @Published var gpsLon: Double = 0
    @Published var gpsSatellites: Int = 0
    @Published var gpsHdop: Double = 0
    @Published var gpsSpeed: Double = 0  // mph
    @Published var gpsCourse: Double = 0
    @Published var gpsFix: Bool = false
    
    // Flow totals
    @Published var gallons: Double = 0
    @Published var chemicalOz: Double = 0
    
    // Relay states
    @Published var relay1On = false  // BTI
    @Published var relay2On = false  // Oil
    @Published var relay3On = false  // Pump
    @Published var relay1Name = "BTI"
    @Published var relay2Name = "Oil"
    @Published var relay3Name = "Pump"
    
    // Sweep
    @Published var sweepEnabled = false
    
    // MARK: - Init
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        session = URLSession(configuration: config)
    }
    
    // MARK: - Connection
    func startPolling() {
        stopPolling()
        
        // Initial fetch
        Task { await refreshAll() }
        
        // Poll every 2 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { await self?.pollLiveData() }
        }
    }
    
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    /// Refresh all data from FLO
    @MainActor
    func refreshAll() async {
        await fetchIdentity()
        await fetchRelayStatus()
        await fetchRelayNames()
        await pollLiveData()
    }
    
    /// Poll frequently changing data (GPS, totals)
    @MainActor
    func pollLiveData() async {
        await fetchGPS()
        await fetchTotals()
    }
    
    // MARK: - Identity
    @MainActor
    func fetchIdentity() async {
        guard let url = URL(string: "\(baseURL)/identity") else { return }
        
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                truckName = json["ssid"] as? String ?? ""
                firmwareVersion = json["version"] as? String ?? ""
                isConnected = true
            }
        } catch {
            isConnected = false
        }
    }
    
    // MARK: - GPS
    @MainActor
    func fetchGPS() async {
        guard let url = URL(string: "\(baseURL)/gps") else { return }
        
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                gpsFix = json["fix"] as? Bool ?? false
                gpsSatellites = json["sats"] as? Int ?? 0
                gpsHdop = json["hdop"] as? Double ?? 0
                
                if gpsFix {
                    gpsLat = json["lat"] as? Double ?? 0
                    gpsLon = json["lon"] as? Double ?? 0
                    gpsSpeed = json["speed"] as? Double ?? 0
                    gpsCourse = json["course"] as? Double ?? 0
                }
                isConnected = true
            }
        } catch {
            // GPS fetch failed - might still be connected
        }
    }
    
    // MARK: - Flow Totals
    @MainActor
    func fetchTotals() async {
        guard let url = URL(string: "\(baseURL)/get_totals") else { return }
        
        do {
            let (data, _) = try await session.data(from: url)
            if let text = String(data: data, encoding: .utf8) {
                // Format: "gallons=2.45&chemical=6.27"
                let parts = text.split(separator: "&")
                for part in parts {
                    let kv = part.split(separator: "=")
                    if kv.count == 2 {
                        let key = String(kv[0])
                        let value = Double(kv[1]) ?? 0
                        if key == "gallons" { gallons = value }
                        if key == "chemical" { chemicalOz = value }
                    }
                }
                isConnected = true
            }
        } catch {
            // Totals fetch failed
        }
    }
    
    // MARK: - Relay Status
    @MainActor
    func fetchRelayStatus() async {
        guard let url = URL(string: "\(baseURL)/get_relay_status") else { return }
        
        do {
            let (data, _) = try await session.data(from: url)
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                // Format: "1,0,0"
                let parts = text.split(separator: ",")
                if parts.count >= 3 {
                    relay1On = parts[0] == "1"
                    relay2On = parts[1] == "1"
                    relay3On = parts[2] == "1"
                }
                isConnected = true
            }
        } catch {
            // Relay fetch failed
        }
    }
    
    @MainActor
    func fetchRelayNames() async {
        guard let url = URL(string: "\(baseURL)/get_relay_names") else { return }
        
        do {
            let (data, _) = try await session.data(from: url)
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                // Format: "BTI,Oil,Pump"
                let parts = text.split(separator: ",")
                if parts.count >= 3 {
                    relay1Name = String(parts[0])
                    relay2Name = String(parts[1])
                    relay3Name = String(parts[2])
                }
            }
        } catch {
            // Names fetch failed - use defaults
        }
    }
    
    // MARK: - Relay Control
    func toggleRelay(_ relayNumber: Int, on: Bool) async -> Bool {
        let cmd = "RELAY=\(relayNumber),\(on ? "on" : "off")"
        return await sendCommand(cmd)
    }
    
    @MainActor
    func toggleBTI() async {
        let newState = !relay1On
        if await toggleRelay(1, on: newState) {
            relay1On = newState
        }
    }
    
    @MainActor
    func toggleOil() async {
        let newState = !relay2On
        if await toggleRelay(2, on: newState) {
            relay2On = newState
        }
    }
    
    @MainActor
    func togglePump() async {
        let newState = !relay3On
        if await toggleRelay(3, on: newState) {
            relay3On = newState
        }
    }
    
    // MARK: - Sweep Control
    @MainActor
    func toggleSweep() async {
        let newState = !sweepEnabled
        let cmd = newState ? "SWEEP_ENABLE" : "SWEEP_DISABLE"
        if await sendCommand(cmd) {
            sweepEnabled = newState
        }
    }
    
    @MainActor
    func enableSweep() async {
        if await sendCommand("SWEEP_ENABLE") {
            sweepEnabled = true
        }
    }
    
    @MainActor
    func disableSweep() async {
        if await sendCommand("SWEEP_DISABLE") {
            sweepEnabled = false
        }
    }
    
    // MARK: - Generic Command
    func sendCommand(_ cmd: String) async -> Bool {
        guard let encoded = cmd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/cmd?data=\(encoded)") else {
            return false
        }
        
        do {
            let (_, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
    
    // MARK: - Daylog (CSV sync)
    struct DaylogFile: Identifiable {
        let id = UUID()
        let name: String
        let size: Int
        let downloaded: Bool
        let path: String
    }
    
    func fetchDaylogList() async -> [DaylogFile] {
        guard let url = URL(string: "\(baseURL)/daylog/list") else { return [] }
        
        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let files = json["files"] as? [[String: Any]] {
                return files.compactMap { file in
                    guard let name = file["name"] as? String,
                          let size = file["size"] as? Int,
                          let path = file["path"] as? String else { return nil }
                    let downloaded = file["downloaded"] as? Bool ?? false
                    return DaylogFile(name: name, size: size, downloaded: downloaded, path: path)
                }
            }
        } catch {
            print("Daylog list fetch failed: \(error)")
        }
        return []
    }
    
    func downloadDaylog(name: String) async -> String? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/daylog/download?name=\(encoded)") else {
            return nil
        }
        
        do {
            let (data, _) = try await session.data(from: url)
            return String(data: data, encoding: .utf8)
        } catch {
            print("Daylog download failed: \(error)")
            return nil
        }
    }
    
    func clearDownloadedFiles() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/clear-downloaded") else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            print("Clear downloaded failed: \(error)")
        }
        return false
    }
    
    // MARK: - Viewer Log (treatment logging)
    func postViewerLog(payload: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(baseURL)/viewer_log/add") else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            print("Viewer log post failed: \(error)")
        }
        return false
    }
}
