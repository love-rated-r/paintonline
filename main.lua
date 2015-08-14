local notification_queue = {}

local game_info = ""

-- this is for the client
local line = {}
local text = nil
local users = {}

-- this is for the server
local buffer = {}
local peers = {}

local current_color = 1
local colors = {
  [0] = {0, 0, 0},
  [1] = {255, 255, 255},
  [2] = {150, 150, 150},

  [3] = {255, 0, 0},
  [4] = {255, 127, 0},
  [5] = {255, 255, 0},

  [6] = {127, 255, 0},
  [7] = {0, 255, 0},
  [8] = {0, 255, 127},

  [9] = {0, 255, 255},
  [10] = {0, 127, 255},
  [11] = {0, 0, 255},
  
  [12] = {127, 0, 255},
  [13] = {255, 0, 255},
  [14] = {255, 0, 127}
}

local function has_arg(name) for _, v in pairs(arg) do if v == name then return true end end return false end

local headless = has_arg("--headless")
local hosting = headless or has_arg("--hosting")
local canvas_whole, big_font, font, small_font, cursors

if not headless then
  -- graphics stuff
  canvas_whole = love.graphics.newCanvas()
  canvas_whole:renderTo(function()
    love.graphics.clear()
    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("fill", 0, 0, canvas_whole:getWidth(), canvas_whole:getHeight())
  end)

  big_font = love.graphics.newFont(22)
  font = love.graphics.newFont(11)
  small_font = love.graphics.newFont(10)
  font:setLineHeight(1.3)

  -- cursors
  cursors = {}

  for i, color in pairs(colors) do
    local image = love.image.newImageData(16, 16)
    image:mapPixel(function(x, y)
      if x > 0 and y > 0 and x + y < 8 then
        return unpack(color)
      end
      if x + y < 10 then
        if i == 0 then
          return 255, 255, 255, 255
        end

        return 0, 0, 0, 255
      end
      return 0, 0, 0, 0
    end)
    
    cursors[i] = love.mouse.newCursor(image)
  end

  love.mouse.setCursor(cursors[current_color])
end

-- rules
local rules = {}

local server_rules = {
  ["real-time lines"] = "yes",
  ["slow draw"] = "no"
}

-- networking stuff
require("enet")

local server, client_host
local server_host

local draw_button = love._version_minor >= 10 and 1 or "l"

-- utf8 support
local utf8 = require("unicode")

function love.load()
  io.stdout:setvbuf("no")

  -- line defaults
  if not headless then
    love.graphics.setLineStyle("smooth")
    love.graphics.setLineWidth(2)

    -- repeat because text inputs
    love.keyboard.setKeyRepeat(true)
  end

  -- try to set up a server
  if hosting then
    -- max 10kib dl
    server_host = enet.host_create("0.0.0.0:9191", 256, 1, 10 * 1024)

    if not server_host then
      io.stderr:write("Could not set up the server\n")
      hosting = false
    end
  end

  -- connect
  if not headless then
    client_host = enet.host_create()
    server = client_host:connect(hosting and "localhost:9191" or "unek.xyz:9191")
  end

  -- feed the randomizer machine with some seeds
  math.randomseed(love.timer.getTime())

  -- game info, press tab to preview
  game_info = [[dick around with your friends!

  instructions:
  - hold ctrl and scroll to change color,
  - hold left mouse button to draw,
  - press enter to type and enter/lmb to place the text,
  - press S to screenshot,
  - press red X to close.]]
  if hosting then
    game_info = game_info .. [[


    server host instructions:
    - press C to clear the canvas,
    - press R to toggle dynamic lines]]
  end
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

local function serialize_line(line)
  return (line.color or current_color or 1) .. ": " .. table.concat(line, " ")
end

local function deserialize_line(str)
  local line = {}

  local color = tonumber(str:match("^(%d+): "))
  line.color  = math.min(#colors, math.max(0, color))

  for x, y in str:gmatch("(%d+)%s+(%d+)") do
    table.insert(line, x)
    table.insert(line, y)
  end

  return line
end

local function serialize_text(t)
  local color, x, y, t = unpack(t)
  color = math.min(#colors, math.max(0, color))
  t = utf8.sub(t, 1, 80)
  return string.format("%d; %d, %d: %s", color, x, y, t)
end

local function deserialize_text(str)
  local color, x, y, t = str:match("^(%d+); (%d+), (%d+): (.*)")

  return {tonumber(color), tonumber(x), tonumber(y), t}
end

local function send_data(type, data)
  server:send(type .. "\t" .. data)
end

local function broadcast_data(type, data)
  server_host:broadcast(type .. "\t" .. data)
end

local function broadcast_notification(text)
  broadcast_data("notification", text)
end

local function clear()
  if not hosting then return end

  broadcast_data("clear", 0)
  buffer = {}
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


local function friendly_name(ip)
  local ip = tostring(ip)
  local p1, p2, p3, p4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)")

  local n = p1 * 256 ^ 3 + p2 * 256 ^ 2, p3 * 256 ^ 1, p4 * 256 ^ 0

  return base36(n)
end

local function place_text(t, x, y)
  -- send to server
  send_data("text", serialize_text({current_color, x, y, t}))

  -- reset input
  text = nil

  -- bring back mouse
  love.mouse.setVisible(true)
end

-- dispatch table for the received commands
local commands = {
  line = function(data)
    if not love.mouse.isDown(draw_button) then
      -- reset
      line = {}
    end

    local line = deserialize_line(data)

    if line and #line > 0 and #line < 10001 then
      canvas_whole:renderTo(function()
        love.graphics.setColor(colors[line.color or 1] or colors[1])

        if #line > 3 then
          love.graphics.line(line)
        elseif #line > 1 then
          -- lol
          love.graphics.line(line[1], line[2] - 1, line[1], line[2] + 1)
        end
      end)
    end
  end,
  text = function(data)
    local color, x, y, t = unpack(deserialize_text(data))

    canvas_whole:renderTo(function()
      love.graphics.setColor(colors[color or 1] or colors[1])
      love.graphics.setFont(font)
      love.graphics.print(t, x, y)
    end)
  end,
  notification = function(data)
    local text = data

    push_notification(text, nil, colors[math.random(3, 14)])
  end,
  clear = function()
    canvas_whole:renderTo(function()
      love.graphics.clear()
      love.graphics.setColor(0, 0, 0)
      love.graphics.rectangle("fill", 0, 0, canvas_whole:getWidth(), canvas_whole:getHeight())
    end)
  end,
  userlist = function(data)
    users = {}
    for user in data:gmatch("(%S+)") do
      table.insert(users, user)
    end
  end,
  rule = function(data)
    local rule, value = data:match("^([^:]-):%s+(.*)")

    if tonumber(value) then
      value = tonumber(value)
    end

    rules[rule] = value
  end
}

local function is_admin(peer)
  return not not (tostring(peer):match("^88%.156") or tostring(peer):match("^2%.237%."))
end

local server_commands = {
  line = function(data)
    -- basically echo with some checking
    local line = deserialize_line(data)

    if line and #line > 0 then
      local serialized = serialize_line(line)
      broadcast_data("line", serialized, true)

      table.insert(buffer, "line\t" .. serialized)
    end
  end,
  text = function(data)
    -- basically echo with some checking
    local text = deserialize_text(data)

    if text then
      local serialized = serialize_text(text)
      broadcast_data("text", serialized, true)

      table.insert(buffer, "text\t" .. serialized)
    end
  end,
  rule = function(data, peer)
    log("%s is trying to use the rule admin command (%s)", tostring(peer), data or "")
    if not is_admin(peer) then return end

    local rule, value = data:match("^([^:]-):%s+(.*)")

    if tonumber(value) then
      value = tonumber(value)
    end

    server_rules[rule] = value

    broadcast_data("rule", rule .. ": " .. value)

    broadcast_notification(friendly_name(peer) .. " changed rule " .. rule .. " to " .. value)
  end,
  clear = function(data, peer)
    log("%s is trying to use the clear admin command (%s)", tostring(peer), data or "")
    if not is_admin(peer) then return end

    clear()

    broadcast_notification(friendly_name(peer) .. " cleared the canvas.")
  end
}

local function receive_data(str, peer, serverside)
  local commands = serverside and server_commands or commands
  local command, data = str:match("(.-)\t(.*)")
  if not command or not commands[command] then
    io.stderr:write("Invalid command received\n")
    return false
  end

  pcall(commands[command], data, peer)

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

  love.graphics.draw(canvas_whole)
  love.graphics.setBlendMode("alpha")

  love.graphics.setColor(colors[current_color])
  -- unpainted shit
  if not text then
    if #line > 3 then
      love.graphics.line(line)
    elseif #line > 1 then
      -- lol
      love.graphics.line(line[1], line[2] - 1, line[1], line[2] + 1)
    end
  else
    local mx, my = love.mouse.getPosition()
    love.graphics.setFont(font)
    love.graphics.print(text, mx, my)

    love.graphics.setColor(255, 255, 255)
    love.graphics.setFont(small_font)

    local length = utf8.len(text)
    love.graphics.print(string.format("%d char%s left", 80 - length, 80 - length == 1 and "" or "s"), mx, my - small_font:getHeight())

    love.graphics.rectangle("fill", mx + font:getWidth(text), my, 1, font:getHeight())
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
    local r, g, b = unpack(colors[current_color])
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

    local text = ("%s\n\nusers online (%d):\n- %s\n\nserver rules:\n%s\n\nnetwork info:\n- bandwidth used: %.2f kib\n- ping: %d ms"):format(game_info, #users, table.concat(users, ",\n- "), rule_list, bandwidth, server:round_trip_time(  ))

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
          event.peer:send("rule\t" .. rule .. ": " .. value)
        end

        -- send the new userlist to everyone
        local users = {}
        for _, peer in ipairs(peers) do
          table.insert(users, friendly_name(peer))
        end

        broadcast_data("userlist", table.concat(users, " "))
      elseif event.type == "disconnect" then
        log("%s (%s) left the paint.", tostring(event.peer), friendly_name(event.peer))
        broadcast_notification(string.format("%s lefted the paint.", friendly_name(event.peer)))

        -- remove from the peer table
        for i = #peers, 1, -1 do
          if peers[i] == event.peer then
            table.remove(peers, i)
          end
        end
        log("%d users online.", #peers)

        -- resend the userlist
        local users = {}
        for _, peer in ipairs(peers) do
          table.insert(users, friendly_name(peer))
        end

        broadcast_data("userlist", table.concat(users, " "))
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

      if rules["slow draw"] == "yes" then
        break
      end
    end
  end
end

if not headless then
  function love.mousemoved(x, y, dx, dy)
    if not love.mouse.isDown(draw_button) then return end

    table.insert(line, x)
    table.insert(line, y)

    if rules["real-time lines"] == "yes" then
      send_data("line", serialize_line(line))

      line = {x, y}
    end
  end

  function love.mousepressed(x, y, btn)
    if btn == draw_button and not text then
      table.insert(line, x)
      table.insert(line, y)
    elseif btn == draw_button and text then
      -- place text
      place_text(text, x, y)
    elseif btn == "wu" or btn == "wd" then
      love.wheelmoved(0, btn == "wu" and 1 or -1)
    end
  end

  function love.mousereleased(x, y, btn)
    if btn ~= draw_button or text then return end

    -- send line
    send_data("line", serialize_line(line))
  end

  function love.wheelmoved(x, y)
    if not love.keyboard.isDown("lctrl", "rctrl") then return end
    current_color = (current_color + y) % #colors

    love.mouse.setCursor(cursors[current_color])
  end

  function love.keypressed(key, is_repeat, blah)
    if love._version_minor >= 10 then
      is_repeat = blah
    end

    if text then
      if key == "backspace" then
        text = utf8.sub(text, 1, utf8.len(text) - 1)
      end
      if key == "return" and not is_repeat then
        place_text(text, love.mouse.getPosition())
      end
      if key == "escape" then
        text = nil
        
        love.mouse.setVisible(true)
      end
    else
      if hosting then
        if key == "c" and not is_repeat then
          clear()
        end
        if key == "r" and not is_repeat then
          server_rules["real-time lines"] = server_rules["real-time lines"] == "yes" and "no" or "yes"
          broadcast_data("rule", "real-time lines: " .. server_rules["real-time lines"])
        end
      end

      if key == "s" and not is_repeat then
        local filename = string.format("%s-drawing.png", os.date("%Y-%m-%d_%H-%M-%S"))
        if love._version_minor >= 10 then
          canvas_whole:newImageData():encode("png", filename)
        else
          canvas_whole:getImageData():encode(filename)
        end
        push_notification("screenshot saved.", 3, {255, 255, 0})
      end
      if key == "return" and not is_repeat then
        text = ""
        love.mouse.setVisible(false)
      end

      -- admin commands
      if key == "f1" then
        if not is_repeat then
          send_data("clear", 0)
        end
      end
      if key == "f2" then
        send_data("rule", "real-time lines: " .. (rules["real-time lines"] == "yes" and "no" or "yes"))
      end
      if key == "f3" then
        send_data("rule", "slow draw: " .. (rules["slow draw"] == "yes" and "no" or "yes"))
      end

      if key == "f4" then
        place_text("FUCK", love.mouse.getPosition())
      end
    end
  end

  function love.textinput(t)
    if not text then return end

    local t = t:gsub("[\r\n]", "")
    text = utf8.sub(text .. t, 1, 80)
  end
end

function love.quit()
  if hosting then
    server_host:flush()
  end

  server:disconnect()
  client_host:flush()
end
