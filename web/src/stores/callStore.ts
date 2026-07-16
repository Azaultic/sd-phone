import { create } from 'zustand';


type Phase = 'incoming' | 'outgoing' | 'active';

interface CallInfo { channel: number; name?: string; number: string }
interface CurrentCall { channel: number; phase: Phase; name?: string; number: string; elapsed: number }

interface CallState {
    phase:     Phase | null;
    channel:   number | null;
    name:      string;
    number:    string;
    startedAt: number | null;
    incoming:  (d: CallInfo) => void;
    outgoing:  (d: CallInfo) => void;
    connected: (d: { channel: number }) => void;
    ended:     () => void;
    hydrate:   (cur: CurrentCall) => void;
}

const RESET = { phase: null, channel: null, name: '', number: '', startedAt: null } as const;

export const useCallStore = create<CallState>((set, get) => ({
    ...RESET,
    incoming:  (d) => set({ phase: 'incoming', channel: d.channel, name: d.name ?? '', number: d.number, startedAt: null }),
    outgoing:  (d) => set({ phase: 'outgoing', channel: d.channel, name: d.name ?? '', number: d.number, startedAt: null }),
    connected: (d) => { if (get().channel === d.channel) set({ phase: 'active', startedAt: Date.now() }); },
    ended:     () => set({ ...RESET }),
    hydrate:   (cur) => set({
        phase:     cur.phase,
        channel:   cur.channel,
        name:      cur.name ?? '',
        number:    cur.number,
        startedAt: cur.phase === 'active' ? Date.now() - cur.elapsed * 1000 : null,
    }),
}));
