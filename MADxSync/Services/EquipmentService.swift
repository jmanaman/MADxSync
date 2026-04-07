//
//  EquipmentService.swift
//  MADxSync
//
//  Equipment identity service — single source of truth for which equipment this device is operating as.
//  Replaces TruckService for all new data. Pulls from Supabase `equipment` table.
//  Persists tech's selection in UserDefaults.
//
//  Assembles the compound identifier (e.g. T14-POS01) by combining
//  selectedEquipmentCode with PositionService.shared.selectedPositionCode.
//  This compound identifier stamps every marker, every sync, every data point.
//
//  Depends on: AuthService (district_id, access token), PositionService (operator code)
//

import Foundation
import Combine

/// Represents a piece of equipment from the Supabase `equipment` table
struct Equipment: Identifiable, Codable {
    let id: String
    let shortCode: String
    let displayName: String
    let equipmentType: String
    let floSsid: String?
    let active: Bool
    let sortOrder: Int
    
    enum CodingKeys: String, CodingKey {
        case id
        case shortCode = "short_code"
        case displayName = "display_name"
        case equipmentType = "equipment_type"
        case floSsid = "flo_ssid"
        case active
        case sortOrder = "sort_order"
    }
}

@MainActor
class EquipmentService: ObservableObject {
    static let shared = EquipmentService()
    
    @Published var equipment: [Equipment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    @Published var selectedEquipmentCode: String? {
        didSet { UserDefaults.standard.set(selectedEquipmentCode, forKey: "selectedEquipmentCode") }
    }
    
    @Published var selectedEquipmentName: String? {
        didSet { UserDefaults.standard.set(selectedEquipmentName, forKey: "selectedEquipmentName") }
    }
    
    @Published var selectedEquipmentType: String? {
        didSet { UserDefaults.standard.set(selectedEquipmentType, forKey: "selectedEquipmentType") }
    }
    
    /// True when a piece of equipment is selected
    var hasEquipmentSelected: Bool { selectedEquipmentCode != nil }
    
    /// The compound identifier: "T14-POS01" or just "T14" if no position set.
    /// This is what gets stamped on every treatment record.
    var operatorIdentifier: String? {
        guard let eq = selectedEquipmentCode else { return nil }
        if let pos = PositionService.shared.selectedPositionCode {
            return "\(eq)-\(pos)"
        }
        return eq
    }
    
    /// True when both equipment AND position are selected — full accountability
    var isFullyConfigured: Bool {
        hasEquipmentSelected && PositionService.shared.hasPositionSelected
    }
    
    private let supabaseURL = SupabaseConfig.url
    private let supabaseKey = SupabaseConfig.publishableKey
    
    private init() {
        selectedEquipmentCode = UserDefaults.standard.string(forKey: "selectedEquipmentCode")
        selectedEquipmentName = UserDefaults.standard.string(forKey: "selectedEquipmentName")
        selectedEquipmentType = UserDefaults.standard.string(forKey: "selectedEquipmentType")
        print("[EquipmentService] Restored selection: \(selectedEquipmentName ?? "none") (\(selectedEquipmentCode ?? "-"))")
    }
    
    // MARK: - Fetch Equipment (filtered by district)
    
    func fetchEquipment() async {
        guard let districtId = AuthService.shared.districtId else {
            errorMessage = "Not authenticated — no district"
            print("[EquipmentService] ✗ No district_id available")
            return
        }
        
        let urlString = "\(supabaseURL)/rest/v1/equipment?active=eq.true&district_id=eq.\(districtId)&select=id,short_code,display_name,equipment_type,flo_ssid,active,sort_order&order=sort_order.asc,display_name.asc"
        
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
                print("[EquipmentService] ✗ Fetch failed: \(statusCode) — \(body)")
                isLoading = false
                return
            }
            
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                errorMessage = "Invalid response format"
                isLoading = false
                return
            }
            
            var fetched: [Equipment] = []
            for json in jsonArray {
                guard let id = json["id"] as? String,
                      let shortCode = json["short_code"] as? String,
                      let displayName = json["display_name"] as? String,
                      let equipmentType = json["equipment_type"] as? String else {
                    continue
                }
                
                let floSsid = json["flo_ssid"] as? String
                let active = json["active"] as? Bool ?? true
                let sortOrder = json["sort_order"] as? Int ?? 0
                
                fetched.append(Equipment(
                    id: id,
                    shortCode: shortCode,
                    displayName: displayName,
                    equipmentType: equipmentType,
                    floSsid: floSsid,
                    active: active,
                    sortOrder: sortOrder
                ))
            }
            
            equipment = fetched
            print("[EquipmentService] ✓ Fetched \(fetched.count) equipment for district \(districtId)")
            
            // Validate current selection still exists in active list
            if let currentCode = selectedEquipmentCode {
                if !fetched.contains(where: { $0.shortCode == currentCode }) {
                    print("[EquipmentService] ⚠️ Selected equipment \(currentCode) no longer active — clearing")
                    clearSelection()
                }
            }
            
        } catch {
            errorMessage = "Failed to fetch equipment: \(error.localizedDescription)"
            print("[EquipmentService] ✗ Fetch error: \(error)")
        }
        
        isLoading = false
    }
    
    // MARK: - Select Equipment
    
    func selectEquipment(_ eq: Equipment) {
        selectedEquipmentCode = eq.shortCode
        selectedEquipmentName = eq.displayName
        selectedEquipmentType = eq.equipmentType
        print("[EquipmentService] ✓ Selected: \(eq.displayName) (\(eq.shortCode))")
    }
    
    // MARK: - Clear Selection
    
    func clearSelection() {
        selectedEquipmentCode = nil
        selectedEquipmentName = nil
        selectedEquipmentType = nil
        UserDefaults.standard.removeObject(forKey: "selectedEquipmentCode")
        UserDefaults.standard.removeObject(forKey: "selectedEquipmentName")
        UserDefaults.standard.removeObject(forKey: "selectedEquipmentType")
        print("[EquipmentService] Selection cleared")
    }
    
    // MARK: - SF Symbol for equipment type (used by picker and badge)
    
    static func iconName(for type: String) -> String {
        switch type {
        case "truck":            return "truck.box.fill"
        case "atv", "sidebyside": return "car.fill"
        case "aircraft", "drone": return "airplane"
        case "watercraft":       return "ferry.fill"
        case "autonomous":       return "cpu.fill"
        case "trailer":          return "shippingbox.fill"
        default:                 return "wrench.fill"
        }
    }
}
