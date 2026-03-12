#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)

# =============================================================================
# Default Configuration
# =============================================================================

DEFAULT_REPO_FILE="${SCRIPT_DIR}/repos.list"

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    printf '%s\n' \
        "Git Subtree 管理脚本 - 将多个组件仓库合并到当前仓库" \
        "" \
        "用法:" \
        "  scripts/repos.sh [选项]" \
        "" \
        "选项:" \
        "  -f, --file <file>    指定仓库列表文件（默认为 scripts/repos.list）" \
        "  -r, --repo <repo>    指定单个仓库，格式: url,branch,dir（例如: https://github.com/user/repo,main,mydir）" \
        "  -h, --help           显示此帮助信息" \
        "" \
        "仓库列表文件格式:" \
        "  每行一个仓库，格式: <仓库URL>|分支名|<目标目录>" \
        "  - 分支名可选，留空则自动检测（优先 main，其次 master，最后默认分支）" \
        "  - 以 # 开头的行为注释，空行会被忽略" \
        "" \
        "示例:" \
        "  scripts/repos.sh                                                # 使用默认的 repos.list 文件" \
        "  scripts/repos.sh -f custom.list                                 # 使用自定义的仓库列表文件" \
        "  scripts/repos.sh -r https://github.com/user/repo,main,mydir     # 添加单个仓库（指定分支）" \
        "  scripts/repos.sh -r https://github.com/user/repo,,mydir         # 添加单个仓库（自动检测分支）"
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

# 合并单个仓库
# 参数: $1 = 仓库URL, $2 = 目标目录, $3 = 分支名（可选）
merge_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="$3"
    
    log_info "=========================================="
    log_info "合并仓库: ${repo_url} -> ${target_dir}"
    if [[ -n "${branch}" ]]; then
        log_info "指定分支: ${branch}"
    else
        log_info "分支: 自动检测"
    fi
    log_info "=========================================="
    
    # 切换到仓库根目录
    cd "${ROOT_DIR}"
    
    # 检查目标目录是否已存在
    if [[ -d "${target_dir}" ]]; then
        log_warn "目录 ${target_dir} 已存在，跳过..."
        return 0
    fi
    
    # 添加远程仓库
    git remote add "${target_dir}" "${repo_url}" 2>/dev/null || git remote set-url "${target_dir}" "${repo_url}"
    
    # 获取远程仓库数据（不获取标签以避免冲突）
    log_info "获取远程仓库数据..."
    if ! git fetch "${target_dir}" --no-tags; then
        log_error "获取远程仓库数据失败"
        git remote remove "${target_dir}" 2>/dev/null || true
        return 1
    fi
    
    # 如果没有指定分支，自动检测
    if [[ -z "${branch}" ]]; then
        # 优先 main，其次 master，最后默认分支
        if git rev-parse "${target_dir}/main" >/dev/null 2>&1; then
            branch="main"
        elif git rev-parse "${target_dir}/master" >/dev/null 2>&1; then
            branch="master"
        else
            # 使用默认分支
            branch=$(git remote show "${target_dir}" 2>/dev/null | grep "HEAD branch" | cut -d":" -f2 | tr -d ' ' || echo "main")
        fi
        log_info "自动检测到分支: ${branch}"
    fi
    
    # 使用 subtree 合并（保留历史）
    log_info "执行 git subtree add..."
    if ! git subtree add --prefix="${target_dir}" "${target_dir}" "${branch}"; then
        log_error "合并 ${target_dir} 失败"
        git remote remove "${target_dir}" 2>/dev/null || true
        return 1
    fi
    
    # 清理远程仓库
    git remote remove "${target_dir}" 2>/dev/null || true
    
    log_success "成功合并 ${target_dir}"
    echo ""
    return 0
}

# 解析仓库列表文件
# 参数: $1 = 文件路径
parse_repo_file() {
    local file_path="$1"
    
    if [[ ! -f "${file_path}" ]]; then
        log_error "仓库列表文件不存在: ${file_path}"
        exit 1
    fi
    
    log_info "从文件读取仓库列表: ${file_path}"
    
    local line_num=0
    local success_count=0
    local fail_count=0
    local skip_count=0
    
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_num=$((line_num + 1))
        
        # 跳过空行和注释
        if [[ -z "${line}" ]] || [[ "${line}" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # 去除前后空格
        line=$(echo "${line}" | xargs)
        
        # 解析格式：url|branch|dir 或 url|dir
        local repo_url=""
        local branch=""
        local target_dir=""
        
        # 统计 | 的数量
        local pipe_count=$(echo "${line}" | tr -cd '|' | wc -c)
        
        if [[ ${pipe_count} -eq 2 ]]; then
            # 新格式：url|branch|dir
            repo_url=$(echo "${line}" | cut -d'|' -f1)
            branch=$(echo "${line}" | cut -d'|' -f2)
            target_dir=$(echo "${line}" | cut -d'|' -f3)
        elif [[ ${pipe_count} -eq 1 ]]; then
            # 旧格式：url|dir（向后兼容）
            repo_url=$(echo "${line}" | cut -d'|' -f1)
            target_dir=$(echo "${line}" | cut -d'|' -f2)
            branch=""
        else
            log_warn "第 ${line_num} 行格式错误，跳过: ${line}"
            skip_count=$((skip_count + 1))
            continue
        fi
        
        # 验证必填字段
        if [[ -z "${repo_url}" ]] || [[ -z "${target_dir}" ]]; then
            log_warn "第 ${line_num} 行缺少必填字段，跳过: ${line}"
            skip_count=$((skip_count + 1))
            continue
        fi
        
        if merge_repo "${repo_url}" "${target_dir}" "${branch}"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done < "${file_path}"
    
    # 输出统计信息
    echo ""
    log_info "=========================================="
    log_info "处理完成"
    log_info "=========================================="
    log_info "成功: ${success_count}"
    log_info "失败: ${fail_count}"
    log_info "跳过: ${skip_count}"
}

# 解析单个仓库参数
# 参数: $1 = 仓库定义（格式: url,branch,dir）
parse_single_repo() {
    local repo_def="$1"
    
    # 统计逗号的数量
    local comma_count=$(echo "${repo_def}" | tr -cd ',' | wc -c)
    
    local repo_url=""
    local branch=""
    local target_dir=""
    
    if [[ ${comma_count} -eq 2 ]]; then
        # 格式：url,branch,dir
        repo_url=$(echo "${repo_def}" | cut -d',' -f1)
        branch=$(echo "${repo_def}" | cut -d',' -f2)
        target_dir=$(echo "${repo_def}" | cut -d',' -f3)
    elif [[ ${comma_count} -eq 1 ]]; then
        # 格式：url,dir（向后兼容）
        repo_url=$(echo "${repo_def}" | cut -d',' -f1)
        target_dir=$(echo "${repo_def}" | cut -d',' -f2)
        branch=""
    else
        log_error "仓库参数格式错误，应为: url,branch,dir 或 url,dir"
        exit 1
    fi
    
    # 验证必填字段
    if [[ -z "${repo_url}" ]] || [[ -z "${target_dir}" ]]; then
        log_error "仓库参数格式错误，url 和 dir 不能为空"
        exit 1
    fi
    
    log_info "处理单个仓库: ${repo_url} -> ${target_dir}"
    if [[ -n "${branch}" ]]; then
        log_info "指定分支: ${branch}"
    else
        log_info "分支: 自动检测"
    fi
    
    if merge_repo "${repo_url}" "${target_dir}" "${branch}"; then
        log_success "仓库合并成功"
    else
        log_error "仓库合并失败"
        exit 1
    fi
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    local repo_file="${DEFAULT_REPO_FILE}"
    local single_repo=""
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                if [[ $# -lt 2 ]]; then
                    log_error "选项 $1 需要一个参数"
                    usage
                    exit 1
                fi
                repo_file="$2"
                shift 2
                ;;
            -r|--repo)
                if [[ $# -lt 2 ]]; then
                    log_error "选项 $1 需要一个参数"
                    usage
                    exit 1
                fi
                single_repo="$2"
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
    
    # 确保在仓库根目录
    if [[ ! -d "${ROOT_DIR}/.git" ]]; then
        log_error "未找到 .git 目录，请确保在 Git 仓库根目录运行此脚本"
        exit 1
    fi
    
    # 执行操作
    if [[ -n "${single_repo}" ]]; then
        # 处理单个仓库
        parse_single_repo "${single_repo}"
    else
        # 处理仓库列表文件
        parse_repo_file "${repo_file}"
    fi
}

# 执行主函数
main "$@"
