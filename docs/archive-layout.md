# 统一目录规范

这套规范把“Skill 源码放在哪里”和“真实聊天数据放在哪里”彻底分开。三个来源使用相同的源码骨架与同一个可移植存档家目录契约，但保留各自的数据格式。

## 1. Skill 源码目录

每个私有开发仓库和公共镜像中的单个 Skill 都遵守以下骨架：

```text
<source>-local-backup/
├── SKILL.md                 # Agent 唯一执行入口：触发条件、流程、安全边界
├── README.md                # GitHub 面向人的功能、安装、目录和示例
├── agents/
│   └── openai.yaml          # UI 名称、短描述、默认调用提示
├── scripts/                 # 确定性初始化、采集、整理、校验和发布程序
│   ├── lib/                 # 可复用内部模块；仅在需要时存在
│   └── tests/               # 合成测试；绝不放真实账户样本
├── references/              # 详细数据契约、目录语义和运行手册
├── LICENSE                  # 独立安装时仍可识别许可证
└── .gitignore               # 阻止真实存档、日志、令牌和临时文件入库
```

`.github/workflows/` 可以存在于私有源仓库，用于 CI；发布到聚合仓库时由聚合仓库统一管理 CI。真实存档、运行报告、账户配置、浏览器状态和私人记忆不得进入 Skill 目录。

## 2. 运行时存档家目录

在每台电脑上选择一个 `ArchiveHome`。盘符或挂载点可以不同，下面的相对结构必须相同：

```text
<ArchiveHome>/
├── chatgpt/
│   └── <profile>/
├── doubao/
│   └── <profile>/
└── feishu/
    └── <profile>/
```

`profile` 是一个稳定的小写 ID，例如 `primary`、`work` 或租户的稳定别名。它表示同一账户/租户的连续存档，不使用日期，也不使用电脑名称。

每个 profile 根目录都必须包含：

```json
{
  "schema": "chat-history-archive-profile-v1",
  "source": "chatgpt | doubao | feishu",
  "profile_id": "primary",
  "layout_version": 1,
  "created_at": "UTC timestamp"
}
```

`layout_version` 由各来源定义；豆包当前为 3。`archive-profile.json` 不保存绝对路径、账号令牌或浏览器凭据。

## 3. 各来源 profile 内部内容

### ChatGPT

```text
chatgpt/<profile>/
├── archive-profile.json
├── tool/export-chatgpt/       # 可重建的第三方导出器
├── state/raw/                 # 可恢复增量状态
├── working/                   # 临时下载与候选
├── final/ChatGPT_Backup/      # 唯一已验证正式备份
├── logs/                      # 脱敏日志
└── reports/                   # 校验与运行报告
```

### 豆包

```text
doubao/<profile>/
├── archive-profile.json
├── tool/                      # 锁和可重建工具缓存
├── state/raw/                 # 检查点与增量数据
├── working/                   # 临时附件与候选
├── final/Doubao_Backup/       # conversations JSON、原始附件和 metadata
├── documents/                 # Markdown 文档
├── logs/
└── reports/
```

### 飞书

```text
feishu/<profile>/
├── archive-profile.json
├── _meta/                     # manifest、完整度、gap、策略、运行、报告、哈希
├── chats/                     # 消息 JSON、成员、附件、隔离区
├── drive/                     # Drive 清单、文档、结构化数据和文件
├── wiki/                      # Wiki 清单、文档、结构化数据和文件
└── calendar|meetings|tasks|…/ # 按需启用的结构化协作域
```

## 4. 路径解析规则

1. 用户显式传入 profile 根目录时，以它为准。
2. 否则使用 `ArchiveHome + source + profile`。
3. 可用环境变量 `CHAT_HISTORY_ARCHIVE_HOME` 保存本机的 `ArchiveHome`，但不得把它提交到 Git。
4. 没有路径或 profile 时停止并询问；不得默认 D 盘、用户主目录或当前工作目录。
5. 标记来源不匹配时立即停止；不得自动改写标记。

## 5. 换电脑与旧存档

- 新电脑：安装 Skill，选择新的 `ArchiveHome`，沿用原 profile ID；若存档随硬盘迁移，只需指向新的路径。
- 旧存档：不强制搬迁。先人工确认来源，再通过各 Skill 的初始化脚本执行 `adopt existing`，只补充 `archive-profile.json`。
- 多账户/多租户：每个账户或租户使用独立 profile，不在同一个 profile 中混写身份。
- 日期快照：放在来源内部的状态或发布机制中；不要用新的日期 profile 代替日常增量维护。
