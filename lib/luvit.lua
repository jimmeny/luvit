-- clear some globals
-- This will break lua code written for other lua runtimes
_G.io = nil
_G.os = nil
_G.math = nil
_G.string = nil
_G.coroutine = nil
_G.jit = nil
_G.bit = nil
_G.debug = nil
_G.table = nil
_G.print = nil
_G.loadfile = nil

-- Load libraries used in this file
local Debug = require('debug')

local UV = require('uv')
local Env = require('env')

local Table = require('table')
local Utils = require('utils')
local FS = require('fs')
local TTY = require('tty')
local Emitter = require('emitter')
local Constants = require('constants')
local Path = require('path')

process = Emitter.new()
process.cwd = getcwd
_G.getcwd = nil
process.argv = argv
_G.argv = nil

local base_path = process.cwd()

-- Hide some stuff behind a metatable
local hidden = {}
setmetatable(_G, {__index=function(table, key)
  if key == "__dirname" then
    local source = Debug.getinfo(2, "S").source
    if source:sub(1,1) == "@" then
      return Path.join(base_path, Path.dirname(source:sub(2)))
    end
    return
  elseif key == "__filename" then
    local source = Debug.getinfo(2, "S").source
    if source:sub(1,1) == "@" then
      return Path.join(base_path, source:sub(2))
    end
    return
  else
    return hidden[key]
  end
end})
local function hide(name)
  hidden[name] = _G[name]
  _G[name] = nil
end
hide("_G")
hide("exit_process")


function process.exit(exit_code)
  process:emit('exit', exit_code)
  exit_process(exit_code or 0)
end

-- Ignore sigpipe and exit cleanly on SIGINT and SIGTERM
-- These shouldn't hold open the event loop
UV.activate_signal_handler(Constants.SIGPIPE);
UV.unref()
UV.activate_signal_handler(Constants.SIGINT);
UV.unref()
UV.activate_signal_handler(Constants.SIGTERM);
UV.unref()

-- Load the tty as a pair of pipes
-- But don't hold the event loop open for them
process.stdin = TTY.new(0)
UV.unref()
process.stdout = TTY.new(1)
UV.unref()
local stdout = process.stdout

-- Replace print
function print(...)
  local n = select('#', ...)
  local arguments = { ... }

  for i = 1, n do
    arguments[i] = tostring(arguments[i])
  end

  stdout:write(Table.concat(arguments, "\t") .. "\n")
end

-- A nice global data dumper
function p(...)
  local n = select('#', ...)
  local arguments = { ... }

  for i = 1, n do
    arguments[i] = Utils.dump(arguments[i])
  end

  stdout:write(Table.concat(arguments, "\t") .. "\n")
end


-- Add global access to the environment variables using a dynamic table
process.env = setmetatable({}, {
  __pairs = function (table)
    local keys = Env.keys()
    local index = 0
    return function (...)
      index = index + 1
      local name = keys[index]
      if name then
        return name, table[name]
      end
    end
  end,
  __index = function (table, name)
    return Env.get(name)
  end,
  __newindex = function (table, name, value)
    if value then
      Env.set(name, value, 1)
    else
      Env.unset(name)
    end
  end
})

-- This is called by all the event sources from C
-- The user can override it to hook into event sources
function event_source(name, fn, ...)
  local args = {...}
  return assert(xpcall(function ()
    return fn(unpack(args))
  end, Debug.traceback))
end

-- Make relative requires be relative to the file that required them
local real_require = require
function require(path)
  if path:sub(1,1) == "." then
    local source = Debug.getinfo(2, "S").source
    if source:sub(1,1) == "@" then
      local dirname = Path.dirname(source:sub(2))
      path = Path.join(dirname, path)
    end
  end
  return real_require(path)
end

-- Load the file given or start the interactive repl
if process.argv[1] then
  dofile(process.argv[1])
else
  require('repl')
end

-- Start the event loop
UV.run()
-- trigger exit handlers and exit cleanly
process.exit(0)

