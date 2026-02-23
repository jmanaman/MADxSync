//
//  SnapService.swift
//  MADxSync
//
//  Snap tap coordinates to nearby point sites and storm drains for precise marker placement.
//  Returns the snapped coordinate and source name if within threshold, otherwise returns nil.
//
//  UPDATED: Added pendingSources parameter for Add Sources feature.
//  Default value [] means all existing call sites work without changes.
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
        stormDrains: [StormDrain],
        pendingSources: [PendingSource] = [],
        sourceFinderPins: [SourceFinderPin] = [],
        serviceRequestPins: [ServiceRequestPin] = []
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
        
        // Check pending point sources (snap to temporary sources too)
        for source in pendingSources {
            // Only snap to point types, not multi-point vertex sources
            guard !source.sourceType.isMultiPoint else { continue }
            guard let sourceCoord = source.coordinate else { continue }
            
            let distance = distanceMeters(from: coordinate, to: sourceCoord)
            
            if distance < closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: sourceCoord,
                    sourceName: source.displayName,
                    sourceType: source.sourceType.rawValue,
                    sourceId: source.id
                )
            }
        }
        
        // Check Source Finder pins LAST — uses <= so SF pins win ties with
                // pending sources at the same coordinate (pending source created from
                // "Recommend Permanent" sits at identical coords as the SF pin)
                for pin in sourceFinderPins {
                    let pinCoord = pin.coordinate
                    let distance = distanceMeters(from: coordinate, to: pinCoord)
                    
                    if distance <= closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: pinCoord,
                    sourceName: pin.displayTitle,
                    sourceType: "sourcefinder",
                    sourceId: pin.id
                )
            }
        }
        
        // Check Service Request pins — same logic as SF pins
        for req in serviceRequestPins {
            let reqCoord = req.coordinate
            let distance = distanceMeters(from: coordinate, to: reqCoord)
            
            if distance <= closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: reqCoord,
                    sourceName: req.displayTitle,
                    sourceType: "servicerequest",
                    sourceId: req.id
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
