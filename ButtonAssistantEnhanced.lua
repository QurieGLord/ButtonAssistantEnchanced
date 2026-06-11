-- ButtonAssistantEnhanced
-- Shows Blizzard Assisted Combat recommendations + keybinds (no Ace3)

local ADDON_NAME, NS = ...
local COOLDOWN_MODEL_VERSION = 2
local EFFECT_MODEL_VERSION = 6

-- Forward declarations of local clean functions
local UpdateButton
local UpdateCooldownForSpell
local UpdateAvada

-- Clean safe call for OnUpdate
local function SafeCallClean(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		print("|cff4e84b1[Button Assistant Enhanced Clean Error]|r " .. tostring(err))
	end
	return ok
end

-- Self-tracking Cooldown Engine (Bypasses secure sandboxing & secret values)
local cleanRecommendedSpellID = nil
local activeCooldowns = {}
local pendingCooldowns = {}
local chargeLedger = {}
local gcdStartTime = 0
local gcdDuration = 0
local cleanGCDDuration = 1.0 -- Cached out-of-combat
local clean_ignoreGCD = false
local cachedBaseCooldowns = {} -- Stores unhasted base durations and haste flags: { baseDuration = X, haste = Y }
local cachedActionSlots = {}
local IsDurationObjectZero
local cooldownVisualSerial = 0
local DURATION_OBJECT_REPAINT_INTERVAL = 0.18
local MAX_AVADA_ICONS = 6

local function GetGCDDurationClean()
	return cleanGCDDuration
end

local function InvalidateCooldownVisuals()
	cooldownVisualSerial = cooldownVisualSerial + 1
end

function NS.GetCleanHasteValue()
	local ok, haste = pcall(GetHaste)
	if not ok then
		return nil
	end

	local cleanOK, cleanHaste = pcall(function()
		if type(haste) == "number" then
			return haste + 0
		end
		return nil
	end)

	if cleanOK and cleanHaste then
		return cleanHaste
	end

	return nil
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
	if NS.RefreshChargeLedgerFromSpell then
		NS.RefreshChargeLedgerFromSpell(baseID)
		if baseID ~= spellID then
			NS.RefreshChargeLedgerFromSpell(spellID)
		end
	end
	local cd = C_Spell.GetSpellCooldown(baseID)

	-- 1. If currently on cooldown, populate activeCooldowns AND cache the duration
	if cd and cd.startTime and cd.duration and cd.duration > 1.5 then
		activeCooldowns[baseID] = {
			startTime = cd.startTime,
			duration = cd.duration
		}

		local haste = NS.GetCleanHasteValue() or 0
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
			local haste = NS.GetCleanHasteValue() or 0
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
			local trackedNow = GetTime()
			local entry = {
				startTime = now or GetTime(),
				duration = duration,
				createdAt = trackedNow,
				source = "cast",
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
local clean_keybindFont = "Numeric"
local clean_keybindFontSize = 12
local clean_keybindUseAssistantAction = false
local clean_showCooldown = true
local clean_showBorder = true
local clean_borderStyle = "classic"
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
local clean_effectGCDReady = { enabled = true, bounce = false, flash = true, pulse = false, color = "White" }
local clean_effectProcBounceEnabled = false
local clean_effectProcFlashEnabled = false
local clean_avadaEnabled = true
local clean_avadaBorderStyle = "classic"
local clean_avadaCustomCooldownText = true
local clean_avadaCooldownFont = "Numeric"
local clean_avadaCooldownFontSize = 12
local clean_avadaCooldownFontOutline = "OUTLINE"
local clean_avadaEffectReadyFlashEnabled = true
local clean_avadaEffectReadyPulseEnabled = true
local clean_avadaEffectReadyBounceEnabled = false
local clean_avadaEffectReadyColor = "Gold"

function NS.SyncCleanSettings()
	if not NS.db then return end
	clean_enabled = NS.db.enabled
	clean_buttonSize = NS.db.buttonSize or 40
	clean_showKeybind = NS.db.showKeybind
	clean_keybindFont = NS.db.keybindFont or "Numeric"
	clean_keybindFontSize = NS.db.keybindFontSize or 12
	clean_keybindUseAssistantAction = NS.db.keybindUseAssistantAction and true or false
	clean_showCooldown = NS.db.showCooldown
	clean_showBorder = NS.db.showBorder
	clean_borderStyle = NS.db.borderStyle or "classic"
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
	clean_effectGCDReady.enabled = NS.db.effectGCDReadyEnabled
	clean_effectGCDReady.bounce = NS.db.effectGCDReadyBounceEnabled
	clean_effectGCDReady.flash = NS.db.effectGCDReadyFlashEnabled
	clean_effectGCDReady.pulse = NS.db.effectGCDReadyPulseEnabled
	clean_effectGCDReady.color = NS.db.effectGCDReadyColor or "White"
	clean_effectProcBounceEnabled = NS.db.effectProcBounceEnabled
	clean_effectProcFlashEnabled = NS.db.effectProcFlashEnabled
	clean_avadaEnabled = NS.db.avadaEnabled
	clean_avadaBorderStyle = NS.db.avadaBorderStyle or "classic"
	clean_avadaCustomCooldownText = NS.db.avadaCustomCooldownText
	clean_avadaCooldownFont = NS.db.avadaCooldownFont or NS.db.cooldownFont or "Numeric"
	clean_avadaCooldownFontSize = NS.db.avadaCooldownFontSize or 12
	clean_avadaCooldownFontOutline = NS.db.avadaCooldownFontOutline or NS.db.cooldownFontOutline or "OUTLINE"
	clean_avadaEffectReadyFlashEnabled = NS.db.avadaEffectReadyFlashEnabled
	clean_avadaEffectReadyPulseEnabled = NS.db.avadaEffectReadyPulseEnabled
	clean_avadaEffectReadyBounceEnabled = NS.db.avadaEffectReadyBounceEnabled
	clean_avadaEffectReadyColor = NS.db.avadaEffectReadyColor or NS.db.glowReadyColor or "Gold"

	-- Cache clean hasted GCD duration out-of-combat
	if not InCombatLockdown() then
		local haste = NS.GetCleanHasteValue()
		if haste then
			cleanGCDDuration = 1.5 / (1 + haste / 100)
			if cleanGCDDuration < 0.75 then
				cleanGCDDuration = 0.75
			elseif cleanGCDDuration > 1.5 then
				cleanGCDDuration = 1.5
			end
		end
	end
end

-- ---------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------
local addonFrame = NS.CreateFrame("Frame", "ButtonAssistantEnhancedEventFrame")
local frame = NS.CreateFrame("Frame", "ButtonAssistantEnhancedFrame", NS.UIParent, "BackdropTemplate")
NS.frame = frame

frame:SetPoint("CENTER", NS.UIParent, "CENTER", 0, -120)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)

local function Round(value)
	if value >= 0 then
		return math.floor(value + 0.5)
	end
	return math.ceil(value - 0.5)
end

local function Clamp(value, minValue, maxValue)
	if value < minValue then
		return minValue
	elseif value > maxValue then
		return maxValue
	end
	return value
end

local function GetGridSize()
	local gridSize = NS.db and NS.db.editGridSize or 32
	if not gridSize or gridSize < 4 then
		gridSize = 4
	end
	return gridSize
end

local function SnapValue(value)
	local gridSize = GetGridSize()
	return Round((value or 0) / gridSize) * gridSize
end

local function MaybeSnapPosition(x, y)
	if NS.db and NS.db.editSnapToGrid then
		return SnapValue(x), SnapValue(y)
	end
	return Round(x or 0), Round(y or 0)
end

local function GetCenterOffset(target)
	if not target then
		return 0, 0
	end

	local x, y = target:GetCenter()
	local parentX, parentY = NS.UIParent:GetCenter()
	if not x or not y or not parentX or not parentY then
		return 0, 0
	end

	return x - parentX, y - parentY
end

local function SetFrameCenter(target, x, y)
	if not target then
		return
	end

	target:ClearAllPoints()
	target:SetPoint("CENTER", NS.UIParent, "CENTER", x or 0, y or 0)
end

local function SaveMainPosition(snap)
	if not NS.db then
		return
	end

	local x, y = GetCenterOffset(frame)
	if snap then
		x, y = MaybeSnapPosition(x, y)
		SetFrameCenter(frame, x, y)
	end
	NS.db.mainX = Round(x)
	NS.db.mainY = Round(y)
end

local function ApplyMainPosition()
	if not NS.db then
		return
	end

	SetFrameCenter(frame, NS.db.mainX or 0, NS.db.mainY or -120)
end

local function SaveAvadaPosition(snap)
	if not NS.db or not frame.avada then
		return
	end

	local x, y = GetCenterOffset(frame.avada)
	if snap then
		x, y = MaybeSnapPosition(x, y)
		SetFrameCenter(frame.avada, x, y)
	end
	NS.db.avadaX = Round(x)
	NS.db.avadaY = Round(y)
end

frame:SetScript("OnDragStart", function(self)
	if NS.db.locked and not NS.editMode then
		return
	end
	if NS.InCombatLockdown and NS.InCombatLockdown() then
		return
	end
	self:StartMoving()
end)

frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	SaveMainPosition(NS.editMode)
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
	local cooldownStartTime = chargesInfo.cooldownStartTime
	local cooldownDuration = chargesInfo.cooldownDuration
	if not IsCleanNumber(cooldownStartTime) then
		cooldownStartTime = nil
	end
	if not IsCleanNumber(cooldownDuration) then
		cooldownDuration = nil
	end

	local isActive = chargesInfo.isActive
	local isOnGCD = chargesInfo.isOnGCD
	if IsCleanBoolean(isActive) and IsCleanBoolean(isOnGCD) then
		return true, isActive == true, isOnGCD == true, charges, maxCharges, cooldownStartTime, cooldownDuration
	end

	if IsCleanBoolean(isActive) and isOnGCD == nil then
		return true, isActive == true, false, charges, maxCharges, cooldownStartTime, cooldownDuration
	end

	if maxCharges > 1 then
		return true, charges < maxCharges, false, charges, maxCharges, cooldownStartTime, cooldownDuration
	end

	return true, false, false, charges, maxCharges, cooldownStartTime, cooldownDuration
end

local function GetCleanSpellChargeState(spellID)
	local api = local_C_Spell_GetSpellCharges or (C_Spell and C_Spell.GetSpellCharges)
	if not api or not spellID then
		return false
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local known, active, onGCD, charges, maxCharges, cooldownStartTime, cooldownDuration = ReadSpellChargeStateForID(api, spellID)
	if known and active and not onGCD then
		return true, true, false, charges, maxCharges, cooldownStartTime, cooldownDuration
	end

	if baseID ~= spellID then
		local baseKnown, baseActive, baseOnGCD, baseCharges, baseMaxCharges, baseStartTime, baseDuration = ReadSpellChargeStateForID(api, baseID)
		if baseKnown and baseActive and not baseOnGCD then
			return true, true, false, baseCharges, baseMaxCharges, baseStartTime, baseDuration
		end
		if not known and baseKnown then
			return true, baseActive, baseOnGCD, baseCharges, baseMaxCharges, baseStartTime, baseDuration
		end
	end

	if known then
		return true, active, onGCD, charges, maxCharges, cooldownStartTime, cooldownDuration
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

local function ApplyConfiguredFont(fontString, fontKey, size, outline, fallbackFontObject)
	if not fontString then
		return
	end

	if type(fontKey) ~= "string" or not local_FontList or not local_FontList[fontKey] then
		fontKey = "Numeric"
	end

	local fontVal = local_FontList and local_FontList[fontKey] or fallbackFontObject or "NumberFontNormal"
	size = size or 12
	outline = outline or "OUTLINE"

	if type(fontVal) == "string" and fontVal:find("Interface\\") then
		fontString:SetFont(fontVal, size, outline)
	else
		fontString:SetFontObject(fontVal or fallbackFontObject or "NumberFontNormal")
		local customPath = fontString:GetFont()
		if customPath then
			fontString:SetFont(customPath, size, outline)
		end
	end
end

local function ApplyCooldownCountdownFont(cooldownFrame)
	if not cooldownFrame or not cooldownFrame.GetCountdownFontString then
		return
	end

	local ok, fontString = pcall(cooldownFrame.GetCountdownFontString, cooldownFrame)
	if not ok or not fontString then
		return
	end

	ApplyConfiguredFont(fontString, clean_cooldownFont, clean_cooldownFontSize or 14, clean_cooldownFontOutline or "OUTLINE", "NumberFontNormal")
end

local function ApplyAvadaCooldownCountdownFont(cooldownFrame)
	if not cooldownFrame or not cooldownFrame.GetCountdownFontString then
		return
	end

	local ok, fontString = pcall(cooldownFrame.GetCountdownFontString, cooldownFrame)
	if not ok or not fontString then
		return
	end

	ApplyConfiguredFont(fontString, clean_avadaCooldownFont or clean_cooldownFont, clean_avadaCooldownFontSize or 12, clean_avadaCooldownFontOutline or clean_cooldownFontOutline or "OUTLINE", "NumberFontNormal")
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
	local known, _, _, charges, maxCharges, cooldownStartTime, cooldownDuration = GetCleanSpellChargeState(spellID)
	if known and IsCleanNumber(charges) and IsCleanNumber(maxCharges) then
		return charges, maxCharges, cooldownStartTime, cooldownDuration
	end

	return nil
end

function NS.GetChargeLedgerKey(spellID)
	if not spellID then
		return nil
	end
	return FindBaseSpellByID(spellID) or spellID
end

function NS.GetStoredChargeLedger(spellID)
	local key = NS.GetChargeLedgerKey(spellID)
	if not key then
		return nil
	end
	return chargeLedger[key] or chargeLedger[spellID]
end

function NS.StoreChargeLedger(spellID, entry)
	local key = NS.GetChargeLedgerKey(spellID)
	if not key or not entry then
		return nil
	end

	entry.spellID = spellID
	entry.baseID = key
	chargeLedger[key] = entry
	if key ~= spellID then
		chargeLedger[spellID] = entry
	end
	return entry
end

function NS.EstimateChargeRechargeDuration(spellID, fallbackDuration)
	local gcdThreshold = math.max(1.55, ((gcdDuration and gcdDuration > 0 and gcdDuration) or cleanGCDDuration or 1.5) + 0.10)
	if fallbackDuration and fallbackDuration > gcdThreshold then
		return fallbackDuration
	end

	local duration = GetSpellCooldownDurationClean(spellID)
	if duration and duration > gcdThreshold then
		return duration
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local baseMS = GetSpellBaseCooldownMSClean(baseID)
	if (not baseMS or baseMS <= gcdThreshold * 1000) and baseID ~= spellID then
		baseMS = GetSpellBaseCooldownMSClean(spellID)
	end
	if baseMS and baseMS > gcdThreshold * 1000 then
		duration = baseMS / 1000
		if baseMS < 60000 then
			duration = duration * (cleanGCDDuration / 1.5)
		end
		return duration
	end

	return nil
end

function NS.AdvanceChargeLedger(entry, now)
	if not entry or not entry.maxCharges or entry.maxCharges <= 1 then
		return entry
	end

	now = now or GetTime()
	entry.currentCharges = Clamp(Round(entry.currentCharges or entry.maxCharges), 0, entry.maxCharges)

	if entry.currentCharges >= entry.maxCharges then
		entry.rechargeStart = nil
		entry.rechargeDuration = nil
		entry.nextReadyAt = nil
		return entry
	end

	local duration = entry.rechargeDuration
	local nextReadyAt = entry.nextReadyAt
	if not nextReadyAt and entry.rechargeStart and duration and duration > 0 then
		nextReadyAt = entry.rechargeStart + duration
		entry.nextReadyAt = nextReadyAt
	end

	if duration and duration > 0 and nextReadyAt then
		while entry.currentCharges < entry.maxCharges and now + 0.02 >= nextReadyAt do
			entry.currentCharges = entry.currentCharges + 1
			if entry.currentCharges < entry.maxCharges then
				nextReadyAt = nextReadyAt + duration
				entry.rechargeStart = nextReadyAt - duration
				entry.nextReadyAt = nextReadyAt
			else
				entry.rechargeStart = nil
				entry.rechargeDuration = nil
				entry.nextReadyAt = nil
			end
		end
	end

	return entry
end

function NS.RefreshChargeLedgerFromSpell(spellID)
	if not spellID then
		return nil, false
	end

	local known, _, onGCD, charges, maxCharges, cooldownStartTime, cooldownDuration = GetCleanSpellChargeState(spellID)
	if not known or not IsCleanNumber(charges) or not IsCleanNumber(maxCharges) or maxCharges <= 1 then
		return nil, false
	end

	local now = GetTime()
	local gcdThreshold = math.max(1.55, ((gcdDuration and gcdDuration > 0 and gcdDuration) or cleanGCDDuration or 1.5) + 0.10)
	maxCharges = Clamp(Round(maxCharges), 1, 99)
	charges = Clamp(Round(charges), 0, maxCharges)

	local entry = NS.GetStoredChargeLedger(spellID) or {}
	NS.AdvanceChargeLedger(entry, now)
	local ledgerHasRecharge = entry.maxCharges == maxCharges
		and entry.currentCharges
		and entry.currentCharges < maxCharges
		and entry.rechargeStart
		and entry.rechargeDuration
		and entry.rechargeDuration > 0
		and entry.nextReadyAt
		and entry.nextReadyAt > now
	local nativeLooksLikeGCD = onGCD == true or (cooldownDuration and cooldownDuration > 0 and cooldownDuration <= gcdThreshold)
	local nativeRechargeActive = charges < maxCharges
		and cooldownStartTime
		and cooldownDuration
		and cooldownDuration > 0
		and not nativeLooksLikeGCD
		and cooldownStartTime + cooldownDuration > now

	if nativeLooksLikeGCD then
		cooldownStartTime = nil
		cooldownDuration = nil
	end

	if ledgerHasRecharge and charges >= maxCharges then
		return NS.AdvanceChargeLedger(NS.StoreChargeLedger(spellID, entry), now), true
	end

	if charges >= maxCharges and cooldownStartTime and cooldownDuration and cooldownDuration > 0 and cooldownDuration > gcdThreshold and cooldownStartTime + cooldownDuration > now then
		charges = maxCharges - 1
		nativeRechargeActive = true
	end

	if ledgerHasRecharge and charges < maxCharges then
		local nativeExpired = not nativeRechargeActive
		local nativeEnd = cooldownStartTime and cooldownDuration and cooldownStartTime + cooldownDuration
		local ledgerEnd = entry.rechargeStart and entry.rechargeDuration and entry.rechargeStart + entry.rechargeDuration
		local nativeLooksStale = cooldownStartTime
			and entry.rechargeStart
			and cooldownStartTime < entry.rechargeStart - 0.05
			and (not nativeEnd or not ledgerEnd or nativeEnd >= ledgerEnd - 0.05)
		if nativeExpired or nativeLooksStale then
			cooldownStartTime = entry.rechargeStart
			cooldownDuration = entry.rechargeDuration
			nativeRechargeActive = true
		end
	end

	entry.maxCharges = maxCharges
	entry.currentCharges = charges
	entry.lastCleanAt = now

	if charges < maxCharges and cooldownStartTime and cooldownDuration and cooldownDuration > 0 then
		entry.rechargeStart = cooldownStartTime
		entry.rechargeDuration = cooldownDuration
		entry.nextReadyAt = cooldownStartTime + cooldownDuration
	elseif charges < maxCharges and ledgerHasRecharge then
		entry.rechargeStart = entry.rechargeStart
		entry.rechargeDuration = entry.rechargeDuration
		entry.nextReadyAt = entry.nextReadyAt
	elseif charges < maxCharges then
		local duration = NS.EstimateChargeRechargeDuration(spellID, entry.rechargeDuration)
		if duration and duration > 0 then
			entry.rechargeStart = now
			entry.rechargeDuration = duration
			entry.nextReadyAt = now + duration
		end
	else
		entry.rechargeStart = nil
		entry.rechargeDuration = nil
		entry.nextReadyAt = nil
	end

	return NS.AdvanceChargeLedger(NS.StoreChargeLedger(spellID, entry), now), true
end

function NS.GetChargeStateForDisplay(spellID)
	local entry, clean = NS.RefreshChargeLedgerFromSpell(spellID)
	if not entry then
		entry = NS.GetStoredChargeLedger(spellID)
		if entry then
			entry = NS.AdvanceChargeLedger(entry)
		end
	end

	if entry and entry.maxCharges and entry.maxCharges > 1 then
		return entry.currentCharges, entry.maxCharges, entry.rechargeStart, entry.rechargeDuration, clean and "native" or "ledger"
	end

	return nil
end

function NS.NoteChargeDurationObjectState(spellID, isZero)
	local entry = NS.GetStoredChargeLedger(spellID)
	if not entry or not entry.maxCharges or entry.maxCharges <= 1 then
		return
	end

	local now = GetTime()
	NS.AdvanceChargeLedger(entry, now)
	if isZero == true then
		if entry.currentCharges < entry.maxCharges and entry.nextReadyAt and entry.nextReadyAt > now then
			return
		end
		entry.currentCharges = entry.maxCharges
		entry.rechargeStart = nil
		entry.rechargeDuration = nil
		entry.nextReadyAt = nil
		return
	end

	if isZero == false and entry.currentCharges >= entry.maxCharges then
		entry.currentCharges = entry.maxCharges - 1
	end

	if isZero == false and entry.currentCharges < entry.maxCharges and not entry.nextReadyAt then
		local duration = NS.EstimateChargeRechargeDuration(spellID, entry.rechargeDuration)
		if duration and duration > 0 then
			entry.rechargeStart = now
			entry.rechargeDuration = duration
			entry.nextReadyAt = now + duration
		end
	end
end

function NS.NoteSpellChargeCast(spellID, startTime)
	local entry = NS.GetStoredChargeLedger(spellID)
	if not entry or not entry.maxCharges or entry.maxCharges <= 1 then
		local known, _, _, charges, maxCharges = GetCleanSpellChargeState(spellID)
		if not known or not IsCleanNumber(maxCharges) or maxCharges <= 1 then
			return false
		end

		maxCharges = Clamp(Round(maxCharges), 1, 99)
		local observedCharges = IsCleanNumber(charges) and Clamp(Round(charges), 0, maxCharges) or maxCharges
		entry = NS.StoreChargeLedger(spellID, {
			maxCharges = maxCharges,
			currentCharges = Clamp(observedCharges + 1, 0, maxCharges),
		})
		if not entry then
			return false
		end
	end

	local now = startTime or GetTime()
	NS.AdvanceChargeLedger(entry, now)
	if entry.currentCharges <= 0 then
		return false
	end

	entry.currentCharges = entry.currentCharges - 1
	if entry.currentCharges < entry.maxCharges and not entry.nextReadyAt then
		local duration = NS.EstimateChargeRechargeDuration(spellID, entry.rechargeDuration)
		if duration and duration > 0 then
			entry.rechargeStart = now
			entry.rechargeDuration = duration
			entry.nextReadyAt = now + duration
		end
	end

	return true
end

function NS.RefreshWatchedChargeLedgers()
	if cleanRecommendedSpellID then
		NS.RefreshChargeLedgerFromSpell(cleanRecommendedSpellID)
	end

	local list = local_GetAvadaTargetList and local_GetAvadaTargetList()
	if not list then
		return
	end

	for i = 1, MAX_AVADA_ICONS do
		local data = list[i]
		if data and data.type == "cd" and data.spellID then
			NS.RefreshChargeLedgerFromSpell(data.spellID)
		end
	end
end

local function GetChargeCooldownKey(charges, maxCharges, cooldownStartTime, cooldownDuration)
	if not charges or not maxCharges or maxCharges <= 1 then
		return nil
	end

	local startKey = IsCleanNumber(cooldownStartTime) and Round(cooldownStartTime * 10) or 0
	local durationKey = IsCleanNumber(cooldownDuration) and Round(cooldownDuration * 10) or 0
	return tostring(charges) .. "/" .. tostring(maxCharges) .. ":" .. tostring(startKey) .. ":" .. tostring(durationKey)
end

local function GetChargeCooldownRemainingForText(spellID)
	local charges, maxCharges, cooldownStartTime, cooldownDuration = NS.GetChargeStateForDisplay(spellID)
	if charges and maxCharges and maxCharges > 1 and charges < maxCharges and cooldownStartTime and cooldownDuration and cooldownDuration > 0 then
		local remaining = cooldownStartTime + cooldownDuration - GetTime()
		if remaining > 0 then
			return remaining
		end
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
	local charges, maxCharges, chargeStartTime, chargeDuration = NS.GetChargeStateForDisplay(spellID)

	if charges and maxCharges and maxCharges > 1 then
		if charges > 0 then
			return false
		end
		if chargeStartTime and chargeDuration and chargeDuration > 0 and chargeStartTime + chargeDuration > now then
			return true
		end
	end

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

	local host = button.visualRoot or button
	local f = NS.CreateFrame("Frame", nil, host)
	f:SetAllPoints(button.icon or button)
	f:SetFrameLevel(host:GetFrameLevel() + 8)
	f:Hide()

	f.wash = f:CreateTexture(nil, "OVERLAY")
	f.wash:SetTexture("Interface\\Buttons\\WHITE8X8")
	f.wash:SetAllPoints()
	f.wash:SetBlendMode("ADD")

	f.sheenGlow = f:CreateTexture(nil, "OVERLAY")
	f.sheenGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
	f.sheenGlow:SetBlendMode("ADD")
	f.sheenGlow:Hide()
	if f.sheenGlow.SetRotation then
		f.sheenGlow:SetRotation(-0.42)
	end

	f.sheen = f:CreateTexture(nil, "OVERLAY")
	f.sheen:SetTexture("Interface\\Buttons\\WHITE8X8")
	f.sheen:SetBlendMode("ADD")
	f.sheen:Hide()
	if f.sheen.SetRotation then
		f.sheen:SetRotation(-0.42)
	end

	local function edge()
		local tex = f:CreateTexture(nil, "OVERLAY")
		tex:SetTexture("Interface\\Buttons\\WHITE8X8")
		tex:SetBlendMode("ADD")
		tex:Hide()
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

	local function setHold(self, alpha)
		local r, g, b = self.glowR or 1, self.glowG or 1, self.glowB or 1
		self.wash:SetVertexColor(r, g, b, 0.075 * alpha)
		self.top:SetVertexColor(r, g, b, 0.38 * alpha)
		self.bottom:SetVertexColor(r, g, b, 0.20 * alpha)
		self.left:SetVertexColor(r, g, b, 0.24 * alpha)
		self.right:SetVertexColor(r, g, b, 0.24 * alpha)
		self.wash:Show()
		self.top:Show()
		self.bottom:Show()
		self.left:Show()
		self.right:Show()
	end

	local function positionSheen(self, progress, alpha)
		local width = self:GetWidth()
		local height = self:GetHeight()
		if not width or width <= 1 or not height or height <= 1 then
			return
		end

		local r, g, b = self.glowR or 1, self.glowG or 1, self.glowB or 1
		local x = -width * 0.28 + width * 1.56 * progress
		self.sheenGlow:ClearAllPoints()
		self.sheenGlow:SetSize(math.max(18, width * 0.34), height * 1.40)
		self.sheenGlow:SetPoint("CENTER", self, "LEFT", x, 0)
		self.sheenGlow:SetVertexColor(r, g, b, 0.16 * alpha)
		self.sheenGlow:Show()

		self.sheen:ClearAllPoints()
		self.sheen:SetSize(math.max(5, width * 0.075), height * 1.24)
		self.sheen:SetPoint("CENTER", self, "LEFT", x, 0)
		self.sheen:SetVertexColor(1, 1, 1, 0.42 * alpha)
		self.sheen:Show()
	end

	f:SetScript("OnUpdate", function(self)
		local now = GetTime()
		if self.mode == "sheen" then
			local progress = (now - (self.startTime or now)) / (self.sheenDuration or 0.34)
			if progress >= 1 then
				self.sheen:Hide()
				self.sheenGlow:Hide()
				if self.persistent then
					self.mode = "settle"
					self.settleStart = now
					self.settleDuration = self.settleDuration or 0.16
					self:SetScale(1)
					setHold(self, 0.75)
				else
					self.mode = "fade"
					self.fadeStart = now
				end
			else
				local alpha = 0.55 + 0.45 * math.sin(math.pi * progress)
				self:SetScale(1)
				setHold(self, 0.24 + 0.50 * progress)
				positionSheen(self, progress, alpha)
			end
		elseif self.mode == "settle" then
			local progress = (now - (self.settleStart or now)) / (self.settleDuration or 0.16)
			if progress >= 1 then
				self.mode = "hold"
				self:SetScale(1.025)
				setHold(self, 1)
			else
				local expansion = 1 + 0.025 * progress
				self:SetScale(expansion)
				setHold(self, 0.75 + 0.25 * progress)
			end
			self.sheen:Hide()
			self.sheenGlow:Hide()
		elseif self.mode == "fade" then
			local progress = (now - (self.fadeStart or now)) / (self.fadeDuration or 0.14)
			if progress >= 1 then
				self:Hide()
				self.mode = nil
				self:SetScale(1)
			else
				local alpha = 1 - progress
				self:SetScale(1)
				setHold(self, 0.45 * alpha)
				self.sheen:Hide()
				self.sheenGlow:Hide()
			end
		elseif self.mode == "hold" then
			self:SetScale(1.025)
			setHold(self, 1)
			self.sheen:Hide()
			self.sheenGlow:Hide()
		end
	end)

	f.setHold = setHold

	button.focusPulse = f
	return f
end

local function HideFocusPulse(button)
	if button and button.focusPulse then
		local f = button.focusPulse
		f.mode = nil
		f.persistent = nil
		if f.sheen then
			f.sheen:Hide()
		end
		if f.sheenGlow then
			f.sheenGlow:Hide()
		end
		f:Hide()
		f:SetScale(1)
	end
end

local function EnsureTransitionPulse(button)
	if not button then
		return nil
	end

	if button.transitionPulse then
		return button.transitionPulse
	end

	local host = button.visualRoot or button
	local f = NS.CreateFrame("Frame", nil, host)
	f:SetAllPoints(button.icon or button)
	f:SetFrameLevel(host:GetFrameLevel() + 7)
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
	f.top:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	f.top:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
	f.top:SetHeight(2)
	f.bottom = edge()
	f.bottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
	f.bottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	f.bottom:SetHeight(2)
	f.left = edge()
	f.left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	f.left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
	f.left:SetWidth(2)
	f.right = edge()
	f.right:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
	f.right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	f.right:SetWidth(2)

	f:SetScript("OnUpdate", function(self)
		local now = GetTime()
		local progress = (now - (self.startTime or now)) / (self.duration or 0.22)
		if progress >= 1 then
			self:Hide()
			self:SetScale(1)
			return
		end

		local r, g, b = self.glowR or 1, self.glowG or 1, self.glowB or 1
		local alpha = 1 - progress
		self:SetScale(1 + 0.055 * progress)
		self.wash:SetVertexColor(r, g, b, 0.10 * alpha)
		self.top:SetVertexColor(r, g, b, 0.42 * alpha)
		self.bottom:SetVertexColor(r, g, b, 0.34 * alpha)
		self.left:SetVertexColor(r, g, b, 0.34 * alpha)
		self.right:SetVertexColor(r, g, b, 0.34 * alpha)
	end)

	button.transitionPulse = f
	return f
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

	local host = button.visualRoot or button
	local f = NS.CreateFrame("Frame", nil, host)
	f:SetAllPoints(button.icon or button)
	f:SetFrameLevel(host:GetFrameLevel() + 9)
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

	local host = button.visualRoot or button
	local f = NS.CreateFrame("Frame", nil, host)
	f:SetFrameLevel(host:GetFrameLevel() + 10)
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
	f:SetFrameLevel((button.visualRoot or button):GetFrameLevel() + 10)
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

local function ShowProcFocusGlow(button, colorName, fallbackName, restart)
	if not button then
		return
	end
	local f = EnsureFocusPulse(button)
	if not f then
		return
	end

	local rgb = GetGlowColorRGB(colorName, fallbackName)
	f.glowR, f.glowG, f.glowB = rgb[1], rgb[2], rgb[3]
	f.persistent = true
	f:SetScale(1)
	f:SetAlpha(1)
	f:Show()

	if restart or not f.mode or f.mode == "fade" then
		f.mode = "sheen"
		f.startTime = GetTime()
		f.sheenDuration = 0.34
		f.settleDuration = 0.16
		f.fadeDuration = 0.14
	elseif f.setHold then
		f:setHold(1)
	end
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
		local pulse = EnsureTransitionPulse(button)
		if pulse then
			local rgb = GetGlowColorRGB(colorName, fallbackName)
			pulse.glowR, pulse.glowG, pulse.glowB = rgb[1], rgb[2], rgb[3]
			pulse.startTime = now
			pulse.duration = 0.22
			pulse:SetScale(1)
			pulse:Show()
		end
	end
end

local function UpdateTransitionAnimations(button, now)
	if not button then
		return
	end

	now = now or GetTime()
	if button.isBouncing and button.bounceStart then
		local visual = button.visualRoot or button
		local progress = now - button.bounceStart
		local duration = 0.26
		if progress < duration then
			local amplitude = math.max(0.02, math.min((clean_bounceScale or 1.10) - 1.0, 0.28))
			local t = progress / duration
			local envelope = (1 - t) ^ 1.25
			local spring = math.sin(t * math.pi * 2)
			visual:SetScale(1 + amplitude * 1.35 * spring * envelope)
		else
			visual:SetScale(1)
			button.isBouncing = false
		end
	end

	if button.flash and button.flash:IsShown() and button.flashStart then
		local progress = now - button.flashStart
		local duration = 0.15
		if progress < duration then
			button.flash:SetAlpha(1.0 - (progress / duration))
		else
			button.flash:Hide()
		end
	end
end

local function OnButtonUpdate(self, elapsed)
	SafeCallClean(function()
		local now = GetTime()

		-- 1. Bounce scale animation
		if self.isBouncing and self.bounceStart then
			local visual = self.visualRoot or self
			local progress = now - self.bounceStart
			local duration = 0.26
			if progress < duration then
				local amplitude = math.max(0.02, math.min((clean_bounceScale or 1.10) - 1.0, 0.28))
				local t = progress / duration
				local envelope = (1 - t) ^ 1.25
				local spring = math.sin(t * math.pi * 2)
				visual:SetScale(1 + amplitude * 1.35 * spring * envelope)
			else
				visual:SetScale(1)
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

		-- 3. Throttled UI & Cooldown Visual Update (Runs every 0.05 seconds / 20 FPS)
		self.timeSinceLastUpdate = (self.timeSinceLastUpdate or 0) + elapsed
		if self.timeSinceLastUpdate >= 0.05 then
			self.timeSinceLastUpdate = 0

			-- Render suggestion button using cleanRecommendedSpellID
			UpdateButton(self, cleanRecommendedSpellID)

			-- Update Avada Tracker (runs in the clean rendering thread!)
			UpdateAvada()
		end

			-- 4. Out of combat background cooldown caching (runs every 1.0 second)
		if not InCombatLockdown() then
			self.timeSinceLastCacheScan = (self.timeSinceLastCacheScan or 0) + elapsed
			if self.timeSinceLastCacheScan >= 1.0 then
				self.timeSinceLastCacheScan = 0
				ScanAllCooldowns()
			end
		end

			-- 5. Custom Cooldown countdown text (runs every frame for smooth tick-down)
			local inGCD = not clean_ignoreGCD and gcdStartTime + gcdDuration > now
			if clean_customCooldownText and self.spellID and not inGCD then
				local remaining = GetChargeCooldownRemainingForText(self.spellID) or GetCooldownRemainingForText(self.spellID)
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

local function EnsureDarkBorder(button)
	if not button then
		return nil
	end
	if button.darkBorder then
		return button.darkBorder
	end

	local host = button.visualRoot or button
	local f = NS.CreateFrame("Frame", nil, host)
	f:SetFrameLevel(host:GetFrameLevel() + 6)
	f:Hide()

	local function makeLine()
		local tex = f:CreateTexture(nil, "OVERLAY")
		tex:SetTexture("Interface\\Buttons\\WHITE8X8")
		return tex
	end

	f.outerTop = makeLine()
	f.outerBottom = makeLine()
	f.outerLeft = makeLine()
	f.outerRight = makeLine()
	f.innerTop = makeLine()
	f.innerBottom = makeLine()
	f.innerLeft = makeLine()
	f.innerRight = makeLine()

	button.darkBorder = f
	return f
end

local function PositionLine(tex, parent, side, inset, thickness)
	tex:ClearAllPoints()
	if side == "TOP" then
		tex:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
		tex:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -inset, -inset)
		tex:SetHeight(thickness)
	elseif side == "BOTTOM" then
		tex:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", inset, inset)
		tex:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, inset)
		tex:SetHeight(thickness)
	elseif side == "LEFT" then
		tex:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
		tex:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", inset, inset)
		tex:SetWidth(thickness)
	else
		tex:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -inset, -inset)
		tex:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, inset)
		tex:SetWidth(thickness)
	end
end

local function ApplyDarkBorder(button, size)
	local f = EnsureDarkBorder(button)
	if not f then
		return
	end

	local target = button.icon or button
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", target, "TOPLEFT", -1, 1)
	f:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 1, -1)
	f:SetFrameLevel((button.visualRoot or button):GetFrameLevel() + 6)

	local outer = math.max(1, math.floor((size or 40) / 32 + 0.5))
	local inner = 1
	PositionLine(f.outerTop, f, "TOP", 0, outer)
	PositionLine(f.outerBottom, f, "BOTTOM", 0, outer)
	PositionLine(f.outerLeft, f, "LEFT", 0, outer)
	PositionLine(f.outerRight, f, "RIGHT", 0, outer)
	PositionLine(f.innerTop, f, "TOP", outer, inner)
	PositionLine(f.innerBottom, f, "BOTTOM", outer, inner)
	PositionLine(f.innerLeft, f, "LEFT", outer, inner)
	PositionLine(f.innerRight, f, "RIGHT", outer, inner)

	f.outerTop:SetVertexColor(0.015, 0.016, 0.018, 0.98)
	f.outerBottom:SetVertexColor(0.015, 0.016, 0.018, 0.98)
	f.outerLeft:SetVertexColor(0.015, 0.016, 0.018, 0.98)
	f.outerRight:SetVertexColor(0.015, 0.016, 0.018, 0.98)
	f.innerTop:SetVertexColor(0.20, 0.22, 0.24, 0.62)
	f.innerBottom:SetVertexColor(0.04, 0.045, 0.05, 0.72)
	f.innerLeft:SetVertexColor(0.12, 0.13, 0.15, 0.58)
	f.innerRight:SetVertexColor(0.04, 0.045, 0.05, 0.72)
	f:Show()
end

local function ApplyIconBorderStyle(button, size, showBorder, style)
	if not button then
		return
	end

	local useDark = showBorder and style == "dark"
	local useBlizzardDark = showBorder and style == "blizzardDark"
	if button.border then
		local borderSize = (size or 40) * 46 / 40
		button.border:SetSize(borderSize, borderSize)
		button.border:SetShown(showBorder and not useDark)
		if useBlizzardDark then
			button.border:SetVertexColor(0.18, 0.19, 0.21, 0.98)
		else
			button.border:SetVertexColor(1, 1, 1, 1)
		end
	end

	if useDark then
		ApplyDarkBorder(button, size)
	elseif button.darkBorder then
		button.darkBorder:Hide()
	end
end

local function CreateSuggestionButton(parent)
	local b = NS.CreateFrame("Frame", nil, parent, "BackdropTemplate")
	b:SetSize(NS.db.buttonSize, NS.db.buttonSize)
	b:SetFrameLevel(parent:GetFrameLevel() + 2)

	b.visualRoot = NS.CreateFrame("Frame", nil, b)
	b.visualRoot:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.visualRoot:SetSize(NS.db.buttonSize, NS.db.buttonSize)
	b.visualRoot:SetFrameLevel(b:GetFrameLevel() + 1)
	b.visualRoot:SetScale(1)

	b.icon = b.visualRoot:CreateTexture(nil, "BACKGROUND")
	b.icon:SetAllPoints()
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- Modern HUD Border
	b.border = b.visualRoot:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture("Interface/HUD/UIActionBar")
	b.border:SetTexCoord(0.707031, 0.886719, 0.248047, 0.291992)
	b.border:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
	b.border:SetSize(46, 45) -- Default size relative to 40px button, scaler will handle resizing

	b.cooldown = NS.CreateFrame("Cooldown", nil, b.visualRoot, "CooldownFrameTemplate")
	b.cooldown:SetAllPoints(b.icon)
	b.cooldown:SetFrameLevel(b.visualRoot:GetFrameLevel() + 1)
	-- One-time cooldown init (asNextSkill pattern — never set these per-frame!)
	ApplyCooldownWidgetStyle(b.cooldown, false)
	b.cooldown:Show() -- Show once, never Hide/Show cycle — use Clear() instead

	b.textLayer = NS.CreateFrame("Frame", nil, b.visualRoot)
	b.textLayer:SetAllPoints(b.icon)
	b.textLayer:SetFrameLevel(b.cooldown:GetFrameLevel() + 3)

	b.hotkey = b.textLayer:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall") -- Using a cleaner number font
	b.hotkey:SetPoint("TOPRIGHT", b.icon, "TOPRIGHT", -2, -2)
	b.hotkey:SetJustifyH("RIGHT")
	b.hotkey:SetDrawLayer("OVERLAY", 7)
	b.hotkeyCache = {}

	b.count = b.textLayer:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	b.count:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", -1, 1)
	b.count:SetJustifyH("RIGHT")
	b.count:SetDrawLayer("OVERLAY", 7)
	b.count:SetText("")
	b.count:Hide()

	-- Custom Cooldown Text Overlaid
	b.customCooldownText = b.textLayer:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.customCooldownText:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
	b.customCooldownText:SetJustifyH("CENTER")
	b.customCooldownText:SetDrawLayer("OVERLAY", 7)
	b.customCooldownText:Hide()

	-- Flash Overlay texture for swap animation
	b.flash = b.visualRoot:CreateTexture(nil, "OVERLAY")
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

	b.textLayer = NS.CreateFrame("Frame", nil, b)
	b.textLayer:SetAllPoints(b.icon)
	b.textLayer:SetFrameLevel(b.cooldown:GetFrameLevel() + 3)

	b.count = b.textLayer:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	b.count:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 0, 0)
	b.count:SetJustifyH("RIGHT")
	b.count:SetDrawLayer("OVERLAY", 7)

	b.customCooldownText = b.textLayer:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.customCooldownText:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
	b.customCooldownText:SetJustifyH("CENTER")
	b.customCooldownText:SetDrawLayer("OVERLAY", 7)
	b.customCooldownText:Hide()

	b.flash = b:CreateTexture(nil, "OVERLAY")
	b.flash:SetTexture("Interface\\Buttons\\WHITE8X8")
	b.flash:SetAllPoints(b.icon)
	b.flash:SetBlendMode("ADD")
	b.flash:SetAlpha(0)
	b.flash:Hide()

	return b
end

local function GetAvadaIconCount()
	local count = 0
	local list = local_GetAvadaTargetList and local_GetAvadaTargetList()
	if list then
		for i = 1, MAX_AVADA_ICONS do
			if list[i] and list[i].spellID then
				count = i
			end
		end
	end

	if count < 1 then
		count = MAX_AVADA_ICONS
	end
	return Clamp(count, 1, MAX_AVADA_ICONS)
end

local function GetAvadaGrid()
	local count = GetAvadaIconCount()
	local columns = Clamp(Round(NS.db.avadaColumns or count), 1, count)
	local rows = Clamp(Round(NS.db.avadaRows or math.ceil(count / columns)), 1, count)
	if columns * rows < count then
		rows = Clamp(math.ceil(count / columns), 1, count)
	end
	NS.db.avadaColumns = columns
	NS.db.avadaRows = rows
	return columns, rows, count
end

function NS.SetAvadaColumns(columns)
	if not NS.db then
		return
	end

	local count = GetAvadaIconCount()
	NS.db.avadaColumns = Clamp(Round(columns or count), 1, count)
	NS.db.avadaRows = Clamp(Round(NS.db.avadaRows or math.ceil(count / NS.db.avadaColumns)), 1, count)
	if NS.db.avadaColumns * NS.db.avadaRows < count then
		NS.db.avadaRows = math.ceil(count / NS.db.avadaColumns)
	end
	if NS.UpdateLayout then
		NS.UpdateLayout()
	end
end

function NS.SetAvadaRows(rows)
	if not NS.db then
		return
	end

	local count = GetAvadaIconCount()
	rows = Clamp(Round(rows or 1), 1, count)
	NS.db.avadaRows = rows
	NS.db.avadaColumns = Clamp(Round(NS.db.avadaColumns or math.ceil(count / rows)), 1, count)
	if NS.db.avadaColumns * NS.db.avadaRows < count then
		NS.db.avadaColumns = math.ceil(count / NS.db.avadaRows)
	end
	if NS.UpdateLayout then
		NS.UpdateLayout()
	end
end

function NS.UpdateAvadaLayout()
	if not frame.avada then
		frame.avada = NS.CreateFrame("Frame", "ButtonAssistantEnhancedAvadaFrame", NS.UIParent, "BackdropTemplate")
		frame.avada.icons = {}
		frame.avada:SetMovable(true)
		frame.avada:SetClampedToScreen(true)
	end

	local f = frame.avada
	local size = NS.db.avadaSize or 16
	local spacing = NS.db.avadaSpacing or 4
	local offsetY = NS.db.avadaOffsetY or -10
	local showBorder = NS.db.avadaShowBorder
	local columns, rows, count = GetAvadaGrid()

	f:ClearAllPoints()
	if NS.db.avadaDetached then
		SetFrameCenter(f, NS.db.avadaX or 0, NS.db.avadaY or -180)
	else
		f:SetPoint("TOP", frame.button, "BOTTOM", 0, offsetY)
	end
	f:SetScale(NS.db.avadaScale or 1.0)
	f:SetSize((size * columns) + (spacing * (columns - 1)), (size * rows) + (spacing * (rows - 1)))

	if not f.value then
		f.value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	end
	f.value:ClearAllPoints()
	f.value:SetPoint("RIGHT", frame.button, "LEFT", -10, 0)

	for i = 1, MAX_AVADA_ICONS do
		local icon = f.icons[i]
		if not icon then
			icon = CreateAvadaIcon(f, i)
			f.icons[i] = icon
		end
		icon:SetSize(size, size)
		icon:ClearAllPoints()
		if i <= count then
			local index = i - 1
			local col = index % columns
			local row = math.floor(index / columns)
			icon:SetPoint("TOPLEFT", f, "TOPLEFT", col * (size + spacing), -row * (size + spacing))
		end

		ApplyIconBorderStyle(icon, size, showBorder, NS.db.avadaBorderStyle or "classic")
		if icon.customCooldownText then
			ApplyConfiguredFont(icon.customCooldownText, NS.db.avadaCooldownFont or NS.db.cooldownFont or "Numeric", NS.db.avadaCooldownFontSize or 12, NS.db.avadaCooldownFontOutline or NS.db.cooldownFontOutline or "OUTLINE", "NumberFontNormal")
		end

		icon:SetShown((NS.editMode or NS.db.avadaEnabled) and i <= count)
	end
	f:SetShown(NS.editMode or NS.db.avadaEnabled)
end

function NS.UpdateLayout()
	local size = NS.db.buttonSize or 40
	local b = frame.button
	if not b then
		b = CreateSuggestionButton(frame)
		frame.button = b
	end

	-- Update Size
	ApplyMainPosition()
	b:SetSize(size, size)
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	if b.visualRoot then
		b.visualRoot:ClearAllPoints()
		b.visualRoot:SetPoint("CENTER", b, "CENTER", 0, 0)
		b.visualRoot:SetSize(size, size)
		if not b.isBouncing then
			b.visualRoot:SetScale(1)
		end
	end

	ApplyIconBorderStyle(b, size, NS.db.showBorder, NS.db.borderStyle or "classic")

	-- Update keybind text font and size
	ApplyConfiguredFont(b.hotkey, NS.db.keybindFont or "Numeric", NS.db.keybindFontSize or 12, "OUTLINE", "NumberFontNormalSmall")
	if b.count then
		ApplyConfiguredFont(b.count, NS.db.keybindFont or "Numeric", math.max(9, NS.db.keybindFontSize or 12), "OUTLINE", "NumberFontNormalSmall")
	end

	-- Update custom cooldown text font and size
	if b.customCooldownText then
		ApplyConfiguredFont(b.customCooldownText, NS.db.cooldownFont or "Numeric", NS.db.cooldownFontSize or 14, NS.db.cooldownFontOutline or "OUTLINE", "NumberFontNormal")
	end

	-- Sync Settings Copy
	NS.SyncCleanSettings()
	ApplyCooldownWidgetStyle(b.cooldown, false)
	b.cooldownVisualSerial = nil
	b.cooldownVisualNextRefresh = nil
	b.cooldownVisualKey = nil

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
		b.cooldownVisualChargeKey = nil
		b.cooldownVisualNextRefresh = nil
		b.cooldownVisualKey = nil
		if b.customCooldownText then b.customCooldownText:Hide() end
		return
	end

	local now = GetTime()
	local charges, maxCharges, chargeStartTime, chargeDuration = NS.GetChargeStateForDisplay(spellID)
	local chargeKey = GetChargeCooldownKey(charges, maxCharges, chargeStartTime, chargeDuration)
	local hasChargeCooldown = charges and maxCharges and maxCharges > 1 and charges < maxCharges
	local gcdActive = not clean_ignoreGCD and gcdStartTime + gcdDuration > now

	if b.cooldownVisualSpellID == spellID and b.cooldownVisualIgnoreGCD == clean_ignoreGCD and b.cooldownVisualSerial == cooldownVisualSerial and b.cooldownVisualChargeKey == chargeKey and (not b.cooldownVisualNextRefresh or b.cooldownVisualNextRefresh > now) then
		return
	end

	-- asNextSkill model: feed Blizzard's opaque DurationObject directly
	-- into the Cooldown widget. With no ignoreGCD argument it displays both
	-- GCD and real spell cooldowns, including in combat.
	local usingChargeCooldown = hasChargeCooldown and not gcdActive
	local durationobj
	if usingChargeCooldown then
		if not (chargeStartTime and chargeDuration and chargeDuration > 0) then
			durationobj = TryGetSpellChargeDurationObject(spellID)
		end
	else
		durationobj = TryGetSpellCooldownDurationObject(spellID, clean_ignoreGCD)
	end
	if durationobj then
		local durationZero = IsDurationObjectZero(durationobj)
		if usingChargeCooldown then
			NS.NoteChargeDurationObjectState(spellID, durationZero)
		end
		if durationZero == true then
			if usingChargeCooldown and chargeStartTime and chargeDuration and chargeDuration > 0 then
				durationobj = nil
			else
				local readyKey = tostring(spellID) .. ":" .. tostring(clean_ignoreGCD) .. ":" .. tostring(chargeKey or "nocharge") .. ":ready"
				ClearTrackedSpellCooldown(spellID)
				if b.cooldownVisualKey ~= readyKey then
					ClearCooldownWidget(b.cooldown, true)
				end
				b.cooldownVisualSpellID = spellID
				b.cooldownVisualIgnoreGCD = clean_ignoreGCD
				b.cooldownVisualSerial = cooldownVisualSerial
				b.cooldownVisualChargeKey = chargeKey
				b.cooldownVisualNextRefresh = nil
				b.cooldownVisualKey = readyKey
				return
			end
			elseif durationZero == nil then
				durationobj = nil
			end

			if durationobj then
				local ok = pcall(b.cooldown.SetCooldownFromDurationObject, b.cooldown, durationobj)
				if ok then
					local activeKey = tostring(spellID) .. ":" .. tostring(clean_ignoreGCD) .. ":" .. tostring(chargeKey or "nocharge") .. ":duration"
					ApplyCooldownWidgetStyle(b.cooldown, false)
					b.cooldown:Show()
					b.cooldownVisualSpellID = spellID
					b.cooldownVisualIgnoreGCD = clean_ignoreGCD
					b.cooldownVisualSerial = cooldownVisualSerial
					b.cooldownVisualChargeKey = chargeKey
					b.cooldownVisualNextRefresh = now + DURATION_OBJECT_REPAINT_INTERVAL
					b.cooldownVisualKey = activeKey
					return
				end
			end
	end

	-- Fallback continuity path for rare API gaps: use the clean local ledger.
	local startTime, duration
	if usingChargeCooldown and chargeStartTime and chargeDuration and chargeDuration > 0 then
		startTime, duration = chargeStartTime, chargeDuration
	elseif not clean_ignoreGCD and gcdStartTime + gcdDuration > now then
		startTime, duration = gcdStartTime, gcdDuration
	elseif not InCombatLockdown() then
		startTime, duration = GetSpellCooldownClean(spellID)
	else
		startTime, duration = 0, 0
	end
	if startTime and duration and startTime > 0 and duration > 0 then
		local activeKey = tostring(spellID) .. ":" .. tostring(clean_ignoreGCD) .. ":" .. tostring(chargeKey or "nocharge") .. ":fallback"
		SafeSetCooldown(b.cooldown, startTime, duration)
		ApplyCooldownWidgetStyle(b.cooldown, false)
		b.cooldown:Show()
		b.cooldownVisualSpellID = spellID
		b.cooldownVisualIgnoreGCD = clean_ignoreGCD
		b.cooldownVisualSerial = cooldownVisualSerial
		b.cooldownVisualChargeKey = chargeKey
		b.cooldownVisualNextRefresh = nil
		b.cooldownVisualKey = activeKey
		return
	end

	local readyKey = tostring(spellID) .. ":" .. tostring(clean_ignoreGCD) .. ":" .. tostring(chargeKey or "nocharge") .. ":ready"
	if b.cooldownVisualKey ~= readyKey then
		ClearCooldownWidget(b.cooldown, true)
	end
	b.cooldownVisualSpellID = spellID
	b.cooldownVisualIgnoreGCD = clean_ignoreGCD
	b.cooldownVisualSerial = cooldownVisualSerial
	b.cooldownVisualChargeKey = chargeKey
	b.cooldownVisualNextRefresh = nil
	b.cooldownVisualKey = readyKey
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

		if NS.editMode then
			f:SetAlpha(1)
			f:Show()
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

local function GetStableKeybindText(button, spellID, changed)
	if not button or not spellID then
		return ""
	end

	button.hotkeyCache = button.hotkeyCache or {}
	if clean_keybindUseAssistantAction then
		local text = NS.GetAssistantKeyBind and NS.GetAssistantKeyBind()
		if text and text ~= "" then
			button.lastAssistantHotkeyText = text
			return text
		end
		return button.lastAssistantHotkeyText or ""
	end

	if not local_GetKeyBindForSpellID then
		return ""
	end

	local baseID = FindBaseSpellByID(spellID) or spellID
	local text = local_GetKeyBindForSpellID(spellID)
	if text and text ~= "" then
		button.hotkeyCache[spellID] = text
		button.hotkeyCache[baseID] = text
		button.lastHotkeySpellID = spellID
		return text
	end

	text = button.hotkeyCache[spellID] or button.hotkeyCache[baseID]
	if text and text ~= "" then
		return text
	end

	if not changed and button.lastHotkeySpellID == spellID and button.hotkey and button.hotkey.GetText then
		text = button.hotkey:GetText()
		if text and text ~= "" then
			return text
		end
	end

	return ""
end

function UpdateButton(b, spellID)
					SafeCallClean(function()
						if not spellID then
							b.spellID = nil
							b.icon:SetTexture(nil)
						b.hotkey:SetText("")
						if b.cooldownVisualKey ~= "empty" then
							ClearCooldownWidget(b.cooldown, false)
						end
						b.cooldownVisualSpellID = nil
						b.cooldownVisualIgnoreGCD = nil
						b.cooldownVisualSerial = nil
						b.cooldownVisualChargeKey = nil
						b.cooldownVisualKey = "empty"
						if b.count then
							b.count:SetText("")
							b.count:Hide()
						end
						if b.customCooldownText then b.customCooldownText:Hide() end
					HideProcEffects(b)
					HideFocusPulse(b)
					if b.transitionPulse then
						b.transitionPulse:Hide()
						b.transitionPulse:SetScale(1)
					end
					if b.flash then b.flash:Hide() end
				b.lastSpellID = nil
						b.lastCooldownActive = nil
							b.lastReady = nil
							b.lastProc = nil
							b.lastChargeCount = nil
							b.lastGCDActive = nil
							b.lastHotkeySpellID = nil
					b.lastAssistantHotkeyText = nil
					b.procGraceUntil = nil
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

				if b.count then
					local charges, maxCharges = NS.GetChargeStateForDisplay(spellID)
					if charges and maxCharges and maxCharges > 1 then
						b.count:SetText(tostring(charges))
						if charges == maxCharges then
							b.count:SetTextColor(1, 0.15, 0.15)
						else
							b.count:SetTextColor(1, 1, 1)
						end
						b.count:Show()
					else
						b.count:SetText("")
						b.count:Hide()
					end
				end

				if clean_showKeybind then
				local text = GetStableKeybindText(b, spellID, changed)
				b.hotkey:SetText(text)
				b.hotkey:SetShown(text ~= "")
			else
				b.hotkey:SetText("")
				b.hotkey:Hide()
				b.lastHotkeySpellID = nil
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
						local now = GetTime()
						local charges, maxCharges = NS.GetChargeStateForDisplay(spellID)
						local chargeReadyEvent = charges and maxCharges and maxCharges > 1 and b.lastChargeCount and charges > b.lastChargeCount
						local gcdActive = not clean_ignoreGCD and gcdStartTime + gcdDuration > now
						local gcdReadyEvent = b.lastGCDActive == true and not gcdActive
						if changed then
							b.procGraceUntil = nil
						end
				if isProc then
					b.procGraceUntil = now + 0.25
				end
				local procHasPriority = isProc or (not changed and b.procGraceUntil and b.procGraceUntil > now)

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

				if realCooldownActive and not procHasPriority then
					desaturated = true
					if isUsable and not outOfRange then
						r, g, bColor = 0.4, 0.4, 0.4
					end
				end

				local isReady = (procHasPriority or not realCooldownActive) and isUsable and not outOfRange

		b.icon:SetVertexColor(r, g, bColor)
		b.icon:SetDesaturated(desaturated)

						local effectsAllowed = ShouldPlayVisualEffects()
						local firedNextReady = false
						if changed then
							b.pendingNextReadySpellID = effectsAllowed and not procHasPriority and spellID or nil
						elseif not effectsAllowed or procHasPriority then
							b.pendingNextReadySpellID = nil
						end

						if effectsAllowed and b.pendingNextReadySpellID == spellID and isReady and not procHasPriority then
							TriggerButtonTransitionEffect(b, clean_enableFlashOverlay, clean_enableBounceAnim, clean_effectNextReadyPulseEnabled, "White", "White")
							b.pendingNextReadySpellID = nil
							firedNextReady = true
						end

								local firedCooldownReady = false
								if effectsAllowed and not firedNextReady and not changed and not procHasPriority and isReady and ((b.lastCooldownActive == true and realCooldownActive == false) or chargeReadyEvent) then
									TriggerButtonTransitionEffect(b, clean_effectReadyFlashEnabled, clean_effectReadyBounceEnabled, clean_effectReadyPulseEnabled, clean_glowReadyColor, "Gold")
									b.pendingNextReadySpellID = nil
									firedCooldownReady = true
								end

									if effectsAllowed and clean_effectGCDReady.enabled and not firedNextReady and not firedCooldownReady and not changed and not procHasPriority and isReady and gcdReadyEvent then
										TriggerButtonTransitionEffect(b, clean_effectGCDReady.flash, clean_effectGCDReady.bounce, clean_effectGCDReady.pulse, clean_effectGCDReady.color, "White")
									end

					if effectsAllowed and isProc and (changed or b.lastProc ~= true) then
						TriggerButtonTransitionEffect(b, clean_effectProcFlashEnabled, clean_effectProcBounceEnabled, false, clean_glowProcColor, "White")
					end

					if effectsAllowed and procHasPriority and clean_glowProcEnabled then
						local procRGB = GetGlowColorRGB(clean_glowProcColor, "White")
						b.glowR, b.glowG, b.glowB = procRGB[1], procRGB[2], procRGB[3]
						local procGlowRestart = changed or b.lastProc ~= true or b.procGlowStyle ~= clean_glowProcType

					if clean_glowProcType == "focusPulse" then
						HideProcSweepGlow(b)
						HideBlizzardProcGlow(b)
						ShowProcFocusGlow(b, clean_glowProcColor, "White", procGlowRestart)
						b.procGlowStyle = "focusPulse"
					elseif clean_glowProcType == "none" then
						HideProcEffects(b)
					elseif clean_glowProcType == "sweepBorder" then
						HideBlizzardProcGlow(b)
						if ShowProcSweepGlow(b, changed or b.lastProc ~= true or b.procGlowStyle ~= "sweepBorder", clean_glowProcColor, "White") then
							HideFocusPulse(b)
							b.procGlowStyle = "sweepBorder"
						else
							ShowProcFocusGlow(b, clean_glowProcColor, "White", changed or b.lastProc ~= true or b.procGlowStyle ~= "focusPulse")
							b.procGlowStyle = "focusPulse"
						end
					else
						HideProcSweepGlow(b)
						if ShowBlizzardProcGlow(b, changed or b.lastProc ~= true or b.procGlowStyle ~= "blizzardProc") then
							HideFocusPulse(b)
							b.procGlowStyle = "blizzardProc"
						else
							ShowProcFocusGlow(b, clean_glowProcColor, "White", changed or b.lastProc ~= true or b.procGlowStyle ~= "focusPulse")
							b.procGlowStyle = "focusPulse"
						end
						end
				else
					HideProcEffects(b)
				end

				b.lastSpellID = spellID
					b.lastCooldownActive = realCooldownActive
					b.lastReady = isReady
					b.lastProc = procHasPriority
					b.lastChargeCount = charges and maxCharges and maxCharges > 1 and charges or nil
					b.lastGCDActive = gcdActive
					b:Show()
				end)
			end

local function ReadRealCooldownSnapshotForID(api, spellID, now)
	if not api or not spellID then
		return nil
	end

	local ok, cooldownInfo = pcall(api, spellID)
	if not ok or type(cooldownInfo) ~= "table" then
		return nil
	end

	local startTime = cooldownInfo.startTime
	local duration = cooldownInfo.duration
	if not IsCleanNumber(startTime) or not IsCleanNumber(duration) then
		return nil
	end

	local isOnGCD = cooldownInfo.isOnGCD
	if IsCleanBoolean(isOnGCD) and isOnGCD == true then
		return nil
	end

	if startTime > 0 and duration > 1.55 then
		local remaining = startTime + duration - now
		if remaining > 0 then
			return startTime, duration, remaining
		end
	end

	return nil
end

local function GetRealCooldownSnapshot(spellID)
	if not spellID then
		return false
	end

	local now = GetTime()
	local baseID = FindBaseSpellByID(spellID) or spellID
	local api = local_C_Spell_GetSpellCooldown or (C_Spell and C_Spell.GetSpellCooldown)
	if api and not InCombatLockdown() then
		local startTime, duration, remaining = ReadRealCooldownSnapshotForID(api, baseID, now)
		if startTime then
			return true, startTime, duration, remaining, "native"
		end
		if baseID ~= spellID then
			startTime, duration, remaining = ReadRealCooldownSnapshotForID(api, spellID, now)
			if startTime then
				return true, startTime, duration, remaining, "native"
			end
		end

		local known, active, onGCD = GetCleanSpellCooldownState(spellID)
		if known and (not active or onGCD) then
			ClearTrackedSpellCooldown(spellID)
			return false
		end
	end

	local remaining = GetCooldownRemainingForText(spellID)
	if remaining and remaining > 1.55 then
		local duration = GetSpellCooldownDurationClean(spellID)
		if not duration or duration <= remaining then
			duration = remaining
		end
		return true, now - (duration - remaining), duration, remaining, "remaining"
	end

	local cd = activeCooldowns[baseID] or activeCooldowns[spellID]
	if cd and cd.startTime and cd.duration then
		local trackedRemaining = cd.startTime + cd.duration - now
		if trackedRemaining > 0 then
			return true, cd.startTime, cd.duration, trackedRemaining, "tracked"
		end
		ClearTrackedSpellCooldown(spellID)
	end

	return false
end

	function UpdateAvada()
		if (not clean_avadaEnabled and not NS.editMode) or not frame.avada then
			if frame.avada then
				frame.avada:Hide()
		end
		return
	end

	local list = local_GetAvadaTargetList()
	if not list then
		if NS.editMode then
			list = {}
		else
			frame.avada:Hide()
			return
		end
	end

	frame.avada:Show()
	local showValue = false
	local tracker = frame.avada

	for i = 1, MAX_AVADA_ICONS do
		local icon = tracker.icons[i]
		local data = list[i]
		if data and data.spellID then
			local unit = data.unit
			local aType = data.type
			local id = data.spellID
			local iconChanged = icon.spellID ~= id or icon.aType ~= aType
			if iconChanged then
				icon.lastCooldownActive = nil
				icon.lastChargeCount = nil
				icon.spellID = id
				icon.aType = aType
			end

			local tex = local_C_Spell_GetSpellTexture(local_AvadaReplacedTexture[id] or id)
			if aType == "item" then
				tex = local_C_Item_GetItemIconByID or local_C_Spell_GetSpellTexture(id)
				if local_C_Item_GetItemIconByID then
					tex = local_C_Item_GetItemIconByID(id)
				end
			end
			icon.icon:SetTexture(tex or "Interface/Icons/INV_Misc_QuestionMark")

			local countText = ""
			local startTime, duration = 0, 0
			local countColor = { 1, 1, 1 }
			local desaturated = false
			local cooldownHandled = false
				local cooldownIsZero = false
				local cooldownReadyCached = false
				local cooldownRemaining
				local useNativeCooldownText = false
				local avadaCooldownActive = false
				local chargeReadyEvent = false
				local chargeHasUsableStack = false
				local chargeDisplayCount = nil

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
					local now = GetTime()
					local charges, maxCharges, chargeStartTime, chargeDuration = NS.GetChargeStateForDisplay(id)
					if charges and maxCharges and maxCharges > 1 then
						countText = tostring(charges)
						chargeDisplayCount = charges
						chargeHasUsableStack = charges > 0
						chargeReadyEvent = icon.lastChargeCount and charges > icon.lastChargeCount
					end

					local preferChargeCooldown = charges and maxCharges and maxCharges > 1 and charges < maxCharges
					local chargeKey = GetChargeCooldownKey(charges, maxCharges, chargeStartTime, chargeDuration)
					local realActive, realStart, realDuration, realRemaining, realSource = GetRealCooldownSnapshot(id)
					local durationobj
					if preferChargeCooldown then
						if not (chargeStartTime and chargeDuration and chargeDuration > 0) then
							durationobj = TryGetSpellChargeDurationObject(id)
						end
					else
						durationobj = TryGetSpellCooldownDurationObject(id, true)
					end
					local durationZero = durationobj and IsDurationObjectZero(durationobj)

					if preferChargeCooldown then
						realActive = true
						NS.NoteChargeDurationObjectState(id, durationZero)
						if chargeStartTime and chargeDuration then
							realStart = chargeStartTime
							realDuration = chargeDuration
						end
					end

					if durationobj and durationZero == false then
						realActive = true
						realSource = "duration"
					elseif durationobj and durationZero == true then
						if preferChargeCooldown and chargeStartTime and chargeDuration and chargeDuration > 0 then
							durationobj = nil
							durationZero = nil
						else
							realActive = false
							realSource = "duration"
							cooldownIsZero = true
							ClearTrackedSpellCooldown(id)
						end
					elseif durationobj and durationZero == nil then
						durationobj = nil
					end

					if preferChargeCooldown then
						cooldownRemaining = GetChargeCooldownRemainingForText(id)
					elseif realSource ~= "tracked" then
						cooldownRemaining = realRemaining
					end
					cooldownRemaining = cooldownRemaining or GetCooldownRemainingForText(id)
					if (not cooldownRemaining or cooldownRemaining <= 0) and realStart and realDuration and (preferChargeCooldown or realSource ~= "tracked" or not durationobj) then
						local remaining = realStart + realDuration - now
						if remaining > 0 then
							cooldownRemaining = remaining
						end
					end

					local hasChargeLedgerCooldown = preferChargeCooldown and chargeStartTime and chargeDuration and chargeDuration > 0
					if realActive and not durationobj and not hasChargeLedgerCooldown then
						durationobj = GetActionDurationObjectForSpell(id, preferChargeCooldown)
						durationZero = durationobj and IsDurationObjectZero(durationobj)
						if durationZero == nil then
							durationobj = nil
						end
					end
					if realActive and not durationobj and not hasChargeLedgerCooldown then
						durationobj = TryGetSpellCooldownDurationObject(id, true)
						durationZero = durationobj and IsDurationObjectZero(durationobj)
						if durationZero == nil then
							durationobj = nil
						end
					end

					if durationobj and durationZero == true then
						if preferChargeCooldown and chargeStartTime and chargeDuration and chargeDuration > 0 then
							durationobj = nil
							durationZero = nil
						else
							realActive = false
							cooldownIsZero = true
							ClearTrackedSpellCooldown(id)
						end
					end

					if realActive then
						avadaCooldownActive = not (preferChargeCooldown and chargeHasUsableStack)
						local fallbackKey = ""
						if realStart and realDuration then
							fallbackKey = ":" .. tostring(Round(realStart * 10)) .. ":" .. tostring(Round(realDuration * 10))
						end
						local cooldownKey = tostring(id) .. ":" .. tostring(preferChargeCooldown) .. ":" .. tostring(chargeKey or "nocharge") .. ":" .. tostring(realSource or "unknown") .. fallbackKey .. ":active"
						local refreshDue = (icon.cooldownVisualKey ~= cooldownKey) or not icon.cooldownVisualNextRefresh or icon.cooldownVisualNextRefresh <= now
						if durationobj and durationZero == false then
							cooldownHandled = true
							desaturated = avadaCooldownActive
							countColor = { 1, 1, 1 }
							if refreshDue then
								local ok = pcall(icon.cooldown.SetCooldownFromDurationObject, icon.cooldown, durationobj)
								if ok then
									icon.cooldownVisualKey = cooldownKey
									icon.cooldownVisualSerial = nil
									icon.cooldownVisualNextRefresh = now + DURATION_OBJECT_REPAINT_INTERVAL
								else
									cooldownHandled = false
									desaturated = false
									icon.cooldownVisualKey = nil
									icon.cooldownVisualSerial = nil
									icon.cooldownVisualNextRefresh = nil
								end
							end
						elseif realStart and realDuration and realDuration > 0 then
							cooldownHandled = true
							desaturated = avadaCooldownActive
							countColor = { 1, 1, 1 }
							if refreshDue then
								icon.cooldown:SetReverse(false)
								SafeSetCooldown(icon.cooldown, realStart, realDuration)
								ApplyCooldownSweepColor(icon.cooldown)
								icon.cooldown:SetDrawSwipe(true)
								icon.cooldown:Show()
								icon.cooldownVisualKey = cooldownKey
								icon.cooldownVisualSerial = nil
								icon.cooldownVisualNextRefresh = nil
							end
						else
							cooldownHandled = false
							desaturated = false
						end
					else
						cooldownHandled = true
						cooldownIsZero = true
						desaturated = false
						local cooldownKey = tostring(id) .. ":" .. tostring(preferChargeCooldown) .. ":" .. tostring(chargeKey or "nocharge") .. ":ready"
						if charges and maxCharges and charges == maxCharges then
							countColor = { 1, 0, 0 }
						end
						if icon.cooldownVisualKey ~= cooldownKey then
							ClearCooldownWidget(icon.cooldown, true)
							icon.cooldownVisualKey = cooldownKey
							icon.cooldownVisualSerial = nil
							icon.cooldownVisualNextRefresh = nil
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
				if icon.customCooldownText then
					if clean_avadaCustomCooldownText and aType == "cd" and cooldownRemaining and cooldownRemaining > 0 and ApplyCustomCooldownText(icon.customCooldownText, cooldownRemaining) then
						icon.cooldown:SetHideCountdownNumbers(true)
					elseif clean_avadaCustomCooldownText and aType == "cd" and cooldownHandled and not cooldownIsZero then
						icon.customCooldownText:Hide()
						useNativeCooldownText = true
						ApplyAvadaCooldownCountdownFont(icon.cooldown)
					else
						icon.customCooldownText:Hide()
						icon.cooldown:SetHideCountdownNumbers(true)
					end
				end

				if cooldownHandled then
					if not cooldownReadyCached then
						icon.cooldown:SetReverse(false)
						icon.cooldown:SetHideCountdownNumbers(not useNativeCooldownText)
						icon.cooldown:SetDrawSwipe(not cooldownIsZero)
						icon.cooldown:Show()
					if not cooldownIsZero then
						ApplyCooldownSweepColor(icon.cooldown)
					end
				end
			else
				if startTime and duration and duration > 0 then
					icon.cooldown:SetReverse(aType == "buff" or aType == "debuff")
					SafeSetCooldown(icon.cooldown, startTime, duration)
						icon.cooldown:Show()
						icon.cooldownVisualKey = nil
						icon.cooldownVisualSerial = nil
						icon.cooldownVisualNextRefresh = nil
						else
							local clearKey = "clear:" .. tostring(aType) .. ":" .. tostring(id)
							if icon.cooldownVisualKey ~= clearKey then
								ClearCooldownWidget(icon.cooldown, true)
								icon.cooldownVisualKey = clearKey
								icon.cooldownVisualSerial = nil
								icon.cooldownVisualNextRefresh = nil
							end
					end
				end

				if aType == "cd" then
					local effectsAllowed = ShouldPlayVisualEffects()
					if effectsAllowed and ((icon.lastCooldownActive == true and avadaCooldownActive == false) or chargeReadyEvent) then
						TriggerButtonTransitionEffect(icon, clean_avadaEffectReadyFlashEnabled, clean_avadaEffectReadyBounceEnabled, clean_avadaEffectReadyPulseEnabled, clean_avadaEffectReadyColor, "Gold")
					end
					icon.lastCooldownActive = avadaCooldownActive
					icon.lastChargeCount = chargeDisplayCount
				else
					icon.lastCooldownActive = nil
					icon.lastChargeCount = nil
				end
				UpdateTransitionAnimations(icon, GetTime())
				icon:Show()
			elseif NS.editMode and i <= GetAvadaIconCount() then
				icon.icon:SetTexture("Interface/Icons/INV_Misc_QuestionMark")
				icon.icon:SetDesaturated(true)
				icon.count:SetText("")
				icon.count:SetTextColor(1, 1, 1)
				ClearCooldownWidget(icon.cooldown, true)
				icon.cooldownVisualKey = nil
				icon.cooldownVisualSerial = nil
				icon.cooldownVisualNextRefresh = nil
			if icon.customCooldownText then
				icon.customCooldownText:Hide()
			end
			icon.lastCooldownActive = nil
			icon.lastChargeCount = nil
			icon.spellID = nil
			icon.aType = nil
			if icon.flash then
				icon.flash:Hide()
			end
			HideFocusPulse(icon)
			if icon.transitionPulse then
				icon.transitionPulse:Hide()
				icon.transitionPulse:SetScale(1)
			end
			icon:Show()
		else
			icon.cooldownVisualKey = nil
			icon.cooldownVisualSerial = nil
			icon.cooldownVisualNextRefresh = nil
			if icon.customCooldownText then
				icon.customCooldownText:Hide()
			end
			icon.lastCooldownActive = nil
			icon.lastChargeCount = nil
			icon.spellID = nil
			icon.aType = nil
			if icon.flash then
				icon.flash:Hide()
			end
			HideFocusPulse(icon)
			if icon.transitionPulse then
				icon.transitionPulse:Hide()
				icon.transitionPulse:SetScale(1)
			end
			icon:Hide()
		end
	end

	if not showValue then
		tracker.value:SetText("")
	end
end

local editUI

local function EnsureEditUI()
	if editUI then
		return editUI
	end

	local ui = {}
	editUI = ui

	local overlay = NS.CreateFrame("Frame", "ButtonAssistantEnhancedEditOverlay", NS.UIParent)
	overlay:SetAllPoints(NS.UIParent)
	overlay:SetFrameStrata("BACKGROUND")
	overlay:SetFrameLevel(500)
	overlay:EnableMouse(false)
	overlay:Hide()
	ui.overlay = overlay
	ui.gridLines = {}
	ui.freeGridLines = {}

	local bg = overlay:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.10)
	ui.bg = bg

	local function acquireLine()
		local line = table.remove(ui.freeGridLines)
		if not line then
			line = overlay:CreateTexture(nil, "ARTWORK")
			line:SetTexture("Interface\\Buttons\\WHITE8X8")
		end
		line:Show()
		ui.gridLines[#ui.gridLines + 1] = line
		return line
	end

	local function clearGrid()
		for i = #ui.gridLines, 1, -1 do
			local line = ui.gridLines[i]
			line:ClearAllPoints()
			line:Hide()
			ui.freeGridLines[#ui.freeGridLines + 1] = line
			ui.gridLines[i] = nil
		end
	end

	local function drawGrid()
		clearGrid()
		local width, height = overlay:GetSize()
		if not width or width <= 0 or not height or height <= 0 then
			width, height = NS.UIParent:GetSize()
		end

		local spacing = GetGridSize()
		local centerX, centerY = width / 2, height / 2
		local thickness = 1

		local centerV = acquireLine()
		centerV:SetColorTexture(0.95, 0.76, 0.22, 0.45)
		centerV:SetWidth(2)
		centerV:SetPoint("TOP", overlay, "TOPLEFT", centerX, 0)
		centerV:SetPoint("BOTTOM", overlay, "BOTTOMLEFT", centerX, 0)

		local centerH = acquireLine()
		centerH:SetColorTexture(0.95, 0.76, 0.22, 0.45)
		centerH:SetHeight(2)
		centerH:SetPoint("LEFT", overlay, "BOTTOMLEFT", 0, centerY)
		centerH:SetPoint("RIGHT", overlay, "BOTTOMRIGHT", 0, centerY)

		for x = spacing, centerX, spacing do
			local left = centerX - x
			local right = centerX + x
			for _, px in ipairs({ left, right }) do
				local line = acquireLine()
				line:SetColorTexture(0.55, 0.65, 0.78, 0.22)
				line:SetWidth(thickness)
				line:SetPoint("TOP", overlay, "TOPLEFT", px, 0)
				line:SetPoint("BOTTOM", overlay, "BOTTOMLEFT", px, 0)
			end
		end

		for y = spacing, centerY, spacing do
			local bottom = centerY - y
			local top = centerY + y
			for _, py in ipairs({ bottom, top }) do
				local line = acquireLine()
				line:SetColorTexture(0.55, 0.65, 0.78, 0.22)
				line:SetHeight(thickness)
				line:SetPoint("LEFT", overlay, "BOTTOMLEFT", 0, py)
				line:SetPoint("RIGHT", overlay, "BOTTOMRIGHT", 0, py)
			end
		end
	end
	ui.drawGrid = drawGrid
	ui.clearGrid = clearGrid

	local function getOwner(kind)
		if kind == "avada" then
			return frame.avada
		end
		return frame
	end

	local function updateHandle(handle)
		local owner = getOwner(handle.kind)
		if not owner then
			handle:Hide()
			return
		end

		handle:ClearAllPoints()
		handle:SetPoint("TOPLEFT", owner, "TOPLEFT", -3, 3)
		handle:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", 3, -3)
		handle:Show()
	end

	local function updateHandles()
		if not NS.editMode then
			return
		end

		updateHandle(ui.mainHandle)
		updateHandle(ui.avadaHandle)
	end
	ui.updateHandles = updateHandles

	local function makeHandle(kind, label)
		local h = NS.CreateFrame("Button", nil, NS.UIParent)
		h.kind = kind
		h:RegisterForClicks("AnyUp")
		h:RegisterForDrag("LeftButton")
		h:SetFrameStrata("DIALOG")
		h:SetFrameLevel(600)
		h:EnableMouse(true)
		h:Hide()

		h.bg = h:CreateTexture(nil, "BACKGROUND")
		h.bg:SetAllPoints()
		h.bg:SetColorTexture(0.08, 0.18, 0.28, 0.42)

		h.border = h:CreateTexture(nil, "BORDER")
		h.border:SetAllPoints()
		h.border:SetColorTexture(0.12, 0.62, 0.78, 0.36)

		h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		h.text:SetPoint("CENTER")
		h.text:SetText(label .. "\n|cffb0d8ffDrag|r  |cffffd36bRight-click|r")
		h.text:SetJustifyH("CENTER")

		h:SetScript("OnDragStart", function(self)
			if InCombatLockdown() then
				return
			end
			local owner = getOwner(self.kind)
			if owner then
				owner:SetMovable(true)
				owner:StartMoving()
				self.isMoving = true
			end
		end)

		h:SetScript("OnDragStop", function(self)
			local owner = getOwner(self.kind)
			if owner and self.isMoving then
				owner:StopMovingOrSizing()
				if self.kind == "avada" then
					NS.db.avadaDetached = true
					SaveAvadaPosition(true)
					NS.UpdateAvadaLayout()
				else
					SaveMainPosition(true)
					NS.UpdateAvadaLayout()
				end
			end
			self.isMoving = nil
			updateHandles()
			if ui.panel and ui.panel:IsShown() then
				NS.ShowEditPanel(self.kind)
			end
		end)

		h:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				NS.ShowEditPanel(self.kind)
			end
		end)

		return h
	end

	ui.mainHandle = makeHandle("main", "Main Button")
	ui.avadaHandle = makeHandle("avada", "Avada Tracker")

	local panel = NS.CreateFrame("Frame", "ButtonAssistantEnhancedEditPanel", NS.UIParent, "BackdropTemplate")
	panel:SetSize(310, 510)
	panel:SetPoint("CENTER", NS.UIParent, "CENTER", 340, 0)
	panel:SetFrameStrata("DIALOG")
	panel:SetFrameLevel(650)
	panel:SetMovable(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetClampedToScreen(true)
	panel:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	panel:SetBackdropColor(0.035, 0.04, 0.05, 0.94)
	panel:SetBackdropBorderColor(0.18, 0.48, 0.62, 0.9)
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
	panel:Hide()
	ui.panel = panel

	panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	panel.title:SetPoint("TOPLEFT", 14, -12)

		local close = NS.CreateFrame("Button", nil, panel, "UIPanelCloseButton")
		close:SetSize(26, 26)
		close:ClearAllPoints()
		close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
		close:SetFrameStrata("DIALOG")
		close:SetFrameLevel(panel:GetFrameLevel() + 40)

	local exit = NS.CreateFrame("Button", "ButtonAssistantEnhancedExitEditButton", NS.UIParent, "UIPanelButtonTemplate")
	exit:SetSize(132, 24)
	exit:SetPoint("TOP", NS.UIParent, "TOP", 0, -18)
	exit:SetFrameStrata("DIALOG")
	exit:SetFrameLevel(700)
	exit:SetText("Exit Edit Mode")
	exit:SetScript("OnClick", function()
		NS.SetEditMode(false)
	end)
	exit:Hide()
	ui.exitButton = exit

	local function makeLabel(text, x, y)
		local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", x, y)
		fs:SetText(text)
		return fs
	end

	local function makeEditBox(name, x, y, width)
		makeLabel(name, x, y)
		local eb = NS.CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
		eb:SetSize(width or 72, 22)
		eb:SetAutoFocus(false)
		eb:SetPoint("TOPLEFT", x + 58, y + 3)
		eb:SetFontObject("GameFontHighlightSmall")
		eb:SetScript("OnEscapePressed", eb.ClearFocus)
		eb:SetScript("OnEnterPressed", function(self)
			if panel.applyCoordinates then
				panel.applyCoordinates()
			end
			self:ClearFocus()
		end)
		return eb
	end

	local function makeSlider(name, y, minValue, maxValue, step, format, onChanged)
		local slider = NS.CreateFrame("Slider", nil, panel, "UISliderTemplate")
		slider:SetPoint("TOPLEFT", 18, y)
		slider:SetSize(214, 18)
		slider:SetMinMaxValues(minValue, maxValue)
		slider:SetValueStep(step or 1)
		if slider.SetObeyStepOnDrag then
			slider:SetObeyStepOnDrag(true)
		end

		slider.label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		slider.label:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 3)
		slider.label:SetText(name)

		slider.valueText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		slider.valueText:SetPoint("LEFT", slider, "RIGHT", 10, 0)

		slider.format = format or "%d"
		slider:SetScript("OnValueChanged", function(self, value)
			value = Round(value / (step or 1)) * (step or 1)
			self.valueText:SetText(string.format(self.format, value))
			if not self.updating and onChanged then
				onChanged(value)
			end
		end)
		return slider
	end

	local function setSliderValue(slider, value, minValue, maxValue)
		slider.updating = true
		if minValue and maxValue then
			slider:SetMinMaxValues(minValue, maxValue)
		end
		slider:SetValue(value)
		slider.valueText:SetText(string.format(slider.format or "%d", value))
		slider.updating = nil
	end
	ui.setSliderValue = setSliderValue

	local function setSliderShown(slider, shown)
		slider:SetShown(shown)
		if slider.label then
			slider.label:SetShown(shown)
		end
		if slider.valueText then
			slider.valueText:SetShown(shown)
		end
	end
	ui.setSliderShown = setSliderShown

	local xBox = makeEditBox("X", 18, -56, 76)
	local yBox = makeEditBox("Y", 162, -56, 76)
	panel.xBox = xBox
	panel.yBox = yBox

	local apply = NS.CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	apply:SetSize(74, 22)
	apply:SetPoint("TOPLEFT", 18, -86)
	apply:SetText("Apply")
	apply:SetScript("OnClick", function()
		if panel.applyCoordinates then
			panel.applyCoordinates()
		end
	end)

	local reset = NS.CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(74, 22)
	reset:SetPoint("LEFT", apply, "RIGHT", 8, 0)
	reset:SetText("Reset")
	reset:SetScript("OnClick", function()
		if panel.kind == "avada" then
			NS.db.avadaDetached = false
			NS.db.avadaX = 0
			NS.db.avadaY = -180
		else
			NS.db.mainX = 0
			NS.db.mainY = -120
		end
		NS.UpdateLayout()
		updateHandles()
		NS.ShowEditPanel(panel.kind)
	end)

	local function attachCheckLabel(check, text)
		local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("LEFT", check, "RIGHT", -2, 0)
		label:SetText(text)
		check.label = label
		return label
	end

	local detach = NS.CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	detach:SetPoint("TOPLEFT", 18, -116)
	attachCheckLabel(detach, "Separate Avada position")
	detach:SetScript("OnClick", function(self)
		NS.db.avadaDetached = self:GetChecked() and true or false
		if NS.db.avadaDetached then
			SaveAvadaPosition(true)
		end
		NS.UpdateLayout()
		updateHandles()
	end)
	panel.detach = detach

	local snap = NS.CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	snap:SetPoint("TOPLEFT", 18, -146)
	attachCheckLabel(snap, "Snap to grid")
	snap:SetScript("OnClick", function(self)
		NS.db.editSnapToGrid = self:GetChecked() and true or false
	end)
	panel.snap = snap

	panel.gridSlider = makeSlider("Grid Size", -190, 8, 96, 4, "%dpx", function(value)
		NS.db.editGridSize = value
		drawGrid()
	end)
	panel.scaleSlider = makeSlider("Main Scale", -238, 50, 200, 5, "%d%%", function(value)
		NS.db.scale = value / 100
		NS.UpdateLayout()
		updateHandles()
	end)
	panel.avadaScaleSlider = makeSlider("Avada Scale", -238, 50, 200, 5, "%d%%", function(value)
		NS.db.avadaScale = value / 100
		NS.UpdateLayout()
		updateHandles()
	end)
	panel.columnsSlider = makeSlider("Avada Columns", -286, 1, MAX_AVADA_ICONS, 1, "%d", function(value)
		NS.SetAvadaColumns(value)
		updateHandles()
		NS.ShowEditPanel("avada")
	end)
	panel.rowsSlider = makeSlider("Avada Rows", -334, 1, MAX_AVADA_ICONS, 1, "%d", function(value)
		NS.SetAvadaRows(value)
		updateHandles()
		NS.ShowEditPanel("avada")
	end)
	panel.sizeSlider = makeSlider("Avada Icon Size", -382, 10, 48, 1, "%dpx", function(value)
		NS.db.avadaSize = value
		NS.UpdateLayout()
		updateHandles()
	end)
	panel.spacingSlider = makeSlider("Avada Spacing", -430, 0, 16, 1, "%dpx", function(value)
		NS.db.avadaSpacing = value
		NS.UpdateLayout()
		updateHandles()
	end)

	function panel.applyCoordinates()
		local x = tonumber(xBox:GetText())
		local y = tonumber(yBox:GetText())
		if not x or not y then
			return
		end
		x, y = MaybeSnapPosition(x, y)
		if panel.kind == "avada" then
			NS.db.avadaDetached = true
			NS.db.avadaX = x
			NS.db.avadaY = y
			NS.UpdateAvadaLayout()
		else
			NS.db.mainX = x
			NS.db.mainY = y
			ApplyMainPosition()
			NS.UpdateAvadaLayout()
		end
		updateHandles()
		NS.ShowEditPanel(panel.kind)
	end

	overlay:SetScript("OnShow", function()
		drawGrid()
		updateHandles()
	end)
	overlay:SetScript("OnHide", function()
		clearGrid()
	end)
	overlay:SetScript("OnUpdate", function(self, elapsed)
		self.elapsed = (self.elapsed or 0) + elapsed
		if self.elapsed >= 0.05 then
			self.elapsed = 0
			updateHandles()
		end
	end)

	return ui
end

function NS.ShowEditPanel(kind)
	local ui = EnsureEditUI()
	local panel = ui.panel
	kind = kind == "avada" and "avada" or "main"
	panel.kind = kind
	panel.title:SetText(kind == "avada" and "Avada Tracker Layout" or "Main Button Layout")

	local x, y
	if kind == "avada" then
		x, y = NS.db.avadaX or 0, NS.db.avadaY or -180
		if frame.avada and not NS.db.avadaDetached then
			x, y = GetCenterOffset(frame.avada)
		end
	else
		x, y = NS.db.mainX or 0, NS.db.mainY or -120
	end
	panel.xBox:SetText(tostring(Round(x)))
	panel.yBox:SetText(tostring(Round(y)))
	panel.snap:SetChecked(NS.db.editSnapToGrid and true or false)
	panel.detach:SetShown(kind == "avada")
	if panel.detach.label then
		panel.detach.label:SetShown(kind == "avada")
	end
	panel.detach:SetChecked(NS.db.avadaDetached and true or false)

	ui.setSliderValue(panel.gridSlider, GetGridSize())
	ui.setSliderValue(panel.scaleSlider, Round((NS.db.scale or 1) * 100))

	local isAvada = kind == "avada"
	ui.setSliderShown(panel.scaleSlider, not isAvada)
	ui.setSliderShown(panel.avadaScaleSlider, isAvada)
	ui.setSliderShown(panel.sizeSlider, isAvada)
	ui.setSliderShown(panel.spacingSlider, isAvada)
	ui.setSliderShown(panel.columnsSlider, isAvada)
	ui.setSliderShown(panel.rowsSlider, isAvada)

	if isAvada then
		local columns, rows, count = GetAvadaGrid()
		ui.setSliderValue(panel.avadaScaleSlider, Round((NS.db.avadaScale or 1) * 100))
		ui.setSliderValue(panel.sizeSlider, NS.db.avadaSize or 16)
		ui.setSliderValue(panel.spacingSlider, NS.db.avadaSpacing or 4)
		ui.setSliderValue(panel.columnsSlider, columns, 1, count)
		ui.setSliderValue(panel.rowsSlider, rows, 1, count)
	end

	panel:Show()
end

function NS.SetEditMode(enabled)
	if enabled and InCombatLockdown() then
		print("|cff4e84b1[Button Assistant Enhanced]|r Layout edit mode is unavailable in combat.")
		return
	end

	NS.editMode = enabled and true or false
	local ui = EnsureEditUI()
	if NS.editMode then
		NS.UpdateLayout()
		frame:Show()
		if frame.button then
			frame.button:Show()
		end
		if frame.avada then
			frame.avada:Show()
		end
		ui.overlay:Show()
		if ui.exitButton then
			ui.exitButton:Show()
		end
		ui.updateHandles()
		print("|cff4e84b1[Button Assistant Enhanced]|r Edit mode enabled. Drag frames or right-click them for layout options.")
	else
		ui.overlay:Hide()
		if ui.exitButton then ui.exitButton:Hide() end
		if ui.mainHandle then ui.mainHandle:Hide() end
		if ui.avadaHandle then ui.avadaHandle:Hide() end
		if ui.panel then ui.panel:Hide() end
		NS.UpdateVisibility()
		NS.UpdateNow()
		print("|cff4e84b1[Button Assistant Enhanced]|r Edit mode disabled.")
	end
end

function NS.ToggleEditMode()
	NS.SetEditMode(not NS.editMode)
end

function NS.RefreshEditGrid()
	if not NS.editMode then
		return
	end
	local ui = EnsureEditUI()
	ui.drawGrid()
	ui.updateHandles()
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
local keybindRefreshPending

local function PrimeKeybindCacheForSpell(spellID)
	if not spellID or not local_GetKeyBindForSpellID then
		return
	end
	pcall(local_GetKeyBindForSpellID, spellID)
end

local function PrimeDisplayedKeybindCache()
	if InCombatLockdown() then
		keybindRefreshPending = true
		return
	end

	PrimeKeybindCacheForSpell(cleanRecommendedSpellID)
	if frame and frame.button then
		PrimeKeybindCacheForSpell(frame.button.spellID)
	end

	if GetActionInfo then
		for slot = 1, 168 do
			local actionType, id = GetActionInfo(slot)
			if actionType == "spell" and id then
				PrimeKeybindCacheForSpell(id)
			elseif actionType == "macro" and id then
				local _, _, spellID = GetMacroSpell(id)
				if spellID then
					PrimeKeybindCacheForSpell(spellID)
				end
			end
		end
	end
	if NS.GetAssistantKeyBind then
		pcall(NS.GetAssistantKeyBind)
	end

	if NS.C_AssistedCombat_GetRotationSpells then
		local ok, spells = pcall(NS.C_AssistedCombat_GetRotationSpells)
		if ok and spells then
			for _, spellID in ipairs(spells) do
				PrimeKeybindCacheForSpell(spellID)
			end
		end
	end

	if NS.C_AssistedCombat_GetActionSpell then
		local ok, spellID = pcall(NS.C_AssistedCombat_GetActionSpell)
		if ok then
			PrimeKeybindCacheForSpell(spellID)
		end
	end

	local list = local_GetAvadaTargetList and local_GetAvadaTargetList()
	if list then
		for _, data in ipairs(list) do
			if data and data.spellID then
				PrimeKeybindCacheForSpell(data.spellID)
			end
		end
	end
end

local function DelayedUpdateKeybindings(wipeKeybindCache)
	if allTimer then
		allTimer:Cancel()
	end
	ClearActionSlotCache()
	if NS.WipeAssistantKeybindCache and not InCombatLockdown() then
		NS.WipeAssistantKeybindCache()
	end
	if wipeKeybindCache then
		if InCombatLockdown() then
			keybindRefreshPending = true
		elseif NS.WipeKeybindCache then
			NS.WipeKeybindCache()
		end
	end
	allTimer = NS.C_Timer_After(0.2, function()
		if not InCombatLockdown() and keybindRefreshPending then
			if NS.WipeKeybindCache then
				NS.WipeKeybindCache()
			end
			if NS.WipeAssistantKeybindCache then
				NS.WipeAssistantKeybindCache()
			end
			keybindRefreshPending = nil
		end
		NS.ReadKeybindings()
		NS.UpdateNow()
		ScanAllCooldowns() -- Scan and cache cooldowns after everything is settled!
		if not InCombatLockdown() then
			PrimeDisplayedKeybindCache()
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

			ButtonAssistantEnhancedDB = ButtonAssistantEnhancedDB or {}
			NS.db = ButtonAssistantEnhancedDB
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
				NS.db.avadaEffectReadyFlashEnabled = true
				NS.db.avadaEffectReadyPulseEnabled = true
				NS.db.avadaEffectReadyBounceEnabled = false
				NS.db.avadaEffectReadyColor = "Gold"
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
					NS.RefreshWatchedChargeLedgers()
					DelayedUpdateKeybindings(false) -- Ensure hotkeys are scanned after bars are ready
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
					NS.NoteSpellChargeCast(capturedSpellID, capturedGCDStart)
					if NS.C_Timer_After then
						NS.C_Timer_After(0, function()
							QueueTrackedSpellCooldown(capturedSpellID, capturedGCDStart)
							NS.RefreshChargeLedgerFromSpell(capturedSpellID)
						end)
						NS.C_Timer_After(0.08, function()
							NS.RefreshChargeLedgerFromSpell(capturedSpellID)
						end)
					else
						QueueTrackedSpellCooldown(capturedSpellID, capturedGCDStart)
						NS.RefreshChargeLedgerFromSpell(capturedSpellID)
					end
				end
					end

				if event == "ASSISTED_COMBAT_ACTION_SPELL_CAST" then
					if NS.C_Timer_After then
						NS.C_Timer_After(0, NS.UpdateNow)
					else
						NS.UpdateNow()
					end
				end

			-- Any binding/bar changes => wipe cache + refresh (debounced)
		if event == "UPDATE_BINDINGS" or event == "ACTIONBAR_SLOT_CHANGED" or event == "SPELLS_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED" or event == "UPDATE_BONUS_ACTIONBAR" or event == "UPDATE_VEHICLE_ACTIONBAR" or event == "UPDATE_OVERRIDE_ACTIONBAR" or event == "ACTIONBAR_UPDATE_STATE" or event == "PLAYER_TALENT_UPDATE" or event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UPDATE_SHAPESHIFT_FORM" or event == "TRAIT_CONFIG_UPDATED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
			if event == "TRAIT_CONFIG_UPDATED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
				NS.RefreshAvadaCachedData()
				NS.UpdateAvadaLayout()
			end
				DelayedUpdateKeybindings(true)
		end

		-- Visibility & Regen Changes
			if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" or event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" or event == "PLAYER_ENTERING_WORLD" then
				NS.UpdateVisibility()
				if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ENTERING_WORLD" then
					ScanAllCooldowns() -- Sync and cache all cooldowns when leaving combat or entering world!
					NS.RefreshWatchedChargeLedgers()
					DelayedUpdateKeybindings(false)
				end
		end

		-- Target Changed
		if event == "PLAYER_TARGET_CHANGED" then
			NS.UpdateVisibility()
		end

			-- Cooldown Updates
			if event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" or event == "ACTIONBAR_UPDATE_COOLDOWN" then
				NS.RefreshWatchedChargeLedgers()
				InvalidateCooldownVisuals()
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
