import Foundation
import CoreLocation

/// Minimal GPX parser: tracks (trk/trkseg/trkpt), routes (rte/rtept) and waypoints (wpt).
final class GPXDocument: NSObject {

    struct Point {
        var coordinate: CLLocationCoordinate2D
        var elevation: Double?
        var time: Date?
    }

    struct Waypoint {
        var coordinate: CLLocationCoordinate2D
        var name: String?
    }

    /// One entry per trkseg (and one per rte), in document order.
    private(set) var segments: [[Point]] = []
    private(set) var waypoints: [Waypoint] = []
    private(set) var name: String?
    private(set) var metadataTime: Date?

    enum GPXError: LocalizedError {
        case malformed
        case empty
        var errorDescription: String? {
            switch self {
            case .malformed: return "The file is not valid GPX."
            case .empty: return "The file contains no location data."
            }
        }
    }

    init(contentsOf url: URL) throws {
        super.init()
        guard let parser = XMLParser(contentsOf: url) else { throw GPXError.malformed }
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse() || !(segments.isEmpty && waypoints.isEmpty) else {
            throw GPXError.malformed
        }
        segments.removeAll { $0.isEmpty }
        if segments.isEmpty && waypoints.isEmpty { throw GPXError.empty }
    }

    // MARK: - Derived stats

    var allTrackPoints: [Point] { segments.flatMap { $0 } }

    var startCoordinate: CLLocationCoordinate2D? {
        segments.first?.first?.coordinate ?? waypoints.first?.coordinate
    }

    /// Best guess at when the activity happened.
    var activityDate: Date? {
        allTrackPoints.compactMap { $0.time }.first ?? metadataTime
    }

    var pointCount: Int { segments.reduce(0) { $0 + $1.count } }

    /// Total length of all segments, in meters.
    var totalDistance: Double {
        var total = 0.0
        for segment in segments {
            for i in 1..<max(segment.count, 1) {
                total += GPXDocument.haversine(segment[i - 1].coordinate, segment[i].coordinate)
            }
        }
        return total
    }

    /// Cumulative ascent in meters, from lightly smoothed elevations. Nil if no elevation data.
    var elevationGain: Double? {
        let elevations = elevationProfile.map(\.elevation)
        guard elevations.count > 1 else { return nil }
        // Moving average to suppress GPS elevation jitter.
        let window = 5
        var smoothed: [Double] = []
        smoothed.reserveCapacity(elevations.count)
        for i in 0..<elevations.count {
            let lo = max(0, i - window / 2), hi = min(elevations.count - 1, i + window / 2)
            let slice = elevations[lo...hi]
            smoothed.append(slice.reduce(0, +) / Double(slice.count))
        }
        var gain = 0.0
        for i in 1..<smoothed.count where smoothed[i] > smoothed[i - 1] {
            gain += smoothed[i] - smoothed[i - 1]
        }
        return gain
    }

    struct ProfilePoint {
        var distance: Double
        var elevation: Double
        var coordinate: CLLocationCoordinate2D
    }

    /// Cumulative distance / elevation / position for every track point that
    /// carries elevation, across all segments. Computed once; gain and range
    /// derive from it.
    private(set) lazy var elevationProfile: [ProfilePoint] = {
        var result: [ProfilePoint] = []
        var total = 0.0
        for segment in segments {
            for (i, point) in segment.enumerated() {
                if i > 0 {
                    total += GPXDocument.haversine(segment[i - 1].coordinate, point.coordinate)
                }
                if let elevation = point.elevation {
                    result.append(ProfilePoint(distance: total, elevation: elevation,
                                               coordinate: point.coordinate))
                }
            }
        }
        return result
    }()

    var elevationRange: (min: Double, max: Double)? {
        let elevations = elevationProfile.map(\.elevation)
        guard let lo = elevations.min(), let hi = elevations.max() else { return nil }
        return (lo, hi)
    }

    var duration: TimeInterval? {
        let times = allTrackPoints.compactMap { $0.time }
        guard let first = times.first, let last = times.last, last > first else { return nil }
        return last.timeIntervalSince(first)
    }

    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    // MARK: - Parser state

    private var currentSegment: [Point]?
    private var currentPoint: Point?
    private var currentWaypoint: Waypoint?
    private var text = ""
    private var inMetadata = false
    private var inTrackHeader = false

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func date(from string: String) -> Date? {
        iso.date(from: string) ?? isoFractional.date(from: string)
    }
}

extension GPXDocument: XMLParserDelegate {

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch element {
        case "metadata":
            inMetadata = true
        case "trk", "rte":
            inTrackHeader = true
            if element == "rte" { currentSegment = [] }
        case "trkseg":
            currentSegment = []
        case "trkpt", "rtept":
            if let lat = Double(attributes["lat"] ?? ""), let lon = Double(attributes["lon"] ?? "") {
                currentPoint = Point(coordinate: .init(latitude: lat, longitude: lon))
            }
        case "wpt":
            if let lat = Double(attributes["lat"] ?? ""), let lon = Double(attributes["lon"] ?? "") {
                currentWaypoint = Waypoint(coordinate: .init(latitude: lat, longitude: lon))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "metadata":
            inMetadata = false
        case "name":
            if currentWaypoint != nil {
                currentWaypoint?.name = value
            } else if (inMetadata || inTrackHeader) && (name?.isEmpty ?? true) {
                name = value
            }
        case "ele":
            currentPoint?.elevation = Double(value)
        case "time":
            if currentPoint != nil {
                currentPoint?.time = GPXDocument.date(from: value)
            } else if inMetadata {
                metadataTime = GPXDocument.date(from: value)
            }
        case "trkpt", "rtept":
            if let point = currentPoint { currentSegment?.append(point) }
            currentPoint = nil
        case "trkseg":
            if let segment = currentSegment { segments.append(segment) }
            currentSegment = nil
        case "trk":
            inTrackHeader = false
        case "rte":
            inTrackHeader = false
            if let segment = currentSegment { segments.append(segment) }
            currentSegment = nil
        case "wpt":
            if let waypoint = currentWaypoint { waypoints.append(waypoint) }
            currentWaypoint = nil
        default:
            break
        }
        text = ""
    }
}
