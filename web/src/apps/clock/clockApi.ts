import { fetchNui, isFiveM } from '@/core/nui';
import { DEFAULT_ALARMS, TIMER_PRESETS, type AlarmDef } from './data';
import type { Envelope } from '@/core/api';

const RECENTS_CAP = 8;

let devAlarms:  AlarmDef[] = [...DEFAULT_ALARMS];
let devRecents: number[]   = TIMER_PRESETS.map(p => p.seconds);


export async function getAlarms(): Promise<AlarmDef[]> {
    if (!isFiveM) return [...devAlarms];
    const res = await fetchNui<Envelope<{ alarms: AlarmDef[] }>>('sd-phone:clock:alarms:list');
    return res?.data?.alarms ?? [];
}

export async function saveAlarm(a: AlarmDef): Promise<void> {
    if (!isFiveM) {
        devAlarms = devAlarms.some(x => x.id === a.id) ? devAlarms.map(x => (x.id === a.id ? a : x)) : [...devAlarms, a];
        return;
    }
    await fetchNui('sd-phone:clock:alarms:save', a);
}

export async function deleteAlarm(id: string): Promise<void> {
    if (!isFiveM) { devAlarms = devAlarms.filter(x => x.id !== id); return; }
    await fetchNui('sd-phone:clock:alarms:delete', { id });
}


export async function getRecents(): Promise<number[]> {
    if (!isFiveM) return [...devRecents];
    const res = await fetchNui<Envelope<{ recents: number[] }>>('sd-phone:clock:recents:list');
    return res?.data?.recents ?? [];
}

export async function addRecent(seconds: number): Promise<void> {
    if (!isFiveM) {
        devRecents = [seconds, ...devRecents.filter(s => s !== seconds)].slice(0, RECENTS_CAP);
        return;
    }
    await fetchNui('sd-phone:clock:recents:add', { seconds });
}
