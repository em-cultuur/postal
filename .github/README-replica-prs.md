# Upstream PR Replication Configuration

This workflow automates the replication of Pull Requests from the upstream repository `postalserver/postal` into the current fork.

## Required Configuration

### 1. Create a Personal Access Token (PAT)

The workflow requires a Personal Access Token with the following permissions:

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate a new token with the following scopes:
   - `repo` (full repository access)
   - `workflow` (to modify workflows)

### 2. Add the token as a secret

1. In your fork repository, go to Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Name: `REPO_ACCESS_TOKEN`
4. Value: the token generated in the previous step

## How It Works

### Automatic Trigger
- Runs every 6 hours via cron job
- Manual execution via workflow dispatch

### Replication Process
1. **PR Scanning**: Searches for all open PRs in the upstream repository
2. **Duplicate Check**: Verifies if a PR has already been replicated
3. **Repository Clone**: Clones the PR branch from the original repository
4. **Push to Fork**: Pushes the branch to your fork
5. **PR Creation**: Creates a new PR in the fork with "Replica:" prefix

### Error Handling
- Fallback for clone issues (shallow → full clone)
- Timeout handling for long operations
- Automatic skip of already replicated PRs or existing branches
- Detailed logging for debugging

## Customization

### Change the Frequency
Modify the `cron` section in the `.github/workflows/replica-pr.yml` file:
```yaml
schedule:
  - cron: '0 */12 * * *'  # Every 12 hours instead of 6
```

### Change the Upstream Repository
Modify the `UPSTREAM_REPO` variable in the workflow:
```yaml
env:
  UPSTREAM_REPO: other-user/other-repo
```

## Troubleshooting

### Error "Resource not accessible by integration"
- Verify that the `REPO_ACCESS_TOKEN` token is configured correctly
- Ensure the token has full `repo` permissions

### Error "Error cloning the repository"
- Check that the upstream repository is public or that you have access
- Verify the network connection of the GitHub runner

### PRs are not being created
- Check the workflow logs for specific errors
- Verify that the token has write permissions on the fork repository

## Monitoring

The workflow logs show:
- ✅ Successfully replicated PRs
- ⏭️ Skipped PRs (already existing)
- ❌ Errors with specific details
- 📊 Final summary with statistics
