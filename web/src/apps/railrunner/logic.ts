import { readJson, writeJson } from '@/lib/storage';

export const FIELD_W = 392;
export const FIELD_H = 560;

const LANES = 3;
export const LANE_W = FIELD_W / LANES;
export const laneCenter = (lane: number): number => LANE_W * (lane + 0.5);

export const RUNNER_W = 46;
export const RUNNER_H = 58;
export const RUNNER_Y = FIELD_H - 150;

const BASE_SPEED = 2.8;
const MAX_SPEED = 7.6;
const SPEED_RAMP = 0.0007;
export const ROW_GAP = 250;

export const TELEGRAPH_STEPS = 26;

export const JUMP_IMPULSE = 14;
export const GRAVITY = 0.92;
const AIR_CLEAR = 22;

export const ROLL_MS = 560;

export const ENTITY_SIZE = 52;

export type Kind = 'train' | 'hurdle' | 'gate' | 'coin';

export interface Entity {
    id: number;
    lane: number;
    y: number;
    kind: Kind;
    taken?: boolean;
    resolved?: boolean;
}

let seedNudge = 0;

export function spawnRow(id0: number, topY: number): { entities: Entity[]; nextId: number } {
    let id = id0;
    const out: Entity[] = [];

    const obstacleCount = Math.random() < 0.3 ? 2 : 1;
    const lanes = [0, 1, 2];
    for (let i = lanes.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [lanes[i], lanes[j]] = [lanes[j], lanes[i]];
    }
    const blocked = lanes.slice(0, obstacleCount);
    const open = lanes.slice(obstacleCount);

    const kinds: Kind[] = ['train', 'hurdle', 'gate'];
    for (const lane of blocked) {
        const kind = kinds[Math.floor(Math.random() * kinds.length)];
        out.push({ id: id++, lane, y: topY, kind });
    }

    if (open.length && Math.random() < 0.4) {
        const lane = open[Math.floor(Math.random() * open.length)];
        const n = 1 + Math.floor(Math.random() * 2);
        for (let k = 0; k < n; k++) {
            out.push({ id: id++, lane, y: topY - k * 46, kind: 'coin' });
        }
    }

    return { entities: out, nextId: id };
}

export function initialEntities(): { entities: Entity[]; nextId: number } {
    let id = 1;
    let entities: Entity[] = [];
    seedNudge = (seedNudge + 1) % 3;
    for (let r = 0; r < 4; r++) {
        const topY = -120 - r * ROW_GAP - seedNudge * 30;
        const row = spawnRow(id, topY);
        entities = entities.concat(row.entities);
        id = row.nextId;
    }
    return { entities, nextId: id };
}

export function speedAt(distance: number): number {
    return Math.min(MAX_SPEED, BASE_SPEED + distance * SPEED_RAMP);
}

export const metres = (distance: number): number => Math.floor(distance / 10);

export interface RunnerState {
    lane: number;
    jumpZ: number;
    rolling: boolean;
}

export const CONTACT_Y = RUNNER_Y + RUNNER_H / 2;

const CONTACT_OFFSET: Record<Kind, number> = {
    train:  ENTITY_SIZE / 2,   // 26 — middle of the wall
    hurdle: ENTITY_SIZE - 9,   // 43 — middle of the low bar (drawn at the bottom)
    gate:   7,                 // middle of the overhead bar (drawn at the top)
    coin:   13,                // middle of the coin
};

export function entityContactY(e: Entity): number {
    return e.y + CONTACT_OFFSET[e.kind];
}

export function crossedContact(prevY: number, curY: number, kind: Kind): boolean {
    const off = CONTACT_OFFSET[kind];
    return prevY + off < CONTACT_Y && curY + off >= CONTACT_Y;
}

export function resolveCross(e: Entity, r: RunnerState): 'coin' | 'dead' | null {
    if (e.lane !== r.lane) return null;
    switch (e.kind) {
        case 'coin':   return e.taken ? null : 'coin';
        case 'train':  return 'dead';
        case 'hurdle': return r.jumpZ > AIR_CLEAR ? null : 'dead';
        case 'gate':   return r.rolling ? null : 'dead';
    }
}

const ACH_KEY = 'sd-phone:railrunner:ach:v1';

export function loadAchievements(): string[] {
    return readJson<string[]>(ACH_KEY, Array.isArray) ?? [];
}

export function saveAchievements(ids: string[]): void {
    writeJson(ACH_KEY, ids);
}

export interface Achievement { id: string; name: string; desc: string; }

export const ACHIEVEMENTS: Achievement[] = [
    { id: 'first',   name: 'First Steps',   desc: 'Run 250m in a single game' },
    { id: 'm500',    name: 'Getting Quick', desc: 'Run 1,000m in a single game' },
    { id: 'm1000',   name: 'Marathoner',    desc: 'Run 2,500m in a single game' },
    { id: 'm2500',   name: 'Untouchable',   desc: 'Run 5,000m in a single game' },
    { id: 'coin50',  name: 'Coin Purse',    desc: 'Collect 100 coins in one game' },
    { id: 'coin200', name: 'Loaded',        desc: 'Collect 1,000 coins total' },
    { id: 'play25',  name: 'Seasoned',      desc: 'Play 50 games' },
];

export function satisfiedAchievements(c: { score: number; runCoins: number; totalCoins: number; plays: number }): string[] {
    const ids: string[] = [];
    if (c.score >= 250)        ids.push('first');
    if (c.score >= 1000)       ids.push('m500');
    if (c.score >= 2500)       ids.push('m1000');
    if (c.score >= 5000)       ids.push('m2500');
    if (c.runCoins >= 100)     ids.push('coin50');
    if (c.totalCoins >= 1000)  ids.push('coin200');
    if (c.plays >= 50)         ids.push('play25');
    return ids;
}

