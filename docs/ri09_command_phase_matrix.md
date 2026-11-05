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

| command | mutates | allowed phases | existing guard |
|---|---|---|---|
| `start_run` | the whole run | any (the entry point) | none, by design |
| `buy_unit` | gold, bench units, the shop offer | PREP | PREP ✓ |
| `buy_item` | gold, the inventory | PREP | PREP ✓ |
| `board_to_bench` | the unit location | PREP | **none** ✗ |
| `bench_to_board` | the unit location | PREP | **none** ✗ |
| `swap_board_units` | the unit order | PREP | **none** ✗ |
| `swap_units_by_id` | the unit order | PREP | **none** ✗ |
| `board_to_bench_by_id` | the unit location | PREP | **none** ✗ |
| `bench_to_board_by_id` | the unit location | PREP | **none** ✗ |
| `equip_item_by_id` | the inventory, the equipment | PREP, BATTLE, REWARD, MAP, SERVICE | **none** ✗ |
| `unequip_item_by_id` | the inventory, the equipment | PREP, BATTLE, REWARD, MAP, SERVICE | **none** ✗ |
| `move_to_board` | the unit location | PREP | **none** ✗ |
| `grant_item` | the inventory | PREP | **none** ✗ |
| `remove_item_at` | the inventory | PREP | **none** ✗ |
| `equip_item_at` | the inventory, the equipment | PREP | **none** ✗ |
| `unequip_item_at` | the inventory, the equipment | PREP | **none** ✗ |
| `exit_shop_to_map` | the phase | PREP | PREP ✓ |
| `start_battle` | the phase, the battle | PREP, MAP | PREP+MAP ✓ |
| `tick_battle` | the battle | BATTLE | the scene gates it ✓ |
| `choose_reward` | the board, the reward | REWARD | REWARD ✓ |
| `skip_reward` | the phase, the reward | REWARD | REWARD ✓ |
| `_on_node_selected` | the map, the phase | MAP | MAP ✓ |

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

GAMEOVER and SERVICE admit no mutation at all: the run is over, and
the service effect is applied by the map flow itself.

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
