export const COLS = 10;
export const ROWS = 20;

export type PieceKind = 'I' | 'O' | 'T' | 'S' | 'Z' | 'J' | 'L';

type Cell = PieceKind | 0;
export type Board = Cell[][];

type Rot = ReadonlyArray<readonly [number, number]>;

interface Shape {
    rotations: ReadonlyArray<Rot>;
    color: string;
    glow: string;
}

export const SHAPES: Record<PieceKind, Shape> = {
    I: {
        color: '#39C5DE', glow: '#7FE4F2',
        rotations: [
            [[0, 1], [1, 1], [2, 1], [3, 1]],
            [[2, 0], [2, 1], [2, 2], [2, 3]],
            [[0, 2], [1, 2], [2, 2], [3, 2]],
            [[1, 0], [1, 1], [1, 2], [1, 3]],
        ],
    },
    O: {
        color: '#F4C84A', glow: '#FFE08A',
        rotations: [
            [[1, 0], [2, 0], [1, 1], [2, 1]],
            [[1, 0], [2, 0], [1, 1], [2, 1]],
            [[1, 0], [2, 0], [1, 1], [2, 1]],
            [[1, 0], [2, 0], [1, 1], [2, 1]],
        ],
    },
    T: {
        color: '#B45CE0', glow: '#D89BF0',
        rotations: [
            [[1, 0], [0, 1], [1, 1], [2, 1]],
            [[1, 0], [1, 1], [2, 1], [1, 2]],
            [[0, 1], [1, 1], [2, 1], [1, 2]],
            [[1, 0], [0, 1], [1, 1], [1, 2]],
        ],
    },
    S: {
        color: '#5BD86A', glow: '#9CEDA6',
        rotations: [
            [[1, 0], [2, 0], [0, 1], [1, 1]],
            [[1, 0], [1, 1], [2, 1], [2, 2]],
            [[1, 1], [2, 1], [0, 2], [1, 2]],
            [[0, 0], [0, 1], [1, 1], [1, 2]],
        ],
    },
    Z: {
        color: '#F0556B', glow: '#FB94A2',
        rotations: [
            [[0, 0], [1, 0], [1, 1], [2, 1]],
            [[2, 0], [1, 1], [2, 1], [1, 2]],
            [[0, 1], [1, 1], [1, 2], [2, 2]],
            [[1, 0], [0, 1], [1, 1], [0, 2]],
        ],
    },
    J: {
        color: '#4D7DF0', glow: '#92AEF8',
        rotations: [
            [[0, 0], [0, 1], [1, 1], [2, 1]],
            [[1, 0], [2, 0], [1, 1], [1, 2]],
            [[0, 1], [1, 1], [2, 1], [2, 2]],
            [[1, 0], [1, 1], [0, 2], [1, 2]],
        ],
    },
    L: {
        color: '#F0913C', glow: '#FBBF85',
        rotations: [
            [[2, 0], [0, 1], [1, 1], [2, 1]],
            [[1, 0], [1, 1], [1, 2], [2, 2]],
            [[0, 1], [1, 1], [2, 1], [0, 2]],
            [[0, 0], [1, 0], [1, 1], [1, 2]],
        ],
    },
};

const KINDS: PieceKind[] = ['I', 'O', 'T', 'S', 'Z', 'J', 'L'];

export interface Piece {
    kind: PieceKind;
    rot: number;
    x: number;
    y: number;
}

export function emptyBoard(): Board {
    return Array.from({ length: ROWS }, () => Array<Cell>(COLS).fill(0));
}

export function cellsOf(p: Piece): Array<readonly [number, number]> {
    return SHAPES[p.kind].rotations[p.rot].map(([dx, dy]) => [p.x + dx, p.y + dy] as const);
}

export function valid(board: Board, p: Piece): boolean {
    for (const [x, y] of cellsOf(p)) {
        if (x < 0 || x >= COLS || y >= ROWS) return false;
        if (y >= 0 && board[y][x] !== 0) return false;
    }
    return true;
}

export function spawn(kind: PieceKind): Piece {
    return { kind, rot: 0, x: 3, y: kind === 'I' ? -1 : 0 };
}

const KICKS: ReadonlyArray<readonly [number, number]> = [
    [0, 0], [-1, 0], [1, 0], [-2, 0], [2, 0], [0, -1],
];

export function rotate(board: Board, p: Piece): Piece {
    const nextRot = (p.rot + 1) % 4;
    for (const [dx, dy] of KICKS) {
        const cand: Piece = { ...p, rot: nextRot, x: p.x + dx, y: p.y + dy };
        if (valid(board, cand)) return cand;
    }
    return p;
}

export function ghostY(board: Board, p: Piece): number {
    let test = { ...p };
    while (valid(board, { ...test, y: test.y + 1 })) test = { ...test, y: test.y + 1 };
    return test.y;
}

export interface MergeResult {
    board: Board;
    cleared: number;
}

export function lockAndClear(board: Board, p: Piece): MergeResult {
    const next: Board = board.map(row => row.slice());
    for (const [x, y] of cellsOf(p)) {
        if (y >= 0 && y < ROWS && x >= 0 && x < COLS) next[y][x] = p.kind;
    }

    const kept = next.filter(row => row.some(c => c === 0));
    const cleared = ROWS - kept.length;
    if (cleared === 0) return { board: next, cleared: 0 };

    const filled: Board = Array.from({ length: cleared }, () => Array<Cell>(COLS).fill(0));
    return { board: filled.concat(kept), cleared };
}

export function lineScore(cleared: number, level: number): number {
    const base = [0, 40, 100, 300, 1200][cleared] ?? 0;
    return base * (level + 1);
}

export function levelFor(lines: number): number {
    return Math.floor(lines / 10);
}

export function dropMs(level: number): number {
    return Math.max(80, 800 - level * 70);
}

export class Bag {
    private queue: PieceKind[] = [];

    next(): PieceKind {
        if (this.queue.length === 0) {
            this.queue = KINDS.slice();
            for (let i = this.queue.length - 1; i > 0; i--) {
                const j = Math.floor(Math.random() * (i + 1));
                [this.queue[i], this.queue[j]] = [this.queue[j], this.queue[i]];
            }
        }
        return this.queue.pop()!;
    }
}
