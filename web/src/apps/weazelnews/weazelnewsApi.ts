
import { isFiveM } from '@/core/nui';
import { ARTICLES, TICKER, type Article, type ArticleDraft, type NewsFeed } from './data';
import { apiCall, apiData } from '@/core/api';


let DEV_ARTICLES: Article[] = ARTICLES.map(a => ({ ...a, body: [...a.body] }));
let DEV_TICKER: string[] = [...TICKER];
let devIdSeq = 1000;


export async function weazelFeed(): Promise<NewsFeed> {
    if (!isFiveM) {
        return { articles: DEV_ARTICLES.map(a => ({ ...a })), ticker: [...DEV_TICKER], canManage: true };
    }
    return (await apiData<NewsFeed>('sd-phone:weazelnews:feed')) ?? { articles: [], ticker: [], canManage: false };
}

export async function weazelView(id: string): Promise<number | null> {
    if (!isFiveM) {
        const a = DEV_ARTICLES.find(x => x.id === id);
        if (!a) return null;
        a.views += 1;
        return a.views;
    }
    return (await apiData<{ views: number }>('sd-phone:weazelnews:view', { id }))?.views ?? null;
}

export async function weazelSave(draft: ArticleDraft): Promise<Article | null> {
    if (!isFiveM) {
        if (draft.featured) DEV_ARTICLES.forEach(a => { a.featured = false; });
        if (draft.id) {
            const a = DEV_ARTICLES.find(x => x.id === draft.id);
            if (!a) return null;
            a.category = draft.category;
            a.headline = draft.headline;
            a.dek      = draft.dek;
            a.body     = [...draft.body];
            a.image    = draft.image;
            a.featured = draft.featured;
            return { ...a };
        }
        const created: Article = {
            id: 'dev-' + devIdSeq++, category: draft.category, headline: draft.headline,
            dek: draft.dek, body: [...draft.body], author: 'You', time: 'now',
            views: 0, image: draft.image, featured: draft.featured,
        };
        DEV_ARTICLES = [created, ...DEV_ARTICLES];
        return { ...created };
    }
    return (await apiData<{ article: Article }>('sd-phone:weazelnews:save', draft))?.article ?? null;
}

export async function weazelDelete(id: string): Promise<boolean> {
    if (!isFiveM) {
        DEV_ARTICLES = DEV_ARTICLES.filter(a => a.id !== id);
        return true;
    }
    const r = await apiCall<unknown>('sd-phone:weazelnews:delete', { id });
    return r.success;
}

export async function weazelSetBreaking(lines: string[]): Promise<string[] | null> {
    if (!isFiveM) {
        DEV_TICKER = lines.map(l => l.trim()).filter(Boolean).slice(0, 8);
        return [...DEV_TICKER];
    }
    return (await apiData<{ ticker: string[] }>('sd-phone:weazelnews:setBreaking', { lines }))?.ticker ?? null;
}
