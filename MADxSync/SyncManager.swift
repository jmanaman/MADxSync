//
//  SyncManager.swift
//  MADxSync
//
//  Created by Justin Manning on 1/29/26.
//
//  FIXED: 2026-03-06 — FLO communication now delegates to FLOService exclusively.
//  Previously, sync() used its own URLSession.shared calls to fetch the daylog
//  file list, download CSVs, and clear downloaded files. URLSession.shared routes
//  over whatever interface iOS prefers — which is LTE when iOS enables it alongside
//  FLO WiFi (because FLO has no internet). This caused silent download failures
//  in the field: the sync appeared to run but downloaded nothing.
//
//  Fix: replaced getFileList(), downloadFile(), and clearDownloaded() with calls
//  to FLOService.fetchDaylogList(), FLOService.downloadDaylog(), and
//  FLOService.clearDownloadedFiles(). FLOService uses a WiFi-pinned URLSession
//  (allowsCellularAccess = false) that always reaches 192.168.4.1 regardless of
//  iOS routing preferences. Also removed the now-redundant FLOFile struct.

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
    // NOTE: floBaseURL removed — all FLO communication now goes through FLOService.
    private let supabaseURL = SupabaseConfig.url
    private let supabaseKey = SupabaseConfig.publishableKey
    
    // MARK: - Local Storage
    private var pendingData: [PendingSync] = []
    private let pendingFileURL: URL
        
    // MARK: - Network Monitor
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    
    // MARK: - FLO Polling Timer
    private var floPollingTimer: Timer?
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        pendingFileURL = docs.appendingPathComponent("pending_syncs.json")
        migrateFromUserDefaults()
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
        // Delegate to FLOService — it owns the WiFi-pinned session and identity check.
        // We just mirror its connected state here for the SyncView UI.
        await FLOService.shared.fetchIdentity()
        
        let wasConnected = floConnected
        floConnected = FLOService.shared.isConnected
        truckName = FLOService.shared.truckName.isEmpty ? nil : FLOService.shared.truckName
        floStatus = floConnected ? "Connected" : "Not connected"
        
        if floConnected && !wasConnected {
            log("📡 Connected to FLO: \(FLOService.shared.truckName)")
        } else if !floConnected && wasConnected {
            log("📡 FLO disconnected")
        }
        
        updateSyncStatus()
    }
    
    // MARK: - Main Sync (Download from FLO)
    //
    // All FLO HTTP calls now go through FLOService, which uses a WiFi-pinned
    // URLSession (allowsCellularAccess = false). This guarantees requests always
    // reach 192.168.4.1 over WiFi even when iOS has enabled LTE in the background.
    func sync() async {
        guard floConnected else {
            log("❌ Not connected to FLO")
            return
        }
        
        guard EquipmentService.shared.hasEquipmentSelected else {
            log("❌ No equipment selected — pick equipment in Settings first")
            return
        }
        
        isSyncing = true
        syncComplete = false
        log("⬇️ Downloading from FLO...")
        
        // Step 1: Get file list via FLOService (WiFi-pinned)
        let files = await FLOService.shared.fetchDaylogList()

        if files.isEmpty {
            log("✓ No files on FLO")
            isSyncing = false
            updateSyncStatus()
            return
        }

        log("Found \(files.count) file(s)")

        // Step 2: Download each file via FLOService (WiFi-pinned)
        var downloadedCount = 0
        for file in files {
            log("  📄 \(file.name)")
            
            guard let csvContent = await FLOService.shared.downloadDaylog(name: file.name) else {
                log("  ⚠️ \(file.name) — download returned nil, skipping")
                continue
            }
            
            let rows = parseCSV(csvContent)
            
            if rows.isEmpty {
                log("  ⚠️ \(file.name) — no parseable rows, skipping")
                continue
            }
            
            log("    └ \(rows.count) rows")
            
            // Determine table based on filename
            let tableName = file.name.contains(".manual") ? "viewer_logs" : "source_logs"
            
            // Store locally for upload — stamp with compound identifier
            // SAFETY: Guard against nil equipment code. The hasEquipmentSelected guard at the
            // top of sync() should prevent this, but equipment could be cleared by a reactive
            // SwiftUI update between the guard and here. Log the anomaly and use a traceable fallback.
            let truckIdForSync: String
            if let opId = EquipmentService.shared.operatorIdentifier {
                truckIdForSync = opId
            } else if let eqCode = EquipmentService.shared.selectedEquipmentCode {
                truckIdForSync = eqCode
            } else {
                log("⚠️ Equipment cleared mid-sync — stamping as UNKNOWN")
                truckIdForSync = "UNKNOWN"
            }
            
            let pending = PendingSync(
                truckId: truckIdForSync,
                fileName: file.name,
                tableName: tableName,
                rows: rows,
                downloadedAt: Date()
            )
            pendingData.append(pending)
            downloadedCount += 1
        }
        
        // Step 3: Save to disk before clearing FLO
        // IMPORTANT: Save happens before clear. If clear fails, we still have the data
        // locally and won't re-download on next sync (Supabase upsert dedupes anyway).
        savePendingToDisk()
        
        // Step 4: Clear downloaded files from FLO via FLOService (WiFi-pinned)
        if downloadedCount > 0 {
            let cleared = await FLOService.shared.clearDownloadedFiles()
            if cleared {
                log("✅ Downloaded \(downloadedCount) file(s)")
            } else {
                // Non-fatal — files will be re-downloaded next sync but Supabase dedupes
                log("✅ Downloaded \(downloadedCount) file(s) — ⚠️ clear failed (will re-download next sync, deduped)")
            }
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
                let truckId = pending.truckId
                
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
                "header":        parts[1],
                "subheader":     parts[2],
                "action":        parts[3],
                "gallons":       Double(parts[4]) ?? 0,
                "ounces":        Double(parts[5]) ?? 0,
                "psi":           Double(parts[6]) ?? 0,
                "mix":           parts[7],
                "relays":        parts[8],
                "lat":           Double(parts[9]) ?? 0,
                "lon":           Double(parts[10]) ?? 0
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
            newRow["district_id"] = AuthService.shared.districtId ?? ""
            return newRow
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
    
    // MARK: - Local Storage (file-based)
    private func savePendingToDisk() {
        do {
            let data = try JSONEncoder().encode(pendingData)
            try data.write(to: pendingFileURL, options: .atomic)
        } catch {
            print("[SyncManager] ⚠️ Failed to save pending data: \(error)")
        }
        pendingFiles = pendingData.count
    }

    private func loadPendingFromDisk() {
        do {
            let data = try Data(contentsOf: pendingFileURL)
            let pending = try JSONDecoder().decode([PendingSync].self, from: data)
            pendingData = pending
            pendingFiles = pending.count
        } catch {
            // File doesn't exist yet or decode failed — start fresh
            pendingData = []
            pendingFiles = 0
        }
    }

    /// One-time migration: move pending data from UserDefaults to file storage
    private func migrateFromUserDefaults() {
        guard let legacyData = UserDefaults.standard.data(forKey: "pendingSync") else {
            return  // Nothing to migrate
        }
        
        // Only migrate if the file doesn't already exist
        guard !FileManager.default.fileExists(atPath: pendingFileURL.path) else {
            // File already exists, just clean up the old key
            UserDefaults.standard.removeObject(forKey: "pendingSync")
            print("[SyncManager] Cleaned up legacy UserDefaults key")
            return
        }
        
        do {
            // Verify it's valid data before migrating
            _ = try JSONDecoder().decode([PendingSync].self, from: legacyData)
            try legacyData.write(to: pendingFileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: "pendingSync")
            print("[SyncManager] ✓ Migrated pending data from UserDefaults to file storage")
        } catch {
            // Don't delete from UserDefaults if file write failed — data is preserved
            print("[SyncManager] ⚠️ Migration failed, keeping UserDefaults data: \(error)")
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
    
    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        let timestamp = formatter.string(from: Date())
        logText += "\n[\(timestamp)] \(message)"
        print("[SyncManager] \(message)")
    }
}

// MARK: - Supporting Types

// NOTE: FLOFile struct removed. FLOService.DaylogFile is now used directly.
// If any other file referenced FLOFile, update those references to FLOService.DaylogFile.

struct PendingSync: Codable {
    let truckId: String
    let fileName: String
    let tableName: String
    let rows: [[String: CodableValue]]
    let downloadedAt: Date
    
    init(truckId: String, fileName: String, tableName: String, rows: [[String: Any]], downloadedAt: Date) {
        self.truckId = truckId
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
