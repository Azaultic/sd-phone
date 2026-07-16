import { create } from 'zustand';
import { persist } from 'zustand/middleware';

import {
    loadFolders, loadTracks, newId, songKey, titleFromUrl,
    type Folder, type IncomingTrack, type Track,
} from '@/apps/music/data';

// The music LIBRARY (tracks + playlist folders), persisted by the zustand
// persist middleware. Lives in a store because it mutates while the Music app
// is closed: AirShare deliveries land via App.tsx and must show up when Music
// next renders. The playback ENGINE stays in MusicContext (owns <audio>/
// YouTube refs). Initial state seeds from the legacy two-key localStorage
// format (loadTracks/loadFolders), so pre-existing libraries carry over; once
// the middleware writes its own key, that wins on later boots.
interface MusicLibraryState {
    tracks:  Track[];
    folders: Folder[];
    setTracks:  (next: Track[] | ((prev: Track[]) => Track[])) => void;
    setFolders: (next: Folder[] | ((prev: Folder[]) => Folder[])) => void;
    /** Merge AirShare-received tracks; returns only the ones that were new. */
    addReceivedTracks: (incoming: IncomingTrack[]) => Track[];
    /** Merge an AirShare-received playlist: dedupes songs, adds a folder. */
    addReceivedPlaylist: (name: string, incoming: IncomingTrack[]) => void;
}

export const useMusicLibrary = create<MusicLibraryState>()(
    persist(
        (set, get) => ({
            tracks:  loadTracks(),
            folders: loadFolders(),

            setTracks: (next) => {
                set(s => ({ tracks: typeof next === 'function' ? next(s.tracks) : next }));
            },

            setFolders: (next) => {
                set(s => ({ folders: typeof next === 'function' ? next(s.folders) : next }));
            },

            addReceivedTracks: (incoming) => {
                const existing = get().tracks;
                const haveKey = new Set(existing.map(t => songKey(t.url)));
                const fresh: Track[] = [];
                for (const t of incoming) {
                    if (!t || !t.url) continue;
                    const key = songKey(t.url);
                    if (haveKey.has(key)) continue;
                    haveKey.add(key);
                    fresh.push({
                        id: newId(), url: t.url, addedAt: Date.now(),
                        title: t.title || titleFromUrl(t.url), artist: t.artist || 'Shared', album: t.album,
                    });
                }
                if (fresh.length) set({ tracks: [...fresh, ...existing] });
                return fresh;
            },

            addReceivedPlaylist: (name, incoming) => {
                const existing = get().tracks;
                const byKey = new Map(existing.map(t => [songKey(t.url), t]));
                const toAdd: Track[] = [];
                const trackIds: string[] = [];
                for (const t of incoming) {
                    if (!t || !t.url) continue;
                    const key = songKey(t.url);
                    const have = byKey.get(key);
                    if (have) { if (!trackIds.includes(have.id)) trackIds.push(have.id); continue; }
                    const nt: Track = {
                        id: newId(), url: t.url, addedAt: Date.now(),
                        title: t.title || titleFromUrl(t.url), artist: t.artist || 'Shared', album: t.album,
                    };
                    byKey.set(key, nt);
                    toAdd.push(nt);
                    trackIds.push(nt.id);
                }
                if (trackIds.length === 0) return;
                const folder: Folder = { id: 'f' + Math.random().toString(36).slice(2, 10), name: (name || 'Shared Playlist').slice(0, 60), trackIds };
                set(s => ({
                    tracks:  toAdd.length ? [...toAdd, ...s.tracks] : s.tracks,
                    folders: [folder, ...s.folders],
                }));
            },
        }),
        {
            name: 'sd-phone:music:lib:v1',
            partialize: s => ({ tracks: s.tracks, folders: s.folders }),
        },
    ),
);
