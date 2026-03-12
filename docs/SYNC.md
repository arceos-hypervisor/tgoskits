# Git Subtree 组件双向同步方案

本文档详细描述如何实现主仓库和组件仓库之间的双向自动同步。

## 目录

- [方案概述](#方案概述)
- [架构设计](#架构设计)
- [工具脚本](#工具脚本)
- [快速开始](#快速开始)
- [详细配置](#详细配置)
- [使用指南](#使用指南)
- [工作流程](#工作流程)
- [故障排查](#故障排查)
- [最佳实践](#最佳实践)

---

## 方案概述

### 同步方向

我们提供两种同步方向：

1. **主仓库 → 组件仓库**：使用 `scripts/push.sh` 手动推送更新
2. **组件仓库 → 主仓库**：使用 GitHub Actions 自动拉取更新

### 核心优势

- ✅ **自动化同步**：组件仓库更新后自动触发主仓库同步
- ✅ **双向同步**：支持主仓库 ↔ 组件仓库双向更新
- ✅ **灵活控制**：支持手动触发、自动触发、批量操作
- ✅ **安全可靠**：使用 GitHub Token 认证，支持强制推送
- ✅ **易于扩展**：新组件只需简单配置即可接入

---

## 架构设计

### 同步流程图

```
┌─────────────────┐                    ┌──────────────────┐
│  组件仓库        │                    │   主仓库          │
│ (arm_vcpu)      │                    │  (tgoskits)      │
├─────────────────┤                    ├──────────────────┤
│                 │  1. Push 到组件仓库  │                  │
│  开发者 ──────> │ ───────────────>   │                  │
│                 │                    │                  │
│                 │  2. GitHub Actions  │                  │
│                 │     触发通知        │                  │
│                 │ ───────────────>   │                  │
│                 │                    │  3. 拉取更新      │
│                 │                    │     (subtree pull)│
│                 │ <───────────────   │                  │
│                 │                    │                  │
│                 │  4. 手动推送        │                  │
│                 │ <───────────────   │  开发者          │
│                 │   (subtree push)   │                  │
└─────────────────┘                    └──────────────────┘
```

### 组件关系

```
tgoskits (主仓库)
├── arm_vcpu        → https://github.com/arceos-hypervisor/arm_vcpu
├── axvm            → https://github.com/arceos-hypervisor/axvm
├── axvisor         → https://github.com/arceos-hypervisor/axvisor
├── arceos          → https://github.com/arceos-org/arceos
├── axconfig-gen    → https://github.com/arceos-org/axconfig-gen
└── ... 更多组件见 scripts/repos.list
```

---

## 工具脚本

### Shell 脚本（本地操作）

#### push.sh - 推送本地修改到组件仓库

将主仓库中的组件修改推送到各个组件的独立仓库。

```bash
# 推送所有修改的组件
scripts/push.sh

# 推送指定组件
scripts/push.sh -r arm_vcpu

# 推送到指定分支
scripts/push.sh -r arm_vcpu -b dev

# 强制推送（覆盖远程）
scripts/push.sh -r arm_vcpu --force

# 自动提交并推送
scripts/push.sh -r arm_vcpu -c "feat: update arm_vcpu"

# 预览操作（不实际执行）
scripts/push.sh --dry-run -r arm_vcpu
```

**选项说明：**
- `-r, --repo <dir>` - 指定组件目录（可多次使用）
- `-b, --branch <branch>` - 指定目标分支（默认 main）
- `-c, --commit <msg>` - 自动提交信息
- `--force` - 强制推送（覆盖远程）
- `-a, --all` - 推送所有组件
- `-d, --dry-run` - 预览模式

#### pull.sh - 从组件仓库拉取更新

从各个组件的独立仓库拉取更新到主仓库。

```bash
# 拉取指定组件的更新
scripts/pull.sh -r arm_vcpu

# 拉取指定组件的指定分支
scripts/pull.sh -r arm_vcpu -b dev

# 拉取所有组件的更新
scripts/pull.sh -a

# 预览拉取操作
scripts/pull.sh --dry-run -a
```

**选项说明：**
- `-r, --repo <dir>` - 指定组件目录（可多次使用）
- `-b, --branch <branch>` - 指定拉取分支
- `-a, --all` - 拉取所有组件
- `-d, --dry-run` - 预览模式

#### 其他辅助脚本

```bash
# 管理组件仓库
scripts/repos.sh                    # 使用默认配置添加所有组件
scripts/repos.sh -f custom.list     # 使用自定义配置文件

# 检查组件状态
scripts/check.sh all                # 检查所有组件
scripts/check.sh arm_vcpu           # 检查指定组件
```

### GitHub Actions Workflows（CI/CD）

#### 主仓库：pull.yml

**位置**：`.github/workflows/pull.yml`

**作用**：接收组件仓库的更新通知，自动拉取更新

**触发方式**：
1. 接收 `repository_dispatch` 事件（组件仓库推送）
2. 手动触发（workflow_dispatch）

#### 组件仓库：push.yml（模板）

**位置**：`scripts/push.yml`

**作用**：组件仓库推送代码时，通知主仓库拉取更新

**使用方式**：复制到组件仓库的 `.github/workflows/` 目录

---

## 快速开始

### 1. 配置组件仓库（5 分钟）

#### 步骤 1：复制 workflow 文件

```bash
cd arm_vcpu  # 进入组件仓库
mkdir -p .github/workflows

# 复制模板文件
cp /path/to/tgoskits/scripts/push.yml .github/workflows/notify-parent.yml
```

#### 步骤 2：创建 Personal Access Token

1. 访问 https://github.com/settings/tokens/new
2. 设置 Token 名称：`tgoskits-subtree-sync`
3. 选择权限：
   - ✅ `repo` (Full control of private repositories)
   - ✅ `workflow` (Update GitHub Action workflows)
4. 点击 "Generate token"
5. **立即复制 Token**（只显示一次）

#### 步骤 3：配置 Secret

1. 进入组件仓库的 **Settings** 页面
2. 左侧菜单选择 **Secrets and variables** → **Actions**
3. 点击 **New repository secret**
4. 填写：
   - Name: `PARENT_REPO_TOKEN`
   - Value: 粘贴刚才复制的 Token
5. 点击 **Add secret**

#### 步骤 4：测试配置

```bash
# 在组件仓库中推送一个测试提交
echo "<!-- test -->" >> README.md
git add README.md
git commit -m "test: notify parent repository"
git push origin main
```

#### 步骤 5：验证

检查：
1. 组件仓库的 **Actions** 页面 - 确认 workflow 运行成功
2. 主仓库的 **Actions** 页面 - 确认收到通知并拉取更新
3. 主仓库的提交历史 - 应该看到 "Merge subtree arm_vcpu/main"

### 2. 使用主仓库脚本

```bash
# 在主仓库中修改组件代码
vim arm_vcpu/src/lib.rs
git add arm_vcpu/src/lib.rs
git commit -m "feat: update arm_vcpu"

# 推送到组件仓库
scripts/push.sh -r arm_vcpu

# 或使用自动提交
scripts/push.sh -r arm_vcpu -c "feat: update arm_vcpu"
```

---

## 详细配置

### 主仓库配置

主仓库已经配置好了接收更新的 GitHub Actions workflow。

**文件位置**：`.github/workflows/pull.yml`

**配置要点**：
- 监听 `repository_dispatch` 事件
- 从 `scripts/repos.list` 读取组件信息
- 自动执行 `git subtree pull`

### 组件仓库配置

#### GitHub Actions Workflow

在组件仓库中创建文件 `.github/workflows/notify-parent.yml`：

```yaml
name: Notify Parent Repository

on:
  push:
    branches:
      - main
      - dev
      - 'feature/**'
      - 'release/**'
  workflow_dispatch:

jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - name: Get repository info
        id: repo
        run: |
          REPO_URL="${{ github.repositoryUrl }}"
          COMPONENT=$(echo "${REPO_URL}" | sed 's|.*/||' | sed 's|\.git$||')
          BRANCH="${{ github.ref_name }}"
          
          echo "component=${COMPONENT}" >> $GITHUB_OUTPUT
          echo "branch=${BRANCH}" >> $GITHUB_OUTPUT

      - name: Notify parent repository
        env:
          GITHUB_TOKEN: ${{ secrets.PARENT_REPO_TOKEN }}
        run: |
          COMPONENT="${{ steps.repo.outputs.component }}"
          BRANCH="${{ steps.repo.outputs.branch }}"
          PARENT_REPO="rcore-os/tgoskits"  # 修改为你的主仓库路径
          
          curl -X POST \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            https://api.github.com/repos/${PARENT_REPO}/dispatches \
            -d "{
              \"event_type\": \"subtree-update\",
              \"client_payload\": {
                \"component\": \"${COMPONENT}\",
                \"branch\": \"${BRANCH}\",
                \"commit\": \"${{ github.sha }}\",
                \"message\": \"${{ github.event.head_commit.message }}\",
                \"author\": \"${{ github.actor }}\"
              }
            }"
```

#### 自定义触发条件

如果只想在特定文件变化时触发，可以修改 `on.push.paths`：

```yaml
on:
  push:
    branches:
      - main
    paths:
      - 'src/**'        # 只在 src 目录变化时触发
      - 'Cargo.toml'    # 或 Cargo.toml 变化时
```

### repos.list 配置

**文件位置**：`scripts/repos.list`

**格式**：`<仓库URL>|<分支>|<目标目录>`

```bash
# 示例
https://github.com/arceos-hypervisor/arm_vcpu||arm_vcpu
https://github.com/arceos-org/arceos|dev|arceos
```

**说明**：
- 第一个字段：仓库 URL
- 第二个字段：分支名（留空则自动检测）
- 第三个字段：本地目录名

---

## 使用指南

### 推送操作（主仓库 → 组件仓库）

#### 基本使用

```bash
# 1. 在主仓库中修改组件代码
vim arm_vcpu/src/lib.rs

# 2. 提交更改
git add arm_vcpu/src/lib.rs
git commit -m "feat: update arm_vcpu"

# 3. 推送到组件仓库
scripts/push.sh -r arm_vcpu
```

#### 高级用法

```bash
# 自动提交并推送（一步完成）
scripts/push.sh -r arm_vcpu -c "feat: update arm_vcpu"

# 推送多个组件
scripts/push.sh -r arm_vcpu -r axvm -r axvisor

# 推送到指定分支
scripts/push.sh -r arm_vcpu -b dev

# 强制推送（覆盖远程）
scripts/push.sh -r arm_vcpu --force

# 推送所有修改的组件
scripts/push.sh

# 推送所有组件（无论是否修改）
scripts/push.sh -a
```

### 拉取操作（组件仓库 → 主仓库）

#### 手动拉取

```bash
# 拉取指定组件的更新
scripts/pull.sh -r arm_vcpu

# 拉取指定组件的指定分支
scripts/pull.sh -r arm_vcpu -b dev

# 拉取所有组件的更新
scripts/pull.sh -a

# 预览拉取操作
scripts/pull.sh --dry-run -a
```

#### 自动拉取

组件仓库推送代码后，主仓库会自动拉取更新：

1. 组件仓库推送代码
2. 触发 GitHub Actions
3. 通知主仓库
4. 主仓库自动执行 `git subtree pull`

### 批量操作

```bash
# 批量推送所有修改的组件
scripts/push.sh

# 批量拉取所有组件
scripts/pull.sh -a

# 批量检查所有组件状态
scripts/check.sh all
```

---

## 工作流程

### 自动同步流程

```
1. 开发者在组件仓库推送代码
   ↓
2. 组件仓库的 GitHub Actions 被触发
   ↓
3. Actions 发送 repository_dispatch 事件到主仓库
   ↓
4. 主仓库的 GitHub Actions 被触发
   ↓
5. 主仓库执行 git subtree pull 拉取更新
   ↓
6. 主仓库自动提交并推送更改
```

### 手动同步流程

#### 推送流程（主仓库 → 组件仓库）

```
主仓库修改组件代码 
  → git commit 
  → scripts/push.sh -r <component>
  → 组件仓库收到更新
```

#### 拉取流程（组件仓库 → 主仓库）

```
组件仓库更新
  → 手动触发或自动触发
  → 主仓库执行 scripts/pull.sh -r <component>
  → 主仓库收到更新
```

### 冲突处理流程

```
1. 拉取时检测到冲突
   ↓
2. 手动解决冲突
   git add .
   git commit -m "resolve conflicts in <component>"
   ↓
3. 推送到主仓库
   git push origin main
   ↓
4. 推送到组件仓库
   scripts/push.sh -r <component>
```

---

## 故障排查

### 推送失败：non-fast-forward

**原因**：远程分支有新的提交

**错误信息**：
```
! [rejected] ... -> zcs (non-fast-forward)
error: failed to push some refs
```

**解决方案**：

```bash
# 方案1：强制推送（覆盖远程）
scripts/push.sh -r <component> --force

# 方案2：先拉取再推送
scripts/pull.sh -r <component>
scripts/push.sh -r <component>
```

### 拉取失败：冲突

**原因**：主仓库和组件仓库都有修改

**解决方案**：

```bash
# 手动拉取并解决冲突
scripts/pull.sh -r <component>

# 解决冲突
# ... 手动编辑冲突文件 ...

# 提交解决
git add .
git commit -m "resolve conflicts in <component>"
git push origin main

# 推送到组件仓库
scripts/push.sh -r <component>
```

### Token 权限不足

**错误信息**：`HTTP 403: Resource not accessible by integration`

**解决方案**：
1. 确保 Token 有 `repo` 和 `workflow` 权限
2. 检查组件仓库的 Secret 配置是否正确
3. 确认 Token 未过期

### 组件未找到

**错误信息**：`Component xxx not found in repos.list`

**解决方案**：
1. 检查主仓库的 `scripts/repos.list` 文件
2. 确认组件配置格式正确
3. 检查组件目录名是否匹配

### GitHub Actions 失败

**可能原因**：
1. Token 权限不足
2. 网络问题
3. 配置错误

**排查步骤**：
1. 查看 Actions 日志
2. 检查 Token 配置
3. 验证 workflow 文件语法
4. 确认主仓库路径正确

---

## 最佳实践

### 推送前检查

1. **确保修改已提交**
   ```bash
   git status
   git add .
   git commit -m "your message"
   ```

2. **预览推送操作**
   ```bash
   scripts/push.sh --dry-run -r <component>
   ```

3. **检查组件状态**
   ```bash
   scripts/check.sh <component>
   ```

### 强制推送使用场景

**适合使用 `--force`**：
- 确认远程提交可以被覆盖
- 个人分支测试
- 修复错误的提交

**不适合使用 `--force`**：
- 团队协作的分支
- 重要的历史提交
- 不确定远程状态时

### 分支管理建议

1. **开发分支**：使用 `dev` 分支进行开发
2. **主分支**：`main` 分支保持稳定
3. **发布分支**：使用 `release/**` 分支准备发布

```bash
# 推送到开发分支
scripts/push.sh -r arm_vcpu -b dev

# 合并到主分支后推送
scripts/push.sh -r arm_vcpu -b main
```

### 定期维护

```bash
# 定期检查所有组件状态
scripts/check.sh all

# 定期拉取所有组件更新
scripts/pull.sh -a

# 清理不需要的 remote
git remote prune origin
```

### Token 管理

1. **定期更新 Token**：建议每 3-6 个月更新一次
2. **最小权限原则**：只给予必要的权限
3. **安全存储**：不要在代码中硬编码 Token
4. **监控使用**：定期检查 Token 使用情况

---

## 附录

### 组件仓库列表

当前配置的组件仓库：

- **arceos-hypervisor 组织**：arm_vcpu, axvm, axvisor, axaddrspace, axdevice 等
- **arceos-org 组织**：arceos, axconfig-gen, axcpu, axsched 等

完整列表见主仓库的 `scripts/repos.list` 文件。

### 相关文件

- `scripts/push.sh` - 推送脚本
- `scripts/pull.sh` - 拉取脚本
- `scripts/repos.sh` - 仓库管理脚本
- `scripts/check.sh` - 检查脚本
- `scripts/push.yml` - 组件仓库 workflow 模板
- `.github/workflows/pull.yml` - 主仓库 workflow
- `scripts/repos.list` - 组件配置列表

### 参考资料

- [Git Subtree 文档](https://git-scm.com/book/en/v2/Git-Tools-Advanced-Merging#_subtree_merge)
- [GitHub Actions 文档](https://docs.github.com/en/actions)
- [GitHub API 文档](https://docs.github.com/en/rest)

---

## 获取帮助

如果遇到问题，请：

1. 查看本文档的故障排查章节
2. 检查 GitHub Actions 的日志
3. 查看相关脚本的帮助信息：`scripts/push.sh --help`
4. 提交 Issue 或联系维护者
