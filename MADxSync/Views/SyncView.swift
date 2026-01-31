import SwiftUI

// MARK: - Sync View (Big obvious feedback for techs)
struct SyncView: View {
    @ObservedObject var syncManager: SyncManager
    @ObservedObject private var markerStore = MarkerStore.shared
    
    @State private var showSuccessBanner = false
    @State private var lastSyncTime: Date?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Success Banner (slides down when sync completes)
                    if showSuccessBanner {
                        successBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    // Connection Cards
                    HStack(spacing: 12) {
                        connectionCard(
                            title: "FLO",
                            isConnected: syncManager.floConnected,
                            detail: syncManager.truckName ?? "Not found",
                            icon: "antenna.radiowaves.left.and.right"
                        )
                        
                        connectionCard(
                            title: "Internet",
                            isConnected: syncManager.hasInternet,
                            detail: syncManager.hasInternet ? "Online" : "Offline",
                            icon: "icloud"
                        )
                    }
                    .padding(.horizontal)
                    
                    // Sync Status Card
                    syncStatusCard
                        .padding(.horizontal)
                    
                    // Action Buttons
                    actionButtons
                        .padding(.horizontal)
                    
                    // Last Sync Info
                    if let lastSync = lastSyncTime {
                        lastSyncCard(time: lastSync)
                            .padding(.horizontal)
                    }
                    
                    // Expandable Log (collapsed by default)
                    logSection
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Sync")
            .background(Color(.systemGroupedBackground))
            .onChange(of: syncManager.syncComplete) { _, complete in
                if complete {
                    showSuccess()
                }
            }
            .refreshable {
                syncManager.checkFLOConnection()
                if syncManager.floConnected {
                    await syncManager.sync()
                }
            }
        }
    }
    
    // MARK: - Success Banner
    private var successBanner: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
            
            VStack(alignment: .leading) {
                Text("Sync Complete!")
                    .font(.headline)
                Text("All data uploaded to cloud")
                    .font(.caption)
            }
            
            Spacer()
        }
        .foregroundColor(.white)
        .padding()
        .background(Color.green)
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    // MARK: - Connection Card
    private func connectionCard(title: String, isConnected: Bool, detail: String, icon: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isConnected ? Color.green : Color.red.opacity(0.8))
                    .frame(width: 60, height: 60)
                
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.white)
            }
            
            Text(title)
                .font(.headline)
            
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
    
    // MARK: - Sync Status Card
    private var syncStatusCard: some View {
        VStack(spacing: 12) {
            // Syncing indicator
            if syncManager.isSyncing {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    
                    Text("Syncing...")
                        .font(.title3.bold())
                    
                    Spacer()
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
            } else if syncManager.pendingFiles > 0 {
                // CSV files waiting to upload
                HStack {
                    Image(systemName: "clock.fill")
                        .font(.title)
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading) {
                        Text("\(syncManager.pendingFiles) file(s) waiting")
                            .font(.title3.bold())
                        
                        if !syncManager.hasInternet {
                            Text("Will upload when internet available")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            Text("Tap Upload to send to cloud")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
            } else {
                // All synced!
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.green)
                    
                    VStack(alignment: .leading) {
                        Text("All Synced!")
                            .font(.title3.bold())
                        Text("No data waiting to upload")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(12)
            }
            
            // Show marker count separately (informational only for now)
            if markerStore.markers.count > 0 {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.blue)
                    
                    Text("\(markerStore.markers.count) marker(s) saved locally")
                        .font(.caption)
                    
                    Spacer()
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    // MARK: - Action Buttons
    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Download from FLO
            Button(action: {
                Task { await syncManager.sync() }
            }) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                    
                    VStack(alignment: .leading) {
                        Text("Download from FLO")
                            .font(.headline)
                        Text("Get today's spray logs")
                            .font(.caption)
                    }
                    
                    Spacer()
                    
                    if syncManager.isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(syncManager.floConnected ? Color.blue : Color.gray.opacity(0.3))
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(!syncManager.floConnected || syncManager.isSyncing)
            
            // Upload to Cloud
            Button(action: {
                Task { await syncManager.uploadPendingData() }
            }) {
                HStack {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.title2)
                    
                    VStack(alignment: .leading) {
                        Text("Upload to Cloud")
                            .font(.headline)
                        Text("Send data to Supabase")
                            .font(.caption)
                    }
                    
                    Spacer()
                    
                    if syncManager.isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(canUpload ? Color.green : Color.gray.opacity(0.3))
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(!canUpload)
        }
    }
    
    private var canUpload: Bool {
        syncManager.hasInternet && !syncManager.isSyncing && (syncManager.pendingFiles > 0 || markerStore.pendingSyncCount > 0)
    }
    
    // MARK: - Last Sync Card
    private func lastSyncCard(time: Date) -> some View {
        HStack {
            Image(systemName: "clock")
                .foregroundColor(.secondary)
            
            Text("Last sync: \(time, style: .relative) ago")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Log Section (Expandable)
    @State private var showLog = false
    
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation { showLog.toggle() }}) {
                HStack {
                    Text("Activity Log")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Image(systemName: showLog ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if showLog {
                ScrollView {
                    Text(syncManager.logText)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Show Success
    private func showSuccess() {
        lastSyncTime = Date()
        
        withAnimation(.easeOut(duration: 0.3)) {
            showSuccessBanner = true
        }
        
        // Haptic
        let notification = UINotificationFeedbackGenerator()
        notification.notificationOccurred(.success)
        
        // Hide after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                showSuccessBanner = false
            }
        }
    }
}

// MARK: - Preview
#Preview {
    let syncManager = SyncManager()
    return SyncView(syncManager: syncManager)
}
