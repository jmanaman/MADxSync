//
//  AddSourceViews.swift
//  MADxSync
//
//  UI components for the Add Source tool.
//  - AddSourceToolState (tracks tool mode)
//  - AddSourceFormSheet (fill out details before arming)
//  - AddSourceContextStrip (shows when armed, vertex count, done/cancel)
//  - FlowLayout (chip layout for subtype presets)
//

import Foundation
import Combine
import SwiftUI
import CoreLocation

// MARK: - Add Source Tool State

class AddSourceToolState: ObservableObject {
    @Published var isActive: Bool = false
    @Published var selectedType: AddSourceType = .pointsite
    @Published var isArmed: Bool = false
    @Published var showForm: Bool = false
    
    /// The source being actively built (multi-point vertex dropping)
    @Published var activeSourceId: String?
    
    // Form fields
    @Published var formName: String = ""
    @Published var formSubtype: String = ""
    @Published var formCondition: SourceCondition = .unknown
    @Published var formDescription: String = ""
    
    func reset() {
            isActive = false
            isArmed = false
            showForm = false
            activeSourceId = nil
            vertexCount = 0
            clearForm()
        }
    
    func clearForm() {
        formName = ""
        formSubtype = ""
        formCondition = .unknown
        formDescription = ""
    }
    
    /// Whether we're in vertex-dropping mode
    var isDroppingVertices: Bool {
        isArmed && selectedType.isMultiPoint && activeSourceId != nil
    }
    
    /// Vertex count — explicitly updated on every vertex add/undo.
        /// @Published so SwiftUI re-renders the context strip reliably.
        @Published var vertexCount: Int = 0
        
        /// Call after every vertex add/undo to keep count in sync
        func refreshVertexCount() {
            guard let sourceId = activeSourceId else {
                vertexCount = 0
                return
            }
            vertexCount = AddSourceService.shared.source(byId: sourceId)?.vertexCount ?? 0
        }
    
    /// Whether the form has minimum required data to arm
    var canArm: Bool {
        !formSubtype.isEmpty
    }
}

// MARK: - Add Source Form Sheet

struct AddSourceFormSheet: View {
    @ObservedObject var toolState: AddSourceToolState
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Source Type") {
                    Picker("Type", selection: $toolState.selectedType) {
                        ForEach(AddSourceType.allCases) { type in
                            Label(type.displayName, systemImage: type.iconName)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                
                Section("Name") {
                    TextField("Source name (optional)", text: $toolState.formName)
                        .autocorrectionDisabled()
                }
                
                Section("What Is It?") {
                    let presets = SourceSubtypePresets.presets(for: toolState.selectedType)
                    
                    FlowLayout(spacing: 8) {
                        ForEach(presets, id: \.self) { preset in
                            Button(action: { toolState.formSubtype = preset }) {
                                Text(preset)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(toolState.formSubtype == preset ? Color.blue : Color(.tertiarySystemBackground))
                                    .foregroundColor(toolState.formSubtype == preset ? .white : .primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    if toolState.formSubtype == "Other" {
                        TextField("Custom type", text: $toolState.formSubtype)
                    }
                }
                
                Section("Condition") {
                    Picker("Condition", selection: $toolState.formCondition) {
                        ForEach(SourceCondition.allCases) { condition in
                            Text(condition.displayName).tag(condition)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Details") {
                    TextEditor(text: $toolState.formDescription)
                        .frame(minHeight: 60)
                        .overlay(
                            Group {
                                if toolState.formDescription.isEmpty {
                                    Text("Additional details or notes...")
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 4)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                }
                            }, alignment: .topLeading
                        )
                }
                
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.tap.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            if toolState.selectedType.isMultiPoint {
                                Text("Tap map to drop vertex points")
                                    .font(.subheadline.bold())
                                Text("Each tap adds a numbered vertex. Tap Done when finished. Admin connects the dots in the HUB.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Tap map to place the source")
                                    .font(.subheadline.bold())
                                Text("One tap places the \(toolState.selectedType.displayName.lowercased()).")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("How It Works")
                }
            }
            .navigationTitle("Add \(toolState.selectedType.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        toolState.reset()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Arm") {
                        toolState.isArmed = true
                        toolState.showForm = false
                        dismiss()
                    }
                    .font(.headline)
                    .disabled(!toolState.canArm)
                }
            }
        }
    }
}

// MARK: - Add Source Context Strip

struct AddSourceContextStrip: View {
    @ObservedObject var toolState: AddSourceToolState
    let onDone: () -> Void
    let onUndoVertex: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: toolState.selectedType.iconName)
                    .foregroundColor(Color(hex: toolState.selectedType.iconColor))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adding \(toolState.selectedType.displayName)")
                        .font(.subheadline.bold())
                    if !toolState.formName.isEmpty {
                        Text(toolState.formName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if toolState.selectedType.isMultiPoint {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse").font(.caption)
                        Text("\(toolState.vertexCount) pts")
                            .font(.caption.bold().monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
                }
            }
            
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                }
                
                Spacer()
                
                if toolState.selectedType.isMultiPoint && toolState.vertexCount > 1 {
                    Button(action: onUndoVertex) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Undo")
                        }
                        .font(.subheadline)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(8)
                    }
                }
                
                if toolState.selectedType.isMultiPoint {
                    let minVerts = toolState.selectedType.minimumVertices
                    Button(action: onDone) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Done")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(toolState.vertexCount >= minVerts ? Color.green : Color.gray)
                        .cornerRadius(8)
                    }
                    .disabled(toolState.vertexCount < minVerts)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, containerWidth: proposal.width ?? 300).size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let offsets = layout(sizes: sizes, containerWidth: bounds.width).offsets
        for (i, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + offsets[i].x, y: bounds.minY + offsets[i].y),
                          proposal: ProposedViewSize(sizes[i]))
        }
    }
    
    private func layout(sizes: [CGSize], containerWidth: CGFloat) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for size in sizes {
            if x + size.width > containerWidth && x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x)
        }
        return (offsets, CGSize(width: maxWidth, height: y + lineHeight))
    }
}
