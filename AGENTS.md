# Agent Instructions

Read the constitution: `.specify/memory/constitution.md`

It contains all instructions for working on this project including workflow,
boundaries, queue mechanics, and completion signals.

## Quick Reference

### You're in a Ralph Loop if:

- Started by ralph-loop.sh
- Prompt mentions "implement spec" or constitution
- You see `<promise>` completion signals in spec

**Action**: Read scout/QUEUE.md. Check mode. Follow spec. Output `<promise>DONE</promise>`.

### You're in Interactive Chat if:

- User is asking questions or discussing
- No Ralph loop context

**Action**: Be helpful. Explain the scout system. Help write CONTEXT.md.
