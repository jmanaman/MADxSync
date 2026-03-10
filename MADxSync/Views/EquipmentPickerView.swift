//
//  EquipmentPickerView.swift
//  MADxSync
//
//  Equipment picker screen. Replaces TruckPickerView.
//  Shows on first launch (no equipment selected) and accessible from Settings.
//  After equipment selection, auto-presents position picker if no position set yet.
//
//  Depends on: EquipmentService, PositionService
//

import SwiftUI

struct EquipmentPickerView: View {
    @ObservedObject private var equipmentService = EquipmentService.shared
    @ObservedObject private var positionService = PositionService.shared
    
    /// Called after equipment (and position if needed) is selected.
    var onComplete: (() -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    var isSheet: Bool = false
    
    /// Auto-present position picker after equipment selection
    @State private var showPositionPicker = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Current selection banner (only when switching, not first launch)
                if let currentName = equipmentService.selectedEquipmentName, isSheet {
                    HStack {
                        Image(systemName: EquipmentService.iconName(for: equipmentService.selectedEquipmentType ?? "other"))
                            .foregroundColor(.blue)
                        Text("Currently: \(currentName)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        if let posLabel = positionService.selectedPositionLabel {
                            Text(posLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                }
                
                // Equipment list
                if equipmentService.isLoading && equipmentService.equipment.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading equipment...")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if let error = equipmentService.errorMessage, equipmentService.equipment.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text("Couldn't load equipment")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Try Again") {
                            Task { await equipmentService.fetchEquipment() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(equipmentService.equipment) { eq in
                                EquipmentRow(
                                    equipment: eq,
                                    isSelected: eq.shortCode == equipmentService.selectedEquipmentCode
                                ) {
                                    selectEquipment(eq)
                                }
                            }
                        } header: {
                            Text("\(equipmentService.equipment.count) active equipment")
                        } footer: {
                            Text("Select the equipment you're operating. You can switch anytime from Settings.")
                                .font(.caption)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await equipmentService.fetchEquipment()
                    }
                }
            }
            .navigationTitle(isSheet ? "Switch Equipment" : "Select Equipment")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showPositionPicker) {
                PositionPickerView(isSheet: true) {
                    // Position selected — complete the flow
                    if isSheet {
                        dismiss()
                    } else {
                        onComplete?()
                    }
                }
            }
        }
        .task {
            await equipmentService.fetchEquipment()
            await positionService.fetchPositions()
        }
    }
    
    private func selectEquipment(_ eq: Equipment) {
        equipmentService.selectEquipment(eq)
        
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        // If no position selected yet, auto-present position picker
        if !positionService.hasPositionSelected {
            showPositionPicker = true
        } else if isSheet {
            dismiss()
        } else {
            onComplete?()
        }
    }
}

// MARK: - Equipment Row
struct EquipmentRow: View {
    let equipment: Equipment
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Type icon
                Image(systemName: EquipmentService.iconName(for: equipment.equipmentType))
                    .font(.title3)
                    .foregroundColor(equipment.floSsid != nil ? .green : .blue)
                    .frame(width: 32)
                
                // Equipment info
                VStack(alignment: .leading, spacing: 2) {
                    Text(equipment.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 8) {
                        Text(equipment.shortCode)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        
                        if let ssid = equipment.floSsid {
                            Text("MADx: \(ssid)")
                                .font(.caption)
                                .foregroundColor(.green)
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

// MARK: - Position Picker View
struct PositionPickerView: View {
    @ObservedObject private var positionService = PositionService.shared
    @Environment(\.dismiss) private var dismiss
    var isSheet: Bool = false
    var onComplete: (() -> Void)?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let currentLabel = positionService.selectedPositionLabel, isSheet {
                    HStack {
                        Image(systemName: "person.fill")
                            .foregroundColor(.blue)
                        Text("Currently: \(currentLabel)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                }
                
                if positionService.isLoading && positionService.positions.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading positions...")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if let error = positionService.errorMessage, positionService.positions.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text("Couldn't load positions")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Try Again") {
                            Task { await positionService.fetchPositions() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(positionService.positions) { pos in
                                PositionRow(
                                    position: pos,
                                    isSelected: pos.shortCode == positionService.selectedPositionCode
                                ) {
                                    selectPosition(pos)
                                }
                            }
                        } header: {
                            Text("\(positionService.positions.count) active positions")
                        } footer: {
                            Text("Select your operator position for today. This stays set when you switch equipment.")
                                .font(.caption)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await positionService.fetchPositions()
                    }
                }
            }
            .navigationTitle(isSheet ? "Select Position" : "Who Are You?")
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
            if positionService.positions.isEmpty {
                await positionService.fetchPositions()
            }
        }
    }
    
    private func selectPosition(_ pos: Position) {
        positionService.selectPosition(pos)
        
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        if isSheet {
            dismiss()
        }
        onComplete?()
    }
}

// MARK: - Position Row
struct PositionRow: View {
    let position: Position
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "person.fill")
                    .font(.title3)
                    .foregroundColor(.orange)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(position.displayLabel)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text(position.shortCode)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
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
