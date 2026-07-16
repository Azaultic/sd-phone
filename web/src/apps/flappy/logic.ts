export const FIELD_W = 392;
export const FIELD_H = 560;
export const GROUND_H = 64;

export const BIRD_X = 96;
export const BIRD_SIZE = 34;

export const GRAVITY = 0.42;
export const FLAP_V = -7.4;
export const MAX_FALL = 11;

export const PIPE_W = 62;
export const PIPE_GAP = 168;
export const PIPE_SPEED = 2.5;
export const PIPE_SPACING = 220;
const PIPE_MIN_TOP = 60;

export interface Pipe {
    id: number;
    x: number;
    gapY: number;
    scored: boolean;
}

export const skyH = (): number => FIELD_H - GROUND_H;

export function randomGapY(): number {
    const max = skyH() - PIPE_GAP - PIPE_MIN_TOP;
    return PIPE_MIN_TOP + Math.random() * Math.max(0, max - PIPE_MIN_TOP);
}

export function initialPipes(): Pipe[] {
    const pipes: Pipe[] = [];
    let id = 1;
    for (let x = FIELD_W + 80; x < FIELD_W + 80 + PIPE_SPACING * 3; x += PIPE_SPACING) {
        pipes.push({ id: id++, x, gapY: randomGapY(), scored: false });
    }
    return pipes;
}

export function hitsPipe(birdY: number, p: Pipe): boolean {
    const pad = 3;
    const bL = BIRD_X + pad;
    const bR = BIRD_X + BIRD_SIZE - pad;
    const bT = birdY + pad;
    const bB = birdY + BIRD_SIZE - pad;

    const withinX = bR > p.x && bL < p.x + PIPE_W;
    if (!withinX) return false;

    const gapTop = p.gapY;
    const gapBot = p.gapY + PIPE_GAP;
    return bT < gapTop || bB > gapBot;
}
