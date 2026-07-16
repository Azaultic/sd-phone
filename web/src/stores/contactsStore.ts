import { create } from 'zustand';
import { useShallow } from 'zustand/react/shallow';

import { loadPhoneState } from '@/apps/phone/contactsApi';
import type { CardOverrides } from '@/apps/phone/contactsApi';
import type { Contact, RawCall } from '@/apps/phone/data';

interface ContactsState {
    contacts:    Contact[];
    recents:     RawCall[];
    myNumber:    string;
    myName:      string;
    card:        CardOverrides;
    loaded:      boolean;
    setContacts: (next: Contact[] | ((prev: Contact[]) => Contact[])) => void;
    setCard:     (next: CardOverrides) => void;
    load:        () => Promise<void>;
    refresh:     () => Promise<void>;
}

let inFlight: Promise<void> | null = null;

function fetchAndCommit(): Promise<void> {
    if (!inFlight) {
        inFlight = loadPhoneState()
            .then(state => {
                useContactsStore.setState({
                    contacts: state.contacts,
                    recents:  state.recents,
                    myNumber: state.myNumber,
                    myName:   state.myName,
                    card:     state.card,
                    loaded:   true,
                });
            })
            .catch(() => {})
            .finally(() => { inFlight = null; });
    }
    return inFlight;
}

export const useContactsStore = create<ContactsState>((set, get) => ({
    contacts: [],
    recents:  [],
    myNumber: '',
    myName:   '',
    card:     {},
    loaded:   false,

    setContacts: (next) => set(s => ({ contacts: typeof next === 'function' ? next(s.contacts) : next })),
    setCard:     (next) => set({ card: next }),

    load:    () => (get().loaded ? Promise.resolve() : fetchAndCommit()),
    refresh: () => fetchAndCommit(),
}));

export function useContacts(): ContactsState;
export function useContacts<K extends keyof ContactsState>(...keys: K[]): Pick<ContactsState, K>;
export function useContacts(...keys: (keyof ContactsState)[]): unknown {
    return useContactsStore(
        useShallow((s: ContactsState) => {
            if (keys.length === 0) return s;
            const out: Record<string, unknown> = {};
            for (const k of keys) out[k] = s[k];
            return out;
        }),
    );
}
