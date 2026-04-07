//
//  WorkingNotesService.swift
//  MADxSync
//
//  Field Discussion Tool — editable scratchpad notes on sources.
//  One note per source. Techs edit back and forth, delete when done.
//  Multi-tenant: all queries scoped by district_id.
//
//  Syncs via HubSyncService on 60-second polling cycle.
//  Saves immediately when tech has network.
//

import Foundation
import Combine

/// A single working note attached to a source
struct WorkingNote: Codable, Identifiable {
    let id: String
    let districtId: String
    let sourceId: String
    let sourceType: String
    var noteText: String
    let createdAt: String
    var updatedAt: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case districtId = "district_id"
        case sourceId = "source_id"
        case sourceType = "source_type"
        case noteText = "note_text"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

@MainActor
final class WorkingNotesService: ObservableObject {
    
    static let shared = WorkingNotesService()
    
    // MARK: - Published State
    
    /// All working notes for this district, keyed by "sourceType_sourceId"
    @Published var notes: [String: WorkingNote] = [:]
    
    // MARK: - Configuration
    
    private let supabaseURL = SupabaseConfig.url
    private let supabaseKey = SupabaseConfig.publishableKey
    private let requestTimeout: TimeInterval = 15.0
    
    private init() {}
    
    // MARK: - Cache Key
    
    func makeKey(sourceType: String, sourceId: String) -> String {
        return "\(sourceType)_\(sourceId)"
    }
    
    // MARK: - Get Note
    
    func getNote(sourceType: String, sourceId: String) -> WorkingNote? {
        let key = makeKey(sourceType: sourceType, sourceId: sourceId)
        return notes[key]
    }
    
    // MARK: - Pull All (called by HubSyncService)
    
    func pullFromHub() async {
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else { return }
        
        let urlString = "\(supabaseURL)/rest/v1/source_working_notes?district_id=eq.\(districtId)&select=*"
        guard let url = URL(string: urlString) else { return }
        
        do {
            let data = try await authenticatedGET(url: url)
            let decoded = try JSONDecoder().decode([WorkingNote].self, from: data)
            
            var newNotes: [String: WorkingNote] = [:]
            for note in decoded {
                let key = makeKey(sourceType: note.sourceType, sourceId: note.sourceId)
                newNotes[key] = note
            }
            
            // Only update if changed
            if newNotes.count != notes.count || newNotes.keys.sorted() != notes.keys.sorted() {
                notes = newNotes
            } else {
                // Check if any note text changed
                for (key, newNote) in newNotes {
                    if notes[key]?.noteText != newNote.noteText || notes[key]?.updatedAt != newNote.updatedAt {
                        notes = newNotes
                        break
                    }
                }
            }
            
        } catch {
            // Silent failure — console only
            print("[WorkingNotes] Pull failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Save Note
    
    func save(sourceType: String, sourceId: String, noteText: String) async -> Bool {
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else {
            print("[WorkingNotes] No district_id — cannot save")
            return false
        }
        
        let urlString = "\(supabaseURL)/rest/v1/source_working_notes?on_conflict=district_id,source_type,source_id"
        guard let url = URL(string: urlString) else { return false }
        
        let body: [String: Any] = [
            "district_id": districtId,
            "source_type": sourceType,
            "source_id": sourceId,
            "note_text": noteText
        ]
        
        print("[WorkingNotes] Saving: district=\(districtId) type=\(sourceType) id=\(sourceId) text=\(noteText.prefix(30))...")
        print("[WorkingNotes] Auth token present: \(AuthService.shared.accessToken != nil)")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            
            // Build request manually for better logging
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = requestTimeout
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
            request.setValue("return=representation,resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
            
            if let token = AuthService.shared.accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            
            print("[WorkingNotes] Response: HTTP \(httpResponse?.statusCode ?? 0)")
            print("[WorkingNotes] Body: \(responseBody)")
            
            guard let status = httpResponse?.statusCode, (200...299).contains(status) else {
                print("[WorkingNotes] Save FAILED with HTTP \(httpResponse?.statusCode ?? 0)")
                return false
            }
            
            // Update local cache immediately
            let key = makeKey(sourceType: sourceType, sourceId: sourceId)
            let now = ISO8601DateFormatter().string(from: Date())
            
            if var existing = notes[key] {
                existing.noteText = noteText
                existing.updatedAt = now
                notes[key] = existing
            } else {
                let note = WorkingNote(
                    id: UUID().uuidString,
                    districtId: districtId,
                    sourceId: sourceId,
                    sourceType: sourceType,
                    noteText: noteText,
                    createdAt: now,
                    updatedAt: now
                )
                notes[key] = note
            }
            
            print("[WorkingNotes] Saved note for \(sourceType) \(sourceId)")
            return true
            
        } catch {
            print("[WorkingNotes] Save failed: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Delete Note
    
    func delete(sourceType: String, sourceId: String) async -> Bool {
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else {
            print("[WorkingNotes] No district_id — cannot delete")
            return false
        }
        
        let urlString = "\(supabaseURL)/rest/v1/source_working_notes?district_id=eq.\(districtId)&source_type=eq.\(sourceType)&source_id=eq.\(sourceId)"
        guard let url = URL(string: urlString) else { return false }
        
        do {
            try await authenticatedDELETE(url: url)
            
            // Remove from local cache
            let key = makeKey(sourceType: sourceType, sourceId: sourceId)
            notes.removeValue(forKey: key)
            
            print("[WorkingNotes] Deleted note for \(sourceType) \(sourceId)")
            return true
            
        } catch {
            print("[WorkingNotes] Delete failed: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Date Formatting
    
    func formatTimestamp(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        
        // Try without fractional seconds
        let basic = ISO8601DateFormatter()
        if let date = basic.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        
        return isoString
    }
    
    // MARK: - HTTP Helpers
    
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
            throw WorkingNotesError.httpError
        }
        
        return data
    }
    
    private func authenticatedPOST(url: URL, body: Data, method: String = "POST", prefer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        
        if let prefer = prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                print("[WorkingNotes] HTTP \(httpResponse.statusCode): \(responseBody)")
            }
            throw WorkingNotesError.httpError
        }
        
        return data
    }
    
    private func authenticatedDELETE(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                print("[WorkingNotes] DELETE HTTP \(httpResponse.statusCode): \(responseBody)")
            }
            throw WorkingNotesError.httpError
        }
    }
}

// MARK: - Error

private enum WorkingNotesError: LocalizedError {
    case httpError
    
    var errorDescription: String? {
        switch self {
        case .httpError: return "HTTP request failed"
        }
    }
}
