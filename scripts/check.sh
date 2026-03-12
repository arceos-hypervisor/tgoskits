#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)

# Source common functions
source "${SCRIPT_DIR}/common.sh"

DEFAULT_TARGET="aarch64-unknown-none-softfloat"
RUSTDOCFLAGS="-D rustdoc::broken_intra_doc_links"

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    printf '%s\n' \
        "组件检查脚本 - 对指定或全部组件进行代码检查" \
        "" \
        "用法:" \
        "  scripts/check.sh <crate|all> [target]" \
        "" \
        "参数:" \
        "  crate   组件名称，如 axvcpu、axaddrspace 等" \
        "  all     检查所有组件" \
        "  target  可选，目标平台（默认为 ${DEFAULT_TARGET}）" \
        "" \
        "检查项:" \
        "  - 代码格式 (cargo fmt --check)" \
        "  - 构建 (cargo build --all-features)" \
        "  - Clippy (cargo clippy -D warnings)" \
        "  - 文档 (cargo doc --no-deps)" \
        "" \
        "示例:" \
        "  scripts/check.sh axvcpu                        # 检查 axvcpu" \
        "  scripts/check.sh all                           # 检查所有组件" \
        "  scripts/check.sh all riscv64gc-unknown-none-elf  # 指定目标平台"
}

# =============================================================================
# Check Functions
# =============================================================================

check_fmt() {
    local name="$1"
    info "[${name}] 检查代码格式"
    if cargo fmt --all -- --check >/dev/null 2>&1; then
        success "[${name}] 代码格式检查通过"
        return 0
    else
        warn "[${name}] 代码格式检查失败"
        return 1
    fi
}

check_build() {
    local name="$1" target="$2"
    info "[${name}] 构建检查 (target: ${target})"
    if cargo build --target "$target" --all-features >/dev/null 2>&1; then
        success "[${name}] 构建检查通过"
        return 0
    else
        warn "[${name}] 构建检查失败"
        return 1
    fi
}

check_clippy() {
    local name="$1" target="$2"
    info "[${name}] Clippy 检查"
    if cargo clippy --target "$target" --all-features -- -D warnings >/dev/null 2>&1; then
        success "[${name}] Clippy 检查通过"
        return 0
    else
        warn "[${name}] Clippy 检查失败"
        return 1
    fi
}

check_doc() {
    local name="$1" target="$2"
    info "[${name}] 文档构建检查"
    if RUSTDOCFLAGS="${RUSTDOCFLAGS}" cargo doc --no-deps --target "$target" --all-features >/dev/null 2>&1; then
        success "[${name}] 文档构建检查通过"
        return 0
    else
        warn "[${name}] 文档构建检查失败"
        return 1
    fi
}

check_crate() {
    local rel_path="$1" target="$2"
    local name
    name=$(get_component_name "${rel_path}")
    local abs_path
    abs_path=$(get_component_path "${rel_path}")
    
    printf '\n%b========== %s ==========%b\n' "${BLUE}" "${name}" "${NC}"
    
    pushd "${abs_path}" >/dev/null
    local failed=0
    
    if ! check_fmt "${name}"; then
        failed=1
    elif ! check_build "${name}" "${target}"; then
        failed=1
    elif ! check_clippy "${name}" "${target}"; then
        failed=1
    elif ! check_doc "${name}" "${target}"; then
        failed=1
    fi
    
    popd >/dev/null
    
    if [[ ${failed} -eq 0 ]]; then
        success "[${name}] 所有检查通过"
        return 0
    else
        return 1
    fi
}

check_all() {
    local target="${1:-${DEFAULT_TARGET}}"
    local components passed=() failed=()
    mapfile -t components < <(scan_components)
    
    info "检查所有组件 (${#components[@]} 个)..."
    
    for rel_path in "${components[@]}"; do
        if check_crate "${rel_path}" "${target}"; then
            passed+=("$(get_component_name "${rel_path}")")
        else
            failed+=("$(get_component_name "${rel_path}")")
        fi
    done
    
    printf '\n%b========================================%b\n' "${BLUE}" "${NC}"
    printf '%b           检查结果汇总           %b\n' "${BLUE}" "${NC}"
    printf '%b========================================%b\n' "${BLUE}" "${NC}"
    
    if [[ ${#passed[@]} -gt 0 ]]; then
        success "通过 ${#passed[@]} 个:"
        for name in "${passed[@]}"; do
            printf '  %b✓%b %s\n' "${GREEN}" "${NC}" "${name}"
        done
        printf '\n'
    fi
    
    if [[ ${#failed[@]} -gt 0 ]]; then
        printf '%b失败 %d 个:%b\n' "${RED}" "${#failed[@]}" "${NC}"
        for name in "${failed[@]}"; do
            printf '  %b✗%b %s\n' "${RED}" "${NC}" "${name}"
        done
        printf '\n'
        die "检查完成，共 ${#failed[@]} 个组件失败"
    else
        success "所有 ${#passed[@]} 个组件检查通过"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    local crate="" target="${DEFAULT_TARGET}"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage; exit 0
                ;;
            all)
                crate="all"
                if [[ -n "${2:-}" ]] && [[ ! "$2" =~ ^- ]]; then
                    target="$2"
                    shift
                fi
                ;;
            *)
                if [[ -z "${crate}" ]]; then
                    crate="$1"
                fi
                ;;
        esac
        shift
    done
    
    # 无参数时显示帮助信息
    if [[ -z "${crate}" ]]; then
        usage; exit 0
    fi
    
    cd "${ROOT_DIR}"
    
    if [[ "${crate}" == "all" ]]; then
        check_all "${target}"
    else
        local rel_path
        rel_path=$(find_crate_rel_path "${crate}")
        
        if [[ -z "${rel_path}" ]]; then
            die "组件 ${crate} 不存在"
        fi
        check_crate "${rel_path}" "${target}"
    fi
}

main "$@"
