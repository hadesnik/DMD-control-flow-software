# AGENTS.md — Instructions for Claude Code Sessions

You are one of several parallel Claude Code agents working on
the TF-Photostim MATLAB codebase.

## Before starting any task
1. Read CLAUDE.md — project context, conventions, hardware API
2. Read ARCHITECTURE.md — class design, data flow, phase plan
3. Read TASKS.md — find one AVAILABLE task whose dependencies are met
4. Confirm the task is still AVAILABLE (another agent may have claimed it)

## Claiming a task
- Edit TASKS.md: change [AVAILABLE] to [IN PROGRESS]
- Commit that change FIRST before writing any code:
  git add TASKS.md
  git commit -m "TASK-P2-XX: claiming task"
  git push
- If git push fails (another agent claimed it first),
  git pull and pick a different task

## Working on a task
- Only touch files listed in your task's "Files" section
- Run runtests BEFORE starting — note the baseline count
- Show diffs before applying every file change
- Run runtests AFTER each file — confirm no regressions
- If runtests shows NEW failures not in your task spec, STOP and report

## Finishing a task
- Run runtests one final time — paste the summary
- git add <only your task's files>
- git commit -m "TASK-P2-XX: description (Y/Z tests green)"
- git push
- Update TASKS.md: change [IN PROGRESS] to [DONE]
- git add TASKS.md && git commit -m "TASK-P2-XX: mark done" && git push

## Hard rules
- NEVER invent ALP function names — only use what's in
  vendor/alp/official/alp.h or vendor/alp/official-4.1/alp.h
- NEVER modify files outside your task's "Files" section
- NEVER modify test files unless your task explicitly says to
- Error identifiers: tfp:<module>:<class>:<reason>
- Private properties: trailing underscore convention
- All assumed parameters: %ASSUMED comment
- configField(struct, name, default) for all config reads

## If you get stuck
Stop. Describe the blocker clearly. Wait for human input.
Never guess on hardware API calls — the cost of a wrong
calllib() call is a crashed MATLAB session or a damaged DMD.
