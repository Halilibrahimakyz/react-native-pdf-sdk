import CoreGraphics
import CoreText
import Foundation

/**
 * The two documents the viewer is shown and tried with.
 *
 * Made here rather than taken from anywhere, so that a screenshot of this
 * package is this package's own work and carries nobody's data. Run with
 * `npm run pdfs`, or `swift make.swift .` from this folder.
 *
 * `sheet.pdf` is the case the viewer exists for: one drawing nine metres wide
 * and half a metre tall, with dimensions written at a size that is a smudge
 * until you are zoomed in ten times. `report.pdf` is the ordinary case: ten A4
 * pages of headings, paragraphs and a table.
 */

// ─── Drawing helpers ─────────────────────────────────────────────────────────

let regular = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil)

enum Align {
  case left, centre, right
}

func write(
  _ string: String,
  at point: CGPoint,
  size: CGFloat,
  bold heavy: Bool = false,
  align: Align = .left,
  grey: CGFloat = 0,
  in context: CGContext
) {
  let font = CTFontCreateCopyWithAttributes(heavy ? bold : regular, size, nil, nil)
  // The keys come from CoreText rather than from AppKit: this runs with
  // Foundation and CoreGraphics alone.
  let line = CTLineCreateWithAttributedString(NSAttributedString(
    string: string,
    attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: grey, alpha: 1),
    ]
  ))
  let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  let x = align == .left ? point.x : (align == .centre ? point.x - width / 2 : point.x - width)
  context.textPosition = CGPoint(x: x, y: point.y)
  CTLineDraw(line, context)
}

func box(_ rect: CGRect, width: CGFloat = 0.6, grey: CGFloat = 0, in context: CGContext) {
  context.setStrokeColor(CGColor(gray: grey, alpha: 1))
  context.setLineWidth(width)
  context.stroke(rect)
}

func line(from: CGPoint, to: CGPoint, width: CGFloat = 0.4, grey: CGFloat = 0, in context: CGContext) {
  context.setStrokeColor(CGColor(gray: grey, alpha: 1))
  context.setLineWidth(width)
  context.beginPath()
  context.move(to: from)
  context.addLine(to: to)
  context.strokePath()
}

func pdf(_ path: String, size: CGSize, pages: Int, draw: (CGContext, Int) -> Void) {
  var media = CGRect(origin: .zero, size: size)
  guard let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &media, nil) else {
    print("could not write \(path)")
    return
  }
  for page in 0..<pages {
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(media)
    draw(context, page)
    context.endPDFPage()
  }
  context.closePDF()
  let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
  print("\(path): \(Int(size.width)) x \(Int(size.height)) pt, \(pages) page(s), \((bytes ?? 0) / 1024) kB")
}

// ─── One drawing, nine metres wide ───────────────────────────────────────────

/// Column letters across the sheet, the way a structural grid is labelled.
let columns = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")

func drawSheet(_ context: CGContext, _ size: CGSize) {
  let margin: CGFloat = 40
  let frame = CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2)
  box(frame, width: 2, in: context)
  box(frame.insetBy(dx: 6, dy: 6), width: 0.6, grey: 0.4, in: context)

  // The title block goes in the corner a drawing is signed in, and is drawn
  // last so that it sits over the plan. The plan itself starts at the left
  // edge, so that the sheet opens on drawing rather than on empty paper.
  let title = CGRect(x: frame.maxX - 914, y: frame.minY + 14, width: 900, height: 300)

  // The plan itself: a grid of bays, a column at every intersection, beams
  // between them and a slab panel in each cell. Everything is written twice,
  // once at a size that can be read at a glance and once at a size that cannot.
  let storey: CGFloat = 330
  let left = frame.minX + 180
  let bottom = frame.minY + 180
  let rows = Int((frame.maxY - 220 - bottom) / storey)
  let bays = columns.count - 1
  let bay = (title.minX - 260 - left) / CGFloat(bays)

  // The grid lines, with a bubble at the end of each.
  for column in 0...bays where column < columns.count {
    let x = left + CGFloat(column) * bay
    line(from: CGPoint(x: x, y: bottom - 70), to: CGPoint(x: x, y: frame.maxY - 150), width: 0.4, grey: 0.55, in: context)
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(1)
    context.strokeEllipse(in: CGRect(x: x - 26, y: frame.maxY - 144, width: 52, height: 52))
    write(String(columns[column]), at: CGPoint(x: x, y: frame.maxY - 126), size: 26, bold: true, align: .centre, in: context)
  }
  for row in 0...rows {
    let y = bottom + CGFloat(row) * storey
    line(from: CGPoint(x: left - 90, y: y), to: CGPoint(x: left + CGFloat(bays) * bay + 60, y: y), width: 0.4, grey: 0.55, in: context)
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(1)
    context.strokeEllipse(in: CGRect(x: left - 150, y: y - 26, width: 52, height: 52))
    write("\(row + 1)", at: CGPoint(x: left - 124, y: y - 9), size: 26, bold: true, align: .centre, in: context)
  }

  for column in 0...bays where column < columns.count {
    let x = left + CGFloat(column) * bay
    for row in 0...rows {
      let y = bottom + CGFloat(row) * storey
      let name = "\(columns[column])\(row + 1)"

      // The column, filled the way a section through concrete is.
      let post = CGRect(x: x - 22, y: y - 35, width: 44, height: 70)
      context.setFillColor(CGColor(gray: 0.15, alpha: 1))
      context.fill(post)
      // Below the beams rather than across them, the way a draughtsman would.
      write("S\(name)", at: CGPoint(x: x + 30, y: y - 34), size: 9, in: context)
      write("40/70 · 8Ø16", at: CGPoint(x: x + 30, y: y - 46), size: 6, grey: 0.3, in: context)
      write("Ø8@15 cm, ties at both ends", at: CGPoint(x: x + 30, y: y - 56), size: 3.5, grey: 0.45, in: context)

      // The beams leaving it, and the slab panel they carry.
      if column < bays {
        line(from: CGPoint(x: x + 22, y: y + 21), to: CGPoint(x: x + bay - 22, y: y + 21), width: 1.4, in: context)
        line(from: CGPoint(x: x + 22, y: y - 21), to: CGPoint(x: x + bay - 22, y: y - 21), width: 1.4, in: context)
        write("B\(name) (30/60)", at: CGPoint(x: x + bay / 2, y: y + 26), size: 8, align: .centre, in: context)

        if row < rows {
          let panel = CGRect(x: x + 40, y: y + 40, width: bay - 80, height: storey - 80)
          box(panel, width: 0.5, grey: 0.55, in: context)
          write("P\(name) — h = 18 cm", at: CGPoint(x: panel.midX, y: panel.maxY - 34), size: 12, bold: true, align: .centre, in: context)
          write(
            "top Ø10/15 both ways · bottom Ø10/20 both ways",
            at: CGPoint(x: panel.midX, y: panel.maxY - 54),
            size: 7,
            align: .centre,
            grey: 0.25,
            in: context
          )
          write(
            "C30/37 · cover 25 mm · casting sequence \(column + 1).\(row + 1) · formwork struck at 7 days",
            at: CGPoint(x: panel.midX, y: panel.minY + 22),
            size: 4,
            align: .centre,
            grey: 0.4,
            in: context
          )
          // A hatched corner, so there is fine line work to sharpen into.
          context.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
          context.setLineWidth(0.3)
          context.beginPath()
          var hatch = panel.minX + 6
          while hatch < panel.minX + 120 {
            context.move(to: CGPoint(x: hatch, y: panel.minY + 6))
            context.addLine(to: CGPoint(x: hatch - 40, y: panel.minY + 46))
            hatch += 8
          }
          context.strokePath()
        }
      }
      if row < rows {
        line(from: CGPoint(x: x - 21, y: y + 35), to: CGPoint(x: x - 21, y: y + storey - 35), width: 1.4, in: context)
        line(from: CGPoint(x: x + 21, y: y + 35), to: CGPoint(x: x + 21, y: y + storey - 35), width: 1.4, in: context)
      }
    }

    // The dimension chain, the smallest thing on the sheet.
    if column < bays {
      let dimension = bottom - 110
      line(from: CGPoint(x: x, y: dimension), to: CGPoint(x: x + bay, y: dimension), width: 0.4, in: context)
      line(from: CGPoint(x: x, y: dimension - 10), to: CGPoint(x: x, y: dimension + 10), width: 0.6, in: context)
      line(from: CGPoint(x: x + bay, y: dimension - 10), to: CGPoint(x: x + bay, y: dimension + 10), width: 0.6, in: context)
      write("\(Int(bay)) mm", at: CGPoint(x: x + bay / 2, y: dimension + 8), size: 7, align: .centre, in: context)
      write(
        "axis \(columns[column])–\(columns[min(column + 1, columns.count - 1)]) · setting out from grid A1",
        at: CGPoint(x: x + bay / 2, y: dimension - 22),
        size: 3,
        align: .centre,
        grey: 0.45,
        in: context
      )
    }
  }

  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(title)
  box(title, width: 1.2, in: context)
  write("PDF SDK", at: CGPoint(x: title.minX + 20, y: title.maxY - 70), size: 54, bold: true, in: context)
  write(
    "DEMONSTRATION SHEET",
    at: CGPoint(x: title.minX + 20, y: title.maxY - 100),
    size: 18,
    grey: 0.35,
    in: context
  )
  let fields = [
    ("PROJECT", "Tiled rendering, one sheet"),
    ("DRAWING", "Formwork plan, level +5.26"),
    ("SCALE", "1:50 at A0"),
    ("SHEET", "1 of 1"),
    ("REVISION", "C"),
  ]
  var row = title.maxY - 140
  for (name, value) in fields {
    write(name, at: CGPoint(x: title.minX + 20, y: row), size: 11, bold: true, grey: 0.35, in: context)
    write(value, at: CGPoint(x: title.minX + 160, y: row), size: 11, in: context)
    line(
      from: CGPoint(x: title.minX + 14, y: row - 8),
      to: CGPoint(x: title.maxX - 14, y: row - 8),
      width: 0.3,
      grey: 0.75,
      in: context
    )
    row -= 30
  }
  write(
    "Every line on this sheet was drawn by example/pdfs/make.swift. No part of it is anyone's work but this package's.",
    at: CGPoint(x: title.minX + 20, y: title.minY + 20),
    size: 10,
    grey: 0.45,
    in: context
  )

  // A note at the far end, so that crossing the sheet has a reward.
  write(
    "END OF SHEET",
    at: CGPoint(x: frame.maxX - 40, y: frame.midY),
    size: 46,
    bold: true,
    align: .right,
    grey: 0.15,
    in: context
  )
  write(
    "If you can read this, you have panned nine metres of paper.",
    at: CGPoint(x: frame.maxX - 40, y: frame.midY - 30),
    size: 12,
    align: .right,
    grey: 0.4,
    in: context
  )
}

// ─── Ten ordinary pages ──────────────────────────────────────────────────────

let headings = [
  "A viewer, and what it is for",
  "How a document opens",
  "How far it may be zoomed",
  "What is drawn, and when",
  "What is shown in the meantime",
  "Two platforms, one set of numbers",
  "What a tile costs",
  "Holding what has been drawn",
  "How often an event is worth sending",
  "Where this document came from",
]

let paragraphs = [
  "This document exists so that a viewer can be shown reading something ordinary. It carries no data belonging to anyone, and every line of it is drawn by a script that ships with the package.",
  "A page like this one is the case most viewers are built for: a fixed size, a column of text, a heading or two, and a table. It is also the case where a viewer can afford to draw the whole page at once, and where doing so is the quickest thing to do.",
  "The sheet in the other document is the case they are not built for. One drawing, nine metres wide, with dimensions written at a size that is a smudge on a phone until the zoom is ten times what the page opened at. Drawing that from one picture of the page means either a line across the middle of the screen or an image too large to hold.",
  "Between those two cases sits everything this package has to get right: how a document opens, how far it may be zoomed, which part of it is drawn at what moment, and what is shown in the meantime.",
  "A document opens fitted to its width, because a document is read by scrolling and fitting twelve pages on a phone would show twelve stamps. A page that is a strip rather than a page fills the height instead, and is read by panning sideways.",
  "How far a document may be zoomed is not a fixed number of times. It is worked out from the page: far enough in that a point of the page is about thirteen points of the screen, which is where a dimension written along a beam becomes comfortable rather than merely possible.",
  "What is on the screen is drawn in tiles, at the zoom it is being looked at. Nothing else is drawn. A tile that has left the view before its turn came is dropped rather than drawn, and the one nearest the middle of the view is always drawn first.",
  "While the tiles of a new zoom are on their way, the levels already held are drawn underneath them, coarsest first. Moving at a deep zoom therefore lands on something drawn on the way in, rather than on a blank rectangle.",
  "Tiles are held until the room runs out, oldest use first. Every tile on the screen is read on every frame, so a tile being looked at can never be the one thrown away to make room for its neighbour.",
  "A pinch changes the zoom on every frame, and whoever is listening is almost certainly putting the number on the screen. So the zoom is reported a few times a second rather than sixty, and once more when the movement stops.",
]

func drawReport(_ context: CGContext, page: Int, size: CGSize) {
  let margin: CGFloat = 56
  let width = size.width - margin * 2

  write("PDF SDK", at: CGPoint(x: margin, y: size.height - 50), size: 9, bold: true, grey: 0.45, in: context)
  write(
    "Demonstration report",
    at: CGPoint(x: size.width - margin, y: size.height - 50),
    size: 9,
    align: .right,
    grey: 0.45,
    in: context
  )
  line(
    from: CGPoint(x: margin, y: size.height - 58),
    to: CGPoint(x: size.width - margin, y: size.height - 58),
    width: 0.4,
    grey: 0.7,
    in: context
  )

  var y = size.height - 110
  write(
    headings[page % headings.count],
    at: CGPoint(x: margin, y: y),
    size: page == 0 ? 24 : 17,
    bold: true,
    in: context
  )
  y -= page == 0 ? 40 : 32

  // Four of the paragraphs, a different four on every page.
  for (index, paragraph) in (0..<4).map({ paragraphs[($0 * 3 + page) % paragraphs.count] }).enumerated() {
    let words = paragraph.split(separator: " ").map(String.init)
    var current = ""
    for word in words {
      let candidate = current.isEmpty ? word : current + " " + word
      let font = CTFontCreateCopyWithAttributes(regular, 11, nil, nil)
      let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: candidate,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
      ))
      if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > width {
        write(current, at: CGPoint(x: margin, y: y), size: 11, in: context)
        y -= 17
        current = word
      } else {
        current = candidate
      }
    }
    if !current.isEmpty {
      write(current, at: CGPoint(x: margin, y: y), size: 11, in: context)
      y -= 17
    }
    y -= 10
    if index == 1 && page % 3 == 0 {
      // A small table, since a document without one is not a document.
      let rows = ["Opening zoom", "Zoom ceiling", "Tile size", "Renderers"]
      let values = ["fits the width", "13 points to the point", "1280 pixels", "three at once"]
      let table = CGRect(x: margin, y: y - CGFloat(rows.count) * 22 - 26, width: width, height: CGFloat(rows.count) * 22 + 26)
      box(table, width: 0.6, grey: 0.4, in: context)
      write("Setting", at: CGPoint(x: table.minX + 10, y: table.maxY - 17), size: 9, bold: true, in: context)
      write("Value", at: CGPoint(x: table.minX + 200, y: table.maxY - 17), size: 9, bold: true, in: context)
      line(
        from: CGPoint(x: table.minX, y: table.maxY - 26),
        to: CGPoint(x: table.maxX, y: table.maxY - 26),
        width: 0.6,
        grey: 0.4,
        in: context
      )
      for (rowIndex, name) in rows.enumerated() {
        let rowY = table.maxY - 26 - CGFloat(rowIndex + 1) * 22 + 7
        write(name, at: CGPoint(x: table.minX + 10, y: rowY), size: 9, in: context)
        write(values[rowIndex], at: CGPoint(x: table.minX + 200, y: rowY), size: 9, grey: 0.25, in: context)
      }
      y = table.minY - 24
    }
  }

  write(
    "\(page + 1) / 10",
    at: CGPoint(x: size.width / 2, y: 40),
    size: 9,
    align: .centre,
    grey: 0.45,
    in: context
  )
}

// ─── Making them ─────────────────────────────────────────────────────────────

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sheetSize = CGSize(width: 26000, height: 1500)
pdf("\(folder)/sheet.pdf", size: sheetSize, pages: 1) { context, _ in
  drawSheet(context, sheetSize)
}

let pageSize = CGSize(width: 595, height: 842)
pdf("\(folder)/report.pdf", size: pageSize, pages: 10) { context, page in
  drawReport(context, page: page, size: pageSize)
}
