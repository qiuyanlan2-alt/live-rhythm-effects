local TAG = "echo_split"

-- 动感分屏（残影版）：3 屏 <-> 5 屏 切换，两侧屏显示延迟残影，带节拍冲击缩放 / 运动模糊 / 紫蓝调色
-- 时间线（秒，随 Cycle 等比缩放）见 timeline()

local vertexShader = [[
    precision highp float;
    attribute vec3 aPosition;
    attribute vec2 aTextureCoord;
    varying vec2 vTexCoord;
    void main() {
        gl_Position = vec4(aPosition, 1.0);
        vTexCoord = aTextureCoord;
    }
]]

local fragmentShader = [[
    precision highp float;
    varying vec2 vTexCoord;
    uniform sampler2D uTexture;   // 实时画面
    uniform sampler2D uE1;        // 残影 1..4（由近到远）
    uniform sampler2D uE2;
    uniform sampler2D uE3;
    uniform sampler2D uE4;
    uniform float u_mix;    // 0 = 3 屏, 1 = 5 屏
    uniform float u_echo;   // 0 = 各屏同步, 1 = 两侧屏延迟残影
    uniform float u_punch;  // 冲击缩放 0..1
    uniform float u_blur;   // 径向模糊强度
    uniform float u_overlap; // 相邻屏重叠 0=硬分屏 1=最大叠影


    uniform float u_wide;   // 每屏取景范围 0.5..1
    uniform float u_flash;  // 闪白

    vec4 tapTex(int k, vec2 p) {
        if (k <= 0) return texture2D(uTexture, p);
        if (k == 1) return texture2D(uE1, p);
        if (k == 2) return texture2D(uE2, p);
        if (k == 3) return texture2D(uE3, p);
        return texture2D(uE4, p);
    }

    // 叠影分屏：每屏是整幅画面的平移副本，相邻屏边缘柔和重叠、加权混合
    vec3 panel(float n, vec2 uv) {
        float center = (n - 1.0) * 0.5;
        float hw = (0.5 + 0.5 * u_overlap) / n;           // 每屏半宽（含重叠区）
        float inner = 0.5 / n * (1.0 - u_overlap);        // 内部完全不透明的半宽
        float s0 = u_wide / (1.0 + 0.45 * u_punch);
        vec3 acc = vec3(0.0);
        float wacc = 0.0;
        for (int j = 0; j < 5; j++) {
            if (float(j) < n) {
                float c = (float(j) + 0.5) / n;
                float d = abs(uv.x - c);
                if (d < hw) {
                    float t = clamp((d - inner) / max(hw - inner, 0.0001), 0.0, 1.0);
                    float w = 1.0 - t * t * (3.0 - 2.0 * t);
                    if (w > 0.0) {
                        int k = int(abs(float(j) - center) + 0.5);
                        int kk = int(mix(0.0, float(k), u_echo) + 0.5);
                        vec3 col = vec3(0.0);
                        float ws = 0.0;
                        for (int i = -2; i <= 2; i++) {
                            if (u_blur < 0.003 && i != 0) continue;  // 无模糊时只采 1 次，省性能
                            float wt = 1.0 - abs(float(i)) * 0.25;
                            // 径向模糊：按不同缩放向外采样
                            float s = s0 * (1.0 - u_blur * float(i) / 2.0);
                            vec2 q = vec2(0.5 + (uv.x - c) * s, 0.5 + (uv.y - 0.5) * s);
                            col += tapTex(kk, clamp(q, 0.0, 1.0)).rgb * wt;
                            ws += wt;
                        }
                        acc += col / ws * w;
                        wacc += w;
                    }
                }
            }
        }
        return acc / max(wacc, 0.0001);
    }

    void main() {
        vec2 uv = vTexCoord;
        vec3 c;
        if (u_mix < 0.001) c = panel(3.0, uv);
        else if (u_mix > 0.999) c = panel(5.0, uv);
        else c = mix(panel(3.0, uv), panel(5.0, uv), u_mix);
        c += vec3(u_flash * 0.18);
        gl_FragColor = vec4(c, 1.0);
    }
]]

local copyShader = [[
    precision highp float;
    varying vec2 vTexCoord;
    uniform sampler2D uTexture;
    void main() {
        gl_FragColor = texture2D(uTexture, vTexCoord);
    }
]]

local _pass = nil
local _copy = nil


-- 残影环：RING_N 帧循环缓冲（复用纹理，不逐帧分配）
local RING_N = 48
local _ring = {}
local _ringW, _ringH = 0, 0
local _head, _count = 0, 0
local _sel = { 0, 0, 0, 0 }
local _eNames = { "uE1", "uE2", "uE3", "uE4" }

local function clamp01(x)
    if x < 0.0 then return 0.0 end
    if x > 1.0 then return 1.0 end
    return x
end

local function smooth(a, b, x)
    local t = clamp01((x - a) / (b - a))
    return t * t * (3.0 - 2.0 * t)
end

-- 冲击：在 t0 时刻触发，dur 秒内衰减
local function hit(t, t0, dur)
    if t < t0 or t > t0 + dur then return 0.0 end
    local k = 1.0 - (t - t0) / dur
    return k * k * k
end

-- 返回 mix, echo, punch, blur, flash（t 为 0..20 的归一化时间线）
-- 0~1s 开场冲击（放大 + 径向模糊）；1~9s 保持三屏同步；9s 起切 5 屏 + 残影
local function timeline(t)
    local mix = smooth(9.0, 10.0, t) - smooth(15.0, 16.0, t)
    local echo = smooth(9.0, 10.0, t) - smooth(18.0, 20.0, t)
    local intro = hit(t, 0.0, 1.0)
    local punch = math.max(intro, hit(t, 9.0, 0.8), hit(t, 11.0, 0.9), hit(t, 15.0, 0.8))
    local blur = intro * 0.30 + math.max(hit(t, 9.0, 0.8), hit(t, 11.0, 0.9), hit(t, 15.0, 0.8)) * 0.12
    local flash = hit(t, 11.0, 0.25)
    return mix, echo, punch, blur, flash
end

local function releaseRing(context)
    for i = 1, #_ring do
        context:releaseTexture(_ring[i].tex)
    end
    _ring = {}
    _ringW, _ringH = 0, 0
    _count, _head = 0, 0
end

-- 用直通 pass 把 inTex 画进缓存纹理（getTexture 得到的纹理不走 copyTexture）
local function drawInto(context, dst, src, w, h)
    context:bindFBO(dst:toOFTexture())
    context:setViewport(0, 0, w, h)
    context:setBlend(false)
    _copy:use()
    _copy:setUniformTexture("uTexture", 0, src.textureID, GL_TEXTURE_2D)
    context:sharedQuadRender():draw(_copy, false)
end

-- 逐帧入环（半分辨率），按时间戳取 k*EchoStep 秒前的帧，残影随画面连续运动
local function ensureRing(context, w, h)
    local hw, hh = math.max(2, math.floor(w / 2)), math.max(2, math.floor(h / 2))
    if #_ring == RING_N and _ringW == hw and _ringH == hh then return hw, hh end
    releaseRing(context)
    for i = 1, RING_N do
        _ring[i] = { tex = context:getTexture(hw, hh), t = 0.0 }
    end
    _ringW, _ringH = hw, hh
    return hw, hh
end

local _lastPush = -1000.0
local function pushRing(context, inTex, now, hw, hh)
    -- 时间回退 / 长时间没入环（历史已过期）：清空
    if _count > 0 and (now < _lastPush - 0.0001 or now - _lastPush > 0.25) then _count = 0 end
    if _count > 0 and math.abs(now - _lastPush) < 0.0001 then
        drawInto(context, _ring[_head].tex, inTex, hw, hh)  -- 同一时刻重复调用：覆盖，不前进
    else
        _head = _head % RING_N + 1
        drawInto(context, _ring[_head].tex, inTex, hw, hh)
        _count = math.min(_count + 1, RING_N)
    end
    _lastPush = now
end

-- 取 frames 帧之前的画面（按帧数而不是时间戳，不受时间戳抖动影响）；历史不足时取最旧一帧
local function pick(frames)
    local n = math.min(frames, _count - 1)
    if n < 0 then n = 0 end
    local idx = _head - n
    if idx < 1 then idx = idx + RING_N end
    return _ring[idx].tex
end
function subType(context, filter)
    return "echo_split"
end

function initParams(context, filter)
    filter:insertFloatParam("Cycle", 8.0, 60.0, 20.0)
    filter:insertFloatParam("BPM", 60.0, 180.0, 120.0)
    filter:insertFloatParam("BeatZoom", 0.0, 1.0, 0.12)
    filter:insertFloatParam("EchoFrames", 1.0, 8.0, 2.0)
    filter:insertFloatParam("Wide", 0.5, 1.0, 1.0)


    filter:insertFloatParam("Overlap", 0.0, 1.0, 0.7)
    filter:insertFloatParam("Hold", -1.0, 60.0, -1.0)
    return OF_Result_Success
end

function onApplyParams(context, filter)
    return OF_Result_Success
end

function initRenderer(context, filter)
    OF_LOGI(TAG, "call initRenderer")
    _pass = context:createCustomShaderPass(vertexShader, fragmentShader)
    _copy = context:createCustomShaderPass(vertexShader, copyShader)
    return OF_Result_Success
end

function teardownRenderer(context, filter)
    releaseRing(context)
    if _pass ~= nil then
        context:destroyCustomShaderPass(_pass)
        _pass = nil
    end
    if _copy ~= nil then
        context:destroyCustomShaderPass(_copy)
        _copy = nil
    end
    return OF_Result_Success
end

function applyRGBA(context, filter, frameData, inTex, outTex, debugTex)
    if not _pass then
        context:copyTexture(inTex, outTex)
        return OF_Result_Success
    end
    local w = math.floor(outTex.width)
    local h = math.floor(outTex.height)

    local now = filter:filterTimestamp()
    local hold = filter:floatParam("Hold")
    if hold >= 0.0 then now = hold end
    local cycle = filter:floatParam("Cycle")
    local t = (now % cycle) / cycle * 20.0

    local mix, echo, punch, blur, flash = timeline(t)
    local beatLen = 60.0 / filter:floatParam("BPM")
    local beat = math.exp(-((now % beatLen) / beatLen) * 6.0)
    if t >= 1.0 and t < 9.0 then beat = 0.0 end  -- 1~9s 保持画面稳定
    punch = math.max(punch, beat * filter:floatParam("BeatZoom"))

    -- 只在切 5 屏前后记录历史（0~7.5s 不需要残影，省掉每帧一次拷贝）
    if t >= 7.5 then
        local hw, hh = ensureRing(context, w, h)
        pushRing(context, inTex, now, hw, hh)
    end
    local D = math.floor(filter:floatParam("EchoFrames") + 0.5)
    for i = 1, 4 do
        if _count > 0 then
            _sel[i] = pick(i * D):toOFTexture().textureID
        else
            _sel[i] = inTex.textureID
        end
    end

    context:bindFBO(outTex)
    context:setViewport(0, 0, w, h)
    context:setBlend(false)
    context:setClearColor(0.0, 0.0, 0.0, 0.0)
    context:clearColorBuffer()

    _pass:use()
    _pass:setUniformTexture("uTexture", 0, inTex.textureID, GL_TEXTURE_2D)
    for i = 1, 4 do
        _pass:setUniformTexture(_eNames[i], i, _sel[i], GL_TEXTURE_2D)
    end
    _pass:setUniform1f("u_mix", mix)
    _pass:setUniform1f("u_echo", echo)
    _pass:setUniform1f("u_punch", punch)
    _pass:setUniform1f("u_blur", blur)


    _pass:setUniform1f("u_overlap", filter:floatParam("Overlap") * (smooth(9.0, 10.0, t) - smooth(16.0, 17.0, t)))  -- 0~9s 硬分屏，之后才叠影
    _pass:setUniform1f("u_wide", filter:floatParam("Wide"))
    _pass:setUniform1f("u_flash", flash)
    context:sharedQuadRender():draw(_pass, false)
    return OF_Result_Success
end

function requiredFrameData(context, filter)
    return { OF_RequiredFrameData_None }
end

function restartAnimation(context, filter)
    _count = 0
end

function readObject(context, filter, archiveIn)
    return OF_Result_Success
end

function writeObject(context, filter, archiveOut)
    return OF_Result_Success
end

