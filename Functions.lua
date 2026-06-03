local _, NS = ...

-- ---------------------------------------------------------------------
-- Utility Functions
-- ---------------------------------------------------------------------

function NS.SafeCall(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		ButtonAssistantEnchancedDB = ButtonAssistantEnchancedDB or {}
		ButtonAssistantEnchancedDB.errors = ButtonAssistantEnchancedDB.errors or {}
		table.insert(ButtonAssistantEnchancedDB.errors, {
			time = date("%H:%M:%S"),
			err = tostring(err),
			stack = debugstack and debugstack(2, 10, 2) or "no stack"
		})
		if #ButtonAssistantEnchancedDB.errors > 20 then
			table.remove(ButtonAssistantEnchancedDB.errors, 1)
		end
		print("|cff4e84b1[Button Assistant Enchanced Error]|r " .. tostring(err))
	end
	return ok
end

function NS.CopyDefaults(dst, src)
	for k, v in NS.pairs(src) do
		if NS.type(v) == "table" then
			if NS.type(dst[k]) ~= "table" then
				dst[k] = {}
			end
			NS.CopyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

-- ---------------------------------------------------------------------
-- Keybind lookup
-- ---------------------------------------------------------------------

function NS.improvedGetBindingText(binding)
	if not binding then
		return ""
	end

	for _, rep in NS.ipairs(NS.BindingSubs) do
		binding = binding:gsub(rep[1], rep[2])
	end

	return binding
end

function NS.StoreKeybindInfo(page, key, aType, id, console)
	if not key or not aType or not id then
		return
	end

	local keys = NS.Hotkeys
	local updatedKeys = NS.UpdatedHotkeys

	-- Hekili uses an 'action' string internally. We will map the ID directly.
	local action = NS.tostring(id)

	if aType == "item" then
		if NS.ItemToAbility[id] then
			action = NS.ItemToAbility[id]
		end
	end

	if action then
		if aType == "macro" then
			local _, _, spellID = NS.GetMacroSpell(id)
			if spellID then
				action = NS.tostring(spellID)
			else
				local _, link = NS.GetMacroItem(id)
				if link then
					local itemID = link:match("item:(%d+)")
					if itemID then
						action = itemID
					end
				end
			end
		end

		local function save(act)
			keys[act] = keys[act] or {
				lower = {},
				upper = {},
				console = {},
			}

			if console == "cPort" then
				local newKey = key:gsub(":%d+:%d+:0:0", ":0:0:0:0")
				keys[act].console[page] = newKey
			else
				keys[act].upper[page] = NS.improvedGetBindingText(key)
				keys[act].lower[page] = NS.string_lower(keys[act].upper[page])
			end
			updatedKeys[act] = true
		end

		save(action)

		-- If it's a spell, also store it under the base ID
		if aType == "spell" then
			local baseID = NS.FindBaseSpellByID(NS.tonumber(action))
			if baseID and NS.tostring(baseID) ~= action then
				save(NS.tostring(baseID))
			end
		end
	end
end

function NS.ReadKeybindings(event)
	-- Empty to prevent secure environment taints from GetActionInfo loops.
	-- Dynamic action-bar lookup is only used out of combat in GetKeyBindForSpellID.
end

function NS.GetBindingForAction(key, display, i)
	if not key then
		return ""
	end

	-- Map the key (action ID) to the hotkey string
	key = NS.tostring(key)

	if not NS.Hotkeys[key] then
		return ""
	end

	local keys = NS.Hotkeys

	local caps, console = true, false
	-- Simplified display/caps logic since we don't have the full display object here
	if display then
		local queued = (i or 1) > 1 and display.keybindings.separateQueueStyle
		caps = not (queued and display.keybindings.queuedLowercase or display.keybindings.lowercase)
		console = NS._G.ConsolePort ~= nil and display.keybindings.cPortOverride
	end

	local db = console and keys[key].console or (caps and keys[key].upper or keys[key].lower)

	local output, source
	local order = NS.BarOrder["DEFAULT"]

	-- Class-specific logic
	local _, class = NS._G.UnitClass("player")
	if class == "DRUID" then
		local form = NS._G.GetShapeshiftForm()
		if form == 1 then -- Bear
			order = NS.BarOrder["DRUID_BEAR"]
		elseif form == 2 then -- Cat
			if NS._G.IsStealthed() then
				order = NS.BarOrder["DRUID_PROWL"]
			else
				order = NS.BarOrder["DRUID_CAT"]
			end
		elseif form == 3 then -- Travel
			order = NS.BarOrder["DRUID_TRAVEL"]
		elseif form == 4 then -- Moonkin
			order = NS.BarOrder["DRUID_OWL"]
		elseif form == 5 then -- Tree/Resto
			order = NS.BarOrder["DRUID_TREE"]
		end
	elseif class == "ROGUE" then
		if NS._G.IsStealthed() then
			order = NS.BarOrder["ROGUE_STEALTH"]
		end
	end

	for _, n in NS.ipairs(order) do
		output = db[n]
		if output and output ~= "" then
			source = n
			break
		end
	end

	output = output or ""

	if output ~= "" and console then
		local size = output:match("Icons(%d%d)")
		size = NS.tonumber(size)
		if size then
			local margin = NS.math_floor(size * (display and display.keybindings.cPortZoom or 1) * 0.5)
			output = output:gsub(":0|t", ":0:" .. size .. ":" .. size .. ":" .. margin .. ":" .. (size - margin) .. ":" .. margin .. ":" .. (size - margin) .. "|t")
		end
	end

	return output
end

function NS.GetKeyBindForSpellID(identifier)
	if not identifier then
		return nil
	end

	-- Instant lookup from the database
	local baseID = NS.FindBaseSpellByID(identifier) or identifier
	local text = NS.GetBindingForAction(baseID) or NS.GetBindingForAction(identifier)

	-- Fallback: Use Retail API to find the spell on bars if cache missed or empty.
	-- Keep this out of combat; action-bar lookup can trip Midnight protected/taint paths.
	if (not text or text == "") and NS.C_ActionBar_FindSpellActionButtons and not NS.InCombatLockdown() then
		local slots = NS.C_ActionBar_FindSpellActionButtons(identifier)
		if not slots or #slots == 0 then
			slots = NS.C_ActionBar_FindSpellActionButtons(baseID)
		end

		if slots and #slots > 0 then
			for _, slot in NS.ipairs(slots) do
				local bName
				if slot <= 12 then
					bName = "ACTIONBUTTON" .. slot
				elseif slot <= 24 then
					bName = "ACTIONBUTTON" .. (slot - 12)
				elseif slot <= 36 then
					bName = "MULTIACTIONBAR3BUTTON" .. (slot - 24)
				elseif slot <= 48 then
					bName = "MULTIACTIONBAR4BUTTON" .. (slot - 36)
				elseif slot <= 60 then
					bName = "MULTIACTIONBAR2BUTTON" .. (slot - 48)
				elseif slot <= 72 then
					bName = "MULTIACTIONBAR1BUTTON" .. (slot - 60)
				elseif slot <= 144 then
					bName = "ACTIONBUTTON" .. (1 + (slot - 73) % 12)
				end

				if bName then
					local key = NS.GetBindingKey(bName)
					if key and key ~= "" then
						text = NS.improvedGetBindingText(key)
						break
					end
				end
			end
		end
	end

	return text
end

function NS.WipeKeybindCache()
	for k in NS.pairs(NS.keybindCache) do
		NS.keybindCache[k] = nil
	end
end

-- ---------------------------------------------------------------------
-- Assisted Combat spell list
-- ---------------------------------------------------------------------
function NS.SafeCallAssisted(fn, arg)
	if not fn then
		return false
	end

	local ok, a, b, c, d, e = NS.pcall(fn, arg)
	if ok then
		return true, a, b, c, d, e
	end

	ok, a, b, c, d, e = NS.pcall(fn)
	if ok then
		return true, a, b, c, d, e
	end

	return false
end

function NS.IsAssistedCombatAvailable()
	if NS.C_AssistedCombat_IsAvailable then
		return NS.C_AssistedCombat_IsAvailable()
	end
	-- Fallback for pre-12.0.0 (TWW/Live)
	-- We can't easily check 'availability' without specific spec checks,
	-- so we just assume it's available if the API exists.
	return NS.C_AssistedCombat_GetNextCastSpell ~= nil
end

function NS.CollectNextSpell()
	local checkVisible = NS.db.checkVisibleButton and true or false

	-- 1. Main Recommendation (The "One-Punch" logic that worked before)
	if NS.C_AssistedCombat_GetNextCastSpell then
		local ok, sid = NS.SafeCallAssisted(NS.C_AssistedCombat_GetNextCastSpell, checkVisible)
		if ok and sid and sid ~= 0 then
			return sid
		end
	end

	-- 2. Highlights (Cyan highlights from the Assisted Combat menu)
	if NS.C_AssistedCombat_GetRotationSpells then
		local spells = NS.C_AssistedCombat_GetRotationSpells()
		if spells and spells[1] and spells[1] ~= 0 then
			return spells[1]
		end
	end

	-- 3. Last Resort (12.0.0 specific recommendation)
	if NS.C_AssistedCombat_GetActionSpell then
		local sid = NS.C_AssistedCombat_GetActionSpell()
		if sid and sid ~= 0 then
			return sid
		end
	end

	return nil
end

-- ---------------------------------------------------------------------
-- Avada Tracker Utilities
-- ---------------------------------------------------------------------

function NS.ParseAvadaString(str)
	if not str then
		return
	end
	local index, unit, aType, id = str:match("(%d+)Z(%w+)Z(%w+)Z(%d+)")
	if index and unit and aType and id then
		index = NS.tonumber(index)
		id = NS.tonumber(id)

		local geminiSpell = NS.AvadaGemini[id]
		if geminiSpell and NS.IsSpellKnown(geminiSpell) then
			id = geminiSpell
		end

		return index, unit, aType, id
	end
end

function NS.UpdateAvadaWatchData()
	NS.wipe(NS.WatchUnits)
	NS.wipe(NS.WatchTypes)

	for _, data in NS.pairs(NS.CachedAvadaData) do
		if data.unit and data.unit ~= "" then
			NS.WatchUnits[data.unit] = true
		end
		if data.type and data.type ~= "" then
			NS.WatchTypes[data.type] = true
		end
	end
end

NS.CachedAvadaData = {}

function NS.RefreshAvadaCachedData()
	local specIndex = NS.GetSpecialization()
	if not specIndex then
		return
	end
	if specIndex > 4 then
		specIndex = 1
	end

	local specID = NS.GetSpecializationInfo(specIndex)
	if not specID then
		return
	end

	-- Check for user-defined profile index
	local activeIndex = (NS.db.avadaIndices and NS.db.avadaIndices[specID]) or 1
	local data

	if activeIndex ~= 1 then
		-- index 1 is usually reserved for the default string or "none" in some contexts,
		-- in our case, if index > 1 and we have a custom profile, use it.
		if NS.db.avadaProfiles and NS.db.avadaProfiles[specID] and NS.db.avadaProfiles[specID][activeIndex] then
			data = NS.db.avadaProfiles[specID][activeIndex]
		end
	end

	-- Fallback to hardcoded default if index 1 or no custom profile found
	if not data or data == "" then
		data = NS.AvadaData[specID]
	end

	NS.wipe(NS.CachedAvadaData)

	if data and data ~= "" then
		for part in data:gmatch("([^N]+)") do
			local index, unit, aType, id = NS.ParseAvadaString(part)
			if index and id then
				NS.CachedAvadaData[index] = {
					index = index,
					unit = unit,
					type = aType,
					spellID = id,
				}
			end
		end
	end

	NS.UpdateAvadaWatchData()
end

function NS.GetAvadaTargetList()
	if #NS.CachedAvadaData == 0 then
		NS.RefreshAvadaCachedData()
	end
	return NS.CachedAvadaData
end

function NS.IsAvadaWatchingUnit(unit)
	for _, data in NS.ipairs(NS.CachedAvadaData) do
		if data.unit == unit then
			return true
		end
	end
	return false
end

function NS.GetAuraInfo(unit, spellID, filter)
	if not NS.C_UnitAuras_GetAuraDataByIndex then
		return
	end

	for i = 1, 40 do
		local aura = NS.C_UnitAuras_GetAuraDataByIndex(unit, i, filter)
		if not aura then
			break
		end
		if aura.spellId == spellID then
			-- Strictly filter for player source to match NDui's "caster == 'player'" check
			if aura.sourceUnit == "player" then
				return aura, aura.points[1]
			end
		end
	end
end

function NS.FormatNumber(value)
	if value >= 1e6 then
		return ("%.1fM"):format(value / 1e6):gsub("%.?0+([km])$", "%1")
	elseif value >= 1e3 then
		return ("%.1fK"):format(value / 1e3):gsub("%.?0+([km])$", "%1")
	else
		return NS.tostring(NS.math_floor(value))
	end
end
