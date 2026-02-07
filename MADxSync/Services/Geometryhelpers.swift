//
//  GeometryHelpers.swift
//  MADxSync
//
//  Helper extensions for calculating centroids and midpoints of spatial features.
//  Used for navigation to determine destination coordinate.
//

import CoreLocation

// MARK: - FieldPolygon Centroid

extension FieldPolygon {
    /// Calculate the centroid (center point) of the polygon
    var centroid: CLLocationCoordinate2D? {
        let coords: [CLLocationCoordinate2D]
        
        switch geometry {
        case .polygon(let poly):
            coords = poly.outerRing
        case .multiPolygon(let multi):
            coords = multi.polygons.first ?? []
        case .multiLineString(let multi):
            coords = multi.lines.first ?? []
        case .lineString(let line):
            coords = line.coordinates2D
        default:
            return nil
        }
        
        guard coords.count >= 3 else { return nil }
        
        // Simple centroid: average of all coordinates
        // For complex polygons, a proper centroid calculation would be better,
        // but for navigation purposes this is sufficient
        let sumLat = coords.reduce(0.0) { $0 + $1.latitude }
        let sumLon = coords.reduce(0.0) { $0 + $1.longitude }
        
        return CLLocationCoordinate2D(
            latitude: sumLat / Double(coords.count),
            longitude: sumLon / Double(coords.count)
        )
    }
}

// MARK: - SpatialPolyline Midpoint

extension SpatialPolyline {
    /// Calculate the midpoint of the polyline
    var midpoint: CLLocationCoordinate2D? {
        let coords: [CLLocationCoordinate2D]
        
        switch geometry {
        case .lineString(let line):
            coords = line.coordinates2D
        case .multiLineString(let multi):
            coords = multi.lines.first ?? []
        default:
            return nil
        }
        
        guard coords.count >= 2 else { return nil }
        
        // For a simple approach, use the middle coordinate
        // For a more accurate midpoint, we'd walk the line and find the point at 50% distance
        let midIndex = coords.count / 2
        return coords[midIndex]
    }
}
