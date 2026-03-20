--
-- BaleDirectSyncSalesEvent
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

BaleDirectSyncSalesEvent = {}

local BaleDirectSyncSalesEvent_mt = Class(BaleDirectSyncSalesEvent, Event)

InitEventClass(BaleDirectSyncSalesEvent, "BaleDirectSyncSalesEvent")

---Create empty event
-- @return table self event
function BaleDirectSyncSalesEvent.emptyNew()
  local self = Event.new(BaleDirectSyncSalesEvent_mt)

  return self
end

---Create event with payload
-- @param table pendingSales
-- @return table self event
function BaleDirectSyncSalesEvent.new(pendingSales)
  local self = BaleDirectSyncSalesEvent.emptyNew()

  self.pendingSales = pendingSales

  return self
end

---Read event from stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectSyncSalesEvent:readStream(streamId, connection)
  self.pendingSales = {}

  -- read pending sales
  local numSales = streamReadUInt16(streamId)

  for _ = 1, numSales do
    local sale = {
      id = streamReadInt32(streamId),
      farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
      netProfit = streamReadFloat32(streamId)
    }

    self.pendingSales[sale.id] = sale
  end

  self:run(connection)
end

---Write event to stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectSyncSalesEvent:writeStream(streamId, connection)
  local salesArray = {}

  -- convert to array
  for _, sale in pairs(self.pendingSales) do
    table.insert(salesArray, sale)
  end

  -- write pending sales
  streamWriteUInt16(streamId, #salesArray)
  for _, sale in ipairs(salesArray) do
    streamWriteInt32(streamId, sale.id)
    streamWriteUIntN(streamId, sale.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteFloat32(streamId, sale.netProfit)
  end
end

---Run event action
-- @param table connection network connection
function BaleDirectSyncSalesEvent:run(connection)
  if connection:getIsServer() then
    local baleDirect = g_currentMission.baleDirect

    -- receive pending sales
    if baleDirect ~= nil and baleDirect.paymentSystem ~= nil then
      baleDirect.paymentSystem:receivePendingSales(self.pendingSales)
    end
  end
end
