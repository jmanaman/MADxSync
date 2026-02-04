//
//  TruckService.swift
//  MADxSync
//
//  Truck identity service — single source of truth for which truck this device is operating as.
//  Pulls truck list from Supabase `trucks` table, persists tech's selection in UserDefaults.
//  Every marker, every sync, every data point gets stamped with the selected truck_id.
//

import Foundation
import Combine

/// Represents a truck from the Supabase `trucks` table
struct Truck: Identifiable, Codable {
    let id: String           // UUID from Supabase
    let name: String         // Display name: "Truck 7", "Quink 3", etc.
    let truckNumber: String  // Short identifier: "7", "Alpha", etc.
    let floSsid: String?     // FLO WiFi SSID if this truck has FLO hardware, nil otherwise
    let assignedTech: String? // Optional tech assignment
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
    
    // MARK: - Published State
    
    /// All active trucks fetched from Supabase
    @Published var trucks: [Truck] = []
    
    /// Whether we're currently fetching the truck list
    @Published var isLoading = false
    
    /// Error message if truck fetch failed
    @Published var errorMessage: String?
    
    // MARK: - Selected Truck (persisted in UserDefaults)
    
    /// The UUID of the currently selected truck, or nil if none selected yet
    @Published var selectedTruckId: String? {
        didSet {
            UserDefaults.standard.set(selectedTruckId, forKey: "selectedTruckId")
        }
    }
    
    /// The display name of the currently selected truck, or nil if none selected
    @Published var selectedTruckName: String? {
        didSet {
            UserDefaults.standard.set(selectedTruckName, forKey: "selectedTruckName")
        }
    }
    
    /// The truck_number of the currently selected truck, or nil if none selected
    @Published var selectedTruckNumber: String? {
        didSet {
            UserDefaults.standard.set(selectedTruckNumber, forKey: "selectedTruckNumber")
        }
    }
    
    /// Whether a truck has been selected (used to gate app entry)
    var hasTruckSelected: Bool {
        selectedTruckId != nil
    }
    
    // MARK: - Supabase Config
    
    private let supabaseURL = "https://amclxjjsialotyuombxg.supabase.co"
    private let supabaseKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
    
    // MARK: - Init
    
    private init() {
        // Restore persisted selection
        selectedTruckId = UserDefaults.standard.string(forKey: "selectedTruckId")
        selectedTruckName = UserDefaults.standard.string(forKey: "selectedTruckName")
        selectedTruckNumber = UserDefaults.standard.string(forKey: "selectedTruckNumber")
        
        print("[TruckService] Restored selection: \(selectedTruckName ?? "none") (id: \(selectedTruckId ?? "nil"))")
    }
    
    // MARK: - Fetch Trucks from Supabase
    
    /// Pulls all active trucks from the `trucks` table.
    /// Call this when showing the truck picker to get the latest fleet.
    func fetchTrucks() async {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/trucks?active=eq.true&select=id,name,truck_number,flo_ssid,assigned_tech,active&order=truck_number.asc") else {
            errorMessage = "Invalid Supabase URL"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                errorMessage = "No response from server"
                isLoading = false
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "unknown"
                errorMessage = "Server error \(httpResponse.statusCode): \(body)"
                print("[TruckService] ✗ Fetch failed: \(httpResponse.statusCode) — \(body)")
                isLoading = false
                return
            }
            
            let decoder = JSONDecoder()
            let fetchedTrucks = try decoder.decode([Truck].self, from: data)
            trucks = fetchedTrucks
            
            print("[TruckService] ✓ Fetched \(fetchedTrucks.count) active truck(s)")
            
            // Validate that the current selection still exists and is active
            if let currentId = selectedTruckId {
                if !fetchedTrucks.contains(where: { $0.id == currentId }) {
                    print("[TruckService] ⚠️ Previously selected truck no longer active — clearing selection")
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
    
    /// Tech picks a truck. Persists immediately to UserDefaults.
    func selectTruck(_ truck: Truck) {
        selectedTruckId = truck.id
        selectedTruckName = truck.name
        selectedTruckNumber = truck.truckNumber
        print("[TruckService] ✓ Selected: \(truck.name) (id: \(truck.id))")
    }
    
    // MARK: - Clear Selection
    
    /// Clears the current truck selection. Used if selected truck is deactivated.
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
