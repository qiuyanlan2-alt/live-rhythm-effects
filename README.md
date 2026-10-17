# live-rhythm-effects
直播律动特效。自己写着玩的，可公开版^^

对摄像头画面实时生效的 OrangeFilter（OF）Lua 滤镜，用 OF Designer 加载。

## side_cycle：侧身节奏滤镜
一轮 3 秒（可调），5 种形态循环：正常 / 平移黑边 / 分身 / 推近闪白 / 左侧叠影。

参数：Cycle（一轮时长）、Slide、CloneStep、Zoom、Flash、Ghost。
调试用：Force 设为 3 画面应立刻变成推近闪白；Force 为 -1 时自动循环；循环不动时把 TimeSource 换成 1 或 2。

状态：shader 在 WebGL 里验证过能编译并出画面，Lua 外壳还没有在 Designer 里验证通过。

## echo_split：动感分屏（叠影版）
默认 20 秒一轮：
- 0 到 1 秒：开场冲击，放大加径向模糊，硬分屏。
- 1 到 9 秒：3 个分屏同步画面，保持稳定。
- 9 秒起：切 5 屏，相邻屏柔和叠影，两侧屏带延迟残影，11 秒有一次冲击加闪白。
- 15 到 17 秒：切回 3 屏，叠影淡出。

参数：Cycle、BPM、BeatZoom、EchoFrames（残影落后帧数）、Wide、Overlap（叠影程度，0 为硬分屏）、Hold（定在某一秒调试，-1 为自动播放）。

状态：用 Designer 的测试视频渲染验证过无报错、画面符合时间线；没有在真实摄像头和实际直播里测过，流畅度未确认。

## 使用
把对应文件夹放进 OF 特效目录，在 Designer 里打开 `effect0.ofeffect`（echo_split）或加载 `side_cycle.lua`。
