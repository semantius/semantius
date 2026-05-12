#!/usr/bin/env bash
# assign-hiring-team-member.sh: Add or remove a user-on-opening junction row
# in hiring_team_members for a given team_role. The junction has NO DB-level
# uniqueness on (job_opening_id, user_id, team_role) (see §7.2); the script
# dedupes by reading first. Add mode reactivates a soft-removed row when one
# exists (PATCH is_active=true) rather than POSTing a duplicate; remove mode
# soft-deactivates via is_active=false so history is preserved. Composes the
# caller-populated team_member_label on insert.
#
# Usage: assign-hiring-team-member.sh <user-email> <job-code> <team-role> <add|remove>
#
# team-role: one of recruiter, hiring_manager, interviewer, coordinator,
#   executive_sponsor.
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / invalid enum
#        2 on platform error
#
# Idempotent: re-running add when a row is already active is a no-op; re-running
# remove when a row is already inactive (or absent) is a no-op.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "Usage: $(basename "$0") <user-email> <job-code> <team-role> <add|remove>" >&2
  exit 1
fi

user_email="$1"
job_code="$2"
team_role="$3"
mode="$4"

case "$team_role" in recruiter|hiring_manager|interviewer|coordinator|executive_sponsor) ;; *) echo "step 0: team-role must be one of recruiter, hiring_manager, interviewer, coordinator, executive_sponsor" >&2; exit 1 ;; esac
case "$mode" in add|remove) ;; *) echo "step 0: mode must be add or remove" >&2; exit 1 ;; esac

# Step 1: resolve user.
user=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/users?email_address=eq.${user_email}&select=id,display_name\"}") \
  || { echo "step 1: user '${user_email}' not found" >&2; exit 1; }
user_id=$(printf '%s' "$user" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')
user_name=$(printf '%s' "$user" | grep -oE '"display_name":"[^"]+"' | sed 's/"display_name":"\([^"]*\)"/\1/')

# Step 2: resolve job opening.
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_code}&select=id,job_title\"}") \
  || { echo "step 2: job opening '${job_code}' not found" >&2; exit 1; }
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')
job_title=$(printf '%s' "$job_opening" | grep -oE '"job_title":"[^"]+"' | sed 's/"job_title":"\([^"]*\)"/\1/')

# Step 3: dedupe-on-junction read.
existing=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/hiring_team_members?job_opening_id=eq.${job_opening_id}&user_id=eq.${user_id}&team_role=eq.${team_role}&select=id,is_active\"}") \
  || { echo "step 3: junction dedupe lookup failed" >&2; exit 2; }
existing_id=$(printf '%s' "$existing" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/' || true)
existing_active=""
if [ -n "$existing_id" ]; then
  if printf '%s' "$existing" | grep -q '"is_active":true'; then
    existing_active="true"
  else
    existing_active="false"
  fi
fi

# Title-case the team_role for the label.
case "$team_role" in
  recruiter) role_label="Recruiter" ;;
  hiring_manager) role_label="Hiring Manager" ;;
  interviewer) role_label="Interviewer" ;;
  coordinator) role_label="Coordinator" ;;
  executive_sponsor) role_label="Executive Sponsor" ;;
esac
team_member_label="${user_name}, ${role_label}, ${job_title}"
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Step 4: write.
case "$mode" in
  add)
    if [ -z "$existing_id" ]; then
      body="{\"team_member_label\":\"${team_member_label}\",\"job_opening_id\":\"${job_opening_id}\",\"user_id\":\"${user_id}\",\"team_role\":\"${team_role}\",\"assigned_at\":\"${now}\",\"is_active\":true}"
      semantius call crud postgrestRequest --single \
        "{\"method\":\"POST\",\"path\":\"/hiring_team_members\",\"body\":${body}}" \
        > /dev/null \
        || { echo "step 4: POST hiring_team_members failed" >&2; exit 2; }
      echo "assign-hiring-team-member: added ${user_name} as ${role_label} on ${job_code}"
    elif [ "$existing_active" = "true" ]; then
      echo "assign-hiring-team-member: ${user_name} is already an active ${role_label} on ${job_code}; nothing to do" >&2
      exit 0
    else
      semantius call crud postgrestRequest --single \
        "{\"method\":\"PATCH\",\"path\":\"/hiring_team_members?id=eq.${existing_id}\",\"body\":{\"is_active\":true,\"assigned_at\":\"${now}\"}}" \
        > /dev/null \
        || { echo "step 4: PATCH (reactivate) failed" >&2; exit 2; }
      echo "assign-hiring-team-member: reactivated ${user_name} as ${role_label} on ${job_code}"
    fi
    ;;
  remove)
    if [ -z "$existing_id" ]; then
      echo "assign-hiring-team-member: ${user_name} is not a ${role_label} on ${job_code}; nothing to do" >&2
      exit 0
    elif [ "$existing_active" = "false" ]; then
      echo "assign-hiring-team-member: ${user_name} is already inactive as ${role_label} on ${job_code}; nothing to do" >&2
      exit 0
    else
      semantius call crud postgrestRequest --single \
        "{\"method\":\"PATCH\",\"path\":\"/hiring_team_members?id=eq.${existing_id}\",\"body\":{\"is_active\":false}}" \
        > /dev/null \
        || { echo "step 4: PATCH (deactivate) failed" >&2; exit 2; }
      echo "assign-hiring-team-member: removed ${user_name} as ${role_label} on ${job_code} (soft-deactivated, history preserved)"
    fi
    ;;
esac
