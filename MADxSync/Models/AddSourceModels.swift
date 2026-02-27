//
//  AddSourceModels.swift
//  MADxSync
//
//  Data models for the Add Sources feature.
//  Pending sources live in the pending_sources table until admin promotes them.
//
//  DESIGN PRINCIPLES:
//  - All fields are var (mutable) — no JSON round-trip hacks to set server values
//  - CodableJSON handles arbitrarily nested structures (GeoJSON safe)
//  - Every computed property is nil-safe — no force unwraps anywhere
//  - Payload generation never throws — worst case returns safe defaults
//

import Foundation
import CoreLocation
import MapKit
import UIKit

// MARK: - Source Type

enum AddSourceType: String, CaseIterable, Identifiable, Codable {
    case pointsite = "pointsite"
    case stormdrain = "stormdrain"
    case polyline = "polyline"
    case polygon = "polygon"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .pointsite: return "Point Site"
        case .stormdrain: return "Storm Drain"
        case .polyline: return "Polyline"
        case .polygon: return "Polygon"
        }
    }
    
    var iconName: String {
        switch self {
        case .pointsite: return "mappin.circle.fill"
        case .stormdrain: return "drop.circle.fill"
        case .polyline: return "line.diagonal"
        case .polygon: return "square.fill"
        }
    }
    
    var iconColor: String {
        switch self {
        case .pointsite: return "#ff9500"
        case .stormdrain: return "#007aff"
        case .polyline: return "#00c7be"
        case .polygon: return "#34c759"
        }
    }
    
    /// Whether this type drops multiple vertices vs single point
    var isMultiPoint: Bool {
        self == .polyline || self == .polygon
    }
    
    /// Minimum vertices required to finish a multi-point source
    var minimumVertices: Int {
        switch self {
        case .polyline: return 2
        case .polygon: return 3
        case .pointsite, .stormdrain: return 1
        }
    }
}

// MARK: - Source Condition

enum SourceCondition: String, CaseIterable, Identifiable, Codable {
    case good = "good"
    case damaged = "damaged"
    case blocked = "blocked"
    case dry = "dry"
    case flooded = "flooded"
    case unknown = "unknown"
    
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// MARK: - Pending Source

/// A source created by a tech, pending admin review.
/// ALL fields are var — server values set directly, no constructor hacks.
struct PendingSource: Codable, Identifiable {
    var id: String
    var districtId: String
    var sourceType: AddSourceType
    
    var name: String
    var sourceSubtype: String
    var condition: SourceCondition
    var description: String
    
    var zone: String?
    var zone2: String?
    
    var geometry: PendingSourceGeometry
    
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    
    /// Local-only sync state. Not stored in Supabase.
    var syncedToSupabase: Bool
    
    /// Create a new local source
    init(
        districtId: String,
        sourceType: AddSourceType,
        name: String,
        sourceSubtype: String,
        condition: SourceCondition,
        description: String,
        zone: String? = nil,
        zone2: String? = nil,
        geometry: PendingSourceGeometry,
        createdBy: String
    ) {
        self.id = UUID().uuidString.lowercased()
        self.districtId = districtId
        self.sourceType = sourceType
        self.name = name
        self.sourceSubtype = sourceSubtype
        self.condition = condition
        self.description = description
        self.zone = zone
        self.zone2 = zone2
        self.geometry = geometry
        self.createdBy = createdBy
        self.createdAt = Date()
        self.updatedAt = Date()
        self.syncedToSupabase = false
    }
    
    // MARK: - Coordinate Access (nil-safe)
    
    var coordinate: CLLocationCoordinate2D? { geometry.primaryCoordinate }
    var allCoordinates: [CLLocationCoordinate2D] { geometry.allCoordinates }
    var vertexCount: Int { geometry.allCoordinates.count }
    
    var displayName: String {
        if !name.isEmpty { return name }
        if !sourceSubtype.isEmpty { return sourceSubtype }
        return sourceType.displayName
    }
    
    // MARK: - Supabase Payloads
    
    private var isoFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
    
    /// Full payload for INSERT
    func toSupabaseInsertPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "district_id": districtId,
            "source_type": sourceType.rawValue,
            "name": name,
            "source_subtype": sourceSubtype,
            "condition": condition.rawValue,
            "description": description,
            "geometry": geometry.toGeoJSONDict(),
            "created_by": createdBy,
            "created_at": isoFormatter.string(from: createdAt),
            "updated_at": isoFormatter.string(from: updatedAt)
        ]
        if let zone = zone, !zone.isEmpty { payload["zone"] = zone }
        if let zone2 = zone2, !zone2.isEmpty { payload["zone2"] = zone2 }
        return payload
    }
    
    /// Partial payload for UPDATE
    func toSupabaseUpdatePayload() -> [String: Any] {
        var payload: [String: Any] = [
            "name": name,
            "source_subtype": sourceSubtype,
            "condition": condition.rawValue,
            "description": description,
            "geometry": geometry.toGeoJSONDict(),
            "updated_at": isoFormatter.string(from: Date())
        ]
        if let zone = zone, !zone.isEmpty { payload["zone"] = zone }
        if let zone2 = zone2, !zone2.isEmpty { payload["zone2"] = zone2 }
        return payload
    }
}

// MARK: - Pending Source Geometry

struct PendingSourceGeometry: Codable {
    var type: String
    var coordinates: [[Double]]
    
    static func point(_ coordinate: CLLocationCoordinate2D) -> PendingSourceGeometry {
        PendingSourceGeometry(type: "Point", coordinates: [[coordinate.longitude, coordinate.latitude]])
    }
    
    static func multiPoint(_ coordinates: [CLLocationCoordinate2D]) -> PendingSourceGeometry {
        PendingSourceGeometry(type: "MultiPoint", coordinates: coordinates.map { [$0.longitude, $0.latitude] })
    }
    
    func addingVertex(_ coordinate: CLLocationCoordinate2D) -> PendingSourceGeometry {
        var newCoords = coordinates
        newCoords.append([coordinate.longitude, coordinate.latitude])
        return PendingSourceGeometry(type: "MultiPoint", coordinates: newCoords)
    }
    
    func removingLastVertex() -> PendingSourceGeometry? {
        guard coordinates.count > 1 else { return nil }
        var newCoords = coordinates
        newCoords.removeLast()
        return PendingSourceGeometry(type: "MultiPoint", coordinates: newCoords)
    }
    
    var primaryCoordinate: CLLocationCoordinate2D? {
        guard let first = coordinates.first, first.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: first[1], longitude: first[0])
    }
    
    var allCoordinates: [CLLocationCoordinate2D] {
        coordinates.compactMap { coord in
            guard coord.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
        }
    }
    
    func toGeoJSONString() -> String {
            let dict = toGeoJSONDict()
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str = String(data: data, encoding: .utf8) else {
                return "{\"type\":\"\(type)\",\"coordinates\":[]}"
            }
            return str
        }
    /// Convert to GeoJSON dict for Supabase JSONB column.
    /// Handles nesting differences between GeoJSON types.
    func toGeoJSONDict() -> [String: Any] {
            switch type {
            case "Point":
                let coords = coordinates.first ?? [0, 0]
                return ["type": "Point", "coordinates": coords.map { NSNumber(value: $0) }]
            case "Polygon":
                let rings = coordinates.map { ring in ring.map { NSNumber(value: $0) } }
                return ["type": "Polygon", "coordinates": [rings]]
            default:
                let mapped = coordinates.map { pair in pair.map { NSNumber(value: $0) } }
                return ["type": type, "coordinates": mapped]
            }
        }
}

// MARK: - CodableJSON

/// Handles ANY nesting depth for JSON serialization.
/// Safe for GeoJSON geometry which has arrays of arrays of arrays.
enum CodableJSON: Codable, Equatable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case array([CodableJSON])
    case object([String: CodableJSON])
    case null
    
    /// Convert any Swift value to CodableJSON. Never crashes.
    static func from(_ value: Any) -> CodableJSON {
        if let str = value as? String { return .string(str) }
        if let bool = value as? Bool { return .bool(bool) }
        if let num = value as? Int { return .int(num) }
        if let num = value as? Double { return .double(num) }
        if let arr = value as? [Any] { return .array(arr.map { from($0) }) }
        if let dict = value as? [String: Any] { return .object(dict.mapValues { from($0) }) }
        if let num = value as? NSNumber {
            if CFBooleanGetTypeID() == CFGetTypeID(num) { return .bool(num.boolValue) }
            if num.doubleValue == Double(num.intValue) { return .int(num.intValue) }
            return .double(num.doubleValue)
        }
        return .null
    }
    
    /// Convert back to plain Swift value for JSONSerialization
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .double(let d): return d
        case .int(let i): return i
        case .bool(let b): return b
        case .array(let arr): return arr.map { $0.anyValue }
        case .object(let dict): return dict.mapValues { $0.anyValue }
        case .null: return NSNull()
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let a = try? container.decode([CodableJSON].self) { self = .array(a) }
        else if let o = try? container.decode([String: CodableJSON].self) { self = .object(o) }
        else { self = .null }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .double(let d): try container.encode(d)
        case .int(let i): try container.encode(i)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Pending Vertex Annotation

class PendingVertexAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let vertexNumber: Int
    let sourceId: String
    let sourceType: AddSourceType
    let colorHex: String 
    
    init(coordinate: CLLocationCoordinate2D, vertexNumber: Int,
         sourceId: String, sourceType: AddSourceType,
         colorHex: String = "#14b8a6") {  // Default teal
        self.coordinate = coordinate
        self.vertexNumber = vertexNumber
        self.sourceId = sourceId
        self.sourceType = sourceType
        self.colorHex = colorHex
    }
    
    // Update markerImage to use colorHex instead of hardcoded teal
    var markerImage: UIImage {
        let size = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            let color = UIColor(hexString: colorHex)
            color.setFill()
            UIColor.white.setStroke()
            ctx.setLineWidth(2)
            ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            ctx.strokeEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            
            // Draw vertex number
            let text = "\(vertexNumber)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 11),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.size(withAttributes: attrs)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
        }
    }
}

// MARK: - Source Subtype Presets

struct SourceSubtypePresets {
    static func presets(for type: AddSourceType) -> [String] {
        switch type {
        case .pointsite:
            return ["Catch Basin", "Standing Water", "Pond", "Pool", "Fountain",
                    "Container", "Tire Pile", "Septic", "Other"]
        case .stormdrain:
            return ["Curb Inlet", "Grate Inlet", "Manhole", "Catch Basin",
                    "Junction Box", "Retention Basin", "Other"]
        case .polyline:
            return ["Ditch", "Canal", "Creek", "Channel", "Drainage Swale",
                    "Pipe Run", "Other"]
        case .polygon:
            return ["Field", "Wetland", "Marsh", "Retention Pond",
                    "Treatment Zone", "Other"]
        }
    }
}
