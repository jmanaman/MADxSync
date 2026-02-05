//
//  SnapService.swift
//  MADxSync
//
//  Snap tap coordinates to nearby point sites and storm drains for precise marker placement.
//  Returns the snapped coordinate and source name if within threshold, otherwise returns nil.
//

import Foundation
import CoreLocation

/// Result of a snap check
struct SnapResult {
    let coordinate: CLLocationCoordinate2D
    let sourceName: String
    let sourceType: String  // "pointsite" or "stormdrain"
    let sourceId: String
}

/// Service for snapping tap locations to nearby point features
class SnapService {
    
    // Snap radius in meters (~50 feet)
    static let snapRadiusMeters: Double = 25.0
    
    /// Check if a tap coordinate is close enough to a point site or storm drain to snap
    /// Returns SnapResult if within threshold, nil otherwise
    static func checkSnap(
        coordinate: CLLocationCoordinate2D,
        pointSites: [PointSite],
        stormDrains: [StormDrain]
    ) -> SnapResult? {
        
        var closestResult: SnapResult? = nil
        var closestDistance: Double = snapRadiusMeters
        
        // Check point sites
        for site in pointSites {
            guard let siteCoord = site.coordinate else { continue }
            
            let distance = distanceMeters(from: coordinate, to: siteCoord)
            
            if distance < closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: siteCoord,
                    sourceName: site.displayName,
                    sourceType: "pointsite",
                    sourceId: site.id
                )
            }
        }
        
        // Check storm drains
        for drain in stormDrains {
            guard let drainCoord = drain.coordinate else { continue }
            
            let distance = distanceMeters(from: coordinate, to: drainCoord)
            
            if distance < closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: drainCoord,
                    sourceName: drain.name ?? "Storm Drain",
                    sourceType: "stormdrain",
                    sourceId: drain.id
                )
            }
        }
        
        return closestResult
    }
    
    /// Calculate distance in meters between two coordinates
    private static func distanceMeters(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double {
        let fromLocation = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let toLocation = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return fromLocation.distance(from: toLocation)
    }
}
