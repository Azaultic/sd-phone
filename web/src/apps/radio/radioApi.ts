import { fetchNui, isFiveM } from '@/core/nui';
import { apiCall, apiData, type Envelope } from '@/core/api';

export interface RadioState {
    on:     boolean;
    freq:   number;
    volume: number;
}

const DEV: RadioState = { on: false, freq: 1.0, volume: 50 };

export async function getRadio(): Promise<RadioState> {
    if (!isFiveM) return { ...DEV };
    return (await apiData<RadioState>('sd-phone:radio:get')) ?? { ...DEV };
}

export async function setRadio(patch: Partial<RadioState>): Promise<RadioState & { error?: string }> {
    if (!isFiveM) { Object.assign(DEV, patch); return { ...DEV }; }
    const res = await fetchNui<Envelope<RadioState> & { denied?: boolean; message?: string }>('sd-phone:radio:set', patch);
    if (res?.data) return { ...res.data, error: res.denied ? res.message : undefined };
    return { ...DEV, ...patch };
}

export interface SavedStation { id: string; label: string; freq: number }

let DEV_SAVED: SavedStation[] = [
    { id: 'd1', label: 'Crew',     freq: 101.5 },
    { id: 'd2', label: 'Dispatch', freq: 5.0 },
];
let devSavedSeq = 100;

export async function listSaved(): Promise<SavedStation[]> {
    if (!isFiveM) return [...DEV_SAVED];
    return (await apiData<{ saved: SavedStation[] }>('sd-phone:radio:saved:list'))?.saved ?? [];
}

export async function addSaved(label: string, freq: number): Promise<SavedStation | null> {
    if (!isFiveM) {
        const s: SavedStation = { id: 'd' + ++devSavedSeq, label, freq };
        DEV_SAVED = [...DEV_SAVED, s];
        return s;
    }
    return await apiData<SavedStation>('sd-phone:radio:saved:add', { label, freq });
}

export async function updateSaved(id: string, label: string, freq: number): Promise<SavedStation | null> {
    if (!isFiveM) {
        DEV_SAVED = DEV_SAVED.map(s => (s.id === id ? { ...s, label, freq } : s));
        return DEV_SAVED.find(s => s.id === id) ?? null;
    }
    return await apiData<SavedStation>('sd-phone:radio:saved:update', { id, label, freq });
}

export async function removeSaved(id: string): Promise<boolean> {
    if (!isFiveM) { DEV_SAVED = DEV_SAVED.filter(s => s.id !== id); return true; }
    const res = await apiCall<{ id: string }>('sd-phone:radio:saved:remove', { id });
    return res.success;
}
