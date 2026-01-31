import SwiftUI

/// Spray session tracking
struct SpraySession: Identifiable {
    let id = UUID()
    let startTime: Date
    var endTime: Date?
    var startGallons: Double
    var startChemical: Double
    var endGallons: Double?
    var endChemical: Double?
    
    var gallonsUsed: Double {
        guard let end = endGallons else { return 0 }
        return end - startGallons
    }
    
    var chemicalUsed: Double {
        guard let end = endChemical else { return 0 }
        return end - startChemical
    }
    
    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }
    
    var durationString: String {
        let seconds = Int(duration)
        let mins = seconds / 60
        let secs = seconds % 60
        return "\(mins)m \(secs)s"
    }
}

/// Collapsible spray control panel with session tracking
struct FLOControlView: View {
    @ObservedObject var floService = FLOService.shared
    @State private var isExpanded = false
    
    // Spray session tracking
    @State private var activeSession: SpraySession?
    @State private var completedSessions: [SpraySession] = []
    @State private var sessionGallons: Double = 0
    @State private var sessionChemical: Double = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Header - always visible
            headerView
            
            // Expanded controls
            if isExpanded {
                expandedView
            }
        }
        .background(Color(.systemBackground).opacity(0.95))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .onAppear {
            floService.startPolling()
        }
        .onChange(of: floService.relay1On) { _, isOn in
            handleBTIStateChange(isOn: isOn)
        }
    }
    
    // MARK: - BTI State Change (auto session tracking)
    private func handleBTIStateChange(isOn: Bool) {
        if isOn && activeSession == nil {
            // BTI turned ON - start session
            activeSession = SpraySession(
                startTime: Date(),
                startGallons: floService.gallons,
                startChemical: floService.chemicalOz
            )
            sessionGallons = 0
            sessionChemical = 0
        } else if !isOn && activeSession != nil {
            // BTI turned OFF - end session
            var session = activeSession!
            session.endTime = Date()
            session.endGallons = floService.gallons
            session.endChemical = floService.chemicalOz
            
            completedSessions.insert(session, at: 0)
            if completedSessions.count > 10 {
                completedSessions.removeLast()
            }
            
            activeSession = nil
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }}) {
            HStack(spacing: 10) {
                // Connection dot
                Circle()
                    .fill(floService.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                // Status
                if floService.isConnected {
                    // BTI indicator
                    if floService.relay1On {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("SPRAYING")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                        }
                    }
                    
                    // Session totals (current spray)
                    if activeSession != nil {
                        Text(String(format: "%.2f gal • %.2f oz",
                            floService.gallons - (activeSession?.startGallons ?? 0),
                            floService.chemicalOz - (activeSession?.startChemical ?? 0)))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.primary)
                    } else {
                        // Cumulative totals
                        Text(String(format: "%.2f gal • %.2f oz", floService.gallons, floService.chemicalOz))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("FLO Offline")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Expanded View
    private var expandedView: some View {
        VStack(spacing: 12) {
            Divider()
            
            // Relay buttons row
            HStack(spacing: 8) {
                RelayButton(
                    name: floService.relay1Name,
                    isOn: floService.relay1On,
                    color: .green
                ) {
                    Task { await floService.toggleBTI() }
                }
                
                RelayButton(
                    name: floService.relay2Name,
                    isOn: floService.relay2On,
                    color: .orange
                ) {
                    Task { await floService.toggleOil() }
                }
                
                RelayButton(
                    name: floService.relay3Name,
                    isOn: floService.relay3On,
                    color: .blue
                ) {
                    Task { await floService.togglePump() }
                }
                
                // Sweep toggle
                Button(action: { Task { await floService.toggleSweep() }}) {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.title3)
                        Text("Sweep")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(floService.sweepEnabled ? Color.purple.opacity(0.2) : Color(.tertiarySystemBackground))
                    .cornerRadius(8)
                }
                .foregroundColor(floService.sweepEnabled ? .purple : .secondary)
            }
            
            // Totals display
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.3f gal", floService.gallons))
                        .font(.subheadline.monospacedDigit().bold())
                }
                
                Spacer()
                
                VStack(alignment: .center, spacing: 2) {
                    Text("Chemical")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.3f oz", floService.chemicalOz))
                        .font(.subheadline.monospacedDigit().bold())
                }
                
                Spacer()
                
                // Reset button
                Button(action: resetTotals) {
                    Text("Reset")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .cornerRadius(6)
                }
            }
            
            // Last sprays log (if any)
            if !completedSessions.isEmpty {
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Sprays")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    
                    ForEach(completedSessions.prefix(5)) { session in
                        HStack {
                            Text(session.durationString)
                                .font(.caption.monospacedDigit())
                            Spacer()
                            Text(String(format: "%.2f gal", session.gallonsUsed))
                                .font(.caption.monospacedDigit())
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(String(format: "%.2f oz", session.chemicalUsed))
                                .font(.caption.monospacedDigit())
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
            
            // Open FLO UI button
            Button(action: openFLOUI) {
                HStack {
                    Image(systemName: "safari")
                    Text("Full FLO UI")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
            .foregroundColor(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
    
    // MARK: - Actions
    private func resetTotals() {
        Task {
            _ = await floService.sendCommand("RESET_TOTALS")
            // Haptic
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        }
    }
    
    private func openFLOUI() {
        if let url = URL(string: "http://192.168.4.1") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Relay Button
struct RelayButton: View {
    let name: String
    let isOn: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Circle()
                    .fill(isOn ? color : Color.gray.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "power")
                            .font(.caption)
                            .foregroundColor(isOn ? .white : .gray)
                    )
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isOn ? color.opacity(0.15) : Color(.tertiarySystemBackground))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview
#Preview {
    VStack {
        FLOControlView()
            .padding()
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
