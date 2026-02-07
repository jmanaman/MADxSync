//
//  NavigationBannerView.swift
//  MADxSync
//
//  Banner displayed during active navigation showing destination, ETA, and distance.
//  Tap X to cancel navigation.
//

import SwiftUI

struct NavigationBannerView: View {
    @ObservedObject var routeService: RouteService
    let onCancel: () -> Void
    
    var body: some View {
        if routeService.isNavigating {
            HStack(spacing: 12) {
                // Icon based on destination type
                destinationIcon
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 32)
                
                // Destination name
                VStack(alignment: .leading, spacing: 2) {
                    Text(routeService.destinationName)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    if routeService.hasArrived {
                        Text("Arrived!")
                            .font(.caption.bold())
                            .foregroundColor(.green)
                    } else if routeService.isCalculating {
                        Text("Calculating route...")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    } else if routeService.isOfflineMode {
                        HStack(spacing: 4) {
                            Text(routeService.bearingArrow)
                                .font(.caption.bold())
                            Text(routeService.bearingString)
                                .font(.caption)
                            Text("•")
                                .font(.caption)
                            Text(routeService.formattedDistance)
                                .font(.caption.bold())
                        }
                        .foregroundColor(.white.opacity(0.9))
                    }
                }
                
                Spacer()
                
                // ETA and distance (when online)
                if !routeService.isCalculating && !routeService.isOfflineMode && !routeService.hasArrived {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(routeService.formattedETA)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                        Text(routeService.formattedDistance)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                
                // Cancel button
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(routeService.hasArrived ? Color.green : Color.blue)
                    .shadow(radius: 4)
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    @ViewBuilder
    private var destinationIcon: some View {
        switch routeService.destinationType {
        case "pointsite":
            Image(systemName: "mappin.circle.fill")
        case "stormdrain":
            Image(systemName: "drop.circle.fill")
        case "field":
            Image(systemName: "square.fill")
        case "polyline":
            Image(systemName: "line.diagonal")
        default:
            Image(systemName: "location.circle.fill")
        }
    }
}

#Preview {
    VStack {
        // Mock preview - in real use, RouteService would have data
        NavigationBannerView(
            routeService: RouteService.shared,
            onCancel: {}
        )
        Spacer()
    }
    .background(Color.gray.opacity(0.2))
}
