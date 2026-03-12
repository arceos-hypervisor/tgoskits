#!/usr/bin/env python3
"""
Git Subtree Manager - Manage git subtree repositories using CSV configuration

This script provides commands to add, remove, pull, and push git subtrees
based on a CSV configuration file.
"""

import csv
import os
import sys
import argparse
import subprocess
import re
from pathlib import Path
from typing import Optional, List, Dict, Tuple
from dataclasses import dataclass, field, astuple


# Default paths
CSV_PATH = Path(__file__).parent / "repos.csv"


@dataclass
class Repo:
    """Repository configuration entry."""
    url: str
    branch: str = ""
    target_dir: str = ""
    category: str = ""
    description: str = ""

    def __iter__(self):
        return iter(astuple(self))

    @property
    def repo_name(self) -> str:
        """Extract repo name from URL."""
        return self.url.rstrip('/').split('/')[-1]


class CSVManager:
    """Manages CSV file operations for repository configurations."""

    def __init__(self, csv_path: Path = CSV_PATH):
        self.csv_path = csv_path
        self._repos: Optional[List[Repo]] = None

    def load_repos(self) -> List[Repo]:
        """Load repositories from CSV file."""
        if self._repos is not None:
            return self._repos

        repos = []
        if not self.csv_path.exists():
            return repos

        with open(self.csv_path, 'r', newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            for row in reader:
                repos.append(Repo(
                    url=row.get('url', ''),
                    branch=row.get('branch', ''),
                    target_dir=row.get('target_dir', ''),
                    category=row.get('category', ''),
                    description=row.get('description', '')
                ))
        self._repos = repos
        return repos

    def save_repos(self, repos: Optional[List[Repo]] = None) -> None:
        """Save repositories to CSV file."""
        if repos is not None:
            self._repos = repos
        elif self._repos is None:
            self._repos = []

        with open(self.csv_path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(['url', 'branch', 'target_dir', 'category', 'description'])
            for repo in self._repos:
                writer.writerow(list(repo))

    def add_repo(self, url: str, target_dir: str, branch: str = "",
                 category: str = "", description: str = "", skip_if_exists: bool = False) -> bool:
        """Add a new repository entry to the CSV. Returns True if added, False if already exists."""
        repos = self.load_repos()

        # Check for duplicate URL or target_dir
        for repo in repos:
            if repo.url == url:
                if skip_if_exists:
                    return False  # Already exists, skip
                raise ValueError(f"Repository with URL '{url}' already exists")
            if repo.target_dir == target_dir:
                if skip_if_exists:
                    return False  # Already exists, skip
                raise ValueError(f"Repository with target_dir '{target_dir}' already exists")

        new_repo = Repo(
            url=url,
            branch=branch,
            target_dir=target_dir,
            category=category,
            description=description
        )
        repos.append(new_repo)
        self.save_repos(repos)
        return True

    def remove_repo(self, repo_name: str) -> Repo:
        """Remove a repository entry by repo name. Returns the removed repo."""
        repos = self.load_repos()

        for i, repo in enumerate(repos):
            if repo.repo_name.lower() == repo_name.lower():
                removed = repos.pop(i)
                self.save_repos(repos)
                return removed

        raise ValueError(f"Repository '{repo_name}' not found in CSV")

    def find_repo(self, repo_name: str) -> Optional[Repo]:
        """Find a repository by repo name."""
        repos = self.load_repos()

        for repo in repos:
            if repo.repo_name.lower() == repo_name.lower():
                return repo

        return None

    def list_repos(self) -> List[Repo]:
        """List all repositories."""
        return self.load_repos()


class GitSubtreeManager:
    """Manages git subtree operations."""

    def __init__(self, csv_manager: CSVManager):
        self.csv_manager = csv_manager

    @staticmethod
    def _run_command(cmd: List[str], check: bool = True) -> subprocess.CompletedProcess:
        """Run a shell command and return the result."""
        print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, check=check, capture_output=False, text=True)
        return result

    @staticmethod
    def get_repo_name(url: str) -> str:
        """Extract repo name from URL."""
        return url.rstrip('/').split('/')[-1]

    def is_added(self, target_dir: str) -> bool:
        """Check if a subtree is already added."""
        path = Path(target_dir)
        if not path.exists():
            return False

        # Check if target_dir is tracked by git
        result = subprocess.run(
            ['git', 'ls-files', '--error-unmatch', str(path)],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def add_subtree(self, url: str, target_dir: str, branch: str = "") -> None:
        """Add a new git subtree."""
        if branch == "":
            branch = "main"

        if self.is_added(target_dir):
            print(f"Subtree at '{target_dir}' already exists.")
            return

        repo_name = self.get_repo_name(url)
        cmd = [
            'git', 'subtree', 'add',
            '--prefix=' + target_dir,
            url,
            branch,
            '-m', f'Add subtree {repo_name}'
        ]
        self._run_command(cmd)

    def pull_subtree(self, url: str, target_dir: str, branch: str = "") -> None:
        """Pull updates from a git subtree."""
        if branch == "":
            branch = "main"

        if not self.is_added(target_dir):
            print(f"Subtree at '{target_dir}' not found. Adding...")
            self.add_subtree(url, target_dir, branch)
            return

        repo_name = self.get_repo_name(url)
        cmd = [
            'git', 'subtree', 'pull',
            '--prefix=' + target_dir,
            url,
            branch,
            '-m', f'Merge subtree {repo_name}/{branch}'
        ]
        self._run_command(cmd)

    def push_subtree(self, url: str, target_dir: str, branch: str = "") -> None:
        """Push local changes to a git subtree."""
        if branch == "":
            branch = "main"

        if not self.is_added(target_dir):
            raise ValueError(f"Subtree at '{target_dir}' not found. Cannot push.")

        cmd = [
            'git', 'subtree', 'push',
            '--prefix=' + target_dir,
            url,
            branch
        ]
        self._run_command(cmd)


def cmd_add(args: argparse.Namespace) -> int:
    """Handle the 'add' command."""
    csv_manager = CSVManager(args.csv)
    git_manager = GitSubtreeManager(csv_manager)

    # Validate required arguments
    if not args.url:
        print("Error: --url is required", file=sys.stderr)
        return 1

    if not args.target:
        print("Error: --target is required", file=sys.stderr)
        return 1

    url = args.url
    target_dir = args.target
    branch = args.branch or ""
    category = args.category or ""
    description = args.description or ""

    # Add to CSV (skip if already exists)
    added = csv_manager.add_repo(url, target_dir, branch, category, description, skip_if_exists=True)
    if added:
        print(f"Added to CSV: {url} -> {target_dir}")
    else:
        print(f"Repository already exists in CSV: {url}")

    # Add git subtree (this will check if already added to git)
    try:
        git_manager.add_subtree(url, target_dir, branch)
        print(f"Successfully added subtree: {target_dir}")
    except subprocess.CalledProcessError as e:
        print(f"Error adding git subtree: {e}", file=sys.stderr)
        return 1

    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    """Handle the 'remove' command."""
    csv_manager = CSVManager(args.csv)

    if not args.repo_name:
        print("Error: repo_name is required", file=sys.stderr)
        return 1

    repo_name = args.repo_name

    # Find and display repo before removing
    repo = csv_manager.find_repo(repo_name)
    if not repo:
        print(f"Error: Repository '{repo_name}' not found", file=sys.stderr)
        return 1

    print(f"Found repository: {repo.repo_name}")
    print(f"  URL: {repo.url}")
    print(f"  Target: {repo.target_dir}")
    print(f"  Category: {repo.category}")

    # Remove from CSV
    try:
        removed = csv_manager.remove_repo(repo_name)
        print(f"Removed '{removed.repo_name}' from CSV")
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    # Ask about removing directory
    if args.force or args.remove_dir:
        target_dir = removed.target_dir
        if target_dir and Path(target_dir).exists():
            try:
                subprocess.run(['git', 'rm', '-r', target_dir], check=True)
                print(f"Removed directory: {target_dir}")
            except subprocess.CalledProcessError as e:
                print(f"Warning: Could not remove directory: {e}", file=sys.stderr)
    else:
        print("Note: The directory still exists. Use --remove-dir to remove it.")

    return 0


def cmd_pull(args: argparse.Namespace) -> int:
    """Handle the 'pull' command."""
    csv_manager = CSVManager(args.csv)
    git_manager = GitSubtreeManager(csv_manager)

    if args.all:
        repos = csv_manager.list_repos()
        if not repos:
            print("No repositories found in CSV")
            return 0
    else:
        if not args.repo_name:
            print("Error: repo_name is required (or use --all)", file=sys.stderr)
            return 1

        repo = csv_manager.find_repo(args.repo_name)
        if not repo:
            print(f"Error: Repository '{args.repo_name}' not found", file=sys.stderr)
            return 1
        repos = [repo]

    # Track skipped repos
    skipped = []

    for repo in repos:
        if not repo.target_dir:
            skipped.append(f"{repo.repo_name} (no target_dir)")
            continue

        try:
            print(f"\nPulling {repo.repo_name}...")
            git_manager.pull_subtree(repo.url, repo.target_dir, repo.branch)
        except subprocess.CalledProcessError as e:
            print(f"Error pulling {repo.repo_name}: {e}", file=sys.stderr)
            if not args.all:
                return 1

    if skipped:
        print("\nSkipped repositories:")
        for s in skipped:
            print(f"  - {s}")

    return 0


def cmd_push(args: argparse.Namespace) -> int:
    """Handle the 'push' command."""
    csv_manager = CSVManager(args.csv)
    git_manager = GitSubtreeManager(csv_manager)

    if args.all:
        repos = csv_manager.list_repos()
        if not repos:
            print("No repositories found in CSV")
            return 0
    else:
        if not args.repo_name:
            print("Error: repo_name is required (or use --all)", file=sys.stderr)
            return 1

        repo = csv_manager.find_repo(args.repo_name)
        if not repo:
            print(f"Error: Repository '{args.repo_name}' not found", file=sys.stderr)
            return 1
        repos = [repo]

    # Track skipped repos
    skipped = []

    for repo in repos:
        if not repo.target_dir:
            skipped.append(f"{repo.repo_name} (no target_dir)")
            continue

        try:
            print(f"\nPushing {repo.repo_name}...")
            git_manager.push_subtree(repo.url, repo.target_dir, repo.branch)
        except (subprocess.CalledProcessError, ValueError) as e:
            print(f"Error pushing {repo.repo_name}: {e}", file=sys.stderr)
            if not args.all:
                return 1

    if skipped:
        print("\nSkipped repositories:")
        for s in skipped:
            print(f"  - {s}")

    return 0


def cmd_list(args: argparse.Namespace) -> int:
    """Handle the 'list' command."""
    csv_manager = CSVManager(args.csv)
    repos = csv_manager.list_repos()

    if not repos:
        print("No repositories found")
        return 0

    # Filter by category if specified
    if args.category:
        repos = [r for r in repos if r.category.lower() == args.category.lower()]

    # Print header
    print(f"{'Name':<25} {'Category':<15} {'Target':<35} {'Branch':<10}")
    print("-" * 85)

    for repo in repos:
        branch = repo.branch if repo.branch else "main"
        target = repo.target_dir if repo.target_dir else "<not set>"
        category = repo.category if repo.category else "<none>"
        print(f"{repo.repo_name:<25} {category:<15} {target:<35} {branch:<10}")

    print(f"\nTotal: {len(repos)} repositories")
    return 0


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Git Subtree Manager - Manage git subtrees using CSV configuration',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s add --url https://github.com/user/repo --target components/repo --branch main
  %(prog)s remove repo_name
  %(prog)s pull --all
  %(prog)s pull repo_name
  %(prog)s push repo_name
  %(prog)s list --category Hypervisor
        """
    )

    parser.add_argument('--csv', type=Path, default=CSV_PATH,
                        help='Path to CSV file (default: repos.csv in script directory)')

    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    # Add command
    add_parser = subparsers.add_parser('add', help='Add a new subtree repository')
    add_parser.add_argument('--url', required=True, help='Repository URL')
    add_parser.add_argument('--target', required=True, help='Target directory path')
    add_parser.add_argument('--branch', default='', help='Branch name (default: main)')
    add_parser.add_argument('--category', default='', help='Category name')
    add_parser.add_argument('--description', default='', help='Repository description')

    # Remove command
    remove_parser = subparsers.add_parser('remove', help='Remove a subtree repository')
    remove_parser.add_argument('repo_name', help='Repository name (extracted from URL)')
    remove_parser.add_argument('--remove-dir', action='store_true',
                               help='Also remove the directory')
    remove_parser.add_argument('-f', '--force', action='store_true',
                               help='Force removal without confirmation')

    # Pull command
    pull_parser = subparsers.add_parser('pull', help='Pull updates from remote')
    pull_parser.add_argument('repo_name', nargs='?', help='Repository name (or use --all)')
    pull_parser.add_argument('--all', action='store_true', help='Pull all repositories')

    # Push command
    push_parser = subparsers.add_parser('push', help='Push local changes to remote')
    push_parser.add_argument('repo_name', nargs='?', help='Repository name (or use --all)')
    push_parser.add_argument('--all', action='store_true', help='Push all repositories')

    # List command
    list_parser = subparsers.add_parser('list', help='List all repositories')
    list_parser.add_argument('--category', help='Filter by category')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    # Dispatch to command handler
    handlers = {
        'add': cmd_add,
        'remove': cmd_remove,
        'pull': cmd_pull,
        'push': cmd_push,
        'list': cmd_list,
    }

    handler = handlers.get(args.command)
    if handler:
        return handler(args)

    return 1


if __name__ == "__main__":
    sys.exit(main())
