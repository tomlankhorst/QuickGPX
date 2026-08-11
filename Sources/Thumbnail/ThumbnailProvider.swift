import AppKit
import CoreLocation
import QuickLookThumbnailing

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let size = request.maximumSize
        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            guard let gpx = try? GPXDocument(contentsOf: request.fileURL) else { return false }
            ThumbnailProvider.draw(gpx, in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }

    private static func draw(_ gpx: GPXDocument, in rect: CGRect) {
        NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
        let background = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: rect.width * 0.06, yRadius: rect.width * 0.06)
        background.fill()
        NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
        background.lineWidth = 1
        background.stroke()

        // Bounding box over everything we might draw.
        var points = gpx.allTrackPoints.map { $0.coordinate }
        points.append(contentsOf: gpx.waypoints.map { $0.coordinate })
        guard let firstCoordinate = points.first else { return }

        var minLat = firstCoordinate.latitude, maxLat = firstCoordinate.latitude
        var minLon = firstCoordinate.longitude, maxLon = firstCoordinate.longitude
        for c in points {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        // Equirectangular projection with latitude correction; preserve aspect ratio.
        let lonScale = cos((minLat + maxLat) / 2 * .pi / 180)
        let spanX = max((maxLon - minLon) * lonScale, 1e-6)
        let spanY = max(maxLat - minLat, 1e-6)
        let inset = rect.width * 0.14
        let drawable = rect.insetBy(dx: inset, dy: inset)
        let scale = min(drawable.width / spanX, drawable.height / spanY)
        let offsetX = drawable.midX - spanX * scale / 2
        let offsetY = drawable.midY - spanY * scale / 2

        func project(_ c: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: offsetX + (c.longitude - minLon) * lonScale * scale,
                    y: offsetY + (c.latitude - minLat) * scale)
        }

        let lineWidth = max(2, rect.width / 42)
        for segment in gpx.segments where segment.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.move(to: project(segment[0].coordinate))
            for point in segment.dropFirst() { path.line(to: project(point.coordinate)) }

            NSColor.white.setStroke()
            path.lineWidth = lineWidth * 1.9
            path.stroke()
            NSColor.trackOrange.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }

        let dotRadius = max(2.5, rect.width / 34)
        func dot(_ center: CGPoint, _ color: NSColor) {
            let dotRect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                 width: dotRadius * 2, height: dotRadius * 2)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        if let first = gpx.segments.first?.first { dot(project(first.coordinate), .systemGreen) }
        if let last = gpx.segments.last?.last { dot(project(last.coordinate), .systemRed) }
        for waypoint in gpx.waypoints.prefix(60) { dot(project(waypoint.coordinate), .systemIndigo) }
    }
}
