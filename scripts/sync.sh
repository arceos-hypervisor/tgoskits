#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)

# =============================================================================
# Default Configuration
# =============================================================================

DEFAULT_REPO_FILE="${SCRIPT_DIR}/repos.list"
DEFAULT_BRANCH="main"   # 默认分支

# 全局变量
declare -A REPO_MAP           # 目录 -> "url|branch" 映射
declare -A SUBREPO_DIRS=()    # 检测到的 subrepo 目录

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    printf '%s\n' \
        "Git Subrepo 同步脚本 - 主仓库与子仓库之间的双向同步" \
        "" \
        "用法:" \
        "  scripts/sync.sh <command> [选项]" \
        "" \
        "命令:" \
        "  pull        从子仓库拉取更新到主仓库" \
        "  push        从主仓库推送更新到子仓库" \
        "  status      查看所有 subrepo 的状态" \
        "  init        初始化 subrepo（基于 repos.list）" \
        "" \
        "选项:" \
        "  -f, --file <file>       指定仓库列表文件（默认为 scripts/repos.list）" \
        "  -r, --repo <dir>        指定要同步的组件目录（可多次使用）" \
        "  -b, --branch <branch>   指定分支（默认使用 repos.list 中的配置或 main）" \
        "  -a, --all               同步所有组件" \
        "  -d, --dry-run           仅显示将要执行的操作，不实际执行" \
        "  --force                 强制推送（用于 push 命令）" \
        "  -h, --help              显示此帮助信息" \
        "" \
        "示例:" \
        "  scripts/sync.sh pull -a                       # 拉取所有子仓库的更新" \
        "  scripts/sync.sh push -r arm_vcpu              # 推送指定组件到子仓库" \
        "  scripts/sync.sh status                        # 查看所有 subrepo 状态" \
        "  scripts/sync.sh init                          # 初始化所有 subrepo" \
        "  scripts/sync.sh pull --dry-run -a             # 预览拉取操作"
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

# 检查 git subrepo 是否可用
check_git_subrepo() {
    if ! git subrepo --version &>/dev/null; then
        log_error "git subrepo 未安装"
        log_info "安装方法："
        log_info "  git clone https://github.com/ingydotnet/git-subrepo /opt/git-subrepo"
        log_info "  echo 'source /opt/git-subrepo/.rc' >> ~/.bashrc"
        log_info "  source ~/.bashrc"
        exit 1
    fi
}

# 解析仓库列表文件
parse_repo_list() {
    local repo_file="$1"
    
    if [[ ! -f "${repo_file}" ]]; then
        log_error "仓库列表文件不存在: ${repo_file}"
        exit 1
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        local url branch dir
        IFS='|' read -r url branch dir <<< "$line"
        
        if [[ -z "$dir" ]]; then
            dir="$branch"
            branch=""
        fi
        
        url=$(echo "$url" | xargs)
        branch=$(echo "$branch" | xargs)
        dir=$(echo "$dir" | xargs)
        
        if [[ -n "$url" && -n "$dir" ]]; then
            REPO_MAP["$dir"]="${url}|${branch}"
        fi
    done < "${repo_file}"
}

# 检测所有 subrepo 目录（通过查找 .gitrepo 文件）
detect_subrepos() {
    log_info "检测 subrepo 目录..."
    
    while IFS= read -r gitrepo_file; do
        local dir
        dir=$(dirname "$gitrepo_file")
        # 转换为相对路径
        dir=${dir#${ROOT_DIR}/}
        if [[ -n "$dir" && "$dir" != "." ]]; then
            SUBREPO_DIRS["$dir"]=1
        fi
    done < <(find "${ROOT_DIR}" -name ".gitrepo" -type f 2>/dev/null)
    
    log_info "检测到 ${#SUBREPO_DIRS[@]} 个 subrepo 目录: ${!SUBREPO_DIRS[*]}"
}

# 初始化 subrepo（将现有的目录转换为 subrepo）
init_subrepo() {
    local dir="$1"
    local repo_url="$2"
    local branch="$3"
    local dry_run="$4"
    
    log_info "=========================================="
    log_info "初始化 subrepo: ${dir}"
    log_info "  仓库: ${repo_url}"
    log_info "  分支: ${branch:-main}"
    log_info "=========================================="
    
    cd "${ROOT_DIR}"
    
    if [[ ! -d "${dir}" ]]; then
        log_error "组件目录不存在: ${dir}"
        return 1
    fi
    
    # 检查是否已经是 subrepo
    if [[ -f "${dir}/.gitrepo" ]]; then
        log_warn "${dir} 已经是 subrepo，跳过初始化"
        return 0
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] 将执行: git subrepo clone ${repo_url} ${dir} -b ${branch:-main}"
        return 0
    fi
    
    # 如果目录已存在，使用 git subrepo init 而不是 clone
    # 首先添加 remote
    local remote_name="${dir}"
    if ! git remote | grep -q "^${remote_name}$"; then
        log_info "添加远程仓库: ${remote_name} -> ${repo_url}"
        git remote add "${remote_name}" "${repo_url}"
    fi
    
    # 使用 git subrepo init 初始化
    log_info "初始化 ${dir} 为 subrepo..."
    if git subrepo init "${dir}" -r "${repo_url}" -b "${branch:-main}"; then
        log_success "成功初始化 ${dir}"
        return 0
    else
        log_error "初始化失败: ${dir}"
        return 1
    fi
}

# 从子仓库拉取更新
pull_subrepo() {
    local dir="$1"
    local dry_run="$2"
    local force="$3"
    
    log_info "=========================================="
    log_info "拉取 subrepo: ${dir}"
    log_info "=========================================="
    
    cd "${ROOT_DIR}"
    
    if [[ ! -f "${dir}/.gitrepo" ]]; then
        log_error "${dir} 不是 subrepo（缺少 .gitrepo 文件）"
        return 1
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] 将执行: git subrepo pull ${dir}"
        return 0
    fi
    
    local force_flag=""
    if [[ "$force" == "true" ]]; then
        force_flag="--force"
    fi
    
    log_info "拉取 ${dir} 的更新..."
    if git subrepo pull ${force_flag} "${dir}"; then
        log_success "成功拉取 ${dir} 的更新"
        return 0
    else
        log_error "拉取失败: ${dir}"
        return 1
    fi
}

# 推送更新到子仓库
push_subrepo() {
    local dir="$1"
    local dry_run="$2"
    local force="$3"
    
    log_info "=========================================="
    log_info "推送 subrepo: ${dir}"
    log_info "=========================================="
    
    cd "${ROOT_DIR}"
    
    if [[ ! -f "${dir}/.gitrepo" ]]; then
        log_error "${dir} 不是 subrepo（缺少 .gitrepo 文件）"
        return 1
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] 将执行: git subrepo push ${dir}"
        return 0
    fi
    
    local force_flag=""
    if [[ "$force" == "true" ]]; then
        force_flag="--force"
    fi
    
    log_info "推送 ${dir} 的更新..."
    if git subrepo push ${force_flag} "${dir}"; then
        log_success "成功推送 ${dir} 的更新"
        return 0
    else
        log_error "推送失败: ${dir}"
        return 1
    fi
}

# 查看 subrepo 状态
status_subrepo() {
    local dir="$1"
    
    cd "${ROOT_DIR}"
    
    if [[ ! -f "${dir}/.gitrepo" ]]; then
        log_warn "${dir} 不是 subrepo（缺少 .gitrepo 文件）"
        return 1
    fi
    
    log_info "=========================================="
    log_info "Subrepo 状态: ${dir}"
    log_info "=========================================="
    
    git subrepo status "${dir}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true
    
    local repo_file="${DEFAULT_REPO_FILE}"
    local branch=""
    local dry_run="false"
    local sync_all="false"
    local force="false"
    local -a manual_repos=()
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                repo_file="$2"
                shift 2
                ;;
            -r|--repo)
                manual_repos+=("$2")
                shift 2
                ;;
            -b|--branch)
                branch="$2"
                shift 2
                ;;
            -d|--dry-run)
                dry_run="true"
                shift
                ;;
            -a|--all)
                sync_all="true"
                shift
                ;;
            --force)
                force="true"
                shift
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
    
    cd "${ROOT_DIR}"
    
    # 检查 git subrepo 是否可用
    check_git_subrepo
    
    # 执行命令
    case "$command" in
        pull)
            log_info "=== 执行 Pull 操作 ==="
            detect_subrepos
            
            declare -A SYNC_DIRS
            
            if [[ ${#manual_repos[@]} -gt 0 ]]; then
                log_info "手动指定拉取 ${#manual_repos[@]} 个组件"
                for dir in "${manual_repos[@]}"; do
                    if [[ -n "${SUBREPO_DIRS[$dir]:-}" ]]; then
                        SYNC_DIRS["$dir"]=1
                    else
                        log_error "未知的 subrepo 目录: ${dir}"
                        exit 1
                    fi
                done
            elif [[ "$sync_all" == "true" ]]; then
                log_info "拉取所有 subrepo 模式"
                for dir in "${!SUBREPO_DIRS[@]}"; do
                    SYNC_DIRS["$dir"]=1
                done
            else
                log_error "请使用 -r 指定组件或使用 -a 拉取所有组件"
                usage
                exit 1
            fi
            
            log_info "将要拉取的组件: ${!SYNC_DIRS[*]}"
            
            local success_count=0
            local fail_count=0
            
            for dir in "${!SYNC_DIRS[@]}"; do
                if pull_subrepo "$dir" "$dry_run" "$force"; then
                    ((success_count++))
                else
                    ((fail_count++))
                fi
            done
            
            log_info "=========================================="
            log_info "拉取完成"
            log_info "  成功: ${success_count}"
            log_info "  失败: ${fail_count}"
            log_info "=========================================="
            
            if [[ $fail_count -gt 0 ]]; then
                exit 1
            fi
            ;;
            
        push)
            log_info "=== 执行 Push 操作 ==="
            detect_subrepos
            
            declare -A SYNC_DIRS
            
            if [[ ${#manual_repos[@]} -gt 0 ]]; then
                log_info "手动指定推送 ${#manual_repos[@]} 个组件"
                for dir in "${manual_repos[@]}"; do
                    if [[ -n "${SUBREPO_DIRS[$dir]:-}" ]]; then
                        SYNC_DIRS["$dir"]=1
                    else
                        log_error "未知的 subrepo 目录: ${dir}"
                        exit 1
                    fi
                done
            elif [[ "$sync_all" == "true" ]]; then
                log_info "推送所有 subrepo 模式"
                for dir in "${!SUBREPO_DIRS[@]}"; do
                    SYNC_DIRS["$dir"]=1
                done
            else
                log_error "请使用 -r 指定组件或使用 -a 推送所有组件"
                usage
                exit 1
            fi
            
            log_info "将要推送的组件: ${!SYNC_DIRS[*]}"
            
            local success_count=0
            local fail_count=0
            
            for dir in "${!SYNC_DIRS[@]}"; do
                if push_subrepo "$dir" "$dry_run" "$force"; then
                    ((success_count++))
                else
                    ((fail_count++))
                fi
            done
            
            log_info "=========================================="
            log_info "推送完成"
            log_info "  成功: ${success_count}"
            log_info "  失败: ${fail_count}"
            log_info "=========================================="
            
            if [[ $fail_count -gt 0 ]]; then
                exit 1
            fi
            ;;
            
        status)
            log_info "=== 查看 Subrepo 状态 ==="
            detect_subrepos
            
            if [[ ${#SUBREPO_DIRS[@]} -eq 0 ]]; then
                log_warn "没有检测到任何 subrepo"
                exit 0
            fi
            
            for dir in "${!SUBREPO_DIRS[@]}"; do
                status_subrepo "$dir"
            done
            ;;
            
        init)
            log_info "=== 初始化 Subrepo ==="
            parse_repo_list "${repo_file}"
            log_info "找到 ${#REPO_MAP[@]} 个配置的组件"
            
            declare -A INIT_DIRS
            
            if [[ ${#manual_repos[@]} -gt 0 ]]; then
                log_info "手动指定初始化 ${#manual_repos[@]} 个组件"
                for dir in "${manual_repos[@]}"; do
                    if [[ -n "${REPO_MAP[$dir]:-}" ]]; then
                        INIT_DIRS["$dir"]=1
                    else
                        log_error "未知的组件目录: ${dir}"
                        exit 1
                    fi
                done
            elif [[ "$sync_all" == "true" ]]; then
                log_info "初始化所有组件模式"
                for dir in "${!REPO_MAP[@]}"; do
                    INIT_DIRS["$dir"]=1
                done
            else
                log_error "请使用 -r 指定组件或使用 -a 初始化所有组件"
                usage
                exit 1
            fi
            
            log_info "将要初始化的组件: ${!INIT_DIRS[*]}"
            
            local success_count=0
            local fail_count=0
            
            for dir in "${!INIT_DIRS[@]}"; do
                local repo_info="${REPO_MAP[$dir]}"
                local repo_url repo_branch
                
                IFS='|' read -r repo_url repo_branch <<< "$repo_info"
                
                local init_branch="${branch:-${repo_branch:-main}}"
                
                if init_subrepo "$dir" "$repo_url" "$init_branch" "$dry_run"; then
                    ((success_count++))
                else
                    ((fail_count++))
                fi
            done
            
            log_info "=========================================="
            log_info "初始化完成"
            log_info "  成功: ${success_count}"
            log_info "  失败: ${fail_count}"
            log_info "=========================================="
            
            if [[ $fail_count -gt 0 ]]; then
                exit 1
            fi
            ;;
            
        help|--help|-h)
            usage
            exit 0
            ;;
            
        *)
            log_error "未知命令: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
