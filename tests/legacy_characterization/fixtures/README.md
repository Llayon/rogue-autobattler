# Legacy Characterization Fixtures

This directory contains observations of the current legacy battle engine only.

- Fixtures must not be treated as the normative `BattleSimulation` contract.
- A known legacy quirk may be recorded here without forcing the ECS backend to reproduce it.
- Fixture updates must be explicit and reviewed; CI must never rewrite fixtures automatically.
- No fixture may derive identity from array index or board position. The current minimal suite uses isolated object references because stable persisted instance IDs are intentionally deferred to the post-Phase-0 Save Schema v4 phase.
