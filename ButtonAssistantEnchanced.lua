-- ButtonAssistantEnchanced
-- Shows Blizzard Assisted Combat recommendations + keybinds (no Ace3)

local ADDON_NAME, NS = ...
local COOLDOWN_MODEL_VERSION = 2
local EFFECT_MODEL_VERSION = 5

-- Forward declarations of local clean functions
local UpdateButton
local UpdateCooldownForSpell
local UpdateAvada

-- Clean safe call for OnUpdate
local function SafeCallClean(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		print("|cff4e84b1[Button Assistant Enchanced Clean Error]|r " .. tostring(err))
	end
	return ok
end

-- Self-tracking Cooldown Engine (Bypasses secure sandboxing & secret values)
local cleanRecommendedSpellID = nil
local activeCooldowns = {}
local pendingCooldowns = {}
local gcdStartTime = 0
local gcdDuration = 0
local cleanGCDDuration = 1.0 -- Cached out-of-combat
local clean_ignoreGCD = false
local cachedBaseCooldowns = {} -- Stores unhasted base durations and haste flags: { baseDuration = X, haste = Y }
local cachedActionSlots = {}
local IsDurationObjectZero
local cooldownVisualSerial = 0

local function GetGCDDurationClean()
	return cleanGCDDuration
end

local function InvalidateCooldownVisuals()
	cooldownVisualSerial = cooldownVisualSerial + 1
end

local function GetSpellBaseCooldownMSClean(spellID)
	if not spellID then
		return nil
	end

	local api = C_Spell and C_Spell.GetSpellBaseCooldown
	if api then
		local ok, baseMS = pcall(api, spellID)
		if ok and type(baseMS) == "number" then
			return baseMS
		end
	end

	if type(GetSpellBaseCooldown) == "function" then
		local ok, baseMS = pcall(GetSpellBaseCooldown, spellID)
		if ok and type(baseMS) == "number" then
			return baseMS
		end
	end

	return nil
end

-- Local cache pointers to C-APIs and helper functions (populated on ADDON_LOADED)
local local_GetAvadaTargetList
local local_C_Spell_GetSpellTexture
local local_AvadaReplacedTexture
local local_C_ActionBar_FindSpellActionButtons
local local_C_ActionBar_GetActionCooldownDuration
local local_C_ActionBar_GetActionChargeDuration
local local_C_Item_GetItemIconByID
local local_GetAuraInfo
local local_AvadaValueSpells
local local_FormatNumber
local local_C_Spell_GetSpellCooldown
local local_C_Spell_GetSpellCooldownDuration
local local_C_Spell_GetSpellCooldownRemaining
local local_C_Spell_GetSpellCharges
local local_C_Spell_GetSpellChargeDuration
local local_C_Item_GetItemCooldown
local local_C_Item_GetItemCount
local local_AvadaGemini
local local_IsSpellKnown
local local_GetKeyBindForSpellID
local local_SweepColors
local local_GlowColors
local local_FontList

local function GetSpellBaseDurationClean(baseID)
	if not baseID then return 0, false end

	local baseCD = GetSpellBaseCooldownMSClean(baseID)
	if baseCD and baseCD > 0 then
		local isHasted = (baseCD < 60000)
		return baseCD / 1000, isHasted
	end
	
	return 0, false
end

local function CacheSpellCooldown(spellID)
	if not spellID or InCombatLockdown() then return end
	if not C_Spell or not C_Spell.GetSpellCooldown then return end
	
	local baseID = FindBaseSpellByID(spellID) or spellID
	local cd = C_Spell.GetSpellCooldown(baseID)
	
	-- 1. If currently on cooldown, populate activeCooldowns AND cache the duration
	if cd and cd.startTime and cd.duration and cd.duration > 1.5 then
		activeCooldowns[baseID] = {
			startTime = cd.startTime,
			duration = cd.duration
		}
		
		local haste = GetHaste() or 0
		local unhastedDuration = cd.duration * (1 + haste / 100)
		local isHasted = (unhastedDuration < 60)
		
		cachedBaseCooldowns[baseID] = {
			baseDuration = unhastedDuration,
			haste = isHasted
		}
	end
	
	-- 2. If it has charges, cache the charge duration
	if C_Spell.GetSpellCharges then
		local chargesInfo = C_Spell.GetSpellCharges(baseID)
		if chargesInfo and chargesInfo.cooldownDuration and chargesInfo.cooldownDuration > 1.5 then
			local haste = GetHaste() or 0
			local unhastedDuration = chargesInfo.cooldownDuration * (1 + haste / 100)
			local isHasted = (unhastedDuration < 60)
			
			cachedBaseCooldowns[baseID] = {
				baseDuration = unhastedDuration,
				haste = isHasted
			}
		end
	end
	
	-- 3. If still not in cachedBaseCooldowns, populate using GetSpellBaseDurationClean
	if not cachedBaseCooldowns[baseID] then
		local baseCD, isHasted = GetSpellBaseDurationClean(baseID)
		if baseCD and baseCD > 0 then
			cachedBaseCooldowns[baseID] = {
				baseDuration = baseCD,
				haste = isHasted
			}
		end
	end

	if cachedBaseCooldowns[baseID] and baseID ~= spellID then
		cachedBaseCooldowns[spellID] = cachedBaseCooldowns[baseID]
	end
end

local function ScanSpellBookCooldowns()
	if InCombatLockdown() then return end
	if not C_SpellBook or not C_SpellBook.GetNumSpellBookSkillLines then return end
	
	pcall(function()
		local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
		for skillLineIndex = 1, numSkillLines do
			local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(skillLineIndex)
			if skillLineInfo then
				local offset = skillLineInfo.itemIndexOffset or 0
				local numSlots = skillLineInfo.numSpellBookItems or 0
				for i = 1, numSlots do
					local slotIndex = offset + i
					local spellType, spellID = C_SpellBook.GetSpellBookItemType(slotIndex, Enum.SpellBookSpellBank.Player)
					if spellID and (spellType == Enum.SpellBookItemType.Spell or spellType == Enum.SpellBookItemType.Flyout) then
						CacheSpellCooldown(spellID)
					end
				end
			end
		end
	end)
end

local function ScanActionBarCooldowns()
	if InCombatLockdown() then return end
	pcall(function()
		for slot = 1, 120 do
			local actionType, id = GetActionInfo(slot)
			if actionType == "spell" and id then
				CacheSpellCooldown(id)
			elseif actionType == "macro" and id then
				local _, _, spellID = GetMacroSpell(id)
				if spellID then
					CacheSpellCooldown(spellID)
				end
			end
		end
	end)
end

local function ScanAllCooldowns()
	if InCombatLockdown() then return end
	
	-- 1. Scan spellbook and action bars
	ScanSpellBookCooldowns()
	ScanActionBarCooldowns()
	
	-- 2. Scan Avada Tracker spells
	local list = local_GetAvadaTargetList and local_GetAvadaTargetList()
	if list then
		for _, data in ipairs(list) do
			if data.spellID and data.type == "cd" then
				CacheSpellCooldown(data.spellID)
			end
		end
	end
	
	-- 3. Scan current recommended spell
	if cleanRecommendedSpellID then
		CacheSpellCooldown(cleanRecommendedSpellID)
	end
end

local function GetSpellCooldownDurationClean(spellID)
	if not spellID then return 0 end
	local baseID = FindBaseSpellByID(spellID) or spellID
	
	local cached = cachedBaseCooldowns[baseID] or (baseID ~= spellID and cachedBaseCooldowns[spellID])
	if cached and cached.baseDuration and cached.baseDuration > 0 then
		if cached.haste then
			return cached.baseDuration * cleanGCDDuration / 1.5
		else
			return cached.baseDuration
		end
	end
	
	-- Double fallback: if not in cache (e.g. dynamically learned or custom cast)
	local baseCD, isHasted = GetSpellBaseDurationClean(baseID)
	if baseCD and baseCD > 0 then
		if isHasted then
			return baseCD * cleanGCDDuration / 1.5
		else
			return baseCD
		end
	end
	
	return 0
end

local function StartTrackedSpellCooldown(spellID, now)
	if not spellID then
		return false
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local baseMS = GetSpellBaseCooldownMSClean(baseID)
	if not baseMS or baseMS <= 1500 then
		baseMS = GetSpellBaseCooldownMSClean(spellID)
	end

	local duration = 0
	if baseMS and baseMS > 1500 then
		duration = baseMS / 1000
		if baseMS < 60000 then
			duration = duration * (cleanGCDDuration / 1.5)
		end
		cachedBaseCooldowns[baseID] = {
			baseDuration = baseMS / 1000,
			haste = baseMS < 60000,
		}
		if baseID ~= spellID then
			cachedBaseCooldowns[spellID] = cachedBaseCooldowns[baseID]
		end
	else
		duration = GetSpellCooldownDurationClean(baseID)
		if not duration or duration <= 1.5 then
			duration = GetSpellCooldownDurationClean(spellID)
		end
	end

	if duration and duration > 1.5 then
		local entry = {
			startTime = now or GetTime(),
			duration = duration
		}
		activeCooldowns[baseID] = entry
		activeCooldowns[spellID] = entry
		return true
	end

	return false
end

local function RetryPendingSpellCooldown(key)
	local pending = pendingCooldowns[key]
	if not pending then
		return
	end

	if StartTrackedSpellCooldown(pending.spellID, pending.startTime) then
		pendingCooldowns[key] = nil
		return
	end

	pending.attempts = (pending.attempts or 0) + 1
	local delays = { 0.03, 0.08, 0.16, 0.32, 0.55 }
	local delay = delays[pending.attempts]
	if not delay or not NS.C_Timer_After then
		pendingCooldowns[key] = nil
		return
	end

	NS.C_Timer_After(delay, function()
		RetryPendingSpellCooldown(key)
	end)
end

local function QueueTrackedSpellCooldown(spellID, startTime)
	if not spellID then
		return
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local key = baseID or spellID
	pendingCooldowns[key] = {
		spellID = spellID,
		startTime = startTime or GetTime(),
		attempts = 0,
	}

	RetryPendingSpellCooldown(key)
end

local function RetryPendingSpellCooldowns()
	local keys = {}
	for key in pairs(pendingCooldowns) do
		keys[#keys + 1] = key
	end

	for _, key in ipairs(keys) do
		RetryPendingSpellCooldown(key)
	end
end

-- Clean local getter for cooldowns (In combat uses self-tracked numbers, Out of combat uses C-APIs)
local function GetSpellCooldownClean(spellID)
	local now = GetTime()
	local baseID = FindBaseSpellByID(spellID) or spellID
	if not clean_ignoreGCD and gcdStartTime + gcdDuration > now then
		return gcdStartTime, gcdDuration
	end

	if not InCombatLockdown() then
		-- Out of combat: use native C_Spell.GetSpellCooldown which returns standard numbers!
		if C_Spell and C_Spell.GetSpellCooldown then
			local cd = C_Spell.GetSpellCooldown(baseID)
			if cd and cd.startTime and cd.duration then
				return cd.startTime, cd.duration
			end
		end
	else
		-- In combat: use our self-tracked activeCooldowns
		local cd = activeCooldowns[baseID] or (baseID ~= spellID and activeCooldowns[spellID])
		if cd then
			local remaining = cd.startTime + cd.duration - now
			if remaining > 0 then
				return cd.startTime, cd.duration
			else
				activeCooldowns[baseID] = nil
				if baseID ~= spellID then
					activeCooldowns[spellID] = nil
				end
			end
		end
	end
	return 0, 0
end

-- Clean Local Copy of Settings
local clean_enabled = true
local clean_buttonSize = 40
local clean_showKeybind = true
local clean_keybindFontSize = 12
local clean_showCooldown = true
local clean_showBorder = true
local clean_customCooldownText = true
local clean_cooldownFont = "Numeric"
local clean_cooldownFontSize = 14
local clean_cooldownFontOutline = "OUTLINE"
local clean_cooldownSweepColor = "Black"
local clean_cooldownSweepAlpha = 0.8
local clean_cooldownDrawBling = false
local clean_cooldownDrawEdge = false
clean_ignoreGCD = false
local clean_enableUsabilityCheck = true
local clean_enableRangeCheck = true
local clean_glowReadyEnabled = false
local clean_glowReadyType = "none"
local clean_glowReadyColor = "Gold"
local clean_glowProcEnabled = true
local clean_glowProcType = "blizzardProc"
local clean_glowProcColor = "White"
local clean_scale = 1.0
local clean_enableBounceAnim = false
local clean_bounceScale = 1.10
local clean_enableFlashOverlay = true
local clean_effectsOnlyInCombat = true
local clean_effectNextReadyPulseEnabled = true
local clean_effectReadyBounceEnabled = false
local clean_effectReadyFlashEnabled = true
local clean_effectReadyPulseEnabled = true
local clean_effectProcBounceEnabled = false
local clean_effectProcFlashEnabled = false
local clean_avadaEnabled = true

function NS.SyncCleanSettings()
	if not NS.db then return end
	clean_enabled = NS.db.enabled
	clean_buttonSize = NS.db.buttonSize or 40
	clean_showKeybind = NS.db.showKeybind
	clean_keybindFontSize = NS.db.keybindFontSize or 12
	clean_showCooldown = NS.db.showCooldown
	clean_showBorder = NS.db.showBorder
	clean_customCooldownText = NS.db.customCooldownText
	clean_cooldownFont = NS.db.cooldownFont or "Numeric"
	clean_cooldownFontSize = NS.db.cooldownFontSize or 14
	clean_cooldownFontOutline = NS.db.cooldownFontOutline or "OUTLINE"
	clean_cooldownSweepColor = NS.db.cooldownSweepColor or "Black"
	clean_cooldownSweepAlpha = NS.db.cooldownSweepAlpha or 0.8
	clean_cooldownDrawBling = NS.db.cooldownDrawBling
	clean_cooldownDrawEdge = NS.db.cooldownDrawEdge
	clean_ignoreGCD = NS.db.ignoreGCD
	clean_enableUsabilityCheck = NS.db.enableUsabilityCheck
	clean_enableRangeCheck = NS.db.enableRangeCheck
	clean_glowReadyEnabled = NS.db.glowReadyEnabled
	clean_glowReadyType = NS.db.glowReadyType or "none"
	clean_glowReadyColor = NS.db.glowReadyColor or "Gold"
	clean_glowProcEnabled = NS.db.glowProcEnabled
	clean_glowProcType = NS.db.glowProcType or "blizzardProc"
	if clean_glowProcType == "blizzard" or clean_glowProcType == "Proc" then
		clean_glowProcType = "blizzardProc"
	elseif clean_glowProcType == "neon" or clean_glowProcType == "border" then
		clean_glowProcType = "focusPulse"
	end
	clean_glowProcColor = NS.db.glowProcColor or "White"
	clean_scale = NS.db.scale or 1.0
	clean_enableBounceAnim = NS.db.enableBounceAnim
	clean_bounceScale = NS.db.bounceScale or 1.10
	clean_enableFlashOverlay = NS.db.enableFlashOverlay
	clean_effectsOnlyInCombat = NS.db.effectsOnlyInCombat
	clean_effectNextReadyPulseEnabled = NS.db.effectNextReadyPulseEnabled
	clean_effectReadyBounceEnabled = NS.db.effectReadyBounceEnabled
	clean_effectReadyFlashEnabled = NS.db.effectReadyFlashEnabled
	clean_effectReadyPulseEnabled = NS.db.effectReadyPulseEnabled
	clean_effectProcBounceEnabled = NS.db.effectProcBounceEnabled
	clean_effectProcFlashEnabled = NS.db.effectProcFlashEnabled
	clean_avadaEnabled = NS.db.avadaEnabled

	-- Cache clean hasted GCD duration out-of-combat
	if not InCombatLockdown() then
		local haste = GetHaste() or 0
		cleanGCDDuration = 1.5 / (1 + haste / 100)
		if cleanGCDDuration < 0.75 then
			cleanGCDDuration = 0.75
		elseif cleanGCDDuration > 1.5 then
			cleanGCDDuration = 1.5
		end
	end
end

-- ---------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------
local addonFrame = NS.CreateFrame("Frame", "ButtonAssistantEnchancedEventFrame")
local frame = NS.CreateFrame("Frame", "ButtonAssistantEnchancedFrame", NS.UIParent, "BackdropTemplate")
NS.frame = frame

frame:SetPoint("CENTER", NS.UIParent, "CENTER", 0, -120)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)

frame:SetScript("OnDragStart", function(self)
	if NS.db.locked then
		return
	end
	if NS.InCombatLockdown and NS.InCombatLockdown() then
		return
	end
	self:StartMoving()
end)

frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
end)

local function IsSecretValue(val)
	if issecretvalue then
		local ok, secret = pcall(issecretvalue, val)
		if ok then
			return secret == true
		end
	end

	local ok = pcall(function()
		if val ~= nil then
			local _ = val == val
			if type(val) == "number" then
				local __ = val + 0
			end
		end
	end)
	return not ok
end

local function IsCleanNumber(val)
	local ok, valType = pcall(type, val)
	return ok and valType == "number" and not IsSecretValue(val)
end

local function IsCleanBoolean(val)
	local ok, valType = pcall(type, val)
	return ok and valType == "boolean" and not IsSecretValue(val)
end

local function IsPositiveCleanNumber(val)
	return IsCleanNumber(val) and val > 0
end

IsDurationObjectZero = function(durationObject)
	if not durationObject or not durationObject.IsZero then
		return nil
	end

	local ok, isZero = pcall(durationObject.IsZero, durationObject)
	if ok and not IsSecretValue(isZero) then
		return isZero == true
	end

	return nil
end

local function ClearActionSlotCache()
	for k in pairs(cachedActionSlots) do
		cachedActionSlots[k] = nil
	end
end

local function GetCachedActionSlotsForSpell(spellID)
	if not spellID or not local_C_ActionBar_FindSpellActionButtons then
		return nil
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local cacheKey = tostring(spellID) .. ":" .. tostring(baseID)
	if cachedActionSlots[cacheKey] then
		return cachedActionSlots[cacheKey]
	end
	if InCombatLockdown() then
		return nil
	end

	local slots = {}
	local function collect(id)
		if not id then
			return
		end

		local ok, found = pcall(local_C_ActionBar_FindSpellActionButtons, id)
		if ok and type(found) == "table" then
			for _, slot in ipairs(found) do
				if IsCleanNumber(slot) then
					slots[#slots + 1] = slot
				end
			end
		end
	end

	collect(spellID)
	if baseID ~= spellID then
		collect(baseID)
	end

	cachedActionSlots[cacheKey] = slots
	return slots
end

local function TryActionDurationObject(api, slot, ignoreGCD)
	if not api or not slot then
		return nil
	end

	local ok, durationObject
	if ignoreGCD ~= nil then
		ok, durationObject = pcall(api, slot, ignoreGCD)
	else
		ok, durationObject = pcall(api, slot)
	end

	if ok and durationObject and IsDurationObjectZero(durationObject) == false then
		return durationObject
	end

	return nil
end

local function GetActionDurationObjectForSpell(spellID, preferCharges)
	if InCombatLockdown() then
		return nil
	end

	local slots = GetCachedActionSlotsForSpell(spellID)
	if not slots or #slots == 0 then
		return nil
	end

	for _, slot in ipairs(slots) do
		local durationObject
		if preferCharges then
			durationObject = TryActionDurationObject(local_C_ActionBar_GetActionChargeDuration, slot)
		end

		if not durationObject then
			durationObject = TryActionDurationObject(local_C_ActionBar_GetActionCooldownDuration, slot, true)
		end

		if not durationObject and not preferCharges then
			durationObject = TryActionDurationObject(local_C_ActionBar_GetActionChargeDuration, slot)
		end

		if durationObject then
			return durationObject
		end
	end

	return nil
end

local function ClearTrackedSpellCooldown(spellID)
	if not spellID then return end
	local baseID = FindBaseSpellByID(spellID) or spellID
	activeCooldowns[baseID] = nil
	if baseID ~= spellID then
		activeCooldowns[spellID] = nil
	end
end

local function GetCooldownRemainingForText(spellID)
	local api = local_C_Spell_GetSpellCooldownRemaining or (C_Spell and C_Spell.GetSpellCooldownRemaining)
	if not api or not spellID then
		return nil
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local ok, remaining = pcall(api, baseID)
	if (not ok or not IsPositiveCleanNumber(remaining)) and baseID ~= spellID then
		ok, remaining = pcall(api, spellID)
	end

	if ok and IsPositiveCleanNumber(remaining) then
		return remaining
	end

	return nil
end

local function ReadSpellCooldownStateForID(api, spellID)
	if not api or not spellID then
		return false
	end

	local ok, cooldownInfo = pcall(api, spellID)
	if not ok or type(cooldownInfo) ~= "table" then
		return false
	end

	local startTime = cooldownInfo.startTime
	local duration = cooldownInfo.duration
	local isOnGCD = cooldownInfo.isOnGCD
	if not IsCleanNumber(startTime) or not IsCleanNumber(duration) then
		return false
	end

	if not IsCleanBoolean(isOnGCD) and isOnGCD ~= nil then
		return false
	end

	local active = startTime > 0 and duration > 0
	return true, active, isOnGCD == true
end

local function GetCleanSpellCooldownState(spellID)
	local api = local_C_Spell_GetSpellCooldown or (C_Spell and C_Spell.GetSpellCooldown)
	if not api or not spellID then
		return false
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local sawInactive = false
	local sawGCD = false

	local known, active, onGCD = ReadSpellCooldownStateForID(api, spellID)
	if known then
		if active and not onGCD then
			return true, true, false
		elseif active and onGCD then
			sawGCD = true
		else
			sawInactive = true
		end
	end

	if baseID ~= spellID then
		known, active, onGCD = ReadSpellCooldownStateForID(api, baseID)
		if known then
			if active and not onGCD then
				return true, true, false
			elseif active and onGCD then
				sawGCD = true
			else
				sawInactive = true
			end
		end
	end

	if sawGCD then
		return true, true, true
	end

	if sawInactive then
		return true, false, false
	end

	return false
end

local function ReadSpellChargeStateForID(api, spellID)
	if not api or not spellID then
		return false
	end

	local ok, chargesInfo = pcall(api, spellID)
	if not ok or type(chargesInfo) ~= "table" then
		return false
	end

	local charges = chargesInfo.currentCharges
	local maxCharges = chargesInfo.maxCharges
	if not IsCleanNumber(charges) or not IsCleanNumber(maxCharges) then
		return false
	end

	local isActive = chargesInfo.isActive
	local isOnGCD = chargesInfo.isOnGCD
	if IsCleanBoolean(isActive) and IsCleanBoolean(isOnGCD) then
		return true, isActive == true, isOnGCD == true, charges, maxCharges
	end

	if IsCleanBoolean(isActive) and isOnGCD == nil then
		return true, isActive == true, false, charges, maxCharges
	end

	if maxCharges > 1 then
		return true, charges < maxCharges, false, charges, maxCharges
	end

	return true, false, false, charges, maxCharges
end

local function GetCleanSpellChargeState(spellID)
	local api = local_C_Spell_GetSpellCharges or (C_Spell and C_Spell.GetSpellCharges)
	if not api or not spellID then
		return false
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local known, active, onGCD, charges, maxCharges = ReadSpellChargeStateForID(api, spellID)
	if known and active and not onGCD then
		return true, true, false, charges, maxCharges
	end

	if baseID ~= spellID then
		local baseKnown, baseActive, baseOnGCD, baseCharges, baseMaxCharges = ReadSpellChargeStateForID(api, baseID)
		if baseKnown and baseActive and not baseOnGCD then
			return true, true, false, baseCharges, baseMaxCharges
		end
		if not known and baseKnown then
			return true, baseActive, baseOnGCD, baseCharges, baseMaxCharges
		end
	end

	if known then
		return true, active, onGCD, charges, maxCharges
	end

	return false
end

local function ShouldUseNativeCooldownObject(spellID, preferCharges)
	if preferCharges then
		local chargesKnown, chargeActive, chargeOnGCD = GetCleanSpellChargeState(spellID)
		if chargesKnown and chargeActive and not chargeOnGCD then
			return true
		end
	end

	local known, active, onGCD = GetCleanSpellCooldownState(spellID)
	if known then
		return active and not onGCD
	end

	return false
end

local function SyncTrackedCooldownsFromNativeState()
	local tracked = {}
	for spellID in pairs(activeCooldowns) do
		tracked[#tracked + 1] = spellID
	end

	for _, spellID in ipairs(tracked) do
		local known, active, onGCD = GetCleanSpellCooldownState(spellID)
		if known and (not active or onGCD) then
			ClearTrackedSpellCooldown(spellID)
		end
	end
end

local function ApplyCustomCooldownText(fontString, remaining)
	if not fontString or not IsPositiveCleanNumber(remaining) then
		return false
	end

	local text, r, g, b = "", 1, 1, 1
	if remaining < 3 then
		text = ("%.1f"):format(remaining)
		r, g, b = 1, 0.2, 0.2
	elseif remaining < 10 then
		text = ("%d"):format(remaining)
		r, g, b = 1, 0.82, 0
	elseif remaining < 60 then
		text = ("%d"):format(remaining)
		r, g, b = 1, 1, 1
	else
		text = ("%dm"):format(math.ceil(remaining / 60))
		r, g, b = 0.7, 0.7, 0.7
	end

	fontString:SetText(text)
	fontString:SetTextColor(r, g, b)
	fontString:Show()
	return true
end

local function ApplyCooldownCountdownFont(cooldownFrame)
	if not cooldownFrame or not cooldownFrame.GetCountdownFontString then
		return
	end

	local ok, fontString = pcall(cooldownFrame.GetCountdownFontString, cooldownFrame)
	if not ok or not fontString then
		return
	end

	local fontKey = clean_cooldownFont
	if type(fontKey) ~= "string" or not local_FontList or not local_FontList[fontKey] then
		fontKey = "Numeric"
	end

	local fontVal = local_FontList and local_FontList[fontKey] or "NumberFontNormal"
	local size = clean_cooldownFontSize or 14
	local outline = clean_cooldownFontOutline or "OUTLINE"

	if type(fontVal) == "string" and fontVal:find("Interface\\") then
		fontString:SetFont(fontVal, size, outline)
	else
		fontString:SetFontObject(fontVal or "NumberFontNormal")
		local customPath = fontString:GetFont()
		if customPath then
			fontString:SetFont(customPath, size, outline)
		end
	end
end

local function TryGetDurationObject(api, spellID)
	if not api or not spellID then
		return nil
	end

	local ok, durationObject = pcall(api, spellID, true)
	if ok and durationObject then
		return durationObject
	end

	return nil
end

local function TryGetSpellCooldownDurationObject(spellID, ignoreGCD)
	local api = local_C_Spell_GetSpellCooldownDuration or (C_Spell and C_Spell.GetSpellCooldownDuration)
	if not api or not spellID then
		return nil
	end

	local ok, durationObject
	if ignoreGCD then
		ok, durationObject = pcall(api, spellID, true)
	else
		ok, durationObject = pcall(api, spellID)
	end

	if ok and durationObject then
		return durationObject
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	if baseID ~= spellID then
		if ignoreGCD then
			ok, durationObject = pcall(api, baseID, true)
		else
			ok, durationObject = pcall(api, baseID)
		end
		if ok and durationObject then
			return durationObject
		end
	end

	return nil
end

local function TryGetSpellChargeDurationObject(spellID)
	local api = local_C_Spell_GetSpellChargeDuration or (C_Spell and C_Spell.GetSpellChargeDuration)
	if not api or not spellID then
		return nil
	end

	local ok, durationObject = pcall(api, spellID)
	if ok and durationObject then
		return durationObject
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	if baseID ~= spellID then
		ok, durationObject = pcall(api, baseID)
		if ok and durationObject then
			return durationObject
		end
	end

	return nil
end

local function GetBestDurationObject(api, primaryID, fallbackID)
	local first = TryGetDurationObject(api, primaryID)
	local firstZero = first and IsDurationObjectZero(first)
	if first and firstZero == false then
		return first
	end

	local second
	local secondZero
	if fallbackID and fallbackID ~= primaryID then
		second = TryGetDurationObject(api, fallbackID)
		secondZero = second and IsDurationObjectZero(second)
		if second and (secondZero == false or firstZero == true) then
			return second
		end
	end

	return first or second
end

local function TryApplySpellCooldownDurationObject(cooldownFrame, spellID, preferCharges, requireRealCooldown)
	if not cooldownFrame or not spellID or not cooldownFrame.SetCooldownFromDurationObject then
		return false
	end

	local cooldownAPI = local_C_Spell_GetSpellCooldownDuration or (C_Spell and C_Spell.GetSpellCooldownDuration)
	local chargeAPI = local_C_Spell_GetSpellChargeDuration or (C_Spell and C_Spell.GetSpellChargeDuration)
	local durationObject = GetActionDurationObjectForSpell(spellID, preferCharges)
	if not durationObject and not cooldownAPI and not chargeAPI then
		return false
	end

	local baseID = FindBaseSpellByID(spellID) or spellID

	if preferCharges and not durationObject then
		durationObject = GetBestDurationObject(chargeAPI, baseID, spellID)
	end

	if not durationObject then
		durationObject = GetBestDurationObject(cooldownAPI, baseID, spellID)
	end

	if not durationObject and not preferCharges then
		durationObject = GetBestDurationObject(chargeAPI, baseID, spellID)
	end

	if not durationObject then
		return false
	end

	if requireRealCooldown and IsDurationObjectZero(durationObject) == true and ShouldUseNativeCooldownObject(spellID, preferCharges) == false then
		return false
	end

	local isZero = IsDurationObjectZero(durationObject)
	local ok = pcall(cooldownFrame.SetCooldownFromDurationObject, cooldownFrame, durationObject)
	if not ok then
		return false
	end

	local active = isZero ~= true
	if isZero == nil and cooldownFrame.IsShown then
		local shownOK, shown = pcall(cooldownFrame.IsShown, cooldownFrame)
		if shownOK then
			active = shown == true
		end
	end

	if active and cooldownFrame.Show then
		pcall(cooldownFrame.Show, cooldownFrame)
	elseif active == false and cooldownFrame.Hide then
		pcall(cooldownFrame.Hide, cooldownFrame)
	end

	return true, active, durationObject
end

local function GetCleanSpellCharges(spellID)
	local known, _, _, charges, maxCharges = GetCleanSpellChargeState(spellID)
	if known and IsCleanNumber(charges) and IsCleanNumber(maxCharges) then
		return charges, maxCharges
	end

	return nil
end

local function GetCleanItemCooldown(itemID)
	local api = local_C_Item_GetItemCooldown or (C_Item and C_Item.GetItemCooldown)
	if not api or not itemID then
		return 0, 0
	end

	local ok, start, duration = pcall(api, itemID)
	if ok and IsCleanNumber(start) and IsCleanNumber(duration) then
		return start, duration
	end

	return 0, 0
end

local function SafeSetCooldown(cooldownFrame, startTime, duration)
	if not cooldownFrame then return end
	local ok = pcall(cooldownFrame.SetCooldown, cooldownFrame, startTime or 0, duration or 0)
	if not ok then
		cooldownFrame:Hide()
	end
end

local function ApplyCooldownSweepColor(cooldownFrame)
	if not cooldownFrame then
		return
	end

	local sweepColor = clean_cooldownSweepColor
	if type(sweepColor) ~= "string" or not local_SweepColors or not local_SweepColors[sweepColor] then
		sweepColor = "Black"
	end

	local sweepRGB = local_SweepColors[sweepColor] or { 0, 0, 0 }
	local sweepAlpha = clean_cooldownSweepAlpha or 0.8
	cooldownFrame:SetSwipeColor(sweepRGB[1], sweepRGB[2], sweepRGB[3], clean_showCooldown and sweepAlpha or 0)
end

local function ApplyCooldownWidgetStyle(cooldownFrame, hideNumbers)
	if not cooldownFrame then
		return
	end

	if cooldownFrame.SetDrawSwipe then
		cooldownFrame:SetDrawSwipe(clean_showCooldown and true or false)
	end
	if cooldownFrame.SetDrawEdge then
		cooldownFrame:SetDrawEdge(clean_cooldownDrawEdge and true or false)
	end
	if cooldownFrame.SetDrawBling then
		cooldownFrame:SetDrawBling(clean_cooldownDrawBling and true or false)
	end
	if cooldownFrame.SetHideCountdownNumbers then
		cooldownFrame:SetHideCountdownNumbers(hideNumbers and true or false)
	end
	if cooldownFrame.SetCountdownMillisecondsThreshold then
		cooldownFrame:SetCountdownMillisecondsThreshold(3)
	end

	ApplyCooldownCountdownFont(cooldownFrame)
	ApplyCooldownSweepColor(cooldownFrame)
end

local function ClearCooldownWidget(cooldownFrame, keepShown)
	if not cooldownFrame then
		return
	end

	local ok = false
	if cooldownFrame.Clear then
		ok = pcall(cooldownFrame.Clear, cooldownFrame)
	end
	if not ok and cooldownFrame.SetCooldown then
		pcall(cooldownFrame.SetCooldown, cooldownFrame, 0, 0)
	end

	if keepShown and cooldownFrame.Show then
		cooldownFrame:Show()
	elseif cooldownFrame.Hide then
		cooldownFrame:Hide()
	end
end

local function GetTrackedSpellCooldownActive(spellID)
	if not spellID then
		return nil
	end

	local now = GetTime()
	local baseID = FindBaseSpellByID(spellID) or spellID
	local cd = activeCooldowns[baseID] or activeCooldowns[spellID]
	if not cd or not cd.startTime or not cd.duration then
		return nil
	end

	if cd.startTime + cd.duration > now then
		return true
	end

	ClearTrackedSpellCooldown(spellID)
	return false
end

local function IsSpellRealCooldownActive(spellID)
	local now = GetTime()
	local gcdActive = gcdStartTime + gcdDuration > now
	local trackedActive = GetTrackedSpellCooldownActive(spellID)
	local directZero = false

	local durationObject = TryGetSpellCooldownDurationObject(spellID, true)
	if durationObject then
		local isZero = IsDurationObjectZero(durationObject)
		if isZero == false then
			return true
		elseif isZero == true then
			directZero = true
		end
	end

	if not gcdActive then
		local visibleDurationObject = TryGetSpellCooldownDurationObject(spellID, false)
		if visibleDurationObject then
			local isVisibleZero = IsDurationObjectZero(visibleDurationObject)
			if isVisibleZero == false then
				return true
			elseif isVisibleZero == true then
				return false
			end
		end
	end

	if directZero then
		if trackedActive == true and gcdActive then
			return true
		end
		return false
	end

	if trackedActive ~= nil then
		return trackedActive
	end

	local known, active, onGCD = GetCleanSpellCooldownState(spellID)
	if known then
		return active and not onGCD
	end

	local remaining = GetCooldownRemainingForText(spellID)
	if remaining and remaining > 1.55 and not gcdActive then
		return true
	end

	return false
end

local function GetGlowColorRGB(colorName, fallbackName)
	if type(colorName) ~= "string" or not local_GlowColors or not local_GlowColors[colorName] then
		colorName = fallbackName or "Gold"
	end

	return (local_GlowColors and local_GlowColors[colorName]) or { 1.0, 0.82, 0.0 }
end

local function IsSpellProcHighlighted(spellID)
	if not spellID then
		return false
	end

	if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
		local ok, overlayed = pcall(C_SpellActivationOverlay.IsSpellOverlayed, spellID)
		if ok and not IsSecretValue(overlayed) and overlayed == true then
			return true
		end
	end

	if IsSpellOverlayed then
		local ok, overlayed = pcall(IsSpellOverlayed, spellID)
		if ok and not IsSecretValue(overlayed) and overlayed == true then
			return true
		end
	end

	if C_Spell and C_Spell.IsSpellHighlighted then
		local ok, highlighted = pcall(C_Spell.IsSpellHighlighted, spellID)
		if ok and not IsSecretValue(highlighted) and highlighted == true then
			return true
		end
	end

	return false
end

local function ShouldPlayVisualEffects()
	return not clean_effectsOnlyInCombat or UnitAffectingCombat("player")
end

local function EnsureFocusPulse(button)
	if not button then
		return nil
	end
	if button.focusPulse then
		return button.focusPulse
	end

	local f = NS.CreateFrame("Frame", nil, button)
	f:SetAllPoints(button.icon or button)
	f:SetFrameLevel(button:GetFrameLevel() + 8)
	f:Hide()

	f.wash = f:CreateTexture(nil, "OVERLAY")
	f.wash:SetTexture("Interface\\Buttons\\WHITE8X8")
	f.wash:SetAllPoints()
	f.wash:SetBlendMode("ADD")

	local function edge()
		local tex = f:CreateTexture(nil, "OVERLAY")
		tex:SetTexture("Interface\\Buttons\\WHITE8X8")
		tex:SetBlendMode("ADD")
		return tex
	end

	f.top = edge()
	f.top:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	f.top:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
	f.top:SetHeight(2)
	f.bottom = edge()
	f.bottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
	f.bottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
	f.bottom:SetHeight(2)
	f.left = edge()
	f.left:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	f.left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
	f.left:SetWidth(2)
	f.right = edge()
	f.right:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
	f.right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
	f.right:SetWidth(2)

	f.anim = f:CreateAnimationGroup()
	f.anim:SetToFinalAlpha(true)

	local scale = f.anim:CreateAnimation("Scale")
	scale:SetScale(1.10, 1.10)
	scale:SetDuration(0.18)
	scale:SetSmoothing("OUT")
	scale:SetOrder(1)

	local alpha = f.anim:CreateAnimation("Alpha")
	alpha:SetFromAlpha(0.72)
	alpha:SetToAlpha(0)
	alpha:SetDuration(0.20)
	alpha:SetSmoothing("OUT")
	alpha:SetOrder(1)

	f.anim:SetScript("OnFinished", function(self)
		local parent = self:GetParent()
		parent:SetScale(1)
		parent:Hide()
	end)
	f.anim:SetScript("OnStop", function(self)
		local parent = self:GetParent()
		parent:SetScale(1)
	end)

	button.focusPulse = f
	return f
end

local function TriggerFocusPulse(button, colorName, fallbackName)
	local f = EnsureFocusPulse(button)
	if not f then
		return
	end

	local rgb = GetGlowColorRGB(colorName, fallbackName)
	f.wash:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.18)
	f.top:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.95)
	f.bottom:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.95)
	f.left:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.95)
	f.right:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.95)
	f:SetScale(0.94)
	f:SetAlpha(1)
	f:Show()
	if f.anim:IsPlaying() then
		f.anim:Stop()
	end
	f.anim:Play()
end

local function HideFocusPulse(button)
	if button and button.focusPulse then
		if button.focusPulse.anim and button.focusPulse.anim:IsPlaying() then
			button.focusPulse.anim:Stop()
		end
		button.focusPulse:Hide()
		button.focusPulse:SetScale(1)
	end
end

local function SetProcSweepColor(frame, r, g, b)
	if not frame then
		return
	end
	frame.procR, frame.procG, frame.procB = r or 1, g or 1, b or 1
end

local function SetProcSweepBorder(frame, alpha)
	if not frame then
		return
	end

	local spread = frame.holdSpread or 3
	local r, g, b = frame.procR or 1, frame.procG or 1, frame.procB or 1
	frame.holdWash:SetVertexColor(r, g, b, 0.055 * alpha)
	frame.holdTop:SetVertexColor(r, g, b, 0.70 * alpha)
	frame.holdBottom:SetVertexColor(r, g, b, 0.70 * alpha)
	frame.holdLeft:SetVertexColor(r, g, b, 0.70 * alpha)
	frame.holdRight:SetVertexColor(r, g, b, 0.70 * alpha)
	frame.holdGlowTop:SetVertexColor(r, g, b, 0.13 * alpha)
	frame.holdGlowBottom:SetVertexColor(r, g, b, 0.13 * alpha)
	frame.holdGlowLeft:SetVertexColor(r, g, b, 0.13 * alpha)
	frame.holdGlowRight:SetVertexColor(r, g, b, 0.13 * alpha)

	frame.holdGlowTop:ClearAllPoints()
	frame.holdGlowTop:SetPoint("TOPLEFT", frame, "TOPLEFT", -spread, spread)
	frame.holdGlowTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", spread, spread)
	frame.holdGlowBottom:ClearAllPoints()
	frame.holdGlowBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -spread, -spread)
	frame.holdGlowBottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", spread, -spread)
	frame.holdGlowLeft:ClearAllPoints()
	frame.holdGlowLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", -spread, spread)
	frame.holdGlowLeft:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -spread, -spread)
	frame.holdGlowRight:ClearAllPoints()
	frame.holdGlowRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", spread, spread)
	frame.holdGlowRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", spread, -spread)
end

local function SetProcSweepTexture(texture, width, height, point, relativeTo, relativePoint, x, y, r, g, b, alpha)
	texture:ClearAllPoints()
	texture:SetSize(width, height)
	texture:SetPoint(point, relativeTo, relativePoint, x, y)
	texture:SetVertexColor(r, g, b, alpha)
	texture:Show()
end

local function HideProcSweepBar(frame)
	if not frame then
		return
	end
	if frame.sweep then
		frame.sweep:Hide()
	end
	if frame.sweepGlow then
		frame.sweepGlow:Hide()
	end
	if frame.sweepSegments then
		for i = 1, #frame.sweepSegments do
			frame.sweepSegments[i]:Hide()
		end
	end
	if frame.sweepGlowSegments then
		for i = 1, #frame.sweepGlowSegments do
			frame.sweepGlowSegments[i]:Hide()
		end
	end
end

local function DrawProcSweepEdge(texture, edge, fromDistance, toDistance, width, height, thickness, r, g, b, alpha)
	local length = toDistance - fromDistance
	if length <= 0 then
		texture:Hide()
		return
	end

	if edge == 0 then
		SetProcSweepTexture(texture, length, thickness, "LEFT", texture:GetParent(), "TOPLEFT", fromDistance, -1, r, g, b, alpha)
	elseif edge == 1 then
		SetProcSweepTexture(texture, thickness, length, "TOP", texture:GetParent(), "TOPRIGHT", -1, -fromDistance, r, g, b, alpha)
	elseif edge == 2 then
		SetProcSweepTexture(texture, length, thickness, "LEFT", texture:GetParent(), "BOTTOMLEFT", width - toDistance, 1, r, g, b, alpha)
	else
		SetProcSweepTexture(texture, thickness, length, "BOTTOM", texture:GetParent(), "BOTTOMLEFT", 1, fromDistance, r, g, b, alpha)
	end
end

local function DrawProcSweepPath(frame, textures, tail, head, thickness, alpha)
	if not textures then
		return
	end

	local width = frame:GetWidth()
	local height = frame:GetHeight()
	local r, g, b = frame.procR or 1, frame.procG or 1, frame.procB or 1
	local used = 0

	for edge = 0, 3 do
		local edgeStart
		local edgeLength
		if edge == 0 then
			edgeStart, edgeLength = 0, width
		elseif edge == 1 then
			edgeStart, edgeLength = width, height
		elseif edge == 2 then
			edgeStart, edgeLength = width + height, width
		else
			edgeStart, edgeLength = width + height + width, height
		end
		local edgeEnd = edgeStart + edgeLength
		local segmentStart = math.max(tail, edgeStart)
		local segmentEnd = math.min(head, edgeEnd)
		if segmentEnd > segmentStart then
			used = used + 1
			DrawProcSweepEdge(textures[used], edge, segmentStart - edgeStart, segmentEnd - edgeStart, width, height, thickness, r, g, b, alpha)
		end
	end

	for i = used + 1, #textures do
		textures[i]:Hide()
	end
end

local function UpdateProcSweepBar(frame, progress)
	local width = frame:GetWidth()
	local height = frame:GetHeight()
	if not width or width <= 1 or not height or height <= 1 then
		return
	end

	local r, g, b = frame.procR or 1, frame.procG or 1, frame.procB or 1
	local p = math.max(0, math.min(progress, 1))
	local perimeter = (width + height) * 2
	local head = perimeter * p
	local trail = math.max(10, math.min(width, height) * 0.30)
	local tail = math.max(0, head - trail)
	local thickness = math.max(1, math.floor(math.min(width, height) * 0.05 + 0.5))
	local glowThickness = thickness + math.max(3, math.floor(math.min(width, height) * 0.09 + 0.5))

	frame.holdWash:SetVertexColor(r, g, b, 0.018 + 0.020 * p)
	frame.holdWash:Show()
	frame.holdTop:Hide()
	frame.holdBottom:Hide()
	frame.holdLeft:Hide()
	frame.holdRight:Hide()
	frame.holdGlowTop:Hide()
	frame.holdGlowBottom:Hide()
	frame.holdGlowLeft:Hide()
	frame.holdGlowRight:Hide()

	DrawProcSweepPath(frame, frame.sweepGlowSegments, tail, head, glowThickness, 0.14 + 0.04 * p)
	DrawProcSweepPath(frame, frame.sweepSegments, tail, head, thickness, 0.78 + 0.08 * p)
end

local function ShowProcSweepHold(frame, alpha, spread)
	if not frame then
		return
	end

	frame.holdSpread = spread or frame.holdSpread or 3
	HideProcSweepBar(frame)
	frame.holdWash:Show()
	frame.holdTop:Show()
	frame.holdBottom:Show()
	frame.holdLeft:Show()
	frame.holdRight:Show()
	frame.holdGlowTop:Show()
	frame.holdGlowBottom:Show()
	frame.holdGlowLeft:Show()
	frame.holdGlowRight:Show()
	SetProcSweepBorder(frame, alpha or 1)
end

local function EnsureProcSweepGlow(button)
	if not button then
		return nil
	end
	if button.procSweepGlow then
		return button.procSweepGlow
	end

	local f = NS.CreateFrame("Frame", nil, button)
	f:SetAllPoints(button.icon or button)
	f:SetFrameLevel(button:GetFrameLevel() + 9)
	f:Hide()

	local function makeTexture(layer, blend)
		local tex = f:CreateTexture(nil, layer or "OVERLAY")
		tex:SetTexture("Interface\\Buttons\\WHITE8X8")
		if blend then
			tex:SetBlendMode(blend)
		end
		tex:Hide()
		return tex
	end

	f.holdWash = makeTexture("OVERLAY", "ADD")
	f.holdWash:SetAllPoints()

	local function edge(thickness, horizontal, glow)
		local tex = makeTexture("OVERLAY", "ADD")
		if horizontal then
			tex:SetHeight(thickness)
		else
			tex:SetWidth(thickness)
		end
		return tex
	end

	f.holdTop = edge(2, true)
	f.holdTop:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	f.holdTop:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
	f.holdBottom = edge(2, true)
	f.holdBottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
	f.holdBottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
	f.holdLeft = edge(2, false)
	f.holdLeft:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	f.holdLeft:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
	f.holdRight = edge(2, false)
	f.holdRight:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
	f.holdRight:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)

	f.holdGlowTop = edge(7, true)
	f.holdGlowTop:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
	f.holdGlowTop:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
	f.holdGlowBottom = edge(7, true)
	f.holdGlowBottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -2, -2)
	f.holdGlowBottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
	f.holdGlowLeft = edge(7, false)
	f.holdGlowLeft:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
	f.holdGlowLeft:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -2, -2)
	f.holdGlowRight = edge(7, false)
	f.holdGlowRight:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
	f.holdGlowRight:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)

		f.sweepGlowSegments = {}
		f.sweepSegments = {}
		for i = 1, 4 do
			f.sweepGlowSegments[i] = makeTexture("OVERLAY", "ADD")
			f.sweepSegments[i] = makeTexture("OVERLAY", "ADD")
		end
		f.sweepDuration = 0.72
		f.expandDuration = 0.18

		f:SetScript("OnUpdate", function(self)
			if self.phase == "sweep" then
				local elapsed = GetTime() - (self.startTime or GetTime())
				local progress = elapsed / (self.sweepDuration or 0.72)
				if progress >= 1 then
					self.phase = "expand"
					self.expandStart = GetTime()
					ShowProcSweepHold(self, 0.68, 1)
				else
					UpdateProcSweepBar(self, progress)
				end
			elseif self.phase == "expand" then
				local elapsed = GetTime() - (self.expandStart or GetTime())
				local progress = math.max(0, math.min(elapsed / (self.expandDuration or 0.18), 1))
				local eased = 1 - ((1 - progress) ^ 3)
				ShowProcSweepHold(self, 0.68 + 0.27 * eased, 1 + 3 * eased)
				if progress >= 1 then
					self.phase = "hold"
				end
			elseif self.phase == "hold" then
				self.holdSpread = 4
				SetProcSweepBorder(self, 0.95)
			end
		end)

	button.procSweepGlow = f
	return f
end

local function ShowProcSweepGlow(button, restart, colorName, fallbackName)
	local f = EnsureProcSweepGlow(button)
	if not f then
		return false
	end

	local rgb = GetGlowColorRGB(colorName, fallbackName)
	SetProcSweepColor(f, rgb[1], rgb[2], rgb[3])

	if f:IsShown() and f.phase == "hold" and not restart then
		SetProcSweepBorder(f, 1)
		return true
	end

	if f:IsShown() and f.phase == "sweep" and not restart then
		return true
	end

	if f:IsShown() and f.phase == "expand" and not restart then
		return true
	end

	if restart or not f:IsShown() then
		f.phase = "sweep"
		f.startTime = GetTime()
		f:Show()
		UpdateProcSweepBar(f, 0)
	else
		ShowProcSweepHold(f)
	end
	return true
end

local function HideProcSweepGlow(button)
	if button and button.procSweepGlow then
		button.procSweepGlow.phase = nil
		HideProcSweepBar(button.procSweepGlow)
		button.procSweepGlow:Hide()
	end
end

local function EnsureBlizzardProcGlow(button)
	if not button then
		return nil
	end
	if button.blizzardProcGlow then
		return button.blizzardProcGlow
	end

	local f = NS.CreateFrame("Frame", nil, button)
	f:SetFrameLevel(button:GetFrameLevel() + 10)
	f:Hide()

	f.ProcStart = f:CreateTexture(nil, "ARTWORK")
	f.ProcStart:SetBlendMode("ADD")
	f.ProcStart:SetAtlas("UI-HUD-ActionBar-Proc-Start-Flipbook")
	f.ProcStart:SetAlpha(1)
	f.ProcStart:SetPoint("CENTER")

	f.ProcLoop = f:CreateTexture(nil, "ARTWORK")
	f.ProcLoop:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
	f.ProcLoop:SetAlpha(0)
	f.ProcLoop:SetAllPoints()

	f.ProcLoopAnim = f:CreateAnimationGroup()
	f.ProcLoopAnim:SetLooping("REPEAT")
	f.ProcLoopAnim:SetToFinalAlpha(true)

	local loopAlpha = f.ProcLoopAnim:CreateAnimation("Alpha")
	loopAlpha:SetChildKey("ProcLoop")
	loopAlpha:SetFromAlpha(1)
	loopAlpha:SetToAlpha(1)
	loopAlpha:SetDuration(0.001)
	loopAlpha:SetOrder(0)

	local loopFlipbook = f.ProcLoopAnim:CreateAnimation("FlipBook")
	loopFlipbook:SetChildKey("ProcLoop")
	loopFlipbook:SetDuration(1)
	loopFlipbook:SetOrder(0)
	loopFlipbook:SetFlipBookRows(6)
	loopFlipbook:SetFlipBookColumns(5)
	loopFlipbook:SetFlipBookFrames(30)
	loopFlipbook:SetFlipBookFrameWidth(0)
	loopFlipbook:SetFlipBookFrameHeight(0)

	f.ProcStartAnim = f:CreateAnimationGroup()
	f.ProcStartAnim:SetToFinalAlpha(true)

	local startAlphaIn = f.ProcStartAnim:CreateAnimation("Alpha")
	startAlphaIn:SetChildKey("ProcStart")
	startAlphaIn:SetDuration(0.001)
	startAlphaIn:SetOrder(0)
	startAlphaIn:SetFromAlpha(1)
	startAlphaIn:SetToAlpha(1)

	local startFlipbook = f.ProcStartAnim:CreateAnimation("FlipBook")
	startFlipbook:SetChildKey("ProcStart")
	startFlipbook:SetDuration(0.7)
	startFlipbook:SetOrder(1)
	startFlipbook:SetFlipBookRows(6)
	startFlipbook:SetFlipBookColumns(5)
	startFlipbook:SetFlipBookFrames(30)
	startFlipbook:SetFlipBookFrameWidth(0)
	startFlipbook:SetFlipBookFrameHeight(0)

	local startAlphaOut = f.ProcStartAnim:CreateAnimation("Alpha")
	startAlphaOut:SetChildKey("ProcStart")
	startAlphaOut:SetDuration(0.001)
	startAlphaOut:SetOrder(2)
	startAlphaOut:SetFromAlpha(1)
	startAlphaOut:SetToAlpha(0)

	f.ProcStartAnim:SetScript("OnFinished", function(self)
		local parent = self:GetParent()
		if parent and parent.active then
			parent.ProcStart:Hide()
			parent.ProcLoop:Show()
			parent.ProcLoopAnim:Play()
		end
	end)

	f:SetScript("OnHide", function(self)
		self.active = false
		if self.ProcStartAnim and self.ProcStartAnim:IsPlaying() then
			self.ProcStartAnim:Stop()
		end
		if self.ProcLoopAnim and self.ProcLoopAnim:IsPlaying() then
			self.ProcLoopAnim:Stop()
		end
	end)

	button.blizzardProcGlow = f
	return f
end

local function ShowBlizzardProcGlow(button, restart)
	local f = EnsureBlizzardProcGlow(button)
	if not f then
		return false
	end

	local target = button.icon or button
	local width = target:GetWidth() or button:GetWidth() or 40
	local height = target:GetHeight() or button:GetHeight() or 40
	if width <= 1 then
		width = button:GetWidth() or 40
	end
	if height <= 1 then
		height = button:GetHeight() or 40
	end
	local xOffset = width * 0.2
	local yOffset = height * 0.2
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", target, "TOPLEFT", -xOffset, yOffset)
	f:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", xOffset, -yOffset)
	f:SetFrameLevel(button:GetFrameLevel() + 10)
	f.active = true
	f:Show()

	if f:IsShown() and not restart and (f.ProcStartAnim:IsPlaying() or f.ProcLoopAnim:IsPlaying()) then
		return true
	end

	if f.ProcStartAnim:IsPlaying() then
		f.ProcStartAnim:Stop()
	end
	if f.ProcLoopAnim:IsPlaying() then
		f.ProcLoopAnim:Stop()
	end

	local frameWidth, frameHeight = width + xOffset * 2, height + yOffset * 2
	f.ProcStart:SetSize((frameWidth / 42 * 150) / 1.4, (frameHeight / 42 * 150) / 1.4)
	f.ProcStart:SetDesaturated(nil)
	f.ProcStart:SetVertexColor(1, 1, 1, 1)
	f.ProcLoop:SetDesaturated(nil)
	f.ProcLoop:SetVertexColor(1, 1, 1, 1)
	f.ProcStart:Show()
	f.ProcLoop:Hide()
	f.ProcStartAnim:Play()
	return true
end

local function HideBlizzardProcGlow(button)
	if button and button.blizzardProcGlow then
		local f = button.blizzardProcGlow
		f.active = false
		if f.ProcStartAnim and f.ProcStartAnim:IsPlaying() then
			f.ProcStartAnim:Stop()
		end
		if f.ProcLoopAnim and f.ProcLoopAnim:IsPlaying() then
			f.ProcLoopAnim:Stop()
		end
		f.ProcStart:Hide()
		f.ProcLoop:Hide()
		f:Hide()
	end
end

local function ShowProcFocusGlow(button, colorName, fallbackName)
	if not button then
		return
	end
	local f = EnsureFocusPulse(button)
	if not f then
		return
	end

	local rgb = GetGlowColorRGB(colorName, fallbackName)
	f.wash:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.10)
	f.top:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.75)
	f.bottom:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.75)
	f.left:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.75)
	f.right:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.75)
	if f.anim:IsPlaying() then
		f.anim:Stop()
	end
	f:SetScale(1)
	f:SetAlpha(0.7)
	f:Show()
end

local function HideProcEffects(button)
	HideProcSweepGlow(button)
	HideBlizzardProcGlow(button)
	if button then
		if button.procGlowStyle == "focusPulse" then
			HideFocusPulse(button)
		end
		button.procGlowStyle = nil
	end
end

local function TriggerButtonTransitionEffect(button, flashEnabled, bounceEnabled, pulseEnabled, colorName, fallbackName)
	if not button then
		return
	end

	local now = GetTime()
	if bounceEnabled then
		button.isBouncing = true
		button.bounceStart = now
	end

	if flashEnabled and button.flash then
		local rgb = GetGlowColorRGB(colorName, fallbackName)
		button.flash:SetVertexColor(rgb[1], rgb[2], rgb[3], 1)
		button.flash:SetAlpha(1.0)
		button.flash:Show()
		button.flashStart = now
	end

	if pulseEnabled then
		TriggerFocusPulse(button, colorName, fallbackName)
	end
end

local function OnButtonUpdate(self, elapsed)
	SafeCallClean(function()
		local now = GetTime()

			-- 1. Bounce scale animation
			if self.isBouncing and self.bounceStart then
				local progress = now - self.bounceStart
				local duration = 0.18
				if progress < duration then
					local amplitude = (clean_bounceScale or 1.15) - 1.0
					local t = progress / duration
					local scale
					if t < 0.42 then
						local p = t / 0.42
						scale = 1.0 + amplitude * (1 - ((1 - p) ^ 3))
					else
						local p = (t - 0.42) / 0.58
						scale = 1.0 + amplitude * ((1 - p) ^ 3)
					end
					self:SetScale((clean_scale or 1.0) * scale)
				else
					self:SetScale(clean_scale or 1.0)
					self.isBouncing = false
				end
		end

		-- 2. Flash overlay fade-out
		if self.flash and self.flash:IsShown() and self.flashStart then
			local progress = now - self.flashStart
			local duration = 0.15
			if progress < duration then
				local alpha = 1.0 - (progress / duration)
				self.flash:SetAlpha(alpha)
			else
				self.flash:Hide()
			end
		end

			-- 3. Minimal proc focus pulse, only when selected as the active proc style.
			if self.focusPulse and self.focusPulse:IsShown() and self.procGlowStyle == "focusPulse" then
				local pulse = 0.58 + 0.12 * math.sin(now * 5.5)
				local r, g, b = self.glowR or 1, self.glowG or 1, self.glowB or 1
				self.focusPulse.wash:SetVertexColor(r, g, b, 0.08 * pulse)
				self.focusPulse.top:SetVertexColor(r, g, b, 0.72 * pulse)
				self.focusPulse.bottom:SetVertexColor(r, g, b, 0.72 * pulse)
				self.focusPulse.left:SetVertexColor(r, g, b, 0.72 * pulse)
				self.focusPulse.right:SetVertexColor(r, g, b, 0.72 * pulse)
			end

		-- 4. Throttled UI & Cooldown Visual Update (Runs every 0.05 seconds / 20 FPS)
		self.timeSinceLastUpdate = (self.timeSinceLastUpdate or 0) + elapsed
		if self.timeSinceLastUpdate >= 0.05 then
			self.timeSinceLastUpdate = 0
			
			-- Render suggestion button using cleanRecommendedSpellID
			UpdateButton(self, cleanRecommendedSpellID)
			
			-- Update Avada Tracker (runs in the clean rendering thread!)
			UpdateAvada()
		end

		-- 5. Out of combat background cooldown caching (runs every 1.0 second)
		if not InCombatLockdown() then
			self.timeSinceLastCacheScan = (self.timeSinceLastCacheScan or 0) + elapsed
			if self.timeSinceLastCacheScan >= 1.0 then
				self.timeSinceLastCacheScan = 0
				ScanAllCooldowns()
			end
		end

		-- 6. Custom Cooldown countdown text (runs every frame for smooth tick-down)
		local inGCD = not clean_ignoreGCD and gcdStartTime + gcdDuration > now
		if clean_customCooldownText and self.spellID and not inGCD then
			local remaining = GetCooldownRemainingForText(self.spellID)
			if remaining and remaining > 0 and ApplyCustomCooldownText(self.customCooldownText, remaining) then
				self.cooldown:SetHideCountdownNumbers(true)
			else
				self.customCooldownText:Hide()
				self.cooldown:SetHideCountdownNumbers(false)
			end
		else
			if self.customCooldownText then
				self.customCooldownText:Hide()
			end
			self.cooldown:SetHideCountdownNumbers(false)
		end
		end)
	end

local function CreateSuggestionButton(parent)
	local b = NS.CreateFrame("Frame", nil, parent, "BackdropTemplate")
	b:SetSize(NS.db.buttonSize, NS.db.buttonSize)
	b:SetFrameLevel(parent:GetFrameLevel() + 2)

	b.icon = b:CreateTexture(nil, "BACKGROUND")
	b.icon:SetAllPoints()
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- Modern HUD Border
	b.border = b:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture("Interface/HUD/UIActionBar")
	b.border:SetTexCoord(0.707031, 0.886719, 0.248047, 0.291992)
	b.border:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
	b.border:SetSize(46, 45) -- Default size relative to 40px button, scaler will handle resizing

	b.cooldown = NS.CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cooldown:SetAllPoints(b.icon)
	b.cooldown:SetFrameLevel(b:GetFrameLevel())
	-- One-time cooldown init (asNextSkill pattern — never set these per-frame!)
	ApplyCooldownWidgetStyle(b.cooldown, false)
	b.cooldown:Show() -- Show once, never Hide/Show cycle — use Clear() instead

	b.hotkey = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall") -- Using a cleaner number font
	b.hotkey:SetPoint("TOPRIGHT", b.icon, "TOPRIGHT", -2, -2)
	b.hotkey:SetJustifyH("RIGHT")
	b.hotkey:SetDrawLayer("OVERLAY", 7)

	-- Custom Cooldown Text Overlaid
	b.customCooldownText = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.customCooldownText:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
	b.customCooldownText:SetJustifyH("CENTER")
	b.customCooldownText:SetDrawLayer("OVERLAY", 7)
	b.customCooldownText:Hide()

	-- Flash Overlay texture for swap animation
	b.flash = b:CreateTexture(nil, "OVERLAY")
	b.flash:SetTexture("Interface\\Buttons\\WHITE8X8")
	b.flash:SetAllPoints(b.icon)
	b.flash:SetBlendMode("ADD")
	b.flash:SetAlpha(0)
	b.flash:Hide()

	b.spellID = nil
	b:SetScript("OnUpdate", OnButtonUpdate)

	return b
end

local function CreateAvadaIcon(parent, index)
	local b = NS.CreateFrame("Frame", nil, parent, "BackdropTemplate")
	b:SetSize(NS.db.avadaSize, NS.db.avadaSize)

	b.icon = b:CreateTexture(nil, "BACKGROUND")
	b.icon:SetAllPoints()
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- Avada Border
	b.border = b:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture("Interface/HUD/UIActionBar")
	b.border:SetTexCoord(0.707031, 0.886719, 0.248047, 0.291992)
	b.border:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
	b.border:SetSize(46, 45) -- Default size relative to 40px button, scaler will handle resizing

	b.cooldown = NS.CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cooldown:SetAllPoints(b.icon)
	b.cooldown:SetHideCountdownNumbers(true)
	b.cooldown:SetFrameLevel(b:GetFrameLevel())
	b.cooldown:SetDrawSwipe(true)
	b.cooldown:Show()

	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	b.count:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 0, 0)
	b.count:SetJustifyH("RIGHT")

	return b
end

function NS.UpdateAvadaLayout()
	if not frame.avada then
		frame.avada = NS.CreateFrame("Frame", "ButtonAssistantEnchancedAvadaFrame", frame)
		frame.avada.icons = {}
	end

	local f = frame.avada
	local size = NS.db.avadaSize or 16
	local spacing = NS.db.avadaSpacing or 4
	local offsetY = NS.db.avadaOffsetY or -10
	local showBorder = NS.db.avadaShowBorder

	f:ClearAllPoints()
	f:SetPoint("TOP", frame.button, "BOTTOM", 0, offsetY)
	f:SetSize((size + spacing) * 6 - spacing, size)

	if not f.value then
		f.value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
		f.value:SetPoint("RIGHT", frame.button, "LEFT", -10, 0)
	end

	for i = 1, 6 do
		local icon = f.icons[i]
		if not icon then
			icon = CreateAvadaIcon(f, i)
			f.icons[i] = icon
		end
		icon:SetSize(size, size)
		icon:ClearAllPoints()
		icon:SetPoint("LEFT", f, "LEFT", (i - 1) * (size + spacing), 0)

		if icon.border then
			local borderSize = size * 46 / 40 -- Maintain same ratio as main button
			icon.border:SetSize(borderSize, borderSize)
			icon.border:SetShown(showBorder)
		end

		icon:SetShown(NS.db.avadaEnabled)
	end
	f:SetShown(NS.db.avadaEnabled)
end

function NS.UpdateLayout()
	local size = NS.db.buttonSize or 40
	local b = frame.button
	if not b then
		b = CreateSuggestionButton(frame)
		frame.button = b
	end

	-- Update Size
	b:SetSize(size, size)
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)

	-- Update Border Size (approx 1.15 ratio to cover edges)
	if b.border then
		local borderSize = size * 46 / 40
		b.border:SetSize(borderSize, borderSize)
		-- Show/Hide border based on settings
		b.border:SetShown(NS.db.showBorder)
	end

	-- Update Font Size
	local fontPath, _, fontFlags = b.hotkey:GetFont()
	b.hotkey:SetFont(fontPath, NS.db.keybindFontSize or 12, fontFlags)

	-- Update custom cooldown text font and size
	if b.customCooldownText then
		local fontKey = NS.db.cooldownFont
		if type(fontKey) ~= "string" or not local_FontList[fontKey] then
			fontKey = "Numeric"
		end
		local fontVal = local_FontList[fontKey] or "NumberFontNormal"
		if fontVal:find("Interface\\") then
			b.customCooldownText:SetFont(fontVal, NS.db.cooldownFontSize or 14, NS.db.cooldownFontOutline or "OUTLINE")
		else
			b.customCooldownText:SetFontObject(fontVal)
			local customPath, _, _ = b.customCooldownText:GetFont()
			if customPath then
				b.customCooldownText:SetFont(customPath, NS.db.cooldownFontSize or 14, NS.db.cooldownFontOutline or "OUTLINE")
			end
		end
	end

	-- Sync Settings Copy
	NS.SyncCleanSettings()
	ApplyCooldownWidgetStyle(b.cooldown, false)
	b.cooldownVisualSerial = nil

	-- Update Avada Layout
	NS.UpdateAvadaLayout()

	-- Update Frame properties
	frame:SetSize(size, size)
	frame:SetScale(NS.db.scale or 1.0)

	b:Show()
end

function UpdateCooldownForSpell(b, spellID)
	if not clean_showCooldown then
		if b.cooldownVisualSpellID then
			ClearCooldownWidget(b.cooldown, false)
		end
		b.cooldownVisualSpellID = nil
		b.cooldownVisualIgnoreGCD = nil
		b.cooldownVisualSerial = nil
		if b.customCooldownText then b.customCooldownText:Hide() end
		return
	end

	if b.cooldownVisualSpellID == spellID and b.cooldownVisualIgnoreGCD == clean_ignoreGCD and b.cooldownVisualSerial == cooldownVisualSerial then
		return
	end

	-- asNextSkill model: feed Blizzard's opaque DurationObject directly
	-- into the Cooldown widget. With no ignoreGCD argument it displays both
	-- GCD and real spell cooldowns, including in combat.
	ApplyCooldownWidgetStyle(b.cooldown, false)
	local durationobj = TryGetSpellCooldownDurationObject(spellID, clean_ignoreGCD)
	if durationobj then
		if IsDurationObjectZero(durationobj) == true then
			ClearCooldownWidget(b.cooldown, true)
			b.cooldownVisualSpellID = spellID
			b.cooldownVisualIgnoreGCD = clean_ignoreGCD
			b.cooldownVisualSerial = cooldownVisualSerial
			return
		end

		local ok = pcall(b.cooldown.SetCooldownFromDurationObject, b.cooldown, durationobj)
		if ok then
			ApplyCooldownWidgetStyle(b.cooldown, false)
			b.cooldown:Show()
			b.cooldownVisualSpellID = spellID
			b.cooldownVisualIgnoreGCD = clean_ignoreGCD
			b.cooldownVisualSerial = cooldownVisualSerial
			return
		end
	end

	-- Fallback continuity path for rare API gaps: use the clean local ledger.
	local startTime, duration = GetSpellCooldownClean(spellID)
	if startTime and duration and startTime > 0 and duration > 0 then
		SafeSetCooldown(b.cooldown, startTime, duration)
		ApplyCooldownWidgetStyle(b.cooldown, false)
		b.cooldown:Show()
		b.cooldownVisualSpellID = spellID
		b.cooldownVisualIgnoreGCD = clean_ignoreGCD
		b.cooldownVisualSerial = cooldownVisualSerial
		return
	end

	ClearCooldownWidget(b.cooldown, true)
	b.cooldownVisualSpellID = spellID
	b.cooldownVisualIgnoreGCD = clean_ignoreGCD
	b.cooldownVisualSerial = cooldownVisualSerial
end

local ticker
local function StartTicker()
	if ticker then
		return
	end
	local rate = NS.db.updateRate or 0.12
	if rate < 0.05 then
		rate = 0.05
	end

	ticker = NS.C_Timer_NewTicker(rate, NS.UpdateNow)
end

function NS.UpdateVisibility()
	NS.SafeCall(function()
		local f = NS.frame
		if not f then
			return
		end

		if not NS.db.enabled then
			f:Hide()
			return
		end

		local inCombat = NS.UnitAffectingCombat("player")
		local inVehicle = NS.UnitInVehicle("player")

		-- Hide in Vehicle check
		if inVehicle and NS.db.hideInVehicle then
			f:Hide()
			return
		end

		-- Only In Combat check
		if NS.db.onlyInCombat and not inCombat then
			f:Hide()
			return
		end

		-- Apply Alpha
		local targetAlpha = inCombat and NS.db.alphaCombat or NS.db.alphaOOC
		f:SetAlpha(targetAlpha)

		-- If we passed checks, show it (UpdateNow will determine if there's a spell to create/show sub-elements)
		f:Show()

		-- Check for availability to start/stop ticker
		if NS.IsAssistedCombatAvailable() then
			StartTicker()
		else
			if ticker then
				ticker:Cancel()
				ticker = nil
			end
		end
	end)
end

function UpdateButton(b, spellID)
			SafeCallClean(function()
				if not spellID then
					b.spellID = nil
					b.icon:SetTexture(nil)
					b.hotkey:SetText("")
				ClearCooldownWidget(b.cooldown, false)
				b.cooldownVisualSpellID = nil
				b.cooldownVisualIgnoreGCD = nil
				b.cooldownVisualSerial = nil
					if b.customCooldownText then b.customCooldownText:Hide() end
					HideProcEffects(b)
					HideFocusPulse(b)
					if b.flash then b.flash:Hide() end
				b.lastSpellID = nil
				b.lastCooldownActive = nil
				b.lastReady = nil
				b.lastProc = nil
				b.pendingNextReadySpellID = nil
				b:Hide()
				return
			end

			local changed = (b.lastSpellID ~= spellID)
			b.spellID = spellID

			if local_C_Spell_GetSpellTexture then
				b.icon:SetTexture(local_C_Spell_GetSpellTexture(spellID))
		else
			b.icon:SetTexture(nil)
		end

		if clean_showKeybind then
			local text = local_GetKeyBindForSpellID(spellID) or ""
			b.hotkey:SetText(text)
			b.hotkey:SetShown(text ~= "")
		else
			b.hotkey:SetText("")
			b.hotkey:Hide()
		end

		-- Cooldown update
		UpdateCooldownForSpell(b, spellID)

		-- Range, usability and real-cooldown state.
		local r, g, bColor = 1, 1, 1
		local desaturated = false
			local isUsable = true
			local outOfRange = false
			local realCooldownActive = IsSpellRealCooldownActive(spellID)
			local isProc = IsSpellProcHighlighted(spellID)

		if clean_enableUsabilityCheck and C_Spell and C_Spell.IsSpellUsable then
			local ok, usable = pcall(C_Spell.IsSpellUsable, spellID)
			if ok and not usable then
				isUsable = false
				desaturated = true
				r, g, bColor = 0.4, 0.4, 0.4
			end
		end

		if clean_enableRangeCheck and C_Spell and C_Spell.IsSpellInRange and UnitExists("target") then
			local ok, inRange = pcall(C_Spell.IsSpellInRange, spellID, "target")
			if ok and inRange == false then
				outOfRange = true
				r, g, bColor = 0.85, 0.15, 0.15
			end
		end

			if realCooldownActive and not isProc then
				desaturated = true
				if isUsable and not outOfRange then
					r, g, bColor = 0.4, 0.4, 0.4
				end
			end

			local isReady = (isProc or not realCooldownActive) and isUsable and not outOfRange

		b.icon:SetVertexColor(r, g, bColor)
		b.icon:SetDesaturated(desaturated)

					local effectsAllowed = ShouldPlayVisualEffects()
					local firedNextReady = false
					if changed then
						b.pendingNextReadySpellID = effectsAllowed and not isProc and spellID or nil
					elseif not effectsAllowed or isProc then
						b.pendingNextReadySpellID = nil
					end

					if effectsAllowed and b.pendingNextReadySpellID == spellID and isReady and not isProc then
						TriggerButtonTransitionEffect(b, clean_enableFlashOverlay, clean_enableBounceAnim, clean_effectNextReadyPulseEnabled, "White", "White")
						b.pendingNextReadySpellID = nil
						firedNextReady = true
					end

					if effectsAllowed and not firedNextReady and not changed and not isProc and b.lastCooldownActive == true and realCooldownActive == false and isReady then
						TriggerButtonTransitionEffect(b, clean_effectReadyFlashEnabled, clean_effectReadyBounceEnabled, clean_effectReadyPulseEnabled, clean_glowReadyColor, "Gold")
						b.pendingNextReadySpellID = nil
					end

				if effectsAllowed and isProc and (changed or b.lastProc ~= true) then
					TriggerButtonTransitionEffect(b, clean_effectProcFlashEnabled, clean_effectProcBounceEnabled, false, clean_glowProcColor, "White")
				end

			if effectsAllowed and isProc and clean_glowProcEnabled then
				local procRGB = GetGlowColorRGB(clean_glowProcColor, "White")
				b.glowR, b.glowG, b.glowB = procRGB[1], procRGB[2], procRGB[3]

				if clean_glowProcType == "focusPulse" then
					HideProcSweepGlow(b)
					HideBlizzardProcGlow(b)
					ShowProcFocusGlow(b, clean_glowProcColor, "White")
					b.procGlowStyle = "focusPulse"
				elseif clean_glowProcType == "none" then
					HideProcEffects(b)
				elseif clean_glowProcType == "sweepBorder" then
					HideBlizzardProcGlow(b)
					HideFocusPulse(b)
					if ShowProcSweepGlow(b, changed or b.lastProc ~= true or b.procGlowStyle ~= "sweepBorder", clean_glowProcColor, "White") then
						b.procGlowStyle = "sweepBorder"
					else
						ShowProcFocusGlow(b, clean_glowProcColor, "White")
						b.procGlowStyle = "focusPulse"
					end
				else
					HideProcSweepGlow(b)
					HideFocusPulse(b)
					if ShowBlizzardProcGlow(b, changed or b.lastProc ~= true or b.procGlowStyle ~= "blizzardProc") then
						b.procGlowStyle = "blizzardProc"
					else
						ShowProcFocusGlow(b, clean_glowProcColor, "White")
						b.procGlowStyle = "focusPulse"
					end
				end
			else
				HideProcEffects(b)
			end

			b.lastSpellID = spellID
			b.lastCooldownActive = realCooldownActive
			b.lastReady = isReady
			b.lastProc = isProc
			b:Show()
		end)
	end

function UpdateAvada()
	if not clean_avadaEnabled or not frame.avada then
		if frame.avada then
			frame.avada:Hide()
		end
		return
	end

	local list = local_GetAvadaTargetList()
	if not list then
		frame.avada:Hide()
		return
	end

	frame.avada:Show()
	local showValue = false
	local tracker = frame.avada

	for i = 1, 6 do
		local icon = tracker.icons[i]
		local data = list[i]
		if data and data.spellID then
			local unit = data.unit
			local aType = data.type
			local id = data.spellID

			local tex = local_C_Spell_GetSpellTexture(local_AvadaReplacedTexture[id] or id)
			if aType == "item" then
				tex = local_C_Item_GetItemIconByID or local_C_Spell_GetSpellTexture(id)
				if local_C_Item_GetItemIconByID then
					tex = local_C_Item_GetItemIconByID(id)
				end
			end
			icon.icon:SetTexture(tex or "Interface/Icons/INV_Misc_QuestionMark")

			local alpha = 1.0
			local countText = ""
			local startTime, duration = 0, 0
				local countColor = { 1, 1, 1 }
				local desaturated = false
				local cooldownHandled = false
				local cooldownIsZero = false
				local cooldownReadyCached = false

				if aType == "buff" or aType == "debuff" then
				local filter = (aType == "debuff") and "HARMFUL" or "HELPFUL"
				local aura, value = local_GetAuraInfo(unit, id, filter)
				if aura then
					countText = (aura.applications > 1) and aura.applications or ""
					if aura.expirationTime and aura.expirationTime > 0 then
						startTime = aura.expirationTime - aura.duration
						duration = aura.duration
					end
					if local_AvadaValueSpells[id] and value then
						tracker.value:SetText(local_FormatNumber(value))
						showValue = true
					end
				else
					desaturated = true
				end
			elseif aType == "cd" then
				local charges, maxCharges = GetCleanSpellCharges(id)
				if charges and maxCharges and maxCharges > 1 then
					countText = charges
				end

					-- Direct DurationObject path (asNextSkill approach)
					local preferChargeCooldown = charges and maxCharges and maxCharges > 1 and charges < maxCharges
					local durationobj
					if preferChargeCooldown then
						durationobj = TryGetSpellChargeDurationObject(id)
					end
					if not durationobj then
						durationobj = TryGetSpellCooldownDurationObject(id, true)
					end
					if not durationobj and not preferChargeCooldown then
						durationobj = TryGetSpellChargeDurationObject(id)
					end

					if durationobj then
						local durationZero = IsDurationObjectZero(durationobj)
						local cooldownKey = tostring(id) .. ":" .. tostring(preferChargeCooldown) .. ":" .. tostring(durationZero == false)
						if durationZero == false then
							cooldownHandled = true
							desaturated = true
							countColor = { 1, 1, 1 }
							if icon.cooldownVisualKey ~= cooldownKey or icon.cooldownVisualSerial ~= cooldownVisualSerial then
								local ok = pcall(icon.cooldown.SetCooldownFromDurationObject, icon.cooldown, durationobj)
								if ok then
									icon.cooldownVisualKey = cooldownKey
									icon.cooldownVisualSerial = cooldownVisualSerial
								else
									cooldownHandled = false
									desaturated = false
									icon.cooldownVisualKey = nil
									icon.cooldownVisualSerial = nil
								end
							end
						else
							cooldownHandled = true
							cooldownIsZero = true
							desaturated = false
							cooldownKey = tostring(id) .. ":" .. tostring(preferChargeCooldown) .. ":ready"
							if icon.cooldownVisualKey ~= cooldownKey or icon.cooldownVisualSerial ~= cooldownVisualSerial then
								ClearCooldownWidget(icon.cooldown, true)
								icon.cooldownVisualKey = cooldownKey
								icon.cooldownVisualSerial = cooldownVisualSerial
							else
								cooldownReadyCached = true
							end
						end
					else
						cooldownHandled = true
						cooldownIsZero = true
						desaturated = false
						local cooldownKey = tostring(id) .. ":" .. tostring(preferChargeCooldown) .. ":ready"
						if charges and maxCharges and charges == maxCharges then
							countColor = { 1, 0, 0 }
						end
						if icon.cooldownVisualKey ~= cooldownKey or icon.cooldownVisualSerial ~= cooldownVisualSerial then
							ClearCooldownWidget(icon.cooldown, true)
							icon.cooldownVisualKey = cooldownKey
							icon.cooldownVisualSerial = cooldownVisualSerial
						else
							cooldownReadyCached = true
						end
					end
				elseif aType == "item" then
				local count = local_C_Item_GetItemCount and local_C_Item_GetItemCount(id)
				if IsCleanNumber(count) and count > 1 then
					countText = count
				end

				local start, dur = GetCleanItemCooldown(id)
				if start and dur and dur > 3 then
					startTime, duration = start, dur
					desaturated = true
				end
			end

			icon.icon:SetDesaturated(desaturated)
			icon.count:SetText(countText)
			icon.count:SetTextColor(unpack(countColor))

				if cooldownHandled then
					if not cooldownReadyCached then
						icon.cooldown:SetReverse(false)
						icon.cooldown:SetHideCountdownNumbers(true)
						icon.cooldown:SetDrawSwipe(not cooldownIsZero)
						icon.cooldown:Show()
						if not cooldownIsZero then
							ApplyCooldownSweepColor(icon.cooldown)
						end
					end
				elseif startTime and duration and duration > 0 then
					icon.cooldown:SetReverse(aType == "buff" or aType == "debuff")
					SafeSetCooldown(icon.cooldown, startTime, duration)
					icon.cooldown:Show()
					icon.cooldownVisualKey = nil
					icon.cooldownVisualSerial = nil
				else
					local clearKey = "clear:" .. tostring(aType) .. ":" .. tostring(id)
					if icon.cooldownVisualKey ~= clearKey or icon.cooldownVisualSerial ~= cooldownVisualSerial then
						ClearCooldownWidget(icon.cooldown, true)
						icon.cooldownVisualKey = clearKey
						icon.cooldownVisualSerial = cooldownVisualSerial
					end
				end
				icon:Show()
			else
				icon.cooldownVisualKey = nil
				icon.cooldownVisualSerial = nil
				icon:Hide()
			end
	end

	if not showValue then
		tracker.value:SetText("")
	end
end

function NS.UpdateNow()
	NS.SyncCleanSettings() -- Keep local clean copies synced!

	NS.SafeCall(function()
		local f = NS.frame
		if not f or not f:IsVisible() then
			return
		end

		local spellID = NS.CollectNextSpell()
		cleanRecommendedSpellID = spellID
	end)
end

local function OnAssistedCombatUpdate()
	if NS.UpdateNow then
		NS.UpdateNow()
	end
end

local function RegisterAssistedCombatEvents()
	if not EventRegistry or not EventRegistry.RegisterCallback then
		return
	end

	-- Blizzard's internal rotation manager events (Patch 11.1.7+)
	EventRegistry:RegisterCallback("AssistedCombatManager.OnAssistedHighlightSpellChange", OnAssistedCombatUpdate, NS)
	EventRegistry:RegisterCallback("AssistedCombatManager.RotationSpellsUpdated", OnAssistedCombatUpdate, NS)
	EventRegistry:RegisterCallback("AssistedCombatManager.OnSetActionSpell", OnAssistedCombatUpdate, NS)
end

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------
addonFrame:RegisterEvent("ADDON_LOADED")
addonFrame:RegisterEvent("UPDATE_BINDINGS")
addonFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
addonFrame:RegisterEvent("SPELLS_CHANGED")
addonFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
addonFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
addonFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
addonFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
addonFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
addonFrame:RegisterEvent("ASSISTED_COMBAT_ACTION_SPELL_CAST")
addonFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
addonFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
addonFrame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
addonFrame:RegisterEvent("UPDATE_OVERRIDE_ACTIONBAR")
addonFrame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
addonFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
addonFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
addonFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
addonFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
addonFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
addonFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
addonFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
addonFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
addonFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
addonFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
addonFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

local allTimer
local function DelayedUpdateKeybindings()
	if allTimer then
		allTimer:Cancel()
	end
	ClearActionSlotCache()
	allTimer = NS.C_Timer_After(0.2, function()
		NS.ReadKeybindings()
		NS.UpdateNow()
		ScanAllCooldowns() -- Scan and cache cooldowns after everything is settled!
		if not InCombatLockdown() then
			if cleanRecommendedSpellID then
				GetCachedActionSlotsForSpell(cleanRecommendedSpellID)
			end
			local list = local_GetAvadaTargetList and local_GetAvadaTargetList()
			if list then
				for _, data in ipairs(list) do
					if data and data.spellID and data.type == "cd" then
						GetCachedActionSlotsForSpell(data.spellID)
					end
				end
			end
		end
		allTimer = nil
	end)
end

addonFrame:SetScript("OnEvent", function(self, event, ...)
	NS.SafeCall(function(self, event, ...)
		if event == "ADDON_LOADED" then
			local name = ...
			if name ~= ADDON_NAME or NS.loaded then
				return
			end
			NS.loaded = true

			ButtonAssistantEnchancedDB = ButtonAssistantEnchancedDB or {}
			NS.db = ButtonAssistantEnchancedDB
			NS.CopyDefaults(NS.db, NS.defaults)
			if (NS.db.cooldownModelVersion or 0) < COOLDOWN_MODEL_VERSION then
				NS.db.ignoreGCD = false
				NS.db.cooldownModelVersion = COOLDOWN_MODEL_VERSION
			end
			if (NS.db.effectModelVersion or 0) < EFFECT_MODEL_VERSION then
				NS.db.glowReadyEnabled = false
				NS.db.glowReadyType = "none"
				NS.db.glowProcEnabled = true
				NS.db.glowProcType = "blizzardProc"
				NS.db.glowProcColor = "White"
				NS.db.effectsOnlyInCombat = true
				NS.db.enableBounceAnim = false
				NS.db.bounceScale = 1.10
				NS.db.enableFlashOverlay = true
				NS.db.effectNextReadyPulseEnabled = true
				NS.db.effectReadyFlashEnabled = true
				NS.db.effectReadyPulseEnabled = true
				NS.db.effectReadyBounceEnabled = false
				NS.db.effectProcFlashEnabled = false
				NS.db.effectProcBounceEnabled = false
				NS.db.effectModelVersion = EFFECT_MODEL_VERSION
			end

			-- Cache namespace pointers cleanly
			local_GetAvadaTargetList = NS.GetAvadaTargetList
			local_C_Spell_GetSpellTexture = NS.C_Spell_GetSpellTexture
			local_AvadaReplacedTexture = NS.AvadaReplacedTexture
			local_C_ActionBar_FindSpellActionButtons = NS.C_ActionBar_FindSpellActionButtons
			local_C_ActionBar_GetActionCooldownDuration = NS.C_ActionBar_GetActionCooldownDuration
			local_C_ActionBar_GetActionChargeDuration = NS.C_ActionBar_GetActionChargeDuration
			local_C_Item_GetItemIconByID = NS.C_Item_GetItemIconByID
			local_GetAuraInfo = NS.GetAuraInfo
			local_AvadaValueSpells = NS.AvadaValueSpells
			local_FormatNumber = NS.FormatNumber
			local_C_Spell_GetSpellCooldown = NS.C_Spell_GetSpellCooldown
			local_C_Spell_GetSpellCooldownDuration = NS.C_Spell_GetSpellCooldownDuration
			local_C_Spell_GetSpellCooldownRemaining = NS.C_Spell_GetSpellCooldownRemaining
			local_C_Spell_GetSpellCharges = NS.C_Spell_GetSpellCharges
			local_C_Spell_GetSpellChargeDuration = NS.C_Spell_GetSpellChargeDuration
			local_C_Item_GetItemCooldown = NS.C_Item_GetItemCooldown
			local_C_Item_GetItemCount = NS.C_Item_GetItemCount
			local_AvadaGemini = NS.AvadaGemini
			local_IsSpellKnown = NS.IsSpellKnown
			local_GetKeyBindForSpellID = NS.GetKeyBindForSpellID
			local_SweepColors = NS.SweepColors
			local_GlowColors = NS.GlowColors
			local_FontList = NS.FontList

			NS.SyncCleanSettings() -- Initial clean settings copy

			NS.RegisterSettings() -- Initialize Modern Settings Panel

			RegisterAssistedCombatEvents() -- Hook into Blizzard's internal events

			NS.UpdateLayout()
			NS.UpdateVisibility() -- Call UpdateVisibility after layout
			DelayedUpdateKeybindings() -- Ensure hotkeys are scanned after bars are ready
			return
		end

			if event == "UNIT_SPELLCAST_SUCCEEDED" then
				local unit, _, spellID = ...
				if unit == "player" then
					-- Track GCD (autonomous, always works)
					gcdStartTime = GetTime()
					gcdDuration = GetGCDDurationClean()
					InvalidateCooldownVisuals()
					if NS.C_Timer_After then
						NS.C_Timer_After((gcdDuration or 0) + 0.03, function()
							InvalidateCooldownVisuals()
						end)
					end

					-- Track spell cooldowns for in-combat dimming
				-- (DurationObject handles sweep display, but we need activeCooldowns
				-- cache to know if a spell has real CD for desaturation purposes)
				local capturedSpellID = spellID
				local capturedGCDStart = gcdStartTime
				if NS.C_Timer_After then
					NS.C_Timer_After(0, function()
						QueueTrackedSpellCooldown(capturedSpellID, capturedGCDStart)
					end)
				else
					QueueTrackedSpellCooldown(capturedSpellID, capturedGCDStart)
				end
			end
		end

			if event == "ASSISTED_COMBAT_ACTION_SPELL_CAST" then
				local now = GetTime()
				gcdStartTime = now
				gcdDuration = GetGCDDurationClean()
				InvalidateCooldownVisuals()
				if NS.C_Timer_After then
					NS.C_Timer_After((gcdDuration or 0) + 0.03, function()
						InvalidateCooldownVisuals()
					end)
				end
				NS.UpdateNow()
			end

		-- Any binding/bar changes => wipe cache + refresh (debounced)
		if event == "UPDATE_BINDINGS" or event == "ACTIONBAR_SLOT_CHANGED" or event == "SPELLS_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED" or event == "UPDATE_BONUS_ACTIONBAR" or event == "UPDATE_VEHICLE_ACTIONBAR" or event == "UPDATE_OVERRIDE_ACTIONBAR" or event == "ACTIONBAR_UPDATE_STATE" or event == "PLAYER_TALENT_UPDATE" or event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UPDATE_SHAPESHIFT_FORM" or event == "TRAIT_CONFIG_UPDATED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
			if event == "TRAIT_CONFIG_UPDATED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
				NS.RefreshAvadaCachedData()
				NS.UpdateAvadaLayout()
			end
			DelayedUpdateKeybindings()
		end

		-- Visibility & Regen Changes
			if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" or event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" or event == "PLAYER_ENTERING_WORLD" then
				NS.UpdateVisibility()
				if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ENTERING_WORLD" then
					ScanAllCooldowns() -- Sync and cache all cooldowns when leaving combat or entering world!
				end
		end

		-- Target Changed
		if event == "PLAYER_TARGET_CHANGED" then
			NS.UpdateVisibility()
		end

		-- Cooldown Updates
		if event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" or event == "ACTIONBAR_UPDATE_COOLDOWN" then
			NS.UpdateNow()
			if not InCombatLockdown() then
				ScanAllCooldowns()
			end
		end

		-- Bag Items Cooldown
		if event == "BAG_UPDATE_COOLDOWN" then
			NS.UpdateNow()
		end
	end, self, event, ...)
end)
