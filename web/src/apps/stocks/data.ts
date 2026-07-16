import { formatMoney } from '@/lib/money';
import { hashSeed, seededRandom } from '@/lib/random';

export { formatMoney } from '@/lib/money';

export type AssetKind = 'stock' | 'crypto';

export interface Asset {
    symbol:    string;
    name:      string;
    kind:      AssetKind;
    color:     string;
    price:     number;
    changePct: number;
    history:   number[];
    units:     number;
    avgCost:   number;
}

export interface Market {
    assets: Asset[];
    cash:   number;
}

export const UP_COLOR   = '#16c784';
export const DOWN_COLOR = '#ea3943';

export const trendColor = (frac: number) => (frac >= 0 ? UP_COLOR : DOWN_COLOR);


function groupInt(intStr: string): string {
    return intStr.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}


export function formatPrice(n: number): string {
    return formatMoney(n, { decimals: n >= 1 ? 2 : 4 });
}

export function formatUnits(n: number): string {
    if (!Number.isFinite(n)) return '0';
    const rounded = Math.round(n * 1e6) / 1e6;
    const [int, dec] = rounded.toString().split('.');
    return groupInt(int) + (dec ? `.${dec}` : '');
}

export function formatPct(frac: number): string {
    const p = frac * 100;
    return `${p >= 0 ? '+' : ''}${p.toFixed(2)}%`;
}

export const holdingValue = (a: Asset) => a.units * a.price;


export type SortKey = 'name' | 'change' | 'price';

export function sortAssets(assets: Asset[], key: SortKey, dir: 'asc' | 'desc'): Asset[] {
    const sign = dir === 'asc' ? 1 : -1;
    const out = [...assets];
    out.sort((a, b) => {
        let d = 0;
        if (key === 'name')        d = a.symbol.localeCompare(b.symbol);
        else if (key === 'change') d = a.changePct - b.changePct;
        else                       d = a.price - b.price;
        return d * sign;
    });
    return out;
}

export function genRangeSeries(symbol: string, rangeKey: string, points: number, vol: number, endPrice: number): number[] {
    const rnd = seededRandom(hashSeed(`${symbol}:${rangeKey}`));
    const gauss = () => {
        const u1 = Math.max(rnd(), 1e-9); const u2 = rnd();
        return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
    };
    const rel: number[] = [1];
    for (let i = 1; i < points; i++) rel.push(Math.max(0.05, rel[i - 1] * (1 + vol * gauss())));
    const scale = endPrice / rel[rel.length - 1];
    return rel.map(v => Math.round(v * scale * 100) / 100);
}


interface Seed { symbol: string; name: string; kind: AssetKind; color: string; base: number; vol: number; trend: number; }

const DEV_SEEDS: Seed[] = [
    { symbol: 'MZB', name: 'Maze Bank',     kind: 'stock', color: '#C0392B', base: 215.40, vol: 0.012, trend:  0.0008 },
    { symbol: 'TNK', name: 'Tinkle',        kind: 'stock', color: '#00B7EB', base:  88.10, vol: 0.018, trend:  0.0015 },
    { symbol: 'VAP', name: 'Vapid',         kind: 'stock', color: '#2C3E50', base: 142.75, vol: 0.014, trend:  0.0004 },
    { symbol: 'ECL', name: 'eCola',         kind: 'stock', color: '#E2231A', base:  53.20, vol: 0.013, trend: -0.0006 },
    { symbol: 'SPK', name: 'Sprunk',        kind: 'stock', color: '#2ECC71', base:  31.65, vol: 0.020, trend:  0.0010 },
    { symbol: 'CLK', name: "Cluckin' Bell", kind: 'stock', color: '#F4C20D', base:  24.90, vol: 0.017, trend: -0.0012 },
    { symbol: 'BSH', name: 'Burger Shot',   kind: 'stock', color: '#E4002B', base:  19.30, vol: 0.019, trend:  0.0006 },
    { symbol: 'LFI', name: 'Lifeinvader',   kind: 'stock', color: '#2D6CDF', base:  96.55, vol: 0.025, trend: -0.0020 },
    { symbol: 'MAI', name: 'Maibatsu',      kind: 'stock', color: '#8E8E93', base:  64.20, vol: 0.015, trend:  0.0009 },
    { symbol: 'FLY', name: 'FlyUS',         kind: 'stock', color: '#1E66D0', base:  12.45, vol: 0.022, trend: -0.0008 },
    { symbol: 'AMU', name: 'Ammu-Nation',   kind: 'stock', color: '#6B8E23', base: 178.00, vol: 0.016, trend:  0.0014 },
    { symbol: 'RWD', name: 'Redwood',       kind: 'stock', color: '#8B0000', base:  41.10, vol: 0.012, trend: -0.0015 },
    { symbol: 'RON', name: 'RON Oil',       kind: 'stock', color: '#ED1C24', base: 134.60, vol: 0.018, trend:  0.0010 },
    { symbol: 'GPO', name: 'GoPostal',      kind: 'stock', color: '#1B5E20', base:  47.80, vol: 0.012, trend:  0.0003 },
    { symbol: 'BIL', name: 'Bilkinton',     kind: 'stock', color: '#16A085', base: 162.30, vol: 0.020, trend:  0.0018 },
    { symbol: 'FRT', name: 'Fruit',         kind: 'stock', color: '#9AA0A6', base: 305.10, vol: 0.016, trend:  0.0020 },
    { symbol: 'VAN', name: 'Vangelico',     kind: 'stock', color: '#D4AF37', base:  71.40, vol: 0.014, trend:  0.0005 },
    { symbol: 'WIZ', name: 'Whiz Wireless', kind: 'stock', color: '#7B2FF7', base:  58.90, vol: 0.020, trend:  0.0012 },
    { symbol: 'DY8', name: 'Dynasty 8',     kind: 'stock', color: '#B8860B', base: 210.75, vol: 0.015, trend:  0.0016 },
    { symbol: 'PIS', name: 'Pisswasser',    kind: 'stock', color: '#C9A227', base:  27.85, vol: 0.018, trend: -0.0004 },
    { symbol: 'SDC', name: 'SD Coin',       kind: 'crypto', color: '#2A7DE1', base:    88.00, vol: 0.040, trend:  0.0030 },
    { symbol: 'BTL', name: 'BitLos',        kind: 'crypto', color: '#F7931A', base: 38250.00, vol: 0.030, trend:  0.0020 },
    { symbol: 'ETD', name: 'Etheriad',      kind: 'crypto', color: '#627EEA', base:  2410.00, vol: 0.035, trend:  0.0025 },
    { symbol: 'SPC', name: 'SprunkCoin',    kind: 'crypto', color: '#FF7A00', base:     4.82, vol: 0.060, trend:  0.0010 },
    { symbol: 'MZC', name: 'MazeCoin',      kind: 'crypto', color: '#9B59B6', base:    67.40, vol: 0.050, trend: -0.0020 },
    { symbol: 'FLC', name: 'FleecaCoin',    kind: 'crypto', color: '#00B894', base:     9.42, vol: 0.050, trend:  0.0020 },
    { symbol: 'WZC', name: 'WeazelCoin',    kind: 'crypto', color: '#C8102E', base:     0.85, vol: 0.070, trend:  0.0010 },
    { symbol: 'POG', name: 'PogoCoin',      kind: 'crypto', color: '#F1C40F', base:     2.36, vol: 0.065, trend: -0.0010 },
    { symbol: 'VWC', name: 'VinewoodCoin',  kind: 'crypto', color: '#8E44AD', base:   410.00, vol: 0.040, trend:  0.0030 },
    { symbol: 'KIF', name: 'Kifflom Coin',  kind: 'crypto', color: '#1ABC9C', base:    33.00, vol: 0.055, trend:  0.0025 },
];

const LIVE_VOL_SCALE = 0.06;
const LIVE_DRIFT_SCALE = 0.012;

function genHistory(seed: Seed, n: number): number[] {
    const rnd = seededRandom(hashSeed(seed.symbol));
    const gauss = () => {
        const u1 = Math.max(rnd(), 1e-9); const u2 = rnd();
        return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
    };
    let p = seed.base * (0.97 + rnd() * 0.06);
    const out: number[] = [];
    for (let i = 0; i < n; i++) {
        p = Math.max(seed.base * 0.3, p * (1 + seed.trend * LIVE_DRIFT_SCALE + seed.vol * LIVE_VOL_SCALE * gauss()));
        out.push(Math.round(p * 100) / 100);
    }
    return out;
}

const DEV_HISTORY_POINTS = 48;

const DEV_HOLDINGS: Record<string, { units: number; avgCost: number }> = {
    SDC: { units: 123.45, avgCost: 62.00 },
    MZB: { units: 8,      avgCost: 198.00 },
    BTL: { units: 0.1542, avgCost: 35100.00 },
    SPK: { units: 60,     avgCost: 29.80 },
};

interface Holder { units: number; pct: number; isYou: boolean; isMarket: boolean }
export interface Holders {
    holders:        Holder[];
    investorCount:  number;
    supply:         number;
    topPlayerPct:   number;
    whaleThreshold: number;
}

const DEV_MARKETCAP = 50_000_000;
const DEV_CAP_OVERRIDES: Record<string, number> = {
    MZB: 250_000_000, SDC: 35_000_000, SPC: 6_000_000, WZC: 4_000_000,
};

export function buildDevHolders(symbol: string, yourUnits: number, price: number): Holders {
    const rnd = seededRandom(hashSeed(`${symbol}:holders`));
    const cap = DEV_CAP_OVERRIDES[symbol] ?? DEV_MARKETCAP;
    const supply = Math.max(1, Math.round(cap / Math.max(price, 0.01)));

    const count = 2 + Math.floor(rnd() * 5);
    const whaleDollars = rnd() > 0.72 ? 2e6 + rnd() * 6e6 : 2e5 + rnd() * 1.5e6;
    const players: { u: number; you: boolean }[] = [{ u: whaleDollars / price, you: false }];
    for (let i = 1; i < count; i++) players.push({ u: (rnd() ** 2 * whaleDollars) / price, you: false });
    if (yourUnits > 0) players.push({ u: yourUnits, you: true });

    players.sort((a, b) => b.u - a.u);
    const held  = Math.min(players.reduce((s, p) => s + p.u, 0), supply);
    const float = Math.max(0, supply - held);
    const top   = players.slice(0, 5);
    const topPlayerPct = top.reduce((m, p) => Math.max(m, p.u / supply), 0);

    const holders: Holder[] = [
        { units: float, pct: float / supply, isYou: false, isMarket: true },
        ...top.map(p => ({ units: p.u, pct: p.u / supply, isYou: p.you, isMarket: false })),
    ];
    return { holders, investorCount: players.length, supply, topPlayerPct, whaleThreshold: 0.1 };
}

export function buildDevMarket(): Market {
    const assets: Asset[] = DEV_SEEDS.map(s => {
        const history = genHistory(s, DEV_HISTORY_POINTS);
        const price = history[history.length - 1];
        const first = history[0];
        const hold = DEV_HOLDINGS[s.symbol];
        return {
            symbol: s.symbol, name: s.name, kind: s.kind, color: s.color,
            price, changePct: first ? (price - first) / first : 0, history,
            units: hold?.units ?? 0, avgCost: hold?.avgCost ?? 0,
        };
    });
    return { assets, cash: 2500 };
}
