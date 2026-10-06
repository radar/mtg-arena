// Resolves a card name to a Scryfall image URL. Requests are queued ~100ms apart (Scryfall's
// rate-limit guidance), and results are cached in memory and localStorage so each name is fetched once.
const DELAY_MS = 100
const STORAGE_KEY = "arena.scryfall.v1"

const memory = new Map(readStorage())
const pending = new Map()
let queue = Promise.resolve()

function readStorage() {
  try {
    return Object.entries(JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}"))
  } catch {
    return []
  }
}

function writeStorage() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(Object.fromEntries(memory)))
  } catch {
    // Storage unavailable or full: the in-memory cache still works.
  }
}

function lookup(name) {
  return queue = queue.then(async () => {
    await new Promise((resolve) => setTimeout(resolve, DELAY_MS))
    const response = await fetch(`https://api.scryfall.com/cards/named?exact=${encodeURIComponent(name)}`, {
      headers: { Accept: "application/json" }
    })
    if (!response.ok) throw new Error(`Scryfall ${response.status} for ${name}`)
    const card = await response.json()
    const faces = card.image_uris || card.card_faces?.[0]?.image_uris
    return { normal: faces.normal, large: faces.large, art: faces.art_crop }
  })
}

export function cardImages(name) {
  if (memory.has(name)) return Promise.resolve(memory.get(name))
  if (!pending.has(name)) {
    pending.set(name, lookup(name).then((images) => {
      memory.set(name, images)
      writeStorage()
      return images
    }).finally(() => pending.delete(name)))
  }
  return pending.get(name)
}
