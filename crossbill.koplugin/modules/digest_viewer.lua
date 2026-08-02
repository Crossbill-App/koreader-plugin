--[[
Digest Viewer Module for Crossbill Sync

A self-contained, scrollable dialog that renders a chapter digest (summary,
key points, questions) as rich HTML — so inline markdown (bold, italics, code)
shows up properly.

It is built on ScrollHtmlWidget, which has been stable for years (it powers the
dictionary popup), rather than TextViewer's markdown support, which only exists
on KOReader master and is absent from released versions.

The dialog structure mirrors the stable TextViewer: a TitleBar, a scrollable
body and a single-button ButtonTable, composed inside
FrameContainer/MovableContainer/WidgetContainer. It can be dismissed via the
Close button, by tapping outside the frame, or with the Back key.

Constructor options:
  title  string  Chapter title shown in the title bar
  html   string  Full body HTML to render
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen

-- Base font size for the HTML body (matches TextViewer's default text size).
local FONT_SIZE = Screen:scaleBySize(20)

-- CSS adapted from KOReader master's TextViewer HTML block, with extra rules
-- for the headings and lists we generate, tuned for e-ink readability.
local CSS = [[
	@page {
		margin: 0;
	}
	body {
		margin: 0;
		line-height: 1.3;
	}
	h2 {
		font-size: 1.1em;
		margin-top: 1em;
		margin-bottom: 0.3em;
	}
	ul, ol {
		margin: 0.3em 0;
		padding-left: 1.5em;
	}
	li {
		margin-bottom: 0.2em;
	}
]]

local DigestViewer = InputContainer:extend({
	title = nil,
	html = nil,
	width = nil,
	height = nil,
	close_callback = nil,
	-- Sizing constants copied from the stable TextViewer.
	text_padding = Size.padding.large,
	text_margin = Size.margin.small,
	button_padding = Size.padding.default,
})

function DigestViewer:init()
	local screen_w = Screen:getWidth()
	local screen_h = Screen:getHeight()

	self.align = "center"
	self.region = Geom:new({
		w = screen_w,
		h = screen_h,
	})
	self.width = self.width or screen_w - Screen:scaleBySize(30)
	self.height = self.height or screen_h - Screen:scaleBySize(30)

	if Device:hasKeys() then
		self.key_events.Close = { { Device.input.group.Back } }
	end

	if Device:isTouchDevice() then
		local range = Geom:new({
			w = screen_w,
			h = screen_h,
		})
		self.ges_events = {
			TapClose = {
				GestureRange:new({
					ges = "tap",
					range = range,
				}),
			},
			MultiSwipe = {
				GestureRange:new({
					ges = "multiswipe",
					range = range,
				}),
			},
		}
	end

	self.titlebar = TitleBar:new({
		width = self.width,
		align = "left",
		with_bottom_line = true,
		title = self.title,
		close_callback = function()
			self:onClose()
		end,
		show_parent = self,
	})

	self.button_table = ButtonTable:new({
		width = self.width - 2 * self.button_padding,
		buttons = {
			{
				{
					text = _("Close"),
					callback = function()
						self:onClose()
					end,
				},
			},
		},
		zero_sep = true,
		show_parent = self,
	})

	-- Body height = dialog height minus the title bar and button row, following
	-- the stable TextViewer's math exactly.
	local htmlw_height = self.height - self.titlebar:getHeight() - self.button_table:getSize().h
	self.scroll_widget = ScrollHtmlWidget:new({
		html_body = self.html,
		css = CSS,
		default_font_size = FONT_SIZE,
		width = self.width - 2 * self.text_padding - 2 * self.text_margin,
		height = htmlw_height - 2 * self.text_padding - 2 * self.text_margin,
		dialog = self,
	})
	self.htmlw = FrameContainer:new({
		padding = self.text_padding,
		margin = self.text_margin,
		bordersize = 0,
		self.scroll_widget,
	})

	self.frame = FrameContainer:new({
		radius = Size.radius.window,
		padding = 0,
		margin = 0,
		background = Blitbuffer.COLOR_WHITE,
		VerticalGroup:new({
			self.titlebar,
			CenterContainer:new({
				dimen = Geom:new({
					w = self.width,
					h = self.htmlw:getSize().h,
				}),
				self.htmlw,
			}),
			CenterContainer:new({
				dimen = Geom:new({
					w = self.width,
					h = self.button_table:getSize().h,
				}),
				self.button_table,
			}),
		}),
	})
	self.movable = MovableContainer:new({
		anchor = self.anchor,
		self.frame,
	})
	self[1] = WidgetContainer:new({
		align = self.align,
		dimen = self.region,
		self.movable,
	})
end

function DigestViewer:onCloseWidget()
	UIManager:setDirty(nil, function()
		return "partial", self.frame.dimen
	end)
end

function DigestViewer:onShow()
	UIManager:setDirty(self, function()
		return "partial", self.frame.dimen
	end)
	return true
end

function DigestViewer:onTapClose(arg, ges_ev)
	if ges_ev.pos:notIntersectWith(self.frame.dimen) then
		self:onClose()
	end
	return true
end

function DigestViewer:onMultiSwipe(arg, ges_ev)
	-- Any multiswipe closes, for consistency with other fullscreen widgets.
	self:onClose()
	return true
end

function DigestViewer:onClose()
	UIManager:close(self)
	if self.close_callback then
		self.close_callback()
	end
	return true
end

return DigestViewer
