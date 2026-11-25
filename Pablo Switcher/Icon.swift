import AppKit
import SwiftUI

public enum MenuBarIconRenderer {
    public static let defaultText = "PB"
    public static let widthPt: CGFloat = 24
    public static let heightPt: CGFloat = 18
    public static let fontSizePt: CGFloat = 10

    /// Генерує векторну Template-іконку для Menu Bar (24x18 pt).
    /// macOS автоматично рендерить її під будь-який масштаб дисплея (@1x / @2x)
    /// та адаптує колір під світлу/темну тему панелі меню.
    public static func makeMenuBarImage(
        text: String = defaultText,
        fontSizePt: CGFloat = fontSizePt
    ) -> NSImage {
        let size = NSSize(width: widthPt, height: heightPt)

        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Рамка 22x16 pt з відступом 1 pt з усіх боків (піксельно-точна на Retina)
            let borderRect = NSRect(
                x: 1.5,
                y: 1.5,
                width: rect.width - 3.0,
                height: rect.height - 3.0
            )
            let path = NSBezierPath(roundedRect: borderRect, xRadius: 3.0, yRadius: 3.0)
            path.lineWidth = 1.0
            path.stroke()

            // Центрований текст
            let font = NSFont.systemFont(ofSize: fontSizePt, weight: .bold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]

            let attrString = NSAttributedString(string: text, attributes: attributes)
            let textSize = attrString.size()
            let textRect = NSRect(
                x: (rect.width - textSize.width) / 2.0,
                y: (rect.height - textSize.height) / 2.0 - 0.5, // легка оптична корекція по вертикалі
                width: textSize.width,
                height: textSize.height
            )
            attrString.draw(in: textRect)

            return true
        }

        image.isTemplate = true
        return image
    }
}
