# Jeskai deck: playtest findings

The Jeskai deck (`config/decks/jeskai.txt`, commander Zinnia, Valley's Voice) is played with
`/games/<id>?deck=jeskai` or `DECK=jeskai bin/rails runner script/simulate.rb <seed>`. The implementation work is in
`mtg/docs/jeskai-deck-plan.md`.

Method: 50 seeded bot games (`DECK=jeskai`, seeds 1-50, `TABLE_DEBUG=1`), run ten at a time in the background.
A seed passes when `Bot` plays it to a winner with no `BUG:` line (`Bot::Stuck`).

**Result: 50 of 50 seeds finish to a winner**, in 51 to 167 decisions on the first sweep. No game stalled, hung or raised a
`Bot::Stuck`. The sweep was run twice: once before and once after the gap fixes below.

The `RuntimeError: <creature> has menace and can't be blocked except by two or more creatures` lines in a sweep with
`TABLE_DEBUG=1` are not bugs: the bot declares one blocker, the engine refuses the block as a whole, and the bot falls
back to no blocks (`Bot#act`, "an illegal set of blocks is refused as a whole").

## Known gaps, and what was done about them

| Gap | Outcome |
|-----|---------|
| Adeline's token always attacked the player. | Fixed. `AttackTargetChoice` offers the player and each planeswalker they control; with no planeswalker the lone option is chosen for you. |
| Suture Priest always took both "may" triggers. | Fixed. Both are `Choice::May` (gain 1 life / have that player lose 1 life); declining does nothing. |
| Solemn Simulacrum always drew when it died. | Fixed. The draw is a `Choice::May` (the land search already was). |
| Echoing Assault asked for a target when only one attacker qualified. | Fixed. It is mandatory, so it goes through `Stack#add_choice`, which picks a lone legal target. |
| Skyclave Apparition and Sun Titan ask for a target when only one is legal. | Not a bug: "up to one" and "you may return" are optional, so the player must be able to decline. They stay as they are. |
| Arena's auto-tapper never tapped a hybrid-cost filter land (Cascade Bluffs, Rugged Prairie ...), so it only gave `{C}`. | Fixed. `Table#pool_payment` pays a source's own generic or hybrid cost (`{U/R}, {T}`) from the pool, and picks the filter pair (`blue_red`) the spell still needs. `TableTest` casts Dualcaster Mage through Cascade Bluffs and two Mountains. |
| A token that is a copy needs the copied card's art. | Already works: a permanent's `name` is its copiable card's name, and the image is looked up by name. |

## Still not modelled

- Nothing from the Jeskai plan. Graveyard "may" cards and optional targets behave as printed.
