--
-- BaleDirectDialog
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

---
BaleDirectDialog = {}

---
BaleDirectDialog.MODE = {
  BALES = 1,
  WINDROWS = 2,
}

local BaleDirectDialog_mt = Class(BaleDirectDialog, MessageDialog)

---
function BaleDirectDialog.show(farmlandId, fieldX, fieldZ, callback, target, sellText, configureText, backText)
  local dialog = BaleDirectDialog.INSTANCE

  if dialog ~= nil then
    dialog.preselectedFarmlandId = farmlandId
    dialog.preselectedFieldX = fieldX
    dialog.preselectedFieldZ = fieldZ

    dialog:setCallback(callback, target)
    dialog:setButtonTexts(sellText, configureText, backText)

    dialog.gui:showDialog("BaleDirectDialog")
  end

  return dialog
end

---Creates a new instance of BaleDirectDialog
function BaleDirectDialog.new(target, customMt, mission, gui, i18n)
  local self = MessageDialog.new(target, customMt or BaleDirectDialog_mt)

  self.gui = gui
  self.i18n = i18n
  self.mission = mission

  -- map and data
  self.currentBales = {}
  self.selectedBales = {}
  self.fillTypeItems = {}
  self.fillTypeLimits = {}
  self.fillTypeSellEnabled = {}

  -- overlay for bales
  self.baleOverlay = g_overlayManager:createOverlay("mapHotspots.other", 0, 0, 1, 1)

  -- mode
  self.mode = BaleDirectDialog.MODE.BALES

  -- field course for boundary detection
  self.openLoadToken = 0
  self.fieldCourseSettings = BaleDirect.createFieldCourseSettings()
  self.lineWidth = 2 / g_screenHeight

  -- delivery type
  self.deliveryType = BaleDirect.DELIVERY_EXPRESS

  return self
end

---
function BaleDirectDialog:onCreate()
  BaleDirectDialog:superClass().onCreate(self)

  self.defaultBackText = self.backButton.text
  self.defaultConfigureText = self.configureButton.text
  self.defaultSellText = self.sellButton.text
end

---
function BaleDirectDialog:onGuiSetupFinished()
  BaleDirectDialog:superClass().onGuiSetupFinished(self)

  -- set data source for fill type list
  self.fillTypeList:setDataSource(self)
  -- apply row colors
  self:applyRowColors()
  -- set subtitle text
  self.subtitleText:setText(string.format(self.i18n:getText("baleDirect_subtitle"), BaleDirect.PRICE_REDUCTION_PERCENT))

  -- update delivery option
  local mission = self.mission
  local baleDirect = mission and mission.baleDirect
  local paymentSystem = baleDirect and baleDirect.paymentSystem

  if paymentSystem ~= nil then
    local modifier = paymentSystem:getFeeModifier(BaleDirect.DELIVERY_STANDARD)
    local discountPercent = math.abs(math.round((1 - modifier) * 100))
    local deferredText = string.format(self.i18n:getText("baleDirect_deliveryDeferred"), discountPercent)

    self.deliveryOption:setTexts({ self.i18n:getText("baleDirect_deliveryExpress"), deferredText })
  end
end

---
function BaleDirectDialog:delete()
  if self.windrowOverlay ~= nil then
    delete(self.windrowOverlay)
    self.windrowOverlay = nil
  end

  BaleDirectDialog:superClass().delete(self)
end

---Called when dialog is opened
function BaleDirectDialog:onOpen()
  BaleDirectDialog:superClass().onOpen(self)

  self.isOpening = true

  -- frequently used refs
  local mission = self.mission
  local baleDirect = mission.baleDirect
  local ingameMap = mission.hud:getIngameMap()

  -- setup map immediately
  self.ingameMapElement.drawHotspots = false
  self.ingameMapElement:setIngameMap(ingameMap)
  self.ingameMapElement:onOpen()

  -- reset runtime state
  self:resetRuntimeState()

  self.modeOption:setState(self.mode)
  self:setModeControlsDisabled(true)
  self:updateExpectedPayoutBar()

  -- block interactions until initial load completes
  self:setButtonsDisabled(true, true)

  -- start async open loading
  self.openLoadToken = self.openLoadToken + 1
  local openLoadToken = self.openLoadToken
  self.openDataLoading = true
  self.fieldCourseLoading = false
  self:updateMapState()

  -- defer owned bale scan so the dialog can render its loading state first
  if g_asyncTaskManager ~= nil then
    g_asyncTaskManager:addTask(function()
      self:continueOpenWithBales(baleDirect:getAllOwnedBales(), openLoadToken)
    end, "BaleDirectDialog:loadOwnedBales")
  else
    self:continueOpenWithBales(baleDirect:getAllOwnedBales(), openLoadToken)
  end

  -- request latest pending sales from server
  if mission:getIsClient() and not mission:getIsServer() then
    g_client:getServerConnection():sendEvent(BaleDirectRequestSalesEvent.new())
  end

  self.isOpening = false
end

---Check whether interactions should be blocked
-- @param boolean includeOpening include opening phase in block state
-- @return boolean isBlocked true if interactions should be ignored
function BaleDirectDialog:isInteractionBlocked(includeOpening)
  local isBlocked = self.openDataLoading or self.fieldCourseLoading

  if includeOpening then
    isBlocked = isBlocked or self.isOpening
  end

  return isBlocked
end

---Enable or disable mode and delivery controls together
-- @param boolean isDisabled disabled state
function BaleDirectDialog:setModeControlsDisabled(isDisabled)
  self.modeOption:setDisabled(isDisabled)
  self.deliveryOption:setDisabled(isDisabled)
end

---Check whether selling is enabled for a fill type
-- @param integer fillType fill type index
-- @return boolean isEnabled true when selling is enabled
function BaleDirectDialog:getIsFillTypeSellEnabled(fillType)
  return self.fillTypeSellEnabled[fillType] ~= false
end

---Resolve fill type display data
-- @param integer fillType fill type index
-- @return string name display name
-- @return string iconFilename icon path or nil
function BaleDirectDialog:getFillTypeDisplay(fillType)
  local name = "Unknown"
  local iconFilename = nil

  if g_fillTypeManager ~= nil then
    local fillTypeObj = g_fillTypeManager:getFillTypeByIndex(fillType)

    if fillTypeObj ~= nil then
      if fillTypeObj.title ~= nil then
        name = fillTypeObj.title
      end

      iconFilename = fillTypeObj.hudOverlayFilename
    end
  end

  return name, iconFilename
end

---Get pending deferred payout summary for current farm
-- @return table summary expected payout summary
function BaleDirectDialog:getExpectedPayoutSummary()
  local mission = self.mission
  local baleDirect = mission.baleDirect

  -- get expected payout summary from bale direct
  return baleDirect.paymentSystem:getExpectedPayoutSummary(mission:getFarmId())
end

---Resolve localized month name by season period index.
-- @param number periodIndex season period index (1..12)
-- @return string monthText localized month name
function BaleDirectDialog:getMonthNameFromPeriod(periodIndex)
  local month = ((periodIndex or 1) + 1) % 12 + 1

  -- adjust month for southern hemisphere
  if self.mission.environment.daylight.latitude < 0 then
    month = (month + 5) % 12 + 1
  end

  return self.i18n:getText(string.format("ui_month%d", month))
end

---Update bottom payout info bar visibility and text.
function BaleDirectDialog:updateExpectedPayoutBar()
  if self.expectedPayoutText == nil then
    return
  end

  local summary = self:getExpectedPayoutSummary()
  -- hide expected payout text if no expected payout
  if summary == nil or (summary.count or 0) <= 0 then
    self.expectedPayoutText:setVisible(false)
    return
  end

  -- update expected payout text
  local monthText = self:getMonthNameFromPeriod(summary.nextPayoutPeriod)
  local payoutText = self.i18n:formatMoney(summary.totalNetProfit or 0, 0, true, true)
  local textPattern = self.i18n:getText("baleDirect_expectedBanner")

  -- set expected payout text
  self.expectedPayoutText:setText(string.format(textPattern, payoutText, monthText))
  self.expectedPayoutText:setVisible(true)
end

---Update financial summary texts using delivery-adjusted fees
-- @param number grossValue gross value
-- @param number totalFees base total fees
-- @param number dispatchFee dispatch component used in fee detail
-- @param number variableFeePer1000 per-1000L fee used in detail text
-- @return number adjustedNetProfit net profit after delivery modifier
function BaleDirectDialog:updateFinancialTexts(grossValue, totalFees, dispatchFee, variableFeePer1000)
  local feeModifier = self.mission.baleDirect.paymentSystem:getFeeModifier(self.deliveryType)
  local adjustedFees = totalFees * feeModifier
  local adjustedNetProfit = grossValue - adjustedFees
  local feeDetail = string.format("%d%% + %s + %s/1000L", BaleDirect.PRICE_REDUCTION_PERCENT, self.i18n:formatMoney(dispatchFee, 0, true, true), self.i18n:formatMoney(variableFeePer1000, 0, true, true))

  -- apply fee modifier to fee detail
  if feeModifier ~= 1.0 then
    feeDetail = string.format("(%s) ×%.0f%%", feeDetail, feeModifier * 100)
  end

  -- set financial summary texts
  self.grossValueText:setText(self.i18n:formatMoney(grossValue, 0, true, true))
  self.serviceFeeText:setText(string.format("%s (%s)", self.i18n:formatMoney(adjustedFees, 0, true, true), feeDetail))
  self.netProfitText:setText(self.i18n:formatMoney(adjustedNetProfit, 0, true, true))

  return adjustedNetProfit
end

---Apply windrow-mode state when no field is selected
function BaleDirectDialog:setNoFieldSelectedState()
  self.fillTypeItems = {}
  self.selectedBales = {}

  -- reload fill type list
  self.fillTypeList:reloadData()

  -- set summary texts
  self:setSummaryTexts("-", "-", "No field selected", "-")
  self:setButtonsDisabled(true, true)
end

---Check whether there is anything sellable in the current mode
-- @return boolean hasSellable true when sale action should be allowed
function BaleDirectDialog:hasSellableItems()
  if self.mode == BaleDirectDialog.MODE.WINDROWS then
    return next(self:getEnabledWindrows()) ~= nil
  end

  return #self.selectedBales > 0
end

---Build bale-mode fill type entries
-- @param table availablePerType map of fillType -> available count
-- @param table breakdown sale breakdown by fill type
-- @param number handlingCost handling fee per 1000L
function BaleDirectDialog:buildBaleModeFillTypeItems(availablePerType, breakdown, handlingCost)
  for fillType, count in pairs(availablePerType) do
    local itemDetails = self:getFillTypeItemDetails(fillType, breakdown[fillType])

    -- set fill type limits
    if self.fillTypeLimits[fillType] == nil then
      self.fillTypeLimits[fillType] = count
      itemDetails.soldCount = count
    end

    -- set fill type sell enabled
    if self.fillTypeSellEnabled[fillType] == nil then
      self.fillTypeSellEnabled[fillType] = true
    end

    -- insert fill type item
    table.insert(self.fillTypeItems, {
      fillType = fillType,
      name = itemDetails.name,
      iconFilename = itemDetails.iconFilename,
      totalCount = count,
      soldCount = itemDetails.soldCount,
      value = itemDetails.value,
      fee = (itemDetails.fillLevel / 1000) * handlingCost,
      isWindrow = false,
      sellEnabled = self.fillTypeSellEnabled[fillType]
    })
  end
end

---Build windrow-mode fill type entries
-- @param table breakdown windrow breakdown by fill type
-- @param number balingCost baling fee per 1000L
function BaleDirectDialog:buildWindrowModeFillTypeItems(breakdown, balingCost)
  for fillType, data in pairs(breakdown) do
    local itemDetails = self:getFillTypeItemDetails(fillType)

    -- insert fill type item
    table.insert(self.fillTypeItems, {
      fillType = fillType,
      name = itemDetails.name,
      iconFilename = itemDetails.iconFilename,
      totalCount = math.floor(data.liters),
      value = data.value,
      fee = (data.liters / 1000) * balingCost,
      isWindrow = true
    })
  end
end

---Reset sale limits and windrow caches for a new bale set
function BaleDirectDialog:resetSaleState()
  self.fillTypeLimits = {}
  self.fillTypeSellEnabled = {}
  self.currentWindrows = nil
  self.windrowsCacheCourse = nil
end

---Get windrows filtered by sell enabled state
-- @return table enabledWindrows map of fillType to liters for enabled types only
function BaleDirectDialog:getEnabledWindrows()
  local enabledWindrows = {}

  if self.currentWindrows == nil then
    return enabledWindrows
  end

  -- filter windrows by sell enabled state
  for fillType, liters in pairs(self.currentWindrows) do
    if self:getIsFillTypeSellEnabled(fillType) then
      enabledWindrows[fillType] = liters
    end
  end

  return enabledWindrows
end

---Build windrow sell-enabled map
-- @return table sellEnabledByFillType map fillType -> bool, or nil
function BaleDirectDialog:getWindrowSellEnabledByFillType()
  local sellEnabledByFillType = {}

  -- build windrow sell-enabled map from current windrows
  if self.currentWindrows ~= nil then
    for fillType, _ in pairs(self.currentWindrows) do
      sellEnabledByFillType[fillType] = self:getIsFillTypeSellEnabled(fillType)
    end
  end

  -- fallback to fill type items when no current windrows
  if next(sellEnabledByFillType) == nil and self.fillTypeItems ~= nil then
    for _, item in ipairs(self.fillTypeItems) do
      if item.isWindrow then
        sellEnabledByFillType[item.fillType] = self:getIsFillTypeSellEnabled(item.fillType)
      end
    end
  end

  if next(sellEnabledByFillType) == nil then
    return nil
  end

  return sellEnabledByFillType
end

---Build windrow overlay now or schedule async build
-- @param integer loadToken token captured for async safety
function BaleDirectDialog:scheduleWindrowOverlayBuild(loadToken)
  if self.mode ~= BaleDirectDialog.MODE.WINDROWS or self.fieldCourse == nil then
    return
  end

  local activeLoadToken = loadToken or self.openLoadToken
  self:createWindrowOverlay()

  if g_asyncTaskManager == nil then
    self:buildWindrowOverlay()
    return
  end

  if self.windrowOverlayBuildPending then
    return
  end

  self.windrowOverlayBuildPending = true
  self.windrowOverlayReady = false
  self.windrowOverlayReadyTime = nil

  g_asyncTaskManager:addTask(function()
    if self.openLoadToken ~= activeLoadToken then
      self.windrowOverlayBuildPending = false
      return
    end

    self.windrowOverlayBuildPending = false

    if self.mode == BaleDirectDialog.MODE.WINDROWS and self.fieldCourse ~= nil then
      self:buildWindrowOverlay()
    end
  end, "BaleDirectDialog:buildWindrowOverlay")
end

---Continue dialog initialization after async bale scan finishes.
-- @param table allOwnedBales loaded bales list
-- @param integer openLoadToken token captured at open time
function BaleDirectDialog:continueOpenWithBales(allOwnedBales, openLoadToken)
  if self.openLoadToken ~= openLoadToken then
    return
  end

  self.allOwnedBales = allOwnedBales or {}

  -- get position for field detection
  local fieldX, fieldZ = self.preselectedFieldX, self.preselectedFieldZ

  -- try to find a bale on the preselected farmland
  if fieldX == nil and self.preselectedFarmlandId ~= nil then
    for _, bale in ipairs(self.allOwnedBales) do
      if bale.farmlandId == self.preselectedFarmlandId then
        fieldX, fieldZ = bale.x, bale.z
        break
      end
    end
  end

  -- fallback to first bale
  if fieldX == nil and #self.allOwnedBales > 0 then
    fieldX, fieldZ = self.allOwnedBales[1].x, self.allOwnedBales[1].z
  end

  -- store field position for FieldCourse generation
  self.fieldX = fieldX
  self.fieldZ = fieldZ

  self.openDataLoading = false
  self:generateFieldCourse()
end

---Apply alternating row colors to settings containers
function BaleDirectDialog:applyRowColors()
  local containers = {
    self.grossValueText.parent,
    self.serviceFeeText.parent,
    self.netProfitText.parent
  }

  -- apply alternating row colors
  for i, container in ipairs(containers) do
    local isEven = (i % 2) == 0
    local color = BaleDirectDialog.COLOR.ALTERNATING[isEven]

    container:setImageColor(nil, unpack(color))
  end
end

---Create the windrow density map visualization overlay
function BaleDirectDialog:createWindrowOverlay()
  local overlayResolution = 1024

  if Utils ~= nil and Utils.getPerformanceClassId ~= nil then
    local profileClassId = Utils.getPerformanceClassId()

    if profileClassId >= GS_PROFILE_HIGH then
      overlayResolution = 2048
    end
  end

  -- remove existing overlay when resolution changed
  if self.windrowOverlay ~= nil and self.windrowOverlay ~= 0 then
    if self.windrowOverlayResolution == overlayResolution then
      return
    end

    delete(self.windrowOverlay)
    self.windrowOverlay = nil
  end

  -- create new overlay
  self.windrowOverlay = createDensityMapVisualizationOverlay("windrowState", overlayResolution, overlayResolution)
  self.windrowOverlayResolution = overlayResolution
  self.windrowOverlayReady = false
  self.windrowOverlayReadyTime = nil
end

---Build windrow overlay
-- Shows all windrows on the map. The map view zoom handles visual field filtering.
function BaleDirectDialog:buildWindrowOverlay()
  if self.windrowOverlay == nil then
    self:createWindrowOverlay()
  end

  if self.windrowOverlay == nil then
    return
  end

  -- reset overlay state
  self.windrowOverlayReady = false
  self.windrowOverlayReadyTime = nil

  -- get terrain detail height id
  local mission = self.mission
  local terrainDetailHeightId = mission.terrainDetailHeightId

  if terrainDetailHeightId == nil then
    return
  end

  resetDensityMapVisualizationOverlay(self.windrowOverlay)

  local numChannels = g_densityMapHeightManager.heightTypeNumChannels

  -- set color for each fill type
  for i, heightType in ipairs(g_densityMapHeightManager:getDensityMapHeightTypes()) do
    if g_fillTypeManager:getIsFillTypeInCategory(heightType.fillTypeIndex, "FORK") then
      local color = BaleDirect.getFillTypeColor(heightType.fillTypeIndex)

      setDensityMapVisualizationOverlayStateColor(self.windrowOverlay, terrainDetailHeightId, 0, 0, 0, numChannels, i, color[1], color[2], color[3])
    end
  end

  -- generate overlay
  generateDensityMapVisualizationOverlay(self.windrowOverlay)
end

---Generate FieldCourse to detect actual merged field boundary
function BaleDirectDialog:generateFieldCourse()
  if self.fieldX == nil or self.fieldZ == nil then
    self.currentBales = self:getCurrentFieldBales()
    self:resetSaleState()
    self:setModeControlsDisabled(false)
    self:updateBaleInfo()
    self:updateMapState()

    return
  end

  if self.fieldCourseLoading then
    return
  end

  -- show loading animation immediately
  self.fieldCourseLoading = true
  self:updateMapState()

  local loadToken = self.openLoadToken

  -- generate field course
  FieldCourse.generateUICourseByFieldPosition(self.fieldX, self.fieldZ, self.fieldCourseSettings, function(course)
    if self.openLoadToken ~= loadToken then
      return
    end

    self.fieldCourseLoading = false

    -- process resolved course
    self.fieldCourse = course
    self.currentBales = self:getCurrentFieldBales()

    self:resetSaleState()

    if self.fieldCourse ~= nil and #self.currentBales == 0 then
      local windrows = self:refreshWindrows(true)

      if windrows ~= nil and next(windrows) ~= nil then
        self.mode = BaleDirectDialog.MODE.WINDROWS
        self.modeOption:setState(self.mode)
      end
    end

    self:scheduleWindrowOverlayBuild(loadToken)

    self:setModeControlsDisabled(false)
    self:updateBaleInfo()
    self:updateMapState()
  end)
end

---Update bale information display
function BaleDirectDialog:updateBaleInfo()
  local baleDirect = self.mission.baleDirect
  local economySettings = baleDirect:getEconomySettings()
  local grossValue, totalFees, fees = 0, 0, { dispatch = 0 }
  local countText = "-"
  local canSell = false
  local canConfigure = false

  -- reset fill type items
  self.fillTypeItems = {}

  -- update bale info based on mode
  if self.mode == BaleDirectDialog.MODE.BALES then
    local breakdown, selectedBales
    grossValue, totalFees, _, breakdown, fees, selectedBales = baleDirect:calculateSaleValue(self.currentBales, self.fillTypeLimits)
    self.selectedBales = selectedBales

    local availablePerType = {}

    for _, bale in ipairs(self.currentBales) do
      availablePerType[bale.fillType] = (availablePerType[bale.fillType] or 0) + 1
    end

    self:buildBaleModeFillTypeItems(availablePerType, breakdown, economySettings.handlingCost)

    local totalSold = #selectedBales
    countText = string.format("%d / %d", totalSold, #self.currentBales)
    canSell = totalSold > 0
    canConfigure = #self.fillTypeItems > 0
  elseif self.fieldCourse == nil then
    self:setNoFieldSelectedState()
    self:updateExpectedPayoutBar()
    return
  else
    local windrows = self:refreshWindrows(false) or {}

    self.currentBales = {}

    local enabledWindrows = self:getEnabledWindrows()
    grossValue, totalFees, _, _, fees = baleDirect:calculateWindrowSale(enabledWindrows)

    local _, _, _, allBreakdown, _ = baleDirect:calculateWindrowSale(windrows)
    self:buildWindrowModeFillTypeItems(allBreakdown, economySettings.balingCost)

    countText = string.format("%d items", #self.fillTypeItems)
    canConfigure = #self.fillTypeItems > 0
  end

  -- sort and update fill type list
  self:sortFillTypeItems()
  self.fillTypeList:reloadData()
  self.baleCountText:setText(countText)

  -- update financial texts
  local feePerUnit = self.mode == BaleDirectDialog.MODE.WINDROWS and economySettings.balingCost or economySettings.handlingCost
  local adjustedProfit = self:updateFinancialTexts(grossValue, totalFees, fees.dispatch, feePerUnit)

  -- update sell button state
  if self.mode == BaleDirectDialog.MODE.WINDROWS then
    canSell = adjustedProfit > 0
  end

  -- update net profit text color
  self.netProfitText:setTextColor(unpack(adjustedProfit < 0 and BaleDirectDialog.COLOR.NET_PROFIT.NEGATIVE or BaleDirectDialog.COLOR.NET_PROFIT.POSITIVE))
  self:setButtonsDisabled(not canSell, not canConfigure)
  self:updateExpectedPayoutBar()
end

---Update map state - fit to field boundary if available
function BaleDirectDialog:updateMapState()
  if self.openDataLoading or self.fieldCourseLoading then
    self.loadingAnimation:setVisible(true)
    self.noBalesText:setVisible(false)
    self.windrowsFoundText:setVisible(false)
    self.ingameMapElement:setVisible(true)
    self.ingameMapElement:setMapAlpha(1)

    if self.fieldCourse == nil then
      self:centerMapOnActiveCamera()
    end

    return
  end

  -- not loading - hide animation
  self.loadingAnimation:setVisible(false)
  self.ingameMapElement:setVisible(true)

  -- fit to field boundary
  if self.fieldCourse ~= nil and self.fieldCourse.courseField ~= nil then
    local minX, maxX, minZ, maxZ = self.fieldCourse.courseField:getBoundingBox()

    self.ingameMapElement:fitToBoundary(minX, maxX, minZ, maxZ, 0.1)
    self.ingameMapElement:setMapAlpha(1)

    local showNoBales = self.mode == BaleDirectDialog.MODE.BALES and #self.currentBales == 0
    local showNoWindrows = self.mode == BaleDirectDialog.MODE.WINDROWS and #self.fillTypeItems == 0

    self.noBalesText:setVisible(showNoBales)
    self.windrowsFoundText:setVisible(showNoWindrows)
  elseif #self.currentBales > 0 then
    self:fitMapToBales()
    self.noBalesText:setVisible(false)
    self.windrowsFoundText:setVisible(false)
  else
    self:centerMapOnActiveCamera()
    self.ingameMapElement:setMapAlpha(0.5)
    self.noBalesText:setVisible(true)
    self.windrowsFoundText:setVisible(false)
  end
end

---Fit map view to bale positions (fallback when no field course)
function BaleDirectDialog:fitMapToBales()
  if #self.currentBales == 0 then
    return
  end

  local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge

  -- find bale bounding box
  for _, baleData in pairs(self.currentBales) do
    minX = math.min(minX, baleData.x)
    maxX = math.max(maxX, baleData.x)
    minZ = math.min(minZ, baleData.z)
    maxZ = math.max(maxZ, baleData.z)
  end

  -- fit to bale bounding box
  self.ingameMapElement:fitToBoundary(minX - 50, maxX + 50, minZ - 50, maxZ + 50, 0.1)
  self.ingameMapElement:setMapAlpha(1)
end

---Draw line on map
-- @param table ingameMap ingame map
-- @param number posX map position X
-- @param number posY map position Y
-- @param number sizeX map size X
-- @param number sizeZ map size Z
-- @param table positions list of {x, z} positions
-- @param table color RGBA color
function BaleDirectDialog:drawLineOnMap(ingameMap, posX, posY, sizeX, sizeZ, positions, color)
  for i = 1, #positions - 1 do
    local pos1 = positions[i]
    local pos2 = positions[i + 1]
    local x1, y1 = self:worldToMapScreenPosition(ingameMap, posX, posY, sizeX, sizeZ, pos1[1], pos1[2])
    local x2, y2 = self:worldToMapScreenPosition(ingameMap, posX, posY, sizeX, sizeZ, pos2[1], pos2[2])

    drawLine2D(x1, y1, x2, y2, self.lineWidth, color[1], color[2], color[3], color[4])
  end
end

---Draw bale positions and field boundary on map
-- @param table element gui element
-- @param table ingameMap ingame map
function BaleDirectDialog:onDrawPostIngameMapHotspots(element, ingameMap)
  local posX, posY = self.ingameMapElement:getMapPosition()
  local sizeX, sizeZ = self.ingameMapElement:getMapSize()

  if self.openDataLoading or self.fieldCourseLoading then
    return
  end

  -- draw field boundary
  if self.fieldCourse ~= nil and self.fieldCourse.courseField ~= nil then
    local boundaryLine = self.fieldCourse.courseField.fieldRootBoundary.boundaryLine

    if boundaryLine ~= nil then
      self:drawLineOnMap(ingameMap, posX, posY, sizeX, sizeZ, boundaryLine, BaleDirectDialog.COLOR.BOUNDARY)
    end
  end

  -- draw windrow density map overlay
  if self.mode == BaleDirectDialog.MODE.WINDROWS and self.fieldCourse ~= nil and self.windrowOverlay ~= nil and self.windrowOverlay ~= 0 then
    if not self.windrowOverlayReady and getIsDensityMapVisualizationOverlayReady(self.windrowOverlay) then
      self.windrowOverlayReady = true
      self.windrowOverlayReadyTime = g_time
    end

    if self.windrowOverlayReady and not self.windrowOverlayBuildPending and self.windrowOverlayReadyTime ~= nil and g_time - self.windrowOverlayReadyTime > 80 and self.fieldCourse.courseField ~= nil then
      local scale = ingameMap.mapExtensionScaleFactor
      local offsetX = ingameMap.mapExtensionOffsetX
      local offsetZ = ingameMap.mapExtensionOffsetZ

      -- terrain extent in screen space
      local terL = offsetX * sizeX + posX
      local terB = (1 - scale - offsetZ) * sizeZ + posY
      local terW = scale * sizeX
      local terH = scale * sizeZ

      -- field bounding box in screen space
      local fMinX, fMaxX, fMinZ, fMaxZ = self.fieldCourse.courseField:getBoundingBox()
      local fieldL, fieldT = self:worldToMapScreenPosition(ingameMap, posX, posY, sizeX, sizeZ, fMinX, fMinZ)
      local fieldR, fieldB = self:worldToMapScreenPosition(ingameMap, posX, posY, sizeX, sizeZ, fMaxX, fMaxZ)

      -- clip to map element and terrain boundaries
      local clipL = math.max(fieldL, posX, terL)
      local clipR = math.min(fieldR, posX + sizeX, terL + terW)
      local clipB = math.max(fieldB, posY, terB)
      local clipT = math.min(fieldT, posY + sizeZ, terB + terH)

      if clipR > clipL and clipT > clipB then
        local u0 = (clipL - terL) / terW
        local u1 = (clipR - terL) / terW
        local v0 = (clipB - terB) / terH
        local v1 = (clipT - terB) / terH

        setOverlayUVs(self.windrowOverlay, u0, v0, u0, v1, u1, v0, u1, v1)
        renderOverlay(self.windrowOverlay, clipL, clipB, clipR - clipL, clipT - clipB)
      end
    end
  end

  -- draw bale markers
  if self.currentBales == nil or #self.currentBales == 0 or self.baleOverlay == nil then
    return
  end

  local isBaleMode = self.mode == BaleDirectDialog.MODE.BALES
  local selectedSet = {}

  -- build lookup set for selected bales
  if isBaleMode then
    for _, bale in ipairs(self.selectedBales) do
      selectedSet[bale] = true
    end
  end

  local markerSizeX, markerSizeY = getNormalizedScreenValues(40, 40)

  for _, baleData in pairs(self.currentBales) do
    local shouldDraw = not baleData.isRect

    if shouldDraw and isBaleMode then
      shouldDraw = self:getIsFillTypeSellEnabled(baleData.fillType) and selectedSet[baleData] == true
    end

    if shouldDraw then
      local color = BaleDirect.getFillTypeColor(baleData.fillType)

      -- draw bale point
      local screenX, screenY = self:worldToMapScreenPosition(ingameMap, posX, posY, sizeX, sizeZ, baleData.x, baleData.z)

      self.baleOverlay:setPosition(screenX - markerSizeX * 0.5, screenY - markerSizeY * 0.5)
      self.baleOverlay:setDimension(markerSizeX, markerSizeY)
      self.baleOverlay:setColor(color[1], color[2], color[3], color[4])
      self.baleOverlay:render()
    end
  end
end

---Get number of items in section
-- @param table list list element
-- @param integer section section index
-- @return integer count number of items
function BaleDirectDialog:getNumberOfItemsInSection(list, section)
  return #self.fillTypeItems
end

---Populate cell for item in section
-- @param table list list element
-- @param integer section section index
-- @param integer index item index
-- @param table cell cell element
function BaleDirectDialog:populateCellForItemInSection(list, section, index, cell)
  local item = self.fillTypeItems[index]

  if item == nil then
    return
  end

  -- get cell elements
  local iconElement = cell:getAttribute("icon")
  local fillTypeNameElement = cell:getAttribute("fillTypeName")
  local quantityTextElement = cell:getAttribute("quantityText")
  local valueTextElement = cell:getAttribute("valueText")
  local feeTextElement = cell:getAttribute("feeText")

  -- icon
  if iconElement ~= nil then
    if item.iconFilename ~= nil then
      iconElement:setImageFilename(item.iconFilename)
      iconElement:setVisible(true)
    else
      iconElement:setVisible(false)
    end
  end

  -- name
  if fillTypeNameElement ~= nil then
    if item.isWindrow then
      fillTypeNameElement:setText(string.format("%s: %s L", item.name, self.i18n:formatNumber(item.totalCount, 0)))
    else
      fillTypeNameElement:setText(item.name)
    end
  end

  -- quantity text (replaces old slider)
  if quantityTextElement ~= nil then
    if item.isWindrow then
      quantityTextElement:setVisible(false)
    else
      quantityTextElement:setVisible(true)

      if item.sellEnabled then
        quantityTextElement:setText(string.format("%d / %d", item.soldCount, item.totalCount))
        quantityTextElement:setTextColor(unpack(BaleDirectDialog.COLOR.ITEM.ENABLED))
      else
        quantityTextElement:setText(self.i18n:getText("baleDirect_itemDisabled"))
        quantityTextElement:setTextColor(unpack(BaleDirectDialog.COLOR.ITEM.DISABLED))
      end
    end
  end

  local isWindrowSellEnabled = true

  if item.isWindrow then
    isWindrowSellEnabled = self:getIsFillTypeSellEnabled(item.fillType)
  end

  -- windrow info
  local virtualInfoTextElement = cell:getAttribute("virtualInfoText")
  if virtualInfoTextElement ~= nil then
    if item.isWindrow then
      virtualInfoTextElement:setVisible(true)

      if isWindrowSellEnabled then
        local baleCount = math.floor(item.totalCount / 5500)
        virtualInfoTextElement:setText(string.format(self.i18n:getText("baleDirect_virtualBaleInfo"), baleCount))
        virtualInfoTextElement:setTextColor(unpack(BaleDirectDialog.COLOR.ITEM.ENABLED))
      else
        virtualInfoTextElement:setText(self.i18n:getText("baleDirect_itemDisabled"))
        virtualInfoTextElement:setTextColor(unpack(BaleDirectDialog.COLOR.ITEM.DISABLED))
      end
    else
      virtualInfoTextElement:setVisible(false)
    end
  end

  -- values
  if valueTextElement ~= nil then
    local displayValue = item.value

    if item.isWindrow and not isWindrowSellEnabled then
      displayValue = 0
    end

    valueTextElement:setText(self.i18n:formatMoney(displayValue, 0, true, true))
  end

  -- fee
  if feeTextElement ~= nil then
    local displayFee = item.fee

    if item.isWindrow and not isWindrowSellEnabled then
      displayFee = 0
    end

    feeTextElement:setText(string.format("Fee: %s", self.i18n:formatMoney(displayFee, 0, true, true)))
  end
end

---Called when item dialog returns with updated values
-- @param boolean sellEnabled whether selling is enabled
-- @param integer soldCount number of bales to sell
function BaleDirectDialog:onItemDialogCallback(sellEnabled, soldCount)
  if self.selectedItemIndex == nil then
    return
  end

  if sellEnabled == nil then
    self.selectedItemIndex = nil
    return
  end

  local item = self.fillTypeItems[self.selectedItemIndex]

  if item == nil then
    return
  end

  self.fillTypeSellEnabled[item.fillType] = sellEnabled

  -- windrow items have no quantity slider
  if not item.isWindrow then
    self.fillTypeLimits[item.fillType] = soldCount
  end

  -- reset selected item and update bale info
  self.selectedItemIndex = nil
  self:updateBaleInfo()
end

---Open item config dialog for a given fill type index
-- @param integer index item index in fillTypeItems
function BaleDirectDialog:openItemDialogForIndex(index)
  local item = self.fillTypeItems[index]

  if item == nil then
    return
  end

  -- store selected item index
  self.selectedItemIndex = index

  -- show item dialog
  BaleDirectItemDialog.show(item, self:getIsFillTypeSellEnabled(item.fillType), self.onItemDialogCallback, self)
end

---Called when fill type item is clicked - opens item config dialog
-- @param table list list element
-- @param integer section section index
-- @param integer index item index
-- @param table element clicked element
function BaleDirectDialog:onClickFillTypeItem(list, section, index, element)
  self:openItemDialogForIndex(index)
end

---Called when configure button (Space) in button bar is clicked
-- Opens item config dialog for the currently selected list item
-- @param integer state button state
-- @param table element button element
function BaleDirectDialog:onClickConfigure(state, element)
  local index = self.fillTypeList:getSelectedIndexInSection()

  if index == nil or index <= 0 then
    return
  end

  self:openItemDialogForIndex(index)
end

---Called when sell button is clicked
-- @param integer state button state
-- @param table element button element
function BaleDirectDialog:onClickSell(state, element)
  if not self:hasSellableItems() then
    return
  end

  local confirmCallback = function(confirmed)
    if confirmed then
      self:executeSell()
    end
  end

  -- get confirmation text
  local confirmText = self.i18n:getText("baleDirect_sellConfirm")

  -- show confirmation dialog
  YesNoDialog.show(confirmCallback, nil, confirmText, self.i18n:getText("baleDirect_sell"))
end

---Execute the actual sale after confirmation
function BaleDirectDialog:executeSell()
  local mission = self.mission

  local farmId = mission:getFarmId()
  local deliveryType = self.deliveryType or BaleDirect.DELIVERY_EXPRESS
  local isServer = mission:getIsServer()

  local success = false
  local netProfit = 0

  -- handle windrow mode
  if self.mode == BaleDirectDialog.MODE.WINDROWS then
    if self.fieldX ~= nil and self.fieldZ ~= nil then
      local sellEnabledByFillType = self:getWindrowSellEnabledByFillType()

      if isServer then
        mission.baleDirect:executeWindrowSaleAtPosition(farmId, self.fieldX, self.fieldZ, deliveryType, sellEnabledByFillType)
      else
        g_client:getServerConnection():sendEvent(BaleDirectWindrowSellEvent.new(farmId, deliveryType, self.fieldX, self.fieldZ, sellEnabledByFillType))
      end

      success = true
    end
  elseif isServer then
    success, netProfit = mission.baleDirect:executeSale(farmId, self.fillTypeLimits, self.currentBales, deliveryType)
  else
    g_client:getServerConnection():sendEvent(BaleDirectSellEvent.new(farmId, deliveryType, self.fillTypeLimits))
    success = true
  end

  -- show money change for express delivery
  if isServer and success and deliveryType == BaleDirect.DELIVERY_EXPRESS then
    mission:showMoneyChange(MoneyType.SOLD_BALES, nil, true)
  end

  -- send callback with success and net profit
  self:sendCallback(success, netProfit)
end

---Center map on active camera position
function BaleDirectDialog:centerMapOnActiveCamera()
  local x, _, z = getWorldTranslation(g_cameraManager:getActiveCamera())

  self.ingameMapElement:setCenterToWorldPosition(x, z)
  self.ingameMapElement:setMapZoom(10)
end

---Convert world position to map screen coordinates
function BaleDirectDialog:worldToMapScreenPosition(ingameMap, posX, posY, sizeX, sizeZ, worldX, worldZ)
  local normalizedX = (worldX + ingameMap.worldCenterOffsetX) / ingameMap.worldSizeX * ingameMap.mapExtensionScaleFactor + ingameMap.mapExtensionOffsetX
  local normalizedY = 1 - ((worldZ + ingameMap.worldCenterOffsetZ) / ingameMap.worldSizeZ * ingameMap.mapExtensionScaleFactor + ingameMap.mapExtensionOffsetZ)

  return normalizedX * sizeX + posX, normalizedY * sizeZ + posY
end

---Sort fill type items by display name
function BaleDirectDialog:sortFillTypeItems()
  table.sort(self.fillTypeItems, function(a, b)
    return a.name < b.name
  end)
end

---Reset runtime state
function BaleDirectDialog:resetRuntimeState()
  self.allOwnedBales = {}
  self.currentBales = {}
  self.selectedBales = {}
  self.fillTypeItems = {}
  self.selectedItemIndex = nil
  self.mode = BaleDirectDialog.MODE.BALES
  self:resetSaleState()
end

---Set buttons disabled
-- @param boolean isSellDisabled disable sell button
-- @param boolean isConfigureDisabled disable configure button
function BaleDirectDialog:setButtonsDisabled(isSellDisabled, isConfigureDisabled)
  self.sellButton:setDisabled(isSellDisabled)
  self.configureButton:setDisabled(isConfigureDisabled)
end

---Set summary texts
-- @param string baleCountText bale count text
-- @param string grossValueText gross value text
-- @param string serviceFeeText service fee text
-- @param string netProfitText net profit text
function BaleDirectDialog:setSummaryTexts(baleCountText, grossValueText, serviceFeeText, netProfitText)
  self.baleCountText:setText(baleCountText)
  self.grossValueText:setText(grossValueText)
  self.serviceFeeText:setText(serviceFeeText)
  self.netProfitText:setText(netProfitText)
end

---Get current field bales
-- @return table current field bales
function BaleDirectDialog:getCurrentFieldBales()
  if self.fieldCourse ~= nil then
    return self.mission.baleDirect:filterBalesInField(self.allOwnedBales, self.fieldCourse)
  end

  return self.allOwnedBales
end

---Refresh windrows
-- @param boolean forceRefresh force refresh
function BaleDirectDialog:refreshWindrows(forceRefresh)
  if self.fieldCourse == nil then
    self.currentWindrows = nil
    self.windrowsCacheCourse = nil

    return nil
  end

  -- refresh windrows if needed
  if forceRefresh or self.currentWindrows == nil or self.windrowsCacheCourse ~= self.fieldCourse then
    self.currentWindrows = self.mission.baleDirect:scanWindrowsInFieldCourse(self.fieldCourse)
    self.windrowsCacheCourse = self.fieldCourse
  end

  return self.currentWindrows
end

---Get fill type item details
-- @param integer fillType fill type
-- @param table breakdownData breakdown data
-- @return table fill type item details
function BaleDirectDialog:getFillTypeItemDetails(fillType, breakdownData)
  local name, iconFilename = self:getFillTypeDisplay(fillType)

  return {
    name = name,
    iconFilename = iconFilename,
    soldCount = breakdownData and breakdownData.count or 0,
    value = breakdownData and breakdownData.value or 0,
    fillLevel = breakdownData and breakdownData.fillLevel or 0,
  }
end

---Called when mode option changes
-- @param integer state option state
function BaleDirectDialog:onClickModeOption(state)
  if self:isInteractionBlocked(false) then
    return
  end

  self.mode = state

  -- update bale data based on mode
  if self.mode == BaleDirectDialog.MODE.BALES then
    self.currentBales = self:getCurrentFieldBales()
  else
    self.currentBales = {}
    self:refreshWindrows(false)
    self:scheduleWindrowOverlayBuild(self.openLoadToken)
  end

  -- update bale info and map state
  self:updateBaleInfo()
  self:updateMapState()
end

---Called when delivery type option changes
-- @param integer state option state (1=Express, 2=Standard)
function BaleDirectDialog:onClickDeliveryOption(state)
  local isBlocked = self:isInteractionBlocked(true)

  if not isBlocked then
    self.deliveryType = state == 1 and BaleDirect.DELIVERY_EXPRESS or BaleDirect.DELIVERY_STANDARD

    self:updateBaleInfo()
  end
end

---Set callback function
-- @param function callbackFunc callback
-- @param table target callback target
function BaleDirectDialog:setCallback(callbackFunc, target)
  self.callbackFunc = callbackFunc
  self.target = target
end

---Set button texts
-- @param string sellText Sell button text
-- @param string configureText Configure button text
-- @param string backText Back button text
function BaleDirectDialog:setButtonTexts(sellText, configureText, backText)
  self.sellButton:setText(Utils.getNoNil(sellText, self.defaultSellText))
  self.configureButton:setText(Utils.getNoNil(configureText, self.defaultConfigureText))
  self.backButton:setText(Utils.getNoNil(backText, self.defaultBackText))
end

---Send callback and close dialog
-- @param boolean|nil success sale was successful
-- @param number|nil amount amount sold for
function BaleDirectDialog:sendCallback(success, amount)
  self:close()

  if self.callbackFunc ~= nil then
    if self.target ~= nil then
      self.callbackFunc(self.target, success, amount)
      return
    end

    self.callbackFunc(success, amount)
  end
end

---Called when back button is clicked
-- @param boolean forceBack force back
-- @param boolean usedMenuButton used menu button
function BaleDirectDialog:onClickBack(forceBack, usedMenuButton)
  self:sendCallback(false, 0)
  return false
end

---Called when dialog is closed
function BaleDirectDialog:onClose()
  BaleDirectDialog:superClass().onClose(self)

  -- close map element
  self.ingameMapElement:onClose()

  -- reset open state
  self.openLoadToken = self.openLoadToken + 1
  self.openDataLoading = false
  self.fieldCourse = nil
  self.fieldCourseLoading = false

  -- delete windrow overlay to release density map references
  if self.windrowOverlay ~= nil then
    delete(self.windrowOverlay)
    self.windrowOverlay = nil
  end

  self.windrowOverlayResolution = nil
  self.windrowOverlayReady = false
  self.windrowOverlayBuildPending = false
  self.windrowOverlayReadyTime = nil

  -- reset runtime state
  self:resetRuntimeState()
end

---
BaleDirectDialog.COLOR = {
  ALTERNATING = {
    [true] = { 0.04231, 0.04231, 0.04231, 1 },
    [false] = { 0.04231, 0.04231, 0.04231, 0.5 },
  },
  BOUNDARY = { 0.0273, 0.0612, 0.3324, 1 },
  NET_PROFIT = {
    NEGATIVE = { 0.8069, 0.0097, 0.0097, 1 },
    POSITIVE = { 0.22323, 0.40724, 0.00368, 1 },
  },
  ITEM = {
    ENABLED = { 1, 1, 1, 1 },
    DISABLED = { 0.8, 0.3, 0.3, 1 },
  },
}
