#!/usr/bin/env bash
# submit-feedback.sh: Capture or finalize an interview_feedback row for one
# interviewer on one interview. Composes the caller-populated feedback_label
# and pairs is_submitted=true with submitted_at when the mode is `submit`
# (the platform rejects unpaired writes via submitted_at_required_when_submitted
# and submitted_at_only_when_submitted).
#
# Usage: submit-feedback.sh <candidate-email-or-name> <interview-kind> <interviewer-email> <submit|draft> [overall_rating] [recommendation]
#
# interview-kind: one of phone_screen, video_call, onsite, technical,
#   take_home, panel, final, reference_check.
# overall_rating (required when submit): strong_yes | yes | lean_yes |
#   lean_no | no | strong_no.
# recommendation (required when submit): advance | hold | reject.
#
# Exit:  0 on success
#        1 on usage / unresolved lookup / multiple interviews matched
#        2 on platform error
#
# Idempotent: re-running create-then-submit is safe (the second create finds
# the existing draft and PATCHes; the second submit is a no-op).
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "Usage: $(basename "$0") <candidate-email-or-name> <interview-kind> <interviewer-email> <submit|draft> [overall_rating] [recommendation]" >&2
  exit 1
fi

candidate_arg="$1"
interview_kind="$2"
interviewer_email="$3"
mode="$4"
rating="${5:-}"
recommendation="${6:-}"

case "$mode" in submit|draft) ;; *) echo "step 0: mode must be submit or draft" >&2; exit 1 ;; esac
case "$interview_kind" in
  phone_screen|video_call|onsite|technical|take_home|panel|final|reference_check) ;;
  *) echo "step 0: invalid interview_kind '${interview_kind}'" >&2; exit 1 ;;
esac

if [ "$mode" = "submit" ]; then
  case "$rating" in strong_yes|yes|lean_yes|lean_no|no|strong_no) ;; *) echo "step 0: submit mode requires overall_rating (strong_yes | yes | lean_yes | lean_no | no | strong_no)" >&2; exit 1 ;; esac
  case "$recommendation" in advance|hold|reject) ;; *) echo "step 0: submit mode requires recommendation (advance | hold | reject)" >&2; exit 1 ;; esac
fi

# Step 1: resolve candidate.
if [[ "$candidate_arg" == *@*.* ]]; then
  candidate=$(semantius call crud postgrestRequest --single \
    "{\"method\":\"GET\",\"path\":\"/candidates?email_address=eq.${candidate_arg}&select=id,full_name\"}") \
    || { echo "step 1: candidate '${candidate_arg}' not found by email" >&2; exit 1; }
else
  candidates=$(semantius call crud postgrestRequest \
    "{\"method\":\"GET\",\"path\":\"/candidates?search_vector=wfts(simple).${candidate_arg}&select=id,full_name\"}") \
    || { echo "step 1: candidate search failed" >&2; exit 2; }
  match_count=$(printf '%s' "$candidates" | grep -oE '"id"' | wc -l | tr -d ' ')
  [ "$match_count" = "1" ] || { echo "step 1: candidate ambiguous or missing (${match_count} matches)" >&2; exit 1; }
  candidate="$candidates"
fi
candidate_id=$(printf '%s' "$candidate" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')
candidate_name=$(printf '%s' "$candidate" | grep -oE '"full_name":"[^"]+"' | head -n1 | sed 's/"full_name":"\([^"]*\)"/\1/')

# Step 2: resolve interviewer by email (unique).
interviewer=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/users?email_address=eq.${interviewer_email}&select=id,display_name\"}") \
  || { echo "step 2: interviewer '${interviewer_email}' not found" >&2; exit 1; }
interviewer_id=$(printf '%s' "$interviewer" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/')
interviewer_name=$(printf '%s' "$interviewer" | grep -oE '"display_name":"[^"]+"' | sed 's/"display_name":"\([^"]*\)"/\1/')

# Step 3: resolve the interview by candidate's applications -> interviews of the requested kind.
applications=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.${candidate_id}&select=id\"}") \
  || { echo "step 3a: application lookup failed" >&2; exit 2; }
app_ids=$(printf '%s' "$applications" | grep -oE '"id":"[^"]+"' | sed 's/"id":"\([^"]*\)"/\1/' | tr '\n' ',' | sed 's/,$//')
[ -n "$app_ids" ] || { echo "step 3a: no applications found for candidate ${candidate_name}" >&2; exit 1; }

interviews=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/interviews?application_id=in.(${app_ids})&interview_kind=eq.${interview_kind}&select=id,interview_label,scheduled_start\"}") \
  || { echo "step 3b: interview lookup failed" >&2; exit 2; }
match_count=$(printf '%s' "$interviews" | grep -oE '"id"' | wc -l | tr -d ' ')
if [ "$match_count" = "0" ]; then
  echo "step 3b: no ${interview_kind} interview found for ${candidate_name}" >&2
  exit 1
fi
if [ "$match_count" != "1" ]; then
  echo "step 3b: more than one ${interview_kind} interview for ${candidate_name}; ask the user to specify the date or pass interview_label directly" >&2
  exit 1
fi
interview_id=$(printf '%s' "$interviews" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/')

# Step 4: dedupe-on-junction. Does an interview_feedback row already exist for this (interview, interviewer)?
existing=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/interview_feedback?interview_id=eq.${interview_id}&interviewer_user_id=eq.${interviewer_id}&select=id,is_submitted\"}") \
  || { echo "step 4: feedback dedupe lookup failed" >&2; exit 2; }
existing_id=$(printf '%s' "$existing" | grep -oE '"id":"[^"]+"' | head -n1 | sed 's/"id":"\([^"]*\)"/\1/' || true)

# Title-case the interview_kind for the label.
case "$interview_kind" in
  phone_screen) kind_label="Phone Screen" ;;
  video_call) kind_label="Video Call" ;;
  onsite) kind_label="Onsite" ;;
  technical) kind_label="Technical" ;;
  take_home) kind_label="Take Home" ;;
  panel) kind_label="Panel" ;;
  final) kind_label="Final" ;;
  reference_check) kind_label="Reference Check" ;;
esac
feedback_label="${interviewer_name}, ${kind_label} for ${candidate_name}"
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Step 5: write.
if [ -z "$existing_id" ]; then
  # Create new feedback row. If submit mode, write everything in one POST.
  if [ "$mode" = "submit" ]; then
    body="{\"feedback_label\":\"${feedback_label}\",\"interview_id\":\"${interview_id}\",\"interviewer_user_id\":\"${interviewer_id}\",\"overall_rating\":\"${rating}\",\"recommendation\":\"${recommendation}\",\"is_submitted\":true,\"submitted_at\":\"${now}\"}"
  else
    body="{\"feedback_label\":\"${feedback_label}\",\"interview_id\":\"${interview_id}\",\"interviewer_user_id\":\"${interviewer_id}\",\"is_submitted\":false}"
  fi
  semantius call crud postgrestRequest --single \
    "{\"method\":\"POST\",\"path\":\"/interview_feedback\",\"body\":${body}}" \
    > /dev/null \
    || { echo "step 5: POST interview_feedback failed" >&2; exit 2; }
  echo "submit-feedback: created ${mode} feedback for ${candidate_name} / ${kind_label} (interviewer ${interviewer_name})"
else
  # PATCH existing row. If submit mode and not already submitted, pair is_submitted+submitted_at.
  if [ "$mode" = "submit" ]; then
    if printf '%s' "$existing" | grep -q '"is_submitted":true'; then
      echo "submit-feedback: feedback ${existing_id} already submitted; nothing to do" >&2
      exit 0
    fi
    body="{\"overall_rating\":\"${rating}\",\"recommendation\":\"${recommendation}\",\"is_submitted\":true,\"submitted_at\":\"${now}\"}"
  else
    body="{\"is_submitted\":false}"
  fi
  semantius call crud postgrestRequest --single \
    "{\"method\":\"PATCH\",\"path\":\"/interview_feedback?id=eq.${existing_id}\",\"body\":${body}}" \
    > /dev/null \
    || { echo "step 5: PATCH interview_feedback failed" >&2; exit 2; }
  echo "submit-feedback: updated feedback ${existing_id} (${mode}) for ${candidate_name} / ${kind_label}"
fi
