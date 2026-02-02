//
//  SpatialModels.swift
//  MADxSync
//
//  Spatial data models for district boundaries, fields, polylines, point sites, storm drains
//

import Foundation
import MapKit
import CoreLocation
import Combine

// MARK: - GeoJSON Geometry Types

struct GeoJSONPoint: Codable {
    let type: String
    let coordinates: [Double]
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinates[1], longitude: coordinates[0])
    }
}

struct GeoJSONLineString: Codable {
    let type: String
    let coordinates: [[Double]]
    
    var coordinates2D: [CLLocationCoordinate2D] {
        coordinates.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }
}

struct GeoJSONPolygon: Codable {
    let type: String
    let coordinates: [[[Double]]]
    
    // Returns outer ring only (first array)
    var outerRing: [CLLocationCoordinate2D] {
        guard let ring = coordinates.first else { return [] }
        return ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }
}

struct GeoJSONMultiLineString: Codable {
    let type: String
    let coordinates: [[[Double]]]
    
    var lines: [[CLLocationCoordinate2D]] {
        coordinates.map { line in
            line.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
        }
    }
}

struct GeoJSONMultiPolygon: Codable {
    let type: String
    let coordinates: [[[[Double]]]]
    
    var polygons: [[CLLocationCoordinate2D]] {
        coordinates.compactMap { polygon in
            polygon.first?.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
        }
    }
}

// MARK: - Flexible Geometry Decoder

enum GeoJSONGeometry: Codable {
    case point(GeoJSONPoint)
    case lineString(GeoJSONLineString)
    case polygon(GeoJSONPolygon)
    case multiLineString(GeoJSONMultiLineString)
    case multiPolygon(GeoJSONMultiPolygon)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Try each type
        if let point = try? container.decode(GeoJSONPoint.self), point.type == "Point" {
            self = .point(point)
        } else if let line = try? container.decode(GeoJSONLineString.self), line.type == "LineString" {
            self = .lineString(line)
        } else if let polygon = try? container.decode(GeoJSONPolygon.self), polygon.type == "Polygon" {
            self = .polygon(polygon)
        } else if let multi = try? container.decode(GeoJSONMultiLineString.self), multi.type == "MultiLineString" {
            self = .multiLineString(multi)
        } else if let multi = try? container.decode(GeoJSONMultiPolygon.self), multi.type == "MultiPolygon" {
            self = .multiPolygon(multi)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown geometry type")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .point(let p): try container.encode(p)
        case .lineString(let l): try container.encode(l)
        case .polygon(let p): try container.encode(p)
        case .multiLineString(let m): try container.encode(m)
        case .multiPolygon(let m): try container.encode(m)
        }
    }
}

// MARK: - District Boundary

struct DistrictBoundary: Codable, Identifiable {
    let id: String
    let district_id: String
    let boundary_id: String?
    let geometry: GeoJSONGeometry
    
    var mkOverlays: [MKOverlay] {
        switch geometry {
        case .multiLineString(let multi):
            return multi.lines.map { coords in
                MKPolyline(coordinates: coords, count: coords.count)
            }
        case .polygon(let poly):
            let coords = poly.outerRing
            return [MKPolygon(coordinates: coords, count: coords.count)]
        case .lineString(let line):
            let coords = line.coordinates2D
            return [MKPolyline(coordinates: coords, count: coords.count)]
        default:
            return []
        }
    }
}

// MARK: - Field Polygon

struct FieldPolygon: Codable, Identifiable {
    let id: String
    let district_id: String
    let global_id: String?
    let name: String?
    let zone: String?
    let zone2: String?
    let habitat: String?
    let priority: String?
    let use_type: String?
    let active: Bool?
    let symbology: String?
    let acres: Double?
    let geometry: GeoJSONGeometry
    
    var mkPolygon: MKPolygon? {
        switch geometry {
        case .polygon(let poly):
            let coords = poly.outerRing
            return MKPolygon(coordinates: coords, count: coords.count)
        case .multiPolygon(let multi):
            if let coords = multi.polygons.first {
                return MKPolygon(coordinates: coords, count: coords.count)
            }
            return nil
        case .multiLineString(let multi):
            // QGIS exported polygons as MultiLineString - treat first line as polygon outline
            if let coords = multi.lines.first, coords.count >= 3 {
                return MKPolygon(coordinates: coords, count: coords.count)
            }
            return nil
        case .lineString(let line):
            // Single line - treat as polygon if closed
            let coords = line.coordinates2D
            if coords.count >= 3 {
                return MKPolygon(coordinates: coords, count: coords.count)
            }
            return nil
        default:
            return nil
        }
    }
    
    var displayName: String {
        name ?? zone2 ?? "Unknown Field"
    }
}

// MARK: - Polyline (Ditches, Canals)

struct SpatialPolyline: Codable, Identifiable {
    let id: String
    let district_id: String
    let global_id: String?
    let name: String?
    let zone: String?
    let zone2: String?
    let habitat: String?
    let active: Bool?
    let length_ft: Double?
    let width_ft: Double?
    let geometry: GeoJSONGeometry
    
    var mkPolyline: MKPolyline? {
        switch geometry {
        case .lineString(let line):
            let coords = line.coordinates2D
            return MKPolyline(coordinates: coords, count: coords.count)
        case .multiLineString(let multi):
            // Return first line segment
            if let coords = multi.lines.first {
                return MKPolyline(coordinates: coords, count: coords.count)
            }
            return nil
        default:
            return nil
        }
    }
    
    // Return all polylines for MultiLineString (multiple segments)
    var mkPolylines: [MKPolyline] {
        switch geometry {
        case .lineString(let line):
            let coords = line.coordinates2D
            return [MKPolyline(coordinates: coords, count: coords.count)]
        case .multiLineString(let multi):
            return multi.lines.map { coords in
                MKPolyline(coordinates: coords, count: coords.count)
            }
        default:
            return []
        }
    }
}

// MARK: - Point Site (Pools, Standpipes, etc.)

struct PointSite: Codable, Identifiable {
    let id: String
    let district_id: String
    let global_id: String?
    let name: String?
    let zone: String?
    let zone2: String?
    let habitat: String?
    let priority: String?
    let active: Bool?
    let symbology: String?
    let longitude: Double?
    let latitude: Double?
    let geometry: GeoJSONGeometry
    
    var coordinate: CLLocationCoordinate2D? {
        if let lat = latitude, let lon = longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        switch geometry {
        case .point(let p):
            return p.coordinate
        default:
            return nil
        }
    }
    
    var displayName: String {
        name ?? habitat ?? "Unknown Site"
    }
    
    // Color based on symbology/status
    var markerColor: String {
        switch symbology?.uppercased() {
        case "ACTION": return "#ff6b6b"      // Red - needs action
        case "INACTIVE": return "#868e96"    // Gray - inactive
        case "NONE": return "#51cf66"        // Green - good
        default: return "#4dabf7"            // Blue - default
        }
    }
}

// MARK: - Storm Drain

struct StormDrain: Codable, Identifiable {
    let id: String
    let district_id: String
    let global_id: String?
    let name: String?
    let zone: String?
    let zone2: String?
    let symbology: String?
    let longitude: Double?
    let latitude: Double?
    let geometry: GeoJSONGeometry
    
    var coordinate: CLLocationCoordinate2D? {
        if let lat = latitude, let lon = longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        switch geometry {
        case .point(let p):
            return p.coordinate
        default:
            return nil
        }
    }
    
    var markerColor: String {
        switch symbology?.uppercased() {
        case "ACTION": return "#ff6b6b"
        case "INACTIVE": return "#868e96"
        default: return "#74c0fc"  // Light blue for drains
        }
    }
}

// MARK: - Layer Visibility State

class LayerVisibility: ObservableObject {
    @Published var showBoundaries: Bool = true
    @Published var showFields: Bool = true
    @Published var showPolylines: Bool = false
    @Published var showPointSites: Bool = false
    @Published var showStormDrains: Bool = false
    
    // Convenience for checking if any layers need loading
    var anyVisible: Bool {
        showBoundaries || showFields || showPolylines || showPointSites || showStormDrains
    }
}
