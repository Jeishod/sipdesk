# SipDesk — agent rules

Native macOS menu-bar SIP softphone (SwiftUI/AppKit, PJSIP), connects directly to the user's own PBX or SIP provider. Global instructions in /Users/jeishod/.agents/AGENTS.md apply.
Git repo, origin Jeishod/sipdesk. Work in worktrees (`agent-worktree create`); `main` changes only through a PR.

## Tasks: Linear SIP (Andrei, 2026-11-14)

- Tracker: personal Linear workspace `jeishod`, team **SIPCraft** (key `SIP`). The team holds two products told apart by the issue label group "Продукт SIP": label **SIPDesk** for this repo, **SIPCraft** for the SIP server. Every change starts with a SIP issue. No issue, no work.
- Branch `<type>/SIP-<n>-<slug>`; every commit message carries `SIP-<n>` (`Refs SIP-<n>` or `Closes SIP-<n>`); the PR title or body names the issue. Enforced by `~/.agents/hooks/git-guard.py` via `~/.agents/task-scopes.json`.
- Issues are grouped into Linear **Projects** (epics): an issue in work belongs to a Project; Triage may be projectless until sorted. A new body of work gets a new Project.
- Access: `linear-jeishod` CLI (`~/.agents/tools/linear-jeishod`), not the Gen2B Linear MCP connector. Only the main session writes to Linear; subagents draft and report.
- Statuses: Backlog/Todo → In Progress → In Review → Done, moved after the real result (PR merged / deploy verified).
- Issue and PR text in English.
