import { create } from 'zustand';

// Cross-app deep links ("open Maps at this waypoint", "message this number").
// Zustand-backed mailbox: requestOpenX stores a take-once target and bumps a
// nonce; App.tsx subscribes via onOpenX to switch apps, and the target app
// consumes the payload with takeXTarget on mount. The exported function API
// is kept stable so the many requestOpenX call sites never change.

export interface MapsTarget {
    label: string;
    x:     number;
    y:     number;
    icon?: string;
    color?: string;
    companyId?: string;
}

export interface MessagesTarget {
    number: string;
    name?:  string;
}

export interface MailTarget {
    to: string;
}

interface DeeplinkState {
    mapsNonce:      number;
    mapsTarget:     MapsTarget | null;
    messagesNonce:  number;
    messagesTarget: MessagesTarget | null;
    mailNonce:      number;
    mailTarget:     MailTarget | null;
}

const useDeeplinkStore = create<DeeplinkState>(() => ({
    mapsNonce: 0,     mapsTarget: null,
    messagesNonce: 0, messagesTarget: null,
    mailNonce: 0,     mailTarget: null,
}));

export function requestOpenMaps(target?: MapsTarget | null): void {
    useDeeplinkStore.setState(s => ({ mapsTarget: target ?? null, mapsNonce: s.mapsNonce + 1 }));
}

export function takeMapsTarget(): MapsTarget | null {
    const t = useDeeplinkStore.getState().mapsTarget;
    useDeeplinkStore.setState({ mapsTarget: null });
    return t;
}

export function onOpenMaps(handler: () => void): () => void {
    return useDeeplinkStore.subscribe((s, prev) => { if (s.mapsNonce !== prev.mapsNonce) handler(); });
}

export function requestOpenMessages(target: MessagesTarget): void {
    useDeeplinkStore.setState(s => ({ messagesTarget: target, messagesNonce: s.messagesNonce + 1 }));
}

export function peekMessagesTarget(): MessagesTarget | null {
    return useDeeplinkStore.getState().messagesTarget;
}

export function clearMessagesTarget(): void {
    useDeeplinkStore.setState({ messagesTarget: null });
}

export function onOpenMessages(handler: () => void): () => void {
    return useDeeplinkStore.subscribe((s, prev) => { if (s.messagesNonce !== prev.messagesNonce) handler(); });
}

export function requestOpenMail(target: MailTarget): void {
    useDeeplinkStore.setState(s => ({ mailTarget: target, mailNonce: s.mailNonce + 1 }));
}

export function takeMailTarget(): MailTarget | null {
    const t = useDeeplinkStore.getState().mailTarget;
    useDeeplinkStore.setState({ mailTarget: null });
    return t;
}

export function onOpenMail(handler: () => void): () => void {
    return useDeeplinkStore.subscribe((s, prev) => { if (s.mailNonce !== prev.mailNonce) handler(); });
}
