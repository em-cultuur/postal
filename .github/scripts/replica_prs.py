import os
import sys
import subprocess
import tempfile
import shutil
import tarfile
import requests
from github import Github
from github.GithubException import GithubException
import time

def run_git_command(command, cwd=None, timeout=300):
    """Executes a git command and handles errors"""
    try:
        # Mask the token for logging
        safe_command = command.replace(os.environ.get("GH_TOKEN", ""), "***") if "GH_TOKEN" in os.environ else command
        print(f"    🔧 Executing: {safe_command}")
        print(f"    📁 Directory: {cwd or 'current'}")

        # Add environment diagnostics before the git command
        if "git clone" in command:
            print(f"    🔍 Environment diagnostics:")
            try:
                # Check git version
                git_version = subprocess.run("git --version", shell=True, capture_output=True, text=True, timeout=10)
                print(f"      - Git version: {git_version.stdout.strip() if git_version.returncode == 0 else 'N/A'}")

                # Check git configuration
                git_user = subprocess.run("git config --global user.name", shell=True, capture_output=True, text=True, timeout=10)
                git_email = subprocess.run("git config --global user.email", shell=True, capture_output=True, text=True, timeout=10)
                print(f"      - Git user: {git_user.stdout.strip() if git_user.returncode == 0 else 'Not configured'}")
                print(f"      - Git email: {git_email.stdout.strip() if git_email.returncode == 0 else 'Not configured'}")

                # Check GitHub connectivity
                connectivity = subprocess.run("curl -s -o /dev/null -w '%{http_code}' https://github.com", shell=True, capture_output=True, text=True, timeout=15)
                print(f"      - GitHub connectivity: {connectivity.stdout.strip() if connectivity.returncode == 0 else 'Error'}")

                # Check available disk space
                if cwd and os.path.exists(os.path.dirname(cwd)):
                    disk_usage = subprocess.run(f"df -h {os.path.dirname(cwd)}", shell=True, capture_output=True, text=True, timeout=5)
                    if disk_usage.returncode == 0:
                        print(f"      - Disk space: {disk_usage.stdout.strip().split()[1] if len(disk_usage.stdout.strip().split()) > 10 else 'N/A'}")

            except Exception as diag_e:
                print(f"      - Diagnostics error: {diag_e}")

        start_time = time.time()
        result = subprocess.run(
            command,
            shell=True,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=True,
            timeout=timeout,
            env=dict(os.environ, GIT_TERMINAL_PROMPT="0")  # Disable interactive prompts
        )
        execution_time = time.time() - start_time

        print(f"    ⏱️  Execution time: {execution_time:.2f}s")
        print(f"    ✅ Return code: {result.returncode}")

        # Git often sends progress messages to stderr even on success
        has_stdout = result.stdout and result.stdout.strip()
        has_stderr = result.stderr and result.stderr.strip()

        if has_stdout:
            print(f"    📤 Full STDOUT:")
            for line in result.stdout.strip().split('\n'):
                print(f"       {line}")

        if has_stderr:
            # For git clone and other commands, stderr often contains normal progress messages
            if "git clone" in command or "git fetch" in command or "git push" in command:
                print(f"    📋 Progress messages (stderr):")
            else:
                print(f"    📝 STDERR:")
            for line in result.stderr.strip().split('\n'):
                print(f"       {line}")

        if not has_stdout and not has_stderr:
            print(f"    📤 No output generated")

        # Return True for success
        return True

    except subprocess.CalledProcessError as e:
        execution_time = time.time() - start_time if 'start_time' in locals() else 0
        safe_command = command.replace(os.environ.get("GH_TOKEN", ""), "***") if "GH_TOKEN" in os.environ else command

        print(f"    ❌ COMMAND FAILED: {safe_command}")
        print(f"    📁 Directory: {cwd or 'current'}")
        print(f"    ⏱️  Execution time: {execution_time:.2f}s")
        print(f"    🔢 Return code: {e.returncode}")

        if e.stdout:
            print(f"    📤 Full STDOUT:")
            for line in e.stdout.strip().split('\n'):
                print(f"       {line}")
        else:
            print(f"    📤 STDOUT: (empty)")

        if e.stderr:
            print(f"    📝 Full STDERR:")
            for line in e.stderr.strip().split('\n'):
                print(f"       {line}")
        else:
            print(f"    📝 STDERR: (empty)")

        # Specific analysis of common errors
        if e.stderr:
            error_lower = e.stderr.lower()
            if "fatal: could not read" in error_lower:
                print(f"    💡 Hint: Authentication problem or repository not accessible")
            elif "timeout" in error_lower or "timed out" in error_lower:
                print(f"    💡 Hint: Network timeout, try with a larger timeout")
            elif "permission denied" in error_lower:
                print(f"    💡 Hint: Permission problem with token or repository")
            elif "repository not found" in error_lower:
                print(f"    💡 Hint: Repository not found or not accessible")
            elif "authentication failed" in error_lower:
                print(f"    💡 Hint: Token invalid or expired")
            elif "network is unreachable" in error_lower:
                print(f"    💡 Hint: Network connectivity problem")
            elif "name resolution" in error_lower:
                print(f"    💡 Hint: DNS resolution problem")

        return False

    except subprocess.TimeoutExpired as e:
        safe_command = command.replace(os.environ.get("GH_TOKEN", ""), "***") if "GH_TOKEN" in os.environ else command
        print(f"    ⏰ TIMEOUT: {safe_command}")
        print(f"    📁 Directory: {cwd or 'current'}")
        print(f"    ⏱️  Timeout after: {timeout}s")

        if hasattr(e, 'stdout') and e.stdout:
            print(f"    📤 Partial STDOUT:")
            for line in e.stdout.strip().split('\n'):
                print(f"       {line}")

        if hasattr(e, 'stderr') and e.stderr:
            print(f"    📝 Partial STDERR:")
            for line in e.stderr.strip().split('\n'):
                print(f"       {line}")

        print(f"    💡 Hint: Command too slow, consider increasing the timeout or checking the connection")
        return False

def get_git_output(command, cwd=None, timeout=300):
    """Executes a git command and returns the output if successful"""
    try:
        result = subprocess.run(
            command,
            shell=True,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=True,
            timeout=timeout,
            env=dict(os.environ, GIT_TERMINAL_PROMPT="0")
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None

def setup_git_config(repo_dir):
    """Configures git to avoid configuration errors"""
    commands = [
        "git config user.email 'action@github.com'",
        "git config user.name 'GitHub Action'",
        "git config --global credential.helper store",
        "git config --global http.sslverify true"
    ]

    for cmd in commands:
        run_git_command(cmd, cwd=repo_dir)

def setup_git_config_global():
    """Configures git globally to avoid configuration errors"""
    commands = [
        "git config --global user.email 'action@github.com'",
        "git config --global user.name 'GitHub Action'",
        "git config --global credential.helper store",
        "git config --global http.sslverify true",
        "git config --global init.defaultBranch main"
    ]

    for cmd in commands:
        run_git_command(cmd)

def get_clone_url(pr, gh_token):
    """Generates the appropriate clone URL based on the repository type"""
    repo = pr.head.repo

    # If the repository is the same as upstream, use the public URL
    if repo.full_name == pr.base.repo.full_name:
        return repo.clone_url

    # For private repositories or forks, use authentication
    if repo.private or repo.fork:
        return f"https://{gh_token}@github.com/{repo.full_name}.git"

    return repo.clone_url

def check_branch_exists_in_fork(fork, branch_name):
    """Checks if a branch already exists in the fork"""
    try:
        fork.get_branch(branch_name)
        return True
    except GithubException:
        return False

def verify_repository_access(repo, gh_token):
    """Verifies repository access and provides diagnostic information"""
    try:
        print(f"  🔍 Verifying access to repository: {repo.full_name}")
        print(f"    - Private: {repo.private}")
        print(f"    - Fork: {repo.fork}")
        print(f"    - Owner: {repo.owner.login}")
        print(f"    - Clone URL: {repo.clone_url}")
        print(f"    - SSH URL: {repo.ssh_url}")

        # Check permissions
        permissions = repo.permissions
        print(f"    - Permissions: admin={permissions.admin}, push={permissions.push}, pull={permissions.pull}")

        return True
    except GithubException as e:
        print(f"  ❌ Repository verification error: {e}")
        print(f"    - Status: {e.status}")
        print(f"    - Data: {e.data}")
        return False

def try_download_repo_archive(repo, branch_name, target_dir, gh_token):
    """Attempts to download the repository as a tar.gz archive"""
    try:
        print(f"  📦 Downloading repository archive...")
        repo_name = repo.full_name
        archive_url = f"https://api.github.com/repos/{repo_name}/tarball/{branch_name}"
        headers = {"Authorization": f"token {gh_token}"}

        # Make the request to download the archive
        response = requests.get(archive_url, headers=headers, stream=True, timeout=30)
        response.raise_for_status()

        # Save the archive to the temporary directory
        tarball_path = os.path.join(target_dir, f"{repo_name.replace('/', '_')}_{branch_name}.tar.gz")
        with open(tarball_path, "wb") as tarball_file:
            for chunk in response.iter_content(chunk_size=8192):
                tarball_file.write(chunk)

        # Extract the archive
        print(f"  📂 Extracting downloaded archive...")
        with tarfile.open(tarball_path, "r:gz") as tar:
            tar.extractall(path=target_dir)

        # Find the extracted folder (usually the first one in the list)
        extracted_dirs = [d for d in os.listdir(target_dir) if os.path.isdir(os.path.join(target_dir, d))]
        if not extracted_dirs:
            print(f"  ❌ Error: No folder found in extracted archive")
            return False

        # Rename the extracted folder with a simpler name
        extracted_dir = os.path.join(target_dir, extracted_dirs[0])
        final_repo_dir = os.path.join(target_dir, "repo")
        os.rename(extracted_dir, final_repo_dir)

        print(f"  ✅ Download and extraction completed: {final_repo_dir}")
        return True
    except Exception as e:
        print(f"  ❌ Error downloading or extracting the archive: {e}")
        return False

def clone_and_setup_repo(clone_url, repo_dir, branch_name, fork_url, gh_token, pr):
    """Clones the repository and configures the remotes"""

    # Step 0: Verify access to the source repository
    print(f"  🔍 Source repository diagnostics...")
    if not verify_repository_access(pr.head.repo, gh_token):
        print(f"  ❌ Unable to access the source repository")
        return False

    # Step 0.5: Configure git before anything else
    print(f"  🔧 Preliminary git configuration...")
    setup_git_config_global()

    # Step 1: Clone the repository with multiple strategies
    print(f"  📥 Cloning from: {clone_url.replace(gh_token, '***') if gh_token in clone_url else clone_url}")

    # Strategy 1: Shallow clone with specific branch
    clone_command = f"git clone --depth=1 --single-branch --branch {branch_name} '{clone_url}' '{repo_dir}'"
    success = run_git_command(clone_command, timeout=180)

    if not success:
        print(f"  🔄 Fallback 1: Full clone with checkout...")
        # Remove directory if it partially exists
        if os.path.exists(repo_dir):
            shutil.rmtree(repo_dir)

        # Strategy 2: Full clone then checkout
        clone_command = f"git clone '{clone_url}' '{repo_dir}'"
        if not run_git_command(clone_command, timeout=300):
            print(f"  🔄 Fallback 2: Attempt without authentication...")

            # Strategy 3: If the repo is public, try without token
            if clone_url.startswith("https://") and "@github.com" in clone_url:
                public_url = clone_url.split("@github.com/")[1]
                public_url = f"https://github.com/{public_url}"
                print(f"  🌐 Attempt with public URL: {public_url}")

                if os.path.exists(repo_dir):
                    shutil.rmtree(repo_dir)

                if not run_git_command(f"git clone '{public_url}' '{repo_dir}'", timeout=300):
                    print(f"  🔄 Fallback 3: Alternative method via tar.gz...")

                    # Strategy 4: Direct download of the repository as archive
                    if try_download_repo_archive(pr.head.repo, branch_name, repo_dir, gh_token):
                        print(f"  ✅ Archive download completed successfully")
                    else:
                        print(f"  ❌ All clone attempts failed")
                        return False

        # Checkout the branch if necessary (only if the clone worked)
        if os.path.exists(repo_dir) and os.path.exists(os.path.join(repo_dir, '.git')):
            current_branch = get_git_output("git branch --show-current", cwd=repo_dir)
            if current_branch != branch_name:
                print(f"  🔄 Checkout branch {branch_name}...")
                if not run_git_command(f"git checkout {branch_name}", cwd=repo_dir):
                    # Try fetch + checkout
                    print(f"  🔄 Fetching branch {branch_name}...")
                    if not run_git_command(f"git fetch origin {branch_name}:{branch_name}", cwd=repo_dir):
                        # Last chance: fetch all branches then checkout
                        print(f"  🔄 Full branch fetch...")
                        run_git_command("git fetch --all", cwd=repo_dir)

                    # List all available branches for debug
                    branches = get_git_output("git branch -a", cwd=repo_dir)
                    print(f"  📋 Available branches: {branches}")

                    if not run_git_command(f"git checkout {branch_name}", cwd=repo_dir):
                        # Try with origin/ prefix
                        if not run_git_command(f"git checkout origin/{branch_name}", cwd=repo_dir):
                            print(f"  ❌ Unable to checkout branch {branch_name}")
                            return False

    # Step 2: Configure git in the cloned repository
    setup_git_config(repo_dir)

    # Step 3: Verify repository state
    print(f"  🔍 Verifying repository state...")
    if os.path.exists(os.path.join(repo_dir, '.git')):
        current_branch = get_git_output("git branch --show-current", cwd=repo_dir)
        if current_branch and current_branch != branch_name:
            print(f"  ⚠️  Current branch ({current_branch}) differs from requested ({branch_name})")
            # Don't fail if we're on a related branch (e.g. origin/branch)
            if f"origin/{branch_name}" not in current_branch and branch_name not in current_branch:
                return False
    else:
        print(f"  ℹ️  Repository downloaded as archive (not a git repository)")

    # Step 4: Initialize git if necessary and add fork remote
    if not os.path.exists(os.path.join(repo_dir, '.git')):
        print(f"  🔧 Initializing git repository...")
        if not run_git_command("git init", cwd=repo_dir):
            print(f"  ❌ Unable to initialize git repository")
            return False

        if not run_git_command("git add .", cwd=repo_dir):
            print(f"  ❌ Unable to add files to repository")
            return False

        if not run_git_command(f"git commit -m 'Initial commit from {pr.head.repo.full_name}#{branch_name}'", cwd=repo_dir):
            print(f"  ❌ Unable to create initial commit")
            return False

    print(f"  🔗 Configuring fork remote...")
    # Check if fork remote already exists
    remotes = get_git_output("git remote -v", cwd=repo_dir)
    if remotes:
        if "fork" in remotes:
            print(f"  ℹ️  Fork remote already present, removing to reconfigure...")
            run_git_command("git remote remove fork", cwd=repo_dir)

        # Always add the fork remote
        if not run_git_command(f"git remote add fork '{fork_url}'", cwd=repo_dir):
            print(f"  ⚠️  Error adding fork remote")
            # Try alternative approach: use origin remote
            print(f"  🔄 Using origin remote as fallback...")
            if not run_git_command(f"git remote set-url origin '{fork_url}'", cwd=repo_dir):
                print(f"  ❌ Unable to configure remote")
                return False
            fork_remote = "origin"
        else:
            fork_remote = "fork"
    else:
        # If there are no remotes (repository initialized from archive)
        print(f"  🔧 Adding first remote...")
        if not run_git_command(f"git remote add origin '{fork_url}'", cwd=repo_dir):
            print(f"  ❌ Unable to add origin remote")
            return False
        fork_remote = "origin"

    # Verify configured remotes
    final_remotes = get_git_output("git remote -v", cwd=repo_dir)
    print(f"  📋 Configured remotes: {final_remotes}")

    # Step 5: Push the branch to the fork
    print(f"  📤 Pushing branch {branch_name} to fork...")
    current_branch = get_git_output("git branch --show-current", cwd=repo_dir) or "main"

    # Create a branch name that includes the source repository to avoid conflicts
    source_repo_name = pr.head.repo.full_name.replace('/', '-')
    fork_branch_name = f"{source_repo_name}-{branch_name}"

    print(f"  📝 Branch on fork: {fork_branch_name}")

    # Try first with the correct branch name
    push_command = f"git push {fork_remote} {current_branch}:{fork_branch_name}"
    if not run_git_command(push_command, cwd=repo_dir, timeout=180):
        # Try force push if there's a conflict
        print(f"  🔄 Attempting with force push...")
        if not run_git_command(f"git push --force {fork_remote} {current_branch}:{fork_branch_name}", cwd=repo_dir, timeout=180):
            # Last attempt: create the branch and then push
            print(f"  🔄 Attempting by creating remote branch...")
            if not run_git_command(f"git push --set-upstream {fork_remote} {current_branch}:{fork_branch_name}", cwd=repo_dir, timeout=180):
                print(f"  ❌ Push to fork failed")
                return False

    print(f"  ✅ Repository configured and push completed")
    return True

def should_skip_pr(pr_title):
    """Determines if a PR should be skipped based on the title"""
    skip_prefixes = ["bump", "chore", "deps:", "dependabot", "ci:", "build:", "test:", "docs:", "style:", "refactor:"]
    title_lower = pr_title.lower().strip()

    for prefix in skip_prefixes:
        if title_lower.startswith(prefix):
            return True, f"Maintenance PR ({prefix.rstrip(':')})"

    return False, None

def main():
    # Check environment variables
    required_env_vars = ["GH_TOKEN", "UPSTREAM_REPO", "FORK_REPO"]
    for var in required_env_vars:
        if not os.environ.get(var):
            print(f"Error: Environment variable {var} not found")
            sys.exit(1)

    gh_token = os.environ["GH_TOKEN"]
    upstream_repo = os.environ["UPSTREAM_REPO"]
    fork_repo = os.environ["FORK_REPO"]

    print(f"🔑 Token present: {'✅' if gh_token else '❌'}")
    print(f"📋 Upstream: {upstream_repo}")
    print(f"📋 Fork: {fork_repo}")

    # Initialize GitHub client
    try:
        g = Github(gh_token)

        # Authentication test (optional - fallback if it fails)
        try:
            user = g.get_user()
            print(f"👤 Authenticated as: {user.login}")
        except GithubException as e:
            print(f"⚠️  Unable to get user info (limited permissions): {e.status}")
            print(f"📝 Continuing anyway...")

        upstream = g.get_repo(upstream_repo)
        fork = g.get_repo(fork_repo)

        # Test repository access
        try:
            print(f"📊 Upstream: {upstream.full_name} (private: {upstream.private})")
        except GithubException as e:
            print(f"❌ Error accessing upstream repository: {e}")
            sys.exit(1)

        try:
            print(f"📊 Fork: {fork.full_name} (private: {fork.private})")
        except GithubException as e:
            print(f"❌ Error accessing fork repository: {e}")
            sys.exit(1)

    except GithubException as e:
        print(f"❌ Error initializing GitHub client: {e}")
        sys.exit(1)

    # Get the fork's default branch
    try:
        default_branch = fork.default_branch
        print(f"🌳 Fork default branch: {default_branch}")
    except GithubException as e:
        print(f"⚠️  Error getting default branch: {e}")
        default_branch = "main"  # fallback

    print(f"\n🔄 Replicating PRs from {upstream_repo} to {fork_repo}")

    # Find open PRs in upstream
    try:
        upstream_prs = list(upstream.get_pulls(state="open"))
        print(f"📋 Found {len(upstream_prs)} open PRs in upstream")
    except GithubException as e:
        print(f"❌ Error getting upstream PRs: {e}")
        sys.exit(1)

    if len(upstream_prs) == 0:
        print("ℹ️  No open PRs found in upstream")
        return

    replicated_count = 0
    skipped_count = 0
    error_count = 0

    for pr in upstream_prs:
        try:
            branch_name = pr.head.ref
            pr_title = pr.title
            pr_author = pr.user.login

            print(f"\n🔍 Processing PR #{pr.number}: {pr_title}")
            print(f"    📝 Branch: {branch_name}")
            print(f"    👤 Author: {pr_author}")
            print(f"    🏠 Repository: {pr.head.repo.full_name}")

            # Check if the PR should be skipped
            should_skip, skip_reason = should_skip_pr(pr_title)
            if should_skip:
                print(f"  ⏭️  Skipping PR: {skip_reason}")
                skipped_count += 1
                continue

            # Check if the PR has already been replicated in the fork
            try:
                existing_prs = [p for p in fork.get_pulls(state="all")
                              if p.title.startswith(f"Replica: {pr_title}") or
                                 p.head.ref == branch_name]
            except GithubException as e:
                print(f"  ⚠️  Error checking existing PRs: {e}")
                existing_prs = []

            if existing_prs:
                print(f"  ⏭️  PR already replicated, skipping...")
                skipped_count += 1
                continue

            # Check if the branch already exists in the fork (with the new naming)
            source_repo_name = pr.head.repo.full_name.replace('/', '-')
            fork_branch_name = f"{source_repo_name}-{branch_name}"

            if check_branch_exists_in_fork(fork, fork_branch_name):
                print(f"  ⚠️  Branch {fork_branch_name} already exists in fork, skipping...")
                skipped_count += 1
                continue

            # Create temporary directory for the clone
            with tempfile.TemporaryDirectory() as temp_dir:
                repo_dir = os.path.join(temp_dir, "repo")

                # URL for the clone
                clone_url = get_clone_url(pr, gh_token)

                # Fork URL with authentication
                fork_url = f"https://{gh_token}@github.com/{fork_repo}.git"

                # Clone and configure the repository
                if not clone_and_setup_repo(clone_url, repo_dir, branch_name, fork_url, gh_token, pr):
                    print(f"  ❌ Error configuring the repository")
                    error_count += 1
                    continue

            # Create a new PR in the fork
            print(f"  🔃 Creating PR in fork...")
            pr_body = f"""This PR replicates the original PR: {pr.html_url}

**Original author:** @{pr_author}
**Original branch:** `{branch_name}`
**Original repository:** {pr.head.repo.full_name}

---

{pr.body or 'No description provided.'}"""

            try:
                new_pr = fork.create_pull(
                    title=f"Replica: {pr_title}",
                    body=pr_body,
                    head=fork_branch_name,  # Use the new branch name
                    base=default_branch
                )
                print(f"  ✅ PR created: {new_pr.html_url}")
                replicated_count += 1

                # Add labels if possible
                try:
                    # Check if labels exist before adding them
                    existing_labels = [label.name for label in fork.get_labels()]
                    labels_to_add = []

                    if "replica" in existing_labels:
                        labels_to_add.append("replica")
                    if "upstream" in existing_labels:
                        labels_to_add.append("upstream")

                    if labels_to_add:
                        new_pr.add_to_labels(*labels_to_add)
                        print(f"  🏷️  Labels added: {', '.join(labels_to_add)}")
                    else:
                        print(f"  ℹ️  No labels available to add")

                except GithubException as e:
                    print(f"  ⚠️  Unable to add labels: {e}")

            except GithubException as e:
                print(f"  ❌ Error creating PR: {e}")
                # If the error is permissions, it might be useful to continue
                if e.status == 403:
                    print(f"  📝 Permissions error - check the REPO_ACCESS_TOKEN token")
                error_count += 1
                continue

        except GithubException as e:
            print(f"  ❌ GitHub error processing PR {pr.number}: {e}")
            error_count += 1
            continue
        except Exception as e:
            print(f"  ❌ Generic error processing PR {pr.number}: {e}")
            error_count += 1
            continue

    print(f"\n📊 Final summary:")
    print(f"  ✅ PRs replicated: {replicated_count}")
    print(f"  ⏭️  PRs skipped: {skipped_count}")
    print(f"  ❌ Errors: {error_count}")
    print(f"  📝 Total processed: {len(upstream_prs)}")

    # Don't exit with error if there are only some errors
    if error_count > 0 and replicated_count == 0:
        print("⚠️  No PRs successfully replicated")
        sys.exit(1)
    elif error_count > 0:
        print("⚠️  Some errors but at least one PR replicated")

if __name__ == "__main__":
    main()
