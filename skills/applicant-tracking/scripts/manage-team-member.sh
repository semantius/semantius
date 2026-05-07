#!/usr/bin/env bash
# manage-team-member.sh: add or remove a hiring_team_members row.
# Add: read-first dedupe; if (job, user, role) exists active, no-op;
#      if exists inactive, reactivate; otherwise create.
# Remove: soft-deactivate (is_active=false) so team history survives.
#
# Usage: manage-team-member.sh add <job_id_or_code> <user_email> <team_role>
#        manage-team-member.sh remove <job_id_or_code> <user_email> <team_role>
#
# Exit:  0 on success (including "already in target state" no-ops)
#        1 on usage / validation failure (job or user not found,
#          unknown role, ambiguous job match)
#        2 on platform error (semantius call failed)
#
# Idempotent: re-running with the same args is safe; a second add
# call against an already-active row is a deterministic no-op.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "Usage: $(basename "$0") <add|remove> <job_id_or_code> <user_email> <team_role>" >&2
  exit 1
fi
op="$1"
job_arg="$2"
user_email="$3"
role="$4"

case "$op" in
  add|remove) ;;
  *)
    echo "step 1: unknown operation '$op'; expected 'add' or 'remove'" >&2
    exit 1
    ;;
esac

case "$role" in
  recruiter|hiring_manager|interviewer|coordinator|executive_sponsor) ;;
  *)
    echo "step 1: unknown team_role '$role'; expected one of recruiter, hiring_manager, interviewer, coordinator, executive_sponsor" >&2
    exit 1
    ;;
esac

uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Step 2: resolve job opening to exactly one row.
# id and job_code are unique → --single. Fuzzy search → array.
if [[ "$job_arg" =~ $uuid_re ]]; then
  job_row=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/job_openings?id=eq.$job_arg&select=id,job_title\"}") \
    || { echo "step 2: no job_opening with id '$job_arg'" >&2; exit 1; }
else
  if job_row=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.$job_arg&select=id,job_title\"}" 2>/dev/null); then
    :
  else
    rows=$(semantius call crud postgrestRequest "{\"method\":\"GET\",\"path\":\"/job_openings?search_vector=wfts(simple).$job_arg&select=id,job_title\"}") \
      || { echo "step 2 (fuzzy read job_openings) failed" >&2; exit 2; }
    count=$(printf '%s' "$rows" | grep -o '"id"' | wc -l | tr -d ' ')
    if [ "$count" = "0" ]; then
      echo "step 2: no job_opening matched '$job_arg'; ask the user for a different term" >&2
      exit 1
    fi
    if [ "$count" -gt 1 ]; then
      echo "step 2: '$job_arg' matched $count job_openings; ask the user to disambiguate" >&2
      printf '%s\n' "$rows" >&2
      exit 1
    fi
    job_row=$(printf '%s' "$rows" | sed -E 's/^\[(.*)\]$/\1/')
  fi
fi

job_id=$(printf '%s' "$job_row" | grep -oE '"id":"[^"]+"' | sed -E 's/.*"id":"([^"]+)".*/\1/')
job_title=$(printf '%s' "$job_row" | grep -oE '"job_title":"[^"]+"' | sed -E 's/.*"job_title":"([^"]+)".*/\1/')

# Step 3: resolve user by email (unique → --single).
user_row=$(semantius call crud postgrestRequest --single "{\"method\":\"GET\",\"path\":\"/users?email_address=eq.$user_email&select=id,display_name\"}") \
  || { echo "step 3: no user with email '$user_email'; create the user via use-semantius first" >&2; exit 1; }

user_id=$(printf '%s' "$user_row" | grep -oE '"id":"[^"]+"' | sed -E 's/.*"id":"([^"]+)".*/\1/')
display_name=$(printf '%s' "$user_row" | grep -oE '"display_name":"[^"]+"' | sed -E 's/.*"display_name":"([^"]+)".*/\1/')

# Step 4: read existing junction row. This is a dedupe check; zero
# rows is the normal "create" branch, so use array mode.
existing=$(semantius call crud postgrestRequest "{\"method\":\"GET\",\"path\":\"/hiring_team_members?job_opening_id=eq.$job_id&user_id=eq.$user_id&team_role=eq.$role&select=id,is_active\"}") \
  || { echo "step 4 (read junction) failed" >&2; exit 2; }

now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$role" in
  recruiter)         role_label="Recruiter" ;;
  hiring_manager)    role_label="Hiring manager" ;;
  interviewer)       role_label="Interviewer" ;;
  coordinator)       role_label="Coordinator" ;;
  executive_sponsor) role_label="Executive sponsor" ;;
esac

if [ "$op" = "add" ]; then
  if printf '%s' "$existing" | grep -q '"id"'; then
    existing_id=$(printf '%s' "$existing" | grep -oE '"id":"[^"]+"' | head -n1 | sed -E 's/.*"id":"([^"]+)".*/\1/')
    is_active=$(printf '%s' "$existing" | grep -oE '"is_active":(true|false)' | head -n1 | sed -E 's/.*"is_active":(true|false).*/\1/')
    if [ "$is_active" = "true" ]; then
      echo "manage-team-member: ok (already active, $existing_id)"
      exit 0
    fi
    semantius call crud postgrestRequest --single "{\"method\":\"PATCH\",\"path\":\"/hiring_team_members?id=eq.$existing_id\",\"body\":{\"is_active\":true,\"assigned_at\":\"$now\"}}" \
      >/dev/null \
      || { echo "step 5 (reactivate) failed" >&2; exit 2; }
    echo "manage-team-member: ok (reactivated, $existing_id)"
    exit 0
  fi

  label="$display_name, $role_label, $job_title"
  body=$(printf '{"team_member_label":"%s","job_opening_id":"%s","user_id":"%s","team_role":"%s","assigned_at":"%s","is_active":true}' \
    "$label" "$job_id" "$user_id" "$role" "$now")
  semantius call crud postgrestRequest --single "{\"method\":\"POST\",\"path\":\"/hiring_team_members\",\"body\":$body}" \
    >/dev/null \
    || { echo "step 5 (create) failed" >&2; exit 2; }
  echo "manage-team-member: ok (created)"
  exit 0
fi

# remove
if ! printf '%s' "$existing" | grep -q '"id"'; then
  echo "manage-team-member: ok (no row to remove)"
  exit 0
fi
existing_id=$(printf '%s' "$existing" | grep -oE '"id":"[^"]+"' | head -n1 | sed -E 's/.*"id":"([^"]+)".*/\1/')
is_active=$(printf '%s' "$existing" | grep -oE '"is_active":(true|false)' | head -n1 | sed -E 's/.*"is_active":(true|false).*/\1/')
if [ "$is_active" = "false" ]; then
  echo "manage-team-member: ok (already inactive, $existing_id)"
  exit 0
fi

semantius call crud postgrestRequest --single "{\"method\":\"PATCH\",\"path\":\"/hiring_team_members?id=eq.$existing_id\",\"body\":{\"is_active\":false}}" \
  >/dev/null \
  || { echo "step 5 (deactivate) failed" >&2; exit 2; }
echo "manage-team-member: ok (deactivated, $existing_id)"
