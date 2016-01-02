local function has_arg(name) for _, v in pairs(arg) do if v == name then return true end end return false end

function love.conf(t)
  t.identity = "PENISDRAW"

  t.window.title = "PENISDRAW"
  t.window.width = 1024
  t.window.height = 768
  t.window.resizable = false

  t.window.vsync = true

  if has_arg("--headless") then
    t.window = false
  end

  local disable = {"audio", "joystick", "math", "physics", "sound", "thread"}

  if has_arg("--headless") then
    t.window = false
    table.insert(disable, "graphics")
    table.insert(disable, "window")
    table.insert(disable, "image")
  end

  for _, module in ipairs(disable) do
    t.modules[module] = false
  end
end