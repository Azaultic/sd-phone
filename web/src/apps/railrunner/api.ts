import { isFiveM } from '@/core/nui';
import { DEFAULT_SKIN, SKINS } from './skins';
import { apiCall, apiData } from '@/core/api';
import { readJson, writeJson } from '@/lib/storage';

export interface Profile {
    best: number;
    coins: number;
    totalCoins: number;
    plays: number;
    unlocked: string[];
    selected: string;
}

interface LbRow { name: string | null; best: number }
export interface LeaderboardData { top: LbRow[]; you: { best: number; rank: number | null } }

export const emptyProfile = (): Profile => ({
    best: 0, coins: 0, totalCoins: 0, plays: 0, unlocked: [DEFAULT_SKIN], selected: DEFAULT_SKIN,
});

const DEV_KEY = 'sd-phone:railrunner:profile:v1';
const COST = Object.fromEntries(SKINS.map((s) => [s.id, s.cost])) as Record<string, number>;

function devRead(): Profile {
    const p = readJson<Partial<Profile>>(DEV_KEY);
    if (p && typeof p.best === 'number') {
        return {
            best: p.best | 0,
            coins: (p.coins ?? 0) | 0,
            totalCoins: (p.totalCoins ?? 0) | 0,
            plays: (p.plays ?? 0) | 0,
            unlocked: Array.isArray(p.unlocked) && p.unlocked.length ? p.unlocked : [DEFAULT_SKIN],
            selected: typeof p.selected === 'string' ? p.selected : DEFAULT_SKIN,
        };
    }
    return emptyProfile();
}
function devWrite(p: Profile) { writeJson(DEV_KEY, p); }

const DEV_BOTS: LbRow[] = [
    { name: 'DashKing', best: 3120 }, { name: 'RailRat', best: 2410 }, { name: 'Sprintz', best: 1880 },
    { name: 'Hopper', best: 1395 }, { name: 'Slider', best: 980 }, { name: 'Coinz', best: 640 },
    { name: 'Newbie', best: 310 }, { name: 'Rookie', best: 120 },
];

export async function getProfile(): Promise<Profile> {
    if (!isFiveM) return devRead();
    return (await apiData<Profile>('sd-phone:games:rrProfile')) ?? emptyProfile();
}

export async function submitRun(dist: number, coins: number): Promise<{ profile: Profile; newBest: boolean }> {
    if (!isFiveM) {
        const p = devRead();
        const newBest = dist > p.best;
        const next: Profile = { ...p, best: Math.max(p.best, dist), coins: p.coins + coins, totalCoins: p.totalCoins + coins, plays: p.plays + 1 };
        devWrite(next);
        return { profile: next, newBest };
    }
    return (await apiData<{ profile: Profile; newBest: boolean }>('sd-phone:games:rrSubmit', { dist, coins }))
        ?? { profile: emptyProfile(), newBest: false };
}

export async function buySkin(skin: string): Promise<{ profile?: Profile; error?: string }> {
    if (!isFiveM) {
        const p = devRead();
        const cost = COST[skin];
        if (cost == null) return { error: 'Unknown item' };
        if (p.unlocked.includes(skin)) return { error: 'Already owned' };
        if (p.coins < cost) return { error: 'Not enough coins' };
        const next: Profile = { ...p, coins: p.coins - cost, unlocked: [...p.unlocked, skin] };
        devWrite(next);
        return { profile: next };
    }
    const r = await apiCall<Profile>('sd-phone:games:rrBuy', { skin });
    return r.success && r.data ? { profile: r.data } : { error: r.message || 'Purchase failed' };
}

export async function selectSkin(skin: string): Promise<Profile | null> {
    if (!isFiveM) {
        const p = devRead();
        if (skin !== DEFAULT_SKIN && !p.unlocked.includes(skin)) return null;
        const next = { ...p, selected: skin };
        devWrite(next);
        return next;
    }
    return await apiData<Profile>('sd-phone:games:rrSelect', { skin });
}

export async function loadLeaderboard(): Promise<LeaderboardData> {
    if (!isFiveM) {
        const me = devRead().best;
        const top = [...DEV_BOTS];
        if (me > 0) top.push({ name: 'You', best: me });
        top.sort((a, b) => b.best - a.best);
        const rank = me > 0 ? DEV_BOTS.filter((b) => b.best > me).length + 1 : null;
        return { top: top.slice(0, 20), you: { best: me, rank } };
    }
    return (await apiData<LeaderboardData>('sd-phone:games:rrLeaderboard')) ?? { top: [], you: { best: 0, rank: null } };
}
