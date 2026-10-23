#!/bin/bash
# Fails unless an app carries a team-anchored designated requirement.
#
# A permission grant (Accessibility, Microphone) is bound to the app's designated requirement — not
# its name, not its path. A requirement that names the team
#
#     identifier "com.ponti.ponte" and anchor apple generic and certificate leaf[subject.OU] = TEAM
#
# is satisfied by every build that team ever signs, so grants survive rebuilds and updates. The two
# other arrangements do not:
#
#   * an ad-hoc signature (--sign -) gets a bare cdhash, which changes on every single build;
#   * a development certificate adds the development marker (…100.6.2.12) that a Developer ID build
#     does not carry, so alternating between the two clears every grant each time.
#
# In both cases System Settings keeps showing the toggle as ON while it applies to nothing, so the
# symptom is not a prompt — it is auto-paste quietly degrading to "copied to clipboard".
#
#   ./scripts/check-signature.sh /Applications/Ponte.app [TEAM_ID]
set -euo pipefail

APP="${1:?usage: check-signature.sh <app> [team id]}"
TEAM="${2:-3QHJ2KN8AL}"

REQ="$(codesign -d -r- "$APP" 2>&1 | grep -i '^designated' | sed 's/^designated => //' || true)"
echo "    requirement: ${REQ:-none}"
[ -n "$REQ" ] || { echo "error: $APP has no designated requirement — it is not properly signed." >&2; exit 1; }

if ! grep -q "anchor apple generic" <<<"$REQ"; then
  echo "error: $APP is ad-hoc signed. Its requirement is a per-build hash, so every rebuild silently" >&2
  echo "       invalidates the Accessibility grant and auto-paste stops working with nothing visibly wrong." >&2
  exit 1
fi

if ! grep -q "$TEAM" <<<"$REQ"; then
  echo "error: $APP's requirement does not name team $TEAM, so grants made for this build will not" >&2
  echo "       apply to builds signed with the team certificate (and vice versa)." >&2
  exit 1
fi

if grep -q "100.6.2.12" <<<"$REQ"; then
  echo "warning: $APP is signed with a development certificate (…100.6.2.12). A Developer ID build does" >&2
  echo "         not satisfy this requirement, so alternating between them clears the grant each way." >&2
fi

echo "    team-anchored: yes — grants survive future builds"
