--
-- BaleDirect
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

---
BaleDirect = {
  DELIVERY_EXPRESS = 1,
  DELIVERY_STANDARD = 2
}

-- economy values
BaleDirect.PRICE_REDUCTION_PERCENT = 15
BaleDirect.BASE_DISPATCH_FEE = 200
BaleDirect.BASE_HANDLING_COST = 5
BaleDirect.BASE_BALING_DISPATCH = 400
BaleDirect.BASE_BALING_COST = 12

-- scanning constants
BaleDirect.MIN_WINDROW_TOTAL_LITERS = 100

local BaleDirect_mt = Class(BaleDirect)

---Creates a new instance of BaleDirect
function BaleDirect.new(modName, modDirectory, mission, i18n, gui)
  local self = setmetatable({}, BaleDirect_mt)

  self.modName = modName
  self.modDirectory = modDirectory
  self.mission = mission
  self.i18n = i18n
  self.gui = gui

  self.isServer = mission:getIsServer()
  self.isClient = mission:getIsClient()

  -- context actions
  self.contextActionIndex = nil
  self.lastHotspotX = nil
  self.lastHotspotZ = nil

  -- payment system
  self.paymentSystem = BaleDirectPaymentSystem.new(mission)

  -- gui manager
  if self.isClient then
    self.guiManager = BaleDirectGui.new(nil, modDirectory, mission, gui, i18n)
  end

  return self
end

---Called when the mission is loaded
-- @param mission table the loaded mission
function BaleDirect:onMissionLoaded(mission)
  self.paymentSystem:init()

  -- load server data
  if self.isServer then
    self.paymentSystem:loadFromFile()
  end

  -- register dialog
  if self.isClient then
    self.guiManager:init()
  end
end

---Called on delete
function BaleDirect:delete()
  -- clear payment system
  if self.paymentSystem ~= nil then
    self.paymentSystem:delete()
    self.paymentSystem = nil
  end

  -- clear gui manager
  if self.isClient then
    self.guiManager:delete()
    self.guiManager = nil
  end

  -- clear caches
  self.modifiersCache = nil
  self.windrowFillTypes = nil
end

---Save pending sales to file
function BaleDirect:saveToFile()
  if self.paymentSystem ~= nil then
    self.paymentSystem:saveToFile()
  end
end

---Get difficulty-scaled economy values
-- @return table economy scaled fee values
function BaleDirect:getEconomySettings()
  local costMultiplier = EconomyManager.getCostMultiplier()

  return {
    dispatchFee = MathUtil.round(self.BASE_DISPATCH_FEE * costMultiplier, 0),
    handlingCost = MathUtil.round(self.BASE_HANDLING_COST * costMultiplier, 0),
    balingDispatch = MathUtil.round(self.BASE_BALING_DISPATCH * costMultiplier, 0),
    balingCost = MathUtil.round(self.BASE_BALING_COST * costMultiplier, 0)
  }
end

---Find best selling station for fill type
-- @param fillTypeIndex integer fill type index
-- @return table sellingStation best station or nil
-- @return number price price per liter
function BaleDirect:getBestSellingStation(fillTypeIndex)
  local storageSystem = self.mission ~= nil and self.mission.storageSystem

  local bestStation = nil
  local bestPrice = 0

  -- find best selling station
  if storageSystem ~= nil then
    for _, sellingStation in pairs(storageSystem:getUnloadingStations()) do
      local canSellFillType = sellingStation.owningPlaceable ~= nil and sellingStation.acceptedFillTypes ~= nil and sellingStation.acceptedFillTypes[fillTypeIndex]

      -- check if selling station can sell fill type
      if canSellFillType then
        local price = sellingStation:getEffectiveFillTypePrice(fillTypeIndex)

        if price > bestPrice then
          bestPrice = price
          bestStation = sellingStation
        end
      end
    end
  end

  return bestStation, bestPrice
end

---Resolve owner farm id for a bale-like object
-- @param table object bale object
-- @return integer|nil ownerFarmId owner farm id
function BaleDirect.getObjectOwnerFarmId(object)
  if object == nil then
    return nil
  end

  if object.getOwnerFarmId ~= nil then
    local ok, ownerFarmId = pcall(function()
      return object:getOwnerFarmId()
    end)

    if ok then
      return ownerFarmId
    end
  end

  return object.ownerFarmId
end

---Check whether a farm may use BaleDirect sale actions
-- @param farmId integer target farm id
-- @param table connection optional client connection
-- @return boolean hasPermission true when sale actions are allowed
function BaleDirect:hasSalePermission(farmId, connection)
  local mission = self.mission
  local farmManager = g_farmManager

  if mission == nil or farmManager == nil or type(farmId) ~= "number" then
    return false
  end

  local resolvedFarmId = math.floor(farmId)

  if resolvedFarmId <= 0 or farmManager:getFarmById(resolvedFarmId) == nil then
    return false
  end

  if connection ~= nil and not mission:getHasPlayerPermission("sellVehicle", connection, resolvedFarmId) then
    return false
  end

  return true
end

---Check whether a farm may access the selected field position
-- @param farmId integer active farm id
-- @param fieldX number world X
-- @param fieldZ number world Z
-- @return boolean hasAccess true when the field position is accessible
function BaleDirect:canAccessFieldPosition(farmId, fieldX, fieldZ)
  local mission = self.mission
  local farmlandManager = g_farmlandManager

  if mission == nil or farmlandManager == nil or type(farmId) ~= "number" or fieldX == nil or fieldZ == nil then
    return false
  end

  local farmlandId = farmlandManager:getFarmlandIdAtWorldPosition(fieldX, fieldZ)
  local ownerFarmId = farmlandManager:getFarmlandOwner(farmlandId)

  if ownerFarmId == nil or ownerFarmId == AccessHandler.NOBODY then
    return false
  end

  if ownerFarmId == farmId or ownerFarmId == AccessHandler.EVERYONE then
    return true
  end

  return mission.accessHandler ~= nil and mission.accessHandler:canFarmAccessOtherId(farmId, ownerFarmId)
end

---Get all owned bales on cultivated fields
-- @param farmId integer optional farm id override
-- @return table bales list of all owned bales
function BaleDirect:getAllOwnedBales(farmId)
  local ownedBales = {}
  local seenBales = {}

  -- get mission objects
  local mission = self.mission
  local farmManager = g_farmManager
  local farmlandManager = g_farmlandManager

  local resolvedFarmId = farmId

  -- check if mission, farm manager and farmland manager are valid
  if mission == nil or farmManager == nil or farmlandManager == nil then
    return ownedBales
  end

  -- resolve farm id
  if resolvedFarmId == nil then
    resolvedFarmId = mission:getFarmId()
  end

  -- check if farm is valid
  if type(resolvedFarmId) == "number" then
    resolvedFarmId = math.floor(resolvedFarmId)

    local hasValidFarm = resolvedFarmId > 0 and farmManager:getFarmById(resolvedFarmId) ~= nil

    if hasValidFarm then
      local nodeToObject = mission.nodeToObject

      if nodeToObject ~= nil then
        -- scan mission objects and collect owned field bales
        for nodeId, object in pairs(nodeToObject) do
          if object ~= nil and not seenBales[object] then
            local baleNodeId = object.nodeId or nodeId
            local isValidNode = BaleDirect.isValidNode(baleNodeId)
            local isBale = BaleDirect.isBale(object)

            -- check if valid node and bale
            if isValidNode and isBale then
              seenBales[object] = true

              local x, y, z = getWorldTranslation(baleNodeId)
              local farmlandId = farmlandManager:getFarmlandIdAtWorldPosition(x, z)
              local landOwnerFarmId = farmlandManager:getFarmlandOwner(farmlandId)
              local baleOwnerFarmId = BaleDirect.getObjectOwnerFarmId(object)
              local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
              local canAccessBale = baleOwnerFarmId == resolvedFarmId or baleOwnerFarmId == AccessHandler.EVERYONE

              if not canAccessBale and mission.accessHandler ~= nil and baleOwnerFarmId ~= nil then
                canAccessBale = mission.accessHandler:canFarmAccessOtherId(resolvedFarmId, baleOwnerFarmId)
              end

              -- check if bale belongs to the farm (or an accessible farm) and is on one of this farm's fields
              if landOwnerFarmId == resolvedFarmId and canAccessBale and isOnField then
                table.insert(ownedBales, {
                  object = object,
                  nodeId = baleNodeId,
                  x = x,
                  z = z,
                  farmlandId = farmlandId,
                  fillType = object:getFillType(),
                  fillLevel = object.fillLevel or 0
                })
              end
            end
          end
        end
      end
    end
  end

  return ownedBales
end

---Filter bales that are inside a field boundary
-- @param allBales table list of all bales
-- @param fieldCourse table FieldCourse object with courseField
-- @return table bales list of bales inside the field
function BaleDirect:filterBalesInField(allBales, fieldCourse)
  local filteredBales = allBales

  -- filter bales inside field boundary
  if fieldCourse ~= nil and fieldCourse.courseField ~= nil then
    local courseField = fieldCourse.courseField
    filteredBales = {}

    for _, bale in ipairs(allBales) do
      if courseField:getIsPointInsideBoundary(bale.x, bale.z) then
        table.insert(filteredBales, bale)
      end
    end
  end

  return filteredBales
end

---Calculate sale value for bales with realistic economy
-- @param bales table array of bale data
-- @param maxBales mixed optional max bales to sell
-- @return number grossValue total value before fees
-- @return number totalFees all fees combined
-- @return number netProfit final profit
-- @return table breakdown per-filltype breakdown
-- @return table fees detailed fee breakdown
-- @return table selectedBales bales that would be sold
function BaleDirect:calculateSaleValue(bales, maxBales)
  local mission = self.mission

  -- init variables
  local grossValue = 0
  local breakdown = {}
  local baleCount = 0
  local totalVolume = 0
  local selectedBales = {}

  -- sort by value
  local sortedBales = { unpack(bales) }

  table.sort(sortedBales, function(a, b)
    local priceA = BaleDirect.getFillTypePrice(a.fillType, mission)
    local priceB = BaleDirect.getFillTypePrice(b.fillType, mission)
    local valueA = (a.fillLevel or 0) * priceA
    local valueB = (b.fillLevel or 0) * priceB

    if valueA ~= valueB then
      return valueA > valueB
    end

    return a.fillType < b.fillType
  end)

  -- sold counters by type
  local soldPerType = {}

  for _, baleData in ipairs(sortedBales) do
    local fillType = baleData.fillType
    local isAllowed = true

    -- apply limits
    if type(maxBales) == "number" then
      if baleCount >= maxBales then
        isAllowed = false
      end
    elseif type(maxBales) == "table" then
      local limit = maxBales[fillType]
      local current = soldPerType[fillType] or 0

      if limit ~= nil and current >= limit then
        isAllowed = false
      end
    end

    -- add to selected bales if allowed
    if isAllowed then
      table.insert(selectedBales, baleData)

      -- resolve fill level
      local fillLevel = baleData.fillLevel or 0

      if fillLevel <= 0 and baleData.object ~= nil then
        if baleData.object.getFillLevel ~= nil then
          fillLevel = baleData.object:getFillLevel() or 0
        else
          fillLevel = 4000
        end
      end

      -- synced economy price
      local price = BaleDirect.getFillTypePrice(fillType, mission)
      local value = fillLevel * price

      -- update totals
      grossValue = grossValue + value
      baleCount = baleCount + 1
      totalVolume = totalVolume + fillLevel
      soldPerType[fillType] = (soldPerType[fillType] or 0) + 1

      -- aggregate per fill type
      if breakdown[fillType] == nil then
        breakdown[fillType] = {
          count = 0,
          fillLevel = 0,
          value = 0,
          price = price
        }
      end

      -- update breakdown
      breakdown[fillType].count = breakdown[fillType].count + 1
      breakdown[fillType].fillLevel = breakdown[fillType].fillLevel + fillLevel
      breakdown[fillType].value = breakdown[fillType].value + value
    end
  end

  -- fee calculation
  local eco = self:getEconomySettings()
  local commission = grossValue * (self.PRICE_REDUCTION_PERCENT / 100)
  local dispatchFee = eco.dispatchFee
  local handlingCost = (totalVolume / 1000) * eco.handlingCost
  local serviceFees = dispatchFee + handlingCost
  local totalFees = commission + serviceFees
  local netProfit = grossValue - totalFees

  -- fee breakdown
  local fees = {
    commission = commission,
    dispatch = dispatchFee,
    handling = handlingCost,
    service = serviceFees,
    total = totalFees,
    baleCount = baleCount
  }

  return grossValue, totalFees, netProfit, breakdown, fees, selectedBales
end

---Execute sale of bales
-- @param farmId integer farm to credit
-- @param maxBales mixed optional max bales to sell (nil = all)
-- @param bales table optional list of bales to sell (nil = all owned bales)
-- @param deliveryType integer optional delivery type (EXPRESS or STANDARD)
-- @param table connection optional client connection for permission checks
-- @return boolean success
-- @return number netProfit amount credited
function BaleDirect:executeSale(farmId, maxBales, bales, deliveryType, connection)
  local mission = self.mission
  local success = false

  local netProfit = 0

  -- check if server
  if mission:getIsServer() and self:hasSalePermission(farmId, connection) then
    local selectedDeliveryType = deliveryType or self.DELIVERY_EXPRESS
    local freshOwnedBales = self:getAllOwnedBales(farmId)
    local sourceBales = bales

    -- check if there are any bales to sell
    if sourceBales == nil then
      sourceBales = freshOwnedBales
    else
      local freshBalesByObject = {}
      local validatedBales = {}

      -- create fresh bales by object
      for _, baleData in ipairs(freshOwnedBales) do
        if baleData.object ~= nil then
          freshBalesByObject[baleData.object] = baleData
        end
      end

      -- validate bales
      for _, baleData in ipairs(sourceBales) do
        local baleObject = baleData ~= nil and baleData.object or nil
        local freshData = baleObject ~= nil and freshBalesByObject[baleObject] or nil

        if freshData ~= nil then
          table.insert(validatedBales, freshData)
        end
      end

      sourceBales = validatedBales
    end

    -- check if there are any bales to sell
    if #sourceBales > 0 then
      local _, _, _, _, _, selectedBales = self:calculateSaleValue(sourceBales, maxBales)
      local soldGrossValue = 0
      local soldTotalVolume = 0
      local soldBaleCount = 0
      local soldBreakdown = {}

      for _, baleData in ipairs(selectedBales) do
        local baleObject = baleData.object
        local baleNodeId = baleObject ~= nil and baleObject.nodeId or baleData.nodeId
        local canDelete = baleObject ~= nil and baleNodeId ~= nil and baleNodeId ~= 0 and entityExists(baleNodeId)

        if canDelete then
          -- resolve fill type and level
          local fillType = baleData.fillType

          if baleObject.getFillType ~= nil then
            fillType = baleObject:getFillType()
          end

          local fillLevel = baleData.fillLevel or 0

          if baleObject.getFillLevel ~= nil then
            fillLevel = baleObject:getFillLevel() or fillLevel
          end

          -- calculate value
          local price = BaleDirect.getFillTypePrice(fillType, mission)
          local value = fillLevel * price

          soldGrossValue = soldGrossValue + value
          soldTotalVolume = soldTotalVolume + fillLevel
          soldBaleCount = soldBaleCount + 1

          -- aggregate breakdown
          if soldBreakdown[fillType] == nil then
            soldBreakdown[fillType] = {
              count = 0,
              fillLevel = 0,
              value = 0,
              price = price
            }
          end

          soldBreakdown[fillType].count = soldBreakdown[fillType].count + 1
          soldBreakdown[fillType].fillLevel = soldBreakdown[fillType].fillLevel + fillLevel
          soldBreakdown[fillType].value = soldBreakdown[fillType].value + value

          -- delete bale
          baleObject:delete()
        end
      end

      if soldBaleCount > 0 then
        -- calculate final fees
        local eco = self:getEconomySettings()
        local commission = soldGrossValue * (self.PRICE_REDUCTION_PERCENT / 100)
        local dispatchFee = eco.dispatchFee
        local handlingCost = (soldTotalVolume / 1000) * eco.handlingCost
        local totalFees = commission + dispatchFee + handlingCost
        local feeModifier = self.paymentSystem:getFeeModifier(selectedDeliveryType)
        local adjustedFees = totalFees * feeModifier
        local adjustedNetProfit = soldGrossValue - adjustedFees

        -- credit farm or schedule sale
        if selectedDeliveryType == self.DELIVERY_EXPRESS then
          mission:addMoney(adjustedNetProfit, farmId, MoneyType.SOLD_BALES, true, true)
        else
          self.paymentSystem:scheduleSale(farmId, adjustedNetProfit, selectedDeliveryType, soldBreakdown, soldBaleCount)
        end

        success = true
        netProfit = adjustedNetProfit
      end
    end
  end

  return success, netProfit
end

---Open the dialog with farmland preselected
-- @param farmlandId integer farmland to preselect
-- @param x number optional world X
-- @param z number optional world Z
function BaleDirect:openDialog(farmlandId, x, z)
  local canOpenDialog = BaleDirectDialog ~= nil and BaleDirectDialog.INSTANCE ~= nil

  if canOpenDialog then
    -- close map view
    if self.mapFrame ~= nil then
      self.mapFrame.ingameMap:onClose()
      self.mapFrame:toggleMapInput(false)
    end

    -- restore map view callback
    local function onDialogClosed(_, _)
      if self.mapFrame ~= nil then
        self.mapFrame:toggleMapInput(true)
        self.mapFrame.ingameMap:onOpen()
        self.mapFrame.ingameMap:registerActionEvents()
      end
    end

    BaleDirectDialog.show(farmlandId, x, z, onDialogClosed)
  end
end

---Called when map frame is loaded - adds our context action
-- @param frame table InGameMenuMapFrame instance
function BaleDirect:onMapFrameLoaded(frame)
  if frame.contextActions ~= nil then
    self.mapFrame = frame

    -- add action
    local action = {
      title = g_i18n:getText("baleDirect_openDialog"),
      callback = function()
        if frame.selectedFarmland ~= nil then
          self.mission.baleDirect:openDialog(frame.selectedFarmland.id, self.lastHotspotX, self.lastHotspotZ)
        end

        return true
      end,
      isActive = false
    }

    table.insert(frame.contextActions, action)
    self.contextActionIndex = #frame.contextActions
  end
end

---Update context action visibility
-- @param frame table InGameMenuMapFrame instance
-- @param hotspot table selected hotspot
function BaleDirect:updateContextAction(frame, hotspot)
  local action = nil

  -- get action
  if self.contextActionIndex ~= nil and frame.contextActions ~= nil then
    action = frame.contextActions[self.contextActionIndex]
  end

  -- check owned farmland hotspot
  if action ~= nil then
    local showAction = false

    if hotspot ~= nil and hotspot.isa ~= nil and hotspot:isa(FarmlandHotspot) then
      local farmland = hotspot:getFarmland()

      if farmland ~= nil then
        local ownerId = g_farmlandManager:getFarmlandOwner(farmland.id)
        local myFarmId = self.mission:getFarmId()
        local hasPermission = self.mission:getHasPlayerPermission("sellVehicle")
        local isPaused = self.mission.paused

        if ownerId == myFarmId and hasPermission and not isPaused then
          showAction = true
        end

        -- save hotspot position
        if hotspot.getWorldPosition ~= nil then
          self.lastHotspotX, self.lastHotspotZ = hotspot:getWorldPosition()
        end
      end
    end

    -- refresh action visibility
    action.isActive = showAction
    frame.contextButtonListFarmland:reloadData()
  end
end

---Calculate sale value for windrows
-- @param windrows table map of fillType to liters
-- @return number grossValue total value before fees
-- @return number totalFees all fees combined
-- @return number netProfit final profit
-- @return table breakdown per-filltype breakdown
-- @return table fees detailed fee breakdown
function BaleDirect:calculateWindrowSale(windrows)
  local breakdown = {}

  local grossValue = 0
  local totalVolume = 0

  -- value per fill type
  for fillType, liters in pairs(windrows) do
    if liters ~= nil and liters > 0 then
      local price = BaleDirect.getFillTypePrice(fillType, self.mission)

      -- full market price
      local value = liters * price

      grossValue = grossValue + value
      totalVolume = totalVolume + liters

      breakdown[fillType] = {
        liters = liters,
        value = value,
        price = price
      }
    end
  end

  -- fee calculation
  local eco = self:getEconomySettings()
  local commission = grossValue * (self.PRICE_REDUCTION_PERCENT / 100)
  local dispatchFee = eco.balingDispatch
  local balingCost = (totalVolume / 1000) * eco.balingCost
  local serviceFees = dispatchFee + balingCost
  local totalFees = commission + serviceFees
  local netProfit = grossValue - totalFees

  -- fee breakdown
  local fees = {
    commission = commission,
    dispatch = dispatchFee,
    baling = balingCost,
    service = serviceFees,
    total = totalFees
  }

  return grossValue, totalFees, netProfit, breakdown, fees
end

---Get windrow fill types
-- @return table fillTypes list of fill type indices
function BaleDirect:getWindrowFillTypes()
  if self.windrowFillTypes == nil then
    local fillTypes = nil

    if g_fillTypeManager ~= nil then
      fillTypes = g_fillTypeManager:getFillTypesByCategoryNames("WINDROW")
    end

    self.windrowFillTypes = fillTypes or {}
  end

  return self.windrowFillTypes
end

---Get shared modifiers cache for windrow scanning
-- @return table modifiers shared modifiers or nil
function BaleDirect:getSharedClearModifiers()
  if g_densityMapHeightManager == nil or not g_densityMapHeightManager:getIsValid() then
    return nil
  end

  -- create modifiers
  if self.modifiersCache == nil then
    self.modifiersCache = {
      heightModifier = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.heightFirstChannel, DensityMapHeightUtil.heightNumChannels),
      typeModifier = DensityMapModifier.new(DensityMapHeightUtil.terrainDetailHeightId, DensityMapHeightUtil.typeFirstChannel, DensityMapHeightUtil.typeNumChannels),
      typeFiltersByFillType = {}
    }
  end

  return self.modifiersCache
end

---Get density map filter for a specific fill type
-- @param integer fillTypeIndex fill type index
-- @return table filter density map filter or nil
function BaleDirect:getClearAreaModifiers(fillTypeIndex)
  -- get modifiers
  local modifiers = fillTypeIndex ~= nil and self:getSharedClearModifiers() or nil
  if modifiers == nil then
    return nil
  end

  -- get cached filter
  local typeFilter = modifiers.typeFiltersByFillType[fillTypeIndex]
  if typeFilter ~= nil then
    return typeFilter
  end

  -- get height type
  local heightType = g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex)
  if heightType == nil then
    return nil
  end

  -- create filter
  typeFilter = DensityMapFilter.new(modifiers.typeModifier)
  typeFilter:setValueCompareParams(DensityValueCompareType.EQUAL, heightType.index)
  modifiers.typeFiltersByFillType[fillTypeIndex] = typeFilter

  return typeFilter
end

---Resolve field area by generated field course
-- @param table fieldCourse generated FieldCourse
-- @return table areaPolygon density map polygon or nil
function BaleDirect:getFieldAreaByCourse(fieldCourse)
  local courseField = fieldCourse ~= nil and fieldCourse.courseField or nil
  local field = courseField ~= nil and courseField.field or nil

  -- try native polygon first
  if field ~= nil and field.getDensityMapPolygon ~= nil then
    return field:getDensityMapPolygon()
  end

  -- fallback: build polygon from boundary line
  local fieldBoundary = courseField ~= nil and courseField.fieldRootBoundary ~= nil and courseField.fieldRootBoundary.boundaryLine or nil
  if fieldBoundary == nil then
    return nil
  end

  local areaPolygon = DensityMapPolygon.new()

  for _, point in ipairs(fieldBoundary) do
    areaPolygon:addPolygonPoint(point[1], point[2])
  end

  return areaPolygon
end

---Scan windrows within a polygon area
-- @param table areaPolygon density map polygon
-- @return table windrows map of fillType to liters
function BaleDirect:scanWindrows(areaPolygon)
  local windrows = {}

  if areaPolygon == nil then
    return windrows
  end

  -- check modifiers and fill types
  local fillTypes = self:getWindrowFillTypes()
  local modifiers = self:getSharedClearModifiers()
  local heightModifier = modifiers ~= nil and modifiers.heightModifier or nil

  if fillTypes == nil or #fillTypes == 0 or heightModifier == nil then
    return windrows
  end

  -- apply area polygon to height modifier
  areaPolygon:applyToModifier(heightModifier)

  -- process each fill type
  for _, fillType in ipairs(fillTypes) do
    local typeFilter = self:getClearAreaModifiers(fillType)

    -- check valid liters
    if typeFilter ~= nil then
      local sumPixels = heightModifier:executeGet(typeFilter)

      if sumPixels ~= nil and sumPixels > 0 then
        local minValidLiterValue = g_densityMapHeightManager:getMinValidLiterValue(fillType) or 1
        local liters = sumPixels * minValidLiterValue

        if liters > BaleDirect.MIN_WINDROW_TOTAL_LITERS then
          windrows[fillType] = liters
        end
      end
    end
  end

  -- clear polygon points
  heightModifier:clearPolygonPoints()

  return windrows
end

---Clear windrows from polygon area using native FieldUpdateTask
-- @param table areaPolygon density map polygon
-- @param table fillTypes optional list of fill types to clear
-- @return boolean hasOperations true when at least one clear operation was executed
function BaleDirect:clearWindrows(areaPolygon, fillTypes)
  if areaPolygon == nil then
    return false
  end

  -- check fill types
  local targetFillTypes = fillTypes or self:getWindrowFillTypes()
  if targetFillTypes == nil or #targetFillTypes == 0 then
    return false
  end

  local hasOperations = false

  -- clear each fill type
  for _, fillType in ipairs(targetFillTypes) do
    local typeFilter = self:getClearAreaModifiers(fillType)

    if typeFilter ~= nil then
      local task = FieldUpdateTask.new()

      task:setArea(areaPolygon)
      task:addFilter(typeFilter)
      task:clearHeight()
      task:enqueue(true)

      hasOperations = true
    end
  end

  return hasOperations
end

---Scan windrows within a generated merged field course
-- @param table fieldCourse generated FieldCourse
-- @return table windrows map of fillType to liters
function BaleDirect:scanWindrowsInFieldCourse(fieldCourse)
  -- return scanned windrows
  return self:scanWindrows(self:getFieldAreaByCourse(fieldCourse))
end

---Execute windrow sale inside provided polygon area
-- @param integer farmId farm to credit
-- @param table areaPolygon density map polygon
-- @param integer deliveryType optional delivery type
-- @param table sellEnabled optional map fillType -> bool (on/off)
-- @return boolean success
-- @return number netProfit amount credited
function BaleDirect:executeWindrowSaleInArea(farmId, areaPolygon, deliveryType, sellEnabled)
  local mission = self.mission
  local success = false

  local netProfit = 0

  -- check mission and area
  if mission == nil or not mission:getIsServer() or areaPolygon == nil then
    return success, netProfit
  end

  -- scan windrows
  local scannedWindrows = self:scanWindrows(areaPolygon)

  -- filter by sell-enabled types
  if sellEnabled ~= nil then
    for fillType, _ in pairs(scannedWindrows) do
      if sellEnabled[fillType] == false then
        scannedWindrows[fillType] = nil
      end
    end
  end

  -- normalize windrows
  local normalizedWindrows, fillTypesToClear = BaleDirect.normalizeWindrows(scannedWindrows, BaleDirect.MIN_WINDROW_TOTAL_LITERS)

  -- clear windrows and calculate sale
  if #fillTypesToClear > 0 and self:clearWindrows(areaPolygon, fillTypesToClear) then
    local selectedDeliveryType = deliveryType or self.DELIVERY_EXPRESS
    local feeModifier = self.paymentSystem:getFeeModifier(selectedDeliveryType)
    local grossValue, totalFees, _, breakdown, _ = self:calculateWindrowSale(normalizedWindrows)
    local adjustedNetProfit = grossValue - totalFees * feeModifier

    -- add money
    if adjustedNetProfit > 0 then
      if selectedDeliveryType == self.DELIVERY_EXPRESS then
        mission:addMoney(adjustedNetProfit, farmId, MoneyType.HARVEST_INCOME, true, true)
      else
        self.paymentSystem:scheduleSale(farmId, adjustedNetProfit, selectedDeliveryType, breakdown, 0)
      end

      success = true
      netProfit = adjustedNetProfit
    end
  end

  return success, netProfit
end

---Execute windrow sale at field position (server resolves merged polygon async)
-- @param integer farmId farm to credit
-- @param number fieldX field X position
-- @param number fieldZ field Z position
-- @param integer deliveryType optional delivery type
-- @param table sellEnabled optional map fillType -> bool (on/off)
-- @param table connection optional network connection for async confirm
function BaleDirect:executeWindrowSaleAtPosition(farmId, fieldX, fieldZ, deliveryType, sellEnabled, connection)
  local mission = self.mission

  if mission == nil or not mission:getIsServer() then
    return
  end

  if fieldX == nil or fieldZ == nil then
    return
  end

  if not self:hasSalePermission(farmId, connection) or not self:canAccessFieldPosition(farmId, fieldX, fieldZ) then
    return
  end

  -- generate field course async to resolve merged field polygon
  local fieldCourseSettings = BaleDirect.createFieldCourseSettings()

  FieldCourse.generateUICourseByFieldPosition(fieldX, fieldZ, fieldCourseSettings, function(course)
    local areaPolygon = course ~= nil and self:getFieldAreaByCourse(course) or nil

    if areaPolygon ~= nil then
      local success, netProfit = self:executeWindrowSaleInArea(farmId, areaPolygon, deliveryType, sellEnabled)

      -- notify requesting client
      if success and connection ~= nil then
        connection:sendEvent(BaleDirectSellConfirmEvent.new(netProfit, farmId))
      end
    end
  end)
end

---Create default field course settings used for windrow sale
-- @return table fieldCourseSettings configured field course settings
function BaleDirect.createFieldCourseSettings()
  local fieldCourseSettings = FieldCourseSettings.new()

  fieldCourseSettings.implementWidth = 14
  fieldCourseSettings.numHeadlands = 3
  fieldCourseSettings.segmentExtendedToBoundary = true
  fieldCourseSettings.segmentHeadlandReverseLines = true

  return fieldCourseSettings
end

---Check if object is a valid bale
-- @param table obj object to check
-- @return boolean true if bale
function BaleDirect.isBale(obj)
  if obj == nil then
    return false
  end

  -- check via isa method
  if obj.isa ~= nil then
    local ok, res = pcall(function()
      return obj:isa(Bale)
    end)

    if ok and res then
      return true
    end
  end

  -- fallback: check for bale-like interface
  return obj.getFillType ~= nil and obj.nodeId ~= nil
end

---Check if node exists and is valid
-- @param integer nodeId node to check
-- @return boolean true if valid
function BaleDirect.isValidNode(nodeId)
  if entityExists ~= nil then
    return nodeId ~= nil and nodeId ~= 0 and entityExists(nodeId)
  end

  return nodeId ~= nil and nodeId ~= 0
end

---Get fill type color for display
-- @param integer fillTypeIndex fill type index
-- @return table color {r, g, b, a}
function BaleDirect.getFillTypeColor(fillTypeIndex)
  local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

  -- lookup color by fill type name
  if fillType ~= nil then
    local name = string.upper(fillType.name)

    if BaleDirect.FILL_COLORS[name] ~= nil then
      return BaleDirect.FILL_COLORS[name]
    end
  end

  return BaleDirect.FILL_COLORS.DEFAULT
end

---Get synchronized fill price per liter
-- @param integer fillTypeIndex fill type index
-- @param table mission current mission
-- @return number price price per liter
function BaleDirect.getFillTypePrice(fillTypeIndex, mission)
  local currentMission = mission or g_currentMission
  local price = 0

  if currentMission ~= nil and currentMission.economyManager ~= nil and fillTypeIndex ~= nil then
    price = currentMission.economyManager:getPricePerLiter(fillTypeIndex) or 0
  end

  return price
end

---Normalize windrow scan map to valid numeric liters above threshold
-- @param table windrows raw windrow map
-- @param number minLiters minimum liters threshold
-- @return table normalizedWindrows normalized map
-- @return table fillTypesToClear array of fill type indices
function BaleDirect.normalizeWindrows(windrows, minLiters)
  local normalizedWindrows = {}
  local fillTypesToClear = {}

  -- normalize windrows
  if windrows ~= nil then
    for fillType, liters in pairs(windrows) do
      if fillType ~= nil and liters ~= nil and liters > minLiters then
        normalizedWindrows[fillType] = liters
        fillTypesToClear[#fillTypesToClear + 1] = fillType
      end
    end
  end

  return normalizedWindrows, fillTypesToClear
end

-- fill type color mapping for hotspots
BaleDirect.FILL_COLORS = {
  STRAW = { 1.00, 0.90, 0.20, 1 },
  HAY = { 0.70, 0.90, 0.50, 1 },
  DRYGRASS = { 0.70, 0.90, 0.50, 1 },
  GRASS = { 0.20, 0.50, 0.20, 1 },
  GRASS_WINDROW = { 0.20, 0.50, 0.20, 1 },
  SILAGE = { 0.45, 0.30, 0.15, 1 },
  COTTON = { 0.95, 0.95, 1.00, 1 },
  DEFAULT = { 0.80, 0.80, 0.80, 1 }
}
