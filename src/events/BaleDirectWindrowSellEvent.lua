--
-- BaleDirectWindrowSellEvent
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

BaleDirectWindrowSellEvent = {}

local BaleDirectWindrowSellEvent_mt = Class(BaleDirectWindrowSellEvent, Event)

InitEventClass(BaleDirectWindrowSellEvent, "BaleDirectWindrowSellEvent")

---Create empty event
-- @return table self event
function BaleDirectWindrowSellEvent.emptyNew()
  local self = Event.new(BaleDirectWindrowSellEvent_mt)

  return self
end

---Create event with payload
-- @param integer farmId farm to credit
-- @param integer deliveryType delivery type constant
-- @param number fieldX field X position for server-side polygon resolution
-- @param number fieldZ field Z position for server-side polygon resolution
-- @param table sellEnabled optional map fillType -> bool (on/off)
-- @return table self event
function BaleDirectWindrowSellEvent.new(farmId, deliveryType, fieldX, fieldZ, sellEnabled)
  local self = BaleDirectWindrowSellEvent.emptyNew()

  self.farmId = farmId
  self.deliveryType = deliveryType
  self.fieldX = fieldX
  self.fieldZ = fieldZ
  self.sellEnabled = sellEnabled

  return self
end

---Read event from stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectWindrowSellEvent:readStream(streamId, connection)
  self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
  self.deliveryType = streamReadUInt8(streamId)
  self.fieldX = streamReadFloat32(streamId)
  self.fieldZ = streamReadFloat32(streamId)
  self.sellEnabled = nil

  -- disabled fill types
  local numDisabled = streamReadUInt8(streamId)

  if numDisabled > 0 then
    self.sellEnabled = {}

    for _ = 1, numDisabled do
      self.sellEnabled[streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)] = false
    end
  end

  self:run(connection)
end

---Write event to stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectWindrowSellEvent:writeStream(streamId, connection)
  streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
  streamWriteUInt8(streamId, self.deliveryType)
  streamWriteFloat32(streamId, self.fieldX)
  streamWriteFloat32(streamId, self.fieldZ)

  -- disabled fill types
  local disabledTypes = {}

  if self.sellEnabled ~= nil then
    for fillType, isEnabled in pairs(self.sellEnabled) do
      if not isEnabled then
        table.insert(disabledTypes, fillType)
      end
    end
  end

  streamWriteUInt8(streamId, #disabledTypes)

  for i = 1, #disabledTypes do
    streamWriteUIntN(streamId, disabledTypes[i], FillTypeManager.SEND_NUM_BITS)
  end
end

---Run event on server
-- @param table connection network connection
function BaleDirectWindrowSellEvent:run(connection)
  if not connection:getIsServer() then
    local baleDirect = g_currentMission.baleDirect

    if baleDirect ~= nil and self.fieldX ~= nil and self.fieldZ ~= nil then
      baleDirect:executeWindrowSaleAtPosition(self.farmId, self.fieldX, self.fieldZ, self.deliveryType, self.sellEnabled, connection)
    end
  end
end
