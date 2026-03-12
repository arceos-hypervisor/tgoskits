#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)

# =============================================================================
# Default Configuration
# =============================================================================

DEFAULT_REPO_FILE="${SCRIPT_DIR}/repos.list"
DEFAULT_BRANCH="dev"   # 默认推送到子仓库的 dev 分支

# 全局变量
declare -A REPO_MAP           # 目录 -> "url|branch" 映射
declare -A MODIFIED_DIRS=()   # 修改的组件目录列表

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    printf '%s\n' \
        "Git Subtree 推送脚本 - 将本地组件修改推送到远程子仓库" \
        "" \
        "注意: 默认推送到子仓库的 dev 分支" \
        "" \
        "用法:" \
        "  scripts/push.sh [选项]" \
        "" \
        "选项:" \
        "  -f, --file <file>       指定仓库列表文件并推送其中所有仓库（默认为 scripts/repos.list）" \
        "  -c, --component <dir>   指定要推送的组件目录（需配合 -b 使用）" \
        "  -b, --branch <branch>   指定推送的目标分支（默认为 dev）" \
        "  -d, --dry-run           仅显示将要执行的操作，不实际执行" \
        "  --force                 强制推送（即使远程有更新也覆盖）" \
        "  -m, --commit <msg>      提交信息（如果没有提交会自动创建）" \
        "  -h, --help              显示此帮助信息" \
        "" \
        "注意:" \
        "  如果遇到 'non-fast-forward' 错误，说明远程分支有更新。" \
        "  可以使用 --force 强制推送，但这可能覆盖远程的提交。" \
        "" \
        "示例:" \
        "  scripts/push.sh                            # 显示帮助信息" \
        "  scripts/push.sh -f                         # 推送文件中所有组件到 dev 分支" \
        "  scripts/push.sh -f -b main                 # 推送文件中所有组件到 main 分支" \
        "  scripts/push.sh -c axconfig-gen -b dev     # 推送指定组件到 dev 分支" \
        "  scripts/push.sh -c arm_vcpu -b dev --force # 强制推送（覆盖远程）" \
        "  scripts/push.sh -f -m 'fix: update API'    # 自动提交并推送"
}

log_info() {
    printf '\033[0;34m[INFO]\033[0m %s\n' "$1"
}

log_success() {
    printf '\033[0;32m[SUCCESS]\033[0m %s\n' "$1"
}

log_warn() {
    printf '\033[0;33m[WARN]\033[0m %s\n' "$1"
}

log_error() {
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$1"
}

# =============================================================================
# Core Functions
# =============================================================================

# 解析仓库列表文件
# 返回: 关联数组 REPO_MAP (目录 -> "url|branch")
parse_repo_list() {
    local repo_file="$1"
    
    if [[ ! -f "${repo_file}" ]]; then
        log_error "仓库列表文件不存在: ${repo_file}"
        exit 1
    fi
    
    # REPO_MAP 已在全局声明
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # 解析行: url|branch|dir 或 url|dir
        local url branch dir
        IFS='|' read -r url branch dir <<< "$line"
        
        # 如果只有两个字段（url|dir），则 branch 为空
        if [[ -z "$dir" ]]; then
            dir="$branch"
            branch=""
        fi
        
        # 去除空格
        url=$(echo "$url" | xargs)
        branch=$(echo "$branch" | xargs)
        dir=$(echo "$dir" | xargs)
        
        if [[ -n "$url" && -n "$dir" ]]; then
            REPO_MAP["$dir"]="${url}|${branch}"
        fi
    done < "${repo_file}"
}

# 获取修改的组件目录列表
# 返回: 数组 MODIFIED_DIRS
get_modified_dirs() {
    # MODIFIED_DIRS 已在全局声明
    
    # 获取所有修改的文件（包括暂存和未暂存的）
    local files
    files=$(git status --porcelain | awk '{print $2}' | sort -u)
    
    if [[ -z "$files" ]]; then
        log_info "没有检测到修改的文件"
        return 0
    fi
    
    # 分析每个文件所属的组件目录
    while IFS= read -r file; do
        # 获取文件的第一级目录
        local top_dir
        top_dir=$(echo "$file" | cut -d'/' -f1)
        
        # 检查是否是已配置的组件目录
        if [[ -n "${REPO_MAP[$top_dir]:-}" ]]; then
            MODIFIED_DIRS["$top_dir"]=1
        fi
    done <<< "$files"
}

# 检查是否有未提交的修改
has_uncommitted_changes() {
    ! git diff-index --quiet HEAD -- 2>/dev/null
}

# 同步单个组件到远程仓库
# 参数: $1 = 组件目录, $2 = 仓库URL, $3 = 分支名, $4 = 目标分支, $5 = dry-run, $6 = force
sync_component() {
    local dir="$1"
    local repo_url="$2"
    local src_branch="$3"
    local target_branch="$4"
    local dry_run="$5"
    local force_push="$6"
    
    log_info "=========================================="
    log_info "同步组件: ${dir}"
    log_info "  仓库: ${repo_url}"
    log_info "  源分支: ${src_branch:-自动检测}"
    log_info "  目标分支: ${target_branch}"
    if [[ "$force_push" == "true" ]]; then
        log_warn "  强制推送: 是（可能覆盖远程提交）"
    fi
    log_info "=========================================="
    
    # 切换到仓库根目录
    cd "${ROOT_DIR}"
    
    # 检查组件目录是否存在
    if [[ ! -d "${dir}" ]]; then
        log_error "组件目录不存在: ${dir}"
        return 1
    fi
    
    # 构建 git subtree push 命令
    local force_flag=""
    if [[ "$force_push" == "true" ]]; then
        force_flag="--force"
    fi
    
    # 如果是 dry-run 模式，只显示信息
    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] 将执行: git subtree push ${force_flag} --prefix=${dir} ${repo_url} ${target_branch}"
        return 0
    fi
    
    # 检查是否有对应的 remote，如果没有则添加
    local remote_name="${dir}"
    if ! git remote | grep -q "^${remote_name}$"; then
        log_info "添加远程仓库: ${remote_name} -> ${repo_url}"
        git remote add "${remote_name}" "${repo_url}"
    fi
    
    # 执行 git subtree push
    log_info "推送 ${dir} 到 ${repo_url}:${target_branch} ..."
    local push_cmd="git subtree push --prefix=\"${dir}\" ${force_flag} \"${remote_name}\" \"${target_branch}\""
    if eval "$push_cmd"; then
        log_success "成功同步 ${dir} 到 ${repo_url}:${target_branch}"
        return 0
    else
        log_error "同步失败: ${dir}"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi
    
    local repo_file="${DEFAULT_REPO_FILE}"
    local target_branch="${DEFAULT_BRANCH}"
    local dry_run="false"
    local force_push="false"
    local commit_msg=""
    local -a manual_repos=()  # 手动指定的组件列表
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
                    repo_file="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            -b|--branch)
                target_branch="$2"
                shift 2
                ;;
            -c|--component)
                manual_repos+=("$2")
                shift 2
                ;;
            -d|--dry-run)
                dry_run="true"
                shift
                ;;
            --force)
                force_push="true"
                shift
                ;;
            -m|--commit)
                commit_msg="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # 切换到仓库根目录
    cd "${ROOT_DIR}"
    
    # 解析仓库列表
    log_info "解析仓库列表: ${repo_file}"
    parse_repo_list "${repo_file}"
    log_info "找到 ${#REPO_MAP[@]} 个配置的组件"
    
    # 确定要同步的组件目录
    if [[ ${#manual_repos[@]} -gt 0 ]]; then
        # 使用手动指定的组件
        log_info "手动指定同步 ${#manual_repos[@]} 个组件"
        for dir in "${manual_repos[@]}"; do
            if [[ -n "${REPO_MAP[$dir]:-}" ]]; then
                MODIFIED_DIRS["$dir"]=1
            else
                log_error "未知的组件目录: ${dir}"
                exit 1
            fi
        done
    else
        log_info "同步文件中所有组件"
        for dir in "${!REPO_MAP[@]}"; do
            MODIFIED_DIRS["$dir"]=1
        done
    fi
    
    # 检查是否有未提交的修改
    if has_uncommitted_changes; then
        if [[ -n "$commit_msg" ]]; then
            log_info "检测到未提交的修改，正在自动提交..."
            git add -A
            git commit -m "$commit_msg"
            log_success "自动提交完成"
        else
            log_error "存在未提交的修改，请先提交或使用 -c 参数指定提交信息"
            git status --short
            exit 1
        fi
    fi
    
    # 如果没有修改的组件
    if [[ ${#MODIFIED_DIRS[@]} -eq 0 ]]; then
        log_info "没有需要同步的组件"
        exit 0
    fi
    
    log_info "将要同步的组件: ${!MODIFIED_DIRS[*]}"
    
    # 同步每个修改的组件
    local success_count=0
    local fail_count=0
    
    for dir in "${!MODIFIED_DIRS[@]}"; do
        local repo_info="${REPO_MAP[$dir]}"
        local repo_url branch
        
        IFS='|' read -r repo_url branch <<< "$repo_info"
        
        # 如果没有指定分支，使用默认分支
        if [[ -z "$branch" ]]; then
            branch="${target_branch}"
        fi
        
        if sync_component "$dir" "$repo_url" "$branch" "$target_branch" "$dry_run" "$force_push"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    # 输出统计信息
    log_info "=========================================="
    log_info "同步完成"
    log_info "  成功: ${success_count}"
    log_info "  失败: ${fail_count}"
    log_info "=========================================="
    
    if [[ $fail_count -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
