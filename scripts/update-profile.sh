#!/usr/bin/env bash
# update-profile.sh
# Fetches repository information for the VoxelStorm-Ltd GitHub organisation
# and updates the projects table in profile/README.md.
#
# Required environment variables:
#   GITHUB_TOKEN  – a read-only token for accessing the GitHub API.
#                   For public-only access the default GITHUB_TOKEN is sufficient.
#                   To include private repositories, supply a fine-grained
#                   read-only PAT via PROFILE_METADATA_READ_TOKEN and set
#                   INCLUDE_PRIVATE=1 (see update-profile.yml).
#                   To show issue/PR counts (public or private repos), the
#                   token must have these fine-grained permissions:
#                     - Repository metadata (read) – list repos via REST
#                     - Issues (read)              – issue counts via GraphQL
#                     - Pull requests (read)       – PR counts via GraphQL
#
# Optional environment variables:
#   ORG             – GitHub organisation name (default: VoxelStorm-Ltd)
#   README          – path to the README to update (default: profile/README.md)
#   INCLUDE_PRIVATE – set to `1` to include private repositories in the table
#                     (requires a token with private repo access)
#
# Column-visibility switches (set to any non-empty value to enable, leave unset/empty to disable):
#   SHOW_STARS      – show the Stars column (default: off)
#   SHOW_FORKS      – show the Forks column (default: off)
#   SHOW_ISSUES     – show the Issues column (default: on)
#   SHOW_PRS        – show the PRs column (default: on)
#
# Issue/PR display mode:
#   ISSUES_SIMPLIFIED – set to any non-empty value (default) to use simplified
#                       mode: shows open count only when > 0, blank otherwise.
#                       Leave empty to show "open / total" linked counts.

set -euo pipefail

ORG="${ORG:-VoxelStorm-Ltd}"
README="${README:-profile/README.md}"
API="https://api.github.com"
PER_PAGE=100
INCLUDE_PRIVATE="${INCLUDE_PRIVATE:-}"
REPO_TYPE="public"
[ "${INCLUDE_PRIVATE}" = "1" ] && REPO_TYPE="all"

# Column visibility (non-empty = show)
SHOW_STARS="${SHOW_STARS:-}"
SHOW_FORKS="${SHOW_FORKS:-}"
SHOW_ISSUES="${SHOW_ISSUES-1}"
SHOW_PRS="${SHOW_PRS-1}"
# Issue/PR display mode: simplified (default) or full open/total
ISSUES_SIMPLIFIED="${ISSUES_SIMPLIFIED-1}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

gh_api() {
  local path="$1"
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/${path}"
}

gh_graphql() {
  local query="$1"
  local variables="${2:-{\}}"
  local payload
  payload=$(jq -n --arg q "${query}" --argjson v "${variables}" '{"query": $q, "variables": $v}')
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/graphql" \
    --data "${payload}"
}

# Fetch non-archived, non-fork repositories for the org.
# Fetches public repos by default; set INCLUDE_PRIVATE=1 to include private ones.
fetch_repos() {
  local page=1
  while :; do
    local chunk
    chunk=$(gh_api "orgs/${ORG}/repos?type=${REPO_TYPE}&sort=full_name&per_page=${PER_PAGE}&page=${page}")
    echo "${chunk}" | jq -c '.[]'
    local count
    count=$(echo "${chunk}" | jq 'length')
    if [ "${count}" -lt "${PER_PAGE}" ]; then
      break
    fi
    page=$((page + 1))
  done
}

# Return base64-encoded JSON objects for each *real* workflow file in a repo.
# Synthetic GitHub-managed workflows (Copilot, Dependabot, etc.) are excluded
# because they have no corresponding file path in .github/workflows/ and their
# badge/action URLs do not resolve correctly.
# The regex matches only top-level .yml/.yaml files directly inside .github/workflows/
# and deliberately excludes subdirectories (which would contain a second slash).
get_workflows() {
  local repo="$1"
  gh_api "repos/${ORG}/${repo}/actions/workflows?per_page=${PER_PAGE}" 2>/dev/null \
    | jq -r '.workflows[] | select((.path // "") | test("^\\.github/workflows/[^/]+\\.ya?ml$")) | @base64' 2>/dev/null || true
}

# Return the html_url of the GitHub Pages site for a repo, or empty string
get_pages_url() {
  local repo="$1"
  local body_file http_code
  body_file=$(mktemp)
  chmod 600 "${body_file}"
  http_code=$(curl -sSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -o "${body_file}" \
    -w "%{http_code}" \
    "${API}/repos/${ORG}/${repo}/pages" 2>/dev/null) || true
  if [ "${http_code}" = "200" ]; then
    jq -r '.html_url // ""' < "${body_file}" 2>/dev/null || true
  fi
  rm -f "${body_file}"
}

# Return space-separated "open_issues total_issues open_prs total_prs" for a
# repo using a single GraphQL request, avoiding the much tighter Search-API
# rate limits.  On failure each field falls back to "—".
get_counts() {
  local repo="$1"
  # Use parameterised query to avoid any injection from org/repo name values.
  local query='query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      openIssues: issues(states: OPEN) { totalCount }
      allIssues: issues(states: [OPEN, CLOSED]) { totalCount }
      openPRs: pullRequests(states: OPEN) { totalCount }
      allPRs: pullRequests(states: [OPEN, CLOSED, MERGED]) { totalCount }
    }
  }'
  local variables
  variables=$(jq -n --arg owner "${ORG}" --arg name "${repo}" '{"owner": $owner, "name": $name}')
  local result
  if ! result=$(gh_graphql "${query}" "${variables}" 2>/dev/null); then
    echo "Warning: failed to fetch counts for ${ORG}/${repo}" >&2
    echo "— — — —"
    return
  fi
  local open_issues total_issues open_prs total_prs
  if ! open_issues=$(echo "${result}" | jq -er '.data.repository.openIssues.totalCount') \
      || ! total_issues=$(echo "${result}" | jq -er '.data.repository.allIssues.totalCount') \
      || ! open_prs=$(echo "${result}" | jq -er '.data.repository.openPRs.totalCount') \
      || ! total_prs=$(echo "${result}" | jq -er '.data.repository.allPRs.totalCount'); then
    local graphql_errors
    graphql_errors=$(echo "${result}" | jq -r '
      if ((.errors // []) | length) > 0 then [(.errors // [])[].message] | join("; ")
      elif .data?.repository? == null then "repository is null (token may lack Issues (read) / Pull requests (read) permissions)"
      else "unexpected response structure"
      end' 2>/dev/null || echo "could not parse response")
    echo "Warning: GraphQL count fetch failed for ${ORG}/${repo}: ${graphql_errors}" >&2
    echo "— — — —"
    return
  fi
  echo "${open_issues} ${total_issues} ${open_prs} ${total_prs}"
}

# ---------------------------------------------------------------------------
# Build the projects table
# ---------------------------------------------------------------------------

build_table() {
  local table=""
  # Build header row dynamically based on enabled columns
  local header="| Project | Description | Build Status |"
  local sep="| ------- | ----------- | :----------: |"
  if [ -n "${SHOW_ISSUES}" ]; then
    if [ -n "${ISSUES_SIMPLIFIED}" ]; then header+=" Open Issues |"; else header+=" Issues |"; fi
    sep+=" :----------: |"
  fi
  if [ -n "${SHOW_PRS}" ]; then
    if [ -n "${ISSUES_SIMPLIFIED}" ]; then header+=" Open PRs |"; else header+=" PRs |"; fi
    sep+=" :------: |"
  fi
  [ -n "${SHOW_STARS}" ]  && header+=" Stars |"  && sep+=" :---: |"
  [ -n "${SHOW_FORKS}" ]  && header+=" Forks |"  && sep+=" :---: |"
  header+=" Pages |"
  sep+=" :---: |"
  table+="${header}\n${sep}\n"

  local repos_json
  mapfile -t repos_json < <(fetch_repos)

  for repo_json in "${repos_json[@]}"; do
    local name fork archived private description has_pages stars forks
    name=$(echo "${repo_json}" | jq -r '.name')
    fork=$(echo "${repo_json}" | jq -r '.fork')
    archived=$(echo "${repo_json}" | jq -r '.archived')
    private=$(echo "${repo_json}" | jq -r '.private')
    description=$(echo "${repo_json}" | jq -r '.description // ""')
    has_pages=$(echo "${repo_json}" | jq -r '.has_pages')
    stars=$(echo "${repo_json}" | jq -r '.stargazers_count // 0')
    forks=$(echo "${repo_json}" | jq -r '.forks_count // 0')

    # Skip the .github repo itself and any forks / archived repos
    if [ "${name}" = ".github" ] || [ "${fork}" = "true" ] || [ "${archived}" = "true" ]; then
      continue
    fi

    # ---- Description (sanitized for Markdown table) -------------------------
    local desc_col
    if [ "${private}" = "true" ]; then
      desc_col="*[Private]*"
    else
      # Replace newlines with spaces and escape pipe characters
      desc_col=$(printf '%s' "${description}" | tr '\n\r' '  ' | sed 's/|/\\|/g')
      [ -z "${desc_col}" ] && desc_col="—"
    fi

    # ---- Build status badges ------------------------------------------------
    local badges=""
    local default_branch
    default_branch=$(echo "${repo_json}" | jq -r '.default_branch')
    # URL-encode the branch name once per repo so special characters don't break badge URLs
    local encoded_branch
    encoded_branch=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "${default_branch}")

    while IFS= read -r workflow_json_b64; do
      [ -z "${workflow_json_b64}" ] && continue
      local workflow_json workflow_path workflow_name workflow_name_md workflow_file
      workflow_json=$(printf '%s' "${workflow_json_b64}" | base64 --decode)
      workflow_path=$(echo "${workflow_json}" | jq -r '.path // empty')
      workflow_name=$(echo "${workflow_json}" | jq -r '.name // "CI"')
      # Escape characters that would break Markdown alt text or table cells
      workflow_name_md="${workflow_name//\\/\\\\}"
      workflow_name_md="${workflow_name_md//]/\\]}"
      workflow_name_md="${workflow_name_md//|/\\|}"
      [ -z "${workflow_path}" ] && continue
      workflow_file=$(basename "${workflow_path}")
      local badge_url="https://github.com/${ORG}/${name}/actions/workflows/${workflow_file}/badge.svg?branch=${encoded_branch}"
      local workflow_url="https://github.com/${ORG}/${name}/actions/workflows/${workflow_file}"
      badges+="[![${workflow_name_md}](${badge_url})](${workflow_url}) "
    done < <(get_workflows "${name}")

    badges="${badges% }"  # trim trailing space

    # ---- Issue and PR counts ------------------------------------------------
    local base_url="https://github.com/${ORG}/${name}"
    local counts open_issues total_issues open_prs total_prs
    local issues_col="" prs_col=""
    if [ -n "${SHOW_ISSUES}" ] || [ -n "${SHOW_PRS}" ]; then
      counts=$(get_counts "${name}")
      read -r open_issues total_issues open_prs total_prs <<< "${counts}"
      if [ -n "${SHOW_ISSUES}" ]; then
        if [ "${open_issues}" = "—" ]; then
          issues_col="—"
        elif [ -n "${ISSUES_SIMPLIFIED}" ]; then
          # Simplified: show linked open count only when > 0, blank otherwise
          if [ "${open_issues}" -gt 0 ] 2>/dev/null; then
            issues_col="[${open_issues}](${base_url}/issues?q=is%3Aissue+is%3Aopen)"
          else
            issues_col=""
          fi
        else
          issues_col="[${open_issues}](${base_url}/issues?q=is%3Aissue+is%3Aopen) / [${total_issues}](${base_url}/issues?q=is%3Aissue)"
        fi
      fi
      if [ -n "${SHOW_PRS}" ]; then
        if [ "${open_prs}" = "—" ]; then
          prs_col="—"
        elif [ -n "${ISSUES_SIMPLIFIED}" ]; then
          if [ "${open_prs}" -gt 0 ] 2>/dev/null; then
            prs_col="[${open_prs}](${base_url}/pulls?q=is%3Apr+is%3Aopen)"
          else
            prs_col=""
          fi
        else
          prs_col="[${open_prs}](${base_url}/pulls?q=is%3Apr+is%3Aopen) / [${total_prs}](${base_url}/pulls?q=is%3Apr)"
        fi
      fi
    fi

    # ---- GitHub Pages -------------------------------------------------------
    local pages_col=""
    if [ "${has_pages}" = "true" ]; then
      local pages_url
      pages_url=$(get_pages_url "${name}")
      if [ -n "${pages_url}" ]; then
        pages_col="[Pages](${pages_url})"
      fi
    fi

    # ---- Assemble row -------------------------------------------------------
    local project_link="[**\`${name}\`**](${base_url})"
    local row="| ${project_link} | ${desc_col} | ${badges} |"
    [ -n "${SHOW_ISSUES}" ] && row+=" ${issues_col} |"
    [ -n "${SHOW_PRS}" ]    && row+=" ${prs_col} |"
    if [ -n "${SHOW_STARS}" ]; then
      local stars_col="[${stars}](${base_url}/stargazers)"
      row+=" ${stars_col} |"
    fi
    if [ -n "${SHOW_FORKS}" ]; then
      local forks_col="[${forks}](${base_url}/network/members)"
      row+=" ${forks_col} |"
    fi
    row+=" ${pages_col} |"
    table+="${row}\n"
  done

  printf '%b' "${table}"
}

# ---------------------------------------------------------------------------
# Inject the table between markers in the README
# ---------------------------------------------------------------------------

update_readme() {
  local table="$1"
  local table_file
  table_file=$(mktemp)
  chmod 600 "${table_file}"
  # Ensure the temp file is removed on function exit (normal or error)
  trap 'rm -f "${table_file}"' RETURN
  printf '%s' "${table}" > "${table_file}"

  python3 - "${README}" "${table_file}" << 'PYEOF'
import sys, re

readme_path = sys.argv[1]
table_file  = sys.argv[2]

with open(table_file, 'r') as f:
    table = f.read()

with open(readme_path, 'r') as f:
    content = f.read()

new_section = (
    '<!-- PROJECTS-START -->\n'
    + table + '\n'
    + '<!-- PROJECTS-END -->'
)

updated, count = re.subn(
    r'<!-- PROJECTS-START -->.*?<!-- PROJECTS-END -->',
    new_section,
    content,
    flags=re.DOTALL,
)

if count != 1:
    if count == 0:
        error = (
            f"ERROR: markers <!-- PROJECTS-START --> / <!-- PROJECTS-END --> not found in {readme_path}"
        )
    else:
        error = (
            f"ERROR: expected exactly one <!-- PROJECTS-START --> / <!-- PROJECTS-END --> block in {readme_path}, found {count}"
        )
    print(error, file=sys.stderr)
    sys.exit(1)

with open(readme_path, 'w') as f:
    f.write(updated)

print(f"Updated {readme_path}")
PYEOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Building projects table for org: ${ORG}"
TABLE=$(build_table)
echo "Updating ${README}…"
update_readme "${TABLE}"
echo "Done."
