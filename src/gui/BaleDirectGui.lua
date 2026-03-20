--
-- BaleDirectGui
--
-- Author: Sławek Jaskulski
-- Copyright (C) Mod Next, All Rights Reserved.
--

BaleDirectGui = {}

local BaleDirectGui_mt = Class(BaleDirectGui)

---Creates a new instance of BaleDirectGui
function BaleDirectGui.new(customMt, modDirectory, mission, gui, i18n)
  local self = setmetatable({}, customMt or BaleDirectGui_mt)

  self.gui = gui
  self.modDirectory = modDirectory
  self.mission = mission
  self.i18n = i18n

  -- dialogs
  self.baleDirectItemDialog = BaleDirectItemDialog.new(nil, customMt, mission, gui, i18n)
  self.baleDirectDialog = BaleDirectDialog.new(nil, customMt, mission, gui, i18n)

  self.isLoaded = false

  return self
end

---Initializes GUI components
function BaleDirectGui:init()
  if self.isLoaded then
    return
  end

  -- item dialog
  local itemDialogXmlPath = Utils.getFilename("data/gui/BaleDirectItemDialog.xml", self.modDirectory)

  self.gui:loadGui(itemDialogXmlPath, "BaleDirectItemDialog", self.baleDirectItemDialog)
  BaleDirectItemDialog.INSTANCE = self.baleDirectItemDialog

  -- dialog
  local dialogXmlPath = Utils.getFilename("data/gui/BaleDirectDialog.xml", self.modDirectory)

  self.gui:loadGui(dialogXmlPath, "BaleDirectDialog", self.baleDirectDialog)
  BaleDirectDialog.INSTANCE = self.baleDirectDialog

  -- set focus to the loading screen
  FocusManager:setGui("MPLoadingScreen")

  self.isLoaded = true
end

---Delete GUI manager state
function BaleDirectGui:delete()
  self.isLoaded = false

  -- dialogs
  self.baleDirectItemDialog = nil
  self.baleDirectDialog = nil
end
