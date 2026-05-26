-- LayeredFX (Visual Only) v0.0.1
-- This version of the LayeredFX mod hides the optional value sliders
-- (and removes the related functions that are unnecessary anymore)
-- So user can be sure that they won't accidentally apply actual damage/buffs
-- Values are stuck at defaults (0) for the visual effects only
--
-- Currently:
-- 		Shattering Reflection -> Shatterseal (GS)
-- 		Synthetic Shield -> Omega's Sword (SnS)
-- 		Synergy -> Omega's Rod (IG)

-- Config things
local CONFIG_PATH = "LayeredFX.json"

local Config = {
	Shatter = {
		Enabled = false,
	},
	OmegaSword = {
		Enabled = false,
	},
	OmegaRod = {
		Enabled = false,
	},
}

-- Merge this version's config, preserve original mod's keys
local function mergeOptConfig(target, ours)
	for key, val in pairs(ours) do
		if type(val) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			mergeOptConfig(target[key], val)
		else
			target[key] = val
		end
	end
end

local function saveConfig()
	local existing = {}
	local ok, parsed = pcall(json.load_file, CONFIG_PATH)
	if ok and type(parsed) == "table" then existing = parsed end
	mergeOptConfig(existing, Config)
	json.dump_file(CONFIG_PATH, existing)
end

-- Handle new keys, merge updated
local function mergeLoadedConfig(target, loaded)
	if type(loaded) ~= "table" then return true end
	local added = false
	for key, default_val in pairs(target) do
		if type(default_val) == "table" then
			if type(loaded[key]) ~= "table" then
				added = true
			else
				if mergeLoadedConfig(default_val, loaded[key]) then
					added = true
				end
			end
		else
			if loaded[key] == nil then
				added = true
			else
				target[key] = loaded[key]
			end
		end
	end
	return added
end

-- Load/create config and keys
local function loadConfig()
	local f = io.open(CONFIG_PATH, "r")
	if not f then
		json.dump_file(CONFIG_PATH, Config)
		return
	end
	local content = f:read("*a")
	f:close()
	if not content or #content == 0 then
		json.dump_file(CONFIG_PATH, Config)
		return
	end

	local ok, loaded = pcall(json.load_file, CONFIG_PATH)
	if not ok or type(loaded) ~= "table" then
		json.dump_file(CONFIG_PATH, Config)
		return
	end

	if mergeLoadedConfig(Config, loaded) then
		json.dump_file(CONFIG_PATH, Config)
	end
end

loadConfig()
log.info(("[LayeredFXVisual] Loaded, config: %s"):format(CONFIG_PATH))

-- Signal the slider-equipped LayeredFX to yield. If both mods are present,
-- the original detects this flag and stops writing to the catalog so this
-- visual-only version is the sole controller.
_G.LayeredFXVisualLoaded = true

-- CONST

-- Shatterseal / Shattering Reflection
local SHATTER_TYPE_INDEX = 0 -- index greatsword OuterMainWeaponCurrent[]
local SHATTER_MODEL_ID = 32 -- _ModelId on _WeaponLongSword
local SHATTER_LAYERED_ID = 53 -- _Id (Fixed enum) on _OuterWeaponLongSword (Shatterseal Drakesnest)
local SHATTER_SKILL_ID = 245 -- <skillId>k__BackingField on _SkillCommonData (Shattering Reflection)
local SHATTER_DAMAGE_FIELD = "_UserContestShellOfsShellExAttack" -- Shattering Reflection on _Wp00ActionParam

-- Omega's Sword / Synthetic Shield
local OMEGA_SWORD_TYPE_INDEX = 1 -- index SnS OuterMainWeaponCurrent[]
local OMEGA_SWORD_MODEL_ID = 35 -- _ModelId on _WeaponShortSword
local OMEGA_SWORD_LAYERED_ID = 52 -- _Id (Fixed enum) on _OuterWeaponShortSword (True Omega's Sword)
local SHIELD_SKILL_ID = 235 -- <skillId>k__BackingField on _SkillCommonData (Synthetic Shield)

-- Synthetic Shield _Catalog._GlobalParam._SkillParam fields (set to 0 while active to suppress effect)
local SHIELD_FIELDS = {
	"_ShieldOptionValue",
	"_ShieldOptionValue_Resonance",
	"_ShieldOptionTime",
	"_ShieldOptionTime_Resonance",
}

-- Omega's Rod / Synergy
local OMEGA_ROD_TYPE_INDEX = 10 -- index IG OuterMainWeaponCurrent[]
local OMEGA_ROD_MODEL_ID = 31 -- _ModelId on _WeaponRod
local OMEGA_ROD_LAYERED_ID = 52 -- _Id (Fixed enum) on _OuterWeaponRod (True Omega's Rod)
local SYNERGY_SKILL_ID = 236 -- <skillId>k__BackingField on _SkillCommonData (Synergy)

-- Synergy _Catalog._GlobalParam._SkillParam fields (set to 0 while active to suppress effect)
local COOP_FIELDS = {
	"_CooperationValue",
	"_CooperationValue_Resonance",
	"_CooperationTime",
	"_CooperationTime_Resonance",
}

-- Lookup
local WeaponUtil = sdk.find_type_definition("app.WeaponUtil")
local getWeaponData = WeaponUtil:get_method("getWeaponData(app.savedata.cEquipWork)")
local cHunterSkill = sdk.find_type_definition("app.cHunterSkill")
local getSkillLevelCore = cHunterSkill:get_method("getSkillLevelCore(app.EquipDef.EquipSkillInfo[], app.HunterDef.Skill, System.Boolean, System.Boolean)")
local getGuiMessage = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")

-- Cache data
local _pm, _sdm, _vdm
local function getPlayerManager()
	if not _pm then _pm = sdk.get_managed_singleton("app.PlayerManager") end
	return _pm
end
local function getSaveDataManager()
	if not _sdm then _sdm = sdk.get_managed_singleton("app.SaveDataManager") end
	return _sdm
end
local function getVariousDataMgr()
	if not _vdm then _vdm = sdk.get_managed_singleton("app.VariousDataManager") end
	return _vdm
end

local function getMasterChar()
	local pm = getPlayerManager()
	if not pm then return nil end
	local p = pm:getMasterPlayer()
	if not p then return nil end
	return p:get_Character()
end

local function getEquip()
	local sdm = getSaveDataManager()
	if not sdm then return nil end
	local save = sdm:getCurrentUserSaveData()
	if not save then return nil end
	return save._Equip
end

local function localizedName(guid)
	if not guid then return nil end
	local ok, s = pcall(getGuiMessage.call, getGuiMessage, nil, guid)
	if ok and type(s) == "string" then return s end
	return nil
end

-- Find items

local Found = {
	Shatter = { model = nil, layered = nil, skill = nil, all = false },
	OmegaSword = { model = nil, layered = nil, skill = nil, all = false },
	OmegaRod = { model = nil, layered = nil, skill = nil, all = false },
}

local ItemLabels = {
	Shatter = {
		model = "Shatterseal Greatsword model",
		layered = "Shatterseal Drakesnest layered weapon",
		skill = "Shattering Reflection skill",
	},
	OmegaSword = {
		model = "Omega's Sword SnS model",
		layered = "True Omega's Sword layered weapon",
		skill = "Synthetic Shield skill",
	},
	OmegaRod = {
		model = "Omega's Rod IG model",
		layered = "True Omega's Rod layered weapon",
		skill = "Synergy skill",
	},
}

local Discovery = {
	complete = false,
	missing = { Shatter = {}, OmegaSword = {}, OmegaRod = {} },
}

local function findShatterWeapon(v)
	for _, w in pairs(v._Setting._EquipDatas._WeaponLongSword._Values) do
		if tonumber(w._ModelId) == SHATTER_MODEL_ID then
			local name = localizedName(w._Name) or "?"
			log.info(("[LayeredFXVisual] Shatter weapon: _ModelId=%d found on _WeaponLongSword: name='%s'"):format(SHATTER_MODEL_ID, name))
			return SHATTER_MODEL_ID
		end
	end
	return nil
end

local function findShatterLayered(v)
	for _, w in pairs(v._Setting._EquipDatas._OuterWeaponLongSword._Values) do
		if tonumber(w._Id) == SHATTER_LAYERED_ID then
			local name = localizedName(w._Name) or "?"
			log.info(("[LayeredFXVisual] Shatter layered: _Id=%d found on _OuterWeaponLongSword: name='%s'"):format(SHATTER_LAYERED_ID, name))
			return SHATTER_LAYERED_ID
		end
	end
	return nil
end

local function findOmegaSwordWeapon(v)
	for _, w in pairs(v._Setting._EquipDatas._WeaponShortSword._Values) do
		if tonumber(w._ModelId) == OMEGA_SWORD_MODEL_ID then
			local name = localizedName(w._Name) or "?"
			log.info(("[LayeredFXVisual] Omega weapon: _ModelId=%d found on _WeaponShortSword: name='%s'"):format(OMEGA_SWORD_MODEL_ID, name))
			return OMEGA_SWORD_MODEL_ID
		end
	end
	return nil
end

local function findOmegaSwordLayered(v)
	for _, w in pairs(v._Setting._EquipDatas._OuterWeaponShortSword._Values) do
		if tonumber(w._Id) == OMEGA_SWORD_LAYERED_ID then
			local name = localizedName(w._Name) or "?"
			log.info(("[LayeredFXVisual] Omega layered: _Id=%d found on _OuterWeaponShortSword: name='%s'"):format(OMEGA_SWORD_LAYERED_ID, name))
			return OMEGA_SWORD_LAYERED_ID
		end
	end
	return nil
end

local function findOmegaRodWeapon(v)
	for _, w in pairs(v._Setting._EquipDatas._WeaponRod._Values) do
		if tonumber(w._ModelId) == OMEGA_ROD_MODEL_ID then
			local name = localizedName(w._Name) or "?"
			log.info(("[LayeredFXVisual] Omega Rod weapon: _ModelId=%d found on _WeaponRod: name='%s'"):format(OMEGA_ROD_MODEL_ID, name))
			return OMEGA_ROD_MODEL_ID
		end
	end
	return nil
end

local function findOmegaRodLayered(v)
	for _, w in pairs(v._Setting._EquipDatas._OuterWeaponRod._Values) do
		if tonumber(w._Id) == OMEGA_ROD_LAYERED_ID then
			local name = localizedName(w._Name) or "?"
			log.info(("[LayeredFXVisual] Omega Rod layered: _Id=%d found on _OuterWeaponRod: name='%s'"):format(OMEGA_ROD_LAYERED_ID, name))
			return OMEGA_ROD_LAYERED_ID
		end
	end
	return nil
end

-- Required skills on _SkillCommonData._Values
local function findSkills(v)
	local skills = {
		[SHATTER_SKILL_ID] = "Shatter skill",
		[SHIELD_SKILL_ID] = "Shield skill",
		[SYNERGY_SKILL_ID] = "Synergy skill",
	}
	local hits = {}
	for _, e in pairs(v._Setting._SkillCommonData._Values) do
		local bid = tonumber(e:get_field("<skillId>k__BackingField"))
		if bid and skills[bid] and not hits[bid] then
			local name = localizedName(e._skillName) or "?"
			log.info(("[LayeredFXVisual] %s: <skillId>=%d found on _SkillCommonData: name='%s'"):format(skills[bid], bid, name))
			hits[bid] = true
			if hits[SHATTER_SKILL_ID] and hits[SHIELD_SKILL_ID] and hits[SYNERGY_SKILL_ID] then break end
		end
	end

	return (hits[SHATTER_SKILL_ID] and SHATTER_SKILL_ID or nil),
	       (hits[SHIELD_SKILL_ID] and SHIELD_SKILL_ID or nil),
	       (hits[SYNERGY_SKILL_ID] and SYNERGY_SKILL_ID or nil)
end

local function isDataReady()
	local v = getVariousDataMgr()
	if not v then return false, nil end
	local ok, vals = pcall(function() return v._Setting._EquipDatas._WeaponLongSword._Values end)
	if not ok or not vals then return false, nil end
	return true, v
end

local function tryFind()
	if Discovery.complete then return end

	local ready, v = isDataReady()
	if not ready then return end

	Found.Shatter.model = findShatterWeapon(v)
	Found.Shatter.layered = findShatterLayered(v)
	Found.OmegaSword.model = findOmegaSwordWeapon(v)
	Found.OmegaSword.layered = findOmegaSwordLayered(v)
	Found.OmegaRod.model = findOmegaRodWeapon(v)
	Found.OmegaRod.layered = findOmegaRodLayered(v)
	Found.Shatter.skill, Found.OmegaSword.skill, Found.OmegaRod.skill = findSkills(v)

	Found.Shatter.all = (Found.Shatter.model ~= nil) and (Found.Shatter.layered ~= nil) and (Found.Shatter.skill ~= nil)
	Found.OmegaSword.all = (Found.OmegaSword.model ~= nil) and (Found.OmegaSword.layered ~= nil) and (Found.OmegaSword.skill ~= nil)
	Found.OmegaRod.all = (Found.OmegaRod.model ~= nil) and (Found.OmegaRod.layered ~= nil) and (Found.OmegaRod.skill ~= nil)

	if not Found.Shatter.model then table.insert(Discovery.missing.Shatter, ItemLabels.Shatter.model) end
	if not Found.Shatter.layered then table.insert(Discovery.missing.Shatter, ItemLabels.Shatter.layered) end
	if not Found.Shatter.skill then table.insert(Discovery.missing.Shatter, ItemLabels.Shatter.skill) end
	if not Found.OmegaSword.model then table.insert(Discovery.missing.OmegaSword, ItemLabels.OmegaSword.model) end
	if not Found.OmegaSword.layered then table.insert(Discovery.missing.OmegaSword, ItemLabels.OmegaSword.layered) end
	if not Found.OmegaSword.skill then table.insert(Discovery.missing.OmegaSword, ItemLabels.OmegaSword.skill) end
	if not Found.OmegaRod.model then table.insert(Discovery.missing.OmegaRod, ItemLabels.OmegaRod.model) end
	if not Found.OmegaRod.layered then table.insert(Discovery.missing.OmegaRod, ItemLabels.OmegaRod.layered) end
	if not Found.OmegaRod.skill then table.insert(Discovery.missing.OmegaRod, ItemLabels.OmegaRod.skill) end

	Discovery.complete = true
	if Found.Shatter.all then
		log.info("[LayeredFXVisual] all shatter items found, enabled shatter")
	else
		log.warn(("[LayeredFXVisual] shatter items missing: %s"):format(table.concat(Discovery.missing.Shatter, ", ")))
	end
	if Found.OmegaSword.all then
		log.info("[LayeredFXVisual] all omega sword items found, enabled omega sword")
	else
		log.warn(("[LayeredFXVisual] omega sword items missing: %s"):format(table.concat(Discovery.missing.OmegaSword, ", ")))
	end
	if Found.OmegaRod.all then
		log.info("[LayeredFXVisual] all omega rod items found, enabled omega rod")
	else
		log.warn(("[LayeredFXVisual] omega rod items missing: %s"):format(table.concat(Discovery.missing.OmegaRod, ", ")))
	end
end

-- Each frame master (player) state

local Shatter_master_model
local Shatter_master_layered
local Shatter_snap_val -- game default
local Shatter_was_active = false

local Omega_Sword_master_model
local Omega_Sword_master_layered
local Omega_Sword_snap = {} -- game default
local Omega_Sword_snap_tmp = {} -- avoid allocation during validate
local Omega_Sword_was_active = false

local Omega_Rod_master_model
local Omega_Rod_master_layered
local Omega_Rod_snap = {} -- game default
local Omega_Rod_snap_tmp = {} -- avoid allocation during validate
local Omega_Rod_was_active = false

-- Visuals IFF
--     Enabled
--     All items found
--     Corresponding layered
--   NOT base weapon (simply default behavior)
local function isShatterVisualOnly()
	if not Config.Shatter.Enabled then return false end
	if not Found.Shatter.all then return false end
	if not Shatter_master_model then return false end
	if not Shatter_master_layered or Shatter_master_layered < 0 then return false end
	if Shatter_master_layered ~= Found.Shatter.layered then return false end
	if Shatter_master_model == Found.Shatter.model then return false end
	return true
end

local function isOmegaSwordVisualOnly()
	if not Config.OmegaSword.Enabled then return false end
	if not Found.OmegaSword.all then return false end
	if not Omega_Sword_master_model then return false end
	if not Omega_Sword_master_layered or Omega_Sword_master_layered < 0 then return false end
	if Omega_Sword_master_layered ~= Found.OmegaSword.layered then return false end
	if Omega_Sword_master_model == Found.OmegaSword.model then return false end
	return true
end

local function isOmegaRodVisualOnly()
	if not Config.OmegaRod.Enabled then return false end
	if not Found.OmegaRod.all then return false end
	if not Omega_Rod_master_model then return false end
	if not Omega_Rod_master_layered or Omega_Rod_master_layered < 0 then return false end
	if Omega_Rod_master_layered ~= Found.OmegaRod.layered then return false end
	if Omega_Rod_master_model == Found.OmegaRod.model then return false end
	return true
end

-- Hook skill
local cached_skill_id = nil
sdk.hook(getSkillLevelCore,
	function(args)
		cached_skill_id = sdk.to_int64(args[4])
	end,
	function(retval)
		if Found.Shatter.all and cached_skill_id == Found.Shatter.skill and isShatterVisualOnly() then
			return sdk.to_ptr(1)
		end
		if Found.OmegaSword.all and cached_skill_id == Found.OmegaSword.skill and isOmegaSwordVisualOnly() then
			return sdk.to_ptr(1)
		end
		if Found.OmegaRod.all and cached_skill_id == Found.OmegaRod.skill and isOmegaRodVisualOnly() then
			return sdk.to_ptr(1)
		end
		return retval
	end
)

-- Cache params for game defaults

-- Shatterseal damage on PlayerManager._Catalog._WeaponsResident._Wp00ActionParam
local _wp00_cached
local function getWp00ActionParam()
	if _wp00_cached then return _wp00_cached end
	local pm = getPlayerManager()
	if not pm then return nil end
	local c = getMasterChar()
	if not c then return nil end
	if not c:get_IsMaster() then return nil end
	local catalog = pm._Catalog
	if not catalog then return nil end
	local wr = catalog._WeaponsResident
	if not wr then return nil end
	_wp00_cached = wr._Wp00ActionParam
	return _wp00_cached
end

-- Synthetic Shield + Synergy fields on PlayerManager._Catalog._GlobalParam._SkillParam
local _skillparam_cached
local function getSkillParam()
	if _skillparam_cached then return _skillparam_cached end
	local pm = getPlayerManager()
	if not pm then return nil end
	local c = getMasterChar()
	if not c then return nil end
	if not c:get_IsMaster() then return nil end
	local catalog = pm._Catalog
	if not catalog then return nil end
	local gp = catalog._GlobalParam
	if not gp then return nil end
	_skillparam_cached = gp._SkillParam
	return _skillparam_cached
end

-- Each frame: snap game defaults, suppress effect (write 0) while active, restore on disable
re.on_frame(function()
	tryFind()

	-- Fetch equip for equipWork + layered ID
	local equip = getEquip()
	local equipWork, layered_shatter, layered_omega_sword, layered_omega_rod
	if equip then
		local idx = equip._EquipIndex.Index[0].m_value
		equipWork = equip._EquipBox[idx]
		local arr = equip.OuterMainWeaponCurrent
		if arr then
			local v0 = arr[SHATTER_TYPE_INDEX]
			if v0 ~= nil then layered_shatter = tonumber(v0.m_value) or tonumber(v0) end
			local v1 = arr[OMEGA_SWORD_TYPE_INDEX]
			if v1 ~= nil then layered_omega_sword = tonumber(v1.m_value) or tonumber(v1) end
			local v2 = arr[OMEGA_ROD_TYPE_INDEX]
			if v2 ~= nil then layered_omega_rod = tonumber(v2.m_value) or tonumber(v2) end
		end
	end

	-- Current weapon data
	local wd = equipWork and getWeaponData:call(nil, equipWork) or nil

	-- Equipped GS
	if wd and wd._LongSword and wd._LongSword ~= 0 then
		Shatter_master_model = tonumber(wd._ModelId)
	else
		Shatter_master_model = nil
	end
	Shatter_master_layered = layered_shatter

	-- Equipped SnS
	if wd and wd._ShortSword and wd._ShortSword ~= 0 then
		Omega_Sword_master_model = tonumber(wd._ModelId)
	else
		Omega_Sword_master_model = nil
	end
	Omega_Sword_master_layered = layered_omega_sword

	-- Equipped IG
	if wd and wd._Rod and wd._Rod ~= 0 then
		Omega_Rod_master_model = tonumber(wd._ModelId)
	else
		Omega_Rod_master_model = nil
	end
	Omega_Rod_master_layered = layered_omega_rod

	-- Shatter
	local wp00 = getWp00ActionParam()
	if wp00 then
		local current = wp00:get_field(SHATTER_DAMAGE_FIELD)
		local active = isShatterVisualOnly()

		-- Snap game's MV
		if current ~= nil and (Shatter_snap_val == nil or (not active and not Shatter_was_active)) then
			Shatter_snap_val = current
		end

		-- Restore on transition out
		if not active and Shatter_was_active then
			if Shatter_snap_val ~= nil then
				wp00:set_field(SHATTER_DAMAGE_FIELD, Shatter_snap_val)
			end
		end
		Shatter_was_active = active

		-- Suppress effect while active (no damage)
		if active and current ~= 0 then
			wp00:set_field(SHATTER_DAMAGE_FIELD, 0)
		end
	end

	-- Omega Sword + Omega Rod share _SkillParam
	local sp = getSkillParam()
	if sp then
		-- Omega Sword
		local sword_active = isOmegaSwordVisualOnly()

		-- Snap game's values (reject zeros — likely uninitialised or our own writes)
		if next(Omega_Sword_snap) == nil or (not sword_active and not Omega_Sword_was_active) then
			local all_positive = true
			for i = 1, #SHIELD_FIELDS do
				local f = SHIELD_FIELDS[i]
				local cur = sp:get_field(f)
				Omega_Sword_snap_tmp[f] = cur
				if not cur or cur <= 0 then all_positive = false end
			end
			if all_positive then
				for i = 1, #SHIELD_FIELDS do
					local f = SHIELD_FIELDS[i]
					Omega_Sword_snap[f] = Omega_Sword_snap_tmp[f]
				end
			end
		end

		-- Restore on transition out
		if not sword_active and Omega_Sword_was_active then
			for _, f in ipairs(SHIELD_FIELDS) do
				local snapped = Omega_Sword_snap[f]
				if snapped ~= nil then
					sp:set_field(f, snapped)
				end
			end
		end
		Omega_Sword_was_active = sword_active

		-- Suppress effect while active (no buff). Only write if we have a valid
		-- snap to restore from later.
		if sword_active and next(Omega_Sword_snap) ~= nil then
			for i = 1, #SHIELD_FIELDS do
				local f = SHIELD_FIELDS[i]
				if sp:get_field(f) ~= 0 then
					sp:set_field(f, 0)
				end
			end
		end

		-- Omega Rod
		local rod_active = isOmegaRodVisualOnly()

		-- Snap game's values
		if next(Omega_Rod_snap) == nil or (not rod_active and not Omega_Rod_was_active) then
			local all_positive = true
			for i = 1, #COOP_FIELDS do
				local f = COOP_FIELDS[i]
				local cur = sp:get_field(f)
				Omega_Rod_snap_tmp[f] = cur
				if not cur or cur <= 0 then all_positive = false end
			end
			if all_positive then
				for i = 1, #COOP_FIELDS do
					local f = COOP_FIELDS[i]
					Omega_Rod_snap[f] = Omega_Rod_snap_tmp[f]
				end
			end
		end

		-- Restore on transition out
		if not rod_active and Omega_Rod_was_active then
			for _, f in ipairs(COOP_FIELDS) do
				local snapped = Omega_Rod_snap[f]
				if snapped ~= nil then
					sp:set_field(f, snapped)
				end
			end
		end
		Omega_Rod_was_active = rod_active

		-- Suppress effect while active (no buff)
		if rod_active and next(Omega_Rod_snap) ~= nil then
			for i = 1, #COOP_FIELDS do
				local f = COOP_FIELDS[i]
				if sp:get_field(f) ~= 0 then
					sp:set_field(f, 0)
				end
			end
		end
	end
end)

-- UI

local function drawShatterSection()
	if not Found.Shatter.all then
		imgui.text_colored("Shatter disabled. Required item not found:", 0xffff0000)
		for _, label in ipairs(Discovery.missing.Shatter) do
			imgui.text_colored("  - " .. label, 0xffff0000)
		end
		return
	end

	local changed
	changed, Config.Shatter.Enabled = imgui.checkbox("Enabled##shatter", Config.Shatter.Enabled)
	if changed then saveConfig() end
end

local function drawOmegaSwordSection()
	if not Found.OmegaSword.all then
		imgui.text_colored("Omega Sword disabled. Required item not found:", 0xffff0000)
		for _, label in ipairs(Discovery.missing.OmegaSword) do
			imgui.text_colored("  - " .. label, 0xffff0000)
		end
		return
	end

	local changed
	changed, Config.OmegaSword.Enabled = imgui.checkbox("Enabled##omega_sword", Config.OmegaSword.Enabled)
	if changed then saveConfig() end
end

local function drawOmegaRodSection()
	if not Found.OmegaRod.all then
		imgui.text_colored("Omega Rod disabled. Required item not found:", 0xffff0000)
		for _, label in ipairs(Discovery.missing.OmegaRod) do
			imgui.text_colored("  - " .. label, 0xffff0000)
		end
		return
	end

	local changed
	changed, Config.OmegaRod.Enabled = imgui.checkbox("Enabled##omega_rod", Config.OmegaRod.Enabled)
	if changed then saveConfig() end
end

re.on_draw_ui(function()
	if not imgui.tree_node("LayeredFX") then return end

	if imgui.tree_node("Shattering Reflection (Greatsword)") then
		drawShatterSection()
		imgui.tree_pop()
	end
	if imgui.tree_node("Synthetic Shield (Sword & Shield)") then
		drawOmegaSwordSection()
		imgui.tree_pop()
	end
	if imgui.tree_node("Synergy (Insect Glaive)") then
		drawOmegaRodSection()
		imgui.tree_pop()
	end

	imgui.tree_pop()
end)
