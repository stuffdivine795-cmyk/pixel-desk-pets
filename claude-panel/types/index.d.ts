export type Mood = 'idle' | 'thinking' | 'working' | 'done' | 'error' | 'sleeping'

export type Outfit = 'none' | 'witch' | 'party' | 'crown' | 'headphones' | 'santa' | 'grad' | 'flower'

export type Pet = {
  mood: Mood
  // The tool being run, or why things went wrong
  detail: string
  line: string
  // Bumped on every poke, so the drawing plays a trick
  pokes: number
  outfit: Outfit
  // Which of the mood's acts is playing; rotates every few seconds
  act: number
}

// One plan window as the last API response reported it
export type QuotaWindow = { used: number; resetsAt?: string }

export type Quota = { five_hour?: QuotaWindow; seven_day?: QuotaWindow }

declare module 'claude-code' {
  interface PluginState {
    'slime-pet': { pet: Shaped<Pet>; quota: Quota }
  }
}
