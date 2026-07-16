import { createContext, useContext } from 'react';

// One boolean, plumbed down each retained app's subtree by AppDeck: true only for
// the single instance that is the interactive fullscreen app (switcher closed and
// id === activeId). It is false for an app sitting in a switcher card, in the hidden
// pool, or kept fullscreen behind the switcher blur. Apps read it via useDeckActive()
// and fold it into their loop / poll / render / media effects so a backgrounded app
// freezes its last frame at ~0 CPU and re-syncs the instant it is foregrounded again.
//
// Default true so any mount OUTSIDE the deck (unit tests, standalone dev) is never
// treated as suspended. Kept in its own module (not AppDeck.tsx) so app-side hooks can
// import it without pulling the deck/registry back in through a cycle.
const DeckActiveContext = createContext(true);

export const DeckActiveProvider = DeckActiveContext.Provider;

export function useDeckActive(): boolean {
    return useContext(DeckActiveContext);
}
