# ◈ Astra

本地优先的 AI 对话工作台：**Windows 桌面 GUI + Android App**，保留原有终端版。

- 🖥 **Flutter GUI**：Windows 桌面与 Android 原生 App，响应式、简洁的浅色/深色界面
- 🧩 **服务与多模型**：填一个 Base URL + Key，拉取模型列表；可启用多个模型，在每个对话顶部切换
- ⚡ **流式对话**：文本、思维链、工具调用过程实时显示，可随时停止
- 🖼 **图片输入**：桌面文件选择 / Android 图片选择，压缩后以视觉模型格式发送
- 🛠 **工具调用**：Python、Shell（桌面）、联网搜索；执行前确认
- 🔗 **局域网配对同步**：任一设备做主机，另一台只输入 12 位配对码即可同步聊天、图片、模型与设置
- 🔐 **密钥不离开设备**：API Key 存系统安全存储，不同步、不写配置文件、不写日志
- 🧊 **旧 TUI 冻结保留**：`astra` 命令仍启动终端版

> GUI 的 Android 运行时使用 Chaquopy 内嵌 Python，桌面端使用本机 Python。

---

## 构建：只用 GitHub Actions

本仓库的 Flutter 平台工程（`android/`、`windows/` 等）**不提交**。CI 会在全新 runner 上：

1. `flutter create` 生成平台工程
2. 打 Android 权限 / Chaquopy / MainActivity 补丁
3. `flutter analyze` + `flutter test`
4. 构建 **Windows x64** 与 **Android arm64** 产物，并上传 artifact

### 步骤

1. 把本项目（Astra 目录）作为 GitHub 仓库根目录推送，或把下面的 workflow 复制到你的仓库根并调整 `app/` 路径。
2. 打开 **Actions → Build Astra → Run workflow**。
3. 构建完成后下载：
   - `Astra-Windows-x64` → 解压，运行其中的 `astra_gui.exe`
   - `Astra-Android-arm64` → 安装 `Astra-Android-arm64.apk`（需允许安装未知来源应用）

> workflow 固定使用 Flutter **3.27.4** 与 Chaquopy **17.2.0**，以保证依赖可复现。  
> 本机不需要安装 Flutter，也不需要本地构建。

CI 文件：`.github/workflows/build.yml`  
Android 补丁脚本：`app/tool/ci_prepare.py`  
Chaquopy 桥模板：`app/tool/templates/android/`

---

## 第一次使用

1. 打开 GUI，点击「添加模型服务」。
2. 选择 **OpenAI 兼容** 或 **Anthropic**，填写 Base URL 与 API Key。
3. 点击「拉取模型」；失败时也可以手动添加模型 ID。
4. 在模型列表中启用需要的模型，设置默认模型。
5. 回到对话列表，点「+」新建对话（多服务时会先选服务）。

### 配置示例

| 服务 | Base URL | 模型示例 |
| --- | --- | --- |
| Anthropic | `https://api.anthropic.com` | `claude-opus-5`、`claude-sonnet-5` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini`、`gpt-4.1` |
| DeepSeek | `https://api.deepseek.com` | `deepseek-reasoner`、`deepseek-chat` |
| OpenRouter | `https://openrouter.ai/api/v1` | 按 OpenRouter 模型页填写 |
| Ollama | `http://localhost:11434/v1` | `qwen3:8b` 等；Key 可随意填 `local` |

> 模型能力（视觉/工具/推理）由模型 ID 自动猜测，也可以在每个模型的「能力与选项」中手动修正。

---

## 图片、思维链与多模型

- **图片**：输入框左侧添加图片（最多 4 张，自动缩放并压缩为 JPEG）。图片会作为 OpenAI `image_url` 或 Anthropic `image` 内容块发送；不支持视觉的模型可能报错。
- **思维链**：OpenAI 兼容网关的 `reasoning_content` / `reasoning` / `thinking` 与 Anthropic 的 thinking 事件都会进入可折叠的「思考过程」面板。
- **多模型**：设置中可一次拉取并启用多个模型；聊天顶部模型 chip 可随时切换，切换只影响后续消息。
- **系统提示词**：设置中有全局默认提示词（可以完全留空）；每个对话也可以单独覆盖，留空即继承全局。

---

## 工具调用与安全

模型可以在对话中请求工具；代码/命令工具默认关闭，开启后**每次执行都会显示代码并要求确认**。

| 工具 | 平台 | 说明 |
| --- | --- | --- |
| `web_search` | 全部 | DuckDuckGo 免 Key；也可在设置中填 Tavily / Brave Search Key |
| `run_python` | Windows / Android | 桌面用本机 Python；Android 用 Chaquopy 内置 Python 标准库 |
| `run_shell` | 仅桌面 | 高风险，默认关闭，需要确认 |

安全边界：

- 代码在对话的私有工作目录中执行，带超时和输出长度限制；不继承 API Key 环境变量。
- **这不是操作系统级强沙箱**。Python/Shell 生成的代码仍可能访问工作目录之外的内容；只在你信任模型与来源时使用。
- 联网搜索会使用你设置的搜索服务；查询内容会发送给对应搜索提供商。
- Chaquopy 对开源项目免费；商业分发/上架前请确认 Chaquopy 许可与目标商店对动态执行代码的政策。

---

## 局域网配对同步

不经过云端；两台设备需在同一局域网（同一 Wi-Fi 或可互通的 VPN）。

1. 在任意一台设备：设置 → 同步 → 打开「本机作为同步主机」→「生成配对码」。
2. 在另一台设备：同步页输入这 12 位配对码 →「加入」。
3. 配对成功后自动同步聊天、图片、服务/模型元数据、系统提示词与可移植设置。
4. 多台设备可依次加入同一个主机；任何设备也都可以同时作为别的主机或加入方。

同步协议要点：

- 自动 UDP 发现（端口 41234），不需要手动输入 IP。
- 配对码有效 120 秒，错误尝试有限流。
- 配对使用 X25519 + HKDF 派生密钥；同步连接使用 PSK 认证、AES-GCM 加密；消息带序号防重放。
- 冲突使用 HLC 最后写入胜出 + 删除 tombstone。
- **API Key、搜索 Key、同步 PSK 永不同步**；每台设备需要各自配置 Key。
- Android 作为主机时，Astra 必须保持在前台；后台可能被系统暂停。iOS 暂未构建。

> 部分 Windows 防火墙会拦截局域网监听/发现；首次运行请在防火墙提示中允许专用网络访问。

---

## 密钥与数据

- GUI 的 API Key、搜索 Key、同步 PSK 使用 `flutter_secure_storage`：Windows DPAPI、Android Keystore。
- 密钥不进入 JSON、不进入同步记录、不写日志。接口报错会先去掉可能回显的 Key。
- 聊天、消息、图片、模型设置在应用私有数据目录：
  - Windows：系统应用支持目录下的 `astra_gui`
  - Android：App 私有目录
- 删除 App 数据或解除配对不会自动删除对端数据；删除同步设备只移除本机配对关系。

---

## 旧终端版（冻结）

终端版仍可通过原命令启动，功能保持不变：

```bat
astra
```

- `astra --version` / `astra --help`
- 配置文件在 `D:\coding\astra\.state\config.json`（可用 `ASTRA_CONFIG_DIR` 覆盖）
- API Key 使用 Windows 凭据管理器（`astra-tui`）或环境变量 `ASTRA_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`
- TUI 源码在 `src/astra/`，不影响 GUI 构建

---

## 目录结构

```
.
├─ app/                     # Flutter GUI
│  ├─ lib/
│  │  ├─ data/              模型、存储、Provider、工具、同步
│  │  ├─ state/             AstraController
│  │  └─ ui/                桌面/手机界面
│  ├─ test/                 Dart 单元测试
│  ├─ tool/                 CI 平台补丁 + Chaquopy 模板
│  └─ pubspec.yaml
├─ src/ tests/              # 冻结的 Python TUI
├─ .github/workflows/       # GitHub Actions 构建
└─ run.cmd
```

---

## 已知限制

- GUI v1 移动端只构建 **Android arm64**，未提供 iOS 构建。
- Android 内置 Python 只有标准库；需要第三方包请在 Chaquopy 配置中预打包。
- 同步要求同一局域网；手机作主机时仅前台可用；当前实现不做跨设备附件中继（点对点文件传输）。
- 配对码安全基于 60-bit 短码 + 加密与限流，仍建议在可信网络中使用。
- 工具执行不是 OS 沙箱，请务必确认每次代码/命令。
- APK 使用 debug 签名，便于侧载；上架 Play Store 前需要自行配置正式签名与 AAB 流程。
- 本地没有 Flutter SDK 时不执行本地构建；编译/测试由 GitHub Actions 完成。

---

## 开发与验证

GUI 的静态检查与测试在 CI 中运行：

```text
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
```

旧 TUI 的测试不受影响：

```bat
uv run pytest -q
```
