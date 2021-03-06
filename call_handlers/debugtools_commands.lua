local Point3 = _radiant.csg.Point3
local InterruptAi = require 'mixintos.interrupt_ai.interrupt_ai'
local entity_forms_lib = require 'stonehearth.lib.entity_forms.entity_forms_lib'

local Commands = class()

function Commands:interrupt_ai(session, response, entity)
   stonehearth.ai:add_custom_action(entity, InterruptAi)
   radiant.events.listen(entity, 'debugtools:ai_interrupted', function()
         stonehearth.ai:remove_custom_action(entity, InterruptAi)
         return radiant.events.UNLISTEN
      end)
end

function Commands:create_and_place_entity(session, response, uri, iconic)
   local entity = radiant.entities.create_entity(uri)
   local entity_forms = entity:get_component('stonehearth:entity_forms')

   if iconic and entity_forms ~= nil then 
      entity = entity_forms:get_iconic_entity()
   end

   stonehearth.selection:select_location()
      :set_cursor_entity(entity)
      :done(function(selector, location, rotation)
            _radiant.call('debugtools:create_entity', uri, iconic, location, rotation)
               :done(function()
                  radiant.entities.destroy_entity(entity)
                  response:resolve(true)
               end)
         end)
      :fail(function(selector)
            selector:destroy()
            response:reject('no location')
         end)
      :always(function()
         end)
      :go()
end

function Commands:create_entity(session, response, uri, iconic, location, rotation)
   local entity = radiant.entities.create_entity(uri, { owner = session.player_id })
   local entity_forms = entity:get_component('stonehearth:entity_forms')

   if entity_forms == nil then
      iconic = false
   end

   radiant.terrain.place_entity(entity, location, { force_iconic = iconic })
   radiant.entities.turn_to(entity, rotation)
   local inventory = stonehearth.inventory:get_inventory(session.player_id)
   if inventory and not inventory:contains_item(entity) then
      inventory:add_item(entity)
   end
   
   return true
end

function Commands:destroy_npc_stockpiles(session, response, npc_player_id)
   if npc_player_id then
      return self:_destroy_player_stockpiles(npc_player_id)
   end
   local npcs = radiant.resources.load_json('stonehearth:data:npc_index')
   if npcs then
      for player_id, info in pairs(npcs) do
         self:_destroy_player_stockpiles(player_id)
      end
   end
   return true
end

function Commands:_destroy_player_stockpiles(player_id)
   local inventory = stonehearth.inventory:get_inventory(player_id)
   local stockpiles = inventory and inventory:get_all_stockpiles()
   if not stockpiles then
      return false
   end
   for id, entity in pairs(stockpiles) do
      radiant.entities.kill_entity(entity)
   end
   return true
end

function Commands:add_exp_command(session, response, entity, exp)
   local job_component = entity:get_component('stonehearth:job')
   if not job_component then
      return false
   end
   if not exp and not job_component:is_max_level() then
      job_component:level_up()
   else
      job_component:add_exp(exp)
   end
   return true
end

function Commands:set_attr_command(session, response, entity, attribute, value)
   local attribute_component = entity:get_component('stonehearth:attributes')
   if not attribute_component then
      return false
   end
   if attribute == 'health' then
      -- special case health because it's not actually an attribute
      radiant.entities.set_health(entity, value)
      return true
   end

   attribute_component:set_attribute(attribute, value)
   return true
end

function Commands:get_score_command(session, response, score_type)
   local scores = stonehearth.score:get_scores_for_player(session.player_id):get_score_data()
   local score = scores and scores.total_scores:get(score_type) or 0

   response:resolve({score = score})
end

function Commands:set_attr_to_all_citizens_command(session, response, attribute, value)
   local town = stonehearth.town:get_town(session.player_id)
   if town then
      local citizens = town:get_citizens()
      if citizens then
         for _, citizen in citizens:each() do
            local attribute_component = citizen:get_component('stonehearth:attributes')
            attribute_component:set_attribute(attribute, value)
         end
      end
      return true
   end
   return false
end

function Commands:set_game_speed_command(session, response, value)
   local default_speed = stonehearth.game_speed:get_default_speed() or 1
   local game_speed = stonehearth.game_speed
   game_speed:set_game_speed(default_speed * value, true)
   return true
end

function Commands:reset_location_command(session, response, entity, x, y, z)
   local location = radiant.entities.get_world_grid_location(entity)
   if x and y and z then
      location = Point3(x, y, z)
   end

   local placement_point = radiant.terrain.find_placement_point(location, 1, 4)
   radiant.terrain.place_entity(entity, placement_point)
   return true
end

function Commands:change_score_command(session, response, entity, scoreName, value)
   local score_component = entity:get_component('stonehearth:score')
   if not score_component then
      return false
   end
   if score_component:get_score(scoreName) == nil then
      return false
   end
   
   score_component:change_score(scoreName, value)
   return true
end

function Commands:reset_scores_command(session, response, entity)
   local score_component = entity:get_component('stonehearth:score')
   if not score_component then
      return false
   end   
   score_component:reset_all_scores()
   return true
end

function Commands:add_buff_command(session, response, entity, buff_uri)
   radiant.entities.add_buff(entity, buff_uri)
   return true
end

function Commands:remove_buff_command(session, response, entity, buff_name)
   if entity and entity:is_valid() then
      local buff_component = entity:get_component('stonehearth:buffs')
      if buff_component then
         buff_component:remove_buff(buff_name, true) -- True for removing all refs for the buff
         return true
      end
   end
   return false
end

function Commands:promote_to_command(session, response, entity, job)
   if not string.find(job, ':') and not string.find(job, '/') then
      -- as a convenience for autotest writers, stick the stonehearth:job on
      -- there if they didn't put it there to begin with
      job = 'stonehearth:jobs:' .. job
   end
   
   radiant.entities.drop_carrying_on_ground(entity)
   entity:get_component('stonehearth:job')
         :promote_to(job)
   return true
end

function Commands:add_citizen_command(session, response, entity, job)
   local player_id = session.player_id
   local pop = stonehearth.population:get_population(player_id)
   local citizen = pop:create_new_citizen()

   citizen:add_component('stonehearth:job')
               :promote_to('stonehearth:jobs:worker')

   local explored_region = stonehearth.terrain:get_visible_region(player_id):get()
   local centroid = _radiant.csg.get_region_centroid(explored_region):to_closest_int()
   local town_center = radiant.terrain.get_point_on_terrain(Point3(centroid.x, 0, centroid.y))

   local spawn_point = radiant.terrain.find_placement_point(town_center, 20, 30)
   radiant.terrain.place_entity(citizen, spawn_point)

   return true
end

function Commands:add_gold_console_command(session, response, gold_amount)
   local inventory = stonehearth.inventory:get_inventory(session.player_id)

   if inventory == nil then
      response:reject('there is no inventory for player ' .. session.player_id)
      return
   end

   if (gold_amount > 0) then
      -- give gold to the player
      inventory:add_gold(gold_amount)
   else
      -- deduct gold from the player
      gold_amount = -gold_amount;
      inventory:subtract_gold(gold_amount)
   end
   response:resolve({'added gold chests next to town banner'})
end

function Commands:dump_backpack_command(session, response, entity)
   local storage = entity:get_component('stonehearth:storage')

   if not storage then
      return false
   end

   storage:_on_kill_event()
   return true
end

function Commands:hot_reload_server(session, response, entity)
   radiant.resources.reset()
   return true
end

function Commands:hot_reload_client(session, response, entity)
   radiant.resources.reset()
   return true
end

function Commands:add_journal_command(session, response, entity, journalType)
   if journalType then
      local substitution_values = {}
      substitution_values['gather_target'] = 'i18n(stonehearth:entities.food.berries.berry_basket.display_name)'
      local score_metadata = {score_name = 'debug', score_mod = 1}
      local journal_data = {entity = entity, description = journalType, probability_override = 100, substitutions = substitution_values}
      stonehearth.personality:log_journal_entry(journal_data, score_metadata)
      response:resolve({})
   else
      local activity_logs = stonehearth.personality._activity_logs
      local available_activities = {}
      for activity_name, _ in pairs(activity_logs) do
         table.insert(available_activities, activity_name)
      end
      response:resolve({error='must specify journal type', available_activities = available_activities})
   end
end

function Commands:pasture_reproduce_command(session, response, entity)
   local pasture = entity:get_component('stonehearth:shepherd_pasture')

   if not pasture then
      return false
   end

   return pasture:_reproduce()
end

function Commands:renew_resource_command(session, response, entity)
   local renewable_resource_component = entity:get_component('stonehearth:renewable_resource_node')

   if not renewable_resource_component then
      return false
   end

   renewable_resource_component:renew()
   return true
end

function Commands:grow_command(session, response, entity)
   local evolve_component = entity:get_component('stonehearth:evolve')
   if evolve_component then
      evolve_component:evolve()
      return true
   end
   
   local growing_component = entity:get_component('stonehearth:growing')
   if growing_component then
      growing_component:_grow()
      return true
   end

   return false
end

function Commands:get_all_item_uris_command(session, response)
   local all_uris = {}
   local mods = radiant.resources.get_mod_list()
   -- for each mod
   for i, mod in ipairs(mods) do
      local manifest = radiant.resources.load_manifest(mod)
      -- for each alias
      if manifest.aliases then
         for alias, _ in pairs(manifest.aliases) do
            -- is it sellable?
            local full_alias = mod .. ':' .. alias
            table.insert(all_uris, full_alias)
         end
      end
   end
   return all_uris
end

function Commands:decay_command(session, response, entity)
   local decay_tuning = radiant.entities.get_entity_data(entity, 'stonehearth:food_decay')
   if not decay_tuning then
      return false
   end
   local decay = radiant.entities.get_attribute(entity, 'decay')
   local largest_trigger_value = 0

   for _, decay_stage in pairs(decay_tuning.decay_stages) do
      -- Find the next decay stage
      if decay > decay_stage.trigger_decay_value and decay_stage.trigger_decay_value > largest_trigger_value then
         largest_trigger_value = decay_stage.trigger_decay_value
      end
   end

   radiant.entities.set_attribute(entity, 'decay', largest_trigger_value)


   return stonehearth.food_decay:increment_decay(entity)
end

function Commands:start_game_master_command(session, response, entity)
   stonehearth.game_master:start()
   return true
end

function Commands:get_mod_controller_command(session, response, mod_name)
   local mod_data = _G[mod_name]
   if mod_data then
      response:resolve({mod_uri=mod_data.__saved_variables})
   end
   response:resolve({})
end

function Commands:get_all_data(session, response, game_object)
   local data = {}
   if not game_object then
      response:reject('unknown game object')
      return
   end
   if type(game_object.get_data) == 'function' then
      data = game_object:get_data()
   elseif type(game_object.__saved_variables) == 'userdata' then
      -- non-SvTable controllers, will just have a __saved_variables block shoved
      -- in there.  Grab that one's data.
      data = game_object.__saved_variables:get_data()
   else
      response:reject('could not find get_data method on ' .. tostring(game_object))
      return
   end
   response:resolve(data)
end

function Commands:call_component_function_command(session, response, entity, component_name, function_name, ...)
   if not entity then
      response:reject('unknown entity')
      return
   end

   local component = entity:get_component(component_name)
   if not component then
      response:reject('no component '..component_name..' on entity.')
      return
   end

   local function_ptr = component[function_name]
   if not function_ptr or type(function_ptr) ~= 'function' then
      response:reject(function_name..' is not a function')
      return
   end

   local data = function_ptr(component, ...)

   response:resolve(data)
end

function Commands:ai_reconsider_entity_command(session, response, entity)
   stonehearth.ai:reconsider_entity(entity, 'debugtools reconsider')

   return true
end

function Commands:fill_storage_command(session, response, entity, uri)
   if not entity then
      response:reject('unknown entity')
      return
   end

   local storage_component = entity:get_component('stonehearth:storage')
   if not storage_component then
      response:reject('entity is not storage')
      return
   end

   local add_to_storage = function(storage, item_uri)
      local item = radiant.entities.create_entity(item_uri, {owner = entity})
      local root, iconic = entity_forms_lib.get_forms(item)
      if iconic then
         storage:add_item(iconic)
      else
         storage:add_item(item)
      end
   end

   local num = storage_component:get_capacity() - storage_component:get_num_items()

   for i=1, num do
      add_to_storage(storage_component, uri)
   end

   return true
end

function Commands:set_ai_log_override_command(session, response, level, entity)
   if entity and entity:is_valid() then
      if level > 1 then
         _radiant.ai.set_entity_log_level_override(entity:get_id())
      else
         _radiant.ai.set_entity_log_level_override(0) -- if no entity, clear out the entity ID stuff.
      end
   else
      _radiant.ai.set_entity_log_level_override(0) -- if no entity, clear out the entity ID stuff.
      _radiant.ai.set_log_level_override(level)
   end
   response:resolve({level = level})
end

function Commands:get_gamestate_now_command(session, response)
   local now = radiant.gamestate.now()
   response:resolve({now = now})
end

function Commands:spawn_encounter_command(session, response, campaign_name, encounter_name, arc, args)
   local options = {
      campaign_name = campaign_name,
      edge_name = encounter_name,
      arc = arc,
      override_info = args
   }

   stonehearth.game_master:set_ignore_start_requirements(true)
   self:_trigger_campaign_encounter(options)
   stonehearth.game_master:set_ignore_start_requirements(false)
   response:resolve({})

end

function Commands:fixup_components_command(session, response, entity)
   if not entity then
      response:reject('unknown entity')
      return
   end
   local uri = entity:get_uri()
   local json = radiant.resources.load_json(uri)
   if not json then
      response:reject('uri '..uri..' has no json')
      return
   end

   local components = json.components or {}
   local added_components = {}
   for component_name, _ in pairs(components) do
      if not entity:get_component(component_name) then
         entity:add_component(component_name)
         table.insert(added_components, component_name)
      end
   end

   response:resolve({added_components = added_components})
end

-- Yuck, move this to a file that can be shared so it is not copy pasted everywhere.
function Commands:_trigger_campaign_encounter(options)
   assert(options.edge_name) -- the name of the in_edge of the desired encounter

   if not self._campaign_started or options.campaign_name ~= self._campaign_name then
      self._gm_index = radiant.resources.load_json('stonehearth:data:gm_index')
      assert(options.campaign_name, 'campaign_name not specified in options!')

      local enc_arc
      local enc_node
      local function get_to_the_challenge(...)
         local args = {...}
         local event_name = args[1]
         if event_name == 'elect_node' then
            local _, nodelist_name, nodes = unpack(args)
            if nodelist_name == options.campaign_name then
               local mod_campaign_map = self._gm_index.campaigns[options.campaign_name]
               local mod_campaign_name, _ = next(mod_campaign_map)
               radiant.assert(mod_campaign_name, 'campaign %s not found in gm_index!', options.campaign_name)
               return mod_campaign_name, nodes[mod_campaign_name]
            end
         elseif event_name == 'override_campaign_arc' then
            local _, campaign, target_arc_type, data = unpack(args)
            if target_arc_type == 'trigger' then
               return options.arc or 'trigger'
            end
         elseif event_name == 'trigger_arc_edge' then
            local _, arc, edge_name, parent_node = unpack(args)
            if edge_name == 'start' then
               --Jump directly to spawning the wolf cage encounter
               local encounter_uri = arc._sv.encounters._sv.nodelist[options.edge_name]
               if not encounter_uri then
                  return
               end
               local encounter = radiant.create_controller('stonehearth:game_master:encounter', encounter_uri)
               enc_arc = arc
               enc_node = encounter
               return options.edge_name, encounter
            end
         end
      end

      stonehearth.game_master:debug_campaign(options.campaign_name, function(...)
         local result = { get_to_the_challenge(...) }
         if #result > 0 then
            return unpack(result)
         end
      end, options.override_info)

      self._campaign_started = true
      self._campaign_name = options.campaign_name
      self._enc_arc = enc_arc
      self._enc_node = enc_node
   else
      stonehearth.game_master:debug_trigger_encounter(self._enc_arc,
                                                      options.edge_name,
                                                      self._enc_node,
                                                      options.override_info)
   end
end

return Commands