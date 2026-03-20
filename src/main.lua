--
-- Main
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

---Directory where the currently loaded mod resides
local modDirectory = g_currentModDirectory or ""
---Name of the currently loaded mod
local modName = g_currentModName or "unknown"
---Environment associated with the currently loaded mod
local modEnvironment

---List of files to be loaded
local sourceFiles = {
  "src/events/BaleDirectSellEvent.lua",
  "src/events/BaleDirectWindrowSellEvent.lua",
  "src/events/BaleDirectSellConfirmEvent.lua",
  "src/events/BaleDirectRequestSalesEvent.lua",
  "src/events/BaleDirectSyncSalesEvent.lua",
  -- gui
  "src/gui/BaleDirectGui.lua",
  "src/gui/dialogs/BaleDirectDialog.lua",
  "src/gui/dialogs/BaleDirectItemDialog.lua",
  -- misc
  "src/misc/BaleDirectPaymentSystem.lua",
  -- main
  "src/BaleDirect.lua",
}

---Load the mod's source files
for _, file in ipairs(sourceFiles) do
  source(modDirectory .. file)
end

---Check if the mod is loaded
local function isLoaded()
  return modEnvironment ~= nil and g_modIsLoaded[modName]
end

---Load the mod
local function load(mission)
  assert(modEnvironment == nil)

  modEnvironment = BaleDirect.new(modName, modDirectory, mission, g_i18n, g_gui)
  mission.baleDirect = modEnvironment
  addModEventListener(modEnvironment)
end

---Called when the mission is loaded
local function loadedMission(mission, node)
  if not isLoaded() then
    return
  end

  if mission.cancelLoading then
    return
  end

  modEnvironment:onMissionLoaded(mission)
end

---Unload the mod
local function unload()
  if not isLoaded() then
    return
  end

  if modEnvironment ~= nil then
    modEnvironment:delete()
    modEnvironment = nil

    if g_currentMission ~= nil then
      g_currentMission.baleDirect = nil
    end
  end
end

---Called on savegame save
local function saveSavegame(missionInfo)
  if not isLoaded() then
    return
  end

  if g_server ~= nil and modEnvironment ~= nil then
    modEnvironment:saveToFile()
  end
end

---Called when map frame finishes loading
local function onMapFrameLoadFinished(frame, superFunc, ...)
  superFunc(frame, ...)

  if modEnvironment ~= nil then
    modEnvironment:onMapFrameLoaded(frame)
  end
end

---Called when map selection item changes
local function onMapSelectionItemChanged(frame, superFunc, hotspot, ...)
  superFunc(frame, hotspot, ...)

  if modEnvironment ~= nil then
    modEnvironment:updateContextAction(frame, hotspot)
  end
end

---Init the mod
local function init()
  FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, unload)
  Mission00.load = Utils.prependedFunction(Mission00.load, load)
  Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)
  FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, saveSavegame)

  InGameMenuMapFrame.onLoadMapFinished = Utils.overwrittenFunction(InGameMenuMapFrame.onLoadMapFinished, onMapFrameLoadFinished)
  InGameMenuMapFrame.setMapSelectionItem = Utils.overwrittenFunction(InGameMenuMapFrame.setMapSelectionItem, onMapSelectionItemChanged)
end

---
init()
