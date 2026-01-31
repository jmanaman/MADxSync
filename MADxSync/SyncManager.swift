//
//  SyncManager.swift
//  MADxSync
//
//  Created by Justin Manning on 1/29/26.
//

import SwiftUI
import Combine
import Network

@MainActor
class SyncManager: ObservableObject {
    // MARK: - Published State
    @Published var floConnected = false
    @Published var floStatus = "Checking..."
    @Published var truckName: String?
    @Published var isSyncing = false
    @Published var hasInternet = false
    @Published var pendingFiles: Int = 0
    @Published var syncComplete = false
    @Published var logText = "Ready.\nConnect to FLO WiFi to download."
    
    // MARK: - Configuration
    private let floBaseURL = "http://192.168.4.1"
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    // MARK: - Local Storage
    private var pendingData: [PendingSync] = []
    private var truckSlug: String?
    
    // MARK: - Network Monitor
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    
    // MARK: - FLO Polling Timer
    private var floPollingTimer: Timer?
    
    init() {
        loadPendingFromDisk()
        startNetworkMonitor()
        startFLOPolling()
    }
    
    deinit {
        floPollingTimer?.invalidate()
    }
    
    // MARK: - FLO Polling (auto-detect connection)
    private func startFLOPolling() {
        // Check immediately
        Task { await checkFLO() }
        
        // Then check every 3 seconds
        floPollingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkFLO()
            }
        }
    }
    
    // MARK: - Network Monitoring
    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                
                let wasOnline = self.hasInternet
                
                if path.status == .satisfied {
                    await self.testRealInternet()
                } else {
                    self.hasInternet = false
                }
                
                // If we just got internet and have pending data, auto-upload
                if self.hasInternet && !wasOnline && !self.pendingData.isEmpty {
                    self.log("📶 Internet detected - uploading pending data...")
                    await self.uploadPendingData()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func testRealInternet() async {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/") else {
            hasInternet = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                hasInternet = true
            } else {
                hasInternet = false
            }
        } catch {
            hasInternet = false
        }
    }
    
    // MARK: - Check FLO Connection (public for manual refresh)
    func checkFLOConnection() {
        Task {
            await checkFLO()
        }
    }
    
    private func checkFLO() async {
        guard let url = URL(string: "\(floBaseURL)/identity") else {
            floConnected = false
            floStatus = "Invalid URL"
            return
        }
        
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 2  // Fast timeout for polling
            let session = URLSession(configuration: config)
            
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                if floConnected {
                    // Was connected, now lost connection
                    log("📡 FLO disconnected")
                }
                floConnected = false
                floStatus = "Not connected"
                truckName = nil
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ssid = json["ssid"] as? String {
                
                if !floConnected {
                    // Just connected
                    log("📡 Connected to FLO: \(ssid)")
                }
                
                floConnected = true
                truckName = ssid
                truckSlug = toSlug(ssid)
                floStatus = "Connected"
            } else {
                floConnected = true
                floStatus = "Connected (unknown)"
            }
            
        } catch {
            if floConnected {
                log("📡 FLO connection lost")
            }
            floConnected = false
            floStatus = "Not connected"
            truckName = nil
        }
        
        updateSyncStatus()
    }
    
    // MARK: - Main Sync (Download from FLO)
    func sync() async {
        guard floConnected else {
            log("❌ Not connected to FLO")
            return
        }
        
        guard let slug = truckSlug else {
            log("❌ No truck identified")
            return
        }
        
        isSyncing = true
        syncComplete = false
        log("⬇️ Downloading from FLO...")
        
        do {
            // Get file list from FLO
            let files = try await getFileList()

            if files.isEmpty {
                log("✓ No files on FLO")
                isSyncing = false
                updateSyncStatus()
                return
            }

            log("Found \(files.count) file(s)")

            // Download ALL files - Supabase dedupes via upsert
            for file in files {
                log("  📄 \(file.name)")
                
                let csvContent = try await downloadFile(name: file.name)
                let rows = parseCSV(csvContent)
                
                if rows.isEmpty {
                    continue
                }
                
                log("    └ \(rows.count) rows")
                
                // Determine table based on filename
                let tableName = file.name.contains(".manual") ? "viewer_logs" : "source_logs"
                
                // Store locally
                let pending = PendingSync(
                    truckSlug: slug,
                    fileName: file.name,
                    tableName: tableName,
                    rows: rows,
                    downloadedAt: Date()
                )
                pendingData.append(pending)
            }
            
            // Save to disk
            savePendingToDisk()
            
            // Clear downloaded files from FLO
            try await clearDownloaded()
            
            log("✅ Downloaded \(files.count) file(s)")
            
        } catch {
            log("❌ Download failed: \(error.localizedDescription)")
        }
        
        isSyncing = false
        updateSyncStatus()
        
        // Auto-upload if we have internet
        if hasInternet && !pendingData.isEmpty {
            log("⬆️ Uploading to cloud...")
            await uploadPendingData()
        }
    }
    
    // MARK: - Upload Pending Data (when internet available)
    func uploadPendingData() async {
        guard hasInternet else {
            log("⏳ No internet - will upload later")
            return
        }
        
        guard !pendingData.isEmpty else {
            return
        }
        
        isSyncing = true
        log("⬆️ Uploading \(pendingData.count) file(s)...")
        
        var successCount = 0
        var failedItems: [PendingSync] = []
        
        for pending in pendingData {
            do {
                // Look up truck ID from Supabase
                guard let truckId = try await lookupTruckId(slug: pending.truckSlug) else {
                    log("⚠️ Truck '\(pending.truckSlug)' not found")
                    failedItems.append(pending)
                    continue
                }
                
                // Convert CodableValue back to Any
                let convertedRows: [[String: Any]] = pending.rows.map { row in
                    var newRow: [String: Any] = [:]
                    for (key, value) in row {
                        newRow[key] = value.anyValue
                    }
                    return newRow
                }

                let uploaded = try await uploadToSupabase(
                    rows: convertedRows,
                    truckId: truckId,
                    table: pending.tableName
                )
                log("  ✓ \(uploaded) rows → \(pending.tableName)")
                successCount += 1
                
            } catch {
                log("  ❌ Upload failed")
                print("Full error: \(error)")
                failedItems.append(pending)
            }
        }
        
        // Keep only failed items for retry
        pendingData = failedItems
        savePendingToDisk()
        
        if failedItems.isEmpty {
            log("✅ All data synced to cloud!")
            syncComplete = true
        } else {
            log("⚠️ \(failedItems.count) file(s) failed - will retry")
        }
        
        isSyncing = false
        updateSyncStatus()
    }
    
    // MARK: - Truck Lookup
    private func lookupTruckId(slug: String) async throws -> String? {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/trucks?slug=eq.\(slug)&select=id") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        print("Truck lookup response: \(String(data: data, encoding: .utf8) ?? "no data")")
        
        if let trucks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let truck = trucks.first,
           let id = truck["id"] as? String {
            return id
        }
        
        return nil
    }
    
    // MARK: - FLO API Calls
    private func getFileList() async throws -> [FLOFile] {
        guard let url = URL(string: "\(floBaseURL)/daylog/list") else {
            throw SyncError.invalidURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filesArray = json["files"] as? [[String: Any]] else {
            throw SyncError.parseError
        }
        
        return filesArray.compactMap { dict -> FLOFile? in
            guard let name = dict["name"] as? String else { return nil }
            let downloaded = dict["downloaded"] as? Bool ?? false
            let size = dict["size"] as? Int ?? 0
            return FLOFile(name: name, downloaded: downloaded, size: size)
        }
    }
    
    private func downloadFile(name: String) async throws -> String {
        guard let url = URL(string: "\(floBaseURL)/daylog/download?name=\(name)") else {
            throw SyncError.invalidURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        guard let content = String(data: data, encoding: .utf8) else {
            throw SyncError.parseError
        }
        
        return content
    }
    
    private func clearDownloaded() async throws {
        guard let url = URL(string: "\(floBaseURL)/api/clear-downloaded") else {
            throw SyncError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SyncError.clearFailed
        }
    }
    
    // MARK: - CSV Parsing
    private func parseCSV(_ content: String) -> [[String: Any]] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }
        
        var rows: [[String: Any]] = []
        
        for i in 1..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            
            let parts = line.components(separatedBy: ",")
            if parts.count < 11 { continue }
            
            let row: [String: Any] = [
                "timestamp_iso": parts[0],
                "header": parts[1],
                "subheader": parts[2],
                "action": parts[3],
                "gallons": Double(parts[4]) ?? 0,
                "ounces": Double(parts[5]) ?? 0,
                "psi": Double(parts[6]) ?? 0,
                "mix": parts[7],
                "relays": parts[8],
                "lat": Double(parts[9]) ?? 0,
                "lon": Double(parts[10]) ?? 0
            ]
            
            rows.append(row)
        }
        
        return rows
    }
    
    // MARK: - Supabase Upload
    private func uploadToSupabase(rows: [[String: Any]], truckId: String, table: String) async throws -> Int {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/\(table)?on_conflict=truck_id,timestamp_iso,lat,lon,action") else {
            throw SyncError.invalidURL
        }
        
        let rowsWithTruck = rows.map { row -> [String: Any] in
            var newRow = row
            newRow["truck_id"] = truckId
            return newRow
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=ignore-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        
        let jsonData = try JSONSerialization.data(withJSONObject: rowsWithTruck)
        request.httpBody = jsonData
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        print("DEBUG: Uploaded to \(table)")
        print("DEBUG: Status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        print("DEBUG: Response body: \(String(data: responseData, encoding: .utf8) ?? "none")")
        print("DEBUG: Request body size: \(jsonData.count) bytes")
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("No HTTP response")
            throw SyncError.uploadFailed
        }
        
        print("Upload status: \(httpResponse.statusCode)")
        print("Upload response: \(String(data: responseData, encoding: .utf8) ?? "no data")")
        
        // 200-299 = success, 409 = duplicate (data already exists, that's fine)
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 409 else {
            throw SyncError.uploadFailed
        }
        
        return rows.count
    }
    
    // MARK: - Local Storage (UserDefaults for simplicity)
    private func savePendingToDisk() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(pendingData) {
            UserDefaults.standard.set(data, forKey: "pendingSync")
        }
        pendingFiles = pendingData.count
    }
    
    private func loadPendingFromDisk() {
        if let data = UserDefaults.standard.data(forKey: "pendingSync"),
           let pending = try? JSONDecoder().decode([PendingSync].self, from: data) {
            pendingData = pending
            pendingFiles = pending.count
        }
    }
    
    // MARK: - Status
    private func updateSyncStatus() {
        pendingFiles = pendingData.count
        if pendingFiles == 0 && !isSyncing {
            syncComplete = true
        } else {
            syncComplete = false
        }
    }
    
    // MARK: - Helpers
    private func toSlug(_ input: String) -> String {
        return input
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    
    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        let timestamp = formatter.string(from: Date())
        logText += "\n[\(timestamp)] \(message)"
        print("[SyncManager] \(message)")
    }
}

// MARK: - Supporting Types
struct FLOFile {
    let name: String
    let downloaded: Bool
    let size: Int
}

struct PendingSync: Codable {
    let truckSlug: String
    let fileName: String
    let tableName: String
    let rows: [[String: CodableValue]]
    let downloadedAt: Date
    
    init(truckSlug: String, fileName: String, tableName: String, rows: [[String: Any]], downloadedAt: Date) {
        self.truckSlug = truckSlug
        self.fileName = fileName
        self.tableName = tableName
        self.downloadedAt = downloadedAt
        
        // Convert [String: Any] to [String: CodableValue]
        self.rows = rows.map { row in
            var codableRow: [String: CodableValue] = [:]
            for (key, value) in row {
                if let str = value as? String {
                    codableRow[key] = .string(str)
                } else if let num = value as? Double {
                    codableRow[key] = .double(num)
                } else if let num = value as? Int {
                    codableRow[key] = .int(num)
                }
            }
            return codableRow
        }
    }
}

enum CodableValue: Codable {
    case string(String)
    case double(Double)
    case int(Int)
    
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .double(let d): return d
        case .int(let i): return i
        }
    }
}

enum SyncError: Error {
    case invalidURL
    case parseError
    case uploadFailed
    case clearFailed
}
