-- Catware - Turbo Soccer (place 101880234193261). Obsidian UI, port of Catware - Blox League.
-- Turbo Soccer runs its own RocketSim-style sim (ReplicatedStorage.Shared.Sim, uu, 120Hz, same axis/sign
-- conventions as RocketSim). Matches go through Net.Prediction:step(controls) (server-authoritative, inputs
-- only); training/tutorial/free play runs a local single-car Sim.World. Both are hooked at their step.
-- Run: loadstring(game:HttpGet(SCRIPT_URL))()
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LP = game:GetService("Players").LocalPlayer

if getgenv().CatwareTurboSoccerUnload then pcall(getgenv().CatwareTurboSoccerUnload) end

local Shared = RS:WaitForChild("Shared")
local Client = LP:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Sim = Shared:WaitForChild("Sim")
local World = require(Sim:WaitForChild("World"))
local BallPrediction = require(Sim:WaitForChild("BallPrediction"))
local Prediction = require(Shared:WaitForChild("Net"):WaitForChild("Prediction"))
local Protocol = require(Shared.Net:WaitForChild("Protocol"))
local Units = require(Client:WaitForChild("Units"))
local Motion = require(Client:WaitForChild("Motion")) -- atMenu(): title screen (the menu backdrop is a live World)

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local Options, Toggles = Library.Options, Library.Toggles

---------------------------------------------------------------- live sim
-- live = { cars = {{car, team, index}}, ball, pads, tick, me = entry } of whichever sim stepped last
local live
local lastMatchAt = -1
local TICK = 1 / 120
local path = {} -- predicted ball {pos, t} every PATH_STRIDE ticks
local PATH_STRIDE = 4
local ballPred = BallPrediction.new()

local function fromMatch(P)
	local m = P.match
	local cars = {}
	for _, e in m.cars do
		if not e.vacant then table.insert(cars, e) end
	end
	return { cars = cars, ball = m.ball, pads = m.pads and m.pads.pads or {}, tick = m.tick, me = P.localIndex and m.cars[P.localIndex] }
end
local function fromWorld(w)
	local me = { car = w.car, team = 0, index = 1 }
	return { cars = { me }, ball = w.ball, pads = w.pads and w.pads.pads or {}, tick = w.tick, me = me }
end

-- Blox League-style read-only view of a car, so the control code below ports verbatim
local function stateOf(car)
	local b = car.body
	return {
		pos = b.pos, vel = b.vel, angVel = b.angVel, rot = { forward = b.fwd, right = b.right, up = b.up },
		boost = car.boost, isOnGround = car.isOnGround, isFlipping = car.isFlipping,
		hasFlipped = car.hasFlipped, hasDoubleJumped = car.hasDoubleJumped, isDemoed = car.isDemoed,
	}
end

local function predictBall(seconds)
	table.clear(path)
	if not live then return end
	ballPred:run(live.ball, seconds, PATH_STRIDE)
	for i = 2, #ballPred.points do
		table.insert(path, { pos = ballPred.points[i], t = ballPred.times[i] })
	end
end

---------------------------------------------------------------- control helpers (signs from Sim.Car)
-- steer/yaw + turns toward rot.right, pitch + = nose up, roll + tilts up toward rot.right
-- rates: pitch = -w·right, yaw = w·up, roll = -w·forward
local UP = vector.create(0, 0, 1)
local function clamp1(x) return math.clamp(x, -1, 1) end
local function flat(v) return vector.create(v.x, v.y, 0) end
local function angleTo(rot, dir)
	return math.atan2(vector.dot(dir, rot.right), vector.dot(dir, rot.forward))
end

local function now() return (live and live.tick or 0) * TICK end

local function orient(c, st, f)
	local rot, w = st.rot, st.angVel
	local eRoll = math.atan2(vector.dot(UP, rot.right), vector.dot(UP, rot.up))
	local ePitch = math.atan2(vector.dot(f, rot.up), vector.dot(f, rot.forward))
	local eYaw = math.atan2(vector.dot(f, rot.right), vector.dot(f, rot.forward))
	c.roll = clamp1(3 * eRoll + 0.6 * vector.dot(w, rot.forward))
	c.pitch = clamp1(3.5 * ePitch + 0.8 * vector.dot(w, rot.right))
	c.yaw = clamp1(3.5 * eYaw - 0.8 * vector.dot(w, rot.up))
end
local function recover(c, st, heading)
	local h = heading or flat(st.rot.forward)
	if vector.magnitude(h) < 1 then h = vector.create(0, 1, 0) end
	orient(c, st, vector.normalize(h))
end

local dodge -- {t0, pitch, yaw}
local function startDodge(st, target)
	if dodge or not st.isOnGround then return end
	local a = angleTo(st.rot, flat(target - st.pos))
	local p, y = -math.cos(a), math.sin(a)
	local m = math.max(math.abs(p), math.abs(y))
	dodge = { t0 = now(), pitch = p / m, yaw = y / m }
end
local function runDodge(c)
	if not dodge then return false end
	local dt = now() - dodge.t0
	if dt > 0.9 or dt < 0 then dodge = nil return false end
	c.pitch, c.yaw, c.roll = 0, 0, 0
	if dt < 0.08 then
		c.jump = true
	elseif dt < 0.13 then
		c.jump = false
	elseif dt < 0.2 then
		c.jump, c.pitch, c.yaw = true, dodge.pitch, dodge.yaw
	else
		c.jump, c.pitch, c.yaw = false, dodge.pitch, dodge.yaw
	end
	return true
end

local function nearBall(st, within)
	local b = path[math.max(1, math.floor(0.15 / (PATH_STRIDE * TICK)))]
	if not b or st.rot.up.z < 0.7 then return nil end
	local d = b.pos - (st.pos + st.vel * 0.15)
	if b.pos.z > 220 or math.abs(d.z) > 200 then return nil end
	local fwd, side = vector.dot(d, st.rot.forward), vector.dot(d, st.rot.right)
	if vector.magnitude(flat(d)) < within and fwd > -40 and math.abs(side) < 130 then return b.pos end
end

---------------------------------------------------------------- Ripple v1.1 external inference adapter
local DIR = "Catware/TurboSoccer/"
local SCRIPT_URL = "https://raw.githubusercontent.com/akramgaali233-dot/catware-ripple/main/catware_ripple_request_probe.lua"
local Ripple = (function()
-- Ripple v1.1 Luau runtime adapter for Turbo Soccer.
--
-- This file ports the inference-side behavior from Ripple-RLBot. It expects
-- the caller to provide the live Turbo Soccer view already used by Catware:
--   live = { cars = {{car, team, index}}, ball = ..., pads = {}, tick = ..., me = ... }
-- and a stateOf(car) function returning the read-only car state used by the
-- pasted Catware script.
--
-- Ripple source/model license: CC BY-NC-SA 4.0.
-- Original author: Rolv-Arild/Ripple-RLBot. This is an adapted Luau port.

local Ripple = {}
Ripple.__index = Ripple

local SQRT2PI = math.sqrt(2 / math.pi)
local SQRT32 = math.sqrt(32)
local EPS = 1e-5
local HttpService = game:GetService("HttpService")

local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end

local function dot3(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z
end

local function add3(a, b)
	return vector.create(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function sub3(a, b)
	return vector.create(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function mul3(a, k)
	return vector.create(a.x * k, a.y * k, a.z * k)
end

local function mag3(a)
	return math.sqrt(dot3(a, a))
end

local function safeUnit(a)
	local m = mag3(a)
	if m < 1e-8 then
		return vector.create(0, 0, 0)
	end
	return mul3(a, 1 / m)
end

local function local3(v, rot)
	return { dot3(v, rot.forward), dot3(v, rot.right), dot3(v, rot.up) }
end

local function put3(out, at, v)
	out[at], out[at + 1], out[at + 2] = v.x, v.y, v.z
end

local function copyArray(a)
	local out = table.create(#a)
	for i = 1, #a do out[i] = a[i] end
	return out
end

local function zeroes(n)
	local out = table.create(n, 0)
	for i = 1, n do out[i] = 0 end
	return out
end

local function erf(x)
	if math.erf then
		return math.erf(x)
	end
	-- Accurate enough for inference in Luau when math.erf is unavailable.
	local ax = math.abs(x)
	local t = 1 / (1 + 0.3275911 * ax)
	local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-ax * ax)
	return x < 0 and -y or y
end

local function gelu(x)
	return 0.5 * x * (1 + erf(x / math.sqrt(2)))
end

local function linear(x, layer, ctx)
	local input, output = layer.input, layer.output
	local w, b = layer.w, layer.b
	local y = table.create(output, 0)
	for j = 1, output do
		local sum = b[j]
		local wi = j - 1
		for i = 1, input do
			sum += x[i] * w[(i - 1) * output + j]
			if ctx and i % 32 == 0 then ctx:yieldIfNeeded() end
		end
		y[j] = sum
		if ctx then ctx:yieldIfNeeded() end
	end
	return y
end

local function layerNorm(x, weight, bias)
	local mean = 0
	for i = 1, #x do mean += x[i] end
	mean /= #x
	local variance = 0
	for i = 1, #x do
		local d = x[i] - mean
		variance += d * d
	end
	variance /= #x
	local scale = 1 / math.sqrt(variance + EPS)
	local y = table.create(#x, 0)
	for i = 1, #x do y[i] = (x[i] - mean) * scale * weight[i] + bias[i] end
	return y
end

local function mlp(x, layers, ctx)
	for i, layer in ipairs(layers) do
		x = linear(x, layer, ctx)
		if i < #layers then
			for j = 1, #x do x[j] = gelu(x[j]) end
		end
	end
	return x
end

local function row(flat, start, length)
	local out = table.create(length)
	for i = 1, length do out[i] = flat[start + i - 1] end
	return out
end

local function append(out, values)
	for i = 1, #values do out[#out + 1] = values[i] end
end

local function softmax(values)
	local maxValue = -math.huge
	for i = 1, #values do maxValue = math.max(maxValue, values[i]) end
	local total = 0
	for i = 1, #values do
		values[i] = math.exp(values[i] - maxValue)
		total += values[i]
	end
	if total == 0 then return values end
	for i = 1, #values do values[i] /= total end
	return values
end

local function applyProjection(x, weights, bias, ctx)
	return linear(x, { input = 128, output = 128, w = weights, b = bias }, ctx)
end

local function attention(q, kv, mask, layer, ctx)
	local q0 = copyArray(q)
	local qn = layerNorm(q, layer.q_norm_w, layer.q_norm_b)
	local kvn = {}
	for i = 1, #kv do kvn[i] = layerNorm(kv[i], layer.kv_norm_w, layer.kv_norm_b) end

	local qProjected = applyProjection(qn, layer.q_w, layer.q_b, ctx)
	local kProjected, vProjected = {}, {}
	for i = 1, #kvn do
		kProjected[i] = applyProjection(kvn[i], layer.k_w, layer.k_b, ctx)
		vProjected[i] = applyProjection(kvn[i], layer.v_w, layer.v_b, ctx)
	end

	local attended = table.create(128, 0)
	for head = 1, 4 do
		local scores = table.create(#kvn)
		for token = 1, #kvn do
			if mask[token] then
				scores[token] = -math.huge
			else
				local sum = 0
				for d = 1, 32 do
					local qIndex = (head - 1) * 32 + d
					sum += qProjected[qIndex] * kProjected[token][qIndex]
				end
				scores[token] = sum / SQRT32
			end
		end
		softmax(scores)
		for d = 1, 32 do
			local sum = 0
			for token = 1, #kvn do
				sum += scores[token] * vProjected[token][(head - 1) * 32 + d]
			end
			attended[(head - 1) * 32 + d] = sum
		end
	end

	local projected = applyProjection(attended, layer.out_w, layer.out_b, ctx)
	local residual = table.create(128)
	for i = 1, 128 do residual[i] = q0[i] + projected[i] end
	local ff = layerNorm(residual, layer.qkv_norm_w, layer.qkv_norm_b)
	ff = linear(ff, { input = 128, output = 512, w = layer.mlp_w1, b = layer.mlp_b1 }, ctx)
	for i = 1, 512 do ff[i] = gelu(ff[i]) end
	ff = linear(ff, { input = 512, output = 128, w = layer.mlp_w2, b = layer.mlp_b2 }, ctx)
	for i = 1, 128 do residual[i] += ff[i] end
	return residual
end

local function argmax(values)
	local best, bestValue = 1, -math.huge
	for i = 1, #values do
		if values[i] > bestValue then best, bestValue = i, values[i] end
	end
	return best
end

local function makeActionTable()
	local actions = {}
	local throttleBins = { -1, 0, 0.5, 1 }
	local steerBins = { -1, -0.5, 0, 0.5, 1 }
	local torqueBins = { -1, -0.5, 0, 0.5, 1 }
	local function push(a) actions[#actions + 1] = a end
	for _, throttle in ipairs(throttleBins) do
		for _, steer in ipairs(steerBins) do
			for boost = 0, 1 do
				for handbrake = 0, 1 do
					if boost == 0 or throttle == 1 then
						push({ throttle, steer, 0, steer, 0, 0, boost, handbrake })
					end
				end
			end
		end
	end
	for _, pitch in ipairs(torqueBins) do
		for _, yaw in ipairs(torqueBins) do
			for _, roll in ipairs(torqueBins) do
				if not (pitch == 0 and roll == 0 and (yaw == -1 or yaw == -0.5 or yaw == 0 or yaw == 0.5 or yaw == 1)) then
					local magnitude = math.max(math.abs(pitch), math.abs(yaw), math.abs(roll))
					if magnitude >= 1 then
						for boost = 0, 1 do
							push({ boost, yaw, pitch, yaw, roll, 0, boost, 0 })
						end
					end
				end
			end
		end
	end
	-- Ripple's official flip/jump section has one empty jump action,
	-- followed by 16 angles at k*pi/8 (k = 0..15), each with boost off/on.
	for boost = 0, 1 do
		push({ boost, 0, 0, 0, 0, 1, boost, 1 })
	end
	for i = 0, 15 do
		local angle = i * math.pi / 8
		local pitch, roll = math.sin(angle), math.cos(angle)
		local magnitude = math.max(math.abs(pitch), math.abs(roll))
		pitch, roll = pitch / magnitude, roll / magnitude
		for boost = 0, 1 do
			push({ boost, 0, pitch, 0, roll, 1, boost, 1 })
		end
	end
	assert(#actions == 276, "Ripple action table must contain 276 actions")
	return actions
end

local ACTIONS = makeActionTable()

function Ripple.new(options)
	assert(options and (options.model or options.externalUrl), "Ripple.new requires a model or externalUrl")
	assert(options.getLive, "Ripple.new requires getLive()")
	assert(options.stateOf, "Ripple.new requires stateOf(car)")
	local self = setmetatable({
		model = options.model,
		externalUrl = options.externalUrl,
		getLive = options.getLive,
		stateOf = options.stateOf,
		getPath = options.getPath or function() return {} end,
		decisionEvery = options.decisionEvery or 8,
		budget = options.budget or 0.0015,
		maxJobSeconds = options.maxJobSeconds or 0.20,
		action = { 0, 0, 0, 0, 0, 0, 0, 0 },
		nextDecision = 0,
		job = nil,
		jobStarted = 0,
		remoteBusy = false,
		remoteResult = nil,
		remoteError = nil,
		spent = 0,
		deadline = 0,
		queues = {},
		previous = {},
		players = {},
		boostTimers = table.create(34, 0),
	}, Ripple)
	for i = 1, 34 do self.boostTimers[i] = 0 end
	return self
end

function Ripple:yieldIfNeeded()
	if coroutine.running() and os.clock() > self.deadline then coroutine.yield() end
end

function Ripple:carKey(entry)
	return tostring(entry.index or entry.id or entry.car)
end

function Ripple:queueFor(entry)
	local key = self:carKey(entry)
	local q = self.queues[key]
	if not q then
		q = {}
		for i = 1, 6 do q[i] = zeroes(8) end
		self.queues[key] = q
	end
	return q
end

function Ripple:updateBoostTimers(live)
	for i = 1, 34 do
		local p = live.pads and live.pads[i]
		local active = p and (p.active == true or p.isActive == true or p.enabled == true)
		if active then self.boostTimers[i] = 0 else self.boostTimers[i] = math.max(self.boostTimers[i], 0.1) end
	end
end

local BOOST_LOCATIONS = {
	{0,-4240,70},{-1792,-4184,70},{1792,-4184,70},{-3072,-4096,73},{3072,-4096,73},
	{-940,-3308,70},{940,-3308,70},{0,-2816,70},{-3584,-2484,70},{3584,-2484,70},
	{-1788,-2300,70},{1788,-2300,70},{-2048,-1036,70},{0,-1024,70},{2048,-1036,70},
	{-3584,0,73},{-1024,0,70},{1024,0,70},{3584,0,73},{-2048,1036,70},
	{0,1024,70},{2048,1036,70},{-1788,2300,70},{1788,2300,70},
	{-3584,2484,70},{3584,2484,70},{0,2816,70},{-940,3310,70},{940,3308,70},
	{-3072,4096,73},{3072,4096,73},{-1792,4184,70},{1792,4184,70},{0,4240,70},
}

function Ripple:ballSlices(live)
	local ball = live.ball.body
	local current = ball.pos
	local path = self.getPath() or {}
	local slices = {}
	for i = 0, 5 do
		local p = current
		if i > 0 then
			local wanted = i
			local nearest, distance = nil, math.huge
			for _, point in ipairs(path) do
				local d = math.abs((point.t or 0) - wanted)
				if d < distance then nearest, distance = point, d end
			end
			if nearest then p = nearest.pos end
		end
		local v = ball.vel
		local av = ball.angVel
		slices[#slices + 1] = { pos = p, vel = v, angVel = av }
	end
	return slices
end

function Ripple:rawPlayers(live)
	local out = {}
	for _, entry in ipairs(live.cars or {}) do
		local st = self.stateOf(entry.car)
		local boost = st.boost or 0
		if boost > 2 then boost /= 100 end
		local q = self:queueFor(entry)
		local action = q[6]
		local key = self:carKey(entry)
		local last = self.previous[key] or { onGround = st.isOnGround }
		local airborne = not st.isOnGround
		local car = {
			entry = entry, state = st, boost = clamp(boost, 0, 2), queue = q,
			hasJump = airborne or not last.onGround,
			hasFlip = not st.hasDoubleJumped,
			boostTime = action[7] > 0 and math.min((last.boostTime or 0) + 4, 12) or 0,
			jumpTime = airborne and math.min((last.jumpTime or 0) + 4, 24) or 0,
			airTime = airborne and math.min((last.airTime or 0) + 4, 150) or 0,
			flipTime = st.isFlipping and math.min((last.flipTime or 0) + 4, 120) or 0,
			handbrake = action[8] > 0 and math.min((last.handbrake or 0) + 1 / 6, 1) or math.max((last.handbrake or 0) - 1 / 30, 0),
			flipDir = last.flipDir or { 0, 0 },
		}
		self.previous[key] = {
			onGround = st.isOnGround, boostTime = car.boostTime, jumpTime = car.jumpTime,
			airTime = car.airTime, flipTime = car.flipTime, handbrake = car.handbrake,
			flipDir = car.flipDir,
		}
		out[#out + 1] = car
	end
	return out
end

function Ripple:buildObservation(live)
	self:updateBoostTimers(live)
	local cars = self:rawPlayers(live)
	local me = live.me
	if not me then return nil end
	local meIndex
	for i, car in ipairs(cars) do if car.entry == me then meIndex = i break end end
	if not meIndex then return nil end
	local ordered = { cars[meIndex] }
	for i, car in ipairs(cars) do if i ~= meIndex then ordered[#ordered + 1] = car end end
	while #ordered < 6 do
		ordered[#ordered + 1] = nil
	end
	local origin = ordered[1].state
	local rot = origin.rot
	local ballSlices = self:ballSlices(live)
	local players = table.create(6 * 32, 0)
	local others = table.create(5 * 21, 0)
	local balls = table.create(6 * 9, 0)
	local actions = table.create(6 * 8, 0)
	local boosts = table.create(34 * 5, 0)
	local team = ordered[1].entry.team or 0

		local function playerRaw(car, target)
			local st = car.state
			local relPos = sub3(st.pos, origin.pos)
			local relVel = sub3(st.vel, origin.vel)
			local p = local3(relPos, rot)
			local v = local3(relVel, rot)
			local av = local3(st.angVel, rot)
			local fwd = local3(st.rot.forward, rot)
			local up = local3(st.rot.up, rot)
			local base = target
			put3(base, 1, vector.create(p[1], p[2], p[3]))
			put3(base, 4, vector.create(v[1], v[2], v[3]))
			put3(base, 7, vector.create(av[1], av[2], av[3]))
			put3(base, 10, vector.create(fwd[1], fwd[2], fwd[3]))
			put3(base, 13, vector.create(up[1], up[2], up[3]))
			base[16] = 2 * car.entry.team - 1
			base[17] = st.isDemoed and 3 or 0
			base[18] = st.isOnGround and 1 or 0
			base[19] = car.hasJump and 1 or 0
			base[20] = car.hasFlip and 1 or 0
			base[21] = car.boost
			base[22] = car.boostTime
			base[23] = car.jumpTime
			base[24] = car.airTime
			base[25] = car.flipTime
			base[26] = car.handbrake
			base[27], base[28] = car.flipDir[1], car.flipDir[2]
			base[29] = 0
			base[30] = (ballSlices[1].pos.x == 0 and ballSlices[1].pos.y == 0) and 1 or 0
			base[31], base[32] = 0, 0
		end

	local current = table.create(32, 0)
	playerRaw(ordered[1], current)
	for i = 1, 32 do current[i] = current[i] / ({2300,2300,2300,2300,2300,2300,6,6,6,1,1,1,1,1,1,1,3,1,1,1,1,12,24,150,120,1,1,1,1,1,1,1})[i] end
	for i = 1, 32 do players[i] = current[i] end

	for i = 2, 6 do
		local base = table.create(32, 0)
		if ordered[i] then playerRaw(ordered[i], base) end
		for j = 1, 32 do
			local div = ({2300,2300,2300,2300,2300,2300,6,6,6,1,1,1,1,1,1,1,3,1,1,1,1,12,24,150,120,1,1,1,1,1,1,1})[j]
			base[j] = base[j] / div
		end
		for j = 1, 21 do
			players[(i - 1) * 32 + j] = base[j]
			others[(i - 2) * 21 + j] = base[j]
		end
	end

	for i, slice in ipairs(ballSlices) do
		local p = local3(sub3(slice.pos, origin.pos), rot)
		local v = local3(sub3(slice.vel, origin.vel), rot)
		local av = local3(slice.angVel, rot)
		local at = (i - 1) * 9 + 1
		balls[at], balls[at+1], balls[at+2] = p[1]/2300, p[2]/2300, p[3]/2300
		balls[at+3], balls[at+4], balls[at+5] = v[1]/2300, v[2]/2300, v[3]/2300
		balls[at+6], balls[at+7], balls[at+8] = av[1]/6, av[2]/6, av[3]/6
	end

	local q = ordered[1].queue
	for step = 1, 6 do
		for j = 1, 8 do actions[(step - 1) * 8 + j] = q[step][j] end
	end
	for i, loc in ipairs(BOOST_LOCATIONS) do
		local p = local3(sub3(vector.create(loc[1], loc[2], loc[3]), origin.pos), rot)
		local at = (i - 1) * 5 + 1
		boosts[at], boosts[at+1], boosts[at+2] = p[1]/2300, p[2]/2300, p[3]/2300
		boosts[at+3] = loc[3] > 72 and 1 or 0.12
		boosts[at+4] = self.boostTimers[i] / 10
	end

	-- Ripple is trained in a blue-side, left-half canonical frame.
	if team == 1 then
		local invTeam = {-1,-1,1,-1,-1,1,-1,-1,1,-1,-1,1,-1,-1,1,-1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1}
		for i = 1, 32 do players[i] *= invTeam[i] end
		for i = 1, 5 do for j = 16, 21 do others[(i-1)*21+j] *= invTeam[j] end end
	end
	if players[1] < 0 then
		local invSide = {-1,1,1,-1,1,1,1,-1,-1,1,-1,1,1,-1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1}
		local invRel = {1,-1,1,1,-1,1,-1,1,-1,1,-1,1,1,-1,1,1,1,1,1,1,1}
		for i = 1, 32 do players[i] *= invSide[i] end
		for i = 1, 5 do for j = 1, 21 do others[(i-1)*21+j] *= invRel[j] end end
		local invBall = {1,-1,1,1,-1,1,-1,1,-1}
		for i = 1, 54 do balls[i] *= invBall[((i-1)%9)+1] end
		for i = 1, 34 do
			boosts[(i-1)*5+1] *= 1
			boosts[(i-1)*5+2] *= -1
			boosts[(i-1)*5+3] *= 1
		end
		for i = 1, #actions do actions[i] *= ({1,-1,1,-1,-1,1,1,1})[((i-1)%8)+1] end
		players[30] *= -1
		players[31] = 1
	end
	return { main = players, others = others, ball = balls, actions = actions, boosts = boosts }
end

function Ripple:forward(obs)
	if self.externalUrl then
		local requester
		pcall(function() requester = request end)
		if not requester then pcall(function() requester = http_request end) end
		if not requester then pcall(function() requester = syn and syn.request end) end
		assert(requester, "Ripple external inference requires the executor request() API")
		local response = requester({
			Url = self.externalUrl,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode({
				main = obs.main,
				others = obs.others,
				ball = obs.ball,
				actions = obs.actions,
				boosts = obs.boosts,
			}),
			Timeout = 0.25,
		})
		assert(response and (response.Success == nil or response.Success), "Ripple inference service request failed")
		local body = response.Body or response.body
		assert(body, "Ripple inference service returned no body")
		local decoded = HttpService:JSONDecode(body)
		assert(decoded and decoded.action, "Ripple inference service returned no action")
		return tonumber(decoded.action)
	end
	local m = self.model
	local main = row(obs.main, 1, 30)
	local q = mlp(main, m.processors.main, self)
	local kv, mask = {}, {}
	for i = 1, 5 do
		local start = (i - 1) * 32 + 1
		local features = row(obs.others, start, 21)
		kv[#kv + 1] = mlp(features, m.processors.others, self)
		mask[#mask + 1] = obs.others[start + 15] == 0
	end
	kv[#kv + 1] = mlp(obs.ball, m.processors.ball, self)
	mask[#mask + 1] = false
	kv[#kv + 1] = mlp(obs.actions, m.processors.actions, self)
	mask[#mask + 1] = false
	local boostTokens = {}
	for i = 1, 34 do boostTokens[i] = mlp(row(obs.boosts, (i - 1) * 5 + 1, 5), m.processors.boosts, self) end
	local boostMax = table.create(128, -math.huge)
	for i = 1, 34 do
		for j = 1, 128 do
			boostMax[j] = math.max(boostMax[j], boostTokens[i][j])
			if j % 32 == 0 then self:yieldIfNeeded() end
		end
	end
	kv[#kv + 1] = boostMax
	mask[#mask + 1] = false
	for _, layer in ipairs(m.layers) do q = attention(q, kv, mask, layer, self) end
	q = layerNorm(q, m.state_norm_w, m.state_norm_b)
	local logits = table.create(276, 0)
	for action = 1, 276 do
		local sum = 0
		for i = 1, 128 do
			sum += q[i] * m.action_embeddings[(i - 1) * 276 + action]
			if i % 32 == 0 then self:yieldIfNeeded() end
		end
		logits[action] = sum
		if action % 8 == 0 then self:yieldIfNeeded() end
	end
	if obs.main[31] > 0.5 then
		local reordered = table.create(276)
		for i = 1, 276 do reordered[i] = logits[m.invert_map[i] + 1] end
		logits = reordered
	end
	return argmax(logits)
end

function Ripple:requestExternal(obs)
	if self.remoteBusy then return end
	local requester
	pcall(function() requester = request end)
	if not requester then pcall(function() requester = http_request end) end
	if not requester then pcall(function() requester = syn and syn.request end) end
	assert(requester, "Ripple external inference requires the executor request() API")
	assert(task and task.spawn, "Ripple external inference requires task.spawn")
	local body = HttpService:JSONEncode({
		main = obs.main,
		others = obs.others,
		ball = obs.ball,
		actions = obs.actions,
		boosts = obs.boosts,
	})
	self.remoteBusy = true
	task.spawn(function()
		local ok, result = pcall(function()
			local response = requester({
				Url = self.externalUrl,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json" },
				Body = body,
				Timeout = 0.25,
			})
			assert(response and (response.Success == nil or response.Success), "Ripple inference service request failed")
			local responseBody = response.Body or response.body
			assert(responseBody, "Ripple inference service returned no body")
			local decoded = HttpService:JSONDecode(responseBody)
			assert(decoded and decoded.action, "Ripple inference service returned no action")
			return tonumber(decoded.action)
		end)
		if ok then self.remoteResult = result else self.remoteError = tostring(result) end
		self.remoteBusy = false
	end)
end

function Ripple:applyAction(controls)
	local a = ACTIONS[self.actionIndex or 1]
	controls.throttle, controls.steer = a[1], a[2]
	controls.pitch, controls.yaw, controls.roll = a[3], a[4], a[5]
	controls.jump, controls.boost, controls.handbrake = a[6] > 0, a[7] > 0, a[8] > 0
end

function Ripple:step(controls)
	local live = self.getLive()
	if not live or not live.me then return end
	local tick = live.tick or 0
	if self.externalUrl then
		if self.remoteResult then
			self.actionIndex = self.remoteResult
			self.remoteResult = nil
		end
		if self.remoteError then
			warn("[Ripple] external inference:", self.remoteError)
			self.remoteError = nil
		end
		if not self.remoteBusy and tick >= self.nextDecision then
			self.nextDecision = tick + self.decisionEvery
			local ok, obs = pcall(function() return self:buildObservation(live) end)
			if ok and obs then
				local started, err = pcall(function() self:requestExternal(obs) end)
				if not started then self.remoteError = err end
			elseif not ok then
				self.remoteError = obs
			end
		end
		self:applyAction(controls)
		return
	end
	if not self.job and tick >= self.nextDecision then
		self.nextDecision = tick + self.decisionEvery
		self.jobStarted = os.clock()
		self.job = coroutine.create(function()
			local obs = self:buildObservation(live)
			return obs and self:forward(obs) or 1
		end)
	end
	if self.job then
		if self.jobStarted > 0 and os.clock() - self.jobStarted > self.maxJobSeconds then
			self.job = nil
			self.jobStarted = 0
			self.actionIndex = nil
			warn("[Ripple] inference timed out; keeping the game responsive")
			self:applyAction(controls)
			return
		end
		local start = os.clock()
		self.deadline = start + self.budget
		local ok, result = coroutine.resume(self.job)
		self.spent += os.clock() - start
		if not ok then
			self.job = nil
			self.jobStarted = 0
			warn("[Ripple] inference failed:", result)
		elseif coroutine.status(self.job) == "dead" then
			self.job = nil
			self.jobStarted = 0
			self.actionIndex = result
		end
	end
	self:applyAction(controls)
end

Ripple.ACTIONS = ACTIONS

return Ripple
end)()
local ripple = Ripple.new({
    externalUrl = "http://127.0.0.1:8765/ripple",
    getLive = function() return live end,
    stateOf = stateOf,
    getPath = function() return path end,
    decisionEvery = 4,
    budget = 0.001,
    maxJobSeconds = 0.35,
})

---------------------------------------------------------------- step hooks
-- c: the controls about to be simulated for our car this tick
local function drive(c)
	local me = live.me
	if not me or Library.Unloaded then return end
	local st = stateOf(me.car)
	if Toggles.RippleBot.Value then
		if not _G.__rippleRequestProbeStarted then
			_G.__rippleRequestProbeStarted = true
			task.spawn(function()
				local requester
				pcall(function() requester = request end)
				if not requester then pcall(function() requester = http_request end) end
				if not requester then pcall(function() requester = syn and syn.request end) end
				if not requester then warn("[Ripple probe] request API unavailable") return end
				local ok, result = pcall(function()
					return requester({ Url = "http://127.0.0.1:8765/health", Method = "GET", Timeout = 0.25 })
				end)
				warn("[Ripple probe] health request", ok, result and (result.StatusCode or result.status_code or "ok") or result)
			end)
		end
		return
	end
	if Toggles.AutoFlip.Value and st.isOnGround and not dodge then
		local b = nearBall(st, Options.FlipRange.Value)
		if b then startDodge(st, b) end
	end
	local idleAir = math.abs(c.pitch) + math.abs(c.yaw) + math.abs(c.roll) < 0.1
	if Toggles.AutoRecover.Value and idleAir and not st.isOnGround and not st.isFlipping and not dodge then
		local v = flat(st.vel)
		recover(c, st, vector.magnitude(v) > 300 and v or nil)
	end
	runDodge(c)
end

local origPStep, origWStep = Prediction.step, World.step
Prediction.step = function(self, controls, ...)
	lastMatchAt = os.clock()
	live = fromMatch(self)
	-- only while the ball is live: goal replays, countdowns and the end screen keep stepping too
	if controls and self.match.phase == "play" then
		drive(controls)
		Protocol.quantize(controls) -- same rounding the game applies before step, so server and history agree
	end
	return origPStep(self, controls, ...)
end
World.step = function(self, ...)
	-- the menu/training world can keep ticking during a match; the match wins
	if os.clock() - lastMatchAt > 0.25 then
		if Motion.atMenu() then
			live = nil
		else
			live = fromWorld(self)
			drive(self.car.controls)
		end
	end
	return origWStep(self, ...)
end

---------------------------------------------------------------- visuals (Drawing)
local cam = workspace.CurrentCamera
local lines, texts = {}, {}
local landing = Drawing.new("Circle")
landing.Thickness, landing.NumSides, landing.Filled = 2, 24, false

local function line(i)
	local l = lines[i]
	if not l then l = Drawing.new("Line") l.Thickness = 2 lines[i] = l end
	return l
end
local function text(i)
	local t = texts[i]
	if not t then t = Drawing.new("Text") t.Size, t.Center, t.Outline = 16, true, true texts[i] = t end
	return t
end
local function screen(uu)
	local v, on = cam:WorldToViewportPoint(Units.pos(uu))
	return Vector2.new(v.X, v.Y), on
end

local function draw()
	local n = 0
	landing.Visible = false
	if Toggles.BallPath.Value and #path > 1 then
		local col = Options.PathColor.Value
		local prev, prevOn = screen(live.ball.body.pos)
		for _, pt in path do
			local s, on = screen(pt.pos)
			if on and prevOn then
				n += 1
				local l = line(n)
				l.From, l.To, l.Color, l.Visible = prev, s, col, true
			end
			prev, prevOn = s, on
		end
		for _, pt in path do
			if pt.pos.z < 110 then
				local s, on = screen(pt.pos)
				if on then
					landing.Position, landing.Radius, landing.Color, landing.Visible = s, 12, col, true
				end
				break
			end
		end
	end
	for i = n + 1, #lines do lines[i].Visible = false end

	local m = 0
	local me = live and live.me
	if Toggles.BoostESP.Value and live then
		for _, e in live.cars do
			if e ~= me and not e.car.isDemoed then
				local s, on = screen(e.car.body.pos + vector.create(0, 0, 90))
				if on then
					m += 1
					local t = text(m)
					t.Text = string.format("%d", math.floor(e.car.boost))
					t.Color = (me and e.team == me.team) and Color3.fromRGB(90, 170, 255) or Color3.fromRGB(255, 110, 60)
					t.Position, t.Visible = s, true
				end
			end
		end
	end
	for i = m + 1, #texts do texts[i].Visible = false end
end

local conn = RunService.RenderStepped:Connect(function()
	local ok, err = pcall(function()
		local want = Toggles.BallPath.Value or Toggles.AutoFlip.Value
		if want then predictBall(Options.PathSeconds.Value) else table.clear(path) end
		draw()
	end)
	ripple.spent = 0
	if not ok then warn("[Catware]", err) end
end)

---------------------------------------------------------------- UI
local hasExecutor, executorName = pcall(identifyexecutor)
local Window = Library:CreateWindow({ Title = "Catware", Footer = "Turbo Soccer | " .. (hasExecutor and executorName or "Unknown"), Icon = "cat", NotifySide = "Right", ShowCustomCursor = false })
local Tabs = {
	Main = Window:AddTab("Main", "car"),
	Visuals = Window:AddTab("Visuals", "eye"),
	["UI Settings"] = Window:AddTab("UI Settings", "settings"),
}

local Bot = Tabs.Main:AddLeftGroupbox("Bot", "bot")
Bot:AddToggle("RippleBot", { Text = "Ripple probe (health request only)", Default = false, Risky = true,
    Tooltip = "Ripple v1.1 via local ONNX Runtime service." })
    :AddKeyPicker("RippleBotKey", { Default = "N", SyncToggleState = true, Mode = "Toggle", Text = "Ripple" })

local Assist = Tabs.Main:AddRightGroupbox("Assists", "hand-helping")
Assist:AddToggle("AutoFlip", { Text = "Auto flip into ball", Default = false, Tooltip = "Front/diagonal dodge when the ball is about to reach you" })
Assist:AddSlider("FlipRange", { Text = "Flip range (uu)", Default = 240, Min = 150, Max = 450, Rounding = 0 })
Assist:AddToggle("AutoRecover", { Text = "Auto air recovery", Default = false, Tooltip = "Lands you on wheels when you're not touching air controls" })

local Vis = Tabs.Visuals:AddLeftGroupbox("Ball", "circle")
Vis:AddToggle("BallPath", { Text = "Ball prediction path", Default = true })
	:AddColorPicker("PathColor", { Default = Color3.fromRGB(255, 220, 60) })
Vis:AddSlider("PathSeconds", { Text = "Prediction seconds", Default = 2, Min = 1, Max = 6, Rounding = 1 })
Tabs.Visuals:AddRightGroupbox("Cars", "car"):AddToggle("BoostESP", { Text = "Boost amount over cars", Default = true })

local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")
-- queue ourselves on teleport (server hops, private servers, tournaments) so Catware comes along
local AUTOLOAD_FLAG = DIR .. "autoload"
local LOADER = 'if not game:IsLoaded() then game.Loaded:Wait() end local p = "' .. DIR .. 'catware.lua" '
	.. 'loadstring(isfile(p) and readfile(p) or game:HttpGet(SCRIPT_URL))()'
MenuGroup:AddToggle("AutoLoad", { Text = "Auto-load after teleport", Default = isfile(AUTOLOAD_FLAG),
	Tooltip = "Re-runs Catware when you teleport to another Turbo Soccer server" })
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })
MenuGroup:AddButton("Unload", function() Library:Unload() end)
Library.ToggleKeybind = Options.MenuKeybind

Toggles.AutoLoad:OnChanged(function(on)
	if on then
		if not isfolder("Catware") then makefolder("Catware") end
		if not isfolder(DIR) then makefolder(DIR) end
		writefile(AUTOLOAD_FLAG, "1")
	elseif isfile(AUTOLOAD_FLAG) then
		delfile(AUTOLOAD_FLAG)
	end
end)
local queued = false
local teleportConn = LP.OnTeleport:Connect(function(state)
	if state == Enum.TeleportState.Started and Toggles.AutoLoad.Value and not queued then
		queued = true -- Started can fire again on retries; queue once
		queue_on_teleport(LOADER)
	end
end)

getgenv().CatwareTurboSoccerUnload = function() Library:Unload() end
Library:OnUnload(function()
	getgenv().CatwareTurboSoccerUnload = nil
	teleportConn:Disconnect()
	conn:Disconnect()
	Prediction.step, World.step = origPStep, origWStep
	for _, d in lines do d:Remove() end
	for _, d in texts do d:Remove() end
	landing:Remove()
end)

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind", "AutoLoad" }) -- AutoLoad lives in its own flag file
ThemeManager:SetFolder("Catware/TurboSoccer")
SaveManager:SetFolder("Catware/TurboSoccer")
SaveManager:BuildConfigSection(Tabs["UI Settings"])
ThemeManager:SetDefaultTheme(ThemeManager.BuiltInThemes["Catppuccin"][2])
ThemeManager:ApplyToTab(Tabs["UI Settings"])
SaveManager:LoadAutoloadConfig()