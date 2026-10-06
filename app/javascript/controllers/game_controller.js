import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { cardImages } from "scryfall"

export default class extends Controller {
  static values = { id: String, deck: String }
  static targets = [
    "status", "hint", "choice", "choicePrompt", "choiceOptions", "join", "picker", "pickerOptions", "board", "turn", "steps", "advance", "error", "preview",
    "opponent", "opponentHand", "opponentOther", "opponentLands",
    "you", "manaPool", "hand", "yourOther", "yourLands",
    "yourGraveyard", "opponentGraveyard", "exile", "concede", "deck", "yourLibrary", "opponentLibrary", "viewer", "viewerTitle", "viewerCards", "log", "stack", "stackItems"
  ]

  connect() {
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "GameChannel", id: this.idValue, deck: this.deckValue },
      { received: (state) => this.receive(state) }
    )
    this.onKeydown = (event) => this.keydown(event)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    this.consumer.disconnect()
  }

  // Space does what the main button does (next step, confirm attackers or blockers, pass priority), unless there is a
  // choice to answer or the key belongs to a focused control, where it would click that control instead.
  keydown(event) {
    if (event.code !== "Space" || event.repeat || event.ctrlKey || event.metaKey || event.altKey) return
    if (event.target.closest?.("button, input, textarea, select, a, [contenteditable]")) return

    const state = this.state
    if (!state || !state.can_act || state.over || (state.choice && !state.priority)) return

    event.preventDefault()
    this.advance()
  }

  join() {
    this.subscription.perform("join", { deck: this.selectedDeck })
  }

  selectDeck(event) {
    this.selectedDeck = event.currentTarget.dataset.deck
    this.markSelectedDeck()
  }

  // One option per deck, showing its commander. Built once; later renders only move the highlight.
  renderDeckPicker(decks) {
    const signature = decks.map((deck) => deck.name).join(",")
    if (this.deckPickerSignature !== signature) {
      this.deckPickerSignature = signature
      this.pickerOptionsTarget.replaceChildren(...decks.map((deck) => this.deckOption(deck)))
    }
    this.markSelectedDeck()
  }

  deckOption(deck) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "deck-option"
    button.dataset.deck = deck.name
    button.dataset.action = "game#selectDeck"

    const art = document.createElement("div")
    art.className = "deck-option__card"
    art.textContent = deck.commander
    cardImages(deck.commander).then((images) => {
      const img = document.createElement("img")
      img.alt = deck.commander
      img.src = images.normal
      img.onload = () => art.replaceChildren(img)
    }).catch(() => {})

    const label = document.createElement("span")
    label.className = "deck-option__name"
    label.textContent = deck.name.replaceAll("_", " ")

    button.append(art, label)
    return button
  }

  markSelectedDeck() {
    for (const option of this.pickerOptionsTarget.children) {
      option.classList.toggle("deck-option--selected", option.dataset.deck === this.selectedDeck)
    }
  }

  receive(state) {
    if (!state.error) {
      this.state = state
      this.manaPicker = null
    }
    this.render(state)
  }

  advance() {
    const { turn, can_act: canAct } = this.state
    if (this.state.priority) {
      this.subscription.perform("pass_priority")
    } else if (canAct && turn.step === "declare_attackers") {
      this.subscription.perform("declare_attackers", { ids: [...this.attackers], targets: Object.fromEntries(this.attackTargets) })
    } else if (canAct && turn.step === "declare_blockers") {
      this.subscription.perform("declare_blockers", { pairs: [...this.blocks] })
    } else {
      this.subscription.perform("advance_step")
    }
  }

  concede() {
    if (window.confirm("Concede the game?")) this.subscription.perform("concede")
  }

  activatableAbilities(p) {
    return (p.abilities || []).filter((ability) => ability.activatable)
  }

  // One usable ability is activated straight away; with several, the sidebar asks which.
  clickAbility(id) {
    const permanent = this.state.you.battlefield.find((p) => p.id === id)
    const abilities = permanent ? this.activatableAbilities(permanent) : []
    if (abilities.length === 1) {
      this.activate(id, abilities[0].index)
    } else if (abilities.length > 1) {
      this.menu = { id, name: permanent.name, abilities }
      this.render(this.state)
    }
  }

  activate(id, index) {
    this.menu = null
    this.subscription.perform("activate", { id, index })
  }

  activateFromMenu(event) {
    this.activate(Number(event.currentTarget.dataset.id), Number(event.currentTarget.dataset.index))
  }

  cancelMenu() {
    this.menu = null
    this.render(this.state)
  }

  choose(event) {
    this.subscription.perform("choose", { answer: event.currentTarget.dataset.answer })
  }

  // Choices answered in the sidebar: yes/no, one of several options, or an acknowledgement. Targeted choices have no
  // panel (legal targets are highlighted on the board, see #permanentCard and #markPlayerTargets); choices over a list
  // of cards (pick, sort) open a card picker over the board.
  renderChoice(state) {
    const { choice } = state
    if (!choice && this.menu) {
      this.renderAbilityMenu()
      return
    }
    const asking = !!choice?.chooser && (choice.kind !== "target" || choice.cancelable) && choice.kind !== "unsupported"
    this.choiceTarget.hidden = !asking
    this.choiceTarget.classList.toggle("choice--cards", asking && ["pick", "sort"].includes(choice.kind))
    if (!asking) {
      this.choiceKey = null
      return
    }

    // Selections belong to one particular choice; start fresh when a different one appears.
    const key = JSON.stringify([choice.kind, choice.prompt, (choice.cards || []).map((c) => c.id), (choice.options || []).map((o) => o.id), (choice.rows || []).map((r) => r.id)])
    if (key !== this.choiceKey) {
      this.choiceKey = key
      this.assigned = new Map((choice.rows || []).map((row) => [row.id, row.value]))
      this.picked = new Set()
      this.sorted = new Map()
      this.modesPicked = new Set()
    }

    this.choicePromptTarget.textContent = choice.prompt
    const children = {
      may: () => this.answerButtons([{ id: "yes", label: "Yes" }, { id: "no", label: "No" }]),
      options: () => this.answerButtons(choice.options),
      confirm: () => this.answerButtons([{ id: "ok", label: "OK" }]),
      pick: () => this.pickerContents(choice),
      modes: () => this.modeContents(choice),
      sort: () => this.sorterContents(choice),
      assign: () => this.assignContents(choice),
      target: () => []
    }[choice.kind]
    const cancel = choice.cancelable ? this.answerButtons([{ id: "cancel", label: "Cancel" }]) : []
    this.choiceOptionsTarget.replaceChildren(...children(), ...cancel)
  }

  renderAbilityMenu() {
    this.choiceTarget.hidden = false
    this.choiceTarget.classList.remove("choice--cards")
    this.choicePromptTarget.textContent = `Activate which ability of ${this.menu.name}?`
    const buttons = this.menu.abilities.map((ability) => {
      const button = document.createElement("button")
      button.className = "btn"
      button.textContent = ability.label
      button.dataset.id = this.menu.id
      button.dataset.index = ability.index
      button.dataset.action = "game#activateFromMenu"
      return button
    })
    const cancel = document.createElement("button")
    cancel.className = "btn"
    cancel.textContent = "Cancel"
    cancel.dataset.action = "game#cancelMenu"
    this.choiceOptionsTarget.replaceChildren(...buttons, cancel)
  }

  answerButtons(options) {
    return options.map((option) => {
      const button = document.createElement("button")
      button.className = "btn"
      button.textContent = option.label
      button.dataset.answer = option.id
      button.dataset.action = "game#choose"
      return button
    })
  }

  doneButton(label, enabled, onClick) {
    const button = document.createElement("button")
    button.className = "btn btn--primary choice__done"
    button.textContent = label
    button.disabled = !enabled
    button.addEventListener("click", onClick)
    return button
  }

  // Divide combat damage: one number per blocker (and the player, for a trampler) that must add up to the total.
  assignContents(choice) {
    const rows = choice.rows.map((row) => {
      const label = document.createElement("label")
      label.className = "choice__mode"
      const input = document.createElement("input")
      input.type = "number"
      input.min = 0
      input.max = choice.total
      input.value = this.assigned.get(row.id)
      input.size = 3
      // On change, not on every key: re-rendering the panel would take the focus away mid-number.
      input.addEventListener("change", () => {
        this.assigned.set(row.id, Number(input.value) || 0)
        this.renderChoice(this.state)
      })
      const lethal = row.lethal ? ` (lethal ${row.lethal})` : ""
      label.append(input, ` ${row.label}${lethal}`)
      return label
    })
    const sum = [...this.assigned.values()].reduce((a, b) => a + b, 0)
    const done = this.doneButton(`Assign ${sum} of ${choice.total}`, sum === choice.total, () => {
      this.subscription.perform("choose", { answer: Object.fromEntries(this.assigned) })
    })
    return [...rows, done]
  }

  // "Choose one or more": tick between `min` and `max` of the listed modes, then cast.
  modeContents(choice) {
    const rows = choice.options.map((option) => {
      const label = document.createElement("label")
      label.className = "choice__mode"
      const box = document.createElement("input")
      box.type = "checkbox"
      box.checked = this.modesPicked.has(option.id)
      box.addEventListener("change", () => {
        if (box.checked) this.modesPicked.add(option.id)
        else this.modesPicked.delete(option.id)
        this.renderChoice(this.state)
      })
      label.append(box, ` ${option.label}`)
      return label
    })
    const count = this.modesPicked.size
    const done = this.doneButton("Cast", count >= choice.min && count <= choice.max, () => {
      this.subscription.perform("choose", { answer: [...this.modesPicked] })
    })
    return [...rows, done]
  }

  // Pick between `min` and `max` cards from a list.
  pickerContents(choice) {
    // Cards picked out of graveyards get a tab per graveyard, so it is clear whose cards they are.
    const tabbed = choice.cards.length > 0 && choice.cards.every((card) => card.graveyard_of)
    const mine = (card) => card.graveyard_of === this.state.you.name
    const tabs = tabbed ? [["you", "Your Graveyard", choice.cards.filter(mine)], ["opponent", "Opponent's Graveyard", choice.cards.filter((c) => !mine(c))]] : []
    if (tabbed && !tabs.some(([id]) => id === this.pickTab)) this.pickTab = "you"
    const shown = tabbed ? tabs.find(([id]) => id === this.pickTab)[2] : choice.cards
    const cards = shown.map((card) => {
      const el = this.card(card.name, { classes: this.picked.has(card.id) ? ["card--selected"] : ["card--playable"] })
      el.addEventListener("click", () => {
        if (this.picked.has(card.id)) this.picked.delete(card.id)
        else if (this.picked.size < choice.max) this.picked.add(card.id)
        else if (choice.max === 1) this.picked = new Set([card.id])
        this.renderChoice(this.state)
      })
      return el
    })
    const count = this.picked.size
    const label = count === 0 && choice.min === 0 ? "Choose nothing" : `Choose ${count} card${count === 1 ? "" : "s"}`
    const done = this.doneButton(label, count >= choice.min && count <= choice.max, () => {
      this.subscription.perform("choose", { answer: [...this.picked] })
    })
    const list = document.createElement("div")
    list.className = "choice__cards"
    list.append(...cards)
    if (!tabbed) return [list, done]

    const bar = document.createElement("div")
    bar.className = "tabs"
    bar.setAttribute("role", "tablist")
    for (const [id, label, tabCards] of tabs) {
      const tab = document.createElement("button")
      tab.className = "tab"
      tab.setAttribute("role", "tab")
      tab.setAttribute("aria-selected", this.pickTab === id)
      tab.classList.toggle("tab--on", this.pickTab === id)
      const picked = tabCards.filter((c) => this.picked.has(c.id)).length
      tab.textContent = `${label} (${tabCards.length})${picked ? ` · ${picked} chosen` : ""}`
      tab.addEventListener("click", () => {
        this.pickTab = id
        this.renderChoice(this.state)
      })
      bar.append(tab)
    }
    if (!cards.length) list.textContent = "No cards in this graveyard."
    return [bar, list, done]
  }

  // Put each card at one end of the library, or in the graveyard (scry and surveil).
  sorterContents(choice) {
    const [first, second] = choice.destinations
    const rows = choice.cards.map((card) => {
      const destination = this.sorted.get(card.id) || first
      const row = document.createElement("div")
      row.className = "choice__sort"
      row.append(this.card(card.name))
      for (const option of choice.destinations) {
        const button = document.createElement("button")
        button.className = "btn"
        button.textContent = option
        button.classList.toggle("btn--on", destination === option)
        button.setAttribute("aria-pressed", destination === option)
        button.addEventListener("click", () => {
          this.sorted.set(card.id, option)
          this.renderChoice(this.state)
        })
        row.append(button)
      }
      return row
    })
    const done = this.doneButton("Done", true, () => {
      const answer = { [first]: [], [second]: [] }
      for (const card of choice.cards) answer[this.sorted.get(card.id) || first].push(card.id)
      this.subscription.perform("choose", { answer })
    })
    const list = document.createElement("div")
    list.className = "choice__cards"
    list.append(...rows)
    return [list, done]
  }

  choiceTargetIds(state) {
    const { choice } = state
    return choice?.chooser && choice.kind === "target" ? new Set(choice.targets.map((t) => t.id)) : new Set()
  }

  // Players are targets too: their name plates become clickable.
  markPlayerTargets(state) {
    const ids = this.choiceTargetIds(state)
    for (const [target, player] of [[this.youTarget, state.you], [this.opponentTarget, state.opponent]]) {
      const targetable = ids.has(player.name)
      target.classList.toggle("plate--target", targetable)
      if (targetable) {
        target.dataset.answer = player.name
        target.dataset.action = "click->game#choose"
      } else {
        delete target.dataset.answer
        delete target.dataset.action
      }
    }
  }

  // Clicking a creature during combat: toggle an attacker, pick a blocker, or choose which attacker a blocker blocks.
  permanentClick(event) {
    const { id, role } = event.currentTarget.dataset
    const numericId = Number(id)
    if (role === "ability") {
      this.clickAbility(numericId)
      return
    }
    if (role === "mana") {
      this.clickMana(numericId)
      return
    }
    if (role === "unmana") {
      this.subscription.perform("untap_for_mana", { id: numericId })
      return
    }
    if (role === "choice") {
      this.subscription.perform("choose", { answer: id })
      return
    }
    if (role === "attacker") {
      // Shift-click acts on every token in the stack; a plain click on one.
      const ids = event.shiftKey && event.currentTarget.dataset.group
        ? event.currentTarget.dataset.group.split(",").map(Number)
        : [numericId]
      const deselect = this.attackers.has(numericId)
      for (const attackerId of ids) {
        if (deselect) {
          this.attackers.delete(attackerId)
          this.attackTargets.delete(attackerId)
        } else {
          this.attackers.add(attackerId)
        }
      }
    } else if (role === "planeswalker") {
      this.sendAttackersTo(numericId)
    } else if (role === "blocker") {
      if (this.blocks.has(numericId)) this.blocks.delete(numericId)
      else this.blocker = this.blocker === numericId ? null : numericId
    } else if (role === "target" && this.blocker !== null) {
      this.blocks.set(this.blocker, numericId)
      this.blocker = null
    }
    this.render(this.state)
  }

  // Clicking an opposing planeswalker while declaring attackers sends every selected attacker at it, or, when they
  // are all at it already, back at the player.
  sendAttackersTo(id) {
    const selected = [...this.attackers]
    const allThere = selected.length > 0 && selected.every((attacker) => this.attackTargets.get(attacker) === id)
    for (const attacker of selected) {
      if (allThere) this.attackTargets.delete(attacker)
      else this.attackTargets.set(attacker, id)
    }
  }

  playLand(event) {
    const { index, zone } = event.currentTarget.dataset
    // Shift-click plays a modal double-faced land (Needleverge Pathway) as its back face.
    this.subscription.perform("play_land", { index: Number(index), zone: zone || "hand", face: event.shiftKey ? "back" : "front" })
  }

  cast(event) {
    const { index, zone } = event.currentTarget.dataset
    this.subscription.perform("cast", { index: Number(index), zone: zone || "hand" })
  }

  cycle(event) {
    event.stopPropagation()
    this.subscription.perform("cycle", { index: Number(event.currentTarget.dataset.index) })
  }

  // --- event log -----------------------------------------------------------

  // Top-level entries newest first; each one is followed by what it caused, oldest first, so a nested entry always
  // sits below its parent. An entry whose parent has dropped out of the log counts as top-level.
  orderLog(entries) {
    const ids = new Set(entries.map((entry) => entry.id))
    const children = new Map()
    const roots = []
    entries.forEach((entry) => {
      if (entry.parent_id && ids.has(entry.parent_id)) {
        if (!children.has(entry.parent_id)) children.set(entry.parent_id, [])
        children.get(entry.parent_id).push(entry)
      } else {
        roots.push(entry)
      }
    })

    const ordered = []
    const walk = (entry) => {
      ordered.push(entry)
      ;(children.get(entry.id) || []).forEach(walk)
    }
    roots.reverse().forEach(walk)
    return ordered
  }

  // Only touches the DOM when an entry is new. Newest top-level entry renders first, at the top.
  renderLog(entries) {
    const last = entries.length ? entries[entries.length - 1].id : 0
    if (last === this.lastLogId) return
    this.lastLogId = last

    this.logTarget.replaceChildren(...this.orderLog(entries).map((entry) => {
      const li = document.createElement("li")
      li.className = `log__entry log__entry--${entry.kind}`
      li.textContent = entry.text
      // An entry caused by an earlier one (a trigger's life gain, a spell's damage) is indented under its cause and
      // says which card it came from.
      if (entry.depth > 0) {
        li.classList.add("log__entry--linked")
        li.style.setProperty("--depth", entry.depth)
        if (entry.via) {
          const via = document.createElement("span")
          via.className = "log__via"
          via.textContent = ` — ${entry.via}`
          li.append(via)
        }
      }
      return li
    }))
  }

  // --- stack ---------------------------------------------------------------

  // Every spell and ability waiting to resolve, the one that resolves next (the top) first. Hidden when empty.
  renderStack(stack) {
    this.stackTarget.hidden = stack.length === 0
    this.stackItemsTarget.replaceChildren(...stack.map((item) => {
      const li = document.createElement("li")
      li.className = "spell-stack__item"
      const name = document.createElement("span")
      name.className = "spell-stack__name"
      name.textContent = item.name
      const controller = document.createElement("span")
      controller.className = "spell-stack__controller"
      controller.textContent = item.controller
      li.append(name, controller)
      return li
    }))
  }

  // --- graveyards ----------------------------------------------------------

  openGraveyard(event) {
    this.viewing = event.currentTarget.dataset.owner
    this.renderViewer()
  }

  openExile() {
    this.viewing = "exile"
    this.renderViewer()
  }

  closeGraveyard() {
    this.viewing = null
    this.renderViewer()
  }

  // A graveyard shows as a pile with its top card (the most recent) and a count; clicking opens the full list.
  renderPile(target, graveyard) {
    const label = document.createElement("div")
    label.className = "pile__label"
    label.textContent = `Graveyard (${graveyard.length})`
    const top = graveyard.length ? this.card(graveyard[0]) : document.createElement("div")
    if (!graveyard.length) top.className = "card card--empty"
    target.replaceChildren(top, label)
  }

  // A library shows as a pile with a count. When something reveals its top card ("play with the top card revealed")
  // that card lies face up on the pile for both players, and its owner can play it from there if the rules allow.
  renderLibrary(target, player, { mine }) {
    const label = document.createElement("div")
    label.className = "pile__label"
    label.textContent = `Library (${player.library})`

    const top = player.library_top
    let pile
    if (top) {
      const action = mine ? (top.playable_land ? "playLand" : top.castable ? "cast" : null) : null
      pile = this.card(top.name, { playable: action, index: 0, zone: "library" })
      label.textContent += " · top revealed"
    } else {
      pile = this.cardBack()
      if (!player.library) pile.classList.add("card--empty")
    }
    target.replaceChildren(pile, label)
  }

  // Exile is shared and face up: a pile of every exiled card, openable like a graveyard.
  renderExilePile(exiled) {
    const label = document.createElement("div")
    label.className = "pile__label"
    label.textContent = `Exile (${exiled.length})`
    const top = exiled.length ? this.card(exiled[exiled.length - 1].name) : document.createElement("div")
    if (!exiled.length) top.className = "card card--empty"
    this.exileTarget.replaceChildren(top, label)
  }

  renderViewer() {
    const owner = this.viewing
    this.viewerTarget.hidden = !owner || !this.state
    if (this.viewerTarget.hidden) return

    if (owner === "exile") {
      const exiled = this.state.exile || []
      this.viewerTitleTarget.textContent = `Exile (${exiled.length})`
      this.viewerCardsTarget.replaceChildren(...exiled.map((card) =>
        this.card(card.name, { playable: card.castable ? "cast" : null, index: card.index, zone: "exile" })
      ))
      return
    }

    const player = owner === "you" ? this.state.you : this.state.opponent
    this.viewerTitleTarget.textContent = `${player.name}'s graveyard (${player.graveyard.length})`
    // Cards in your own graveyard may have abilities usable from there (Crown of Skemfar): a button for each.
    const abilities = owner === "you" ? [...(player.graveyard_abilities || [])] : []
    this.viewerCardsTarget.replaceChildren(...player.graveyard.map((name) => {
      const el = this.card(name)
      const entry = abilities.find((candidate) => candidate.name === name)
      if (!entry) return el

      abilities.splice(abilities.indexOf(entry), 1)
      const wrapper = document.createElement("div")
      wrapper.className = "viewer__card"
      wrapper.append(el)
      for (const ability of entry.abilities) {
        const button = document.createElement("button")
        button.className = "btn"
        button.textContent = ability.label
        button.disabled = !ability.activatable
        button.addEventListener("click", () => this.subscription.perform("activate_graveyard", { id: entry.id, index: ability.index }))
        wrapper.append(button)
      }
      return wrapper
    }))
  }

  // --- card elements -------------------------------------------------------

  card(name, { tapped = false, playable = null, index = null, zone = null, classes = [], id = null, role = null } = {}) {
    const el = document.createElement("div")
    el.className = "card"
    el.title = name
    el.classList.toggle("card--tapped", tapped)
    el.classList.add(...classes)
    if (role) {
      el.dataset.id = id
      el.dataset.role = role
      el.dataset.action = "click->game#permanentClick"
    }

    const fallback = document.createElement("div")
    fallback.className = "fallback"
    fallback.textContent = name
    el.append(fallback)

    cardImages(name).then((images) => {
      const img = document.createElement("img")
      img.alt = name
      img.src = images.normal
      img.onload = () => fallback.remove()
      el.append(img)
      el.addEventListener("mouseenter", () => this.showPreview(images.large))
      el.addEventListener("mouseleave", () => this.hidePreview())
    }).catch(() => {})

    if (playable) {
      el.classList.add("card--playable")
      el.dataset.index = index
      if (zone) el.dataset.zone = zone
      el.dataset.action = `click->game#${playable}`
    }
    return el
  }

  // Which action a click on this hand card performs, or null when it can't be played right now.
  handAction(card, state) {
    if (card.land) return state.can_play_land ? "playLand" : null
    return card.castable ? "cast" : null
  }

  // A hand card; one that can be cycled also gets a Cycle button over its corner.
  handCard(card, state, index) {
    const el = this.card(card.name, { playable: this.handAction(card, state), index })
    if (card.back_face) el.title = `${card.name} (shift-click to play as ${card.back_face})`
    if (card.cyclable) {
      const button = document.createElement("button")
      button.className = "btn card__cycle"
      button.textContent = "Cycle"
      button.dataset.index = index
      button.addEventListener("click", (event) => this.cycle(event))
      el.append(button)
    }
    return el
  }

  cardBack() {
    const el = document.createElement("div")
    el.className = "card"
    return el
  }

  showPreview(url) {
    this.previewTarget.querySelector("img").src = url
    this.previewTarget.hidden = false
  }

  hidePreview() {
    this.previewTarget.hidden = true
  }

  // Same-name, same-tapped-state lands collapse into one overlapping stack.
  landStacks(lands, mine = false) {
    const groups = new Map()
    for (const land of lands) {
      const key = `${land.name}|${land.tapped}|${JSON.stringify(land.counters)}|${this.activatableAbilities(land).length}|${(land.mana_colors || []).length}|${land.mana_refundable}`
      if (!groups.has(key)) groups.set(key, [])
      groups.get(key).push(land)
    }
    return [...groups.values()].map((group) => {
      const stack = document.createElement("div")
      stack.className = "stack"
      group.forEach((land) => {
        const usable = mine && this.activatableAbilities(land).length > 0
        const taps = mine && (land.mana_colors || []).length > 0
        const refund = mine && land.mana_refundable
        const el = this.card(land.name, refund
          ? { tapped: land.tapped, classes: ["card--playable"], id: land.id, role: "unmana" }
          : usable
          ? { tapped: land.tapped, classes: ["card--playable"], id: land.id, role: "ability" }
          : taps
            ? { tapped: land.tapped, classes: ["card--playable"], id: land.id, role: "mana" }
            : { tapped: land.tapped })
        el.append(...this.counterBadges(land), ...this.manaPickerFor(land))
        stack.append(el)
      })
      if (group.length > 1) {
        const count = document.createElement("span")
        count.className = "stack-count"
        count.textContent = `×${group.length}`
        stack.append(count)
      }
      return stack
    })
  }

  renderField(battlefield, landsTarget, otherTarget, { mine }) {
    landsTarget.replaceChildren(...this.landStacks(battlefield.filter((p) => p.land), mine))
    // Auras and Equipment whose host is also on this side's board render beneath the host, not as their own card.
    const others = battlefield.filter((p) => !p.land)
    const hostIds = new Set(others.map((p) => p.id))
    const attachments = new Map()
    const loose = others.filter((p) => {
      if (p.attached_to === null || p.attached_to === undefined || !hostIds.has(p.attached_to)) return true
      if (!attachments.has(p.attached_to)) attachments.set(p.attached_to, [])
      attachments.get(p.attached_to).push(p)
      return false
    })
    this.attachments = attachments
    otherTarget.replaceChildren(...this.permanentStacks(loose, mine))
  }

  // Identical tokens share a stack with a ×N count. The key includes combat selection state, so tokens picked to
  // attack (or block) split off into their own stack. Tokens with abilities or that are choice targets stay single.
  permanentStacks(permanents, mine) {
    const choiceIds = this.choiceTargetIds(this.state)
    const groups = new Map()
    permanents.forEach((p, i) => {
      const groupable = p.token && !this.activatableAbilities(p).length && !choiceIds.has(String(p.id)) && !this.attachments?.has(p.id)
      const key = groupable
        ? JSON.stringify([
            p.name, p.tapped, p.counters, p.power, p.toughness, p.damage, p.attacking, p.can_attack, p.can_block,
            this.attackers.has(p.id), this.attackTargets.get(p.id), this.blocker === p.id, this.blocks.get(p.id),
            [...this.blocks.values()].includes(p.id)
          ])
        : `single-${i}`
      if (!groups.has(key)) groups.set(key, [])
      groups.get(key).push(p)
    })
    return [...groups.values()].map((group) => {
      if (group.length === 1) return this.permanentCard(group[0], { mine })
      const stack = document.createElement("div")
      stack.className = "stack"
      const ids = group.map((p) => p.id).join(",")
      group.forEach((p) => {
        const el = this.permanentCard(p, { mine })
        if (el.dataset.role) el.dataset.group = ids
        stack.append(el)
      })
      const count = document.createElement("span")
      count.className = "stack-count"
      count.textContent = `×${group.length}`
      stack.append(count)
      return stack
    })
  }

  // Combat decorations and click roles for a non-land permanent.
  permanentCard(p, { mine }) {
    const classes = []
    let role = null
    if (p.attacking) classes.push("card--attacking")

    if (this.choiceTargetIds(this.state).has(String(p.id))) {
      role = "choice"
      classes.push("card--target")
    } else if (mine && p.can_attack) {
      role = "attacker"
      classes.push(this.attackers.has(p.id) ? "card--selected" : "card--playable")
    } else if (mine && p.can_block) {
      role = "blocker"
      if (this.blocker === p.id) classes.push("card--selected")
      else classes.push(this.blocks.has(p.id) ? "card--blocking" : "card--playable")
    } else if (!mine && p.planeswalker && this.state.can_act && this.state.turn.step === "declare_attackers" && this.attackers.size) {
      role = "planeswalker"
      classes.push([...this.attackTargets.values()].includes(p.id) ? "card--selected" : "card--playable")
    } else if (!mine && p.attacking && this.state.can_act && this.state.turn.step === "declare_blockers") {
      role = "target"
      classes.push("card--target")
      if ([...this.blocks.values()].includes(p.id)) classes.push("card--blocked")
    } else if (mine && this.activatableAbilities(p).length) {
      role = "ability"
      classes.push("card--playable")
    } else if (mine && (p.mana_colors || []).length) {
      role = "mana"
      classes.push("card--playable")
    } else if (mine && p.mana_refundable) {
      role = "unmana"
      classes.push("card--playable")
    }
    if (p.damage > 0) classes.push("card--damaged")
    const el = this.card(p.name, { tapped: p.tapped, classes, id: p.id, role })
    if (p.power !== null) el.append(...this.statsBadge(p))
    el.append(...this.counterBadges(p), ...this.manaPickerFor(p))
    const attached = this.attachments?.get(p.id) || []
    attached.forEach((a, i) => {
      const aura = this.permanentCard(a, { mine })
      aura.classList.add("card--attachment")
      aura.style.setProperty("--slot", i + 1)
      aura.title = `${a.name} (attached to ${p.name})`
      el.append(aura)
    })
    if (attached.length) {
      el.classList.add("card--hosting")
      el.style.setProperty("--attached", attached.length)
    }
    return el
  }

  // One chip per kind of counter, e.g. "3 quest" or "+1/+1 ×2", along the bottom-left of the card.
  counterBadges(p) {
    if (!p.counters?.length) return []
    const chips = document.createElement("div")
    chips.className = "counters"
    for (const counter of p.counters) {
      const chip = document.createElement("span")
      chip.className = "counter"
      chip.textContent = `${counter.count} ${counter.name}`
      chip.title = `${counter.count} ${counter.name} counter${counter.count === 1 ? "" : "s"}`
      chips.append(chip)
    }
    return [chips]
  }

  // Always-visible power/toughness (toughness shown net of damage), plus a damage marker when hurt.
  statsBadge(p) {
    const badge = document.createElement("div")
    badge.className = "stats"
    badge.textContent = `${p.power}/${p.toughness - p.damage}`
    badge.title = p.damage > 0 ? `${p.damage} damage marked (toughness ${p.toughness})` : "Power/toughness"
    if (p.damage === 0) return [badge]
    badge.classList.add("stats--damaged")

    const marker = document.createElement("div")
    marker.className = "damage-marker"
    marker.textContent = `−${p.damage}`
    return [badge, marker]
  }

  // Selections only make sense within the step they were made in.
  resetSelectionsOnNewStep(turn) {
    const key = `${turn.number}:${turn.step}`
    if (key === this.stepKey) return
    this.stepKey = key
    this.attackers = new Set()
    this.attackTargets = new Map()
    this.blocks = new Map()
    this.blocker = null
  }

  buttonLabel(state) {
    const { step } = state.turn
    if (state.choice) return "Waiting for a choice"
    if (state.over) return "Game over"
    if (state.priority) return "Pass"
    if (!state.can_act) return "Opponent's turn"
    if (step === "declare_attackers") return this.attackers.size ? `Attack with ${this.attackers.size}` : "No attack"
    if (step === "declare_blockers") return this.blocks.size ? `Confirm blocks (${this.blocks.size})` : "No blocks"
    if (step === "first_main") return "Go to combat"
    if (step === "second_main") return "End turn"
    return "Next step"
  }

  hint(state) {
    if (state.choice && !state.choice.chooser) return `Waiting for ${state.choice.chooser_name} to make a choice…`
    if (!state.can_act) return ""
    if (state.priority) {
      const top = state.stack[0]
      return `${top.controller} put ${top.name} on the stack. Respond, or pass.`
    }
    if (state.choice?.kind === "target") return state.choice.prompt
    if (state.choice) return ""
    if (state.turn.step === "declare_attackers") return "Select creatures to attack with."
    if (state.turn.step === "declare_blockers") {
      return this.blocker === null ? "Select one of your creatures to block with." : "Now select the attacker it blocks."
    }
    return ""
  }

  plate(player, { reveal }) {
    const frag = document.createDocumentFragment()
    const add = (cls, text) => {
      const span = document.createElement("span")
      span.className = cls
      span.textContent = text
      frag.append(span)
    }
    add("name", player.name)
    add("life", player.life)
    return frag
  }

  // The mana tapped by hand and not yet spent, as a tally of coloured chips under the player bar.
  renderManaPool(pool) {
    const chips = Object.entries(pool).map(([color, count]) => {
      const symbol = { white: "W", blue: "U", black: "B", red: "R", green: "G", colorless: "C" }[color]
      const chip = document.createElement("span")
      chip.className = "mana"
      chip.title = `${count} ${color} mana floating`
      if (symbol) {
        const icon = document.createElement("img")
        icon.className = "mana__icon"
        icon.alt = `{${symbol}}`
        icon.src = `https://svgs.scryfall.io/card-symbols/${symbol}.svg`
        chip.append(icon)
      } else {
        chip.append(color)
      }
      chip.append(`×${count}`)
      return chip
    })
    this.manaPoolTarget.replaceChildren(...chips)
    this.manaPoolTarget.hidden = chips.length === 0
  }

  static manaSymbols = { white: "W", blue: "U", black: "B", red: "R", green: "G", colorless: "C" }

  // Tap a source for mana: straight away when it makes one colour, else a colour picker opens over the card.
  clickMana(id) {
    const permanent = this.state.you.battlefield.find((p) => p.id === id)
    const colors = permanent?.mana_colors || []
    if (colors.length === 1) {
      this.subscription.perform("tap_for_mana", { id, color: colors[0] })
    } else if (colors.length > 1) {
      this.manaPicker = this.manaPicker?.id === id ? null : { id, colors }
      this.render(this.state)
    }
  }

  // The colour buttons floating over the card being tapped, when its picker is open.
  manaPickerFor(p) {
    if (this.manaPicker?.id !== p.id) return []
    const picker = document.createElement("div")
    picker.className = "mana-picker"
    for (const color of this.manaPicker.colors) {
      const button = document.createElement("button")
      button.className = "mana-picker__btn"
      button.title = `Add ${color}`
      const symbol = this.constructor.manaSymbols[color]
      if (symbol) {
        const icon = document.createElement("img")
        icon.className = "mana__icon"
        icon.alt = `{${symbol}}`
        icon.src = `https://svgs.scryfall.io/card-symbols/${symbol}.svg`
        button.append(icon)
      } else {
        button.textContent = color
      }
      button.addEventListener("click", (event) => {
        event.stopPropagation()
        this.manaPicker = null
        this.subscription.perform("tap_for_mana", { id: p.id, color })
      })
      picker.append(button)
    }
    return [picker]
  }

  // --- rendering -----------------------------------------------------------

  render(state) {
    this.errorTarget.textContent = state.error || ""
    if (state.error) return

    const canJoin = !state.seated && state.seat_count < 2
    this.joinTarget.hidden = !canJoin
    this.pickerTarget.hidden = !canJoin
    if (canJoin) {
      this.selectedDeck ||= state.decks.find((deck) => deck.name === state.deck)?.name || state.decks[0].name
      this.renderDeckPicker(state.decks)
    }
    this.boardTarget.classList.toggle("table--over", !!state.over)
    this.deckTarget.textContent = state.deck || ""
    this.concedeTarget.hidden =!state.seated || state.status !== "started" || !!state.over
    this.boardTarget.hidden = state.status !== "started"

    if (!state.seated && state.seat_count >= 2) {
      this.statusTarget.textContent = "This game is full."
    } else if (!state.seated) {
      this.statusTarget.textContent = `${state.seat_count}/2 players seated.`
    } else if (state.status === "waiting") {
      this.statusTarget.textContent = `You are ${state.you.name}. Waiting for an opponent… share this URL.`
    } else if (state.over) {
      this.statusTarget.textContent = state.winner ? `Game over — ${state.winner} wins!` : "Game over — it's a draw."
    } else {
      this.statusTarget.textContent = `You are ${state.you.name}.`
    }

    if (state.status !== "started" || !state.you) return

    const { turn, you, opponent } = state
    this.resetSelectionsOnNewStep(turn)
    this.turnTarget.textContent = `Turn ${turn.number} — ${turn.active}`
    this.stepsTarget.replaceChildren(...turn.steps.map((step) => {
      const li = document.createElement("li")
      li.textContent = step.replaceAll("_", " ")
      li.classList.toggle("current", step === turn.step)
      return li
    }))
    this.advanceTarget.disabled = !state.can_act || !!state.choice
    this.advanceTarget.textContent = this.buttonLabel(state)
    this.hintTarget.textContent = this.hint(state)
    this.renderStack(state.stack || [])
    this.renderChoice(state)
    this.markPlayerTargets(state)

    this.opponentTarget.replaceChildren(this.plate(opponent, { reveal: false }))
    this.youTarget.replaceChildren(this.plate(you, { reveal: true }))
    this.renderManaPool(you.mana_pool || {})
    this.opponentHandTarget.replaceChildren(...Array.from({ length: opponent.hand_size }, () => this.cardBack()))
    this.handTarget.replaceChildren(...you.hand.map((card, index) =>
      this.handCard(card, state, index)
    ))

    this.renderField(you.battlefield, this.yourLandsTarget, this.yourOtherTarget, { mine: true })
    this.renderField(opponent.battlefield, this.opponentLandsTarget, this.opponentOtherTarget, { mine: false })
    this.renderLog(state.log)
    this.renderLibrary(this.yourLibraryTarget, you, { mine: true })
    this.renderLibrary(this.opponentLibraryTarget, opponent, { mine: false })
    this.renderPile(this.yourGraveyardTarget, you.graveyard)
    this.renderPile(this.opponentGraveyardTarget, opponent.graveyard)
    this.renderExilePile(state.exile || [])
    this.renderViewer()
    this.hidePreview()
  }
}
