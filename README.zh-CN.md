# Astra

[English](README.md) | 简体中文

Astra 是一个多供应商 AI 聊天客户端，基于原 `chat-demo` 静态聊天前端扩展而来，使用 **Tauri 2** 打包为 Android 手机/平板、Windows 和 Linux 桌面应用，不支持 iOS。

## 功能

- **多供应商**：内置 DeepSeek、OpenAI、Anthropic、OpenRouter、Gemini、xAI、Groq、Mistral、Together、硅基流动、Moonshot Kimi、智谱、阿里云百炼、火山方舟、MiniMax、百度千帆、腾讯混元、Ollama、LM Studio 等预设，也可添加自定义 OpenAI 兼容服务。
- **模型检测**：一键拉取供应商模型列表，分类对话/生图模型，并支持最小对话测试。
- **全局模型切换**：输入区模型菜单按供应商分组，选中模型自动切换供应商。
- **自定义 system prompt**：全局一份，留空使用当前供应商默认值，可一键恢复。
- **长期记忆**：全局记忆库，支持手动增删改、启用/禁用，以及聊天后的自动提取；记忆会随请求注入 system prompt。
- **生图**：对接 OpenAI 兼容 `/images/generations`，在聊天内生成图片、查看、保存和重新生成。
- **原生网络层**：Tauri 端使用 Rust `reqwest` 发起请求，绕过 WebView CORS，并提供真正的 SSE 流式输出。
- 保留原有的会话分支、编辑/重新生成、Markdown/KaTeX/Mermaid、语音输入与朗读、历史导入导出等能力。

## 下载与构建

所有安装包由 GitHub Actions 构建，不需要本地打包：

- `.github/workflows/ci.yml`：每次 push / PR 运行类型检查、lint、Web 构建和 `cargo check`。
- `.github/workflows/release.yml`：推送 `v*` 标签或在 Actions 页面手动触发，产出：
  - Android（arm64，debug 签名 APK，可直接安装）
  - Windows（NSIS + MSI）
  - Linux（AppImage + deb）

当前 `origin` 指向上游 `deepseek-ai/chat-demo`，请推送到你自己的 GitHub 仓库后再运行 Actions。

### 本地开发（可选）

```sh
pnpm install
pnpm icons        # 生成各平台图标
pnpm tauri dev    # 桌面调试；Web 版可用 pnpm dev
pnpm build        # 只构建 Web 静态文件到 dist/
pnpm tauri build  # 桌面安装包
```

Android 本地构建需要 Android SDK、NDK 与 Rust Android targets；CI 已配置好，无需在本地执行。

## 供应商与模型

在 **设置 → 供应商** 中从预设添加供应商，填入你自己的 API Key，点“检测模型”，选择对话模型（生图供应商再选生图模型）。所有预设只包含连接信息，不内置任何 Key，字段均可编辑。

- 需要 API Key 的供应商：DeepSeek、OpenAI、Anthropic 及大多数商业服务。
- Ollama / LM Studio 默认不需要 Key；在 Android 上请把 `localhost` 换成电脑的局域网 IP，并确保同一网络。
- DeepSeek 供应商保留原版扩展能力：深度思考、联网搜索、服务端标题、语音输入/朗读、Files API 附件。
- OpenAI/Anthropic 供应商只支持内联图片附件；文档附件请使用 DeepSeek 供应商。
- 供应商接口地址可能随官方调整，遇到问题时可在编辑页直接修改 base URL。

## 数据与隐私

- 供应商配置和 API Key 保存在本机 `localStorage`（`chat-demo:providers`）。
- 会话、附件原件、生成图片和记忆保存在 IndexedDB（数据库 `chat-demo`）。
- 聊天、记忆提取和生图请求只会发送到当前选择的供应商。
- 历史导出 ZIP（格式 v4）包含会话、本地图片、生成图片和 `memory.json`；**不包含** API Key、供应商配置和 system prompt。
- 导入会覆盖会话；若归档含 `memory.json` 也会替换记忆；v3 旧归档没有记忆文件，导入时保留现有记忆。
- “删除全部聊天”保留记忆和供应商设置；记忆可在 **设置 → 记忆** 中单独清空。

## 项目结构

```text
src/
  app/                 应用布局、主题、视口
  components/          聊天、设置、Markdown、供应商/记忆/生图 UI
  services/
    api/               HTTP/SSE 传输、DeepSeek 协议、语音、错误处理
    providers/         供应商预设、适配器、模型检测、system prompt
    memory/            记忆库、注入、自动提取
    imagegen/          OpenAI 兼容生图
    chat/              会话、分支、存储、历史导入导出
    speech/            录音与朗读
src-tauri/             Tauri 2 工程与 Rust 原生 HTTP/SSE 命令
```

## 许可

[MIT](LICENSE)。上游 `deepseek-ai/chat-demo` 同样使用 MIT 许可；第三方依赖遵循各自许可。
