--
-- BaleDirectRequestSalesEvent
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

BaleDirectRequestSalesEvent = {}

local BaleDirectRequestSalesEvent_mt = Class(BaleDirectRequestSalesEvent, Event)

InitEventClass(BaleDirectRequestSalesEvent, "BaleDirectRequestSalesEvent")

---Create empty event
-- @return table self event
function BaleDirectRequestSalesEvent.emptyNew()
  local self = Event.new(BaleDirectRequestSalesEvent_mt)

  return self
end

---Create event
-- @return table self event
function BaleDirectRequestSalesEvent.new()
  local self = BaleDirectRequestSalesEvent.emptyNew()

  return self
end

---Read event from stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectRequestSalesEvent:readStream(streamId, connection)
  self:run(connection)
end

---Write event to stream
-- @param integer streamId stream id
-- @param table connection network connection
function BaleDirectRequestSalesEvent:writeStream(streamId, connection)
  --
end

---Run event action
-- @param table connection network connection
function BaleDirectRequestSalesEvent:run(connection)
  if not connection:getIsServer() then
    local baleDirect = g_currentMission.baleDirect

    -- send pending sales to client
    if baleDirect ~= nil and baleDirect.paymentSystem ~= nil then
      baleDirect.paymentSystem:sendPendingSalesToClient(connection)
    end
  end
end
