-- Shared colours for the bank sidebar, header, and pages

local Theme = {}

-- Gold section, label, and folder headings, and the line beneath them
Theme.HEADING_TEXT = 0xE7C878FF
Theme.HEADING_LINE = 0x756C60FF

-- Panel frames and the warmer frame around scroll areas
Theme.FRAME = 0x635842FF
Theme.INNER_FRAME = 0x806432FF

-- Background of the bank item area
Theme.VIEW_BACKGROUND = 0x332E29FF

-- Gold outline around the selected row or item
Theme.SELECTED_BORDER = 0xD2A84DFF

-- Alternating list rows and their hover and selected fills
Theme.ROW_ODD = 0x211E1BFF
Theme.ROW_EVEN = 0x2A2622FF
Theme.ROW_HOVER = 0x403728FF
Theme.ROW_SELECTED = 0x49371FFF
Theme.ROW_TEXT = 0xE7D7B0FF

return Theme
