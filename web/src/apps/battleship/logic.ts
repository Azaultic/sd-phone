
export const GRID = 8;
export const CELLS = GRID * GRID;
export const idx = (r: number, c: number): number => r * GRID + c;
export const rowOf = (i: number): number => Math.floor(i / GRID);
export const colOf = (i: number): number => i % GRID;

export type Difficulty = 'easy' | 'medium' | 'hard';

interface ShipDef { id: string; name: string; size: number }
const FLEET: ShipDef[] = [
    { id: 'carrier',   name: 'Carrier',   size: 4 },
    { id: 'cruiser',   name: 'Cruiser',   size: 3 },
    { id: 'submarine', name: 'Submarine', size: 3 },
    { id: 'destroyer', name: 'Destroyer', size: 2 },
];
export const FLEET_CELLS = FLEET.reduce((n, s) => n + s.size, 0);

export interface Ship { id: string; name: string; size: number; cells: number[] }
export type Fleet = Ship[];

export function randomFleet(): Fleet {
    for (let attempt = 0; attempt < 500; attempt++) {
        const occupied = new Set<number>();
        const ships: Fleet = [];
        let ok = true;
        for (const def of FLEET) {
            const ship = placeOne(def, occupied);
            if (!ship) { ok = false; break; }
            ships.push(ship);
            for (const c of ship.cells) occupied.add(c);
        }
        if (ok) return ships;
    }
    return FLEET.map((def, i) => ({ ...def, cells: Array.from({ length: def.size }, (_, k) => idx(i, k)) }));
}

function placeOne(def: ShipDef, occupied: Set<number>): Ship | null {
    for (let tries = 0; tries < 100; tries++) {
        const horiz = Math.random() < 0.5;
        const r = Math.floor(Math.random() * (horiz ? GRID : GRID - def.size + 1));
        const c = Math.floor(Math.random() * (horiz ? GRID - def.size + 1 : GRID));
        const cells: number[] = [];
        for (let k = 0; k < def.size; k++) cells.push(horiz ? idx(r, c + k) : idx(r + k, c));
        if (cells.some(x => occupied.has(x))) continue;
        return { ...def, cells };
    }
    return null;
}

export function shipAt(fleet: Fleet, cell: number): Ship | undefined {
    return fleet.find(s => s.cells.includes(cell));
}

function isSunk(ship: Ship, hits: Set<number>): boolean {
    return ship.cells.every(c => hits.has(c));
}

export function sunkCells(fleet: Fleet, hits: Set<number>): Set<number> {
    const out = new Set<number>();
    for (const s of fleet) if (isSunk(s, hits)) for (const c of s.cells) out.add(c);
    return out;
}

export function aiNextShot(shots: Record<number, 'hit' | 'miss'>, sunk: Set<number>, difficulty: Difficulty): number {
    const tried = (c: number) => shots[c] !== undefined;
    const inB = (r: number, c: number) => r >= 0 && r < GRID && c >= 0 && c < GRID;

    const active = Object.keys(shots).map(Number).filter(c => shots[c] === 'hit' && !sunk.has(c));

    if (difficulty !== 'easy' && active.length > 0) {
        const targets = new Set<number>();
        for (const a of active) {
            const ra = rowOf(a), ca = colOf(a);
            const sameRow = active.filter(x => rowOf(x) === ra);
            const sameCol = active.filter(x => colOf(x) === ca);
            if (sameRow.length >= 2) {
                const cols = sameRow.map(colOf).sort((m, n) => m - n);
                const lo = cols[0], hi = cols[cols.length - 1];
                if (inB(ra, lo - 1) && !tried(idx(ra, lo - 1))) targets.add(idx(ra, lo - 1));
                if (inB(ra, hi + 1) && !tried(idx(ra, hi + 1))) targets.add(idx(ra, hi + 1));
            }
            if (sameCol.length >= 2) {
                const rows = sameCol.map(rowOf).sort((m, n) => m - n);
                const lo = rows[0], hi = rows[rows.length - 1];
                if (inB(lo - 1, ca) && !tried(idx(lo - 1, ca))) targets.add(idx(lo - 1, ca));
                if (inB(hi + 1, ca) && !tried(idx(hi + 1, ca))) targets.add(idx(hi + 1, ca));
            }
        }
        if (targets.size === 0) {
            for (const h of active) {
                const r = rowOf(h), c = colOf(h);
                for (const [dr, dc] of [[0, 1], [0, -1], [1, 0], [-1, 0]] as const) {
                    if (inB(r + dr, c + dc) && !tried(idx(r + dr, c + dc))) targets.add(idx(r + dr, c + dc));
                }
            }
        }
        const list = [...targets];
        if (list.length) return list[Math.floor(Math.random() * list.length)];
    }

    const candidates: number[] = [];
    for (let i = 0; i < CELLS; i++) {
        if (tried(i)) continue;
        if (difficulty === 'hard' && (rowOf(i) + colOf(i)) % 2 !== 0) continue;
        candidates.push(i);
    }
    const pool = candidates.length ? candidates : Array.from({ length: CELLS }, (_, i) => i).filter(i => !tried(i));
    return pool[Math.floor(Math.random() * pool.length)];
}
