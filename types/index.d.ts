// A capture waiting in the prompt box, as the preview card above it shows it.
export type Attached = {
  id: string
  app: string
  title?: string
  png?: string
  txt: string
  chars: number
  // The thumbnail as a JPEG data URI, for the card.
  thumb?: string
  thumbWidth?: number
  thumbHeight?: number
}

declare module 'claude-code' {
  interface PluginState {
    appshot: { attached: Shaped<Attached[]> }
  }
}
