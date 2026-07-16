import { fetchNui, isFiveM } from '@/core/nui';
import { apiData } from '@/core/api';
import { readJson, writeJson } from '@/lib/storage';

const DEV_KEY = 'sd-phone:installed-apps';

function devRead(): string[] {
    return readJson<string[]>(DEV_KEY) ?? [];
}
function devWrite(ids: string[]): void {
    writeJson(DEV_KEY, ids);
}

export async function listInstalledApps(): Promise<string[]> {
    if (!isFiveM) return devRead();
    return (await apiData<{ installed: string[] }>('sd-phone:apps:list'))?.installed ?? [];
}

export async function installApp(id: string): Promise<string[]> {
    if (!isFiveM) { const ids = [...new Set([...devRead(), id])]; devWrite(ids); return ids; }
    const r = await apiData<{ installed: string[] }>('sd-phone:apps:install', { id });
    return r ? r.installed : listInstalledApps();
}

export async function uninstallApp(id: string): Promise<string[]> {
    if (!isFiveM) { const ids = devRead().filter(x => x !== id); devWrite(ids); return ids; }
    const r = await apiData<{ installed: string[] }>('sd-phone:apps:uninstall', { id });
    return r ? r.installed : listInstalledApps();
}

const LAYOUT_KEY = 'sd-phone:home-layout';

interface FolderDef { key: string; name: string; appIds: string[] }
export interface SavedLayout { slots: (string | null)[]; folders: FolderDef[] }

export function parseLayout(raw: string | null | undefined): SavedLayout | null {
    if (!raw) return null;
    try {
        const v = JSON.parse(raw) as unknown;
        if (Array.isArray(v)) return { slots: v as (string | null)[], folders: [] };
        if (v && typeof v === 'object' && Array.isArray((v as SavedLayout).slots)) {
            const o = v as SavedLayout;
            return { slots: o.slots, folders: Array.isArray(o.folders) ? o.folders : [] };
        }
    } catch { /* ignore */ }
    return null;
}

export function loadHomeLayout(): SavedLayout | null {
    if (isFiveM) return null;
    try { return parseLayout(window.localStorage.getItem(LAYOUT_KEY)); } catch { return null; }
}

export function saveHomeLayout(layout: SavedLayout): void {
    if (!isFiveM) { writeJson(LAYOUT_KEY, layout); return; }
    void fetchNui('sd-phone:apps:saveLayout', { layout: JSON.stringify(layout) });
}
