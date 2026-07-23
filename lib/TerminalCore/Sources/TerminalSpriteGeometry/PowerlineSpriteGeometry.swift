// Cell-local physical-pixel paths for Ghostty's geometric Powerline glyphs.

/// The exact finite Powerline vocabulary supported by DanTerm's sprite renderer.
public enum PowerlinePattern: CaseIterable, Equatable, Sendable {
    case rightHard, rightThin, leftHard, leftThin
    case rightHardRounded, rightThinRounded, leftHardRounded, leftThinRounded
    case upperRightHardDiagonal, upperRightThinDiagonal
    case lowerRightHardDiagonal, lowerRightThinDiagonal
    case lowerLeftHardDiagonal, lowerLeftThinDiagonal
    case upperLeftHardDiagonal, upperLeftThinDiagonal
    case leftCap, rightCap
}

/// A fractional coordinate in cell-local physical-pixel space.
public struct PowerlinePixelPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Retains Ghostty's cubic rounded-divider construction without leaking Core Graphics.
public enum PowerlinePixelPathCommand: Equatable, Sendable {
    case move(PowerlinePixelPoint)
    case line(PowerlinePixelPoint)
    case cubic(
        control1: PowerlinePixelPoint,
        control2: PowerlinePixelPoint,
        end: PowerlinePixelPoint
    )
    case close
}

/// Makes each path's fill or clipping-aware stroke behavior explicit.
public enum PowerlinePixelPathStyle: Equatable, Sendable {
    case fill
    case stroke(widthPixels: Int)
    case innerStroke(widthPixels: Int)
}

/// One deterministic Powerline path expressed entirely in physical-pixel coordinates.
public struct PowerlinePixelPath: Equatable, Sendable {
    public let commands: [PowerlinePixelPathCommand]
    public let style: PowerlinePixelPathStyle

    public init(commands: [PowerlinePixelPathCommand], style: PowerlinePixelPathStyle) {
        self.commands = commands
        self.style = style
    }
}

/// Carries the one or two paths needed to paint a Powerline glyph.
public struct PowerlinePixelGeometry: Equatable, Sendable {
    public let paths: [PowerlinePixelPath]

    public init(paths: [PowerlinePixelPath]) {
        self.paths = paths
    }

    func mirroredHorizontally(cellWidthPixels width: Int) -> Self {
        Self(paths: paths.map { path in
            PowerlinePixelPath(
                commands: path.commands.map { $0.mirroredHorizontally(width: Double(width)) },
                style: path.style
            )
        })
    }
}

/// Reproduces Ghostty's triangles, cubic dividers, strokes, and split caps.
public enum PowerlineSpriteGeometry {
    public static func geometry(
        pattern: PowerlinePattern,
        cellWidthPixels width: Int,
        cellHeightPixels height: Int,
        lightStrokePixels requestedLight: Int
    ) -> PowerlinePixelGeometry {
        precondition(width >= 0 && height >= 0 && requestedLight > 0)
        guard width > 0 && height > 0 else { return .init(paths: []) }
        let stroke = min(requestedLight, width, height)
        let right: PowerlinePixelGeometry

        switch pattern {
        case .rightHard:
            right = .init(paths: [triangle(
                .init(x: 0, y: 0), .init(x: Double(width), y: Double(height) / 2),
                .init(x: 0, y: Double(height))
            )])
        case .leftHard:
            return geometry(
                pattern: .rightHard, cellWidthPixels: width,
                cellHeightPixels: height, lightStrokePixels: stroke
            ).mirroredHorizontally(cellWidthPixels: width)
        case .rightThin:
            right = .init(paths: [.init(commands: [
                .move(.init(x: 0, y: 0)),
                .line(.init(x: Double(width), y: Double(height) / 2)),
                .line(.init(x: 0, y: Double(height))),
            ], style: .stroke(widthPixels: stroke))])
        case .leftThin:
            return geometry(
                pattern: .rightThin, cellWidthPixels: width,
                cellHeightPixels: height, lightStrokePixels: stroke
            ).mirroredHorizontally(cellWidthPixels: width)
        case .rightHardRounded, .rightThinRounded:
            right = rounded(
                width: width, height: height, stroke: stroke,
                filled: pattern == .rightHardRounded
            )
        case .leftHardRounded:
            return geometry(
                pattern: .rightHardRounded, cellWidthPixels: width,
                cellHeightPixels: height, lightStrokePixels: stroke
            ).mirroredHorizontally(cellWidthPixels: width)
        case .leftThinRounded:
            return geometry(
                pattern: .rightThinRounded, cellWidthPixels: width,
                cellHeightPixels: height, lightStrokePixels: stroke
            ).mirroredHorizontally(cellWidthPixels: width)
        case .upperRightHardDiagonal:
            right = .init(paths: [triangle(
                .init(x: 0, y: 0), .init(x: Double(width), y: Double(height)),
                .init(x: 0, y: Double(height))
            )])
        case .lowerRightHardDiagonal:
            return geometry(
                pattern: .upperRightHardDiagonal, cellWidthPixels: width,
                cellHeightPixels: height, lightStrokePixels: stroke
            ).mirroredHorizontally(cellWidthPixels: width)
        case .lowerLeftHardDiagonal:
            right = .init(paths: [triangle(
                .init(x: 0, y: 0), .init(x: Double(width), y: 0),
                .init(x: 0, y: Double(height))
            )])
        case .upperLeftHardDiagonal:
            return geometry(
                pattern: .lowerLeftHardDiagonal, cellWidthPixels: width,
                cellHeightPixels: height, lightStrokePixels: stroke
            ).mirroredHorizontally(cellWidthPixels: width)
        case .upperRightThinDiagonal, .upperLeftThinDiagonal:
            right = diagonal(
                from: .init(x: 0, y: 0),
                to: .init(x: Double(width), y: Double(height)),
                stroke: stroke
            )
        case .lowerRightThinDiagonal, .lowerLeftThinDiagonal:
            right = diagonal(
                from: .init(x: Double(width), y: 0),
                to: .init(x: 0, y: Double(height)),
                stroke: stroke
            )
        case .leftCap:
            right = cap(width: width, height: height, stroke: stroke)
        case .rightCap:
            return geometry(
                pattern: .leftCap, cellWidthPixels: width,
                cellHeightPixels: height, lightStrokePixels: stroke
            ).mirroredHorizontally(cellWidthPixels: width)
        }
        return right
    }

    private static func triangle(
        _ first: PowerlinePixelPoint,
        _ second: PowerlinePixelPoint,
        _ third: PowerlinePixelPoint
    ) -> PowerlinePixelPath {
        .init(commands: [.move(first), .line(second), .line(third), .close], style: .fill)
    }

    private static func diagonal(
        from: PowerlinePixelPoint,
        to: PowerlinePixelPoint,
        stroke: Int
    ) -> PowerlinePixelGeometry {
        .init(paths: [.init(
            commands: [.move(from), .line(to)],
            style: .stroke(widthPixels: stroke)
        )])
    }

    private static func rounded(
        width: Int, height: Int, stroke: Int, filled: Bool
    ) -> PowerlinePixelGeometry {
        let w = Double(width)
        let h = Double(height)
        let radius = min(w, h / 2)
        let c = (2.squareRoot() - 1) * 4 / 3
        var commands: [PowerlinePixelPathCommand] = [
            .move(.init(x: 0, y: 0)),
            .cubic(
                control1: .init(x: radius * c, y: 0),
                control2: .init(x: radius, y: radius - radius * c),
                end: .init(x: radius, y: radius)
            ),
            .line(.init(x: radius, y: h - radius)),
            .cubic(
                control1: .init(x: radius, y: h - radius + radius * c),
                control2: .init(x: radius * c, y: h),
                end: .init(x: 0, y: h)
            ),
        ]
        if filled { commands.append(.close) }
        return .init(paths: [.init(
            commands: commands,
            style: filled ? .fill : .innerStroke(widthPixels: stroke)
        )])
    }

    private static func cap(width: Int, height: Int, stroke: Int) -> PowerlinePixelGeometry {
        let w = Double(width)
        let h = Double(height)
        let half = h / 2
        let halfStroke = Double(stroke) / 2
        return .init(paths: [
            .init(commands: [
                .move(.init(x: 0, y: 0)), .line(.init(x: w, y: 0)),
                .line(.init(x: w / 2, y: half - halfStroke)),
                .line(.init(x: 0, y: half - halfStroke)), .close,
            ], style: .fill),
            .init(commands: [
                .move(.init(x: 0, y: h)), .line(.init(x: w, y: h)),
                .line(.init(x: w / 2, y: half + halfStroke)),
                .line(.init(x: 0, y: half + halfStroke)), .close,
            ], style: .fill),
        ])
    }
}

private extension PowerlinePixelPathCommand {
    func mirroredHorizontally(width: Double) -> Self {
        func mirror(_ point: PowerlinePixelPoint) -> PowerlinePixelPoint {
            .init(x: width - point.x, y: point.y)
        }
        return switch self {
        case let .move(point): .move(mirror(point))
        case let .line(point): .line(mirror(point))
        case let .cubic(control1, control2, end):
            .cubic(control1: mirror(control1), control2: mirror(control2), end: mirror(end))
        case .close: .close
        }
    }
}
