//
//  SourceNotesService.swift
//  MADxSync
//
//  Pulls permanent source notes from Supabase so techs can see
//  notes dropped by other techs (gate codes, contact info, etc.)
//  Read-only on the app side — notes are created via the flag tool
//  and managed/deleted by the OD on the Hub.
//  Multi-tenant: all queries scoped by district_id.
//

import Foundation
import Combine

/// A permanent note attached to a source
struct SourceNote: Codable, Identifiable {
    let id: String
    let districtId: String
    let sourceId: String?
    let sourceType: String?
    var note: String?
    let createdBy: String?
    let truckId: String?
    let createdAt: String?
    let updatedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case districtId = "district_id"
        case sourceId = "source_id"
        case sourceType = "source_type"
        case note
        case createdBy = "created_by"
        case truckId = "truck_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

@MainActor
final class SourceNotesService: ObservableObject {
    
    static let shared = SourceNotesService()
    
    // MARK: - Published State
    
    /// All source notes for this district, keyed by "sourceType_sourceId"
    /// A source can have multiple notes (from different techs/flags)
    @Published var notesBySource: [String: [SourceNote]] = [:]
    
    // MARK: - Configuration
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    private let requestTimeout: TimeInterval = 15.0
    
    private init() {}
    
    // MARK: - Cache Key
    
    func makeKey(sourceType: String, sourceId: String) -> String {
        return "\(sourceType)_\(sourceId)"
    }
    
    // MARK: - Get Notes for a Source
    
    func getNotesForSource(sourceType: String, sourceId: String) -> [SourceNote] {
        let key = makeKey(sourceType: sourceType, sourceId: sourceId)
        return notesBySource[key] ?? []
    }
    
    // MARK: - Pull All (called by HubSyncService)
    
    func pullFromHub() async {
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else { return }
        
        // Only pull notes that have been attached to a source (have source_type and source_id)
        let urlString = "\(supabaseURL)/rest/v1/source_notes?district_id=eq.\(districtId)&source_id=not.is.null&source_type=not.is.null&select=*"
        guard let url = URL(string: urlString) else { return }
        
        do {
            let data = try await authenticatedGET(url: url)
            let decoded = try JSONDecoder().decode([SourceNote].self, from: data)
            
            var newNotes: [String: [SourceNote]] = [:]
            for note in decoded {
                guard let sourceType = note.sourceType, let sourceId = note.sourceId else { continue }
                guard let noteText = note.note, !noteText.isEmpty else { continue }
                
                let key = makeKey(sourceType: sourceType, sourceId: sourceId)
                if newNotes[key] == nil {
                    newNotes[key] = []
                }
                newNotes[key]?.append(note)
            }
            
            notesBySource = newNotes
            
        } catch {
            print("[SourceNotes] Pull failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Date Formatting
    
    func formatTimestamp(_ isoString: String?) -> String {
        guard let isoString = isoString else { return "" }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        
        let basic = ISO8601DateFormatter()
        if let date = basic.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        
        return isoString
    }
    
    // MARK: - HTTP Helper
    
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
            throw SourceNotesError.httpError
        }
        
        return data
    }
}

// MARK: - Error

private enum SourceNotesError: LocalizedError {
    case httpError
    
    var errorDescription: String? {
        switch self {
        case .httpError: return "HTTP request failed"
        }
    }
}
