-- 侧身节奏滤镜：对摄像头画面实时生效，一轮 3 秒（可调），5 种形态循环
-- 正常 / 平移黑边 / 分身 / 推近闪白 / 左侧叠影
-- 写法照 OFLua 模板库里的 duplicate.lua / flash_size.lua（createCustomShaderPass + sharedQuadRender）
-- 状态：shader 已在 WebGL 里验证过能编译并出画面；Lua 外壳还没有在 OrangeFilter Designer 里验证通过
-- 排查：把 Force 设成 3，画面应该立刻变成推近闪白；若没变化说明滤镜根本没跑起来（加载失败 / shader 在引擎里编译失败）
--       Force=-1 时不循环，说明时间没在走，换 TimeSource 试 1 或 2

local VS = [[
    precision highp float;

    attribute vec4 aPosition;
    attribute vec4 aTextureCoord;
    varying vec2 vTexCoord;

    void main()
    {
        gl_Position = aPosition;
        vTexCoord = aTextureCoord.xy;
    }
]]

local FS = [[
    precision highp float;

    varying vec2 vTexCoord;
    uniform sampler2D uTexture0;
    uniform float uTime;        // 秒，filter:filterTimestamp()
    uniform float uCycle;       // 一轮的时长（秒）
    uniform float uSlide;       // 平移幅度
    uniform float uCloneStep;   // 分身错开的距离
    uniform float uZoom;        // 推近倍数
    uniform float uFlash;       // 闪白强度系数
    uniform float uGhost;       // 左侧叠影强度
    uniform float uForce;       // 调试：>=0 时固定显示第几段，-1 为自动循环


    const float FADE = 0.04;    // 形态切换的交叉淡化（以 3 秒为基准的秒数）

    vec4 tex(vec2 uv)
    {
        return texture2D(uTexture0, clamp(uv, vec2(0.001), vec2(0.999)));
    }

    // 平移：整体横移，露出黑边
    vec4 formSlide(vec2 uv, float dx)
    {
        vec2 p = vec2(uv.x - dx, uv.y);
        if (p.x < 0.0 || p.x > 1.0) {
            return vec4(0.0, 0.0, 0.0, 1.0);
        }
        return tex(p);
    }

    // 分身：同一张画面左右错开叠几份，取暗
    vec4 formClone(vec2 uv, float stepX, float third)
    {
        vec4 c = min(tex(uv), tex(uv - vec2(stepX, 0.0)));
        if (third > 0.5) {
            c = min(c, tex(uv + vec2(stepX, 0.0)));
        }
        return c;
    }

    // 推近 + 闪白
    vec4 formZoom(vec2 uv, float s, float flash)
    {
        vec2 c = vec2(0.5, 0.45);
        vec4 col = tex(c + (uv - c) / s);
        col.rgb = mix(col.rgb, vec3(1.0), clamp(flash, 0.0, 1.0));
        return col;
    }

    // 左侧叠影：公式取自 one_split_screen_filter 的 left_overlay
    vec4 formGhost(vec2 uv)
    {
        vec4 base = tex(uv);
        vec2 g = vec2(0.43, 0.30) + (uv - vec2(0.12, 0.15)) / 1.85;
        float mask = (1.0 - smoothstep(0.34, 0.68, uv.x))
                   * smoothstep(-0.02, 0.12, uv.x)
                   * smoothstep(-0.04, 0.10, uv.y)
                   * (1.0 - smoothstep(0.98, 1.08, uv.y))
                   * uGhost;
        base.rgb = clamp(mix(base.rgb, tex(g).rgb, mask), 0.0, 1.0);
        return base;
    }

    // 第 i 段用哪种形态
    vec4 segment(float i, vec2 uv)
    {
        if (i < 0.5) { return tex(uv); }
        if (i < 1.5) { return formSlide(uv, uSlide); }
        if (i < 2.5) { return formClone(uv, uCloneStep, 0.0); }
        if (i < 3.5) { return formZoom(uv, uZoom, 0.30 * uFlash); }
        if (i < 4.5) { return formSlide(uv, -uSlide * 1.4); }
        if (i < 5.5) { return formGhost(uv); }
        if (i < 6.5) { return formClone(uv, uCloneStep * 0.9, 1.0); }
        if (i < 7.5) { return formZoom(uv, uZoom * 1.12, 0.35 * uFlash); }
        return tex(uv);
    }

    // 返回 (段序号, 该段起始时间)，时间以 3 秒为基准
    vec2 locate(float t)
    {
        float i = 0.0;
        float s = 0.0;
        if (t >= 0.30) { i = 1.0; s = 0.30; }
        if (t >= 0.70) { i = 2.0; s = 0.70; }
        if (t >= 1.00) { i = 3.0; s = 1.00; }
        if (t >= 1.30) { i = 4.0; s = 1.30; }
        if (t >= 1.70) { i = 5.0; s = 1.70; }
        if (t >= 2.10) { i = 6.0; s = 2.10; }
        if (t >= 2.50) { i = 7.0; s = 2.50; }
        if (t >= 2.80) { i = 8.0; s = 2.80; }
        return vec2(i, s);
    }

    void main()
    {
        vec2 uv = vTexCoord;
        if (uForce > -0.5) {
            gl_FragColor = segment(floor(uForce + 0.5), uv);
            return;
        }
        float t = mod(uTime, uCycle) / uCycle * 3.0;
        vec2 loc = locate(t);
        vec4 col = segment(loc.x, uv);
        float since = t - loc.y;
        if (loc.x > 0.5 && since < FADE) {
            col = mix(segment(loc.x - 1.0, uv), col, smoothstep(0.0, FADE, since));
        }
        gl_FragColor = col;
    }
]]

local _pass = nil

function initRenderer(context, filter)
    _pass = context:createCustomShaderPass(VS, FS)
    return OF_Result_Success
end

function teardownRenderer(context, filter)
    context:destroyCustomShaderPass(_pass)
    _pass = nil
    return OF_Result_Success
end

function initParams(context, filter)
    filter:insertFloatParam("Cycle", 0.5, 10.0, 3.0)
    filter:insertFloatParam("Slide", 0.0, 0.5, 0.14)
    filter:insertFloatParam("CloneStep", 0.0, 0.5, 0.22)
    filter:insertFloatParam("Zoom", 1.0, 3.0, 1.6)
    filter:insertFloatParam("Flash", 0.0, 2.0, 1.0)
    filter:insertFloatParam("Ghost", 0.0, 1.0, 0.4)
    -- 调试用：Force 填 0~8 固定看某一段（0 正常 1 平移 2 分身 3 推近 4 反向平移 5 叠影 6 三分身 7 大推近 8 正常），-1 为自动循环
    filter:insertFloatParam("Force", -1.0, 8.0, -1.0)
    -- 时间来源：0 = filter:filterTimestamp()  1 = frameData.timestamp  2 = context:currentTime()
    filter:insertFloatParam("TimeSource", 0.0, 2.0, 0.0)
    return OF_Result_Success
end

local TAG = "side_cycle"
local _lastLogSec = -1

local function currentTimeSec(context, filter, frameData)
    local src = math.floor(filter:floatParam("TimeSource") + 0.5)
    local t
    if src == 1 then
        t = frameData.timestamp
    elseif src == 2 then
        t = context:currentTime()
    else
        t = filter:filterTimestamp()
    end
    -- 每秒在 Designer 日志里打一行，方便确认时间有没有在走
    local sec = math.floor(t)
    if sec ~= _lastLogSec then
        _lastLogSec = sec
        OF_LOGI(TAG, "time source " .. tostring(src) .. " = " .. tostring(t))
    end
    return t
end

function onApplyParams(context, filter)
    return OF_Result_Success
end

function readObject(context, filter, archiveIn)
    return OF_Result_Success
end

function writeObject(context, filter, archiveOut)
    return OF_Result_Success
end

function requiredFrameData(context, filter)
    return { OF_RequiredFrameData_None }
end

function applyRGBA(context, filter, frameData, inTex, outTex, debugTex)
    local render = context:sharedQuadRender()

    context:setViewport(0, 0, outTex.width, outTex.height)
    context:setBlend(false)
    context:setClearColor(0.0, 0.0, 0.0, 0.0)
    context:clearColorBuffer()
    context:clearDepthBuffer()

    context:bindFBO(outTex)
    _pass:use()
    _pass:setUniformTexture("uTexture0", 0, inTex.textureID, GL_TEXTURE_2D)
    _pass:setUniform1f("uTime", currentTimeSec(context, filter, frameData))
    _pass:setUniform1f("uForce", filter:floatParam("Force"))
    _pass:setUniform1f("uCycle", filter:floatParam("Cycle"))
    _pass:setUniform1f("uSlide", filter:floatParam("Slide"))
    _pass:setUniform1f("uCloneStep", filter:floatParam("CloneStep"))
    _pass:setUniform1f("uZoom", filter:floatParam("Zoom"))
    _pass:setUniform1f("uFlash", filter:floatParam("Flash"))
    _pass:setUniform1f("uGhost", filter:floatParam("Ghost"))
    render:draw(_pass, false)

    if debugTex ~= nil then
        context:copyTexture(inTex, debugTex)
    end
    return OF_Result_Success
end
