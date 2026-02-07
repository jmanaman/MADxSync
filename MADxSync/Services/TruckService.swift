//
//  TruckService.swift
//  MADxSync
//
//  Truck identity service — single source of truth for which truck this device is operating as.
//  Pulls truck list from Supabase `trucks` table, filtered by authenticated district.
//  Persists tech's selection in UserDefaults.
//  Every marker, every sync, every data point gets stamped with the selected truck_id.
//

import Foundation
import Combine

/// Represents a truck from the Supabase `trucks` table
struct Truck: Identifiable, Codable {
    let id: String
    let name: String
    let truckNumber: String
    let floSsid: String?
    let assignedTech: String?
    let active: Bool
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case truckNumber = "truck_number"
        case floSsid = "flo_ssid"
        case assignedTech = "assigned_tech"
        case active
    }
}

@MainActor
class TruckService: ObservableObject {
    static let shared = TruckService()
    
    @Published var trucks: [Truck] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    @Published var selectedTruckId: String? {
        didSet { UserDefaults.standard.set(selectedTruckId, forKey: "selectedTruckId") }
    }
    
    @Published var selectedTruckName: String? {
        didSet { UserDefaults.standard.set(selectedTruckName, forKey: "selectedTruckName") }
    }
    
    @Published var selectedTruckNumber: String? {
        didSet { UserDefaults.standard.set(selectedTruckNumber, forKey: "selectedTruckNumber") }
    }
    
    var hasTruckSelected: Bool { selectedTruckId != nil }
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    private init() {
        selectedTruckId = UserDefaults.standard.string(forKey: "selectedTruckId")
        selectedTruckName = UserDefaults.standard.string(forKey: "selectedTruckName")
        selectedTruckNumber = UserDefaults.standard.string(forKey: "selectedTruckNumber")
        print("[TruckService] Restored selection: \(selectedTruckName ?? "none")")
    }
    
    // MARK: - Fetch Trucks (filtered by district)
    
    func fetchTrucks() async {
        // Get district_id from authenticated user — this is the multi-tenant filter
        guard let districtId = AuthService.shared.districtId else {
            errorMessage = "Not authenticated — no district"
            print("[TruckService] ✗ No district_id available")
            return
        }
        
        guard let url = URL(string: "\(supabaseURL)/rest/v1/trucks?active=eq.true&district_id=eq.\(districtId)&select=id,name,truck_number,flo_ssid,assigned_tech,active&order=truck_number.asc") else {
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
                print("[TruckService] ✗ Fetch failed: \(statusCode) — \(body)")
                isLoading = false
                return
            }
            
            // Manual JSON parsing — handles type mismatches gracefully
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                errorMessage = "Invalid response format"
                isLoading = false
                return
            }
            
            var fetchedTrucks: [Truck] = []
            for truckJson in jsonArray {
                guard let id = truckJson["id"] as? String,
                      let name = truckJson["name"] as? String else {
                    continue
                }
                
                // Handle truck_number as String or Int
                let truckNumber: String
                if let tn = truckJson["truck_number"] as? String {
                    truckNumber = tn
                } else if let tn = truckJson["truck_number"] as? Int {
                    truckNumber = String(tn)
                } else {
                    truckNumber = "0"
                }
                
                let floSsid = truckJson["flo_ssid"] as? String
                let assignedTech = truckJson["assigned_tech"] as? String
                let active = truckJson["active"] as? Bool ?? true
                
                fetchedTrucks.append(Truck(
                    id: id,
                    name: name,
                    truckNumber: truckNumber,
                    floSsid: floSsid,
                    assignedTech: assignedTech,
                    active: active
                ))
            }
            
            trucks = fetchedTrucks
            print("[TruckService] ✓ Fetched \(fetchedTrucks.count) truck(s) for district \(districtId)")
            
            // Validate current selection still exists
            if let currentId = selectedTruckId {
                if !fetchedTrucks.contains(where: { $0.id == currentId }) {
                    print("[TruckService] ⚠️ Selected truck no longer active — clearing")
                    clearSelection()
                }
            }
            
        } catch {
            errorMessage = "Failed to fetch trucks: \(error.localizedDescription)"
            print("[TruckService] ✗ Fetch error: \(error)")
        }
        
        isLoading = false
    }
    
    // MARK: - Select Truck
    
    func selectTruck(_ truck: Truck) {
        selectedTruckId = truck.id
        selectedTruckName = truck.name
        selectedTruckNumber = truck.truckNumber
        print("[TruckService] ✓ Selected: \(truck.name) (#\(truck.truckNumber))")
    }
    
    // MARK: - Clear Selection
    
    func clearSelection() {
        selectedTruckId = nil
        selectedTruckName = nil
        selectedTruckNumber = nil
        UserDefaults.standard.removeObject(forKey: "selectedTruckId")
        UserDefaults.standard.removeObject(forKey: "selectedTruckName")
        UserDefaults.standard.removeObject(forKey: "selectedTruckNumber")
        print("[TruckService] Selection cleared")
    }
}
