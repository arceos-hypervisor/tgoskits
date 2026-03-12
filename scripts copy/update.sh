#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    printf '%s\n' \
        "更新 .gitrepo 文件中的 parent commit ID" \
        "" \
        "用法:" \
        "  scripts/update.sh [选项]" \
        "" \
        "选项:" \
        "  -h, --help     显示此帮助信息" \
        "" \
        "说明:" \
        "  此脚本会扫描所有 .gitrepo 文件，并将其中的 parent commit ID" \
        "  更新为当前主仓库的最新 commit ID。" \
        "" \
        "  这在以下情况下有用：" \
        "  1. 手动同步后需要更新 parent commit" \
        "  2. CI 自动同步后需要记录 parent commit" \
        "  3. 修复不一致的 .gitrepo 文件"
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
# Main
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
    
    # 获取当前主仓库的 commit ID
    PARENT_COMMIT_ID=$(git log -1 --pretty=%H | head -n 1)
    log_info "当前主仓库 commit ID: ${PARENT_COMMIT_ID}"
    
    # 查找所有 .gitrepo 文件
    local gitrepo_files=()
    while IFS= read -r file; do
        gitrepo_files+=("$file")
    done < <(find "${ROOT_DIR}" -name ".gitrepo" -type f 2>/dev/null)
    
    if [[ ${#gitrepo_files[@]} -eq 0 ]]; then
        log_warn "没有找到任何 .gitrepo 文件"
        exit 0
    fi
    
    log_info "找到 ${#gitrepo_files[@]} 个 .gitrepo 文件"
    
    local updated_count=0
    
    for gitrepo_file in "${gitrepo_files[@]}"; do
        local dir
        dir=$(dirname "$gitrepo_file")
        # 转换为相对路径
        dir=${dir#${ROOT_DIR}/}
        
        log_info "更新 ${dir}/.gitrepo ..."
        
        # 检查文件中是否有 parent 行
        if grep -q "^\tparent = " "$gitrepo_file"; then
            # 获取旧的 parent commit
            local old_parent
            old_parent=$(grep "^\tparent = " "$gitrepo_file" | awk '{print $3}')
            
            # 更新 parent commit
            sed -i "s/^\tparent = .*/\tparent = ${PARENT_COMMIT_ID}/" "$gitrepo_file"
            
            log_success "  ${dir}: ${old_parent} -> ${PARENT_COMMIT_ID}"
            ((updated_count++))
        else
            log_warn "  ${dir}: 未找到 parent 行，跳过"
        fi
    done
    
    log_info "=========================================="
    log_info "更新完成"
    log_info "  更新文件数: ${updated_count}"
    log_info "=========================================="
    
    # 检查是否有变更
    if git diff --quiet && git diff --staged --quiet; then
        log_info "没有变更需要提交"
    else
        log_info "检测到变更，可以使用以下命令提交："
        log_info "  git add -A"
        log_info "  git commit -m 'chore: update .gitrepo parent commits'"
    fi
}

main "$@"
