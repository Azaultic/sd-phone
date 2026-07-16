import { fetchNui, isFiveM } from '@/core/nui';
import { apiData, type Envelope } from '@/core/api';

export interface GifItem     { id: string; preview: string; full: string }
export interface GifCategory { name: string; term: string; image: string }

const DEV_CATEGORIES: GifCategory[] = [
    '#excited', '#lol', '#no', '#bye', '#sorry', '#congratulations',
    '#sleepy', '#hello', '#hugs', '#ok', '#please', '#thank you',
    '#miss you', '#wink', '#yes', '#happy',
].map(name => ({ name, term: name.slice(1), image: '' }));

const DEV_GIFS: GifItem[] = Array.from({ length: 14 }, (_, i) => ({ id: `dev-${i}`, preview: '', full: '' }));

let categoriesCache:   GifCategory[] | null = null;
let categoriesInFlight: Promise<GifCategory[] | null> | null = null;

export async function fetchGifCategories(): Promise<GifCategory[] | null> {
    if (!isFiveM) return DEV_CATEGORIES;
    if (categoriesCache) return categoriesCache;
    if (categoriesInFlight) return categoriesInFlight;
    categoriesInFlight = (async () => {
        const res  = await fetchNui<Envelope<GifCategory[]>>('sd-phone:gifs:categories');
        const data = res?.success ? (res.data ?? []) : null;
        if (data) categoriesCache = data;
        categoriesInFlight = null;
        return data;
    })();
    return categoriesInFlight;
}

export function warmGifCategories(): void {
    if (!isFiveM) return;
    void fetchGifCategories().then(cats => {
        for (const c of cats ?? []) {
            if (c.image) { const img = new Image(); img.src = c.image; }
        }
    });
}

export async function fetchFeaturedGifs(): Promise<GifItem[]> {
    if (!isFiveM) return DEV_GIFS;
    return (await apiData<{ gifs: GifItem[] }>('sd-phone:gifs:featured'))?.gifs ?? [];
}

export async function searchGifs(q: string): Promise<GifItem[]> {
    if (!isFiveM) return DEV_GIFS;
    return (await apiData<{ gifs: GifItem[] }>('sd-phone:gifs:search', { q }))?.gifs ?? [];
}
