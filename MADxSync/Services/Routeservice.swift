//
//  RouteService.swift
//  MADxSync
//
//  Navigation routing service using Apple MKDirections.
//  Tap a source, get turn-by-turn directions to it.
//  Falls back to bearing/distance mode when offline.
//

import Foundation
import MapKit
import CoreLocation
import Combine

// MARK: - Route Service

@MainActor
class RouteService: ObservableObject {
    
    static let shared = RouteService()
    
    // MARK: - Published State
    
    /// Currently active route (nil if no navigation)
    @Published var currentRoute: MKRoute?
    
    /// Route polyline for map display
    @Published var routePolyline: MKPolyline?
    
    /// Destination info
    @Published var destinationName: String = ""
    @Published var destinationCoordinate: CLLocationCoordinate2D?
    @Published var destinationType: String = ""  // "pointsite", "stormdrain", "field", "polyline"
    @Published var destinationId: String = ""
    
    /// Live navigation stats
    @Published var distanceMeters: Double = 0
    @Published var etaSeconds: TimeInterval = 0
    
    /// State flags
    @Published var isNavigating: Bool = false
    @Published var isCalculating: Bool = false
    @Published var hasArrived: Bool = false
    @Published var isOfflineMode: Bool = false
    
    /// Error message if routing failed
    @Published var errorMessage: String?
    
    // MARK: - Configuration
    
    /// Distance threshold for "arrived" detection (meters)
    private let arrivalThresholdMeters: Double = 50.0
    
    /// Reference to NavigationService for location updates
    private var navigationService: NavigationService?
    private var locationCancellable: AnyCancellable?
    
    // MARK: - Init
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Set the navigation service reference for location updates
    func setNavigationService(_ service: NavigationService) {
        self.navigationService = service
        
        // Subscribe to location updates for live distance/arrival detection
        locationCancellable = service.$location
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.handleLocationUpdate(location)
            }
    }
    
    /// Start navigation to a destination
    /// - Parameters:
    ///   - coordinate: Destination coordinate
    ///   - name: Display name for the destination
    ///   - type: Source type ("pointsite", "stormdrain", "field", "polyline")
    ///   - id: Source ID
    func navigateTo(
        coordinate: CLLocationCoordinate2D,
        name: String,
        type: String,
        id: String
    ) async {
        // Set destination info
        destinationCoordinate = coordinate
        destinationName = name
        destinationType = type
        destinationId = id
        isCalculating = true
        isNavigating = true
        hasArrived = false
        isOfflineMode = false
        errorMessage = nil
        
        // Get current location
        guard let currentLocation = navigationService?.location else {
            // No GPS fix - go to offline mode
            activateOfflineMode()
            return
        }
        
        // Calculate initial distance
        distanceMeters = currentLocation.distance(from: CLLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))
        
        // Request directions from Apple
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocation.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        
        let directions = MKDirections(request: request)
        
        do {
            let response = try await directions.calculate()
            
            if let route = response.routes.first {
                currentRoute = route
                routePolyline = route.polyline
                etaSeconds = route.expectedTravelTime
                distanceMeters = route.distance
                isCalculating = false
                
                print("[RouteService] Route calculated: \(route.distance)m, \(route.expectedTravelTime)s")
            } else {
                // No routes found - fall back to offline mode
                activateOfflineMode()
            }
        } catch {
            print("[RouteService] Routing error: \(error.localizedDescription)")
            // Network error or no route available - fall back to offline mode
            activateOfflineMode()
        }
    }
    
    /// Cancel current navigation
    func cancelNavigation() {
        currentRoute = nil
        routePolyline = nil
        destinationName = ""
        destinationCoordinate = nil
        destinationType = ""
        destinationId = ""
        distanceMeters = 0
        etaSeconds = 0
        isNavigating = false
        isCalculating = false
        hasArrived = false
        isOfflineMode = false
        errorMessage = nil
        
        print("[RouteService] Navigation cancelled")
    }
    
    /// Formatted distance string
    var formattedDistance: String {
        if distanceMeters < 160 {  // Less than ~0.1 miles, show feet
            let feet = distanceMeters * 3.28084
            return String(format: "%.0f ft", feet)
        } else {
            let miles = distanceMeters / 1609.34
            if miles < 10 {
                return String(format: "%.1f mi", miles)
            } else {
                return String(format: "%.0f mi", miles)
            }
        }
    }
    
    /// Formatted ETA string
    var formattedETA: String {
        if isOfflineMode {
            return bearingString
        }
        
        let minutes = Int(etaSeconds / 60)
        if minutes < 1 {
            return "<1 min"
        } else if minutes < 60 {
            return "\(minutes) min"
        } else {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if remainingMinutes == 0 {
                return "\(hours) hr"
            } else {
                return "\(hours) hr \(remainingMinutes) min"
            }
        }
    }
    
    /// Bearing to destination (for offline mode)
    var bearingString: String {
        guard let destination = destinationCoordinate,
              let current = navigationService?.location?.coordinate else {
            return ""
        }
        
        let bearing = calculateBearing(from: current, to: destination)
        let cardinal = bearingToCardinal(bearing)
        return cardinal
    }
    
    /// Bearing arrow character
    var bearingArrow: String {
        guard let destination = destinationCoordinate,
              let current = navigationService?.location?.coordinate else {
            return "→"
        }
        
        let bearing = calculateBearing(from: current, to: destination)
        return bearingToArrow(bearing)
    }
    
    // MARK: - Private Methods
    
    /// Handle location updates for live distance/arrival
    private func handleLocationUpdate(_ location: CLLocation) {
        guard isNavigating, let destination = destinationCoordinate else { return }
        
        let destinationLocation = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        let distance = location.distance(from: destinationLocation)
        
        // Update distance
        distanceMeters = distance
        
        // In offline mode, we don't have ETA - just distance
        // In online mode, we could recalculate but that's expensive
        // For now, estimate based on 25 mph average
        if isOfflineMode {
            etaSeconds = distance / 11.176  // 25 mph in m/s
        }
        
        // Check for arrival
        if distance <= arrivalThresholdMeters && !hasArrived {
            hasArrived = true
            print("[RouteService] Arrived at destination!")
            
            // Auto-clear after delay
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
                if hasArrived {
                    cancelNavigation()
                }
            }
        }
    }
    
    /// Activate offline/bearing mode when routing unavailable
    private func activateOfflineMode() {
        isOfflineMode = true
        isCalculating = false
        routePolyline = nil
        currentRoute = nil
        errorMessage = "No route available - showing direction"
        
        // Calculate straight-line distance
        if let destination = destinationCoordinate,
           let current = navigationService?.location {
            distanceMeters = current.distance(from: CLLocation(
                latitude: destination.latitude,
                longitude: destination.longitude
            ))
            // Estimate ETA at 25 mph
            etaSeconds = distanceMeters / 11.176
        }
        
        print("[RouteService] Offline mode activated")
    }
    
    /// Calculate bearing between two coordinates
    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 {
            bearing += 360
        }
        
        return bearing
    }
    
    /// Convert bearing to cardinal direction
    private func bearingToCardinal(_ bearing: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((bearing + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return directions[index]
    }
    
    /// Convert bearing to arrow character
    private func bearingToArrow(_ bearing: Double) -> String {
        let arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
        let index = Int(((bearing + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return arrows[index]
    }
}
