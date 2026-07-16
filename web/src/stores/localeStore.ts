import { create } from 'zustand';

import { fetchNui, isFiveM } from '@/core/nui';
import { getLocale, setLocale as applyLocale, SUPPORTED_LOCALES } from '@/i18n';
import type { LocaleOption } from '@/i18n';

export type { LocaleOption };
export { SUPPORTED_LOCALES };

const LOCALE_KEY = 'sd-phone:locale';
function loadLocal(): string | null {
    try { return window.localStorage.getItem(LOCALE_KEY); } catch { return null; }
}
function saveLocal(code: string) {
    try { window.localStorage.setItem(LOCALE_KEY, code); } catch { /* ignore */ }
}

interface LocaleState {
    locale: string;
    initialized: boolean;
    /** Player explicitly picked a language (Setup or Settings) — applies, persists, and wins from now on. */
    setLocale: (code: string) => void;
    /** Server's config.Locale, pushed on every `sd-phone:open`. Only used before the player has a locale of their own. */
    applyServerDefault: (code: string) => void;
    /** Loads the player's previously saved locale, if any. */
    hydrate: () => void;
}

export const useLocaleStore = create<LocaleState>((set, get) => ({
    locale: getLocale(),
    initialized: false,

    setLocale: (code) => {
        set({ initialized: true });
        void applyLocale(code).then(() => set({ locale: getLocale() }));
        if (isFiveM) void fetchNui('sd-phone:settings:setLocale', { locale: code }).catch(() => {});
        else saveLocal(code);
    },

    applyServerDefault: (code) => {
        if (get().initialized) return;
        set({ initialized: true });
        void applyLocale(code).then(() => set({ locale: getLocale() }));
    },

    hydrate: () => {
        if (isFiveM) {
            void fetchNui<{ data?: { locale?: string } }>('sd-phone:settings:get')
                .then(res => {
                    const code = res?.data?.locale;
                    if (code) {
                        set({ initialized: true });
                        void applyLocale(code).then(() => set({ locale: getLocale() }));
                    }
                })
                .catch(() => {});
        } else {
            const code = loadLocal();
            if (code) {
                set({ initialized: true });
                void applyLocale(code).then(() => set({ locale: getLocale() }));
            }
        }
    },
}));
