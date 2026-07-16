
import { isFiveM } from '@/core/nui';
import { apiCall } from '@/core/api';
import { readJson } from '@/lib/storage';
import { newId as libNewId } from '@/lib/format';

export interface Track {
    id:     string;
    title:  string;
    artist: string;
    album?: string;
    url:    string;
    addedAt: number;
}

const STORE_KEY = 'sd-phone:music:v1';

export function newId(): string {
    return libNewId('t');
}

export function youtubeId(url: string): string | null {
    const m = url.match(
        /(?:youtube\.com\/(?:watch\?(?:.*&)?v=|embed\/|shorts\/|live\/)|youtu\.be\/|music\.youtube\.com\/watch\?(?:.*&)?v=)([A-Za-z0-9_-]{11})/,
    );
    return m ? m[1] : null;
}

export function isYouTube(url: string): boolean {
    return youtubeId(url) !== null;
}

export async function fetchYouTubeMeta(url: string): Promise<{ title: string; artist: string }> {
    try {
        const r = await fetch(`https://www.youtube.com/oembed?url=${encodeURIComponent(url)}&format=json`);
        if (r.ok) {
            const j = await r.json() as { title?: string; author_name?: string };
            return { title: j.title || 'YouTube video', artist: j.author_name || 'YouTube' };
        }
    } catch { /* ignore */ }
    return { title: 'YouTube video', artist: 'YouTube' };
}

export { formatDuration as fmt } from '@/lib/time';

const PALETTE: [string, string][] = [
    ['#1DB954', '#0a3d20'], ['#e8455f', '#3d0a14'], ['#0a84ff', '#0a1f3d'],
    ['#ff9f0a', '#3d2a0a'], ['#bf5af2', '#2a0a3d'], ['#64d2ff', '#0a2a3d'],
    ['#ff375f', '#3d0a1e'], ['#30d158', '#0a3d1e'], ['#ffd60a', '#3d3a0a'],
    ['#5e5ce6', '#16153d'],
];
export function coverGradient(seed: string): string {
    let h = 0;
    for (let i = 0; i < seed.length; i++) h = (h * 31 + seed.charCodeAt(i)) | 0;
    const [a, b] = PALETTE[Math.abs(h) % PALETTE.length];
    return `linear-gradient(135deg, ${a}, ${b})`;
}

function hexToRgb(hex: string): [number, number, number] {
    const h = hex.replace('#', '');
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
}

export function coverColor(seed: string): [number, number, number] {
    let h = 0;
    for (let i = 0; i < seed.length; i++) h = (h * 31 + seed.charCodeAt(i)) | 0;
    return hexToRgb(PALETTE[Math.abs(h) % PALETTE.length][0]);
}

export function titleFromUrl(url: string): string {
    try {
        const path = new URL(url).pathname.split('/').pop() || 'Track';
        return decodeURIComponent(path.replace(/\.[a-z0-9]+$/i, '')).replace(/[-_]+/g, ' ').trim() || 'Track';
    } catch {
        return 'Track';
    }
}

export function loadTracks(): Track[] {
    const raw = readJson<Track[]>(STORE_KEY, Array.isArray);
    return raw ? raw.filter(t => !/soundhelix\.com/i.test(t.url)) : DEFAULT_TRACKS;
}



export interface Folder {
    id:       string;
    name:     string;
    trackIds: string[];
    cover?:   string;
}

const FOLDERS_KEY = 'sd-phone:music:folders:v1';

export function loadFolders(): Folder[] {
    const raw = readJson<Folder[]>(FOLDERS_KEY, Array.isArray);
    return raw ? raw.filter(f => f.id !== 'f-chill' && f.id !== 'f-drive') : DEFAULT_FOLDERS;
}



export type IncomingTrack = Partial<Track> & { url: string };

export async function shareTrack(track: Track, target: number): Promise<boolean> {
    if (!isFiveM) return true;
    const r = await apiCall<void>('sd-phone:music:share', { target, kind: 'music-track', track });
    return r.success;
}

export async function sharePlaylist(name: string, tracks: Track[], target: number): Promise<boolean> {
    if (tracks.length === 0) return false;
    if (!isFiveM) return true;
    const r = await apiCall<void>('sd-phone:music:share', { target, kind: 'music-playlist', name, tracks });
    return r.success;
}

export function songKey(url: string): string {
    return youtubeId(url) ?? url.trim();
}

const DEFAULT_FOLDERS: Folder[] = [];
const DEFAULT_TRACKS: Track[] = [];


export interface ArtistGroup { name: string; tracks: Track[] }
export interface AlbumGroup  { key: string; album: string; artist: string; tracks: Track[] }

export function groupByArtist(tracks: Track[]): ArtistGroup[] {
    const map = new Map<string, Track[]>();
    for (const t of tracks) {
        const name = t.artist.trim() || 'Unknown artist';
        const list = map.get(name);
        if (list) list.push(t); else map.set(name, [t]);
    }
    return [...map.entries()]
        .map(([name, ts]) => ({ name, tracks: ts }))
        .sort((a, b) => a.name.localeCompare(b.name));
}

export function groupByAlbum(tracks: Track[]): AlbumGroup[] {
    const map = new Map<string, AlbumGroup>();
    for (const t of tracks) {
        const album = t.album?.trim();
        if (!album) continue;
        const key = `${t.artist} ${album}`;
        const g = map.get(key);
        if (g) g.tracks.push(t);
        else map.set(key, { key, album, artist: t.artist, tracks: [t] });
    }
    return [...map.values()].sort((a, b) => a.album.localeCompare(b.album));
}
