import CoreGraphics

/// Small monochrome companion to the production spacebar-and-piano app icon.
enum BrandGlyph {
    static func draw(in context: CGContext, rect: CGRect, background: Bool = true) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
        if background {
            context.setFillColor(CGColor(srgbRed: 0.96, green: 0.38, blue: 0.25, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900), cornerWidth: 205, cornerHeight: 205, transform: nil))
            context.fillPath()
        }
        context.translateBy(x: 512, y: 512)
        if background { context.rotate(by: -.pi / 15) }
        context.translateBy(x: -512, y: -512)
        let body = background ? CGRect(x: 170, y: 350, width: 684, height: 330) : CGRect(x: 45, y: 280, width: 934, height: 464)
        context.setFillColor(background ? CGColor(srgbRed: 0.98, green: 0.94, blue: 0.86, alpha: 1) : CGColor(gray: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: body, cornerWidth: 80, cornerHeight: 80, transform: nil)); context.fillPath()
        if background { context.setFillColor(CGColor(srgbRed: 0.18, green: 0.13, blue: 0.22, alpha: 1)) }
        else { context.setBlendMode(.clear) }
        for fraction in [0.19, 0.39, 0.59, 0.79] {
            let slot = CGRect(x: body.minX + body.width * fraction - body.width * 0.045,
                              y: body.minY - 2, width: body.width * 0.09, height: body.height * 0.59)
            context.addPath(CGPath(roundedRect: slot, cornerWidth: 16, cornerHeight: 16, transform: nil)); context.fillPath()
        }
        context.restoreGState()
    }
}
