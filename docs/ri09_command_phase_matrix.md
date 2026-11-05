# RI-09 — command × phase matrix

## The invariant

Every public mutation command has an explicit allowed-phase set.

```
wrong phase:
    return failure
    no gold change
    no inventory change
    no unit change
    no map/reward change
    no RNG draw
    no event emission
    no save side effect
```

The matrix is the single source of truth. The guards are derived from
it, so they cannot become a scatter of ad-hoc conditions.

## The phases

```
PREP=0  BATTLE=1  REWARD=2  GAMEOVER=3  MAP=4  SERVICE=5
```

## The commands

| command | mutates | allowed phases | guard |
|---|---|---|---|
| `start_run` | the whole run | any (the entry point) | unguarded, by design |
| `buy_unit` | gold, bench units, the shop offer | PREP | the matrix |
| `buy_item` | gold, the inventory | PREP | the matrix |
| `board_to_bench` | the unit location | PREP | the matrix |
| `bench_to_board` | the unit location | PREP | the matrix |
| `swap_board_units` | the unit order | PREP | the matrix |
| `swap_units_by_id` | the unit order | PREP | the matrix |
| `board_to_bench_by_id` | the unit location | PREP | the matrix |
| `bench_to_board_by_id` | the unit location | PREP | the matrix |
| `equip_item_by_id` | the inventory, the equipment | PREP, BATTLE, REWARD, MAP, SERVICE | the matrix |
| `unequip_item_by_id` | the inventory, the equipment | PREP, BATTLE, REWARD, MAP, SERVICE | the matrix |
| `move_to_board` | the unit location | PREP | the matrix |
| `grant_item` | the inventory | PREP | the matrix |
| `remove_item_at` | the inventory | PREP | the matrix |
| `equip_item_at` | the inventory, the equipment | PREP, BATTLE, REWARD, MAP, SERVICE | the matrix |
| `unequip_item_at` | the inventory, the equipment | PREP, BATTLE, REWARD, MAP, SERVICE | the matrix |
| `exit_shop_to_map` | the phase | PREP | its own check |
| `start_battle` | the phase, the battle | PREP, MAP | its own check |
| `tick_battle` | the battle | BATTLE | the scene gates it |
| `choose_reward` | the board, the reward | REWARD | its own check |
| `skip_reward` | the phase, the reward | REWARD | its own check |
| `_on_node_selected` | the map, the phase | MAP | its own check |

Every row of the matrix is enforced by `COMMAND_PHASES` in
`core/progression/run_controller.gd`, which is the machine-readable
form of this table. The commands with "its own check" are not in the
matrix: they are the phase transitions themselves.

## The reward delivery is NOT a command

The game's own item rewards do NOT go through the `grant_item`
command, because they are delivered in phases where a command is
refused:

| reward | phase | path |
|---|---|---|
| the TREASURE node's random item | MAP | `_apply_treasure_effect` → `_grant_reward_item` |
| the post-victory combat drop (35%) | BATTLE | `_grant_combat_drop` → `_grant_reward_item` |

`_grant_reward_item` is an INTERNAL grant: it is not a player command,
so it has no phase guard, and it is the only path the rewards use.

This separation is what keeps both properties: the player-facing
`grant_item` stays PREP-only, and the rewards land.

The first version of the matrix made `grant_item` the single path, and
that silently killed both rewards: the TREASURE item and the combat
drop were refused in every run (measured: 0/20 drops through the real
battle path).

## Why the equipment commands are allowed in every live phase

The inventory is an OVERLAY inside the battle scene, toggled with the
`I` key, and it is reachable in every phase. `equip_item_by_id` and
`unequip_item_by_id` are called from there.

The equipment bonuses are read ONCE, in `start_battle` (the combatant
is built with `get_unit_bonus_stats`), so equipping during a battle
changes the NEXT battle, not the running one. It is a legal UX, and a
"PREP only" guard would break it.

What the equipment commands must NOT do is run after the run is over:
GAMEOVER admits no mutation.

## Why PREP for the board and the inventory commands

The board is only editable between the battles: the battle snapshot is
taken in `start_battle` from the board units, and the reward screen
places a unit onto the board. A mutation during BATTLE would change
the live state under the battle, and the battle participants were
already captured -- so the mutated unit would not be the one in the
fight, and the outcome would be written against a different board.

The BOARD commands are only editable between the battles: the battle
snapshot is taken in `start_battle` from the board units, and the
reward screen places a unit onto the board. A mutation during BATTLE
would change the live state under the battle, and the participants
were already captured.

The GOLD commands (`buy_unit`, `buy_item`) are only editable between
the battles: they spend gold, and the merchant offer exists only in
PREP (the MERCHANT effect enters PREP, `run_controller.gd:1283`).

GAMEOVER admits no mutation at all: the run is over. SERVICE is a
phase that is never entered in the current code, and the equipment
commands are allowed there for the future, so the phase is not a
restriction that anything depends on today.

## The exploitable case

`buy_item` had no guard at all in the earlier code: it spent gold and
granted an item in ANY phase, including during a battle. That is a
violation of the command contract, not a theoretical debt.

## The implementation shape

The guards are derived from ONE table, so they cannot drift apart:

```gdscript
## The allowed phases of every public mutation command.
const COMMAND_PHASES: Dictionary = { ... }
```

A single helper answers the question:

```gdscript
func _command_allowed(command: String) -> bool
```

Every guarded command starts with:

```gdscript
if not _command_allowed("buy_item"):
    return false
```

The helper logs the refusal through GameLog, so the violation is
visible, and it returns BEFORE any mutation, so nothing is changed:
no gold, no inventory, no unit, no RNG draw, no event, no save.
