import AppKit
import CoreLocation

/// Compact elevation-vs-distance chart drawn under the map, with a hover
/// crosshair that reports the hovered point back (to mark it on the map).
final class ElevationProfileView: NSView {

    var profile: [GPXDocument.ProfilePoint] = [] {
        didSet {
            hoverIndex = nil
            needsDisplay = true
        }
    }

    /// Called with the hovered point, or nil when the cursor leaves the chart.
    var onHover: ((GPXDocument.ProfilePoint?) -> Void)?

    private var hoverIndex: Int? {
        didSet { if hoverIndex != oldValue { needsDisplay = true } }
    }

    private var chartRect: NSRect {
        NSRect(x: 10, y: 17, width: bounds.width - 20, height: bounds.height - 27)
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard profile.count > 1, let total = profile.last?.distance, total > 0,
              chartRect.width > 0 else { return }
        let location = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, (location.x - chartRect.minX) / chartRect.width))
        let target = Double(fraction) * total

        var lo = 0, hi = profile.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if profile[mid].distance < target { lo = mid } else { hi = mid }
        }
        let index = (target - profile[lo].distance) <= (profile[hi].distance - target) ? lo : hi
        hoverIndex = index
        onHover?(profile[index])
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        onHover?(nil)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard profile.count > 1, let total = profile.last?.distance, total > 0 else { return }

        let chart = chartRect
        guard chart.width > 20, chart.height > 20 else { return }

        var minEle = profile.map(\.elevation).min()!
        var maxEle = profile.map(\.elevation).max()!
        if maxEle - minEle < 10 {
            let mid = (maxEle + minEle) / 2
            minEle = mid - 5
            maxEle = mid + 5
        }

        func point(_ p: GPXDocument.ProfilePoint) -> NSPoint {
            NSPoint(x: chart.minX + CGFloat(p.distance / total) * chart.width,
                    y: chart.minY + CGFloat((p.elevation - minEle) / (maxEle - minEle)) * chart.height)
        }

        let step = max(1, profile.count / (Int(chart.width) * 2))
        var points = stride(from: 0, to: profile.count, by: step).map { point(profile[$0]) }
        if step > 1 { points.append(point(profile[profile.count - 1])) }

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // Distance gridlines at a "nice" km interval.
        let stepKm = [0.5, 1, 2, 5, 10, 20, 50, 100].first { total / 1000 / $0 <= 6 } ?? 200
        var km = stepKm
        while km * 1000 < total {
            let x = chart.minX + CGFloat(km * 1000 / total) * chart.width
            NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setStroke()
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: x, y: chart.minY))
            grid.line(to: NSPoint(x: x, y: chart.maxY))
            grid.lineWidth = 0.5
            grid.stroke()
            let text = km.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f km", km)
                : String(format: "%.1f km", km)
            NSAttributedString(string: text, attributes: labelAttributes)
                .draw(at: NSPoint(x: x + 3, y: 2))
            km += stepKm
        }

        // Filled area under the curve.
        let area = NSBezierPath()
        area.move(to: NSPoint(x: points[0].x, y: chart.minY))
        points.forEach { area.line(to: $0) }
        area.line(to: NSPoint(x: points[points.count - 1].x, y: chart.minY))
        area.close()
        NSGraphicsContext.current?.saveGraphicsState()
        area.addClip()
        NSGradient(starting: NSColor.trackOrange.withAlphaComponent(0.4),
                   ending: NSColor.trackOrange.withAlphaComponent(0.04))?
            .draw(in: chart, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // The curve itself.
        let line = NSBezierPath()
        line.move(to: points[0])
        points.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        NSColor.trackOrange.setStroke()
        line.stroke()

        // Min / max altitude labels.
        NSAttributedString(string: String(format: "%.0f m", maxEle), attributes: labelAttributes)
            .draw(at: NSPoint(x: chart.minX + 2, y: chart.maxY - 12))
        NSAttributedString(string: String(format: "%.0f m", minEle), attributes: labelAttributes)
            .draw(at: NSPoint(x: chart.minX + 2, y: chart.minY + 2))

        // Hover crosshair, dot on the curve, and tooltip.
        if let index = hoverIndex, index < profile.count {
            let p = profile[index]
            let pos = point(p)

            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
            let crosshair = NSBezierPath()
            crosshair.move(to: NSPoint(x: pos.x, y: chart.minY))
            crosshair.line(to: NSPoint(x: pos.x, y: chart.maxY))
            crosshair.lineWidth = 1
            crosshair.stroke()

            let dotRect = NSRect(x: pos.x - 4.5, y: pos.y - 4.5, width: 9, height: 9)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -2, dy: -2)).fill()
            NSColor.trackOrange.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            let distanceText = p.distance >= 1000
                ? String(format: "%.1f km", p.distance / 1000)
                : String(format: "%.0f m", p.distance)
            let tooltip = NSAttributedString(
                string: "\(distanceText) · \(String(format: "%.0f m", p.elevation))",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ])
            let size = tooltip.size()
            let pad: CGFloat = 5
            var origin = NSPoint(x: pos.x + 9, y: chart.maxY - size.height - 4)
            if origin.x + size.width + pad * 2 > chart.maxX {
                origin.x = pos.x - 9 - size.width - pad * 2
            }
            let background = NSRect(x: origin.x, y: origin.y - 3,
                                    width: size.width + pad * 2, height: size.height + 6)
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
            tooltip.draw(at: NSPoint(x: origin.x + pad, y: origin.y))
        }
    }
}
