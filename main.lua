return function(mod)
  mod.options:define({
    { key = "debug_ticket_events", label = "DEBUG TICKET EVENTS", type = "toggle", default = false },
  })

  local function debugTicketEvents()
    return mod.options:get("debug_ticket_events") == true
  end

  if mod.generation ~= 3 then return end

  local installed = false
  local function install()
    if installed then return true end

    local okUntamed, untamed = pcall(function() return mod:find("untamed_advanced") end)
    local engine = okUntamed and untamed and untamed.exports and untamed.exports.engine
    if type(engine) ~= "table" then
      mod.log:error("Navel Rock + Birth Island Events requires Untamed Advanced")
      return false
    end

    local function darkraiRoamingTime()
      local hour = tonumber(os.date("*t").hour) or 0
      return hour >= 18 or hour < 4
    end

    -- FRLG normally keeps only one roaming beast in session.roamer. Keep all
    -- three in that same saved field so each has independent route, HP/status,
    -- personality/IVs, and caught state while preserving the native mechanics.
    local Roamer = require("src.core.game3.roamer")
    if not Roamer._allBeastsInstalled then
      local rawInit = Roamer.init
      local rawMove = Roamer.move
      local rawJump = Roamer.jump
      local rawTryEncounter = Roamer.tryEncounter
      local rawBattleEnd = Roamer.onBattleEnd

      local function isMulti(r)
        return type(r) == "table" and type(r.beasts) == "table"
      end

      local function withBeast(session, beast, fn, ...)
        local saved = session.roamer
        session.roamer = beast
        local result = fn(session, ...)
        session.roamer = saved
        return result
      end

      Roamer.init = function(session, starterChoice)
        if not session then return false end
        local darkrai
        if isMulti(session.roamer) then
          for _, beast in ipairs(session.roamer.beasts) do
            if beast.darkrai then darkrai = beast break end
          end
        end
        local beasts = {}
        for _, starter in ipairs({ 1, 0, 2 }) do
          rawInit(session, starter)
          beasts[#beasts + 1] = session.roamer
        end
        if darkrai then beasts[#beasts + 1] = darkrai end
        session.roamer = { active = true, beasts = beasts }
        return true
      end

      Roamer.move = function(session, reason, mapId)
        local group = session and session.roamer
        if not isMulti(group) then return rawMove(session, reason, mapId) end
        for _, beast in ipairs(group.beasts) do
          if beast.active then withBeast(session, beast, rawMove, reason, mapId) end
        end
      end

      Roamer.jump = function(session)
        local group = session and session.roamer
        if not isMulti(group) then return rawJump(session) end
        for _, beast in ipairs(group.beasts) do
          if beast.active then withBeast(session, beast, rawJump) end
        end
      end

      Roamer.tryEncounter = function(session, mapId, terrain)
        local group = session and session.roamer
        if not isMulti(group) then return rawTryEncounter(session, mapId, terrain) end

        local candidates = {}
        for _, beast in ipairs(group.beasts) do
          if beast.active
            and (not beast.darkrai or darkraiRoamingTime())
            and Roamer.normalizeMapId(beast.map) == Roamer.normalizeMapId(mapId) then
            candidates[#candidates + 1] = beast
          end
        end
        if #candidates == 0 then return nil end
        local start = (math.random(#candidates))
        for offset = 0, #candidates - 1 do
          local beast = candidates[((start + offset - 1) % #candidates) + 1]
          local enc = withBeast(session, beast, rawTryEncounter, mapId, terrain)
          if enc then return enc end
        end
        return nil
      end

      Roamer.onBattleEnd = function(session, foeState, battleResult, endReason)
        local group = session and session.roamer
        if not isMulti(group) then
          return rawBattleEnd(session, foeState, battleResult, endReason)
        end
        local species = foeState and (foeState.species or foeState.speciesId)
        for _, beast in ipairs(group.beasts) do
          if beast.active and beast.species == species then
            local result = withBeast(session, beast, rawBattleEnd, foeState, battleResult, endReason)
            if beast.darkrai and battleResult ~= "caught" and not beast.active then
              beast.active = true
              beast.hp = beast.maxHp
              beast.status, beast.statusNum = 0, 0
              withBeast(session, beast, rawJump)
            end
            return result
          end
        end
      end

      Roamer._allBeastsInstalled = true
    end

    -- Untamed models FRLG roamers as category 0. Keep that public category,
    -- but pin the exact grouped roamer chosen for its visible OWE so the
    -- collision/A-press battle resolves to the same persistent individual.
    if engine.roamerAt and not engine._groupedRoamerOWEInstalled then
      local visibleRoamer = nil

      engine.roamerAt = function(index)
        if index ~= 0 then return nil end
        local session = engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession()
        local mapId = session and session.map
        if not session or not mapId then visibleRoamer = nil; return nil end

        if visibleRoamer and visibleRoamer.mapId == mapId then
          local beast = visibleRoamer.beast
          if beast and beast.active
            and (not beast.darkrai or darkraiRoamingTime())
            and Roamer.normalizeMapId(beast.map) == Roamer.normalizeMapId(mapId) then
            return visibleRoamer.species, visibleRoamer.level, visibleRoamer.foe
          end
          visibleRoamer = nil
        end

        local enc = Roamer.tryEncounter(session, mapId, "land")
        if not enc then return nil end

        local chosen
        local group = session.roamer
        if type(group) == "table" and type(group.beasts) == "table" then
          for _, beast in ipairs(group.beasts) do
            if beast.active and beast.species == enc.species
              and Roamer.normalizeMapId(beast.map) == Roamer.normalizeMapId(mapId) then
              chosen = beast
              break
            end
          end
        end

        visibleRoamer = {
          mapId = mapId,
          beast = chosen,
          species = enc.species,
          level = enc.level,
          foe = enc.foe,
        }
        return enc.species, enc.level, enc.foe
      end

      local rawUntamedRoamerMove = engine.roamerMove
      engine.roamerMove = function(index)
        visibleRoamer = nil
        if rawUntamedRoamerMove then return rawUntamedRoamerMove(index) end
      end

      mod.events:on("map.entered", function()
        visibleRoamer = nil
      end)

      engine._groupedRoamerOWEInstalled = true
    end


    local Bag = require("src.core.game3.bag")
    local Objects = require("src.core.game3.objects")
    local Message = require("src.ui.game3.message")

    local MYSTIC_TICKET = 370
    local AURORA_TICKET = 371
    local FLAG_ENABLE_SHIP_NAVEL_ROCK = 0x84A
    local FLAG_ENABLE_SHIP_BIRTH_ISLAND = 0x84B
    local FLAG_RECEIVED_MYSTIC_TICKET = 0x2A8
    local FLAG_RECEIVED_AURORA_TICKET = 0x2A7
local FLAG_SHOWN_MYSTIC_TICKET = 0x2F0
    local FLAG_SHOWN_AURORA_TICKET = 0x2F1
    local VAR_MAP_SCENE_ONE_ISLAND_POKEMON_CENTER_1F = 0x4076
    local VAR_MAP_SCENE_VERMILION_CITY = 0x407E
    local LEGENDARY_UNLOCK = { 144, 145, 146, 243, 244, 245 }
    local Dex = require("src.core.game3.dex")
    local MysteryGift = require("src.core.game3.mystery_gift")
    local mysticTicketBusy = false
    local auroraTicketBusy = false

    local function hasRayquaza(session)
      if debugTicketEvents() then return true end
      return session and session.dex and Dex.isCaught(session.dex, 384) == true
    end

    local function hasLegendarySet(session)
      if debugTicketEvents() then return true end
      if not session or not session.dex then return false end
      for _, species in ipairs(LEGENDARY_UNLOCK) do
        if not Dex.isCaught(session.dex, species) then return false end
      end
      return true
    end

    -- FireRed only checks event tickets at Vermilion. Extend the shared
    -- Seagallop menu so the MysticTicket can also reach Navel Rock from
    -- the Sevii harbors without replacing any normal island destination.
    do
      local okSea, Seagallop = pcall(require, "src.core.game3.scripting.natives_seagallop")
      local okSpaceSea, SpaceSea = pcall(require, "src.core.game3.scripting.space")
      local okFlagsSea, FlagsSea = pcall(require, "src.core.game3.scripting.flags")
      local okBagSea, BagSea = pcall(require, "src.core.game3.bag")
      if okSea and okSpaceSea and okFlagsSea and okBagSea and Seagallop
          and not Seagallop._mysticTicketCompat then
        Seagallop._mysticTicketCompat = true
        local oldMenu = Seagallop.destinationMenu
        local oldSelected = Seagallop.selectedDestination
        local oldFerryTask = Seagallop.ferryTask
        local pendingNavel = false
        local pendingBirth = false

        local function hasAuroraTicket()
          local session = engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession()
          local ctx = SpaceSea.vm and SpaceSea.vm.ctx or nil
          return session and session.bag
            and BagSea.get(session.bag, AURORA_TICKET) > 0
            and FlagsSea.getFlag(SpaceSea.store, ctx, FLAG_ENABLE_SHIP_BIRTH_ISLAND) == true
        end

        local function hasMysticTicket()
          local session = engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession()
          local ctx = SpaceSea.vm and SpaceSea.vm.ctx or nil
          return session and session.bag
            and BagSea.get(session.bag, MYSTIC_TICKET) > 0
            and FlagsSea.getFlag(SpaceSea.store, ctx, FLAG_ENABLE_SHIP_NAVEL_ROCK) == true
        end

        Seagallop.destinationMenu = function(originId, page)
          local labels, top = oldMenu(originId, page)
          if page == 1 then
            if hasMysticTicket() then table.insert(labels, #labels, "NAVEL ROCK") end
            if hasAuroraTicket() then table.insert(labels, #labels, "BIRTH ISLAND") end
          end
          return labels, top
        end

        Seagallop.selectedDestination = function(originId, page, result)
          if page == 1 then
            local nextResult = 4
            if hasMysticTicket() then
              if result == nextResult then
                pendingNavel, pendingBirth = true, false
                return 4
              end
              nextResult = nextResult + 1
            end
            if hasAuroraTicket() and result == nextResult then
              pendingNavel, pendingBirth = false, true
              return 4
            end
            if hasAuroraTicket() then nextResult = nextResult + 1 end
            -- Extra ticket destinations are inserted immediately before EXIT.
            -- Translate the shifted EXIT index back to the stock page-2 EXIT slot.
            if result == nextResult then
              pendingNavel, pendingBirth = false, false
              return 127
            end
          end
          pendingNavel, pendingBirth = false, false
          return oldSelected(originId, page, result)
        end

        Seagallop.ferryTask = function(ctx, adapters, destId)
          if pendingNavel and destId == 4 then
            pendingNavel, pendingBirth = false, false
            return oldFerryTask(ctx, adapters, 9)
          end
          if pendingBirth and destId == 4 then
            pendingNavel, pendingBirth = false, false
            return oldFerryTask(ctx, adapters, 10)
          end
          pendingNavel, pendingBirth = false, false
          return oldFerryTask(ctx, adapters, destId)
        end


      end
    end

    local function oneIslandCenter(mapId)
      local okCatalog, MapCatalog = pcall(require, "src.import.gba.map_catalog")
      if okCatalog and MapCatalog and MapCatalog.pretToEngine then
        local expected = MapCatalog.pretToEngine("OneIsland_PokemonCenter_1F")
        if expected and mapId == expected then return true end
      end
      local id = tostring(mapId or ""):upper()
      return (id:find("ONE_ISLAND", 1, true) or id:find("ONEISLAND", 1, true))
        and (id:find("POKEMON_CENTER_1F", 1, true) or id:find("POKEMONCENTER_1F", 1, true))
    end

    local function mysticTicketState(session)
      session.modData = session.modData or {}
      session.modData[mod.id] = session.modData[mod.id] or {}
      return session.modData[mod.id]
    end

    local function enableTicketDebugTravel(session)
      if not debugTicketEvents() or not session then return end
      local okSpace, Space = pcall(require, "src.core.game3.scripting.space")
      local okFlags, Flags = pcall(require, "src.core.game3.scripting.flags")
      if not okSpace or not okFlags or not Space or not Flags or not Space.store then return end
      local ctx = Space.vm and Space.vm.ctx or nil
      -- Open only the normal Sevii/ferry progression needed to test both
      -- ticket events from an unfinished save. Catch flags stay untouched.
      Flags.setFlag(Space.store, ctx, 0x71, true)
      Flags.setFlag(Space.store, ctx, 0x72, true)
      Flags.setFlag(Space.store, ctx, 0x2DC, true)
      Flags.setFlag(Space.store, ctx, 0x2DD, true)
      Flags.setFlag(Space.store, ctx, 0x844, true)
      Flags.setVar(Space.store, ctx, VAR_MAP_SCENE_VERMILION_CITY, 3)
      Flags.setVar(Space.store, ctx, VAR_MAP_SCENE_ONE_ISLAND_POKEMON_CENTER_1F, 6)
    end

    local function tryTicketEvents()
      local session = engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession()
      local mapId = session and session.map
      local okSpace, Space = pcall(require, "src.core.game3.scripting.space")
      if okSpace and Space and Space.mapId then mapId = Space.mapId end
      if not session or not oneIslandCenter(mapId) or mysticTicketBusy or auroraTicketBusy then return false end
      local state = mysticTicketState(session)
      local hasMystic = state.mysticTicketGiven or MysteryGift.getFlag(session, FLAG_RECEIVED_MYSTIC_TICKET)
        or (session.bag and Bag.get(session.bag, MYSTIC_TICKET) > 0)
      local hasAurora = state.auroraTicketGiven or MysteryGift.getFlag(session, FLAG_RECEIVED_AURORA_TICKET)
        or (session.bag and Bag.get(session.bag, AURORA_TICKET) > 0)
      if hasMystic then state.mysticTicketGiven = true end
      if hasAurora then state.auroraTicketGiven = true end
      local giveMystic = not hasMystic and hasLegendarySet(session)
      local giveAurora = not hasAurora and hasRayquaza(session)
      if not giveMystic and not giveAurora then return false end

      local okFlags, Flags = pcall(require, "src.core.game3.scripting.flags")
      local ctx = Space and Space.vm and Space.vm.ctx or nil
      local function setTicketFlags(item)
        local enableFlag, receivedFlag, shownFlag
        if item == MYSTIC_TICKET then
          enableFlag, receivedFlag, shownFlag = FLAG_ENABLE_SHIP_NAVEL_ROCK, FLAG_RECEIVED_MYSTIC_TICKET, FLAG_SHOWN_MYSTIC_TICKET
          state.mysticTicketGiven = true
        else
          enableFlag, receivedFlag, shownFlag = FLAG_ENABLE_SHIP_BIRTH_ISLAND, FLAG_RECEIVED_AURORA_TICKET, FLAG_SHOWN_AURORA_TICKET
          state.auroraTicketGiven = true
        end
        MysteryGift.setFlag(session, enableFlag, true)
        MysteryGift.setFlag(session, receivedFlag, true)
        if okFlags and Space and Space.store then
          Flags.setFlag(Space.store, ctx, enableFlag, true)
          Flags.setFlag(Space.store, ctx, receivedFlag, true)
          Flags.setFlag(Space.store, ctx, shownFlag, false)
          Flags.setVar(Space.store, ctx, VAR_MAP_SCENE_VERMILION_CITY, 3)
          Flags.setVar(Space.store, ctx, VAR_MAP_SCENE_ONE_ISLAND_POKEMON_CENTER_1F, 5)
        end
      end
      local celioReturn
      local function unlock()
        local function finish()
          engine.Field.locked = false
          mysticTicketBusy, auroraTicketBusy = false, false
        end
        if celioReturn then
          local cb = celioReturn
          celioReturn = nil
          cb(finish)
        else
          finish()
        end
      end
      local function giveTicket(item, name, nextStep)
        if not Bag.add(session.bag, item, 1) then
          Message.show("Your KEY ITEMS POCKET is full.", unlock)
          return
        end
        setTicketFlags(item)
        Message.show("{PLAYER} received the "..name.."!", nextStep)
      end

      local function startTicketDialogue()
        if giveMystic and giveAurora then
        Message.show("Oh! Perfect timing!", function()
          Message.show("Two unusual tickets arrived for you.", function()
            Message.show("They both look like they're for the SEAGALLOP ferry.", function()
              giveTicket(MYSTIC_TICKET, "MYSTICTICKET", function()
                giveTicket(AURORA_TICKET, "AURORATICKET", function()
                  Message.show("I've never seen destinations like these before...", function()
                    Message.show("You should ask the sailor about them.", unlock)
                  end)
                end)
              end)
            end)
          end)
        end)
      else
        local alreadyHasOther = (giveMystic and hasAurora) or (giveAurora and hasMystic)
        Message.show("Oh! Perfect timing!", function()
          Message.show(alreadyHasOther and "Another unusual ticket arrived for you." or "Something unusual arrived for you.", function()
            Message.show("It looks like a ticket for the SEAGALLOP ferry.", function()
              local item = giveMystic and MYSTIC_TICKET or AURORA_TICKET
              local name = giveMystic and "MYSTICTICKET" or "AURORATICKET"
              giveTicket(item, name, function()
                Message.show("I've never seen a destination like this before...", function()
                  Message.show("You should ask the sailor about it.", unlock)
                end)
              end)
            end)
          end)
        end)
      end
      end

      local function celioApproach(nextStep)
        local celio, celioId
        for _, lid in ipairs(Objects._order or {}) do
          local eo = Objects._byId and Objects._byId[lid]
          if eo and tonumber(eo.graphicsId) == 89 then
            celio, celioId = eo, lid
            break
          end
        end
        if not celio or not celioId then
          nextStep()
          return
        end

        local x = tonumber(celio.x or (celio.def and celio.def.x)) or 15
        local y = tonumber(celio.y or (celio.def and celio.def.y)) or 6
        local startX, startY = x, y
        local startFacing = celio.facing or (celio.def and celio.def.facing)
        celioReturn = function(done)
          local back = {}
          local rx, ry = 9, 8
          while rx < startX do back[#back + 1] = { kind = "step", dir = "right" }; rx = rx + 1 end
          while rx > startX do back[#back + 1] = { kind = "step", dir = "left" }; rx = rx - 1 end
          while ry < startY do back[#back + 1] = { kind = "step", dir = "down" }; ry = ry + 1 end
          while ry > startY do back[#back + 1] = { kind = "step", dir = "up" }; ry = ry - 1 end
          if startFacing then back[#back + 1] = { kind = "turn", dir = startFacing } end
          Objects.startTrack(celioId, back, done)
        end
        local actions = {}
        while y < 8 do actions[#actions + 1] = { kind = "step", dir = "down" }; y = y + 1 end
        while y > 8 do actions[#actions + 1] = { kind = "step", dir = "up" }; y = y - 1 end
        while x > 9 do actions[#actions + 1] = { kind = "step", dir = "left" }; x = x - 1 end
        while x < 9 do actions[#actions + 1] = { kind = "step", dir = "right" }; x = x + 1 end
        actions[#actions + 1] = { kind = "turn", dir = "down" }
        Objects.startTrack(celioId, actions, nextStep)
      end

      mysticTicketBusy, auroraTicketBusy = true, true
      engine.Field.locked = true
      celioApproach(startTicketDialogue)
      return true
    end


    mod.events:on("map.entered", function()
      enableTicketDebugTravel(engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession())
      tryTicketEvents()
    end)
    mod.events:on("world.stepped", function()
      tryTicketEvents()
    end)

    installed = true
    mod.log:info("Navel Rock + Birth Island Events installed")
    return true
  end

  mod.events:on("game.ready", install, -40)
end
