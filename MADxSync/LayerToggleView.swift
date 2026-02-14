//
//  LayerToggleView.swift
//  MADxSync
//
//  Toggle panel for showing/hiding spatial layers
//

import SwiftUI

struct LayerToggleView: View {
    @ObservedObject var visibility: LayerVisibility
    @ObservedObject var spatialService: SpatialService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("Map Layers") {
                    LayerToggleRow(
                        icon: "square.dashed",
                        title: "District Boundary",
                        subtitle: "\(spatialService.boundaries.count) segments",
                        color: .purple,
                        isOn: $visibility.showBoundaries
                    )
                    
                    LayerToggleRow(
                        icon: "square.fill",
                        title: "Fields",
                        subtitle: "\(spatialService.fields.count) polygons",
                        color: .green,
                        isOn: $visibility.showFields
                    )
                    
                    LayerToggleRow(
                        icon: "line.diagonal",
                        title: "Ditches & Canals",
                        subtitle: "\(spatialService.polylines.count) lines",
                        color: .cyan,
                        isOn: $visibility.showPolylines
                    )
                    
                    LayerToggleRow(
                        icon: "mappin.circle.fill",
                        title: "Point Sites",
                        subtitle: "\(spatialService.pointSites.count) sites",
                        color: .orange,
                        isOn: $visibility.showPointSites
                    )
                    
                    LayerToggleRow(
                        icon: "drop.circle.fill",
                        title: "Storm Drains",
                        subtitle: "\(spatialService.stormDrains.count) drains",
                        color: .blue,
                        isOn: $visibility.showStormDrains
                    )
                                        
                     LayerToggleRow(
                         icon: "plus.circle.fill",
                         title: "Pending Sources",
                         subtitle: "\(AddSourceService.shared.sources.count) temporary",
                         color: .teal,
                         isOn: $visibility.showPendingSources
                    )
                }
                
                Section("Data Status") {
                    HStack {
                        Text("Total Features")
                        Spacer()
                        Text("\(spatialService.totalFeatures)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Last Sync")
                        Spacer()
                        if let age = spatialService.cacheAge {
                            Text(age)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Never")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if spatialService.isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading...")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let error = spatialService.lastError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }
                
                Section {
                    Button(action: {
                        Task {
                            await spatialService.loadAllLayers()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh All Layers")
                        }
                    }
                    .disabled(spatialService.isLoading)
                    
                    Button(role: .destructive, action: {
                        spatialService.clearCache()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Cache")
                        }
                    }
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Layer Toggle Row

struct LayerToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    @Binding var isOn: Bool
    
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                    .frame(width: 28)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Compact Layer Button (for map overlay)

struct LayerButton: View {
    @Binding var showLayerSheet: Bool
    let featureCount: Int
    
    var body: some View {
        Button(action: { showLayerSheet = true }) {
            HStack(spacing: 4) {
                Image(systemName: "square.3.layers.3d")
                    .font(.subheadline)
                if featureCount > 0 {
                    Text("\(featureCount)")
                        .font(.caption.bold())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
        }
    }
}

#Preview {
    LayerToggleView(
        visibility: LayerVisibility(),
        spatialService: SpatialService.shared
    )
}
