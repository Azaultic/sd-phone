
import { isFiveM } from '@/core/nui';
import type { Business, BusinessEdit, Review, ReviewDraft } from './data';
import { apiCall, apiData } from '@/core/api';


const DEV_CATEGORIES = ['Food', 'Auto', 'Nightlife', 'Shopping', 'Services', 'Health', 'Hotels'];

const DEV_BUSINESSES: Business[] = [
    { id: 'beanmachine', name: 'Bean Machine Coffee', category: 'Food',      address: 'Alta St, Downtown',      hours: '6am – 8pm',  blurb: 'Artisan roasts and fresh pastries in the heart of the city.', logo: '#6F4E37', rating: 4.5, count: 2 },
    { id: 'lscustoms',   name: 'Los Santos Customs',  category: 'Auto',      address: 'Greenwich Pkwy, La Mesa', hours: '24 hours',  blurb: 'Repairs, resprays and full custom builds.', logo: '#1C7ED6', rating: 4.0, count: 1, myRating: 4, canManage: true },
    { id: 'bahamamamas', name: 'Bahama Mamas',        category: 'Nightlife', address: 'San Andreas Ave',         hours: '9pm – 4am', blurb: 'Upscale club, bottle service and a packed dance floor.', logo: '#9C36B5', rating: 0, count: 0 },
    { id: 'pillbox',     name: 'Pillbox Medical',     category: 'Health',    address: 'Strawberry Ave',          hours: '24 hours',  blurb: 'Emergency care and check-ups, day or night.', logo: '#E64980', rating: 5, count: 1 },
];

const DEV_REVIEWS: Record<string, Review[]> = {
    beanmachine: [
        { id: 'd1', author: 'Mara Lopez',  rating: 5, body: 'Best flat white in the city, hands down. The baristas know my order.', date: 'Today',          mine: false, helpful: 3, helped: false },
        { id: 'd2', author: 'You',         rating: 4, body: 'Great coffee, gets a little crowded at lunch.',                         date: 'Yesterday',      mine: true,  helpful: 1, helped: false },
    ],
    lscustoms: [
        { id: 'd3', author: 'You',         rating: 4, body: 'Quick respray, fair price. Wheel selection could be bigger.',           date: 'May 20th, 2026', mine: true,  helpful: 0, helped: false },
    ],
    pillbox: [
        { id: 'd4', author: 'Dr. Reyes',   rating: 5, body: 'Fast triage even on a busy night. Professional staff.',                date: 'Today',          mine: false, helpful: 6, helped: true },
    ],
};

let devIdSeq = 100;

function recompute(b: Business) {
    const list = DEV_REVIEWS[b.id] ?? [];
    b.count = list.length;
    b.rating = list.length ? Math.round((list.reduce((s, r) => s + r.rating, 0) / list.length) * 10) / 10 : 0;
    const mine = list.find(r => r.mine);
    b.myRating = mine?.rating;
}


export async function reviewList(): Promise<{ businesses: Business[]; categories: string[] }> {
    if (!isFiveM) {
        DEV_BUSINESSES.forEach(recompute);
        return { businesses: [...DEV_BUSINESSES], categories: DEV_CATEGORIES };
    }
    return (await apiData<{ businesses: Business[]; categories: string[] }>('sd-phone:review:list')) ?? { businesses: [], categories: [] };
}

export async function reviewBusiness(id: string): Promise<{ business: Business; reviews: Review[] } | null> {
    if (!isFiveM) {
        const b = DEV_BUSINESSES.find(x => x.id === id);
        if (!b) return null;
        recompute(b);
        return { business: { ...b }, reviews: [...(DEV_REVIEWS[id] ?? [])] };
    }
    return await apiData<{ business: Business; reviews: Review[] }>('sd-phone:review:business', { id });
}

export async function reviewCreate(draft: ReviewDraft): Promise<Review | null> {
    if (!isFiveM) {
        const list = DEV_REVIEWS[draft.businessId] ?? (DEV_REVIEWS[draft.businessId] = []);
        if (list.some(r => r.mine)) return null;
        const review: Review = {
            id: 'dev-' + devIdSeq++, author: 'You', rating: draft.rating, body: draft.body,
            image: draft.image, date: 'Today', mine: true, helpful: 0, helped: false,
        };
        list.unshift(review);
        return { ...review };
    }
    return (await apiData<{ review: Review }>('sd-phone:review:create', draft))?.review ?? null;
}

export async function reviewDelete(id: string): Promise<boolean> {
    if (!isFiveM) {
        for (const k of Object.keys(DEV_REVIEWS)) DEV_REVIEWS[k] = DEV_REVIEWS[k].filter(r => r.id !== id);
        return true;
    }
    const r = await apiCall<unknown>('sd-phone:review:delete', { id });
    return r.success;
}

export async function reviewManage(edit: BusinessEdit): Promise<Business | null> {
    if (!isFiveM) {
        const b = DEV_BUSINESSES.find(x => x.id === edit.id);
        if (!b) return null;
        if (edit.hours.trim()) b.hours = edit.hours.trim();
        if (edit.blurb.trim()) b.blurb = edit.blurb.trim();
        if (/^#[0-9a-fA-F]{6}$/.test(edit.logo)) b.logo = edit.logo.toUpperCase();
        return { ...b };
    }
    return (await apiData<{ business: Business }>('sd-phone:review:manage', edit))?.business ?? null;
}

export async function reviewHelpful(id: string): Promise<{ helpful: number; helped: boolean } | null> {
    if (!isFiveM) {
        for (const list of Object.values(DEV_REVIEWS)) {
            const rev = list.find(r => r.id === id);
            if (rev) {
                rev.helped = !rev.helped;
                rev.helpful += rev.helped ? 1 : -1;
                return { helpful: rev.helpful, helped: rev.helped };
            }
        }
        return null;
    }
    return await apiData<{ helpful: number; helped: boolean }>('sd-phone:review:helpful', { id });
}
