--
-- BaleDirectItemDialog
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

---
BaleDirectItemDialog = {}

local BaleDirectItemDialog_mt = Class(BaleDirectItemDialog, MessageDialog)

---
function BaleDirectItemDialog.show(itemData, sellEnabled, callback, target, okText, backText)
  local dialog = BaleDirectItemDialog.INSTANCE

  if dialog ~= nil then
    dialog.itemData = itemData
    dialog.isWindrow = itemData.isWindrow == true
    dialog.sellEnabled = sellEnabled ~= false
    dialog.soldCount = itemData.soldCount or itemData.totalCount

    dialog:setCallback(callback, target)
    dialog:setButtonTexts(okText, backText)

    dialog.gui:showDialog("BaleDirectItemDialog")
  end
end

---Creates a new instance of BaleDirectItemDialog
function BaleDirectItemDialog.new(target, customMt, mission, gui, i18n)
  local self = MessageDialog.new(target, customMt or BaleDirectItemDialog_mt)

  self.mission = mission
  self.gui = gui
  self.i18n = i18n

  -- state
  self.itemData = nil
  self.sellEnabled = true
  self.soldCount = 0

  self.callbackFunc = nil
  self.callbackTarget = nil

  return self
end

---
function BaleDirectItemDialog:onCreate()
  BaleDirectItemDialog:superClass().onCreate(self)

  self.defaultBackText = self.backButton.text
  self.defaultOkText = self.okButton.text
end

---
function BaleDirectItemDialog:onGuiSetupFinished()
  BaleDirectItemDialog:superClass().onGuiSetupFinished(self)

  -- set alternating colors for settings box elements
  for i, element in ipairs(self.settingsBox.elements) do
    local color = BaleDirectItemDialog.COLOR.ALTERNATING[i % 2 == 0]

    if color ~= nil then
      element:setImageColor(nil, unpack(color))
    end
  end
end

---
function BaleDirectItemDialog:delete()
  BaleDirectItemDialog:superClass().delete(self)
end

---Called when dialog is opened
function BaleDirectItemDialog:onOpen()
  BaleDirectItemDialog:superClass().onOpen(self)

  -- set title
  local fillTypeTitle = "Unknown"
  if g_fillTypeManager ~= nil then
    local fillTypeObj = g_fillTypeManager:getFillTypeByIndex(self.itemData.fillType)

    if fillTypeObj ~= nil and fillTypeObj.title ~= nil then
      fillTypeTitle = fillTypeObj.title
    end
  end

  self.dialogTitleText:setText(fillTypeTitle)

  -- set icon
  local hasIcon = self.itemData.iconFilename ~= nil
  if hasIcon then
    self.fillTypeIcon:setImageFilename(self.itemData.iconFilename)
  end

  self.fillTypeIcon:setVisible(hasIcon)

  -- set binary option
  self.sellEnabledOption:setIsChecked(self.sellEnabled == true, true)

  -- hide quantity slider for windrow items
  local showSlider = not self.isWindrow
  self.quantitySlider.parent:setVisible(showSlider)

  -- set quantity slider
  if showSlider then
    self:updateQuantitySlider()
  end

  -- update summary text
  self:updateSummary()
end

---Update the quantity slider state and texts
function BaleDirectItemDialog:updateQuantitySlider()
  local quantitySlider = self.quantitySlider

  local totalCount = self:getResolvedTotalCount()
  local texts = {}

  for i = 0, totalCount do
    texts[#texts + 1] = tostring(i)
  end

  quantitySlider:setTexts(texts)

  local clampedCount = math.min(math.max(self.soldCount or 0, 0), totalCount)
  local isSellEnabled = self.sellEnabled

  self.soldCount = clampedCount

  if isSellEnabled then
    quantitySlider:setState(clampedCount + 1)
    quantitySlider:setDisabled(false)
  else
    quantitySlider:setState(1)
    quantitySlider:setDisabled(true)
  end
end

---Update the summary text display
function BaleDirectItemDialog:updateSummary()
  local summaryText = self.summaryText

  if self.sellEnabled then
    if self.isWindrow then
      local totalCount = self:getResolvedTotalCount()
      summaryText:setText(string.format("%d L", totalCount))
    else
      local totalCount = self:getResolvedTotalCount()
      summaryText:setText(string.format("%d / %d", self.soldCount, totalCount))
    end

    summaryText:setTextColor(unpack(BaleDirectItemDialog.COLOR.SUMMARY.ENABLED))
  else
    summaryText:setText(self.i18n:getText("baleDirect_itemDisabled"))
    summaryText:setTextColor(unpack(BaleDirectItemDialog.COLOR.SUMMARY.DISABLED))
  end
end

---Called when sell enabled binary option changes
-- @param integer state option state (1=left/off, 2=right/on)
-- @param table element option element
function BaleDirectItemDialog:onClickSellEnabled(state, element)
  self.sellEnabled = element:getIsChecked()

  if not self.isWindrow then
    if self.sellEnabled then
      -- restore previous count or set to total
      if self.soldCount == 0 then
        self.soldCount = self:getResolvedTotalCount()
      end
    end

    -- update quantity slider
    self:updateQuantitySlider()
  end

  -- update summary
  self:updateSummary()
end

---Called when quantity slider value changes
-- @param integer state new slider state
-- @param table element slider element
function BaleDirectItemDialog:onClickQuantitySlider(state, element)
  if self.sellEnabled then
    local sliderState = state or 1

    self.soldCount = math.max(sliderState - 1, 0)
    self:updateSummary()
  end
end

---Resolve total item count for current payload
-- @return integer totalCount normalized count (>= 0)
function BaleDirectItemDialog:getResolvedTotalCount()
  local itemData = self.itemData

  -- default to 0 if not set
  local totalCount = 0

  -- get total count from item data
  if itemData ~= nil and itemData.totalCount ~= nil then
    totalCount = math.max(math.floor(itemData.totalCount), 0)
  end

  return totalCount
end

---Set callback function
-- @param function callbackFunc callback
-- @param table target callback target
function BaleDirectItemDialog:setCallback(callbackFunc, target)
  self.callbackFunc = callbackFunc
  self.callbackTarget = target
end

---Send callback
-- @param boolean|nil sellEnabled sell enabled state
-- @param integer|nil soldCount sold count
function BaleDirectItemDialog:sendCallback(sellEnabled, soldCount)
  self:close()

  if self.callbackFunc ~= nil then
    if self.callbackTarget ~= nil then
      self.callbackFunc(self.callbackTarget, sellEnabled, soldCount)
      return
    end

    self.callbackFunc(sellEnabled, soldCount)
  end
end

---Called when OK button is clicked
-- @param integer state button state
-- @param table element button element
function BaleDirectItemDialog:onClickOk(state, element)
  local finalSellEnabled = self.sellEnabled == true
  local finalSoldCount = finalSellEnabled and self.soldCount or 0

  self:sendCallback(finalSellEnabled, finalSoldCount)
end

---Set button texts
-- @param string okText OK button text
-- @param string backText Back button text
function BaleDirectItemDialog:setButtonTexts(okText, backText)
  self.okButton:setText(Utils.getNoNil(okText, self.defaultOkText))
  self.backButton:setText(Utils.getNoNil(backText, self.defaultBackText))
end

---Called when back button is clicked
-- @param boolean forceBack force back
-- @param boolean usedMenuButton used menu button
function BaleDirectItemDialog:onClickBack(forceBack, usedMenuButton)
  self:sendCallback(nil)
  return false
end

---Called when dialog is closed
function BaleDirectItemDialog:onClose()
  BaleDirectItemDialog:superClass().onClose(self)
end

---
BaleDirectItemDialog.COLOR = {
  ALTERNATING = {
    [true] = { 0.02956, 0.02956, 0.02956, 0.6 },
    [false] = { 0.02956, 0.02956, 0.02956, 0.2 },
  },
  SUMMARY = {
    ENABLED = { 1, 1, 1, 1 },
    DISABLED = { 0.8, 0.3, 0.3, 1 },
  },
}
