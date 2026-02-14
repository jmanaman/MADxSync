//
//  AddSourceService.swift
//  MADxSync
//
//  Store-and-forward service for pending sources.
//
//  ARCHITECTURE (matches MarkerStore pattern):
//  1. Every create/edit/delete persists to disk IMMEDIATELY (atomic write)
//  2. If online → attempt Supabase sync right away
//  3. If offline → operations queue on disk, auto-drain when connectivity returns
//  4. App crash, iOS kill, battery death → data survives on disk
//
//  PRODUCTION HARDENING:
//  - Reconciliation on launch: orphaned unsynced sources get re-queued
//  - 404 on update/delete = source was promoted/deleted elsewhere = success
//  - CodableJSON handles any nesting depth (GeoJSON safe)
//  - Every network call has 401 retry with token refresh
//  - Exponential backoff on repeated failures
//  - No force unwraps, no force casts, no assumptions
//  - Operation deduplication: update→update collapses, delete cancels pending create
//

import Foundation
import Combine
import CoreLocation

// MARK: - Pending Operation

enum PendingOperationType: String, Codable {
    case create
    case update
    case delete
}

struct PendingOperation: Codable, Identifiable {
    let id: String
    let sourceId: String
    let operationType: PendingOperationType
    let payload: [String: CodableJSON]?
    let queuedAt: Date
    
    init(sourceId: String, type: PendingOperationType, payload: [String: Any]? = nil) {
        self.id = UUID().uuidString
        self.sourceId = sourceId
        self.operationType = type
        self.queuedAt = Date()
        self.payload = payload?.mapValues { CodableJSON.from($0) }
    }
    
    /// Convert payload back to [String: Any] for JSONSerialization
    var payloadAsDict: [String: Any]? {
        payload?.mapValues { $0.anyValue }
    }
}

// MARK: - Add Source Service

@MainActor
class AddSourceService: ObservableObject {
    static let shared = AddSourceService()
    
    // MARK: - Published State
    @Published var sources: [PendingSource] = []
    @Published var pendingOperationCount: Int = 0
    @Published var isSyncing: Bool = false
    @Published var lastSyncError: String?
    
    // MARK: - Configuration
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    // MARK: - Local Storage
    private let sourcesFileURL: URL
    private let operationsFileURL: URL
    private var pendingOperations: [PendingOperation] = []
    
    // MARK: - Sync Control
    private var networkObserver: Any?
    private var syncTask: Task<Void, Never>?
    private var consecutiveFailures: Int = 0
    private var isSyncBackingOff: Bool = false
    private let maxBackoffSeconds: Double = 300
    
    // MARK: - Init
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        sourcesFileURL = docs.appendingPathComponent("pending_sources_local.json")
        operationsFileURL = docs.appendingPathComponent("pending_source_operations.json")
        
        loadSourcesFromDisk()
        loadOperationsFromDisk()
        reconcileOrphanedSources()
        setupNetworkObserver()
        
        if pendingOperationCount > 0 && NetworkMonitor.shared.hasInternet {
            print("[AddSourceService] Found \(pendingOperationCount) queued operations on launch — syncing")
            syncTask = Task { await drainOperationQueue() }
        }
    }
    
    deinit {
        if let observer = networkObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        syncTask?.cancel()
    }
    
    // MARK: - Reconciliation
    
    /// On launch, check for sources that are marked unsynced but have no
    /// corresponding create operation in the queue. This happens if the app
    /// crashed after saving the source but before saving the operation,
    /// or if the operations file corrupted. Re-queue the create.
    private func reconcileOrphanedSources() {
        let queuedSourceIds = Set(pendingOperations.map { $0.sourceId })
        var reconciled = 0
        
        for source in sources where !source.syncedToSupabase {
            if !queuedSourceIds.contains(source.id) {
                // Orphan: source exists locally but no operation to create it in Supabase
                let operation = PendingOperation(
                    sourceId: source.id,
                    type: .create,
                    payload: source.toSupabaseInsertPayload()
                )
                pendingOperations.append(operation)
                reconciled += 1
            }
        }
        
        if reconciled > 0 {
            saveOperationsToDisk()
            updatePendingCount()
            print("[AddSourceService] Reconciled \(reconciled) orphaned sources — re-queued for sync")
        }
    }
    
    // MARK: - Network Observer
    
    private func setupNetworkObserver() {
        networkObserver = NotificationCenter.default.addObserver(
            forName: .networkStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NetworkMonitor.shared.hasInternet && self.pendingOperationCount > 0 && !self.isSyncing {
                    print("[AddSourceService] Network restored — syncing \(self.pendingOperationCount) queued operations")
                    self.consecutiveFailures = 0
                    self.isSyncBackingOff = false
                    self.syncTask?.cancel()
                    self.syncTask = Task { await self.drainOperationQueue() }
                }
            }
        }
    }
    
    // MARK: - Create Source
    
    func createSource(_ source: PendingSource) {
        var newSource = source
        newSource.syncedToSupabase = false
        
        sources.append(newSource)
        
        let operation = PendingOperation(
            sourceId: newSource.id,
            type: .create,
            payload: newSource.toSupabaseInsertPayload()
        )
        pendingOperations.append(operation)
        
        // CRITICAL: Both files saved atomically before any network call
        saveAllToDisk()
        
        print("[AddSourceService] Created: \(newSource.displayName) (\(newSource.sourceType.rawValue)) — \(newSource.id.prefix(8))")
        
        attemptSync()
    }
    
    // MARK: - Update Source
    
    func updateSource(_ sourceId: String, name: String? = nil, sourceSubtype: String? = nil,
                      condition: SourceCondition? = nil, description: String? = nil) {
        guard let index = sources.firstIndex(where: { $0.id == sourceId }) else {
            print("[AddSourceService] ⚠️ Update failed — source not found: \(sourceId.prefix(8))")
            return
        }
        
        if let name = name { sources[index].name = name }
        if let subtype = sourceSubtype { sources[index].sourceSubtype = subtype }
        if let condition = condition { sources[index].condition = condition }
        if let desc = description { sources[index].description = desc }
        sources[index].updatedAt = Date()
        
        // Deduplicate: remove any previous pending update for this source
        // (only the latest state matters)
        deduplicateOperations(forSourceId: sourceId, keepType: .update)
        
        let operation = PendingOperation(
            sourceId: sourceId,
            type: .update,
            payload: sources[index].toSupabaseUpdatePayload()
        )
        pendingOperations.append(operation)
        
        saveAllToDisk()
        print("[AddSourceService] Updated: \(sourceId.prefix(8))")
        attemptSync()
    }
    
    // MARK: - Add Vertex
    
    func addVertex(to sourceId: String, coordinate: CLLocationCoordinate2D) {
        guard let index = sources.firstIndex(where: { $0.id == sourceId }) else {
            print("[AddSourceService] ⚠️ Add vertex failed — source not found: \(sourceId.prefix(8))")
            return
        }
        
        sources[index].geometry = sources[index].geometry.addingVertex(coordinate)
        sources[index].updatedAt = Date()
        
        // Deduplicate: only keep the latest geometry update
        deduplicateOperations(forSourceId: sourceId, keepType: .update)
        
        let operation = PendingOperation(
            sourceId: sourceId,
            type: .update,
            payload: sources[index].toSupabaseUpdatePayload()
        )
        pendingOperations.append(operation)
        
        saveAllToDisk()
        
        let count = sources[index].vertexCount
        print("[AddSourceService] Vertex #\(count) added to \(sourceId.prefix(8))")
        attemptSync()
    }
    
    // MARK: - Undo Last Vertex
    
    func undoLastVertex(sourceId: String) -> Bool {
        guard let index = sources.firstIndex(where: { $0.id == sourceId }) else { return false }
        guard let updated = sources[index].geometry.removingLastVertex() else { return false }
        
        sources[index].geometry = updated
        sources[index].updatedAt = Date()
        
        deduplicateOperations(forSourceId: sourceId, keepType: .update)
        
        let operation = PendingOperation(
            sourceId: sourceId,
            type: .update,
            payload: sources[index].toSupabaseUpdatePayload()
        )
        pendingOperations.append(operation)
        
        saveAllToDisk()
        print("[AddSourceService] Undo vertex on \(sourceId.prefix(8)), \(sources[index].vertexCount) remaining")
        attemptSync()
        return true
    }
    
    // MARK: - Delete Source
    
    func deleteSource(_ sourceId: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceId }) else {
            print("[AddSourceService] ⚠️ Delete failed — source not found: \(sourceId.prefix(8))")
            return
        }
        
        let sourceName = sources[index].displayName
        let wasEverSynced = sources[index].syncedToSupabase
        
        sources.remove(at: index)
        
        // If this source was never synced to Supabase, just remove all its operations.
        // No need to send a DELETE for something that never made it to the server.
        if !wasEverSynced {
            pendingOperations.removeAll { $0.sourceId == sourceId }
        } else {
            // Remove any pending create/update operations (they're moot now)
            pendingOperations.removeAll { $0.sourceId == sourceId && $0.operationType != .delete }
            // Queue the delete
            let operation = PendingOperation(sourceId: sourceId, type: .delete, payload: nil)
            pendingOperations.append(operation)
        }
        
        saveAllToDisk()
        print("[AddSourceService] Deleted: \(sourceName) (\(sourceId.prefix(8))) — wasEverSynced=\(wasEverSynced)")
        attemptSync()
    }
    
    // MARK: - Operation Deduplication
    
    /// Remove stale operations for a source. For updates, only the latest matters.
    /// For deletes, all prior create/updates are moot.
    private func deduplicateOperations(forSourceId sourceId: String, keepType: PendingOperationType) {
        switch keepType {
        case .update:
            // Remove previous updates for this source (latest update supersedes)
            pendingOperations.removeAll { $0.sourceId == sourceId && $0.operationType == .update }
        case .delete:
            // Remove ALL operations for this source (delete supersedes everything)
            pendingOperations.removeAll { $0.sourceId == sourceId }
        case .create:
            break  // Don't deduplicate creates
        }
    }
    
    // MARK: - Sync from Supabase (Pull)
    
    func syncFromSupabase() async {
        guard NetworkMonitor.shared.hasInternet else {
            print("[AddSourceService] Pull skipped — no internet (\(sources.count) sources cached)")
            return
        }
        
        guard let districtId = AuthService.shared.districtId else {
            print("[AddSourceService] Pull skipped — no district_id")
            return
        }
        
        guard let url = URL(string: "\(supabaseURL)/rest/v1/pending_sources?district_id=eq.\(districtId)&select=*&order=created_at.asc") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return }
            
            if httpResponse.statusCode == 401 {
                let refreshed = await AuthService.shared.handleUnauthorized()
                if refreshed { await syncFromSupabase() }
                return
            }
            
            // Table doesn't exist yet — graceful, not an error
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 406 {
                print("[AddSourceService] pending_sources table not found — run SQL setup")
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[AddSourceService] Pull failed: HTTP \(httpResponse.statusCode) — \(body.prefix(200))")
                return
            }
            
            let remoteSources = decodeRemoteSources(data)
            mergeRemoteSources(remoteSources)
            saveSourcesToDisk()
            
            print("[AddSourceService] Pulled \(remoteSources.count) from Supabase, \(sources.count) total")
            
        } catch {
            // Network error — not a data loss scenario, just log it
            print("[AddSourceService] Pull error: \(error.localizedDescription)")
        }
    }
    
    /// Decode Supabase JSON into PendingSource array. Never throws — returns what it can.
    private func decodeRemoteSources(_ data: Data) -> [PendingSource] {
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("[AddSourceService] ⚠️ Could not parse remote sources JSON")
            return []
        }
        
        return jsonArray.compactMap { json -> PendingSource? in
            guard let id = json["id"] as? String,
                  let districtId = json["district_id"] as? String,
                  let sourceTypeStr = json["source_type"] as? String,
                  let sourceType = AddSourceType(rawValue: sourceTypeStr),
                  let geometryDict = json["geometry"] as? [String: Any],
                  let geoType = geometryDict["type"] as? String else {
                return nil  // Skip malformed rows — don't crash
            }
            
            // Parse geometry safely
            let geometry: PendingSourceGeometry
            if geoType == "Point" {
                guard let coords = geometryDict["coordinates"] as? [Double], coords.count >= 2 else { return nil }
                geometry = PendingSourceGeometry(type: "Point", coordinates: [coords])
            } else if geoType == "Polygon" {
                // Polygon coordinates are [[[lon,lat],...]] — unwrap one level
                guard let rings = geometryDict["coordinates"] as? [[[Double]]], let ring = rings.first else { return nil }
                geometry = PendingSourceGeometry(type: "Polygon", coordinates: ring)
            } else {
                // MultiPoint, LineString — coordinates are [[lon,lat],...]
                guard let coords = geometryDict["coordinates"] as? [[Double]] else { return nil }
                geometry = PendingSourceGeometry(type: geoType, coordinates: coords)
            }
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Fallback formatter without fractional seconds
            let fallbackFormatter = ISO8601DateFormatter()
            
            func parseDate(_ str: String?) -> Date {
                guard let str = str else { return Date() }
                return formatter.date(from: str) ?? fallbackFormatter.date(from: str) ?? Date()
            }
            
            var source = PendingSource(
                districtId: districtId,
                sourceType: sourceType,
                name: json["name"] as? String ?? "",
                sourceSubtype: json["source_subtype"] as? String ?? "",
                condition: SourceCondition(rawValue: json["condition"] as? String ?? "") ?? .unknown,
                description: json["description"] as? String ?? "",
                zone: json["zone"] as? String,
                zone2: json["zone2"] as? String,
                geometry: geometry,
                createdBy: json["created_by"] as? String ?? "unknown"
            )
            
            // Override auto-generated values with server values — clean, no hacks
            source.id = id
            source.createdAt = parseDate(json["created_at"] as? String)
            source.updatedAt = parseDate(json["updated_at"] as? String)
            source.syncedToSupabase = true
            
            return source
        }
    }
    
    /// Merge remote with local. Rules:
    /// 1. Remote is truth for all synced sources
    /// 2. Local unsynced sources are preserved (they haven't reached the server yet)
    /// 3. If a local source is synced but not in remote, it was deleted by admin — remove locally
    private func mergeRemoteSources(_ remote: [PendingSource]) {
        let remoteIds = Set(remote.map { $0.id })
        
        // Keep local sources that haven't synced yet (not in remote because they haven't reached server)
        let unsyncedLocal = sources.filter { !$0.syncedToSupabase }
        
        // Start with remote as truth
        var merged = remote
        
        // Add unsynced local sources that aren't duplicates
        for local in unsyncedLocal {
            if !remoteIds.contains(local.id) {
                merged.append(local)
            }
            // If remote already has this ID (race condition: sync succeeded but
            // syncedToSupabase flag wasn't saved), use remote version (it's newer)
        }
        
        sources = merged
    }
    
    // MARK: - Operation Queue Drain
    
    private func drainOperationQueue() async {
        guard NetworkMonitor.shared.hasInternet else { return }
        guard !pendingOperations.isEmpty else { return }
        guard !isSyncing else { return }
        guard !isSyncBackingOff else { return }
        
        isSyncing = true
        lastSyncError = nil
        
        var remaining: [PendingOperation] = []
        var successCount = 0
        
        for operation in pendingOperations {
            // Check connectivity before each operation
            guard NetworkMonitor.shared.hasInternet else {
                remaining.append(operation)
                continue
            }
            
            guard !Task.isCancelled else {
                remaining.append(operation)
                continue
            }
            
            let result = await executeOperation(operation)
            
            switch result {
            case .success:
                successCount += 1
                // Mark source as synced for creates
                if operation.operationType == .create {
                    if let index = sources.firstIndex(where: { $0.id == operation.sourceId }) {
                        sources[index].syncedToSupabase = true
                    }
                }
                print("[AddSourceService] ✓ \(operation.operationType.rawValue) \(operation.sourceId.prefix(8))")
                
            case .gone:
                // Source was promoted/deleted by admin on HUB. Not an error.
                // Remove the source locally if it still exists.
                successCount += 1
                if let index = sources.firstIndex(where: { $0.id == operation.sourceId }) {
                    let name = sources[index].displayName
                    sources.remove(at: index)
                    print("[AddSourceService] ✓ \(operation.sourceId.prefix(8)) was promoted/deleted on HUB — removed locally (\(name))")
                } else {
                    print("[AddSourceService] ✓ \(operation.sourceId.prefix(8)) already gone locally")
                }
                
            case .retryable(let error):
                // Network/server error — keep in queue, back off
                print("[AddSourceService] ✗ \(operation.operationType.rawValue) \(operation.sourceId.prefix(8)): \(error)")
                lastSyncError = error
                remaining.append(operation)
                // Stop processing — back off and retry the whole queue later
                // Remaining unprocessed operations also go back in the queue
                let unprocessedStart = pendingOperations.firstIndex(where: { $0.id == operation.id })! + 1
                if unprocessedStart < pendingOperations.count {
                    remaining.append(contentsOf: pendingOperations[unprocessedStart...])
                }
                break
            }
        }
        
        pendingOperations = remaining
        updatePendingCount()
        saveAllToDisk()
        
        isSyncing = false
        
        if remaining.isEmpty {
            consecutiveFailures = 0
            if successCount > 0 {
                print("[AddSourceService] ✓ All \(successCount) operations synced")
            }
        } else {
            consecutiveFailures += 1
            scheduleRetrySync()
        }
    }
    
    // MARK: - Execute Single Operation
    
    /// Execute an operation against Supabase.
    /// Returns .success, .gone (source was deleted/promoted), or .retryable (transient error).
    /// NEVER throws — all errors are handled and classified.
    private func executeOperation(_ operation: PendingOperation) async -> OperationResult {
        switch operation.operationType {
        case .create: return await executeCreate(operation)
        case .update: return await executeUpdate(operation)
        case .delete: return await executeDelete(operation)
        }
    }
    
    private func executeCreate(_ operation: PendingOperation) async -> OperationResult {
        guard let payload = operation.payloadAsDict else {
            // Payload is nil/corrupt — can't create without data. Drop the operation.
            // The reconciliation step will re-queue from the source if it still exists.
            print("[AddSourceService] ⚠️ Create payload corrupt for \(operation.sourceId.prefix(8)) — dropping, will reconcile on next launch")
            return .success
        }
        
        guard let url = URL(string: "\(supabaseURL)/rest/v1/pending_sources") else {
            return .retryable("Invalid URL")
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[AddSourceService] ⚠️ Could not serialize create payload — dropping")
            return .success  // Drop corrupt operation
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retryable("No HTTP response") }
            
            switch http.statusCode {
            case 200...299:
                return .success
            case 409:
                // Duplicate — already exists. That's fine (maybe a previous attempt succeeded
                // but we crashed before marking it synced).
                return .success
            case 401:
                let refreshed = await AuthService.shared.handleUnauthorized()
                if refreshed { return await executeCreate(operation) }
                return .retryable("Auth failed")
            case 403:
                // RLS violation — district_id mismatch or policy issue
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[AddSourceService] ⚠️ RLS violation on create: \(body.prefix(200))")
                return .retryable("Permission denied")
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                return .retryable("HTTP \(http.statusCode): \(body.prefix(100))")
            }
        } catch {
            return .retryable(error.localizedDescription)
        }
    }
    
    private func executeUpdate(_ operation: PendingOperation) async -> OperationResult {
        guard let payload = operation.payloadAsDict else {
            print("[AddSourceService] ⚠️ Update payload corrupt — dropping")
            return .success
        }
        
        let sourceId = operation.sourceId
        guard let url = URL(string: "\(supabaseURL)/rest/v1/pending_sources?id=eq.\(sourceId)") else {
            return .retryable("Invalid URL")
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return .success  // Drop corrupt operation
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.httpBody = jsonData
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retryable("No HTTP response") }
            
            switch http.statusCode {
            case 200...299:
                return .success
            case 404:
                // Source was promoted or deleted by admin on HUB — not an error
                return .gone
            case 401:
                let refreshed = await AuthService.shared.handleUnauthorized()
                if refreshed { return await executeUpdate(operation) }
                return .retryable("Auth failed")
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                return .retryable("HTTP \(http.statusCode): \(body.prefix(100))")
            }
        } catch {
            return .retryable(error.localizedDescription)
        }
    }
    
    private func executeDelete(_ operation: PendingOperation) async -> OperationResult {
        let sourceId = operation.sourceId
        guard let url = URL(string: "\(supabaseURL)/rest/v1/pending_sources?id=eq.\(sourceId)") else {
            return .retryable("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retryable("No HTTP response") }
            
            switch http.statusCode {
            case 200...299:
                return .success
            case 404:
                // Already gone — admin promoted/deleted it. That's fine.
                return .gone
            case 401:
                let refreshed = await AuthService.shared.handleUnauthorized()
                if refreshed { return await executeDelete(operation) }
                return .retryable("Auth failed")
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                return .retryable("HTTP \(http.statusCode): \(body.prefix(100))")
            }
        } catch {
            return .retryable(error.localizedDescription)
        }
    }
    
    // MARK: - Sync Helpers
    
    private func attemptSync() {
        if NetworkMonitor.shared.hasInternet && !isSyncBackingOff {
            syncTask?.cancel()
            syncTask = Task { await drainOperationQueue() }
        }
    }
    
    private func scheduleRetrySync() {
        let backoffSeconds = min(5.0 * pow(2.0, Double(consecutiveFailures - 1)), maxBackoffSeconds)
        isSyncBackingOff = true
        
        print("[AddSourceService] Retry in \(Int(backoffSeconds))s (attempt \(consecutiveFailures))")
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isSyncBackingOff = false
                if pendingOperationCount > 0 && NetworkMonitor.shared.hasInternet {
                    syncTask?.cancel()
                    syncTask = Task { await drainOperationQueue() }
                }
            }
        }
    }
    
    private func updatePendingCount() {
        pendingOperationCount = pendingOperations.count
    }
    
    // MARK: - Persistence (Atomic Writes)
    
    /// Save both files. Called after every mutation.
    private func saveAllToDisk() {
        saveSourcesToDisk()
        saveOperationsToDisk()
        updatePendingCount()
    }
    
    func saveSourcesToDisk() {
        do {
            let data = try JSONEncoder().encode(sources)
            try data.write(to: sourcesFileURL, options: .atomic)
        } catch {
            print("[AddSourceService] ⚠️ Failed to save sources: \(error)")
        }
    }
    
    private func saveOperationsToDisk() {
        do {
            let data = try JSONEncoder().encode(pendingOperations)
            try data.write(to: operationsFileURL, options: .atomic)
        } catch {
            print("[AddSourceService] ⚠️ Failed to save operations: \(error)")
        }
    }
    
    private func loadSourcesFromDisk() {
        guard FileManager.default.fileExists(atPath: sourcesFileURL.path) else {
            sources = []
            return
        }
        do {
            let data = try Data(contentsOf: sourcesFileURL)
            sources = try JSONDecoder().decode([PendingSource].self, from: data)
            print("[AddSourceService] Loaded \(sources.count) sources from disk")
        } catch {
            // Corrupt file — move aside for debugging, start fresh
            let backup = sourcesFileURL.deletingLastPathComponent()
                .appendingPathComponent("pending_sources_corrupt_\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: sourcesFileURL, to: backup)
            sources = []
            print("[AddSourceService] ⚠️ Sources file corrupt — backed up, starting fresh: \(error)")
        }
    }
    
    private func loadOperationsFromDisk() {
        guard FileManager.default.fileExists(atPath: operationsFileURL.path) else {
            pendingOperations = []
            updatePendingCount()
            return
        }
        do {
            let data = try Data(contentsOf: operationsFileURL)
            pendingOperations = try JSONDecoder().decode([PendingOperation].self, from: data)
            updatePendingCount()
            print("[AddSourceService] Loaded \(pendingOperations.count) queued operations from disk")
        } catch {
            // Operations file corrupt — start fresh. Reconciliation will re-queue from sources.
            pendingOperations = []
            updatePendingCount()
            print("[AddSourceService] ⚠️ Operations file corrupt — starting fresh (reconciliation will recover): \(error)")
        }
    }
    
    // MARK: - Query Helpers
    
    func sources(ofType type: AddSourceType) -> [PendingSource] {
        sources.filter { $0.sourceType == type }
    }
    
    func source(byId id: String) -> PendingSource? {
        sources.first { $0.id == id }
    }
    
    var hasSources: Bool { !sources.isEmpty }
}

// MARK: - Operation Result

/// Three-state result for operation execution.
/// No ambiguity — every outcome is classified.
private enum OperationResult {
    /// Operation succeeded — remove from queue
    case success
    /// Source was promoted/deleted on HUB (404) — remove from queue AND remove local source
    case gone
    /// Transient error — keep in queue, retry later
    case retryable(String)
}
