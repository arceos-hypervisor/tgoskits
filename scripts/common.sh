#!/usr/bin/env bash
# Common functions for component crate discovery
# This script can be sourced by other scripts OR executed directly
# 
# When executed directly:
#   ./common.sh              # 输出所有组件仓库相对路径
#   ./common.sh --names      # 输出所有组件仓库名称
#   ./common.sh --paths      # 输出所有组件仓库绝对路径
#   ./common.sh --help       # 显示帮助信息

set -euo pipefail

# =============================================================================
# Setup ROOT_DIR
# =============================================================================

# Determine ROOT_DIR whether sourced or executed directly
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
    ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
else
    ROOT_DIR="$(pwd -P)"
    SCRIPT_DIR="${ROOT_DIR}/scripts"
fi

# =============================================================================
# Component Discovery Functions
# =============================================================================

# Directories to exclude from component scanning
# These are special directories that are not component crates
EXCLUDE_DIRS=(
    ".git"
    ".github"
    "scripts"
    "target"
    "doc"
    "docs"
    "examples"
    "tests"
    "tools"
)

# Cache for component list (to avoid repeated scanning)
_COMPONENTS_CACHE=""

# Scan all valid component crates and return their relative paths
# Valid component: top-level directory that contains Cargo.toml and is not in EXCLUDE_DIRS
# Output format: axvisor, arceos, axaddrspace, etc.
scan_components() {
    # Return cached result if available
    if [[ -n "${_COMPONENTS_CACHE}" ]]; then
        printf '%s\n' "${_COMPONENTS_CACHE}"
        return
    fi
    
    local components=()
    
    # Scan top-level directories
    while IFS= read -r -d '' dir; do
        local name
        name=$(basename "${dir}")
        
        # Skip excluded directories
        local skip=false
        for exclude in "${EXCLUDE_DIRS[@]}"; do
            if [[ "${name}" == "${exclude}" ]]; then
                skip=true
                break
            fi
        done
        
        if [[ "${skip}" == true ]]; then
            continue
        fi
        
        # Check if it's a valid crate (has Cargo.toml)
        if [[ -f "${dir}/Cargo.toml" ]]; then
            components+=("${name}")
        fi
    done < <(find "${ROOT_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    
    # Cache and output
    if [[ ${#components[@]} -gt 0 ]]; then
        _COMPONENTS_CACHE=$(printf '%s\n' "${components[@]}")
        printf '%s\n' "${components[@]}"
    fi
}

# Get all crate names
# Output: axvisor, arceos, axaddrspace, etc.
get_all_crate_names() {
    scan_components
}

# Find crate relative path by name (e.g., "axvcpu" -> "axvcpu")
# Returns empty string if not found
find_crate_rel_path() {
    local crate_name="$1"
    while IFS= read -r name; do
        if [[ "${name}" == "${crate_name}" ]]; then
            echo "${name}"
            return 0
        fi
    done < <(scan_components)
    return 1
}

# Find crate absolute path by name (e.g., "axvcpu" -> "/home/user/tgoskits/axvcpu")
# Returns empty string if not found
find_crate_abs_path() {
    local crate_name="$1"
    local rel_path
    rel_path=$(find_crate_rel_path "${crate_name}")
    if [[ -n "${rel_path}" ]]; then
        echo "${ROOT_DIR}/${rel_path}"
    fi
}

# Get component name from relative path
get_component_name() {
    local rel_path="$1"
    basename "${rel_path}"
}

# Get component absolute path from relative path
get_component_path() {
    local rel_path="$1"
    echo "${ROOT_DIR}/${rel_path}"
}

# Check if a component is a git repository
is_git_repo() {
    local rel_path="$1"
    local abs_path="${ROOT_DIR}/${rel_path}"
    [[ -d "${abs_path}/.git" || -f "${abs_path}/.git" ]]
}

# Check if a component has uncommitted changes
has_changes() {
    local rel_path="$1"
    local abs_path="${ROOT_DIR}/${rel_path}"
    
    if ! is_git_repo "${rel_path}"; then
        return 1
    fi
    
    pushd "${abs_path}" >/dev/null
    local result
    result=$(git status --porcelain 2>/dev/null)
    popd >/dev/null
    
    [[ -n "${result}" ]]
}

# Get current branch of a component
get_current_branch() {
    local rel_path="$1"
    local abs_path="${ROOT_DIR}/${rel_path}"
    
    if ! is_git_repo "${rel_path}"; then
        echo "unknown"
        return
    fi
    
    pushd "${abs_path}" >/dev/null
    git branch --show-current 2>/dev/null || echo "HEAD"
    popd >/dev/null
}

# =============================================================================
# Output Functions
# =============================================================================

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

die() { printf '%b✗%b %s\n' "${RED}" "${NC}" "$*" >&2; exit 1; }
info() { printf '%b→%b %s\n' "${BLUE}" "${NC}" "$*"; }
success() { printf '%b✓%b %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%b⚠%b %s\n' "${YELLOW}" "${NC}" "$*"; }

# =============================================================================
# Command Line Interface (when executed directly)
# =============================================================================

# Check if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    MODE="${1:---relative}"
    
    case "${MODE}" in
        --names|-n)
            scan_components | while IFS= read -r rel_path; do
                basename "${rel_path}"
            done
            ;;
        --paths|-p)
            scan_components | while IFS= read -r rel_path; do
                echo "${ROOT_DIR}/${rel_path}"
            done
            ;;
        --relative|-r)
            scan_components
            ;;
        --help|-h)
            cat << EOHELP
用法: $0 [选项]

选项:
  -r, --relative    输出相对路径（默认）: axvisor, arceos
  -n, --names       只输出名称: axvisor, arceos（与 --relative 相同）
  -p, --paths       输出绝对路径: /home/user/tgoskits/axvisor
  -h, --help        显示帮助信息

说明:
  扫描仓库根目录下的所有组件（包含 Cargo.toml 的目录）
  自动排除特殊目录：.git, .github, scripts, target, doc, docs, examples, tests, tools

示例:
  # 在脚本中获取组件数组
  source scripts/common.sh
  mapfile -t components < <(scan_components)
  
  # 直接执行输出所有组件
  ./scripts/common.sh
  
  # 只获取名称
  ./scripts/common.sh --names
  
  # 获取绝对路径
  ./scripts/common.sh --paths
  
  # 查找特定组件的路径
  source scripts/common.sh
  find_crate_abs_path "axvisor"
EOHELP
            ;;
        *)
            scan_components
            ;;
    esac
fi
