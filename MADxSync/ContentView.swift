//
//  ContentView.swift
//  MADxSync
//
//  Created by Justin Manning on 1/29/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var syncManager = SyncManager()
    
    var body: some View {
        VStack(spacing: 24) {
            // Header with sync status
            HStack {
                Text("MADx Sync")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Spacer()
                
                // Sync status indicator
                if syncManager.syncComplete && syncManager.pendingFiles == 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                } else if syncManager.pendingFiles > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.orange)
                        Text("\(syncManager.pendingFiles)")
                            .fontWeight(.semibold)
                    }
                    .font(.title2)
                }
            }
            
            // Connection status
            VStack(spacing: 12) {
                // FLO Connection
                HStack {
                    Circle()
                        .fill(syncManager.floConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(syncManager.floConnected ? "Connected to FLO" : "Not connected to FLO")
                        .font(.headline)
                    Spacer()
                }
                
                // Truck info
                if let truck = syncManager.truckName {
                    HStack {
                        Image(systemName: "truck.box.fill")
                        Text(truck)
                            .font(.subheadline)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
                
                // Internet status
                HStack {
                    Circle()
                        .fill(syncManager.hasInternet ? Color.green : Color.orange)
                        .frame(width: 12, height: 12)
                    Text(syncManager.hasInternet ? "Internet available" : "No internet (will sync later)")
                        .font(.subheadline)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                
                // Pending uploads
                if syncManager.pendingFiles > 0 {
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundStyle(.orange)
                        Text("\(syncManager.pendingFiles) file(s) waiting to upload")
                            .font(.subheadline)
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            // Sync button
            Button(action: {
                Task {
                    await syncManager.sync()
                }
            }) {
                HStack {
                    if syncManager.isSyncing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(syncManager.isSyncing ? "Syncing..." : "Sync from FLO")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(syncManager.floConnected ? Color.blue : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(!syncManager.floConnected || syncManager.isSyncing)
            
            // Manual upload button (if pending and has internet)
            if syncManager.pendingFiles > 0 && syncManager.hasInternet {
                Button(action: {
                    Task {
                        await syncManager.uploadPendingData()
                    }
                }) {
                    HStack {
                        Image(systemName: "icloud.and.arrow.up")
                        Text("Upload Now")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(syncManager.isSyncing)
            }
            
            // Log area
            ScrollViewReader { proxy in
                ScrollView {
                    Text(syncManager.logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logBottom")
                }
                .onChange(of: syncManager.logText) { _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
            .frame(maxHeight: 200)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            Spacer()
        }
        .padding()
        .onAppear {
            syncManager.checkFLOConnection()
        }
    }
}

#Preview {
    ContentView()
}
