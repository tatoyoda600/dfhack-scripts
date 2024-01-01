-- Prompt units to adjust their uniform.
local utils = require('utils')

local validArgs = utils.invert({
    'all',
    'drop',
    'free',
    'multi',
    'help'
})

-- Functions

local function item_description(item)
    return dfhack.df2console(dfhack.items.getDescription(item, 0, true))
end

local function get_item_pos(item)
    local x, y, z = dfhack.items.getPosition(item)
    if not x or not y or not z then
        return
    end

    if dfhack.maps.isTileVisible(x, y, z) then
        return xyz2pos(x, y, z)
    end
end

local function get_squad_position(unit)
    local squad = df.squad.find(unit.military.squad_id)
    if not squad then return end
    if #squad.positions > unit.military.squad_position then
        return squad.positions[unit.military.squad_position]
    end
end

local function bodyparts_that_can_wear(unit, item)
    local bodyparts = {}
    local unitparts = df.creature_raw.find(unit.race).caste[unit.caste].body_info.body_parts

    if item._type == df.item_helmst then
        for index, part in ipairs(unitparts) do
            if part.flags.HEAD then
                table.insert(bodyparts, index)
            end
        end
    elseif item._type == df.item_armorst then
        for index, part in ipairs(unitparts) do
            if part.flags.UPPERBODY then
                table.insert(bodyparts, index)
            end
        end
    elseif item._type == df.item_glovesst then
        for index, part in ipairs(unitparts) do
            if part.flags.GRASP then
                table.insert(bodyparts, index)
            end
        end
    elseif item._type == df.item_pantsst then
        for index, part in ipairs(unitparts) do
            if part.flags.LOWERBODY then
                table.insert(bodyparts, index)
            end
        end
    elseif item._type == df.item_shoesst then
        for index, part in ipairs(unitparts) do
            if part.flags.STANCE then
                table.insert(bodyparts, index)
            end
        end
    else
        -- print("Ignoring item type for "..item_description(item) )
    end

    return bodyparts
end

-- Will figure out which items need to be moved to the floor, returns an item_id:item map
local function process(unit, args)
    local silent = args.all -- Don't print details if we're iterating through all dwarves
    local unit_name = dfhack.df2console(dfhack.TranslateName(dfhack.units.getVisibleName(unit)))

    if not silent then
        print("Processing unit " .. unit_name)
    end

    -- The return value
    local to_drop = {} -- item id to item object

    -- First get squad position for an early-out for non-military dwarves
    local squad_position = get_squad_position(unit)
    if not squad_position then
        if not silent then
            print("Unit " .. unit_name .. " does not have a military uniform.")
        end
        return
    end

    -- Find all worn items which may be at issue.
    local worn_items = {} -- map of item ids to item objects
    local worn_parts = {} -- map of item ids to body part ids
    for _, inv_item in ipairs(unit.inventory) do
        local item = inv_item.item
        -- Include weapons so we can check we have them later
        if inv_item.mode == df.unit_inventory_item.T_mode.Worn or
            inv_item.mode == df.unit_inventory_item.T_mode.Weapon
        then
            worn_items[item.id] = item
            worn_parts[item.id] = inv_item.body_part_id
        end
    end

    -- Now get info about which items have been assigned as part of the uniform
    local assigned_items = {} -- assigned item ids mapped to item objects
    for _, specs in ipairs(squad_position.uniform) do
        for _, spec in ipairs(specs) do
            for _, assigned in ipairs(spec.assigned) do
                -- Include weapon and shield so we can avoid dropping them, or pull them out of container/inventory later
                assigned_items[assigned] = df.item.find(assigned)
            end
        end
    end

    -- Figure out which assigned items are currently not being worn
    -- and if some other unit is carrying the item, unassign it from this unit's uniform

    local present_ids = {} -- map of item ID to item object
    local missing_ids = {} -- map of item ID to item object
    for u_id, item in pairs(assigned_items) do
        if not worn_items[u_id] then
            print("Unit " .. unit_name .. " is missing an assigned item, object #" .. u_id .. " '" ..
                item_description(item) .. "'")
            if dfhack.items.getGeneralRef(item, df.general_ref_type.UNIT_HOLDER) then
                print("  Another unit has a claim on object #" .. u_id .. " '" .. item_description(item) .. "'")
                if args.free then
                    print("  Removing from uniform")
                    assigned_items[u_id] = nil
                    for _, specs in ipairs(squad_position.uniform) do
                        for _, spec in ipairs(specs) do
                            for idx, assigned in ipairs(spec.assigned) do
                                if assigned == u_id then
                                    spec.assigned:erase(idx)
                                    break
                                end
                            end
                        end
                    end
                    unit.military.pickup_flags.update = true
                end
            else
                missing_ids[u_id] = item
                if args.free then
                    to_drop[u_id] = item
                end
            end
        else
            present_ids[u_id] = item
        end
    end

    -- Figure out which worn items should be dropped

    -- First, figure out which body parts are covered by the uniform pieces we have.
    -- unless --multi is specified, in which we don't care
    local covered = {} -- map of body part id to true/nil
    if not args.multi then
        for id, item in pairs(present_ids) do
            -- weapons and shields don't "cover" the bodypart they're assigned to. (Needed to figure out if we're missing gloves.)
            if item._type ~= df.item_weaponst and item._type ~= df.item_shieldst then
                covered[worn_parts[id]] = true
            end
        end
    end

    -- Figure out body parts which should be covered but aren't
    local uncovered = {}
    for _, item in pairs(missing_ids) do
        for _, bp in ipairs(bodyparts_that_can_wear(unit, item)) do
            if not covered[bp] then
                uncovered[bp] = true
            end
        end
    end

    -- Drop everything (except uniform pieces) from body parts which should be covered but aren't
    for w_id, item in pairs(worn_items) do
        if assigned_items[w_id] == nil then -- don't drop uniform pieces (including shields, weapons for hands)
            if uncovered[worn_parts[w_id]] then
                print("Unit " ..
                    unit_name ..
                    " potentially has object #" ..
                    w_id .. " '" .. item_description(item) .. "' blocking a missing uniform item.")
                if args.drop then
                    to_drop[w_id] = item
                end
            end
        end
    end

    return to_drop
end

local function do_drop(item_list)
    if not item_list then
        return
    end

    for id, item in pairs(item_list) do
        local pos = get_item_pos(item)
        if not pos then
            dfhack.printerr("Could not find drop location for item #" .. id .. "  " .. item_description(item))
        else
            if dfhack.items.moveToGround(item, pos) then
                print("Dropped item #" .. id .. " '" .. item_description(item) .. "'")
            else
                dfhack.printerr("Could not drop object #" .. id .. "  " .. item_description(item))
            end
        end
    end
end


-- Main

local args = utils.processArgs({ ... }, validArgs)

if args.help then
    print(dfhack.script_help())
    return
end

if args.all then
    for _, unit in ipairs(dfhack.units.getCitizens(false)) do
        do_drop(process(unit, args))
    end
else
    local unit = dfhack.gui.getSelectedUnit()
    if unit then
        do_drop(process(unit, args))
    else
        qerror("Please select a unit if not running with --all")
    end
end
