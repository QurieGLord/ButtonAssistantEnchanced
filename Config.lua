local ADDON_NAME, NS = ...

-- ---------------------------------------------------------------------
-- Settings Registration (Modern UI)
-- ---------------------------------------------------------------------

function NS.RegisterSettings()
	local category = Settings.RegisterVerticalLayoutCategory(NS.ADDON_DISPLAY_NAME or ADDON_NAME)
	NS.SettingsCategory = category

	-- Helper to register settings
	local function Register(key, varType, name, defaultValue, description, callback)
		local setting = Settings.RegisterAddOnSetting(category, ADDON_NAME .. "_" .. key, key, NS.db, varType, name, defaultValue)
		if callback then
			setting:SetValueChangedCallback(callback)
		end
		return setting
	end

	-- General Toggle
	local enabledSetting = Register("enabled", Settings.VarType.Boolean, "Enabled", true, "Enable or disable the addon.", function()
		if NS.UpdateNow then
			NS.UpdateNow()
		end
	end)
	Settings.CreateCheckbox(category, enabledSetting, "Toggle Button Assistant Enchanced on/off.")

	-- Lock Toggle
	local lockedSetting = Register("locked", Settings.VarType.Boolean, "Locked", false, "Lock the frame to prevent dragging.")
	Settings.CreateCheckbox(category, lockedSetting, "Lock the suggestion button in place.")

	-- Visual Settings Category
	local visualSubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Main Button")

	-- The "Right" label is standard for showing values next to sliders
	local labelRight = (MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label and MinimalSliderWithSteppersMixin.Label.Right) or 2

	-- Button Size
	local sizeSetting = Register("buttonSize", Settings.VarType.Number, "Button Size", 40, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
	end)
	local sizeOptions = Settings.CreateSliderOptions(20, 100, 2)
	sizeOptions:SetLabelFormatter(labelRight, function(value)
		return value .. "px"
	end)
	Settings.CreateSlider(visualSubcat, sizeSetting, sizeOptions, "Adjust the dimensions of the suggestion button.")

	-- Show Border
	local borderSetting = Register("showBorder", Settings.VarType.Boolean, "Show Border", true, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
	end)
	Settings.CreateCheckbox(visualSubcat, borderSetting, "Toggle the Blizzard-style border around the button.")

	-- Scale
	local scaleSetting = Register("scale", Settings.VarType.Number, "Scale", 1.0, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
	end)
	local scaleOptions = Settings.CreateSliderOptions(0.5, 2.0, 0.05)
	scaleOptions:SetLabelFormatter(labelRight, function(value)
		return (NS.math_floor(value * 100)) .. "%"
	end)
	Settings.CreateSlider(visualSubcat, scaleSetting, scaleOptions, "Overall scale of the assistant UI.")

	-- Visibility Category
	local visibilitySubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Visibility")

	local alphaCombatSetting = Register("alphaCombat", Settings.VarType.Number, "Alpha (In Combat)", 1.0, nil, function()
		if NS.UpdateVisibility then
			NS.UpdateVisibility()
		end
	end)
	local alphaCombatOptions = Settings.CreateSliderOptions(0.0, 1.0, 0.05)
	alphaCombatOptions:SetLabelFormatter(labelRight, function(value)
		return (NS.math_floor(value * 100)) .. "%"
	end)
	Settings.CreateSlider(visibilitySubcat, alphaCombatSetting, alphaCombatOptions, "Opacity of the frame when in combat.")

	local alphaOOCSetting = Register("alphaOOC", Settings.VarType.Number, "Alpha (Out of Combat)", 0.5, nil, function()
		if NS.UpdateVisibility then
			NS.UpdateVisibility()
		end
	end)
	local alphaOOCOptions = Settings.CreateSliderOptions(0.0, 1.0, 0.05)
	alphaOOCOptions:SetLabelFormatter(labelRight, function(value)
		return (NS.math_floor(value * 100)) .. "%"
	end)
	Settings.CreateSlider(visibilitySubcat, alphaOOCSetting, alphaOOCOptions, "Opacity of the frame when out of combat.")

	local onlyInCombatSetting = Register("onlyInCombat", Settings.VarType.Boolean, "Only Show in Combat", false, nil, function()
		if NS.UpdateVisibility then
			NS.UpdateVisibility()
		end
	end)
	Settings.CreateCheckbox(visibilitySubcat, onlyInCombatSetting, "Hide the frame completely when not in combat.")

	local hideInVehicleSetting = Register("hideInVehicle", Settings.VarType.Boolean, "Hide in Vehicle", true, nil, function()
		if NS.UpdateVisibility then
			NS.UpdateVisibility()
		end
	end)
	Settings.CreateCheckbox(visibilitySubcat, hideInVehicleSetting, "Hide the frame when in a vehicle.")

	-- Keybinds Category
	local keybindSubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Keybind Text")

	-- Show Keybind
	local showKeybindSetting = Register("showKeybind", Settings.VarType.Boolean, "Show Keybinds", true, nil, function()
		if NS.UpdateNow then
			NS.UpdateNow()
		end
	end)
	Settings.CreateCheckbox(keybindSubcat, showKeybindSetting, "Show the keybind text on the button.")

	-- Keybind Font Size
	local fontSizeSetting = Register("keybindFontSize", Settings.VarType.Number, "Keybind Font Size", 12, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
	end)
	local fontOptions = Settings.CreateSliderOptions(6, 24, 1)
	fontOptions:SetLabelFormatter(labelRight, function(value)
		return value .. "pt"
	end)
	Settings.CreateSlider(keybindSubcat, fontSizeSetting, fontOptions, "Adjust the size of the keybind text.")

	-- Cooldown & Range Subcategory
	local cdRangeSubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Cooldowns & Feedback")

	-- Show Cooldown
	local showCooldownSetting = Register("showCooldown", Settings.VarType.Boolean, "Show Cooldown", true, nil, function()
		if NS.UpdateNow then
			NS.UpdateNow()
		end
	end)
	Settings.CreateCheckbox(cdRangeSubcat, showCooldownSetting, "Show the cooldown animation.")

	-- Custom Cooldown Text Toggle
	local customCdSetting = Register("customCooldownText", Settings.VarType.Boolean, "Custom Countdown Text", true, nil, function()
		if NS.UpdateNow then NS.UpdateNow() end
	end)
	Settings.CreateCheckbox(cdRangeSubcat, customCdSetting, "Use custom high-definition countdown timer text instead of standard numbers.")

	-- Ignore GCD Toggle
	local ignoreGCDSetting = Register("ignoreGCD", Settings.VarType.Boolean, "Ignore GCD on Countdown", false, nil, function()
		if NS.UpdateNow then NS.UpdateNow() end
	end)
	Settings.CreateCheckbox(cdRangeSubcat, ignoreGCDSetting, "Hide the cooldown sweep and countdown text when only the Global Cooldown (GCD) is active.")

	-- Cooldown Font
	local cdFontSetting = Register("cooldownFont", Settings.VarType.String, "Countdown Font Style", "Numeric", nil, function()
		if NS.UpdateLayout then NS.UpdateLayout() end
	end)
	local function GetFontOptions()
		local container = Settings.CreateControlTextContainer()
		container:Add("Numeric", "Numeric (Default)")
		container:Add("Standard", "Standard UI Font")
		container:Add("Bold", "Header Bold Font")
		container:Add("Expressive", "Expressive Shadowed")
		container:Add("Large", "Large Shadowed")
		-- Custom NiceDamage fonts
		container:Add("Expressway", "Expressway")
		container:Add("Roboto Bold", "Roboto Bold")
		container:Add("Denmark", "Denmark")
		container:Add("Prototype", "Prototype")
		container:Add("Zero Cool", "Zero Cool")
		container:Add("Big Noodle", "Big Noodle Titling")
		container:Add("Bangers", "Bangers")
		container:Add("Alte Haas", "Alte Haas")
		container:Add("Gotham Ultra", "Gotham Ultra")
		container:Add("LifeCraft", "LifeCraft")
		container:Add("Pepsi Modern", "Pepsi Modern")
		container:Add("Zero Pixel", "Zero Pixel")
		container:Add("Yikes", "Yikes")
		return container:GetData()
	end
	Settings.CreateDropdown(cdRangeSubcat, cdFontSetting, GetFontOptions, "Select the font style for the custom cooldown text.")

	-- Cooldown Font Size
	local cdFontSizeSetting = Register("cooldownFontSize", Settings.VarType.Number, "Countdown Font Size", 14, nil, function()
		if NS.UpdateLayout then NS.UpdateLayout() end
	end)
	local cdFontSizeOptions = Settings.CreateSliderOptions(6, 30, 1)
	cdFontSizeOptions:SetLabelFormatter(labelRight, function(value) return value .. "pt" end)
	Settings.CreateSlider(cdRangeSubcat, cdFontSizeSetting, cdFontSizeOptions, "Adjust the text size of the cooldown timer.")

	-- Cooldown Outline
	local cdOutlineSetting = Register("cooldownFontOutline", Settings.VarType.String, "Countdown Text Outline", "OUTLINE", nil, function()
		if NS.UpdateLayout then NS.UpdateLayout() end
	end)
	local function GetOutlineOptions()
		local container = Settings.CreateControlTextContainer()
		container:Add("NONE", "None")
		container:Add("OUTLINE", "Outline")
		container:Add("THICKOUTLINE", "Thick Outline")
		return container:GetData()
	end
	Settings.CreateDropdown(cdRangeSubcat, cdOutlineSetting, GetOutlineOptions, "Adjust the outline style of the timer text.")

	-- Sweep Color
	local sweepColorSetting = Register("cooldownSweepColor", Settings.VarType.String, "Sweep Texture Color", "Black", nil, function()
		if NS.UpdateNow then NS.UpdateNow() end
	end)
	local function GetSweepColorOptions()
		local container = Settings.CreateControlTextContainer()
		container:Add("Black", "Standard Dark")
		container:Add("Red", "Crimson Tint")
		container:Add("Blue", "Arcane Tint")
		container:Add("Purple", "Void Purple")
		container:Add("Gray", "Muted Gray")
		return container:GetData()
	end
	Settings.CreateDropdown(cdRangeSubcat, sweepColorSetting, GetSweepColorOptions, "Change the color of the shaded cooldown circular sweep.")

	-- Sweep Opacity
	local sweepAlphaSetting = Register("cooldownSweepAlpha", Settings.VarType.Number, "Sweep Opacity", 0.8, nil, function()
		if NS.UpdateNow then NS.UpdateNow() end
	end)
	local sweepAlphaOptions = Settings.CreateSliderOptions(0.0, 1.0, 0.05)
	sweepAlphaOptions:SetLabelFormatter(labelRight, function(value) return (NS.math_floor(value * 100)) .. "%" end)
	Settings.CreateSlider(cdRangeSubcat, sweepAlphaSetting, sweepAlphaOptions, "Adjust the opacity of the shaded cooldown circular sweep.")

	-- Draw Bling
	local cdBlingSetting = Register("cooldownDrawBling", Settings.VarType.Boolean, "Draw Cooldown Bling", false, nil, function()
		if NS.UpdateNow then NS.UpdateNow() end
	end)
	Settings.CreateCheckbox(cdRangeSubcat, cdBlingSetting, "Toggle the shiny flash when a cooldown finishes.")

	-- Draw Edge
	local cdEdgeSetting = Register("cooldownDrawEdge", Settings.VarType.Boolean, "Draw Cooldown Edge", false, nil, function()
		if NS.UpdateNow then NS.UpdateNow() end
	end)
	Settings.CreateCheckbox(cdRangeSubcat, cdEdgeSetting, "Toggle the bright line on the leading edge of the cooldown sweep.")

	-- Usability Check
	local usabilityCheckSetting = Register("enableUsabilityCheck", Settings.VarType.Boolean, "Enable Usability Color Feedback", true, nil, function()
		if NS.UpdateNow then NS.UpdateNow() end
	end)
	Settings.CreateCheckbox(cdRangeSubcat, usabilityCheckSetting, "Desaturate and darken the spell icon if you lack resources (like Mana or Focus) to cast it.")

	-- Range Check
	local rangeCheckSetting = Register("enableRangeCheck", Settings.VarType.Boolean, "Enable Target Range Tinting", true, nil, function()
		if NS.UpdateNow then NS.UpdateNow() end
	end)
	Settings.CreateCheckbox(cdRangeSubcat, rangeCheckSetting, "Color the icon red when your current target is out of range for the suggested spell.")


	-- Visual Effects Subcategories
	local effectsGeneralSubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Effects - General")
	local effectsNextReadySubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Effects - Next Ready")
	local effectsCooldownReadySubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Effects - Cooldown Ready")
	local effectsProcSubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Effects - Proc Highlight")
	local function RefreshEffects()
		if NS.SyncCleanSettings then NS.SyncCleanSettings() end
		if NS.UpdateNow then NS.UpdateNow() end
	end

	local function GetGlowColorOptions()
		local container = Settings.CreateControlTextContainer()
		container:Add("Gold", "Golden Yellow")
		container:Add("Red", "Crimson Red")
		container:Add("Green", "Poison Green")
		container:Add("Blue", "Arcane Blue")
		container:Add("Purple", "Shadow Purple")
		container:Add("Cyan", "Frost Cyan")
		container:Add("Orange", "Solar Orange")
		container:Add("Pink", "Shocking Pink")
		container:Add("White", "Pure White")
		return container:GetData()
	end

	local effectsCombatSetting = Register("effectsOnlyInCombat", Settings.VarType.Boolean, "Effects Only in Combat", true, nil, RefreshEffects)
	Settings.CreateCheckbox(effectsGeneralSubcat, effectsCombatSetting, "Play visual effects only while the player is in combat.")

	local bounceScaleSetting = Register("bounceScale", Settings.VarType.Number, "Bounce Strength", 1.10, nil, RefreshEffects)
	local bounceScaleOptions = Settings.CreateSliderOptions(1.02, 1.25, 0.01)
	bounceScaleOptions:SetLabelFormatter(labelRight, function(value) return (NS.math_floor(value * 100)) .. "%" end)
	Settings.CreateSlider(effectsGeneralSubcat, bounceScaleSetting, bounceScaleOptions, "Peak scale used by any enabled bounce effect.")

		local flashSetting = Register("enableFlashOverlay", Settings.VarType.Boolean, "Next Ready Flash", true, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsNextReadySubcat, flashSetting, "Flash once when the recommendation changes to a ready spell.")

		local nextPulseSetting = Register("effectNextReadyPulseEnabled", Settings.VarType.Boolean, "Next Ready Focus Pulse", true, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsNextReadySubcat, nextPulseSetting, "Play a short minimal focus pulse when the next recommendation is ready.")

		local bounceSetting = Register("enableBounceAnim", Settings.VarType.Boolean, "Next Ready Bounce", false, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsNextReadySubcat, bounceSetting, "Apply a short smooth scale pop when the recommendation changes to a ready spell.")

		local readyFlashSetting = Register("effectReadyFlashEnabled", Settings.VarType.Boolean, "Cooldown Finished Flash", true, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsCooldownReadySubcat, readyFlashSetting, "Flash once when the current spell leaves its own cooldown.")

		local readyPulseSetting = Register("effectReadyPulseEnabled", Settings.VarType.Boolean, "Cooldown Finished Focus Pulse", true, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsCooldownReadySubcat, readyPulseSetting, "Play a short minimal focus pulse when the current spell becomes ready again.")

		local readyBounceSetting = Register("effectReadyBounceEnabled", Settings.VarType.Boolean, "Cooldown Finished Bounce", false, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsCooldownReadySubcat, readyBounceSetting, "Apply the short smooth scale pop when the current spell becomes ready again.")

		local glowReadyColorSetting = Register("glowReadyColor", Settings.VarType.String, "Ready Event Color", "Gold", nil, RefreshEffects)
		Settings.CreateDropdown(effectsCooldownReadySubcat, glowReadyColorSetting, GetGlowColorOptions, "Color for cooldown-finished focus effects.")

		local glowProcToggle = Register("glowProcEnabled", Settings.VarType.Boolean, "Enable Proc Effect", true, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsProcSubcat, glowProcToggle, "Show a persistent effect while the recommended spell is proc-highlighted.")

		local function GetProcGlowTypeOptions()
			local container = Settings.CreateControlTextContainer()
			container:Add("blizzardProc", "Blizzard Proc Glow")
			container:Add("sweepBorder", "Sweep Line Glow")
			container:Add("focusPulse", "Minimal Focus Glow")
			container:Add("none", "Disable Proc Glow")
			return container:GetData()
		end
		local glowProcTypeSetting = Register("glowProcType", Settings.VarType.String, "Proc Effect Style", "blizzardProc", nil, RefreshEffects)
		Settings.CreateDropdown(effectsProcSubcat, glowProcTypeSetting, GetProcGlowTypeOptions, "Persistent visual used while a proc is active.")

		local glowProcColorSetting = Register("glowProcColor", Settings.VarType.String, "Proc Effect Color", "White", nil, RefreshEffects)
		Settings.CreateDropdown(effectsProcSubcat, glowProcColorSetting, GetGlowColorOptions, "Color used by Sweep Line and Minimal Focus proc styles.")

		local procFlashSetting = Register("effectProcFlashEnabled", Settings.VarType.Boolean, "Proc Start Flash", false, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsProcSubcat, procFlashSetting, "Flash once when the recommended spell gains a proc highlight.")

		local procBounceSetting = Register("effectProcBounceEnabled", Settings.VarType.Boolean, "Proc Start Bounce", false, nil, RefreshEffects)
		Settings.CreateCheckbox(effectsProcSubcat, procBounceSetting, "Apply the short smooth scale pop when the recommended spell gains a proc highlight.")


	-- Logic Category
	local logicSubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Recommendation Logic")

	-- Visible Button Check
	local visibleSetting = Register("checkVisibleButton", Settings.VarType.Boolean, "Check Visible Buttons", true)
	Settings.CreateCheckbox(logicSubcat, visibleSetting, "Only suggest spells that are currently visible on your action bars.")

	-- Avada Tracker Settings
	local avadaSubcat = Settings.RegisterVerticalLayoutSubcategory(category, "Avada Tracker")

	-- Avada Enabled
	local avadaEnabledSetting = Register("avadaEnabled", Settings.VarType.Boolean, "Enable Avada Tracker", true, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
		if NS.UpdateNow then
			NS.UpdateNow()
		end
	end)
	Settings.CreateCheckbox(avadaSubcat, avadaEnabledSetting, "Track important class-specific spells below the suggestion button.")

	-- Avada Size
	local avadaSizeSetting = Register("avadaSize", Settings.VarType.Number, "Icon Size", 16, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
	end)
	local avadaSizeOptions = Settings.CreateSliderOptions(10, 40, 1)
	avadaSizeOptions:SetLabelFormatter(labelRight, function(value)
		return value .. "px"
	end)
	Settings.CreateSlider(avadaSubcat, avadaSizeSetting, avadaSizeOptions, "Adjust the size of the Avada tracker icons.")

	-- Avada Spacing
	local avadaSpacingSetting = Register("avadaSpacing", Settings.VarType.Number, "Spacing", 4, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
	end)
	local avadaSpacingOptions = Settings.CreateSliderOptions(0, 10, 1)
	avadaSpacingOptions:SetLabelFormatter(labelRight, function(value)
		return value .. "px"
	end)
	Settings.CreateSlider(avadaSubcat, avadaSpacingSetting, avadaSpacingOptions, "Spacing between icons.")

	-- Avada Offset Y
	local avadaOffsetYSetting = Register("avadaOffsetY", Settings.VarType.Number, "Vertical Offset", -10, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
	end)
	local avadaOffsetYOptions = Settings.CreateSliderOptions(-50, 50, 1)
	avadaOffsetYOptions:SetLabelFormatter(labelRight, function(value)
		return value .. "px"
	end)
	Settings.CreateSlider(avadaSubcat, avadaOffsetYSetting, avadaOffsetYOptions, "Vertical position relative to the main button.")

	-- Avada Border
	local avadaBorderSetting = Register("avadaShowBorder", Settings.VarType.Boolean, "Show Border", true, nil, function()
		if NS.UpdateLayout then
			NS.UpdateLayout()
		end
	end)
	Settings.CreateCheckbox(avadaSubcat, avadaBorderSetting, "Show a border around the Avada icons.")

	Settings.RegisterAddOnCategory(category)
	NS.SettingsCategory = category
end

-- ---------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------
SLASH_BUTTONASSISTANTENCHANCED1 = "/buttonassistantenchanced"
SLASH_BUTTONASSISTANTENCHANCED2 = "/bae"
SLASH_BUTTONASSISTANTENCHANCED3 = "/baenchanced"

SlashCmdList.BUTTONASSISTANTENCHANCED = function(msg)
	msg = msg and NS.string_lower(msg) or ""

	if msg == "toggle" then
		NS.db.enabled = not NS.db.enabled
		if NS.UpdateNow then
			NS.UpdateNow()
		end
		return
	end

	if msg == "errors" or msg == "logs" or msg == "error" then
		if ButtonAssistantEnchancedDB and ButtonAssistantEnchancedDB.errors and #ButtonAssistantEnchancedDB.errors > 0 then
			print("|cff4e84b1[Button Assistant Enchanced Logs]|r Displaying last 20 caught errors:")
			for i, err in ipairs(ButtonAssistantEnchancedDB.errors) do
				print(("[%s] %s"):format(err.time, err.err))
			end
		else
			print("|cff4e84b1[Button Assistant Enchanced Logs]|r No errors recorded. Addon is running smoothly!")
		end
		return
	end

	-- Open Settings Panel
	if Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(NS.SettingsCategory:GetID())
	end
end

-- Avada Config Slash Command
SLASH_BUTTONASSISTANTENCHANCED_AVADA1 = "/baeavada"
SlashCmdList.BUTTONASSISTANTENCHANCED_AVADA = function()
	if NS.SetupAvada then
		NS.SetupAvada()
	end
end
