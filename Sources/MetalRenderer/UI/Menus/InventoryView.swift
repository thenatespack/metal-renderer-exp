import Cocoa

/// Full inventory display, toggled with I. Laid out as two cards side by
/// side: Materials (a 4x4 grid of hotbar slots) + Crafting Grid on the
/// left, Recipe Book on the right. Previously everything was stacked in one
/// long single-row-of-16 column, which read as cramped and didn't use the
/// window's width at all — this uses the same interaction model, just
/// organized into clearer, bounded panels.
///
/// Interaction:
///   - Drag a hotbar slot onto a grid cell to move one item into it.
///   - Click a filled grid cell (no drag) to return its contents to the hotbar.
///   - Click a recipe in the book to fill the grid with one batch of it, if affordable.
///   - Right-click a recipe to bulk-fill the grid with up to `bulkFillCap` batches at once.
///   - Click the result slot (appears once the grid matches a recipe) to craft one batch.
///   - Click (without dragging onto the grid) an inventory-only overflow slot
///     (below the divider in Materials) to equip it into the active hotbar
///     slot — those items aren't otherwise wieldable, since only the first
///     Hotbar.hotbarSlotCount slots respond to 1...9/0.
///
/// Full-bounds and hit-intercepting (no hitTest override, so it uses
/// NSView's default of capturing anything within its bounds) like
/// PauseMenuView, since it should block game input while open.
final class InventoryView: NSView, ControllerMenuNavigable {
    private let hotbar: Hotbar
    private let craftingGrid = CraftingGrid()

    private var slots: [HotbarSlot] = []
    private var selectedIndex = 0
    private var focusedRecipeIndex = 0

    private var hotbarSlotRects: [CGRect] = []
    private var gridCellRects: [CGRect] = []
    private var resultRect: CGRect = .zero
    private var recipeCellRects: [CGRect] = []

    private var dragSourceSlotIndex: Int?
    private var dragType: VoxelType?
    private var dragPoint: NSPoint = .zero

    private static let bulkFillCap = 4

    // Layout constants — see draw(_:) for how these compose into the two cards.
    // Materials columns matches Hotbar.hotbarSlotCount exactly, so the first
    // row is precisely the wieldable hotbar and any further rows are
    // inventory-only overflow — see the divider line in drawMaterialsAndCrafting.
    // Always drawn as a full materialsRows x materialsColumns grid (padded
    // with empty cells past however many slots actually exist), fitting
    // Hotbar.slotCount's 21 real slots with room to grow.
    private let materialsColumns = Hotbar.hotbarSlotCount
    private let materialsRows = 3
    private let slotSize: CGFloat = 40
    private let slotSpacing: CGFloat = 8
    // Vertical-only gap between Materials rows — wider than slotSpacing
    // (which stays tight for the horizontal gutters) because each filled
    // slot draws its item name in the space just below it; at slotSpacing's
    // width alone that label collided with the row beneath it.
    private let materialsRowSpacing: CGFloat = 22
    private let craftCellSize: CGFloat = 52
    private let craftCellSpacing: CGFloat = 10
    private let bookColumns = 4
    private let bookCellSize: CGFloat = 60
    private let bookCellSpacing: CGFloat = 14

    private let leftColumnWidth: CGFloat = 540
    private let rightColumnWidth: CGFloat = 360
    private let columnGap: CGFloat = 70
    private let leftPanelHeight: CGFloat = 520
    private let rightPanelHeight: CGFloat = 360
    private let panelCornerRadius: CGFloat = 10

    init(frame frameRect: NSRect, hotbar: Hotbar) {
        self.hotbar = hotbar
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(slots: [HotbarSlot], selectedIndex: Int) {
        self.slots = slots
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    // MARK: Mouse interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let index = recipeCellRects.firstIndex(where: { $0.contains(point) }) {
            fillGrid(with: CraftingRecipes.all[index], batches: 1)
            focusedRecipeIndex = index
            needsDisplay = true
            return
        }

        if resultRect.contains(point) {
            craftFromGrid()
            return
        }

        if let index = gridCellRects.firstIndex(where: { $0.contains(point) }), craftingGrid.cells[index].type != nil {
            returnGridCellToHotbar(index)
            return
        }

        if let index = hotbarSlotRects.firstIndex(where: { $0.contains(point) }), slots.indices.contains(index), let type = slots[index].type {
            dragSourceSlotIndex = index
            dragType = type
            dragPoint = point
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragSourceSlotIndex != nil else { return }
        dragPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragSourceSlotIndex = nil
            dragType = nil
            needsDisplay = true
        }
        guard let type = dragType, let sourceIndex = dragSourceSlotIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let targetIndex = gridCellRects.firstIndex(where: { $0.contains(point) }) {
            guard hotbar.remove(type, count: 1) > 0 else { return }
            guard craftingGrid.place(type, count: 1, at: targetIndex) else {
                // Target cell holds a different type — give the item back rather than losing it.
                hotbar.addItem(type)
                return
            }
            return
        }
        // Released outside the crafting grid: for an inventory-only overflow
        // slot (unreachable via 1...9/0), treat this as a click to equip —
        // swap it into the active hotbar slot instead of just canceling.
        // Hotbar-range slots are already wieldable, so this only matters for
        // overflow storage.
        if sourceIndex >= Hotbar.hotbarSlotCount {
            hotbar.swapIntoSelectedHotbarSlot(from: sourceIndex)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = recipeCellRects.firstIndex(where: { $0.contains(point) }) else { return }
        fillGrid(with: CraftingRecipes.all[index], batches: Self.bulkFillCap)
        focusedRecipeIndex = index
        needsDisplay = true
    }

    private func returnGridCellToHotbar(_ index: Int) {
        let cell = craftingGrid.clearCell(index)
        guard let type = cell.type, cell.count > 0 else { return }
        hotbar.addItems(type, count: cell.count)
        needsDisplay = true
    }

    /// Moves up to `batches` worth of a recipe's ingredients from the hotbar
    /// into the grid — capped by both what's actually affordable and
    /// bulkFillCap, so right-clicking in creative (infinite materials)
    /// doesn't try to stack an unbounded amount into 9 cells.
    private func fillGrid(with recipe: CraftingRecipe, batches: Int) {
        let affordable = recipe.ingredients.map { hotbar.count(of: $0.type) / $0.count }.min() ?? 0
        let actualBatches = min(batches, affordable, Self.bulkFillCap)
        guard actualBatches > 0 else { return }

        for ingredient in recipe.ingredients {
            let removed = hotbar.remove(ingredient.type, count: ingredient.count * actualBatches)
            craftingGrid.add(ingredient.type, count: removed)
        }
    }

    private func craftFromGrid() {
        guard let recipe = craftingGrid.matchingRecipe() else { return }
        craftingGrid.consume(recipe)
        hotbar.addItems(recipe.resultType, count: recipe.resultCount)
        needsDisplay = true
    }

    // MARK: ControllerMenuNavigable — D-pad moves the recipe-book focus in
    // both dimensions (clamped to the grid, not wrapping), Cross fills the
    // grid with one batch of the focused recipe (equivalent to a left
    // click). Bulk-fill and dragging currently need the mouse.

    func resetFocus() {
        focusedRecipeIndex = 0
        needsDisplay = true
    }

    func moveFocus(by delta: Int) {
        let newIndex = focusedRecipeIndex + delta * bookColumns
        guard CraftingRecipes.all.indices.contains(newIndex) else { return }
        focusedRecipeIndex = newIndex
        needsDisplay = true
    }

    func adjustFocused(by delta: Int) {
        let newIndex = focusedRecipeIndex + delta
        guard CraftingRecipes.all.indices.contains(newIndex),
              newIndex / bookColumns == focusedRecipeIndex / bookColumns else { return }
        focusedRecipeIndex = newIndex
        needsDisplay = true
    }

    func activateFocused() {
        fillGrid(with: CraftingRecipes.all[focusedRecipeIndex], batches: 1)
        needsDisplay = true
    }

    // MARK: Layout helpers

    /// `rowSpacing` defaults to the column `spacing` — pass a larger value
    /// for a grid whose cells draw something (like Materials' name labels)
    /// below them that needs more room than a tight column gutter gives.
    private func cellRect(index: Int, columns: Int, size: CGFloat, spacing: CGFloat, left: CGFloat, top: CGFloat, rowSpacing: CGFloat? = nil) -> CGRect {
        let row = index / columns
        let col = index % columns
        let x = left + CGFloat(col) * (size + spacing)
        let y = top - CGFloat(row + 1) * size - CGFloat(row) * (rowSpacing ?? spacing)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    private func gridWidth(columns: Int, size: CGFloat, spacing: CGFloat) -> CGFloat {
        CGFloat(columns) * size + CGFloat(columns - 1) * spacing
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !slots.isEmpty else { return }

        let contentWidth = leftColumnWidth + columnGap + rightColumnWidth
        let contentLeft = bounds.midX - contentWidth / 2
        let leftColumnX = contentLeft
        let rightColumnX = contentLeft + leftColumnWidth + columnGap
        let panelTop = bounds.midY + 220

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let title = "Inventory" as NSString
        title.draw(at: NSPoint(x: bounds.midX - title.size(withAttributes: titleAttrs).width / 2, y: panelTop + 40), withAttributes: titleAttrs)

        let leftPanelRect = CGRect(x: leftColumnX, y: panelTop - leftPanelHeight, width: leftColumnWidth, height: leftPanelHeight)
        let rightPanelRect = CGRect(x: rightColumnX, y: panelTop - rightPanelHeight, width: rightColumnWidth, height: rightPanelHeight)
        drawPanelBackground(leftPanelRect, context: context)
        drawPanelBackground(rightPanelRect, context: context)

        drawMaterialsAndCrafting(in: leftPanelRect, context: context)
        drawRecipeBook(in: rightPanelRect, context: context)

        drawFloatingDrag(context: context)

        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let hint = "I or Esc to close" as NSString
        let hintSize = hint.size(withAttributes: hintAttrs)
        hint.draw(at: NSPoint(x: bounds.midX - hintSize.width / 2, y: 20), withAttributes: hintAttrs)
    }

    private func drawPanelBackground(_ rect: CGRect, context: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: panelCornerRadius, cornerHeight: panelCornerRadius, transform: nil)
        context.setFillColor(NSColor(calibratedWhite: 0.1, alpha: 0.55).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
    }

    private func drawSectionHeader(_ text: String, x: CGFloat, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white]
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        return y - 26
    }

    private func drawMaterialsAndCrafting(in panel: CGRect, context: CGContext) {
        let padding: CGFloat = 18
        var cursorY = drawSectionHeader("Materials — top row is the hotbar (1\u{2013}9, 0)", x: panel.minX + padding, y: panel.maxY - padding - 16)

        // Always a full materialsRows x materialsColumns grid, padded out
        // with empty cells past however many slots actually exist — a
        // partial last row reads as a layout bug, not "you're just not
        // carrying that much yet."
        let totalCells = materialsRows * materialsColumns
        let materialsWidth = gridWidth(columns: materialsColumns, size: slotSize, spacing: slotSpacing)
        let materialsLeft = panel.minX + (panel.width - materialsWidth) / 2
        let materialsHeight = CGFloat(materialsRows) * (slotSize + materialsRowSpacing) - materialsRowSpacing

        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        hotbarSlotRects = Array(repeating: .zero, count: totalCells)
        for index in 0..<totalCells {
            let slot: HotbarSlot? = slots.indices.contains(index) ? slots[index] : nil
            let rect = cellRect(index: index, columns: materialsColumns, size: slotSize, spacing: slotSpacing, left: materialsLeft, top: cursorY, rowSpacing: materialsRowSpacing)
            hotbarSlotRects[index] = rect

            context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.fill(rect.insetBy(dx: -3, dy: -3))

            // While dragging, the source slot shows empty (the item follows the cursor instead).
            if let slot, let type = slot.type, index != dragSourceSlotIndex {
                fillSwatch(type, in: rect, context: context)
                let countText: String? = slot.count < 0 ? "\u{221E}" : (slot.count > 1 ? "\(slot.count)" : nil)
                if let countText {
                    drawCount(countText, in: rect, context: context)
                }
            }

            if index == selectedIndex {
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(3)
                context.stroke(rect.insetBy(dx: -3, dy: -3))
            }

            if let type = slot?.type {
                let labelText = type.displayName as NSString
                let labelSize = labelText.size(withAttributes: nameAttrs)
                if labelSize.width <= slotSize + 6 {
                    labelText.draw(at: NSPoint(x: rect.midX - labelSize.width / 2, y: rect.minY - 12), withAttributes: nameAttrs)
                }
            }
        }

        // A thin rule between the hotbar row and any inventory-only overflow
        // rows below it — materialsColumns == Hotbar.hotbarSlotCount, so the
        // hotbar always fills exactly the first row.
        if slots.count > Hotbar.hotbarSlotCount {
            let dividerY = cursorY - slotSize - materialsRowSpacing / 2
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: materialsLeft, y: dividerY))
            context.addLine(to: CGPoint(x: materialsLeft + materialsWidth, y: dividerY))
            context.strokePath()
        }

        cursorY -= materialsHeight + 34

        cursorY = drawSectionHeader("Crafting Grid — drag in, click to take back", x: panel.minX + padding, y: cursorY)

        let craftGridSize = gridWidth(columns: 3, size: craftCellSize, spacing: craftCellSpacing)
        let arrowGap: CGFloat = 34
        let rowWidth = craftGridSize + arrowGap + craftCellSize
        let rowLeft = panel.minX + (panel.width - rowWidth) / 2

        gridCellRects = Array(repeating: .zero, count: craftingGrid.cells.count)
        for (index, cell) in craftingGrid.cells.enumerated() {
            let rect = cellRect(index: index, columns: 3, size: craftCellSize, spacing: craftCellSpacing, left: rowLeft, top: cursorY)
            gridCellRects[index] = rect

            context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.fill(rect.insetBy(dx: -2, dy: -2))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(1)
            context.stroke(rect)

            if let type = cell.type {
                fillSwatch(type, in: rect, context: context)
                if cell.count > 1 {
                    drawCount("\(cell.count)", in: rect, context: context)
                }
            }
        }

        let arrowAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white.withAlphaComponent(0.8)]
        let arrow = "\u{2192}" as NSString
        let arrowX = rowLeft + craftGridSize + arrowGap / 2 - arrow.size(withAttributes: arrowAttrs).width / 2
        arrow.draw(at: NSPoint(x: arrowX, y: cursorY - craftGridSize / 2 - 9), withAttributes: arrowAttrs)

        let resultX = rowLeft + craftGridSize + arrowGap
        resultRect = CGRect(x: resultX, y: cursorY - craftGridSize / 2 - craftCellSize / 2, width: craftCellSize, height: craftCellSize)
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(resultRect.insetBy(dx: -3, dy: -3))
        if let recipe = craftingGrid.matchingRecipe() {
            fillSwatch(recipe.resultType, in: resultRect, context: context)
            drawCount("\(recipe.resultCount)", in: resultRect, context: context)
            context.setStrokeColor(NSColor(calibratedRed: 0.5, green: 0.95, blue: 0.5, alpha: 1).cgColor)
            context.setLineWidth(2)
            context.stroke(resultRect.insetBy(dx: -3, dy: -3))
        }
    }

    private func drawRecipeBook(in panel: CGRect, context: CGContext) {
        let padding: CGFloat = 18
        let cursorY = drawSectionHeader("Recipe Book — click to fill, right-click bulk", x: panel.minX + padding, y: panel.maxY - padding - 16)

        let recipes = CraftingRecipes.all
        let bookWidth = gridWidth(columns: bookColumns, size: bookCellSize, spacing: bookCellSpacing)
        let bookLeft = panel.minX + (panel.width - bookWidth) / 2
        let rows = Int(ceil(Double(recipes.count) / Double(bookColumns)))
        let bookHeight = CGFloat(rows) * bookCellSize + CGFloat(rows - 1) * bookCellSpacing

        recipeCellRects = Array(repeating: .zero, count: recipes.count)
        for (index, recipe) in recipes.enumerated() {
            let rect = cellRect(index: index, columns: bookColumns, size: bookCellSize, spacing: bookCellSpacing, left: bookLeft, top: cursorY)
            recipeCellRects[index] = rect

            let available = hotbar.hasIngredients(for: recipe)
            context.setFillColor(NSColor.black.withAlphaComponent(available ? 0.55 : 0.3).cgColor)
            context.fill(rect.insetBy(dx: -3, dy: -3))
            fillSwatch(recipe.resultType, in: rect, context: context, dimmed: !available)
            drawCount("x\(recipe.resultCount)", in: rect, context: context)

            if index == focusedRecipeIndex {
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(3)
                context.stroke(rect.insetBy(dx: -3, dy: -3))
            }
        }

        drawFocusedRecipeDetail(recipes[focusedRecipeIndex], panel: panel, below: cursorY - bookHeight - 14)
    }

    private func drawFocusedRecipeDetail(_ recipe: CraftingRecipe, panel: CGRect, below top: CGFloat) {
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let title = "\(recipe.resultType.displayName) x\(recipe.resultCount)" as NSString
        title.draw(at: NSPoint(x: panel.midX - title.size(withAttributes: nameAttrs).width / 2, y: top), withAttributes: nameAttrs)

        let ingredientsList = recipe.ingredients.map { "\($0.count) \($0.type.displayName)" }.joined(separator: " + ")
        let needsAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let needsText = "Needs: \(ingredientsList)" as NSString
        needsText.draw(at: NSPoint(x: panel.midX - needsText.size(withAttributes: needsAttrs).width / 2, y: top - 18), withAttributes: needsAttrs)
    }

    private func drawFloatingDrag(context: CGContext) {
        guard let type = dragType else { return }
        let size: CGFloat = 40
        let rect = CGRect(x: dragPoint.x - size / 2, y: dragPoint.y - size / 2, width: size, height: size)
        fillSwatch(type, in: rect, context: context)
    }

    private func fillSwatch(_ type: VoxelType, in rect: CGRect, context: CGContext, dimmed: Bool = false) {
        let c = type.color
        let alpha: CGFloat = dimmed ? 0.4 : 1
        context.setFillColor(NSColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.stroke(rect)
    }

    private func drawCount(_ text: String, in rect: CGRect, context: CGContext) {
        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let size = ns.size(withAttributes: attrs)
        ns.draw(at: NSPoint(x: rect.maxX - size.width - 2, y: rect.minY + 1), withAttributes: attrs)
    }
}
