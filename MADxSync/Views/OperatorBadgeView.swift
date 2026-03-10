//
//  OperatorBadgeView.swift
//  MADxSync
//
//  Persistent always-visible badge overlaid on the FieldMapView.
//  Shows current equipment and position at a glance.
//  Tapping opens a bottom sheet for one-tap switching.
//
//  This is the primary UX defense against the "forgetting problem" —
//  techs will forget to switch equipment. The badge makes the current
//  state always visible so they notice when it's wrong.
//
//  Depends on: EquipmentService, PositionService
//

import SwiftUI

struct OperatorBadgeView: View {
    @ObservedObject private var equipmentService = EquipmentService.shared
    @ObservedObject private var positionService = PositionService.shared
    
    @State private var showSwitchSheet = false
    
    private var isConfigured: Bool {
        equipmentService.hasEquipmentSelected && positionService.hasPositionSelected
    }
    
    var body: some View {
        Button(action: { showSwitchSheet = true }) {
            HStack(spacing: 8) {
                if isConfigured {
                    // Normal state — show equipment icon + codes
                    Image(systemName: EquipmentService.iconName(for: equipmentService.selectedEquipmentType ?? "other"))
                        .font(.caption.bold())
                    
                    Text("\(equipmentService.selectedEquipmentCode ?? "") · \(positionService.selectedPositionCode ?? "")")
                        .font(.caption.bold().monospaced())
                    
                    if let label = positionService.selectedPositionLabel {
                        Text("(\(label))")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                } else {
                    // Warning state — not fully configured
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                    Text("Tap to set operator")
                        .font(.caption.bold())
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isConfigured ? Color.black.opacity(0.75) : Color.red.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isConfigured ? Color.white.opacity(0.2) : Color.red, lineWidth: 1)
            )
        }
        .sheet(isPresented: $showSwitchSheet) {
            OperatorSwitchSheet()
        }
    }
}

// MARK: - Switch Sheet (bottom sheet for quick switching)

struct OperatorSwitchSheet: View {
    @ObservedObject private var equipmentService = EquipmentService.shared
    @ObservedObject private var positionService = PositionService.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var showEquipmentPicker = false
    @State private var showPositionPicker = false
    
    var body: some View {
        NavigationView {
            List {
                // Current Equipment
                Section(header: Text("Equipment")) {
                    HStack {
                        Image(systemName: EquipmentService.iconName(for: equipmentService.selectedEquipmentType ?? "other"))
                            .foregroundColor(.blue)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(equipmentService.selectedEquipmentName ?? "Not Selected")
                                .fontWeight(.medium)
                            if let code = equipmentService.selectedEquipmentCode {
                                Text(code)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    
                    Button(action: { showEquipmentPicker = true }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Switch Equipment")
                        }
                    }
                }
                
                // Current Position
                Section(header: Text("Operator Position")) {
                    HStack {
                        Image(systemName: "person.fill")
                            .foregroundColor(.orange)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(positionService.selectedPositionLabel ?? "Not Selected")
                                .fontWeight(.medium)
                            if let code = positionService.selectedPositionCode {
                                Text(code)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    
                    Button(action: { showPositionPicker = true }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Switch Position")
                        }
                    }
                }
                
                // Compound identifier preview
                if let identifier = equipmentService.operatorIdentifier {
                    Section(header: Text("Log Identifier")) {
                        HStack {
                            Image(systemName: "tag.fill")
                                .foregroundColor(.green)
                                .frame(width: 28)
                            Text(identifier)
                                .font(.body.monospaced())
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Operator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showEquipmentPicker) {
                EquipmentPickerView(isSheet: true)
            }
            .sheet(isPresented: $showPositionPicker) {
                PositionPickerView(isSheet: true)
            }
        }
    }
}
