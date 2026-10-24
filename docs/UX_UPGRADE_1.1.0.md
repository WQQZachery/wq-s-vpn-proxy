# WQ's Proxy VPN 1.1.0 — UI 与核心体验升级说明

日期：2026-10-24（Asia/Shanghai）。版本 `1.1.0+2`。包名不变。

> 本次只改动界面、动画、检测与测速逻辑；**未改动** sing-box 内核接入、Kotlin VpnService、配置生成、
> 节点解析/订阅/编辑/持久化、路由模式、安全存储与日志脱敏。

## 一、修改文件清单

| 文件 | 类型 | 目的 |
|---|---|---|
| `lib/app/theme.dart` | 重写 | 全局视觉系统：颜色/间距/圆角/字号层级/动效时长常量，统一 Card、输入框、Chip、按钮、对话框、底部弹层、SnackBar；新增 `PageHeader`、`SectionTitle(info)`、`InfoTip`、`AppCard`、`StatusPill`、`EmptyState`、`KvRow`、`SwapSwitcher`、`Motion.reduced` |
| `lib/app/ripple_nav.dart` | 新增 | 底部导航水波扩散 + 页面 fade-through 转场容器 |
| `lib/main.dart` | 修改 | 使用 `RippleNavShell`；节点页接收“是否可见”以触发自动检测 |
| `lib/features/dashboard/connect_orb.dart` | 新增 | 由真实 VPN 状态驱动的连接按钮动效（CustomPainter） |
| `lib/features/dashboard/live_speed_chart.dart` | 新增 | 平滑滚动的实时网速曲线（Ticker + CustomPainter，局部重绘） |
| `lib/core/engine/chart_math.dart` | 新增 | 单调三次插值、刻度取整、与帧率无关的平滑、采样间隔估计（纯函数，可测） |
| `lib/features/dashboard/dashboard_page.dart` | 重写 | 新首页布局；连接防重复点击/状态锁定/连接中可取消；会话计时只重建一行 |
| `lib/core/engine/latency_tester.dart` | 新增 | 节点延迟调度器：分层、并发上限、错峰、冷却、复用、取消、错误归类 |
| `lib/app/state.dart` | 修改 | 节点检测改用调度器；`NodesState.latency` 区分本次结果与历史缓存；VPN 开关后作废旧结果；`connect()` 重入保护；provider 释放后不再写状态 |
| `lib/core/networking/probes.dart` | 修改 | 新增严格校验证书的 `tlsHandshake` |
| `lib/features/profiles/profiles_page.dart` | 重写顶部与列表 | 标题/检测状态/搜索筛选形成连续头部（搜索栏吸顶），节点列表为一个整体分组；固定宽度延迟徽标；选中/使用中区分；进入页面自动检测 |
| `lib/core/reputation/ip_reputation.dart` | 修改 | 报告保留原始字段并提供类型化读取；失败原因分类；读取每日配额响应头；数据不完整时报“数据缺失” |
| `lib/features/diagnostics/reputation_panel.dart` | 新增 | IP 信誉新界面：AbuseIPDB 说明、配置方法、分数环、举报情况、字段中文释义、各类失败状态、免责声明 |
| `lib/features/diagnostics/diagnostics_page.dart` | 重写界面 | 检测中心重排：测速入口卡、出口 IP 与信誉合并卡（一键查询）、连通性检测、历史 |
| `lib/core/networking/speedtest/throughput.dart` | 新增 | 吞吐与延迟统计（原始值、预热排除、窗口截止、中位数/抖动、仪表刻度） |
| `lib/core/networking/speedtest/speedtest_engine.dart` | 新增 | 测速引擎：服务器发现与选择、延迟、下载、上传（M-Lab ndt7 + Cloudflare） |
| `lib/features/speedtest/speed_gauge.dart` | 新增 | Speedtest 风格仪表盘 + 原始速度折线 |
| `lib/features/speedtest/speedtest_page.dart` | 新增 | 主动测速页：阶段条、仪表、结果、服务器选择、摘要、失败/取消反馈 |
| `lib/core/networking/speed_test.dart` | 删除 | 被新测速引擎取代 |
| `lib/features/settings/settings_page.dart` | 修改 | 统一页头；API Key 说明；不再显示 Key 位数；版本 1.1.0 |
| `test/ux_upgrade_test.dart` | 新增 | 34 个单元/组件测试 |
| `test/app_shell_test.dart` | 新增 | 3 个整壳组件测试（小屏 + 1.3 倍字体逐页渲染、空状态、未配置 Key、打开测速页） |
| `tool/speedtest_smoke.dart` | 新增 | 开发机真实网络测速冒烟脚本 |
| `tool/screens/screens_test.dart` | 新增 | 开发机截图渲染（视觉检查用，不属于常规测试） |

## 二、核心实现说明

### 1. 连接 / 断开动画（`connect_orb.dart`）
- 显示阶段 `OrbPhase` 只由原生上报的 `VpnState` 推导，外加“请求已发出”的本地标志（显示为“准备中”）。
  `started` 之外的任何状态都不会映射为“已连接”（有单测穷举验证），所以失败时不可能出现成功动画。
- 准备/连接中：主色渐变弧线旋转；断开中：弧线反向旋转并转为琥珀色；已连接：绿色实环 + 一次性扩散波纹 + 缓慢呼吸光晕；
  失败：红环 + 一次轻微抖动 + 触觉反馈。颜色用 `ColorTween` 平滑过渡，文字用淡入上移切换。
- 5 个 `AnimationController` 只在 `initState` 创建、`dispose` 释放；光晕用径向渐变绘制而非 `BoxShadow`，避免每帧模糊。
- 防重复：首页 `_busy` + 控制器 `_connecting` 双重保护；断开中锁定；连接中轻点 = 取消。配置校验/授权失败只在界面显示失败，不伪造 VPN 状态。
- 系统“减少动态效果”开启时只保留颜色变化，不运行循环动画。

### 2. 实时网速曲线（`live_speed_chart.dart` + `chart_math.dart`）
- 数据源不变：Kotlin 每 500 ms 上报 sing-box 内核的累计字节，`TrafficMeter` 换算速度/峰值/累计（保留 160 个采样）。
- 绘制与采样解耦：`Ticker` 按屏幕刷新率重绘，仅重绘 `RepaintBoundary` 内的 `CustomPaint`，页面本身仍按采样频率（2 Hz）重建数字。
- 平滑滚动：画面时间 = 现在 − 约 1.15 个采样间隔，最新真实点从右边缘连续“长出”；线头位于两次真实采样之间时，用
  Fritsch–Carlson 单调三次 Hermite 插值求值并用 de Casteljau 截断贝塞尔段。**插值不越过相邻两次实测值（单测随机 200 组验证）、
  不外推**；数据迟到时线头停在最后一个真实点，恢复后以 ≤1.6 倍速追赶，不跳变。
- 纵轴上限取整刻度并按时间常数平滑（与 60/120 Hz 无关），流量突增/回落不闪烁；最小量程 100 Kbps，空闲时不放大噪声。
- 下载（蓝，带渐变填充）与上传（绿）两条线，图例与单位一致；曲线说明见“实时速度”旁的 ⓘ。

### 3. 节点自动延迟检测（`latency_tester.dart` + `state.dart`）
- 进入节点页（转场结束后 280 ms）自动检测已启用节点；30 秒冷却，2 分钟内的本次结果直接复用；正在排队/检测的节点不会重复加入。
- 并发 4，worker 启动错峰 60 ms；结果按节点 id 写入 Map，列表项 `ValueKey(node.id)`，重建不会错位。
- 分层检测并明确标注：VPN 开启 → **代理请求**（Clash API 让 sing-box 经该节点请求 generate_204）；VPN 未开启 → **仅 TCP**，
  对非 REALITY 的 TLS 节点再做一次严格校验证书的 **TLS 握手**。Hysteria2/TUIC（UDP/QUIC）不做无意义的 TCP 探测，标“不适用，需连接 VPN”。
  VPN 开启时不做本机 TCP 探测（会被 TUN 本地应答，结果无意义）。
- 状态：未检测 / 排队中 / 检测中 / 成功(ms + 层级) / 超时 / 失败(原因) / 不适用 / 已取消；数据库中的历史结果显示为“上次 …”，与本次实时结果区分。
- 支持取消（排队中的立即取消；进行中的有 5 秒超时，完成后仍记录真实结果）、单个重新检测、全部重测。VPN 连接/断开后作废本次结果（检测层级已变化）。

### 4. IP 信誉（`reputation_panel.dart`）
- 显示出口 IP、查询状态（成功/缓存/未配置 Key/额度受限/Key 无效/网络失败/服务异常/数据缺失）、滥用置信度分数环与分档说明、
  90 天举报次数与举报者数、最近举报时间、用途分类、ISP/域名、国家代码、Tor、白名单、数据时间、今日剩余额度（响应头有返回时）。
- 每个字段有中文 ⓘ 解释；页面明确区分 IP 信誉 / 节点延迟 / 速度 / 隐私安全，并提示“不能凭单一分数断言安全或危险”。
- 未配置 Key 时给出注册与配置步骤、用途和存储方式；Key 仅存于安全存储，不进日志、不进 SQLite、不进仓库。

### 5. 主动测速（`speedtest_engine.dart` + `speedtest_page.dart`）
- **端点验证（2026-10-24 在开发机实测）**：
  - Cloudflare `speed.cloudflare.com/__down`、`/__up` 可用；原生 HttpClient 不受 CORS 约束。但**连续大流量测试后返回 HTTP 429 限流**（已实际遇到）；
    该端点没有单独发布 API 条款；响应头 `city/country` 是**客户端**位置，`colo` 才是数据中心代码。
  - M-Lab ndt7：`locate.measurementlab.net/v2/nearest/ndt/ndt7` 返回 4 台附近服务器（含城市/国家），WebSocket 下载/上传可用；
    M-Lab 有公开的使用条款与隐私政策（会公开发布测量数据，含客户端 IP，已在页面说明）。
  - 冒烟结果（开发机经代理）：M-Lab 西雅图 下载约 875 Mbps / 上传约 135 Mbps / 延迟 42.7 ms；见 `logs/speedtest-smoke-*.log`。
- 服务器选择：候选 = M-Lab 定位结果 + Cloudflare；对每个候选在 keep-alive 连接上做 5 次 HTTP 往返（首个含握手的请求不计），
  评分 = 中位延迟 + 0.5×抖动 + 丢失惩罚，Cloudflare 因限流风险乘 1.25。**不用地理距离**；负载数据平台未公开，界面不显示。可手动选择/重新探测。
- 延迟：20 次 HTTP 往返中位数（Cloudflare 扣除 `Server-Timing: cfRequestDuration`），抖动 = 相邻差值平均。**丢包率显示“不支持”**（TCP 重传，应用层测不到真实丢包）。
- 下载：ndt7 计接收字节；Cloudflare 4 路并发循环 25 MB 请求。上传：ndt7 以服务器回报的 `TCPInfo.BytesReceived` 计；
  Cloudflare 只在请求完成（服务器确认收到）后计字节，请求大小自适应。每阶段 10 秒，排除前 2 秒预热，窗口外到达的数据不计；6 秒无数据判中断；到时 1.5 秒后强制收尾。
- 原始值与显示值分离：引擎每 200 ms 给出最近 1 秒的真实速度；仪表指针只对其做 0.35 s 时间平滑；结果卡片显示引擎最终值。
- 内存：上传缓冲一次分配复用；ndt7 上传限制在途 4 MB；下载数据即读即弃。
- 失败/取消/超时有明确提示；结果写入检测历史（类型“主动测速”）。

### 6. 底部导航水波（`ripple_nav.dart`）
- 记录手指按下的实际位置，水波从该点以 easeOutCubic 扩散到约 75% 屏高，径向渐变（边缘稍亮、外缘羽化），透明度按 (1−t)² 衰减，520 ms。
- 覆盖层 `IgnorePointer + RepaintBoundary`，不拦截触摸、不重建页面。导航在点击瞬间切换；页面 fade-through（旧页前 35% 淡出，新页随后淡入并上移 1.2%），300 ms，无双重曝光、无闪屏。
- 所有页面常驻（保持滚动与结果），非当前页 Offstage + `TickerMode` 关闭；包裹结构恒定，切换不重建页面 State（有组件测试）。快速连续点击、返回键（先回首页）已覆盖。减少动态效果时无水波、直接切换。

### 7–8. 节点页衔接与全局视觉
- 统一 `AppColors / Gaps / Radii / Motion`；卡片统一 20 圆角 + 8% 白细边框、无阴影；页面左右边距 20；标题 24/w700，分组标题 13/w600。
- 节点页：标题 → 检测方式标签 + 进度（固定高度，开始/结束不跳动）→ 吸顶搜索与筛选（滚动后出现底部细线）→ 一个整体的节点分组（首尾圆角、行间细分隔）。
  选中节点：左侧强调条 + 浅色底 + “已选”；VPN 使用中：绿色 + “使用中”；禁用节点降低不透明度。
- 空状态：无节点、筛选无结果、无检测历史、未配置 Key、等待首个采样。大字体：搜索头高度随字体缩放计算，徽标/标签可缩放不溢出（测试覆盖 360×640 dp、1.3 倍字体）。

## 三、测试与构建

见 `docs/TEST_REPORT.md`（1.1.0 节）。

## 四、未解决 / 需真机确认

1. **未在任何 Android 真机或模拟器上运行**：动画帧率、120 Hz 表现、触觉反馈、真实 VPN 连接下的曲线与节点代理检测、测速在移动网络下的结果均未实测。
2. 测速仅在开发机（经代理）实测过引擎；手机上经 VPN 隧道的测速结果、M-Lab 在部分地区的可达性未验证。
3. Cloudflare 测速端点存在限流（HTTP 429），因此默认优先 M-Lab；若两者都不可达会明确报错。
4. 丢包率无法在 TCP 测速中真实测得，界面显示“不支持”。
5. 节点检测在 VPN 未开启时只能到 TCP / TLS 层；代理层检测需要连接 VPN。
6. 仍为 debug 签名；GeoIP 规则集、按应用分流未实现（与 1.0.0 相同）。
