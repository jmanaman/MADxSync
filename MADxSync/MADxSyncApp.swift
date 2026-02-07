//
//  MADxSyncApp.swift
//  MADxSync
//
//  Main app entry point.
//  Flow: Login → Pick Truck → App
//
//  1. Not authenticated → LoginView
//  2. Authenticated but no truck selected → TruckPickerView
//  3. Authenticated + truck selected → MainTabView
//

import SwiftUI

@main
struct MADxSyncApp: App {
    @StateObject private var authService = AuthService.shared
    @StateObject private var truckService = TruckService.shared
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(truckService)
        }
    }
}

// MARK: - Root View (handles auth + truck gate)

struct RootView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var truckService: TruckService
    
    var body: some View {
        Group {
            if !authService.isAuthenticated {
                // Step 1: Login
                LoginView()
            } else if !truckService.hasTruckSelected {
                // Step 2: Pick a truck
                TruckPickerView()
            } else {
                // Step 3: Go
                MainTabView()
            }
        }
        .animation(.easeInOut, value: authService.isAuthenticated)
        .animation(.easeInOut, value: truckService.hasTruckSelected)
    }
}
