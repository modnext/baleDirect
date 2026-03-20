--
-- BaleDirectSellEvent
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

BaleDirectSellEvent = {}

local BaleDirectSellEvent_mt = Class(BaleDirectSellEvent, Event)

InitEventClass(BaleDirectSellEvent, "BaleDirectSellEvent")

---Create empty event
-- @return table self event
function BaleDirectSellEvent.emptyNew()
  local self = Event.new(BaleDirectSellEvent_mt)

  return self
end

---Create event with payload
-- @param integer farmId farm to credit
-- @param integer deliveryType delivery type constant
-- @param table fillTypeLimits optional map of fillType to max count
-- @return table self event
function BaleDirectSellEvent.new(farmId, deliveryType, fillTypeLimits)
  local self = BaleDirectSellEvent.emptyNew()

  self.farmId = farmId
  self.deliveryType = deliveryType
  self.fillTypeLimits = fillTypeLimits

  return self
end

---Read event from stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectSellEvent:readStream(streamId, connection)
  self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
  self.deliveryType = streamReadUInt8(streamId)

  -- fill type limits
  local numLimits = streamReadUInt8(streamId)

  if numLimits > 0 then
    self.fillTypeLimits = {}

    for _ = 1, numLimits do
      local fillType = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
      local limit = streamReadUInt16(streamId)

      self.fillTypeLimits[fillType] = limit
    end
  end

  self:run(connection)
end

---Write event to stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectSellEvent:writeStream(streamId, connection)
  streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
  streamWriteUInt8(streamId, self.deliveryType)

  -- fill type limits
  local numLimits = 0
  local limitEntries = {}

  if self.fillTypeLimits ~= nil then
    for fillType, limit in pairs(self.fillTypeLimits) do
      numLimits = numLimits + 1
      table.insert(limitEntries, { fillType = fillType, limit = limit })
    end
  end

  streamWriteUInt8(streamId, numLimits)

  for _, entry in ipairs(limitEntries) do
    streamWriteUIntN(streamId, entry.fillType, FillTypeManager.SEND_NUM_BITS)
    streamWriteUInt16(streamId, entry.limit)
  end
end

---Run event on server
-- @param table connection network connection
function BaleDirectSellEvent:run(connection)
  if not connection:getIsServer() then
    local baleDirect = g_currentMission.baleDirect

    if baleDirect ~= nil then
      local success, netProfit = baleDirect:executeSale(self.farmId, self.fillTypeLimits, nil, self.deliveryType, connection)

      -- notify requesting client
      if success then
        connection:sendEvent(BaleDirectSellConfirmEvent.new(netProfit, self.farmId))
      end
    end
  end
end
