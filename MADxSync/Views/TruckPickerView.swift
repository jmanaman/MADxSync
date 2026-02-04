//
//  TruckPickerView.swift
//  MADxSync
//
//  Truck picker screen. Shows on first launch (no truck selected yet) and
//  accessible anytime from Settings to switch trucks.
//
//  Pulls active trucks from Supabase via TruckService. Tech taps a truck, done.
//  No login, no password, just pick your truck and go.
//

import SwiftUI

struct TruckPickerView: View {
    @ObservedObject private var truckService = TruckService.shared
    
    /// Called after a truck is selected. Used by the first-launch gate to dismiss this view.
    var onTruckSelected: (() -> Void)?
    
    /// Whether this is being shown as a sheet (from Settings) vs. the first-launch gate
    @Environment(\.dismiss) private var dismiss
    var isSheet: Bool = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Current selection banner (only when switching, not on first launch)
                if let currentName = truckService.selectedTruckName, isSheet {
                    HStack {
                        Image(systemName: "truck.box.fill")
                            .foregroundColor(.blue)
                        Text("Currently: \(currentName)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                }
                
                // Truck list
                if truckService.isLoading && truckService.trucks.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading trucks...")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if let error = truckService.errorMessage, truckService.trucks.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text("Couldn't load trucks")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Try Again") {
                            Task { await truckService.fetchTrucks() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(truckService.trucks) { truck in
                                TruckRow(
                                    truck: truck,
                                    isSelected: truck.id == truckService.selectedTruckId
                                ) {
                                    selectTruck(truck)
                                }
                            }
                        } header: {
                            Text("\(truckService.trucks.count) active truck\(truckService.trucks.count == 1 ? "" : "s")")
                        } footer: {
                            Text("Select the truck you're operating today. You can change this anytime from Settings.")
                                .font(.caption)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await truckService.fetchTrucks()
                    }
                }
            }
            .navigationTitle(isSheet ? "Switch Truck" : "Select Your Truck")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .task {
            await truckService.fetchTrucks()
        }
    }
    
    private func selectTruck(_ truck: Truck) {
        truckService.selectTruck(truck)
        
        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        if isSheet {
            dismiss()
        } else {
            // First-launch gate — tell the parent we're done
            onTruckSelected?()
        }
    }
}

// MARK: - Truck Row
struct TruckRow: View {
    let truck: Truck
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Truck icon
                Image(systemName: truck.floSsid != nil ? "antenna.radiowaves.left.and.right" : "truck.box.fill")
                    .font(.title3)
                    .foregroundColor(truck.floSsid != nil ? .green : .blue)
                    .frame(width: 32)
                
                // Truck info
                VStack(alignment: .leading, spacing: 2) {
                    Text(truck.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 8) {
                        Text("#\(truck.truckNumber)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if let ssid = truck.floSsid {
                            Text("FLO: \(ssid)")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("No FLO")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let tech = truck.assignedTech, !tech.isEmpty {
                            Text("• \(tech)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview
#Preview("First Launch") {
    TruckPickerView()
}

#Preview("Sheet - Switching") {
    TruckPickerView(isSheet: true)
}
