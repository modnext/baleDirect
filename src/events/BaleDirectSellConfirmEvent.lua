--
-- BaleDirectSellConfirmEvent
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

BaleDirectSellConfirmEvent = {}

local BaleDirectSellConfirmEvent_mt = Class(BaleDirectSellConfirmEvent, Event)

InitEventClass(BaleDirectSellConfirmEvent, "BaleDirectSellConfirmEvent")

---Create empty event
-- @return table self event
function BaleDirectSellConfirmEvent.emptyNew()
  local self = Event.new(BaleDirectSellConfirmEvent_mt)

  return self
end

---Create event with payload
-- @param number netProfit amount credited
-- @param integer farmId farm credited
-- @return table self event
function BaleDirectSellConfirmEvent.new(netProfit, farmId)
  local self = BaleDirectSellConfirmEvent.emptyNew()

  self.netProfit = netProfit
  self.farmId = farmId

  return self
end

---Read event from stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectSellConfirmEvent:readStream(streamId, connection)
  self.netProfit = streamReadFloat32(streamId)
  self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)

  self:run(connection)
end

---Write event to stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectSellConfirmEvent:writeStream(streamId, connection)
  local maxFarmId = 2 ^ FarmManager.FARM_ID_SEND_NUM_BITS - 1
  local farmId = math.min(math.max(self.farmId or 0, 0), maxFarmId)

  streamWriteFloat32(streamId, self.netProfit)
  streamWriteUIntN(streamId, farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
end

---Run event action
-- @param table connection network connection
function BaleDirectSellConfirmEvent:run(connection)
  if connection:getIsServer() and g_currentMission:getFarmId() == self.farmId then
    g_currentMission:showMoneyChange(MoneyType.SOLD_BALES, nil, true)
  end
end
