//
//  ServiceRequestPin.swift
//  MADxSync
//
//  Data model for Service Request pins created by management in the HUB.
//  Matches the `service_requests` Supabase table schema exactly.
//
//  Sibling of SourceFinderPin — same lifecycle, same promotion path.
//  Added fields: caller_name, caller_phone, city, state, zip (structured address).
//
//  Lifecycle: pending → inspected → resolved
//  Requests are temporary — they either get promoted to permanent
//  point-sites (via existing approval queue) or expire via push-off timer.
//

import Foundation
import CoreLocation

// MARK: - Service Request Pin

struct ServiceRequestPin: Codable, Identifiable, Equatable {
    var id: String
    var districtId: String
    var latitude: Double
    var longitude: Double
    
    // Caller info (SR-specific)
    var callerName: String?
    var callerPhone: String?
    
    // Structured address (SR-specific)
    var address: String?
    var city: String?
    var state: String?
    var zip: String?
    
    // Shared with SF
    var sourceType: String        // green_pool, standing_water, neglected_property, other
    var priority: String           // low, normal, urgent
    var mainMessage: String?
    var shoutOut: String?
    var status: String             // pending, inspected, resolved
    var createdBy: String?
    var createdAt: Date
    var inspectedBy: String?
    var inspectedAt: Date?
    var techFindings: String?
    var recommendedPermanent: Bool
    var pushOffDays: Int
    var expiresAt: Date?
    var updatedAt: Date
    
    // Local-only flags (not stored in Supabase)
    var hasBeenShownAsBanner: Bool = false
    
    // MARK: - Coding Keys (snake_case ↔ camelCase)
    
    enum CodingKeys: String, CodingKey {
        case id
        case districtId = "district_id"
        case latitude, longitude
        case callerName = "caller_name"
        case callerPhone = "caller_phone"
        case address, city, state, zip
        case sourceType = "source_type"
        case priority
        case mainMessage = "main_message"
        case shoutOut = "shout_out"
        case status
        case createdBy = "created_by"
        case createdAt = "created_at"
        case inspectedBy = "inspected_by"
        case inspectedAt = "inspected_at"
        case techFindings = "tech_findings"
        case recommendedPermanent = "recommended_permanent"
        case pushOffDays = "push_off_days"
        case expiresAt = "expires_at"
        case updatedAt = "updated_at"
    }
    
    // MARK: - Computed Properties
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    var isPending: Bool { status == "pending" }
    var isInspected: Bool { status == "inspected" }
    var isResolved: Bool { status == "resolved" }
    var isUrgent: Bool { priority == "urgent" }
    
    var sourceTypeLabel: String {
        switch sourceType {
        case "green_pool": return "Green Pool"
        case "standing_water": return "Standing Water"
        case "neglected_property": return "Neglected Property"
        case "other": return "Other"
        default: return sourceType.capitalized
        }
    }
    
    var priorityLabel: String {
        priority.capitalized
    }
    
    /// Full formatted address from structured fields
    var fullAddress: String? {
        let parts = [address, city, state, zip].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
    
    var displayTitle: String {
        if let full = fullAddress {
            return full
        }
        if let addr = address, !addr.isEmpty {
            return addr
        }
        return "\(sourceTypeLabel) — \(String(format: "%.4f, %.4f", latitude, longitude))"
    }
    
    /// Caller display string for banner and detail views
    var callerDisplay: String? {
        let parts = [callerName, callerPhone].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
    
    // MARK: - Equatable (compare by id only for set operations)
    
    static func == (lhs: ServiceRequestPin, rhs: ServiceRequestPin) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - JSON Decoding from Supabase REST Response

extension ServiceRequestPin {
    
    /// Decode from a Supabase JSON dictionary (uses JSONSerialization, not Codable,
    /// for flexibility with date formats and null handling — matches HubSyncService pattern)
    static func fromJSON(_ row: [String: Any]) -> ServiceRequestPin? {
        guard let id = row["id"] as? String,
              let districtId = row["district_id"] as? String,
              let latitude = row["latitude"] as? Double,
              let longitude = row["longitude"] as? Double else {
            return nil
        }
        
        return ServiceRequestPin(
            id: id,
            districtId: districtId,
            latitude: latitude,
            longitude: longitude,
            callerName: row["caller_name"] as? String,
            callerPhone: row["caller_phone"] as? String,
            address: row["address"] as? String,
            city: row["city"] as? String,
            state: row["state"] as? String,
            zip: row["zip"] as? String,
            sourceType: row["source_type"] as? String ?? "other",
            priority: row["priority"] as? String ?? "normal",
            mainMessage: row["main_message"] as? String,
            shoutOut: row["shout_out"] as? String,
            status: row["status"] as? String ?? "pending",
            createdBy: row["created_by"] as? String,
            createdAt: parseDate(row["created_at"]) ?? Date(),
            inspectedBy: row["inspected_by"] as? String,
            inspectedAt: parseDate(row["inspected_at"]),
            techFindings: row["tech_findings"] as? String,
            recommendedPermanent: row["recommended_permanent"] as? Bool ?? false,
            pushOffDays: row["push_off_days"] as? Int ?? 7,
            expiresAt: parseDate(row["expires_at"]),
            updatedAt: parseDate(row["updated_at"]) ?? Date(),
            hasBeenShownAsBanner: false
        )
    }
    
    /// Parse ISO 8601 dates from Supabase (handles both standard and fractional seconds)
    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: string) { return date }
        
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        
        return nil
    }
}
