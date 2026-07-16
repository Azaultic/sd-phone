import { useEffect } from 'react';
import type { ReactNode } from 'react';
import { create } from 'zustand';
import { useShallow } from 'zustand/react/shallow';

import lockscreenAsset from '@/assets/wallpapers/lockscreen.webp';
import devDefaultAsset from '@/assets/photos/background5.webp';
import { fetchNui, isFiveM } from '@/core/nui';
import { wallpaperKey } from '@/shell/wallpapers';
import { DEFAULT_LOCK_CLOCK, loadLockClockLocal, saveLockClockLocal, type LockClock } from '@/shell/lockClock';
import { DEFAULT_NOTIFICATION, DEFAULT_RINGTONE } from '@/apps/settings/tones';
import type { CustomTone, ToneKind } from '@/apps/settings/tones';
import { warmYouTube } from '@/apps/settings/tonePlayer';

export type Theme = 'light' | 'dark';

interface Security { passcode: string | null; faceId: boolean }
const SECURITY_KEY = 'sd-phone:security';
function loadSecurityLocal(): Security {
    try {
        const raw = window.localStorage.getItem(SECURITY_KEY);
        if (raw) {
            const p = JSON.parse(raw) as Security;
            return { passcode: typeof p.passcode === 'string' ? p.passcode : null, faceId: !!p.faceId };
        }
    } catch { /* ignore */ }
    return { passcode: '1234', faceId: false };
}
function saveSecurityLocal(s: Security) {
    try { window.localStorage.setItem(SECURITY_KEY, JSON.stringify(s)); } catch { /* ignore */ }
}

// hydrate() reads every persisted setting in one settings:get. On first join the phone NUI mounts
// before the framework finishes loading the character, so that call can't resolve the citizenid and
// comes back empty; without a retry the phone would keep its defaults (wallpaper, lock clock, tones,
// passcode...) until the resource is restarted. Retry a bounded number of times, spaced out, so the
// real settings land on their own within seconds of joining.
const HYDRATE_RETRY_MS = 1500;
const HYDRATE_MAX_RETRIES = 20;

const WALLPAPER_KEY = 'sd-phone:wallpaper';
function loadWallpaperLocal(): string | null {
    try { return window.localStorage.getItem(WALLPAPER_KEY); } catch { return null; }
}
function saveWallpaperLocal(v: string) {
    try { window.localStorage.setItem(WALLPAPER_KEY, v); } catch { /* ignore */ }
}

const CHAT_SCALE_KEY = 'sd-phone:chatTextScale';
const clampChatScale = (n: number) => Math.min(1.5, Math.max(0.8, n));
function loadChatScaleLocal(): number {
    try {
        const n = parseFloat(window.localStorage.getItem(CHAT_SCALE_KEY) ?? '');
        return Number.isFinite(n) ? clampChatScale(n) : 1;
    } catch { return 1; }
}
function saveChatScaleLocal(v: number) {
    try { window.localStorage.setItem(CHAT_SCALE_KEY, String(v)); } catch { /* ignore */ }
}

export type PhoneAlign =
    | 'top-left'    | 'top-center'    | 'top-right'
    | 'middle-left' | 'middle-center' | 'middle-right'
    | 'bottom-left' | 'bottom-center' | 'bottom-right';

interface ThemeState {
    theme:             Theme;
    setTheme:          (t: Theme) => void;
    wallpaper:         string;
    setWallpaper:      (url: string) => void;
    blurHomescreen:    boolean;
    setBlurHomescreen: (v: boolean) => void;
    brightness:        number;
    setBrightness:     (v: number) => void;
    phoneScale:        number;
    setPhoneScale:     (v: number) => void;
    chatTextScale:     number;
    setChatTextScale:  (v: number) => void;
    phoneAlign:        PhoneAlign;
    setPhoneAlign:     (v: PhoneAlign) => void;
    ringtoneVol:       number;
    setRingtoneVol:    (v: number) => void;
    callVol:           number;
    setCallVol:        (v: number) => void;
    airplaneMode:      boolean;
    setAirplaneMode:   (on: boolean) => void;
    hour24:            boolean;
    setHour24:         (on: boolean) => void;
    ringtone:            string;
    setRingtone:         (id: string) => void;
    notificationTone:    string;
    setNotificationTone: (id: string) => void;
    customRingtones:         CustomTone[];
    customNotificationTones: CustomTone[];
    addCustomTone:    (kind: ToneKind, name: string, url: string) => string;
    removeCustomTone: (kind: ToneKind, id: string) => void;
    statusLightOverride:    boolean | null;
    setStatusLightOverride: (v: boolean | null) => void;
    hideHomeIndicator:    boolean;
    setHideHomeIndicator: (v: boolean) => void;
    lockClock:    LockClock;
    setLockClock: (cfg: LockClock) => void;
    passcode:    string | null;
    setPasscode: (pin: string | null) => void;
    faceId:      boolean;
    setFaceId:   (on: boolean) => void;
    setSecurity: (pin: string | null, faceId: boolean) => void;
    hydrate: (attempt?: number) => void;
}

const initialSecurity = isFiveM ? { passcode: null, faceId: false } : loadSecurityLocal();

function persistSecurity(pin: string | null, face: boolean) {
    if (isFiveM) void fetchNui('sd-phone:settings:setSecurity', { passcode: pin, faceId: face }).catch(() => {});
    else saveSecurityLocal({ passcode: pin, faceId: face });
}

export const useThemeStore = create<ThemeState>((set, get) => ({
    theme: 'light',
    wallpaper: isFiveM ? lockscreenAsset : (loadWallpaperLocal() ?? devDefaultAsset),
    blurHomescreen: false,
    brightness: 100,
    phoneScale: 50,
    chatTextScale: isFiveM ? 1 : loadChatScaleLocal(),
    phoneAlign: 'bottom-right',
    ringtoneVol: 40,
    callVol: 45,
    airplaneMode: false,
    hour24: false,
    ringtone: DEFAULT_RINGTONE,
    notificationTone: DEFAULT_NOTIFICATION,
    customRingtones: [],
    customNotificationTones: [],
    statusLightOverride: null,
    hideHomeIndicator: false,
    lockClock: isFiveM ? DEFAULT_LOCK_CLOCK : loadLockClockLocal(),
    passcode: initialSecurity.passcode,
    faceId: initialSecurity.faceId,

    setTheme: (next) => {
        if (typeof document === 'undefined') { set({ theme: next }); return; }
        document.documentElement.classList.add('theme-transitioning');
        requestAnimationFrame(() => {
            set({ theme: next });
            window.setTimeout(() => {
                document.documentElement.classList.remove('theme-transitioning');
            }, 340);
        });
    },

    setWallpaper: (value) => {
        set({ wallpaper: value });
        const key = wallpaperKey(value);
        if (isFiveM) void fetchNui('sd-phone:settings:setWallpaper', { wallpaper: key }).catch(() => {});
        else saveWallpaperLocal(key);
    },

    setBlurHomescreen: (v) => set({ blurHomescreen: v }),
    setBrightness:     (v) => set({ brightness: v }),
    setPhoneScale:     (v) => set({ phoneScale: v }),
    setPhoneAlign:     (v) => set({ phoneAlign: v }),
    setRingtoneVol:    (v) => set({ ringtoneVol: v }),
    setCallVol:        (v) => set({ callVol: v }),

    setChatTextScale: (v) => {
        const next = clampChatScale(v);
        set({ chatTextScale: next });
        if (isFiveM) void fetchNui('sd-phone:settings:setChatTextScale', { scale: next }).catch(() => {});
        else saveChatScaleLocal(next);
    },

    setAirplaneMode: (on) => {
        set({ airplaneMode: on });
        void fetchNui('sd-phone:settings:setAirplane', { on }).catch(() => {});
    },

    setHour24: (on) => {
        set({ hour24: on });
        void fetchNui('sd-phone:settings:setHour24', { on }).catch(() => {});
    },

    setRingtone: (id) => {
        set({ ringtone: id });
        void fetchNui('sd-phone:settings:setTones', { ringtone: id, notificationTone: get().notificationTone }).catch(() => {});
    },

    setNotificationTone: (id) => {
        set({ notificationTone: id });
        void fetchNui('sd-phone:settings:setTones', { ringtone: get().ringtone, notificationTone: id }).catch(() => {});
    },

    addCustomTone: (kind, name, url) => {
        const item: CustomTone = { id: (kind === 'ringtone' ? 'c-' : 'cn-') + Math.random().toString(36).slice(2, 10), name, url };
        if (kind === 'ringtone') set(s => ({ customRingtones: [...s.customRingtones, item] }));
        else                     set(s => ({ customNotificationTones: [...s.customNotificationTones, item] }));
        warmYouTube();
        void fetchNui('sd-phone:settings:tones:add', { kind, ...item }).catch(() => {});
        return item.id;
    },

    removeCustomTone: (kind, id) => {
        if (kind === 'ringtone') {
            set(s => ({ customRingtones: s.customRingtones.filter(c => c.id !== id) }));
            if (get().ringtone === id) get().setRingtone(DEFAULT_RINGTONE);
        } else {
            set(s => ({ customNotificationTones: s.customNotificationTones.filter(c => c.id !== id) }));
            if (get().notificationTone === id) get().setNotificationTone(DEFAULT_NOTIFICATION);
        }
        void fetchNui('sd-phone:settings:tones:remove', { kind, id }).catch(() => {});
    },

    setStatusLightOverride: (v) => set({ statusLightOverride: v }),
    setHideHomeIndicator:   (v) => set({ hideHomeIndicator: v }),

    setLockClock: (cfg) => {
        set({ lockClock: cfg });
        if (isFiveM) void fetchNui('sd-phone:settings:setLockClock', cfg).catch(() => {});
        else saveLockClockLocal(cfg);
    },

    setPasscode: (pin) => {
        const face = pin === null ? false : get().faceId;
        set({ passcode: pin, faceId: pin === null ? false : get().faceId });
        persistSecurity(pin, face);
    },
    setFaceId: (on) => {
        const next = get().passcode === null ? false : on;
        set({ faceId: next });
        persistSecurity(get().passcode, next);
    },
    setSecurity: (pin, face) => {
        const finalFace = pin === null ? false : face;
        set({ passcode: pin, faceId: finalFace });
        persistSecurity(pin, finalFace);
    },

    hydrate: (attempt = 0) => {
        // In-game only: on first join the character may not be loaded yet, so settings:get returns
        // no data. Reschedule until it does (or we hit the cap). In dev there is no server, so no
        // retry - the store already seeded itself from localStorage.
        const retry = () => {
            if (isFiveM && attempt < HYDRATE_MAX_RETRIES) {
                window.setTimeout(() => get().hydrate(attempt + 1), HYDRATE_RETRY_MS);
            }
        };
        void fetchNui<{ data?: { ringtone?: string; notificationTone?: string; customRingtones?: CustomTone[]; customNotificationTones?: CustomTone[]; airplaneMode?: boolean; hour24?: boolean; lockClock?: Partial<LockClock>; passcode?: string | null; faceId?: boolean; wallpaper?: string; chatTextScale?: number } }>('sd-phone:settings:get')
            .then(res => {
                if (!res?.data) { retry(); return; }
                const d = res.data;
                const patch: Partial<ThemeState> = {};
                if (typeof d.wallpaper === 'string' && d.wallpaper) patch.wallpaper = wallpaperKey(d.wallpaper);
                if (d.ringtone)         patch.ringtone = d.ringtone;
                if (d.notificationTone) patch.notificationTone = d.notificationTone;
                if (typeof d.airplaneMode === 'boolean') patch.airplaneMode = d.airplaneMode;
                if (typeof d.hour24 === 'boolean') patch.hour24 = d.hour24;
                if (typeof d.chatTextScale === 'number') patch.chatTextScale = clampChatScale(d.chatTextScale);
                if (d.lockClock && typeof d.lockClock === 'object') patch.lockClock = { ...DEFAULT_LOCK_CLOCK, ...d.lockClock };
                const pin = typeof d.passcode === 'string' && d.passcode ? d.passcode : null;
                patch.passcode = pin;
                patch.faceId   = pin !== null && !!d.faceId;
                const ring  = Array.isArray(d.customRingtones)         ? d.customRingtones         : [];
                const notif = Array.isArray(d.customNotificationTones) ? d.customNotificationTones : [];
                patch.customRingtones         = ring;
                patch.customNotificationTones = notif;
                set(patch);
                const ringIsYt  = !!d.ringtone         && ring.some(c => c.id === d.ringtone);
                const notifIsYt = !!d.notificationTone && notif.some(c => c.id === d.notificationTone);
                if (ringIsYt || notifIsYt) warmYouTube();
            })
            .catch(retry);
    },
}));

export function useTheme(): ThemeState;
export function useTheme<K extends keyof ThemeState>(...keys: K[]): Pick<ThemeState, K>;
// Pick-style subscription: consumers name the fields they render, and only
// changes to THOSE fields re-render them (shallow compare on the picked
// object; store actions are stable references so naming them is free). The
// zero-arg form subscribes to the whole store — avoid it in components.
export function useTheme(...keys: (keyof ThemeState)[]): unknown {
    return useThemeStore(
        useShallow((s: ThemeState) => {
            if (keys.length === 0) return s;
            const out: Record<string, unknown> = {};
            for (const k of keys) out[k] = s[k];
            return out;
        }),
    );
}

export function ThemeProvider({ children }: { children: ReactNode }) {
    const chatTextScale = useThemeStore(s => s.chatTextScale);
    useEffect(() => { useThemeStore.getState().hydrate(); }, []);
    useEffect(() => {
        document.documentElement.style.setProperty('--chat-text-scale', String(chatTextScale));
    }, [chatTextScale]);
    return <>{children}</>;
}
