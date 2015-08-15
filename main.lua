local notification_queue = {}

local game_info = ""

-- this is for the client
local line = {}
local text = nil
local users = {}
local mouses = setmetatable({}, {__mode = "k"})

-- this is for the server
local buffer = {}
local peers = {}
local peer_mouses = setmetatable({}, {__mode = "k"})

local current_color = {255, 255, 255}
local current_width = 2
local current_size = 11

local function has_arg(name) for _, v in pairs(arg) do if v == name then return true end end return false end

local headless = has_arg("--headless")
local hosting = has_arg("--hosting")
local canvas, big_font, font, small_font, fonts

local colorpicker

if not headless then
  local w, h = 800, 600
  colorpicker = require("colorpicker")
  colorpicker:create(w / 2 - 200, h / 2 - 200, 200)
  -- graphics stuff
  canvas = love.graphics.newCanvas()
  canvas:renderTo(function()
    love.graphics.clear()
    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("fill", 0, 0, canvas:getWidth(), canvas:getHeight())
  end)

  big_font = love.graphics.newFont(22)
  font = love.graphics.newFont(11)
  small_font = love.graphics.newFont(10)
  font:setLineHeight(1.3)

  fonts = {}

  setmetatable(fonts, {
    __index = function(t, k)
      local font = rawget(t, k)
      if not font then
        font = love.graphics.newFont(k)
        rawset(t, k, font)
      end

      return font
    end
  })
end

-- rules
local rules = {}
local server_rules = {
  ["send mouse position"] = "yes"
}

-- networking stuff
require("enet")

local server, client_host
local server_host

local draw_button = love._version_minor >= 10 and 1 or "l"

-- serialization stuff
local cdata = require("cdata")
local ffi = require("ffi")
local packets = {}

-- all structs get a type field so we don't lose our minds.
function add_struct(name, fields, map)
  local struct = string.format("typedef struct { uint8_t type; %s } %s;", fields, name)
  cdata:new_struct(name, struct)

  -- the packet_type struct isn't a real packet, so don't index it.
  if map then
    map.name = name
    table.insert(packets, map)
    packets[name] = #packets
  end
end

add_struct("packet_type", "")

-- this one is sent to the server and to the clients
add_struct(
  "draw_line", [[
    uint8_t r, g, b;
    uint8_t width;
    uint16_t x1, y1, x2, y2;
  ]], {
    "r", "g", "b",
    "x1", "y1", "x2", "y2"
  }
)
add_struct(
  "draw_text", [[
    uint8_t r, g, b;
    uint8_t size;
    uint16_t x, y;
    unsigned char text[160];
  ]], {
    "r", "g", "b",
    "x", "y",
    "text"
  }
)
add_struct(
  "user_list", [[
    uint8_t count;
    unsigned char names[32][12];
  ]], {
    "count",
    "names"
  }
)
add_struct(
  "notification", [[
    unsigned char text[256];
    uint8_t r, g, b;
    uint8_t time;
  ]], {
    "text", 
    "r, g, b",
    "time"
  }
)
add_struct(
  "rpc", [[
    unsigned char command[32];
    unsigned char args[512];
  ]], {
    "command",
    "args"
  }
)
add_struct(
  "mouse_move", [[
    uint8_t id;
    uint16_t x, y;
  ]], {
    "id",
    "x", "y"
  }
)
add_struct(
  "mouse_add", [[
    uint8_t id;
    uint8_t width;
    uint8_t r, g, b;
  ]], {
    "id",
    "width",
    "x", "y"
  }
)
add_struct(
  "mouse_remove", [[
    uint8_t id;
  ]], {
    "id"
  }
)
add_struct(
  "set_text", [[
    uint8_t id;
    uint8_t size;
    unsigned char text[160];
    bool input;
  ]], {
    "id",
    "size",
    "text",
    "input"
  }
)

-- utf8 support
local utf8 = require("unicode")

function love.load()
  io.stdout:setvbuf("no")

  -- check if version >0.9.2
  if not headless and love._version_minor == 9 and love._version_revision < 2 then
    error("You need at least LOVE 0.9.2 to draw dicks.")
    return
  end

  -- line defaults
  if not headless then
    love.graphics.setLineStyle("smooth")
    love.graphics.setLineJoin("miter")

    -- repeat because text inputs
    love.keyboard.setKeyRepeat(true)
  end

  -- try to set up a server
  if hosting then
    -- max 10kib dl
    server_host = enet.host_create("0.0.0.0:9292", 32, 1)

    if not server_host then
      io.stderr:write("Could not set up the server\n")
      hosting = false
    end
  end

  -- connect
  if not headless then
    client_host = enet.host_create()
    server = client_host:connect(hosting and "localhost:9292" or "unek.xyz:9292")
  end

  -- feed the randomizer machine with some seeds
  math.randomseed(love.timer.getTime())

  -- game info, press tab to preview
  game_info = [[dick around with your friends!

  instructions:
  - hold right mouse to change color,
  - hold left mouse button to draw,
  - press middle mouse button to pick a color from the canvas,
  - scroll to change width/text size,
  - press enter to type and enter/lmb to place the text,
  - press S to screenshot,
  - press red X to close.]]
  if hosting then
    game_info = game_info .. [[


    server host instructions:
    - press f1 to clear the canvas.]]
  end

  game_info = game_info .. [[


  thanks to:
  - excessive (karai + holo supergroup) for his awesome cdata lib,
  - alexar for his colorpicker lib,
  - nix for being a cool guy,
  - penis painters who crashed or lagged my server over and over.]]
end

local function log(str, ...)
  print("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. str:format(...))
end

local function push_notification(text, time, color)
  table.insert(notification_queue, {
    text = text,
    spawn_time = love.timer.getTime(),
    time = time or 5,
    color = color or {0, 0, 0}
  })

  if love._version_minor >= 10 then
    love.window.requestAttention()
  end
end

-- snatched from https://github.com/phyber/Snippets/blob/master/Lua/base36.lua
local alphabet = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"
}

local function base36(num)
  -- Special case for numbers less than 36
  if num < 36 then
    return alphabet[num + 1]
  end

  -- Process large numbers now
  local result = ""
  while num ~= 0 do
    local i = num % 36
    result = alphabet[i + 1] .. result
    num = math.floor(num / 36)
  end
  return result
end

-- i think it works right
local function ip2long(ip)
  local ip = tostring(ip)
  local p1, p2, p3, p4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)")

  local n = p1 * 256 ^ 3 + p2 * 256 ^ 2, p3 * 256 ^ 1, p4 * 256 ^ 0

  return n
end

local function friendly_name(ip)
  return base36(ip2long(ip))
end

local function serialize_notification(text, time, color)
  local r, g, b = unpack(color or {80, 80, 80})

  local struct = cdata:set_struct("notification", {
    type = packets.notification,
    text = text,
    r = r, g = g, b = b,
    time = time or 3
  })

  return cdata:encode(struct)
end

local function deserialize_notification(packet)
  local decoded = cdata:decode("notification", packet)

  return ffi.string(decoded.text), decoded.time, {decoded.r, decoded.g, decoded.b}
end

local function serialize_user_list(peers)
  local users = {}
  for _, peer in ipairs(peers) do
    table.insert(users, friendly_name(peer))
  end

  local struct = cdata:set_struct("user_list", {
    type = packets.user_list,
    count = #users,
    names = users
  })

  return cdata:encode(struct)
end

local function deserialize_user_list(packet)
  local decoded = cdata:decode("user_list", packet)
  local users = {}
  for i = 0, decoded.count - 1 do
    local name = decoded.names[i]

    table.insert(users, ffi.string(name))
  end

  return users
end

local function serialize_line(line)
  local r, g, b = unpack(line.color or current_color)
  local width = line.width or current_width
  local x1, y1, x2, y2 = unpack(line)

  local struct = cdata:set_struct("draw_line", {
    type = packets.draw_line,
    r = r, g = g, b = b,
    width = width,
    x1 = x1, y1 = y1, x2 = x2 or x1, y2 = y2 or y1
  })

  return cdata:encode(struct)
end

local function deserialize_line(packet)
  local decoded = cdata:decode("draw_line", packet)

  return {
    color = {decoded.r, decoded.g, decoded.b},
    width = math.min(16, math.max(1, decoded.width)),
    decoded.x1, decoded.y1, decoded.x2, decoded.y2
  }
end

local function serialize_text(text)
  local r, g, b = unpack(text.color or current_color)

  local struct = cdata:set_struct("draw_text", {
    type = packets.draw_text,
    r = r, g = g, b = b,
    size = text.size,
    x = text.x, y = text.y,
    text = text.text
  })

  return cdata:encode(struct)
end

local function deserialize_text(packet)
  local decoded = cdata:decode("draw_text", packet)

  return {
    color = {decoded.r, decoded.g, decoded.b},
    size = decoded.size,
    x = decoded.x, y = decoded.y,
    text = ffi.string(decoded.text)
  }
end

local function serialize_rpc(command, ...)
  local args = table.concat({...}, string.char(3)) .. string.char(3)

  local struct = cdata:set_struct("rpc", {
    type = packets.rpc,
    command = command,
    args = args
  })

  return cdata:encode(struct)
end

local function deserialize_rpc(packet)
  local decoded = cdata:decode("rpc", packet)

  local args = {}
  for data in ffi.string(decoded.args):gmatch("(.-)" .. string.char(3)) do
    table.insert(args, data)
  end

  return ffi.string(decoded.command), unpack(args)
end

local function serialize_mouse_move(id, x, y)
  local struct = cdata:set_struct("mouse_move", {
    type = packets.mouse_move,
    id = id or 0,
    x = x, y = y
  })

  return cdata:encode(struct)
end

local function deserialize_mouse_move(packet)
  local decoded = cdata:decode("mouse_move", packet)

  return decoded.id, decoded.x or 0, decoded.y or 0
end

local function serialize_mouse_add(id, width, color)
  local r, g, b = unpack(color)
  local struct = cdata:set_struct("mouse_add", {
    type = packets.mouse_add,
    id = id,
    width = width,
    r = r, g = g, b = b
  })

  return cdata:encode(struct)
end

local function deserialize_mouse_add(packet)
  local decoded = cdata:decode("mouse_add", packet)

  return decoded.id, decoded.width or 2, {decoded.r, decoded.g, decoded.b}
end

local function serialize_mouse_remove(id)
  local struct = cdata:set_struct("mouse_remove", {
    type = packets.mouse_remove,
    id = id or 0
  })

  return cdata:encode(struct)
end

local function deserialize_mouse_remove(packet)
  local decoded = cdata:decode("mouse_remove", packet)

  return decoded.id
end

local function serialize_set_text(id, size, text, input)
  local struct = cdata:set_struct("set_text", {
    type = packets.set_text,
    id = id or 0,
    size = size,
    text = text or "",
    input = input == nil and text ~= nil or input
  })

  return cdata:encode(struct)
end

local function deserialize_set_text(packet)
  local decoded = cdata:decode("set_text", packet)

  return decoded.id, decoded.size, ffi.string(decoded.text), decoded.input
end

local function send_data(data)
  server:send(data)
end

local function broadcast_data(data)
  server_host:broadcast(data)
end

local function broadcast_notification(text, time, color)
  broadcast_data(serialize_notification(text, time, color))
end

local function send_rpc(command, ...)
  send_data(serialize_rpc(command, ...))
end

local function broadcast_rpc(command, ...)
  broadcast_data(serialize_rpc(command, ...))
end

local function clear()
  broadcast_rpc("clear")
  buffer = {}
end

local function place_text(t, x, y)
  -- send to server
  send_data(serialize_text({
    color = current_color,
    x = x, y = y,
    size = current_size,
    text = t
  }))

  -- reset input
  text = nil
  send_data(serialize_set_text(nil, current_size, text))

  -- bring back mouse
  love.mouse.setVisible(true)
end

-- dispatch table for the received commands
local commands = {
  draw_line = function(data)
    if not love.mouse.isDown(draw_button) then
      -- reset
      line = {}
    end

    local line = deserialize_line(data)

    if line and #line > 0 and #line < 10001 then
      canvas:renderTo(function()
        love.graphics.setColor(line.color)
        love.graphics.setLineWidth(line.width or 0)

        if #line > 3 then
          love.graphics.line(line)
          love.graphics.circle("fill", line[1], line[2], line.width / 2)
          love.graphics.circle("fill", line[3], line[4], line.width / 2)
        elseif #line > 1 then
          love.graphics.circle("fill", line[1], line[2], line.width / 2)
        end
      end)
    end
  end,
  draw_text = function(data)
    local text = deserialize_text(data)

    canvas:renderTo(function()
      love.graphics.setColor(text.color)
      love.graphics.setFont(fonts[text.size or 11])
      love.graphics.print(text.text, text.x, text.y)
    end)
  end,
  notification = function(data)
    local text, time, color = deserialize_notification(data)

    push_notification(text, time, color)
  end,
  user_list = function(data)
    users = deserialize_user_list(data)
  end,
  rpc = function(data)
    args = {deserialize_rpc(data)}
    local command = args[1]
    table.remove(args, 1)

    if command == "clear" then
      canvas:renderTo(function()
        love.graphics.clear()
        love.graphics.setColor(0, 0, 0)
        love.graphics.rectangle("fill", 0, 0, canvas:getWidth(), canvas:getHeight())
      end)
    elseif command == "rule" then
      local rule = args[1]
      local value = args[2]

      if tonumber(value) then
        value = tonumber(value)
      end

      rules[rule] = value

      if rule == "send mouse position" then
        if value == "yes" then
          send_data(serialize_mouse_add(nil, current_width, current_color))
        elseif value == "no" then
          mouses = {}
        end
      end
    end
  end,
  mouse_move = function(data)
    local id, x, y = deserialize_mouse_move(data)

    if not mouses[id] then
      mouses[id] = {
        x = x,
        y = y,
        width = 2,
        color = {255, 255, 255},
        text = nil,
        text_size = 11
      }
    else
      mouses[id].x, mouses[id].y = x, y
    end
  end,
  mouse_add = function(data)
    local id, width, color = deserialize_mouse_add(data)

    if not mouses[id] then
      mouses[id] = {
        x = 0,
        y = 0,
        width = width,
        color = color,
        text = nil,
        text_size = 11
      }
    else
      mouses[id].color = color
      mouses[id].width = width
    end
  end,
  mouse_remove = function(data)
    local id = deserialize_mouse_remove(data)

    mouses[id] = nil
  end,
  set_text = function(data)
    local id, size, text, input = deserialize_set_text(data)

    if not input then text = nil end

    if not mouses[id] then
      mouses[id] = {
        x = 0,
        y = 0,
        width = 2,
        color = {255, 255, 255},
        text = text,
        text_size = size
      }
    else
      mouses[id].text = text
      mouses[id].text_size = size
    end
  end
}

local function is_admin(peer)
  return not not (tostring(peer):match("^88%.156") or tostring(peer):match("^127%.0%.0%.1") or tostring(peer):match("^2%.237%."))
end

counter = 0
local server_commands = {
  draw_line = function(data)
    local line = deserialize_line(data)

    if line then
      local serialized = serialize_line(line)
      broadcast_data(serialized, true)

      table.insert(buffer, serialized)
    end
  end,
  draw_text = function(data)
    local text = deserialize_text(data)

    if text then
      local serialized = serialize_text(text)
      broadcast_data(serialized, true)

      table.insert(buffer, serialized)
    end
  end,
  rpc = function(data, peer)
    args = {deserialize_rpc(data)}
    local command = args[1]
    table.remove(args, 1)

    if not is_admin(peer) then return end

    if command == "clear" then
      clear()

      broadcast_notification(friendly_name(peer) .. " cleared the canvas.", 2, {120, 0, 0})
    elseif command == "save" then
      local filename = string.format("%s-buffer.txt", os.date("%Y-%m-%d_%H-%M-%S"))

      love.filesystem.write(filename, table.concat(buffer, "\n"))

      broadcast_notification(friendly_name(peer) .. " saved the canvas.", 2, {120, 0, 0})
    elseif command == "rule" then
      local rule = args[1]
      local value = args[2]

      if tonumber(value) then
        value = tonumber(value)
      end

      server_rules[rule] = value

      broadcast_rpc("rule", rule, value)

      broadcast_notification(friendly_name(peer) .. " changed rule " .. rule .. " to " .. value .. ".", 3, {0, 120, 0})
    end
  end,
  mouse_move = function(data, peer)
    if server_rules["send mouse position"] ~= "yes" then return end

    local id = peer_mouses[peer]
    if not id then return end

    local _, x, y = deserialize_mouse_move(data)

    if data then
      broadcast_data(serialize_mouse_move(id, x, y))
    end
  end,
  mouse_add = function(data, peer)
    if server_rules["send mouse position"] ~= "yes" then return end

    local id = peer_mouses[peer]

    if not id then
      -- increase counter
      counter = counter + 1
      -- set the id to the new value
      id = counter
      -- assign the id to client's mouse
      peer_mouses[peer] = id
    end

    local _, width, color = deserialize_mouse_add(data)

    broadcast_data(serialize_mouse_add(id, width, color))
  end,
  mouse_remove = function(data, peer)
    if server_rules["send mouse position"] ~= "yes" then return end

    local id = peer_mouses[peer]
    if not id then return end

    broadcast_data(serialize_mouse_remove(id))
  end,
  set_text = function(data, peer)
    if server_rules["send mouse position"] ~= "yes" then return end

    local id = peer_mouses[peer]
    if not id then return end

    local _, size, text, input = deserialize_set_text(data)

    broadcast_data(serialize_set_text(id, size, text, input))
  end
}

local function receive_data(data, peer, serverside)
  local commands = serverside and server_commands or commands

  local header = cdata:decode("packet_type", data)
  -- half-assed check against incorrect stuff
  if not header or not header.type then return end

  local map = packets[header.type]

  if not map then
    log("Invalid command received from %s (type %s)", tostring(peer), header.type)
    return false
  end

  local decoded = cdata:decode(map.name, data)

  pcall(commands[map.name], decoded, peer)

  return true
end

function love.draw()
  local w, h = love.graphics.getDimensions()

  -- painted shit
  love.graphics.setColor(255, 255, 255)
  if love._version_minor >= 10 then
    love.graphics.setBlendMode("alpha", false)
  else
    love.graphics.setBlendMode("premultiplied")
  end

  love.graphics.draw(canvas)
  love.graphics.setBlendMode("alpha")

  love.graphics.setColor(current_color)
  local mx, my = love.mouse.getPosition()

  -- unpainted shit
  if not text then
    if #line > 3 then
      love.graphics.line(line)
    elseif #line > 1 then
      love.graphics.circle("fill", line[1], line[2], current_width / 2)
    end

    if rules["send mouse position"] ~= "yes" then
      love.graphics.setLineWidth(1)
      love.graphics.circle("line", mx, my, current_width / 2)
    end
  else
    if rules["send mouse position"] ~= "yes" then
      local font = fonts[current_size]
      love.graphics.setFont(font)
      love.graphics.print(text, mx, my)

      love.graphics.setColor(255, 255, 255)
      love.graphics.setFont(small_font)

      local length = utf8.len(text)
      love.graphics.print(string.format("%d char%s left", 80 - length, 80 - length == 1 and "" or "s"), mx, my - small_font:getHeight())

      love.graphics.rectangle("fill", mx + font:getWidth(text), my, 1, font:getHeight())
    end
  end

  -- draw cursors
  if rules["send mouse position"] == "yes" then
    for id, mouse in pairs(mouses) do
      love.graphics.setColor(mouse.color)
      love.graphics.setLineWidth(1)
      if not mouse.text then
        love.graphics.circle("line", mouse.x, mouse.y, mouse.width / 2)
      else
        local text, mx, my = mouse.text, mouse.x, mouse.y
        local font = fonts[mouse.text_size]
        love.graphics.setFont(font)
        love.graphics.print(text, mx, my)

        love.graphics.setColor(255, 255, 255)
        love.graphics.setFont(small_font)

        local length = utf8.len(text)
        love.graphics.print(string.format("%d char%s left", 80 - length, 80 - length == 1 and "" or "s"), mx, my - small_font:getHeight())

        love.graphics.rectangle("fill", mx + font:getWidth(text), my, 1, font:getHeight())
      end
    end
  end

  -- notifications
  local t = love.timer.getTime()

  local th = font:getHeight() * font:getLineHeight()
  local spacing = 10
  love.graphics.setFont(font)
  for i, notification in ipairs(notification_queue) do
    local tw = font:getWidth(notification.text)
    local tx, ty = w - 10 - tw, 5 + (i - 1) * (th + spacing)
    local a = 1 - ((t - notification.spawn_time) / notification.time)

    local r, g, b = unpack(notification.color)
    love.graphics.setColor(r, g, b, 120)
    love.graphics.rectangle("fill", tx - 8, ty - 2, tw + 16, th + 2)

    love.graphics.setColor(255, 255, 255)
    love.graphics.print(notification.text, tx, ty)

    love.graphics.rectangle("fill", tx + tw, ty + th - 3, -tw * a, 1)
  end

  if love.keyboard.isDown("tab") then
    local r, g, b = unpack(current_color)
    love.graphics.setColor(r, g, b, 80)
    love.graphics.rectangle("fill", 0, 0, 200, h)

    love.graphics.setFont(big_font)
    love.graphics.setColor(0, 0, 0)
    love.graphics.print("PENISDRAW", (200 - big_font:getWidth("PENISDRAW")) / 2 + 1, 5 + 1)
    love.graphics.setColor(255, 255, 255)
    love.graphics.print("PENISDRAW", (200 - big_font:getWidth("PENISDRAW")) / 2, 5)

    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("fill", 5 + 1, big_font:getHeight() + 5 + 1, 190, 1)
    love.graphics.setColor(255, 255, 255)
    love.graphics.rectangle("fill", 5, big_font:getHeight() + 5, 190, 1)

    love.graphics.setFont(small_font)

    local bandwidth = (client_host:total_sent_data() + client_host:total_received_data() + (hosting and (server_host:total_sent_data() + server_host:total_received_data()) or 0)) / 1024
    local rule_list = {}
    for rule, value in pairs(rules) do
      table.insert(rule_list, "- " .. rule .. ": " .. value)
    end
    rule_list = table.concat(rule_list, "\n")

    local text = ("%s\n\nusers online (%d):\n- %s\n\nserver rules:\n%s\n\nnetwork info:\n- bandwidth used: %.2f kib\n- ping: %d ms\n- fps: %d"):format(game_info, #users, table.concat(users, ",\n- "), rule_list, bandwidth, server:round_trip_time(), love.timer.getFPS())

    love.graphics.setColor(0, 0, 0)
    love.graphics.printf(text, 5 + 1, 5 + 1 + big_font:getHeight() + 5, 190)

    love.graphics.setColor(255, 255, 255)
    love.graphics.printf(text, 5, 5 + big_font:getHeight() + 5, 190)
  end

  -- draw something if unconnected
  local state = server:state()
  if state ~= "connected" then
    love.graphics.setColor(255, 0, 0, 80)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(255, 255, 255, 180 + math.sin(love.timer.getTime() * 3) * 75)
    love.graphics.print(state, (w - font:getWidth(state)) / 2, (h - th) / 2)
  end

  -- colordicker
  if love.mouse.isDown(love._version_minor >= 10 and 2 or "r") then
    love.graphics.setColor(0, 0, 0, 160)
    love.graphics.rectangle("fill", 0, 0, w, h)

    colorpicker:draw()
  end
end

function love.update(dt)
  -- notifications
  if not headless then
    local t = love.timer.getTime()
    for i = #notification_queue, 1, -1 do
      local notification = notification_queue[i]

      if notification.spawn_time + notification.time < t then
        table.remove(notification_queue, i)
      end
    end
  end

  -- colorpicker
  if love.mouse.isDown(love._version_minor >= 10 and 2 or "r") then
    colorpicker:update(dt)
    current_color = colorpicker.sc
  end

  -- server update
  if hosting then
    while true do
      local event = server_host:service()
      if not event then break end

      if event.type == "receive" then
        receive_data(event.data, event.peer, true)
      elseif event.type == "connect" then
        log("%s (%s) joined the paint.", tostring(event.peer), friendly_name(event.peer))
        broadcast_notification(string.format("%s joined the paint.", friendly_name(event.peer)))

        -- into the peer table
        table.insert(peers, event.peer)
        log("%d users online.", #peers)

        -- send him the lines and texts
        for _, line in ipairs(buffer) do
          event.peer:send(line)
        end
        for rule, value in pairs(server_rules) do
          event.peer:send(serialize_rpc("rule", rule, value))
        end

        -- send the new userlist to everyone
        broadcast_data(serialize_user_list(peers))
      elseif event.type == "disconnect" then
        log("%s (%s) left the paint.", tostring(event.peer), friendly_name(event.peer))
        broadcast_notification(string.format("%s lefted the paint.", friendly_name(event.peer)))

        -- remove the mouse
        if server_rules["send mouse position"] == "yes" then
          broadcast_data(serialize_mouse_remove(peer_mouses[peer]))
        end

        -- remove from the peer table
        for i = #peers, 1, -1 do
          if peers[i] == event.peer then
            table.remove(peers, i)
          end
        end
        log("%d users online.", #peers)
        -- resend the userlist
        broadcast_data(serialize_user_list(peers))
      end
    end
  end

  -- client update
  if not headless then
    while true do
      local event = client_host:service()
      if not event then break end

      if event.type == "receive" then
        receive_data(event.data, event.peer)
      elseif event.type == "connect" then
        push_notification("hold tab for help.", 8, {255, 0, 0})
      end
    end
  end
end

if not headless then
  function love.mousemoved(x, y, dx, dy)
    if love.mouse.isDown(draw_button) then
      table.insert(line, x)
      table.insert(line, y)

      send_data(serialize_line(line))

      line = {x, y}
    end

    if rules["send mouse position"] == "yes" then
      send_data(serialize_mouse_move(0, x, y))
    end
  end

  function love.mousepressed(x, y, btn)
    if btn == draw_button and not text then
      line = {x, y}
    elseif btn == draw_button and text then
      -- place text
      place_text(text, x, y)
    elseif btn == "wu" or btn == "wd" then
      love.wheelmoved(0, btn == "wu" and 1 or -1)
    elseif btn == "r" or btn == 2 then
      colorpicker:create(x - 200, y - 200, 200)
    end
  end

  function love.mousereleased(x, y, btn)
    if btn == draw_button and not text and #line > 1 then
      -- send line
      send_data(serialize_line(line))
    elseif btn == "r" or btn == 2 then
      send_data(serialize_mouse_add(nil, current_width, current_color))
    elseif btn == "m" or btn == 3 then
      local r, g, b
      if love._version_minor >= 10 then
        r, g, b = canvas:newImageData():getPixel(x, y)
      else
        r, g, b = canvas:getPixel(x, y)
      end
      current_color = {r, g, b}

      send_data(serialize_mouse_add(nil, current_width, current_color))
    end
  end

  function love.keypressed(key, is_repeat, blah)
    if love._version_minor >= 10 then
      is_repeat = blah
    end

    if text then
      if key == "backspace" then
        text = utf8.sub(text, 1, utf8.len(text) - 1)
        send_data(serialize_set_text(nil, current_size, text))
      end
      if key == "return" and not is_repeat then
        place_text(text, love.mouse.getPosition())
      end
      if key == "escape" then
        text = nil
        send_data(serialize_set_text(nil, current_size, text))
        
        love.mouse.setVisible(true)
      end
    else
      if key == "s" and not is_repeat then
        local filename = string.format("%s-drawing.png", os.date("%Y-%m-%d_%H-%M-%S"))
        if love._version_minor >= 10 then
          canvas:newImageData():encode("png", filename)
        else
          canvas:getImageData():encode(filename)
        end
        push_notification("screenshot saved.", 3, {255, 255, 0})
      end
      if key == "return" and not is_repeat then
        text = ""
        send_data(serialize_set_text(nil, current_size, text))

        love.mouse.setVisible(false)
      end

      -- admin commands
      if not is_repeat then
        if key == "f1" then
          send_rpc("clear")
        elseif key == "f2" then
          send_rpc("save")
        elseif key == "f3" then
          send_rpc("rule", "send mouse position", rules["send mouse position"] == "yes" and "no" or "yes")
        end
      end
    end
  end

  function love.textinput(t)
    if not text then return end

    local t = t:gsub("[\r\n]", "")
    text = utf8.sub(text .. t, 1, 80)

    if rules["send mouse position"] == "yes" then
      send_data(serialize_set_text(nil, current_size, text))
    end
  end
end

function love.wheelmoved(x, y)
  if not text then
    local original_width = current_width
    current_width = math.min(16, math.max(1, current_width + y))

    if rules["send mouse position"] == "yes" and original_width ~= current_width then
      send_data(serialize_mouse_add(nil, current_width, current_color))
    end
  else
    current_size = math.min(32, math.max(9, current_size + y))
    send_data(serialize_set_text(nil, current_size, text))
  end
end

function love.quit()
  if hosting then
    server_host:flush()
  end

  server:disconnect()
  client_host:flush()
end
