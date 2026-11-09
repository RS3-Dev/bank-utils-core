-- Bank styles, images, and scrollbar controls.

local NativeUi = {}

NativeUi.PANEL_BACKGROUND_SPRITE = 8082
NativeUi.SCROLLBAR_WIDTH = 16

local SCROLLBAR_WIDTH = NativeUi.SCROLLBAR_WIDTH
local ARROW_HEIGHT = 12
local THUMB_WIDTH = 12
local THUMB_X = (SCROLLBAR_WIDTH - THUMB_WIDTH) // 2
local THUMB_CAP_HEIGHT = 6
local MIN_THUMB_HEIGHT = 18
local UP_SPRITE = 18436
local DOWN_SPRITE = 18437
local TRACK_SPRITE = 792
local THUMB_TOP_SPRITE = 18423
local THUMB_BOTTOM_SPRITE = 18424
local THUMB_MIDDLE_SPRITE = 18425
-- Draw decorations above clickable areas, with arrows on top.
local PART_ORDER = { "track", "trackSprite", "thumb", "thumbTop", "thumbMiddle", "thumbBottom",
    "upArrow", "downArrow" }

-- Use these style IDs if the game does not supply them.
local STYLE_FALLBACK_IDS = {
    RECT_BLACK = 269,
    BUTTON_PANEL = 318,
}

-- Use the game's style ID when available.
function NativeUi.styleID(styleName)
    return id.StyleSheet[styleName] or STYLE_FALLBACK_IDS[styleName]
end

local function scrollbarSprite(parent, spriteID, clickthrough)
    local sprite = ui.Sprite.new(parent)
    sprite.sprite = spriteID
    sprite.colour = Vector4.new(1.0, 1.0, 1.0, 1.0)
    sprite.clickthrough = clickthrough
    return sprite
end

-- An almost transparent rectangle still receives clicks.
local function inputRectangle(parent)
    local rectangle = ui.Rectangle.new(parent)
    rectangle.colour = Vector4.new(1.0, 1.0, 1.0, 0.01)
    rectangle.fill = true
    return rectangle
end

local function setBounds(part, x, y, width, height)
    part:SetPos(x, y)
    part:SetSize(width, height)
end

local Scrollbar = {}
Scrollbar.__index = Scrollbar

-- The caller removes the scrollbar if setup fails.
function NativeUi.createScrollbar(parent, options)
    local scrollbar = setmetatable({ height = options.height }, Scrollbar)
    scrollbar.upArrow = scrollbarSprite(parent, UP_SPRITE, false)
    scrollbar.downArrow = scrollbarSprite(parent, DOWN_SPRITE, false)
    scrollbar.track = inputRectangle(parent)
    scrollbar.track.stylesheetID = NativeUi.styleID("RECT_BLACK")
    scrollbar.trackSprite = scrollbarSprite(parent, TRACK_SPRITE, true)
    scrollbar.thumb = inputRectangle(parent)
    -- Decorations let clicks reach the draggable part of the scrollbar.
    scrollbar.thumbTop = scrollbarSprite(parent, THUMB_TOP_SPRITE, true)
    scrollbar.thumbMiddle = scrollbarSprite(parent, THUMB_MIDDLE_SPRITE, true)
    scrollbar.thumbBottom = scrollbarSprite(parent, THUMB_BOTTOM_SPRITE, true)

    scrollbar.upArrow:Subscribe(ui.Hook.ONCLICK, options.onUp)
    scrollbar.downArrow:Subscribe(ui.Hook.ONCLICK, options.onDown)
    scrollbar.track:Subscribe(ui.Hook.ONCLICK, options.onTrackClick)
    scrollbar.thumb:Subscribe(ui.Hook.ONCLICK, options.onThumbClick)
    scrollbar.thumb:Subscribe(ui.Hook.ONHOLD, options.onThumbHold)
    scrollbar.thumb:Subscribe(ui.Hook.ONRELEASE, options.onThumbRelease)
    scrollbar.thumb:Subscribe(ui.Hook.ONDRAGCOMPLETE, options.onThumbRelease)
    return scrollbar
end

function Scrollbar:TrackHeight()
    return math.max(1, self.height - ARROW_HEIGHT * 2)
end

-- Size the scrollbar handle to show how much of the page is visible.
function Scrollbar:ThumbHeight(contentHeight)
    if contentHeight <= self.height then return self:TrackHeight() end
    return math.max(MIN_THUMB_HEIGHT,
        math.floor(self.height / contentHeight * self:TrackHeight()))
end

function Scrollbar:ThumbTravel(contentHeight)
    return self:TrackHeight() - self:ThumbHeight(contentHeight)
end

local function thumbOffset(self, contentHeight, scrollY)
    local maxScrollY = contentHeight - self.height
    local travel = self:ThumbTravel(contentHeight)
    if maxScrollY <= 0 or travel <= 0 then return 0 end
    return math.floor(scrollY / maxScrollY * travel + 0.5)
end

-- Centre the scrollbar handle on the clicked position.
function Scrollbar:ScrollFromTrack(trackY, contentHeight)
    local maxScrollY = contentHeight - self.height
    local travel = self:ThumbTravel(contentHeight)
    if maxScrollY <= 0 or travel <= 0 then return 0 end
    local thumbY = trackY - math.floor(self:ThumbHeight(contentHeight) / 2)
    return math.max(0, math.min(travel, thumbY)) / travel * maxScrollY
end

-- Hide controls when content fits; keep the bank's scrollbar covered.
function Scrollbar:Refresh(contentHeight, scrollY)
    local hidden = contentHeight <= self.height
    local trackHeight = self:TrackHeight()
    local thumbHeight = self:ThumbHeight(contentHeight)
    local thumbY = ARROW_HEIGHT + thumbOffset(self, contentHeight, scrollY)
    local capHeight = math.min(THUMB_CAP_HEIGHT, math.floor(thumbHeight / 2))
    setBounds(self.upArrow, 0, 0, SCROLLBAR_WIDTH, ARROW_HEIGHT)
    setBounds(self.downArrow, 0, self.height - ARROW_HEIGHT, SCROLLBAR_WIDTH, ARROW_HEIGHT)
    setBounds(self.track, 0, ARROW_HEIGHT, SCROLLBAR_WIDTH, trackHeight)
    setBounds(self.trackSprite, 0, ARROW_HEIGHT, SCROLLBAR_WIDTH, trackHeight)
    setBounds(self.thumb, 0, thumbY, SCROLLBAR_WIDTH, thumbHeight)
    setBounds(self.thumbTop, THUMB_X, thumbY, THUMB_WIDTH, capHeight)
    setBounds(self.thumbMiddle, THUMB_X, thumbY + capHeight, THUMB_WIDTH,
        math.max(1, thumbHeight - capHeight * 2))
    setBounds(self.thumbBottom, THUMB_X, thumbY + thumbHeight - capHeight, THUMB_WIDTH, capHeight)
    for _, key in ipairs(PART_ORDER) do
        self[key].hidden = hidden
        self[key]:MoveToFront()
    end
end

return NativeUi
