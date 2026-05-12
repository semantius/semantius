#!/usr/bin/env bash
# assign-hiring-team-member.sh: Add or remove a user from a job_opening's
# hiring_team_members junction with a specific team_role. Reads first to
# avoid duplicate active rows; soft-deactivates on remove (is_active=false)
# so the assignment history survives.
#
# Usage: assign-hiring-team-member.sh <job-code-or-title> <user-email> <team_role> <add|remove>
#
# team_role: one of recruiter, hiring_manager, interviewer, coordinator,
#   executive_sponsor.
#
# Add:    if no row exists, POST a new is_active=true row with composed
#         team_member_label. If an inactive row exists for the same
#         (job_opening_id, user_id, team_role), reactivate it (PATCH
#         is_active=true). If an active row already exists, no-op.
# Remove: if an active row exists, PATCH is_active=false. If no row or
#         already inactive, no-op (idempotent).
#
# Note: writing to this junction does NOT update job_openings.hiring_manager_id
# or job_openings.recruiter_id, those are independent summary FKs (per §3.13).
#
# Exit:  0 on success (including no-op cases)
#        1 on usage / unresolved lookup / invalid args
#        2 on platform error
#
# Idempotent: add+add is one POST plus one no-op; remove+remove is one PATCH
# plus one no-op.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "Usage: $(basename "$0") <job-code-or-title> <user-email> <team_role> <add|remove>" >&2
  exit 1
fi

job_arg="$1"
user_email="$2"
team_role="$3"
mode="$4"

case "$team_role" in recruiter|hiring_manager|interviewer|coordinator|executive_sponsor) ;; *) echo "step 0: invalid team_role '${team_role}'" >&2; exit 1 ;; esac
case "$mode" in add|remove) ;; *) echo "step 0: mode must be add or remove" >&2; exit 1 ;; esac

# Step 1: parallel-fetch (no dependency between user and job lookups).
user=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/users?email_address=eq.${user_email}&select=id,display_name\"}") \
  || { echo "step 1: user '${user_email}' not found" >&2; exit 1; }
user_id=$(printf '%s' "$user" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')
user_name=$(printf '%s' "$user" | grep -oE '"display_name":"[^"]+"' | sed 's/"display_name":"\([^"]*\)"/\1/')

job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.${job_arg}&select=id,job_title\"}" 2>/dev/null) \
  || job_opening=""
if [ -z "$job_opening" ]; then
  jobs=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/job_openings?search_vector=wfts(simple).${job_arg}&select=id,job_title\"}")
  match_count=$(printf '%s' "$jobs" | grep -oE '"id"' | wc -l | tr -d ' ')
  [ "$match_count" = "1" ] || { echo "step 1: job opening not found or ambiguous (${match_count})" >&2; exit 1; }
  job_opening="$jobs"
fi
job_opening_id=$(printf '%s' "$job_opening" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')
job_title=$(printf '%s' "$job_opening" | grep -oE '"job_title":"[^"]+"' | head -n1 | sed 's/"job_title":"\([^"]*\)"/\1/')

# Step 2: read-first dedupe on the (job_opening_id, user_id, team_role) triple.
existing=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/hiring_team_members?job_opening_id=eq.${job_opening_id}&user_id=eq.${user_id}&team_role=eq.${team_role}&select=id,is_active\"}") \
  || { echo "step 2: junction lookup failed" >&2; exit 2; }
existing_id=$(printf '%s' "$existing" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/' || true)
existing_active=$(printf '%s' "$existing" | grep -oE '"is_active":(true|false)' | head -n1 | sed 's/"is_active"://' || true)

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

# Step 3: write.
if [ "$mode" = "add" ]; then
  if [ -z "$existing_id" ]; then
    body="{\"team_member_label\":\"${team_member_label}\",\"job_opening_id\":\"${job_opening_id}\",\"user_id\":\"${user_id}\",\"team_role\":\"${team_role}\",\"assigned_at\":\"${now}\",\"is_active\":true}"
    semantius call crud postgrestRequest --single \
      "{\"method\":\"POST\",\"path\":\"/hiring_team_members\",\"body\":${body}}" \
      > /dev/null \
      || { echo "step 3: POST hiring_team_members failed; if the platform 409s, the live schema may have a unique constraint, recommend regenerating the skill" >&2; exit 2; }
    echo "assign-hiring-team-member: added ${user_name} as ${role_label} on ${job_title}"
  elif [ "$existing_active" = "true" ]; then
    echo "assign-hiring-team-member: ${user_name} already active as ${role_label} on ${job_title}; nothing to do"
  else
    semantius call crud postgrestRequest --single \
      "{\"method\":\"PATCH\",\"path\":\"/hiring_team_members?id=eq.${existing_id}\",\"body\":{\"is_active\":true,\"assigned_at\":\"${now}\"}}" \
      > /dev/null \
      || { echo "step 3: PATCH reactivate failed" >&2; exit 2; }
    echo "assign-hiring-team-member: reactivated ${user_name} as ${role_label} on ${job_title}"
  fi
else
  if [ -z "$existing_id" ]; then
    echo "assign-hiring-team-member: ${user_name} was not on the team for ${job_title} as ${role_label}; nothing to do"
  elif [ "$existing_active" = "false" ]; then
    echo "assign-hiring-team-member: ${user_name} already inactive as ${role_label} on ${job_title}; nothing to do"
  else
    semantius call crud postgrestRequest --single \
      "{\"method\":\"PATCH\",\"path\":\"/hiring_team_members?id=eq.${existing_id}\",\"body\":{\"is_active\":false}}" \
      > /dev/null \
      || { echo "step 3: PATCH deactivate failed" >&2; exit 2; }
    echo "assign-hiring-team-member: deactivated ${user_name} as ${role_label} on ${job_title}"
  fi
fi
