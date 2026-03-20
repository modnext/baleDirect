--
-- BaleDirectPaymentSystem
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

---
BaleDirectPaymentSystem = {
  DELIVERY_EXPRESS = 1,
  DELIVERY_STANDARD = 2
}

-- fee modifiers per delivery type
BaleDirectPaymentSystem.FEE_MODIFIER = {
  [BaleDirectPaymentSystem.DELIVERY_EXPRESS] = 1.5,
  [BaleDirectPaymentSystem.DELIVERY_STANDARD] = 0.5
}

local BaleDirectPaymentSystem_mt = Class(BaleDirectPaymentSystem)

---Creates a new payment system instance
-- @param table mission current mission
function BaleDirectPaymentSystem.new(mission)
  local self = setmetatable({}, BaleDirectPaymentSystem_mt)

  self.mission = mission

  -- deferred sales
  self.pendingSales = {}
  self.nextSaleId = 1

  self.isInitialized = false

  return self
end

---Initializes the payment system
function BaleDirectPaymentSystem:init()
  if self.isInitialized then
    return
  end

  -- reset state
  self.pendingSales = {}
  self.nextSaleId = 1
  self.isInitialized = true

  -- subscribe to hour changes on server
  if self.mission ~= nil and self.mission:getIsServer() then
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
  end
end

---Deletes the payment system
function BaleDirectPaymentSystem:delete()
  if not self.isInitialized then
    return
  end

  -- reset state
  self.pendingSales = {}
  self.isInitialized = false

  -- unsubscribe from hour changes on server
  if self.mission ~= nil and self.mission:getIsServer() then
    g_messageCenter:unsubscribe(MessageType.HOUR_CHANGED, self)
  end
end

---Load pending sales from XML file
-- @param table xmlFile XML file handle
-- @param string key base XML key
function BaleDirectPaymentSystem:loadFromXMLFile(xmlFile, key)
  self.nextSaleId = Utils.getNoNil(getXMLInt(xmlFile, key .. "#nextSaleId"), 1)

  --
  local salesKey = key .. ".pendingSales"
  local index = 0
  local highestSaleId = 0
  local hasMoreSales = true

  -- reset state
  self.pendingSales = {}

  while hasMoreSales do
    local saleKey = string.format("%s.sale(%d)", salesKey, index)
    hasMoreSales = hasXMLProperty(xmlFile, saleKey)

    if hasMoreSales then
      local saleId = Utils.getNoNil(getXMLInt(xmlFile, saleKey .. "#id"), index + 1)
      local sale = {
        id = saleId,
        farmId = Utils.getNoNil(getXMLInt(xmlFile, saleKey .. "#farmId"), 1),
        netProfit = Utils.getNoNil(getXMLFloat(xmlFile, saleKey .. "#netProfit"), 0),
        baleCount = Utils.getNoNil(getXMLInt(xmlFile, saleKey .. "#baleCount"), 0),
        createdAt = Utils.getNoNil(getXMLInt(xmlFile, saleKey .. "#createdAt"), 0),
        saleYear = Utils.getNoNil(getXMLInt(xmlFile, saleKey .. "#saleYear"), self:getCurrentYear()),
        deliveryType = self:getResolvedDeliveryType(getXMLInt(xmlFile, saleKey .. "#deliveryType"))
      }

      -- add sale to pending sales
      self.pendingSales[sale.id] = sale

      -- update highest sale id
      highestSaleId = math.max(highestSaleId, sale.id)
      index = index + 1
    end
  end

  -- update next sale id
  if self.nextSaleId <= highestSaleId then
    self.nextSaleId = highestSaleId + 1
  end
end

---Load pending sales from mod-specific XML file
function BaleDirectPaymentSystem:loadFromFile()
  local filePath = self:getSaveFilePath()

  -- load from file if it exists
  if filePath ~= nil and fileExists(filePath) then
    local xmlFile = loadXMLFile("baleDirect", filePath)

    if xmlFile ~= nil then
      self:loadFromXMLFile(xmlFile, "baleDirect")

      -- delete XML file
      delete(xmlFile)
    end
  end
end

---Save pending sales to XML file
-- @param table xmlFile XML file handle
-- @param string key base XML key
function BaleDirectPaymentSystem:saveToXMLFile(xmlFile, key)
  local salesKey = key .. ".pendingSales"
  local index = 0

  -- save pending sales to XML file
  for _, sale in pairs(self.pendingSales) do
    local saleKey = string.format("%s.sale(%d)", salesKey, index)

    setXMLInt(xmlFile, saleKey .. "#id", sale.id)
    setXMLInt(xmlFile, saleKey .. "#farmId", sale.farmId)
    setXMLFloat(xmlFile, saleKey .. "#netProfit", sale.netProfit)
    setXMLInt(xmlFile, saleKey .. "#baleCount", sale.baleCount or 0)
    setXMLInt(xmlFile, saleKey .. "#createdAt", sale.createdAt or 0)
    setXMLInt(xmlFile, saleKey .. "#saleYear", sale.saleYear or 1)
    setXMLInt(xmlFile, saleKey .. "#deliveryType", self:getResolvedDeliveryType(sale.deliveryType))

    index = index + 1
  end

  -- save next sale id
  setXMLInt(xmlFile, key .. "#nextSaleId", self.nextSaleId)
end

---Save pending sales to mod-specific XML file
function BaleDirectPaymentSystem:saveToFile()
  local filePath = self:getSaveFilePath()

  if filePath ~= nil then
    local xmlFile = createXMLFile("baleDirect", filePath, "baleDirect")

    -- save to XML file if it exists
    if xmlFile ~= nil then
      self:saveToXMLFile(xmlFile, "baleDirect")

      -- save and delete XML file
      saveXMLFile(xmlFile)
      delete(xmlFile)
    end
  end
end

---Process all pending sales and pay each one
function BaleDirectPaymentSystem:processAllPendingSales()
  for _, sale in pairs(self.pendingSales) do
    self:executePendingPayment(sale)
  end

  -- reset state
  self.pendingSales = {}
end

---Called when game hour changes
-- @param integer currentHour current hour (0-23)
function BaleDirectPaymentSystem:onHourChanged(currentHour)
  if self.mission ~= nil and self.mission:getIsServer() then
    local currentYear = self:getCurrentYear()
    local salesToProcess = {}

    -- check if we entered a new year
    for _, sale in pairs(self.pendingSales) do
      local saleYear = sale.saleYear or currentYear

      if currentYear > saleYear then
        table.insert(salesToProcess, sale)
      end
    end

    -- process all pending sales
    if #salesToProcess > 0 then
      for _, sale in ipairs(salesToProcess) do
        self:executePendingPayment(sale)
        self.pendingSales[sale.id] = nil
      end
    end
  end
end

---Execute payment for a completed sale
-- @param table sale pending sale data
function BaleDirectPaymentSystem:executePendingPayment(sale)
  if sale ~= nil and self.mission ~= nil then
    -- add money to farm
    self.mission:addMoney(sale.netProfit, sale.farmId, MoneyType.SOLD_BALES, true, true)

    -- broadcast event to clients
    if self.mission:getIsServer() and g_server ~= nil then
      g_server:broadcastEvent(BaleDirectSellConfirmEvent.new(sale.netProfit, sale.farmId))
    end
  end
end

---Schedule a new pending sale
-- @param integer farmId farm to credit
-- @param number netProfit amount to pay
-- @param integer deliveryType delivery type constant
-- @param table breakdown optional fill type breakdown
-- @param integer baleCount number of bales sold
-- @return integer saleId unique sale id
function BaleDirectPaymentSystem:scheduleSale(farmId, netProfit, deliveryType, breakdown, baleCount)
  local resolvedDeliveryType = self:getResolvedDeliveryType(deliveryType)

  -- create sale
  local sale = {
    id = self.nextSaleId,
    farmId = farmId,
    netProfit = netProfit,
    baleCount = baleCount or 0,
    breakdown = breakdown or {},
    createdAt = self:getCurrentMonotonicDay(),
    saleYear = self:getCurrentYear(),
    deliveryType = resolvedDeliveryType
  }

  -- add sale to pending sales and increment next sale id
  self.pendingSales[self.nextSaleId] = sale
  self.nextSaleId = self.nextSaleId + 1

  return sale.id
end

---Send pending sales to client
-- @param table connection network connection
function BaleDirectPaymentSystem:sendPendingSalesToClient(connection)
  if self.mission ~= nil and self.mission:getIsServer() then
    connection:sendEvent(BaleDirectSyncSalesEvent.new(self.pendingSales))
  end
end

---Receive pending sales from server
-- @param table pendingSales pending sales list
function BaleDirectPaymentSystem:receivePendingSales(pendingSales)
  if self.mission ~= nil and self.mission:getIsClient() then
    self.pendingSales = pendingSales

    -- notify GUI to update the payout bar if dialog is open
    if BaleDirectDialog ~= nil and BaleDirectDialog.INSTANCE ~= nil then
      local dialog = BaleDirectDialog.INSTANCE

      if dialog.isOpen then
        dialog:updateExpectedPayoutBar()
      end
    end
  end
end

---Gets current monotonic day from mission environment
-- @return integer currentDay monotonic day or 0
function BaleDirectPaymentSystem:getCurrentMonotonicDay()
  local mission = self.mission
  local currentDay = 0

  -- get current monotonic day from mission environment
  if mission ~= nil and mission.environment ~= nil then
    currentDay = mission.environment.currentMonotonicDay or 0
  end

  return currentDay
end

---Gets current game year from mission environment
-- @return integer currentYear current year or 1
function BaleDirectPaymentSystem:getCurrentYear()
  local mission = self.mission
  local currentYear = 1

  if mission ~= nil and mission.environment ~= nil then
    currentYear = mission.environment.currentYear or 1
  end

  return currentYear
end

---Gets save file path for bale direct deferred payments
-- @return string filePath absolute file path or nil
function BaleDirectPaymentSystem:getSaveFilePath()
  local mission = self.mission

  -- get save file path
  local savePath = nil
  local filePath = nil

  -- get save path from mission
  if mission ~= nil and mission.missionInfo ~= nil then
    savePath = mission.missionInfo.savegameDirectory
  end

  -- get file path from save path
  if savePath ~= nil then
    filePath = savePath .. "/baleDirect.xml"
  end

  return filePath
end

---Resolves delivery type to a valid value
-- @param integer deliveryType requested delivery type
-- @return integer resolvedDeliveryType validated delivery type
function BaleDirectPaymentSystem:getResolvedDeliveryType(deliveryType)
  local resolvedDeliveryType = deliveryType

  -- resolve delivery type
  if BaleDirectPaymentSystem.FEE_MODIFIER[resolvedDeliveryType] == nil then
    resolvedDeliveryType = BaleDirectPaymentSystem.DELIVERY_STANDARD
  end

  return resolvedDeliveryType
end

---Get number of periods in a year
-- @return integer numPeriods usually 12
function BaleDirectPaymentSystem:getNumPeriods()
  local mission = self.mission

  --
  local numPeriods = 12

  -- get number of periods from mission environment
  if mission ~= nil and mission.environment ~= nil and mission.environment.numPeriods ~= nil then
    numPeriods = mission.environment.numPeriods
  end

  return numPeriods
end

---Get pending sales count for farm
-- @param integer farmId farm id to check
-- @return integer count number of pending sales
function BaleDirectPaymentSystem:getPendingSalesCount(farmId)
  local count = 0

  -- get pending sales count for farm
  for _, sale in pairs(self.pendingSales) do
    if sale.farmId == farmId then
      count = count + 1
    end
  end

  return count
end

---Get all pending sales for farm
-- @param integer farmId farm id to get sales for
-- @return table sales list of pending sales
function BaleDirectPaymentSystem:getPendingSalesForFarm(farmId)
  local sales = {}

  for _, sale in pairs(self.pendingSales) do
    if sale.farmId == farmId then
      table.insert(sales, sale)
    end
  end

  return sales
end

---Get expected payout summary for farm
-- @param integer farmId farm id to get summary for
-- @return table summary pending payout summary
function BaleDirectPaymentSystem:getExpectedPayoutSummary(farmId)
  local summary = {
    count = 0,
    totalNetProfit = 0,
    totalBaleCount = 0,
    nextPayoutPeriod = nil,
    sales = {}
  }

  local mission = self.mission
  local resolvedFarmId = math.floor(farmId or mission:getFarmId())

  -- validate farm id
  if type(resolvedFarmId) ~= "number" then
    return summary
  end

  -- get pending sales for farm
  summary.sales = self:getPendingSalesForFarm(resolvedFarmId)
  summary.count = #summary.sales

  -- calculate total net profit and bale count
  for _, sale in ipairs(summary.sales) do
    summary.totalNetProfit = summary.totalNetProfit + (sale.netProfit or 0)
    summary.totalBaleCount = summary.totalBaleCount + math.max(sale.baleCount or 0, 0)
  end

  -- get next payout period
  summary.nextPayoutPeriod = 1

  return summary
end

---Get fee modifier for delivery type
-- @param integer deliveryType delivery type constant
-- @return number modifier fee multiplier
function BaleDirectPaymentSystem:getFeeModifier(deliveryType)
  local modifier = BaleDirectPaymentSystem.FEE_MODIFIER[deliveryType]

  -- get fee modifier for delivery type
  if modifier == nil then
    modifier = 1.0
  end

  return modifier
end
