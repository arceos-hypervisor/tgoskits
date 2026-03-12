#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)

# =============================================================================
# Default Configuration
# =============================================================================

DEFAULT_REPO_FILE="${SCRIPT_DIR}/repos.list"

# 全局变量
declare -A REPO_MAP           # 目录 -> "url|branch" 映射

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    printf '%s\n' \
        "Git Subtree 拉取脚本 - 从远程子仓库拉取组件更新到本地主仓库" \
        "" \
        "注意: CI/CD 自动拉取时会推送到主仓库的 next 分支" \
        "" \
        "用法:" \
        "  scripts/pull.sh [选项]" \
        "" \
        "选项:" \
        "  -f, --file <file>       指定仓库列表文件并拉取其中所有仓库（默认为 scripts/repos.list）" \
        "  -c, --component <dir>   指定要拉取的组件目录（需配合 -b 使用）" \
        "  -b, --branch <branch>   指定要拉取的分支（需配合 -c 使用）" \
        "  -d, --dry-run           仅显示将要执行的操作，不实际执行" \
        "  -h, --help              显示此帮助信息" \
        "" \
        "示例:" \
        "  scripts/pull.sh                         # 显示帮助信息" \
        "  scripts/pull.sh -f                      # 拉取默认文件中所有仓库" \
        "  scripts/pull.sh -f repos.list           # 拉取指定文件中所有仓库" \
        "  scripts/pull.sh -c arm_vcpu -b dev      # 拉取指定组件的 dev 分支" \
        "  scripts/pull.sh --dry-run -f            # 预览拉取操作"
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

# 拉取单个组件的更新
pull_component() {
    local dir="$1"
    local repo_url="$2"
    local branch="$3"
    local dry_run="$4"
    
    log_info "=========================================="
    log_info "拉取组件: ${dir}"
    log_info "  仓库: ${repo_url}"
    log_info "  分支: ${branch:-自动检测}"
    log_info "=========================================="
    
    cd "${ROOT_DIR}"
    
    # 检查工作区是否干净
    if ! git diff --quiet HEAD 2>/dev/null; then
        log_error "工作区有未提交的修改，请先提交或暂存更改"
        git status --short
        return 1
    fi
    
    if [[ ! -d "${dir}" ]]; then
        log_error "组件目录不存在: ${dir}"
        return 1
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] 将执行: git subtree pull --prefix=${dir} ${repo_url} ${branch}"
        return 0
    fi
    
    local remote_name="${dir}"
    if ! git remote | grep -q "^${remote_name}$"; then
        log_info "添加远程仓库: ${remote_name} -> ${repo_url}"
        git remote add "${remote_name}" "${repo_url}"
    fi
    
    log_info "拉取 ${dir} 从 ${repo_url}:${branch} ..."
    if git subtree pull --prefix="${dir}" "${remote_name}" "${branch}" -m "Merge subtree ${dir}/${branch}"; then
        log_success "成功拉取 ${dir} 的更新"
        return 0
    else
        log_error "拉取失败: ${dir}"
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
    local branch=""
    local dry_run="false"
    local -a manual_repos=()
    
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
            -c|--component)
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
    
    log_info "解析仓库列表: ${repo_file}"
    parse_repo_list "${repo_file}"
    log_info "找到 ${#REPO_MAP[@]} 个配置的组件"
    
    declare -A PULL_DIRS
    
    if [[ ${#manual_repos[@]} -gt 0 ]]; then
        if [[ -z "${branch}" ]]; then
            log_error "使用 -r 指定组件时必须使用 -b 指定分支"
            usage
            exit 1
        fi
        log_info "手动指定拉取 ${#manual_repos[@]} 个组件"
        for dir in "${manual_repos[@]}"; do
            # 尝试直接匹配
            if [[ -n "${REPO_MAP[$dir]:-}" ]]; then
                PULL_DIRS["$dir"]=1
            # 尝试添加 components/ 前缀
            elif [[ -n "${REPO_MAP[components/$dir]:-}" ]]; then
                PULL_DIRS["components/$dir"]=1
            # 尝试添加 os/ 前缀
            elif [[ -n "${REPO_MAP[os/$dir]:-}" ]]; then
                PULL_DIRS["os/$dir"]=1
            else
                log_error "未知的组件目录: ${dir}"
                exit 1
            fi
        done
    else
        log_info "拉取文件中所有组件"
        for dir in "${!REPO_MAP[@]}"; do
            PULL_DIRS["$dir"]=1
        done
    fi
    
    log_info "将要拉取的组件: ${!PULL_DIRS[*]}"
    
    local success_count=0
    local fail_count=0
    
    for dir in "${!PULL_DIRS[@]}"; do
        local repo_info="${REPO_MAP[$dir]}"
        local repo_url repo_branch
        
        IFS='|' read -r repo_url repo_branch <<< "$repo_info"
        
        local pull_branch="${branch:-${repo_branch:-main}}"
        
        if pull_component "$dir" "$repo_url" "$pull_branch" "$dry_run"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
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
}

main "$@"
