//
//  PositionService.swift
//  MADxSync
//
//  Operator position service — tracks which position slot (POS01, POS02, etc.)
//  the tech is operating as today. Pulls from Supabase `positions` table.
//  Persists selection in UserDefaults.
//
//  Position is sticky for the entire day — it doesn't change when equipment changes.
//  A tech picks their position once at start of shift. Equipment can switch
//  throughout the day (truck → Argo → backpack) but the operator stays the same.
//
//  Depends on: AuthService (district_id, access token)
//

import Foundation
import Combine

/// Represents an operator position from the Supabase `positions` table
struct Position: Identifiable, Codable {
    let id: String
    let shortCode: String
    let displayLabel: String
    let active: Bool
    let sortOrder: Int
    
    enum CodingKeys: String, CodingKey {
        case id
        case shortCode = "short_code"
        case displayLabel = "display_label"
        case active
        case sortOrder = "sort_order"
    }
}

@MainActor
class PositionService: ObservableObject {
    static let shared = PositionService()
    
    @Published var positions: [Position] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    @Published var selectedPositionCode: String? {
        didSet { UserDefaults.standard.set(selectedPositionCode, forKey: "selectedPositionCode") }
    }
    
    @Published var selectedPositionLabel: String? {
        didSet { UserDefaults.standard.set(selectedPositionLabel, forKey: "selectedPositionLabel") }
    }
    
    /// True when a position is selected
    var hasPositionSelected: Bool { selectedPositionCode != nil }
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    private init() {
        selectedPositionCode = UserDefaults.standard.string(forKey: "selectedPositionCode")
        selectedPositionLabel = UserDefaults.standard.string(forKey: "selectedPositionLabel")
        print("[PositionService] Restored selection: \(selectedPositionLabel ?? "none") (\(selectedPositionCode ?? "-"))")
    }
    
    // MARK: - Fetch Positions (filtered by district)
    
    func fetchPositions() async {
        guard let districtId = AuthService.shared.districtId else {
            errorMessage = "Not authenticated — no district"
            print("[PositionService] ✗ No district_id available")
            return
        }
        
        let urlString = "\(supabaseURL)/rest/v1/positions?active=eq.true&district_id=eq.\(districtId)&select=id,short_code,display_label,active,sort_order&order=sort_order.asc,short_code.asc"
        
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? "unknown"
                errorMessage = "Server error \(statusCode)"
                print("[PositionService] ✗ Fetch failed: \(statusCode) — \(body)")
                isLoading = false
                return
            }
            
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                errorMessage = "Invalid response format"
                isLoading = false
                return
            }
            
            var fetched: [Position] = []
            for json in jsonArray {
                guard let id = json["id"] as? String,
                      let shortCode = json["short_code"] as? String,
                      let displayLabel = json["display_label"] as? String else {
                    continue
                }
                
                let active = json["active"] as? Bool ?? true
                let sortOrder = json["sort_order"] as? Int ?? 0
                
                fetched.append(Position(
                    id: id,
                    shortCode: shortCode,
                    displayLabel: displayLabel,
                    active: active,
                    sortOrder: sortOrder
                ))
            }
            
            positions = fetched
            print("[PositionService] ✓ Fetched \(fetched.count) positions for district \(districtId)")
            
            // Validate current selection still exists in active list
            if let currentCode = selectedPositionCode {
                if !fetched.contains(where: { $0.shortCode == currentCode }) {
                    print("[PositionService] ⚠️ Selected position \(currentCode) no longer active — clearing")
                    clearSelection()
                }
            }
            
        } catch {
            errorMessage = "Failed to fetch positions: \(error.localizedDescription)"
            print("[PositionService] ✗ Fetch error: \(error)")
        }
        
        isLoading = false
    }
    
    // MARK: - Select Position
    
    func selectPosition(_ pos: Position) {
        selectedPositionCode = pos.shortCode
        selectedPositionLabel = pos.displayLabel
        print("[PositionService] ✓ Selected: \(pos.displayLabel) (\(pos.shortCode))")
    }
    
    // MARK: - Clear Selection
    
    func clearSelection() {
        selectedPositionCode = nil
        selectedPositionLabel = nil
        UserDefaults.standard.removeObject(forKey: "selectedPositionCode")
        UserDefaults.standard.removeObject(forKey: "selectedPositionLabel")
        print("[PositionService] Selection cleared")
    }
}
