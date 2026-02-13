//
//  FLOService.swift
//  MADxSync
//
//  Handles all HTTP communication with the FLO ESP32 hardware.
//  Base URL: http://192.168.4.1 (FLO WiFi AP)
//
//  HARDENED: 2026-02-09 — Network-aware polling, pause/resume for lifecycle,
//  FLO WiFi detection via NetworkMonitor, no polling when not on FLO WiFi.
//
//  UPDATED: 2026-02-11 — WiFi-pinned URLSession for LTE coexistence.
//  When iOS enables LTE alongside FLO WiFi (because FLO has no internet),
//  the default URLSession routes requests over LTE, which can't reach 192.168.4.1.
//  Fix: Create a URLSession bound to the WiFi interface so FLO requests always
//  go over WiFi regardless of iOS routing preferences. This lets flow estimate
//  polling continue working while LTE handles cloud sync in the background.
//
//  Key endpoints:
//  - GET /identity → truck name, firmware
//  - GET /gps → position, satellites, speed
//  - GET /get_totals → gallons & chemical oz
//  - GET /get_relay_status → "1,0,0" for 3 relays
//  - GET /get_relay_names → custom relay names
//  - POST /cmd?data=RELAY=1,on → toggle relay
//  - POST /cmd?data=SWEEP_ENABLE → enable sweep
//  - GET /daylog/list → list CSV files for sync
//  - GET /daylog/download?name=X.csv → download specific file

import Foundation
import Combine
import Network

class FLOService: ObservableObject {
    static let shared = FLOService()
    
    private let baseURL = "http://192.168.4.1"
    
    // MARK: - WiFi-Pinned URLSession
    //
    // WHY: When iOS detects that FLO WiFi has no internet connectivity, it may
    // offer to enable LTE for data. Once LTE is active, iOS promotes it as the
    // preferred route. The default URLSession then routes ALL requests over LTE —
    // including our requests to 192.168.4.1, which is only reachable over WiFi.
    //
    // FIX: We create a URLSession whose underlying connection is bound to the
    // WiFi interface using URLSessionConfiguration + a custom URLProtocol, or
    // more practically, by using Network.framework's NWConnection with
    // requiredInterfaceType(.wifi).
    //
    // However, URLSession doesn't natively support requiredInterfaceType.
    // The cleanest iOS approach is:
    //   1. Use a URLSessionConfiguration with waitsForConnectivity = false
    //   2. Set allowsCellularAccess = false — this forces WiFi
    //   3. Set allowsExpensiveNetworkAccess = false (belts + suspenders)
    //
    // allowsCellularAccess = false is the key. It tells URLSession:
    // "Do NOT use cellular for this request, even if cellular is available."
    // Since the only non-cellular interface is WiFi, this pins to WiFi.
    //
    // This is the Apple-recommended approach and is used by many IoT apps
    // that communicate with local WiFi devices (printers, smart home, etc).
    
    /// WiFi-only session for all FLO communication.
    /// Requests will NEVER route over cellular, ensuring they reach 192.168.4.1.
    private let wifiSession: URLSession
    
    /// Fallback session (allows cellular) — used ONLY for non-FLO requests if needed.
    /// Currently unused, but available if we add cloud-side FLO features later.
    private let defaultSession: URLSession
    
    private var pollTimer: Timer?
    
    /// Tracks whether polling has been started (so resumePolling knows to restart)
    private var pollingWasActive: Bool = false
    
    /// Consecutive identity check failures — used to back off when not on FLO WiFi
    private var identityFailCount: Int = 0
    
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
    
    // Cycle logs — authoritative per-spray data from FlowTracker on the ESP32.
    // Format per entry: "cycleNumber,durationMs,gallons,oz"
    // These are calculated at the EXACT moment the relay toggles, not from polled snapshots.
    @Published var cycleLogs: [CycleLog] = []
    
    struct CycleLog: Identifiable {
        let id: Int          // cycle number
        let durationMs: UInt32
        let gallons: Double
        let chemicalOz: Double
        
        var durationString: String {
            let totalSeconds = Int(durationMs / 1000)
            let mins = totalSeconds / 60
            let secs = totalSeconds % 60
            return "\(mins)m \(secs)s"
        }
    }
    
    // MARK: - Init
    private init() {
        // WiFi-pinned session — the critical fix for LTE coexistence
        let wifiConfig = URLSessionConfiguration.default
        wifiConfig.timeoutIntervalForRequest = 3
        wifiConfig.timeoutIntervalForResource = 5
        wifiConfig.allowsCellularAccess = false          // ← KEY: Forces WiFi-only
        wifiConfig.allowsExpensiveNetworkAccess = false   // ← Belt + suspenders (cellular is "expensive")
        wifiConfig.allowsConstrainedNetworkAccess = true  // Allow on Low Data Mode (WiFi is fine)
        wifiConfig.waitsForConnectivity = false           // Fail fast if WiFi unavailable, don't wait
        wifiSession = URLSession(configuration: wifiConfig)
        
        // Default session for anything that should use the best available path
        let defaultConfig = URLSessionConfiguration.default
        defaultConfig.timeoutIntervalForRequest = 3
        defaultConfig.timeoutIntervalForResource = 5
        defaultSession = URLSession(configuration: defaultConfig)
        
        print("[FLOService] Initialized with WiFi-pinned session (allowsCellularAccess=false)")
    }
    
    // MARK: - Connection / Polling
    
    /// Start polling for FLO data.
    /// Called by FLOControlView.onAppear — now network-aware.
    func startPolling() {
        stopPolling()
        pollingWasActive = true
        identityFailCount = 0
        
        // Initial fetch
        Task { @MainActor in
            await checkConnection()
        }
        
        // Poll on a timer — the callback checks network state before each request
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.networkAwarePoll()
            }
        }
        
        print("[FLOService] Polling started")
    }
    
    /// Stop polling completely. Timer is invalidated.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollingWasActive = false
        print("[FLOService] Polling stopped")
    }
    
    /// Pause polling (app going to background). Remembers that polling was active.
    func pausePolling() {
        guard pollTimer != nil else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        // pollingWasActive stays true so resumePolling can restart
        print("[FLOService] Polling paused (background)")
    }
    
    /// Resume polling (app coming to foreground). Only restarts if it was active before.
    func resumePolling() {
        guard pollingWasActive && pollTimer == nil else { return }
        identityFailCount = 0
        
        // Re-check connection immediately
        Task { @MainActor in
            await checkConnection()
        }
        
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.networkAwarePoll()
            }
        }
        
        print("[FLOService] Polling resumed (foreground)")
    }
    
    /// Network-aware poll — checks NetworkMonitor before making requests.
    ///
    /// UPDATED 2026-02-11: Changed guard from `connectionType != .wifi` to
    /// `!wifiAvailable`. This is critical for LTE coexistence.
    ///
    /// OLD behavior: If iOS reported cellular as the primary path, we'd bail.
    ///   This killed flow estimates when LTE was enabled alongside FLO WiFi.
    ///
    /// NEW behavior: We check if WiFi is available AT ALL (even if not primary).
    ///   Combined with the WiFi-pinned URLSession, requests reach 192.168.4.1
    ///   even when LTE is the "preferred" route for internet traffic.
    @MainActor
    private func networkAwarePoll() async {
        let network = NetworkMonitor.shared
        
        // FLO is a WiFi AP — if WiFi interface is not available at all, skip everything.
        // NOTE: We check wifiAvailable, NOT connectionType == .wifi.
        // When iOS enables LTE alongside FLO WiFi, connectionType may report .cellular
        // even though WiFi is still associated. wifiAvailable checks the actual interface.
        if !network.wifiAvailable {
            if isConnected {
                isConnected = false
                network.setFLOWiFiConnected(false)
                print("[FLOService] WiFi interface not available — marking disconnected")
            }
            return
        }
        
        // WiFi is available — poll normally using the WiFi-pinned session.
        // Even if LTE is active, our wifiSession will route to 192.168.4.1 over WiFi.
        if isConnected {
            await pollLiveData()
        } else {
            // Not connected yet — try identity, but back off after repeated failures
            // to avoid hammering the network stack during WiFi transitions
            identityFailCount += 1
            
            // Back off: check every 5s for first 3 attempts, then every 15s, then every 30s
            let shouldCheck: Bool
            if identityFailCount <= 3 {
                shouldCheck = true
            } else if identityFailCount <= 10 {
                shouldCheck = identityFailCount % 3 == 0  // every 15s
            } else {
                shouldCheck = identityFailCount % 6 == 0  // every 30s
            }
            
            if shouldCheck {
                await fetchIdentity()
            }
        }
    }
    
    /// Check if FLO is reachable
    @MainActor
    private func checkConnection() async {
        await fetchIdentity()
    }
    
    /// Refresh all data from FLO
    @MainActor
    func refreshAll() async {
        await fetchIdentity()
        if isConnected {
            await fetchRelayStatus()
            await fetchRelayNames()
            await pollLiveData()
        }
    }
    
    /// Poll frequently changing data (GPS, totals, cycle logs)
    @MainActor
    func pollLiveData() async {
        await fetchGPS()
        await fetchTotals()
        await fetchCycleLogs()
    }
    
    // MARK: - Identity
    @MainActor
    func fetchIdentity() async {
        guard let url = URL(string: "\(baseURL)/identity") else { return }
        
        do {
            let (data, _) = try await wifiSession.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                truckName = json["ssid"] as? String ?? ""
                firmwareVersion = json["version"] as? String ?? ""
                
                let wasConnected = isConnected
                isConnected = true
                identityFailCount = 0
                
                // Tell NetworkMonitor we confirmed FLO WiFi
                NetworkMonitor.shared.setFLOWiFiConnected(true)
                
                if !wasConnected {
                    print("[FLOService] ✓ Connected to FLO: \(truckName) (fw: \(firmwareVersion))")
                    // Fetch relay info on first connect
                    await fetchRelayStatus()
                    await fetchRelayNames()
                }
            }
        } catch {
            if isConnected {
                print("[FLOService] Lost connection to FLO: \(error.localizedDescription)")
            }
            isConnected = false
            NetworkMonitor.shared.setFLOWiFiConnected(false)
        }
    }
    
    // MARK: - GPS
    @MainActor
    func fetchGPS() async {
        guard let url = URL(string: "\(baseURL)/gps") else { return }
        
        do {
            let (data, _) = try await wifiSession.data(from: url)
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
            let (data, _) = try await wifiSession.data(from: url)
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
    
    // MARK: - Cycle Logs (authoritative per-spray data from FlowTracker)
    //
    // The FLO's FlowTracker calculates per-cycle gallons and chemical at the
    // EXACT moment the relay toggles on/off. These are the ground truth numbers.
    // The app should NEVER calculate its own per-spray deltas from polled totals
    // because polling introduces a 5+ second lag that consistently undercounts.
    //
    // Endpoint: GET /get_logs
    // Format: "cycleNumber,durationMs,gallons,oz\n..." (last 10 cycles, newest last)
    
    @MainActor
    func fetchCycleLogs() async {
        guard let url = URL(string: "\(baseURL)/get_logs") else { return }
        
        do {
            let (data, _) = try await wifiSession.data(from: url)
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                guard !text.isEmpty else { return }
                
                var logs: [CycleLog] = []
                let lines = text.split(separator: "\n")
                for line in lines {
                    let parts = line.split(separator: ",")
                    if parts.count >= 4 {
                        let cycleNum = Int(parts[0]) ?? 0
                        let durMs = UInt32(parts[1]) ?? 0
                        let gal = Double(parts[2]) ?? 0
                        let oz = Double(parts[3]) ?? 0
                        logs.append(CycleLog(
                            id: cycleNum,
                            durationMs: durMs,
                            gallons: gal,
                            chemicalOz: oz
                        ))
                    }
                }
                
                // FlowTracker stores oldest-first, reverse for display (newest first)
                cycleLogs = logs.reversed()
                isConnected = true
            }
        } catch {
            // Cycle logs fetch failed — non-critical
        }
    }
    
    // MARK: - Relay Status
    @MainActor
    func fetchRelayStatus() async {
        guard let url = URL(string: "\(baseURL)/get_relay_status") else { return }
        
        do {
            let (data, _) = try await wifiSession.data(from: url)
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
            let (data, _) = try await wifiSession.data(from: url)
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
            let (_, response) = try await wifiSession.data(from: url)
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
            let (data, _) = try await wifiSession.data(from: url)
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
            let (data, _) = try await wifiSession.data(from: url)
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
            let (_, response) = try await wifiSession.data(for: request)
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
            let (_, response) = try await wifiSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            print("Viewer log post failed: \(error)")
        }
        return false
    }
}
