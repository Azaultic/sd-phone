// Bridge between the AppSwitcher (which owns card geometry + gestures) and the
// AppDeck (which owns the single live app instances). The switcher renders an
// empty "stage" node per card and registers its DOM element here; the deck moves
// the matching retained app's host element INTO that stage via appendChild, so the
// live app view inherits the card's transform (position/scale/drag/eject) for free
// with zero per-frame React sync. This is what keeps single-mount intact: the app
// is instantiated only in the deck and merely re-parented, never rendered twice.

type Listener = () => void;

const cardStages = new Map<string, HTMLElement>();
const listeners  = new Set<Listener>();

// The single fullscreen slot the (now top-level, keep-alive) deck re-parents the
// active app into. It lives INSIDE the open phone screen and is registered the same
// way the switcher registers its card stages, so the deck can move the one live app
// instance into the phone while the phone is open and drop it to the hidden pool the
// moment the phone holsters - all without the deck itself ever unmounting.
let fullscreenStage: HTMLElement | null = null;

export function registerCardStage(id: string, el: HTMLElement | null): void {
    if (el) cardStages.set(id, el);
    else    cardStages.delete(id);
    for (const fn of listeners) fn();
}

export function getCardStage(id: string): HTMLElement | undefined {
    return cardStages.get(id);
}

export function registerFullscreenStage(el: HTMLElement | null): void {
    fullscreenStage = el;
    for (const fn of listeners) fn();
}

export function getFullscreenStage(): HTMLElement | null {
    return fullscreenStage;
}

export function subscribeCardStages(fn: Listener): () => void {
    listeners.add(fn);
    return () => { listeners.delete(fn); };
}
